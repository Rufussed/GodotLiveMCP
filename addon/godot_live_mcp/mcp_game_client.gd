@tool
extends RefCounted
## Client for the running game's bridge (runtime_bridge.gd, default port 9090):
## the same newline-delimited JSON protocol as the editor bridge, in a different
## process. The game and the editor share one token (same project, same
## user:// token file, or the GODOT_LIVE_MCP_TOKEN both inherit).

const DEFAULT_PORT := 9090

var _host: Node
var _token_getter: Callable


func setup(host: Node, token_getter: Callable) -> void:
	_host = host
	_token_getter = token_getter


## One request; waits across frames, never blocks the editor. Returns {ok, result, error}.
func call_command(command: String, params: Dictionary, timeout_ms: int = 5000) -> Dictionary:
	var port := int(OS.get_environment("GODOT_LIVE_MCP_RUNTIME_PORT")) if OS.get_environment("GODOT_LIVE_MCP_RUNTIME_PORT") != "" else DEFAULT_PORT
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return _no_game(port)
	var started := Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - started < 2000:
		peer.poll()
		await _host.get_tree().process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
		return _no_game(port)
	var request := JSON.stringify({"id": 1, "token": _token_getter.call(), "command": command, "params": params}) + "\n"
	peer.put_data(request.to_utf8_buffer())
	var received := PackedByteArray()
	while Time.get_ticks_msec() - started < timeout_ms:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var n := peer.get_available_bytes()
		if n > 0:
			received.append_array(peer.get_data(n)[1])
			var newline := received.find(10)
			if newline != -1:
				peer.disconnect_from_host()
				return _parse(received.slice(0, newline).get_string_from_utf8())
		await _host.get_tree().process_frame
	peer.disconnect_from_host()
	return {"ok": false, "result": null, "error": "No reply to \"%s\" from the running game within %ds. The game may be busy or paused; the command may still complete, so check before repeating it." % [command, timeout_ms / 1000]}


func _parse(line: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(line) != OK or not (json.data is Dictionary):
		return {"ok": false, "result": null, "error": "the running game sent a reply that is not valid JSON"}
	var reply: Dictionary = json.data
	return {"ok": bool(reply.get("ok", false)), "result": reply.get("result"), "error": reply.get("error")}


func _no_game(port: int) -> Dictionary:
	return {"ok": false, "result": null, "error": "Cannot reach a running game on port %d. Start the game with play_scene, and make sure runtime_bridge.gd is an Autoload in Project Settings." % port}
