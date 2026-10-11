@tool
extends RefCounted
## Tools that are not a plain pass-through to one bridge command: images,
## multi-frame and tabular results from the running game, and the Asset Library
## tools (which in the Node server live outside the bridge). Each adapter
## returns an MCP tool result {content: [...]} or {error: "message"}.
## See docs/phase0_inventory.md for why each one is an adapter.

const GameClient = preload("res://addons/godot_live_mcp/mcp_game_client.gd")

const API := "https://godotengine.org/asset-library/api"
const SITE := "https://godotengine.org/asset-library/asset"
const ALLOWED_HOSTS := ["github.com", "codeload.github.com", "gitlab.com", "bitbucket.org"]
const DEFAULT_GODOT_VERSION := "4.7"
const MAX_ZIP_BYTES := 100 * 1024 * 1024
const SAMPLING_TIMEOUT_MS := 15000

const NAMES := ["image", "capture_game_frames", "monitor_game_properties", "search_assets", "install_asset"]

var _host: Node
var _bridge: Node
var game


func setup(host: Node, bridge: Node) -> void:
	_host = host
	_bridge = bridge
	game = GameClient.new()
	game.setup(host, Callable(bridge, "get_token"))


func run(adapter: String, entry: Dictionary, args: Dictionary) -> Dictionary:
	var x: Dictionary = entry.x_godot
	var command: String = x.get("command", entry.name)
	match adapter:
		"image":
			return _image(await _call(x, command, args))
		"capture_game_frames":
			return _frames(await game.call_command(command, args, SAMPLING_TIMEOUT_MS))
		"monitor_game_properties":
			return _table(await game.call_command(command, args, SAMPLING_TIMEOUT_MS))
		"search_assets":
			return await _search_assets(args)
		"install_asset":
			return await _install_asset(args)
	return {"error": "unknown adapter: %s" % adapter}


func _call(x: Dictionary, command: String, args: Dictionary) -> Dictionary:
	if x.get("target", "editor") == "game":
		return await game.call_command(command, args)
	return await _bridge.execute_command(command, args)


# ---- results ---------------------------------------------------------------

func _image(out: Dictionary) -> Dictionary:
	if not out.ok:
		return {"error": str(out.error)}
	var r: Dictionary = out.result
	return {"content": [{"type": "image", "data": r.base64, "mimeType": "image/%s" % r.format}]}


func _frames(out: Dictionary) -> Dictionary:
	if not out.ok:
		return {"error": str(out.error)}
	var content: Array = []
	for f in out.result.frames:
		content.append({"type": "text", "text": "t=%.3fs (%dx%d)" % [float(f.t), int(f.width), int(f.height)]})
		content.append({"type": "image", "data": f.base64, "mimeType": "image/%s" % f.format})
	return {"content": content}


## One row per line: pretty-printed JSON would put every cell on its own line.
func _table(out: Dictionary) -> Dictionary:
	if not out.ok:
		return {"error": str(out.error)}
	var lines: Array = [JSON.stringify(out.result.columns)]
	for row in out.result.rows:
		var cells: Array = [snappedf(float(row[0]), 0.001)]
		cells.append_array(row.slice(1))
		lines.append(JSON.stringify(_ints(cells), "", false))
	return {"content": [{"type": "text", "text": "\n".join(PackedStringArray(lines))}]}


func _text_result(value: Variant) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(_ints(value), "  ", false)}]}


func _sorted(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var out := {}
		for k in keys:
			out[k] = _sorted(value[k])
		return out
	if value is Array:
		return value.map(func(v): return _sorted(v))
	return value


## JSON parsing makes every number a float; whole ones go back to integers.
func _ints(value: Variant) -> Variant:
	if value is float and value == floorf(value) and absf(value) < 9007199254740992.0:
		return int(value)
	if value is Array:
		return value.map(func(v): return _ints(v))
	if value is Dictionary:
		var out := {}
		for k in value:
			out[k] = _ints(value[k])
		return out
	return value


# ---- Asset Library ---------------------------------------------------------

func _http_get(url: String, timeout_sec: float, size_limit: int = -1) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout_sec
	if size_limit > 0:
		req.body_size_limit = size_limit
	_host.add_child(req)
	var err := req.request(url, PackedStringArray(["User-Agent: godot-live-mcp"]))
	if err != OK:
		req.queue_free()
		return {"error": "could not start the request for %s (error %d)" % [url, err]}
	var done: Array = await req.request_completed
	req.queue_free()
	if done[0] != HTTPRequest.RESULT_SUCCESS:
		return {"error": "request failed (result %d) for %s" % [done[0], url]}
	return {"code": done[1], "headers": done[2], "body": done[3]}


func _get_json(url: String) -> Dictionary:
	var res: Dictionary = await _http_get(url, 20.0)
	if res.has("error"):
		return {"error": "Asset Library %s" % res.error}
	if res.code < 200 or res.code >= 300:
		return {"error": "Asset Library request failed (%d) for %s" % [res.code, url]}
	var json := JSON.new()
	if json.parse(res.body.get_string_from_utf8()) != OK or not (json.data is Dictionary):
		return {"error": "Asset Library sent a reply that is not valid JSON (%s)" % url}
	return {"data": json.data}


func _editor_version() -> String:
	var v := Engine.get_version_info()
	return "%d.%d" % [v.major, v.minor]


var _category_cache: Variant = null

func _category_id(name: String) -> String:
	if name.is_valid_int():
		return name
	if _category_cache == null:
		_category_cache = []
		var res: Dictionary = await _get_json("%s/configure?type=addon" % API)
		if res.has("data"):
			_category_cache = res.data.get("categories", [])
	for c in _category_cache:
		if str(c.get("name", "")).to_lower() == name.to_lower():
			return str(c.get("id", ""))
	return ""


func _search_assets(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", "")).strip_edges()
	var max_results := clampi(int(args.get("max_results", 8)), 1, 20)
	var params := {"filter": query, "max_results": str(max_results), "type": str(args.get("type", "addon"))}
	var notes: Array = []
	# The API treats a missing version as a very old engine and returns nothing,
	# so always send one; the editor is right here, so ask it.
	var version := str(args.get("godot_version", ""))
	if version == "":
		version = _editor_version()
	params["godot_version"] = version
	if args.get("sort"):
		params["sort"] = str(args.sort)
	if int(args.get("page", 0)) != 0:
		params["page"] = str(int(args.page))
	if args.get("category"):
		var id: String = await _category_id(str(args.category))
		if id != "":
			params["category"] = id
		else:
			notes.append("unknown category \"%s\" — not filtered" % str(args.category))
	var pairs: Array = []
	for k in params:
		pairs.append("%s=%s" % [str(k).uri_encode(), str(params[k]).uri_encode()])
	var res: Dictionary = await _get_json("%s/asset?%s" % [API, "&".join(PackedStringArray(pairs))])
	if res.has("error"):
		return {"error": res.error}
	var data: Dictionary = res.data
	var results: Array = data.get("result", [])
	if args.get("support"):
		results = results.filter(func(a): return a.get("support_level") == args.support)
	var rows: Array = []
	for a in results:
		rows.append({
			"asset_id": a.get("asset_id"), "title": a.get("title"), "author": a.get("author"),
			"category": a.get("category"),
			"license": a.get("cost"),  # the API's "cost" field holds the licence
			"support_level": a.get("support_level"), "godot_version": a.get("godot_version"),
			"version": a.get("version_string"), "rating": a.get("rating"), "updated": a.get("modify_date"),
			"page_url": "%s/%s" % [SITE, str(a.get("asset_id"))],
		})
	notes.append("Before installing, tell the user the title, author, license and support level, and ask them to confirm unless they already named this asset.")
	notes.append("Install with install_asset {asset_id}. Installing only copies files; it does not enable the plugin.")
	return _text_result({
		"query": query, "godot_version": version, "total_matches": data.get("total_items"),
		"page": data.get("page"), "pages": data.get("pages"), "results": rows, "notes": notes,
	})


func _install_asset(args: Dictionary) -> Dictionary:
	var id := str(args.get("asset_id", "")).strip_edges()
	if not id.is_valid_int() or id.begins_with("-") or id.begins_with("+"):
		return {"error": "asset_id must be the number from search_assets"}
	var info: Dictionary = await _get_json("%s/asset/%s" % [API, id])
	if info.has("error"):
		return {"error": info.error}
	var a: Dictionary = info.data
	var download_url := str(a.get("download_url", ""))
	if download_url == "":
		return {"error": "asset %s has no download link" % id}
	var host_name := _https_host(download_url)
	if host_name == "" or not host_name in ALLOWED_HOSTS:
		return {"error": "refusing to download from %s: only %s are allowed" % [host_name if host_name != "" else download_url, ", ".join(PackedStringArray(ALLOWED_HOSTS))]}
	var dl: Dictionary = await _http_get(download_url, 60.0, MAX_ZIP_BYTES)
	if dl.has("error"):
		return {"error": "download failed: %s" % dl.error}
	if dl.code != 200:
		return {"error": "download failed (%d) from %s" % [dl.code, host_name]}
	var bytes: PackedByteArray = dl.body
	if bytes.size() > MAX_ZIP_BYTES:
		return {"error": "the download is over the %d MB limit" % (MAX_ZIP_BYTES / 1000000)}
	var expected := str(a.get("download_hash", "")).to_lower()
	if expected != "":
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(bytes)
		if ctx.finish().hex_encode() != expected:
			return {"error": "the download does not match the library's checksum — refusing to install"}
	var zip_path := ProjectSettings.globalize_path("user://godot_live_mcp_asset_%s.zip" % id)
	var f := FileAccess.open(zip_path, FileAccess.WRITE)
	if f == null:
		return {"error": "could not write the download to %s" % zip_path}
	f.store_buffer(bytes)
	f.close()
	var out: Dictionary = await _bridge.execute_command("install_asset_zip", {
		"zip_path": zip_path, "name": a.get("title"),
		"include": str(args.get("include", "addons")), "overwrite": bool(args.get("overwrite", false)),
	})
	DirAccess.remove_absolute(zip_path)
	if not out.ok:
		return {"error": str(out.error)}
	var path_start := download_url.find("/", 8)
	var url_path := download_url.substr(path_start).get_slice("?", 0).get_slice("#", 0) if path_start != -1 else "/"
	var result := {
		"asset": {
			"asset_id": a.get("asset_id"), "title": a.get("title"), "author": a.get("author"),
			"license": a.get("cost"), "support_level": a.get("support_level"),
			"version": a.get("version_string"), "godot_version": a.get("godot_version"),
			"repo": a.get("browse_url"), "issues": a.get("issues_url"),
			"downloaded_from": host_name + url_path,
			"checksum_verified": expected != "",
			"size_mb": snappedf(bytes.size() / 1e6, 0.1),
		},
	}
	if out.result is Dictionary:
		result.merge(_sorted(out.result))  # Node relays the bridge's reply, whose keys are sorted
	result["next"] = "Installed but NOT enabled. Tell the user what was installed (title, author, license), and only when they agree enable the plugin in Project > Project Settings > Plugins."
	return _text_result(result)


## The host of an https URL, or "" if it is not a plain https URL. A userinfo
## part (https://github.com@evil.example/) is refused rather than parsed.
func _https_host(url: String) -> String:
	if not url.begins_with("https://"):
		return ""
	var authority := url.substr(8)
	for sep in ["/", "?", "#"]:
		var i := authority.find(sep)
		if i != -1:
			authority = authority.substr(0, i)
	if authority.contains("@") or authority.begins_with("["):
		return ""
	return authority.get_slice(":", 0).to_lower()
