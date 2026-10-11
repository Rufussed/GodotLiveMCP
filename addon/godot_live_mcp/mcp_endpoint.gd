@tool
extends Node
## Runs the in-editor MCP endpoint (HTTP mode): owns the server and the core,
## picks and remembers the port, and polls once per frame.
##
## Settings live in user://godot_live_mcp_http.cfg ([http] enabled, port,
## profile), per project. The bearer token is the bridge's own token. Overrides:
## GODOT_LIVE_MCP_HTTP_PORT, GODOT_LIVE_MCP_PROFILE (lite|full),
## GODOT_LIVE_MCP_HTTP=off.

const Server = preload("res://addons/godot_live_mcp/mcp_http_server.gd")
const Core = preload("res://addons/godot_live_mcp/mcp_core.gd")

const CONFIG_PATH := "user://godot_live_mcp_http.cfg"
const PORT_RANGE_START := 41000
const PORT_RANGE_SIZE := 2000

var _server
var _core
var _port := 0
var _attached := false
var _token := ""


func start(bridge: Node) -> void:
	# The bridge makes its token in _ready, which runs after the plugin's _enter_tree.
	if not bridge.is_node_ready():
		await bridge.ready
	_token = bridge.get_token()
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var enabled := OS.get_environment("GODOT_LIVE_MCP_HTTP").to_lower() != "off" and bool(cfg.get_value("http", "enabled", true))
	if not enabled:
		return
	var profile := OS.get_environment("GODOT_LIVE_MCP_PROFILE").to_lower()
	if profile == "":
		profile = str(cfg.get_value("http", "profile", "lite"))
	_core = Core.new()
	_core.setup(bridge, profile, _plugin_version())
	if _core.load_error != "":
		push_error("GodotLiveMCP: MCP endpoint disabled: %s" % _core.load_error)
		return
	var wanted := int(OS.get_environment("GODOT_LIVE_MCP_HTTP_PORT")) if OS.get_environment("GODOT_LIVE_MCP_HTTP_PORT") != "" else int(cfg.get_value("http", "port", 0))
	_server = Server.new()
	var port := _choose_port(wanted)
	if port == -1:
		_attached = true  # another editor already serves this project
		_server = null
		_port = wanted
		print("GodotLiveMCP: MCP endpoint already served by another editor on http://127.0.0.1:%d/mcp" % wanted)
		return
	var err: int = _server.start(port, _token, Callable(_core, "handle"), _plugin_version())
	if err != OK:
		push_error("GodotLiveMCP: MCP endpoint could not start on port %d (error %d%s)" % [
			port, err, "; the token is too short" if err == ERR_UNCONFIGURED else ""])
		_server = null
		return
	_port = port
	if port != wanted:
		cfg.set_value("http", "port", port)
		cfg.save(CONFIG_PATH)
	print("GodotLiveMCP: MCP endpoint on http://127.0.0.1:%d/mcp (%s tool group)" % [port, _core.get_profile()])
	set_process(true)


func stop() -> void:
	set_process(false)
	if _server:
		_server.stop()
		_server = null


func get_port() -> int:
	return _port


func is_serving() -> bool:
	return _server != null and _server.is_listening()


func _process(_delta: float) -> void:
	if _server:
		_server.poll()


## The saved port if it is free or already ours; otherwise the first free port
## from a start point derived from the project's path (stable per project, so
## two projects rarely collide). Returns -1 to mean "attach to the editor that
## already serves this project".
func _choose_port(wanted: int) -> int:
	var identity := _project_identity()
	var start := wanted if wanted > 0 else PORT_RANGE_START + (identity.hash() & 0x7fffffff) % PORT_RANGE_SIZE
	for i in 50:
		var candidate := start + i
		if candidate > 65535:
			break
		if _is_free(candidate):
			return candidate
		if _probe_is_ours(candidate, identity):
			return -1
		if wanted > 0 and i == 0:
			start = PORT_RANGE_START + (identity.hash() & 0x7fffffff) % PORT_RANGE_SIZE  # saved port is taken by something else
			return _choose_port(0)
	return 0


func _is_free(port: int) -> bool:
	var probe := TCPServer.new()
	if probe.listen(port, "127.0.0.1") != OK:
		return false
	probe.stop()
	return true


func _project_identity() -> String:
	return ProjectSettings.globalize_path("res://").sha256_text().substr(0, 16)


## Asks whatever listens on `port` who it is. Authenticated, so only an editor
## holding this project's token reports the project identity.
func _probe_is_ours(port: int, identity: String) -> bool:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return false
	var deadline := Time.get_ticks_msec() + 300
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		peer.poll()
		OS.delay_msec(2)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	peer.put_data(("GET /health HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n" % [port, _token]).to_utf8_buffer())
	var text := ""
	deadline = Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var n := peer.get_available_bytes()
		if n > 0:
			text += peer.get_utf8_string(n)
			if text.contains("}"):
				break
		OS.delay_msec(2)
	peer.disconnect_from_host()
	return text.contains("\"project_identity\":\"%s\"" % identity)


func _plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/godot_live_mcp/plugin.cfg") == OK:
		return str(cfg.get_value("plugin", "version", "0"))
	return "0"
