@tool
extends RefCounted
## Writes the in-editor MCP endpoint into an AI app's config file. No UI and no
## editor access, so it can be tested headless (tests/mcp_http/connect_test.gd).
##
## Rules, all deliberate: a file that is not valid JSON is never touched; the
## first write to a file leaves a .bak copy of what was there; other servers in
## the file are kept; writing the same entry again changes nothing; a file that
## holds a token gets owner-only permissions where the OS allows it.
##
## The JSON and TOML merge approach is adapted from FunplayAI/funplay-godot-mcp
## (MIT, Copyright (c) 2026 FunplayAI); see THIRD_PARTY_NOTICES.

## Clients written as a file. Claude Code is registered with its own CLI instead
## (claude_add_args), so its token lands in ~/.claude.json, not in a file here.
const FILE_CLIENTS := ["vscode", "cursor", "codex", "gemini", "opencode"]
## Server name for entries scoped to one project folder.
const PROJECT_SERVER_NAME := "godot-live-mcp"
const VSCODE_INPUT_ID := "godot-token"
## Unix mode rw------- (octal 600), for files that hold the token.
const OWNER_ONLY := 0x180

const _JSON_ROOT_KEY := {"vscode": "servers", "cursor": "mcpServers", "gemini": "mcpServers", "opencode": "mcp"}


## "godot-<project>" for entries in a user-level file shared by all projects.
func user_server_name(project_name: String) -> String:
	var slug := ""
	for c in project_name.to_lower():
		slug += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "-"
	while slug.contains("--"):
		slug = slug.replace("--", "-")
	slug = slug.trim_prefix("-").trim_suffix("-").left(30).trim_suffix("-")
	return "godot-" + (slug if slug != "" else "project")


## {path, user_level, name, format} for a file client. user_level means the file
## is outside the project and holds the token itself.
func target(client: String, project_dir: String, project_name: String) -> Dictionary:
	var home := home_path()
	match client:
		"vscode":
			return {"path": project_dir.path_join(".vscode/mcp.json"), "user_level": false, "name": PROJECT_SERVER_NAME, "format": "json"}
		"gemini":
			return {"path": project_dir.path_join(".gemini/settings.json"), "user_level": false, "name": PROJECT_SERVER_NAME, "format": "json"}
		"cursor":
			return {"path": home.path_join(".cursor/mcp.json"), "user_level": true, "name": user_server_name(project_name), "format": "json"}
		"opencode":
			var cfg_home := OS.get_environment("XDG_CONFIG_HOME")
			if cfg_home == "":
				cfg_home = home.path_join(".config")
			return {"path": cfg_home.path_join("opencode/opencode.json"), "user_level": true, "name": user_server_name(project_name), "format": "json"}
		"codex":
			var codex_home := OS.get_environment("CODEX_HOME")
			if codex_home == "":
				codex_home = home.path_join(".codex")
			return {"path": codex_home.path_join("config.toml"), "user_level": true, "name": user_server_name(project_name), "format": "toml"}
	return {}


## The text that goes in the file for this client (for the confirm dialog and
## "Copy config"). With mask_token the secret is replaced by a placeholder.
func snippet(client: String, url: String, token: String, project_dir: String, project_name: String, mask_token: bool = false) -> String:
	var t := target(client, project_dir, project_name)
	if t.is_empty():
		return ""
	var shown := "<token>" if mask_token else token
	if t.format == "toml":
		return _toml_section(t.name, url, shown)
	var root := {}
	root[_JSON_ROOT_KEY[client]] = {t.name: _json_entry(client, url, shown)}
	if client == "vscode":
		root["inputs"] = [_vscode_input()]
	return JSON.stringify(root, "\t", false)


## Arguments for `claude`, to be run with the project folder as the working
## directory. Local scope: stored against this project in ~/.claude.json.
func claude_add_args(url: String, token: String) -> Array:
	return ["mcp", "add", "-s", "local", "--transport", "http", PROJECT_SERVER_NAME, url, "-H", "Authorization: Bearer " + token]


## Writes (or updates) the entry. Returns {ok, code, path, message, changed}.
func configure(client: String, url: String, token: String, project_dir: String, project_name: String) -> Dictionary:
	var t := target(client, project_dir, project_name)
	if t.is_empty():
		return _fail("unknown_client", "", "Unknown client: %s" % client)
	var path: String = t.path
	var old := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var text: String
	if t.format == "toml":
		text = _merge_toml(old, t.name, _toml_section(t.name, url, token))
	else:
		var merged := _merge_json(old, client, t.name, _json_entry(client, url, token))
		if merged.has("error"):
			return _fail("config_json_invalid", path, "%s is not plain JSON (comments are not supported), so it was left alone. Use Copy config and add the entry by hand. (%s)" % [path, merged.error])
		text = merged.text
	if text == old:
		return {"ok": true, "code": "unchanged", "path": path, "changed": false, "message": "%s already has this entry." % path}
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK:
		return _fail("config_directory_failed", path, "Could not create %s (error %d)." % [path.get_base_dir(), err])
	if old != "" and not FileAccess.file_exists(path + ".bak"):
		var bak := FileAccess.open(path + ".bak", FileAccess.WRITE)
		if bak == null:
			return _fail("config_backup_failed", path, "Could not write a backup next to %s, so it was not changed." % path)
		bak.store_string(old)
		bak.close()
		if t.user_level:
			FileAccess.set_unix_permissions(path + ".bak", OWNER_ONLY)
	# Write beside the file, then rename over it: a crash never leaves half a config.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return _fail("config_write_failed", path, "Could not write %s." % path)
	f.store_string(text)
	f.close()
	if t.user_level:
		FileAccess.set_unix_permissions(tmp, OWNER_ONLY)
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return _fail("config_write_failed", path, "Could not replace %s." % path)
	return {"ok": true, "code": "config_written", "path": path, "changed": true, "message": "Wrote %s." % path}


# ---- JSON ------------------------------------------------------------------

func _json_entry(client: String, url: String, token: String) -> Dictionary:
	match client:
		"vscode":
			return {"type": "http", "url": url, "headers": {"Authorization": "Bearer ${input:%s}" % VSCODE_INPUT_ID}}
		"gemini":
			return {"httpUrl": url, "headers": {"Authorization": "Bearer " + token}}
		"opencode":
			return {"type": "remote", "url": url, "headers": {"Authorization": "Bearer " + token}, "enabled": true}
	return {"url": url, "headers": {"Authorization": "Bearer " + token}}  # cursor


func _vscode_input() -> Dictionary:
	return {"type": "promptString", "id": VSCODE_INPUT_ID, "description": "Godot MCP token (in Godot: AI Assistant panel > More… > Copy config… > Copy token)", "password": true}


func _merge_json(old: String, client: String, name: String, entry: Dictionary) -> Dictionary:
	var root := {}
	if old.strip_edges() != "":
		var json := JSON.new()
		if json.parse(old) != OK:
			return {"error": "line %d: %s" % [json.get_error_line(), json.get_error_message()]}
		if not (json.data is Dictionary):
			return {"error": "the top level is not an object"}
		root = _ints(json.data)
	var key: String = _JSON_ROOT_KEY[client]
	var servers: Variant = root.get(key, {})
	if not (servers is Dictionary):
		servers = {}
	servers[name] = entry
	root[key] = servers
	if client == "vscode":
		var inputs: Variant = root.get("inputs", [])
		if not (inputs is Array):
			inputs = []
		var has_input := false
		for i in inputs:
			if i is Dictionary and i.get("id") == VSCODE_INPUT_ID:
				has_input = true
		if not has_input:
			inputs.append(_vscode_input())
		root["inputs"] = inputs
	return {"text": JSON.stringify(root, "\t", false) + "\n"}


## JSON parsing turns every number into a float; put whole ones back so a user's
## own settings (a timeout of 30000) don't come back as 30000.0.
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


# ---- TOML ------------------------------------------------------------------

func _toml_section(name: String, url: String, token: String) -> String:
	return "[mcp_servers.%s]\nurl = %s\n\n[mcp_servers.%s.http_headers]\nAuthorization = %s\n" % [
		name, _toml_quote(url), name, _toml_quote("Bearer " + token)]


func _toml_quote(value: String) -> String:
	return "\"%s\"" % value.replace("\\", "\\\\").replace("\"", "\\\"")


## Replaces our server's tables (the table and any nested ones) and leaves the
## rest of the file as it was. A table header is a line starting with "[".
func _merge_toml(old: String, name: String, section: String) -> String:
	var own := "[mcp_servers.%s]" % name
	var own_prefix := "[mcp_servers.%s." % name
	var kept: Array = []
	var skipping := false
	for line in old.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("["):
			skipping = trimmed == own or trimmed.begins_with(own_prefix)
		if not skipping:
			kept.append(line)
	var rest := "\n".join(PackedStringArray(kept)).strip_edges(false, true)
	return section if rest == "" else rest + "\n\n" + section


# ---- helpers ---------------------------------------------------------------

func home_path() -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "":
		return home.simplify_path()
	return OS.get_user_data_dir().get_base_dir()


func _fail(code: String, path: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "path": path, "changed": false, "message": message}
