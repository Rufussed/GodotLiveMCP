extends SceneTree
## Writes every client's config with connect_clients.gd, for
## tests/connect_cli_check.sh. HOME (and CODEX_HOME) come from the environment.
##   godot --headless --path tests/mcp_http --script res://write_configs.gd -- <url> <token> <project dir> <project name>

const Clients = preload("res://addons/godot_live_mcp/connect_clients.gd")


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	# This writes real config files at HOME. Refuse anything but a temporary folder,
	# and make sure no other variable can redirect a client's path to the real one.
	var home := OS.get_environment("HOME")
	if not (home.begins_with("/tmp/") or home.begins_with(OS.get_environment("TMPDIR") + "/") and OS.get_environment("TMPDIR") != ""):
		push_error("write_configs.gd: HOME (%s) is not a temporary folder; refusing to write." % home)
		quit(2)
		return
	OS.set_environment("XDG_CONFIG_HOME", "")
	OS.set_environment("CODEX_HOME", "")
	var c = Clients.new()
	var bad := 0
	for client in c.FILE_CLIENTS:
		var r: Dictionary = c.configure(client, a[0], a[1], a[2], a[3])
		print("%s: %s" % [client, r.message])
		if not r.ok:
			bad += 1
	# Claude Code is registered by its own CLI; the shell script runs it with these arguments.
	for arg in c.claude_add_args(a[0], a[1]):
		print("CLAUDE_ARG:" + arg)
	quit(bad)
