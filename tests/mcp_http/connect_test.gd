extends SceneTree
## connect_clients.gd against a throwaway HOME. Nothing outside the temp folder
## is read or written.
##   godot --headless --path tests/mcp_http --script res://connect_test.gd

const Clients = preload("res://addons/godot_live_mcp/connect_clients.gd")
const URL := "http://127.0.0.1:41069/mcp"
const TOKEN := "tok-0123456789abcdef0123456789"
var failures := 0
var checks := 0
var tmp := ""


func _initialize() -> void:
	tmp = ProjectSettings.globalize_path("user://connect_test_%d" % Time.get_ticks_usec())
	var home := tmp.path_join("home")
	var project := tmp.path_join("project")
	DirAccess.make_dir_recursive_absolute(home)
	DirAccess.make_dir_recursive_absolute(project)
	OS.set_environment("HOME", home)
	OS.set_environment("CODEX_HOME", "")
	OS.set_environment("XDG_CONFIG_HOME", "")
	var c = Clients.new()

	eq(c.user_server_name("My Cool Game!"), "godot-my-cool-game", "server name from project name")
	eq(c.user_server_name("!!!"), "godot-project", "server name for a name with no letters")
	eq(c.user_server_name("a".repeat(60)), "godot-" + "a".repeat(30), "server name is capped")

	# Fresh files
	for client in c.FILE_CLIENTS:
		var r: Dictionary = c.configure(client, URL, TOKEN, project, "Demo")
		eq(r.ok and r.changed, true, "%s: writes a new file" % client)
		eq(FileAccess.file_exists(r.path), true, "%s: file exists at %s" % [client, r.path.trim_prefix(tmp)])
	var vs: Dictionary = _json(project.path_join(".vscode/mcp.json"))
	eq(vs.servers["godot-live-mcp"].headers.Authorization, "Bearer ${input:godot-token}", "vscode: token is an input reference, not the secret")
	eq(FileAccess.get_file_as_string(project.path_join(".vscode/mcp.json")).contains(TOKEN), false, "vscode: the project file never contains the token")
	eq(vs.inputs[0].password, true, "vscode: the token prompt is a password field")
	eq(_json(home.path_join(".cursor/mcp.json")).mcpServers["godot-demo"].url, URL, "cursor: url")
	eq(_json(project.path_join(".gemini/settings.json")).mcpServers["godot-live-mcp"].httpUrl, URL, "gemini: httpUrl")
	eq(_json(home.path_join(".config/opencode/opencode.json")).mcp["godot-demo"].type, "remote", "opencode: remote server")
	var toml := FileAccess.get_file_as_string(home.path_join(".codex/config.toml"))
	eq(toml, "[mcp_servers.godot-demo]\nurl = \"%s\"\n\n[mcp_servers.godot-demo.http_headers]\nAuthorization = \"Bearer %s\"\n" % [URL, TOKEN], "codex: TOML text")

	# Permissions: files that hold the token are owner-only (POSIX)
	if OS.get_name() != "Windows":
		for p in [home.path_join(".cursor/mcp.json"), home.path_join(".codex/config.toml"), home.path_join(".config/opencode/opencode.json")]:
			eq(_mode(p), "600", "owner-only: %s" % p.trim_prefix(tmp))

	# Idempotent
	for client in c.FILE_CLIENTS:
		var again: Dictionary = c.configure(client, URL, TOKEN, project, "Demo")
		eq(again.code, "unchanged", "%s: writing the same entry again changes nothing" % client)
	eq(FileAccess.file_exists(home.path_join(".cursor/mcp.json.bak")), false, "no .bak when there was nothing to back up")

	# Existing content is kept
	var cursor_path := home.path_join(".cursor/mcp.json")
	_write(cursor_path, '{"mcpServers": {"other": {"command": "x", "timeout": 30000}}, "theme": "dark"}')
	var r2: Dictionary = c.configure("cursor", URL, TOKEN, project, "Demo")
	var cur: Dictionary = _json(cursor_path)
	eq(r2.ok, true, "cursor: merges into an existing file")
	eq(cur.mcpServers.other.command, "x", "cursor: other servers are kept")
	eq(cur.theme, "dark", "cursor: other settings are kept")
	eq(FileAccess.get_file_as_string(cursor_path).contains("30000.0"), false, "cursor: whole numbers stay integers")
	eq(FileAccess.get_file_as_string(cursor_path + ".bak"), '{"mcpServers": {"other": {"command": "x", "timeout": 30000}}, "theme": "dark"}', "cursor: .bak holds the original")
	c.configure("cursor", "http://127.0.0.1:50000/mcp", TOKEN, project, "Demo")
	eq(_json(cursor_path).mcpServers["godot-demo"].url, "http://127.0.0.1:50000/mcp", "cursor: a changed URL replaces our entry")
	eq(FileAccess.get_file_as_string(cursor_path + ".bak").contains("godot-demo"), false, "cursor: .bak keeps the first original, not a later state")

	# Invalid JSON is never touched
	for bad in ['{"mcpServers": {', '// comment\n{"mcpServers": {}}', '[1, 2]']:
		_write(cursor_path, bad)
		var refused: Dictionary = c.configure("cursor", URL, TOKEN, project, "Demo")
		eq(refused.ok == false and refused.code == "config_json_invalid" and FileAccess.get_file_as_string(cursor_path) == bad, true, "cursor: refuses and leaves %s alone" % bad.left(20).replace("\n", " "))

	# vscode keeps existing inputs and servers, and does not duplicate its own input
	var vs_path := project.path_join(".vscode/mcp.json")
	_write(vs_path, '{"inputs": [{"type": "promptString", "id": "other"}], "servers": {"x": {"type": "http", "url": "http://x"}}}')
	c.configure("vscode", URL, TOKEN, project, "Demo")
	c.configure("vscode", URL, TOKEN, project, "Demo")
	var vs2: Dictionary = _json(vs_path)
	eq(vs2.inputs.size(), 2, "vscode: keeps the user's input and adds ours once")
	eq(vs2.servers.has("x") and vs2.servers.has("godot-live-mcp"), true, "vscode: keeps the user's server")

	# TOML: other tables kept, ours replaced including nested tables, nothing duplicated
	var toml_path := home.path_join(".codex/config.toml")
	_write(toml_path, 'model = "o3"\n\n[mcp_servers.other]\ncommand = "x"\n\n[mcp_servers.godot-demo]\nurl = "old"\n\n[mcp_servers.godot-demo.http_headers]\nAuthorization = "Bearer old"\n\n[mcp_servers.godot-demo2]\nurl = "keep"\n\n[tui]\ntheme = "x"\n')
	c.configure("codex", URL, TOKEN, project, "Demo")
	var t2 := FileAccess.get_file_as_string(toml_path)
	eq(t2.count("[mcp_servers.godot-demo]"), 1, "codex: our table appears once")
	eq(t2.contains("Bearer old") or t2.contains('url = "old"'), false, "codex: the old entry is gone")
	eq(t2.contains('[mcp_servers.godot-demo2]\nurl = "keep"') and t2.contains("[mcp_servers.other]") and t2.contains('model = "o3"') and t2.contains('[tui]\ntheme = "x"'), true, "codex: other tables, including a longer name sharing our prefix, are kept")
	eq(c.configure("codex", URL, TOKEN, project, "Demo").code, "unchanged", "codex: second run is a no-op")

	# Snippets and the Claude command
	eq(c.snippet("cursor", URL, TOKEN, project, "Demo", true).contains(TOKEN), false, "snippet with mask_token hides the token")
	eq(c.snippet("cursor", URL, TOKEN, project, "Demo").contains(TOKEN), true, "snippet without mask shows it")
	eq(c.claude_add_args(URL, TOKEN), ["mcp", "add", "-s", "local", "--transport", "http", "godot-live-mcp", URL, "-H", "Authorization: Bearer " + TOKEN], "claude mcp add arguments")

	OS.move_to_trash(tmp)
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _mode(path: String) -> String:
	var out: Array = []
	OS.execute("stat", ["-c", "%a", path], out)
	return "".join(out).strip_edges()


func eq(got, want, label: String) -> void:
	checks += 1
	if got != want:
		failures += 1
		print("FAIL  %s\n      got    %s\n      wanted %s" % [label, str(got), str(want)])
	else:
		print("ok    " + label)
