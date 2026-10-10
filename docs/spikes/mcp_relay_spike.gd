extends SceneTree
## Spike: a stdio MCP server run by Godot itself (--headless --script). Reads
## newline-delimited JSON-RPC on stdin, answers on stdout, relays tool calls
## to the editor's bridge over local TCP. Nothing but JSON may reach stdout.

var _lines: Array = []
var _mutex := Mutex.new()
var _thread := Thread.new()
var _eof := false
var _port := 9080
var _token := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2:
		_port = int(args[0])
		_token = str(args[1])
	_thread.start(_read_stdin)

func _read_stdin() -> void:
	while true:
		var line := OS.read_string_from_stdin()
		if line == "":
			_mutex.lock()
			_eof = true
			_mutex.unlock()
			return
		_mutex.lock()
		_lines.append(line.strip_edges())
		_mutex.unlock()

func _process(_delta: float) -> bool:
	_mutex.lock()
	var batch := _lines.duplicate()
	_lines.clear()
	var done := _eof
	_mutex.unlock()
	for l in batch:
		if str(l) != "":
			_handle(str(l))
	if done and batch.is_empty():
		_thread.wait_to_finish()
		quit()
	return false

func _send(msg: Dictionary) -> void:
	# JSON parsing makes every number a float; ids must go back out as integers.
	if msg.get("id") is float and float(msg.id) == floorf(float(msg.id)):
		msg["id"] = int(msg.id)
	print(JSON.stringify(msg))

func _handle(line: String) -> void:
	var req = JSON.parse_string(line)
	if typeof(req) != TYPE_DICTIONARY:
		return
	var id = req.get("id", null)
	match str(req.get("method", "")):
		"initialize":
			_send({"jsonrpc": "2.0", "id": id, "result": {
				"protocolVersion": str(req.get("params", {}).get("protocolVersion", "2024-11-05")),
				"capabilities": {"tools": {}},
				"serverInfo": {"name": "godot-live-mcp-relay-spike", "version": "0"}}})
		"tools/list":
			_send({"jsonrpc": "2.0", "id": id, "result": {"tools": [{
				"name": "list_scene_tree", "description": "Scene tree of the open scene",
				"inputSchema": {"type": "object", "properties": {}}}]}})
		"tools/call":
			var p: Dictionary = req.get("params", {})
			var reply := _call_bridge(str(p.get("name", "")), p.get("arguments", {}))
			if reply.has("error"):
				_send({"jsonrpc": "2.0", "id": id, "result": {"isError": true, "content": [{"type": "text", "text": str(reply.error)}]}})
			else:
				_send({"jsonrpc": "2.0", "id": id, "result": {"content": [{"type": "text", "text": JSON.stringify(reply.result)}]}})
		"ping":
			_send({"jsonrpc": "2.0", "id": id, "result": {}})
		_:
			if id != null:
				_send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "unknown method"}})

## One request to the editor's bridge (blocking is fine for a relay).
func _call_bridge(command: String, params: Dictionary) -> Dictionary:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", _port) != OK:
		return {"error": "cannot connect to the editor"}
	var t0 := Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 2000:
		peer.poll()
		OS.delay_msec(2)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return {"error": "the editor is not running (no bridge on port %d)" % _port}
	peer.put_data((JSON.stringify({"id": 1, "token": _token, "command": command, "params": params}) + "\n").to_utf8_buffer())
	var buf := ""
	while Time.get_ticks_msec() - t0 < 8000:
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			buf += peer.get_utf8_string(n)
			if buf.contains("\n"):
				break
		OS.delay_msec(2)
	peer.disconnect_from_host()
	var parsed = JSON.parse_string(buf.get_slice("\n", 0))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"error": "no reply from the editor"}
	return {"error": parsed.get("error")} if not parsed.get("ok", false) else {"result": parsed.get("result")}
