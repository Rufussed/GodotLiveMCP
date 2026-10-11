@tool
extends RefCounted
## The MCP dispatcher inside the editor: initialize, ping, tools/list and
## tools/call over the tool list in tools.json. Transport-agnostic (HTTP mode
## now, the stdio relay later): handle(request, reply) takes a parsed JSON-RPC
## message and calls reply with the JSON-RPC response, or null for none.
##
## Tools are served from tools.json ("x_godot" metadata, see
## server/scripts/export-tools.js). Phase 1 serves the generic editor tools,
## which pass their arguments straight to the bridge command of the same name.
## Adapters, the running-game tools and Node-only tools are not served yet and
## are left out of tools/list.

const SUPPORTED_PROTOCOL_VERSIONS := ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
const TOOLS_PATH := "res://addons/godot_live_mcp/tools.json"

var _bridge: Node
var _version := "0"
var _profile := "lite"
var _tools: Dictionary = {}   # name -> tool entry, only the ones this core serves
var _order: Array = []
var load_error := ""


func setup(bridge: Node, profile: String, version: String) -> void:
	_bridge = bridge
	_profile = "full" if profile == "full" else "lite"
	_version = version
	_load_tools()


func set_profile(profile: String) -> void:
	_profile = "full" if profile == "full" else "lite"


func get_profile() -> String:
	return _profile


func tool_count() -> int:
	return _tools.size()


func _load_tools() -> void:
	_tools.clear()
	_order.clear()
	load_error = ""
	if not FileAccess.file_exists(TOOLS_PATH):
		load_error = "missing %s" % TOOLS_PATH
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(TOOLS_PATH)) != OK or not (json.data is Dictionary):
		load_error = "%s is not valid JSON" % TOOLS_PATH
		return
	for entry in json.data.get("tools", []):
		if _serves(entry):
			_tools[entry.name] = entry
			_order.append(entry.name)


## What this core can run. Grows as adapters are ported (docs/phase0_inventory.md).
func _serves(entry: Dictionary) -> bool:
	var x: Dictionary = entry.get("x_godot", {})
	return x.get("route") == "generic" and x.get("target", "editor") == "editor"


func _in_profile(entry: Dictionary) -> bool:
	return _profile == "full" or entry.get("x_godot", {}).get("group") == "lite"


func handle(request: Dictionary, reply: Callable) -> void:
	var id: Variant = request.get("id")
	var is_notification := not request.has("id")
	if str(request.get("jsonrpc", "")) != "2.0" or typeof(request.get("method")) != TYPE_STRING:
		reply.call(null if is_notification else _error(id, -32600, "Invalid Request"))
		return
	var params: Variant = request.get("params", {})
	if not (params is Dictionary):
		params = {}
	var method: String = request.method
	if is_notification:
		reply.call(null)  # notifications/initialized, notifications/cancelled, ...
		return
	match method:
		"initialize":
			reply.call(_initialize(id, params))
		"ping":
			reply.call(_result(id, {}))
		"tools/list":
			reply.call(_result(id, {"tools": _list_tools()}))
		"tools/call":
			_call_tool(id, params, reply)
		_:
			reply.call(_error(id, -32601, "Method not found: %s" % method))


func _initialize(id: Variant, params: Dictionary) -> Dictionary:
	var asked := str(params.get("protocolVersion", ""))
	return _result(id, {
		"protocolVersion": asked if asked in SUPPORTED_PROTOCOL_VERSIONS else SUPPORTED_PROTOCOL_VERSIONS[0],
		"capabilities": {"tools": {"listChanged": false}},
		"serverInfo": {"name": "godot-live-mcp", "version": _version},
	})


func _list_tools() -> Array:
	var out: Array = []
	for name in _order:
		var entry: Dictionary = _tools[name]
		if _in_profile(entry):
			out.append({"name": entry.name, "description": entry.description, "inputSchema": entry.inputSchema})
	return out


func _call_tool(id: Variant, params: Dictionary, reply: Callable) -> void:
	var name := str(params.get("name", ""))
	if name == "":
		reply.call(_error(id, -32602, "Invalid params: 'name' is required"))
		return
	if not _tools.has(name):
		reply.call(_error(id, -32602, "Unknown tool: %s" % name))
		return
	var entry: Dictionary = _tools[name]
	if not _in_profile(entry):
		reply.call(_result(id, _tool_error(
			"The tool %s is not in the Lite tool group. Switch the tool group to Full in the AI Assistant panel, or start the editor with GODOT_LIVE_MCP_PROFILE=full." % name)))
		return
	var args: Variant = params.get("arguments", {})
	if args == null:
		args = {}
	if not (args is Dictionary):
		reply.call(_error(id, -32602, "Invalid params: 'arguments' must be an object"))
		return
	# A wrong parameter name must fail loudly: the bridge would otherwise default
	# the field it expected and quietly act on the wrong node (see validateArgs.ts).
	var allowed: Dictionary = entry.inputSchema.get("properties", {})
	var unknown: Array = []
	for key in args:
		if not allowed.has(key):
			unknown.append(str(key))
	if not unknown.is_empty():
		var expected := ", ".join(PackedStringArray(allowed.keys().map(func(k): return str(k)))) if not allowed.is_empty() else "(no parameters)"
		reply.call(_result(id, _tool_error("unknown parameter(s) for \"%s\": %s — expected one of: %s" % [name, ", ".join(PackedStringArray(unknown)), expected])))
		return
	var command: String = entry.x_godot.get("command", name)
	var out: Dictionary = await _bridge.execute_command(command, args)
	if out.ok:
		reply.call(_result(id, {"content": [{"type": "text", "text": _text(out.result)}]}))
	else:
		reply.call(_result(id, _tool_error(str(out.error))))


## Same text the Node server produces: strings as they are, anything else as JSON.
func _text(value: Variant) -> String:
	return value if value is String else JSON.stringify(value, "  ")


func _tool_error(message: String) -> Dictionary:
	return {"content": [{"type": "text", "text": message}], "isError": true}


func _result(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
