@tool
class_name GodotLiveMCPBridge
extends Node

## Headless local socket bridge for the GodotLiveMCP MCP server.
##
## Protocol: newline-delimited JSON over TCP, localhost-only.
## Request:  {"id": <int>, "token": <string>, "command": <string>, "params": {...}}
## Response: {"id": <int>, "ok": <bool>, "result": <any>, "error": <string|null>}
##
## Variant values that aren't native JSON types (Vector2, Color, NodePath, ...)
## are carried as Godot's own var_to_str()/str_to_var() encoding, so callers
## must encode `value` params and decode `result` values that way.

const DEFAULT_PORT := 9080
const HOST := "127.0.0.1"

var _server: TCPServer
var _peers: Array = []
var _peer_buffers: Dictionary = {}
var _token: String = ""
var _port: int = DEFAULT_PORT
var _scene_root: Node = null

func _ready() -> void:
	_token = _load_or_create_token()
	_port = _load_port()
	_server = TCPServer.new()
	var err := _server.listen(_port, HOST)
	if err != OK:
		push_error("GodotLiveMCPBridge: failed to listen on %s:%d (err %d)" % [HOST, _port, err])
		return
	print("GodotLiveMCPBridge: listening on %s:%d" % [HOST, _port])
	set_process(true)

func set_scene_root(root: Node) -> void:
	_scene_root = root

func _get_scene_root() -> Node:
	if _scene_root and is_instance_valid(_scene_root):
		return _scene_root
	if Engine.is_editor_hint():
		var edited := EditorInterface.get_edited_scene_root()
		if edited:
			return edited
	return get_tree().root if is_inside_tree() else null

func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		peer.set_no_delay(true)
		_peers.append(peer)
		_peer_buffers[peer] = ""

	var dead: Array = []
	for peer in _peers:
		var stream: StreamPeerTCP = peer
		stream.poll()
		var status := stream.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(peer)
			continue
		var avail := stream.get_available_bytes()
		if avail > 0:
			var chunk := stream.get_utf8_string(avail)
			_peer_buffers[peer] += chunk
			_drain_lines(peer)

	for peer in dead:
		_peers.erase(peer)
		_peer_buffers.erase(peer)

func _drain_lines(peer: StreamPeerTCP) -> void:
	var buf: String = _peer_buffers[peer]
	while true:
		var nl := buf.find("\n")
		if nl == -1:
			break
		var line := buf.substr(0, nl)
		buf = buf.substr(nl + 1)
		if line.strip_edges() != "":
			_handle_line(peer, line)
	_peer_buffers[peer] = buf

func _handle_line(peer: StreamPeerTCP, line: String) -> void:
	var parsed = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_send(peer, {"id": null, "ok": false, "error": "invalid JSON request"})
		return

	var req: Dictionary = parsed
	var id = req.get("id", null)

	if String(req.get("token", "")) != _token:
		_send(peer, {"id": id, "ok": false, "error": "invalid token"})
		return

	var command := String(req.get("command", ""))
	var params: Dictionary = req.get("params", {})
	var result
	var error = null
	var ok := true

	if not has_method("_cmd_" + command):
		ok = false
		error = "unknown command: %s" % command
	else:
		var response = call("_cmd_" + command, params)
		if typeof(response) == TYPE_DICTIONARY and response.has("__error__"):
			ok = false
			error = response["__error__"]
		else:
			result = response

	_send(peer, {"id": id, "ok": ok, "result": result, "error": error})

func _send(peer: StreamPeerTCP, payload: Dictionary) -> void:
	var text := JSON.stringify(payload) + "\n"
	peer.put_data(text.to_utf8_buffer())

func _fail(msg: String) -> Dictionary:
	return {"__error__": msg}

func _resolve_node(node_path: String) -> Node:
	var root := _get_scene_root()
	if root == null:
		return null
	if node_path == "" or node_path == ".":
		return root
	return root.get_node_or_null(NodePath(node_path))

func _rel_path(node: Node) -> String:
	var root := _get_scene_root()
	if root == null or node == root:
		return "."
	return String(root.get_path_to(node))

# ---- Commands ----

func _cmd_ping(_params: Dictionary):
	return "pong"

func _cmd_eval_expression(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var expr_src := String(params.get("expression", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var expr := Expression.new()
	var parse_err := expr.parse(expr_src, [])
	if parse_err != OK:
		return _fail("parse error: %s" % expr.get_error_text())

	var value = expr.execute([], node, true)
	if expr.has_execute_failed():
		return _fail("execute error: %s" % expr.get_error_text())

	return {"value": var_to_str(value)}

func _cmd_list_scene_tree(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	return _describe_node(node)

func _describe_node(node: Node) -> Dictionary:
	var children := []
	for child in node.get_children():
		children.append(_describe_node(child))
	return {
		"name": node.name,
		"type": node.get_class(),
		"path": _rel_path(node),
		"children": children,
	}

func _cmd_get_node_properties(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var props := {}
	for prop in node.get_property_list():
		if prop.usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		var name: String = prop.name
		props[name] = var_to_str(node.get(name))
	return props

func _cmd_set_property(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var prop_name := String(params.get("property_name", ""))
	var value_str := String(params.get("value", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if prop_name == "":
		return _fail("property_name is required")

	var value = str_to_var(value_str)
	node.set(prop_name, value)
	return {"value": var_to_str(node.get(prop_name))}

func _cmd_set_transform(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is Node2D or node is Node3D):
		return _fail("node is not a Node2D or Node3D: %s" % node_path)

	if params.has("position"):
		node.position = str_to_var(String(params["position"]))
	if params.has("rotation"):
		node.rotation = float(str_to_var(String(params["rotation"])))
	if params.has("scale"):
		node.scale = str_to_var(String(params["scale"]))
	return {"ok": true}

func _cmd_attach_script(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var script_path := String(params.get("script_path", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not ResourceLoader.exists(script_path):
		return _fail("script not found: %s" % script_path)
	var script := load(script_path)
	node.set_script(script)
	return {"ok": true}

func _cmd_remove_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if node == _get_scene_root():
		return _fail("cannot remove the scene root")
	node.get_parent().remove_child(node)
	node.queue_free()
	return {"ok": true}

func _cmd_reparent_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var new_parent_path := String(params.get("new_parent_path", ""))
	var node := _resolve_node(node_path)
	var new_parent := _resolve_node(new_parent_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if new_parent == null:
		return _fail("new parent not found: %s" % new_parent_path)
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	return {"path": _rel_path(node)}

func _cmd_duplicate_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	var dup: Node = node.duplicate()
	node.get_parent().add_child(dup)
	return {"path": _rel_path(dup)}

func _cmd_get_project_setting(params: Dictionary):
	var key := String(params.get("key", ""))
	if not ProjectSettings.has_setting(key):
		return _fail("setting not found: %s" % key)
	return {"value": var_to_str(ProjectSettings.get_setting(key))}

func _cmd_set_project_setting(params: Dictionary):
	var key := String(params.get("key", ""))
	var value_str := String(params.get("value", ""))
	ProjectSettings.set_setting(key, str_to_var(value_str))
	return {"ok": true}

func _cmd_add_node_live(params: Dictionary):
	var parent_path := String(params.get("parent_path", "."))
	var node_type := String(params.get("node_type", ""))
	var node_name := String(params.get("node_name", ""))
	var parent := _resolve_node(parent_path)
	if parent == null:
		return _fail("parent not found: %s" % parent_path)
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type):
		return _fail("cannot instantiate node type: %s" % node_type)

	var new_node: Node = ClassDB.instantiate(node_type)
	if node_name != "":
		new_node.name = node_name
	parent.add_child(new_node)
	var root := _get_scene_root()
	if root:
		new_node.owner = root
	return {"path": _rel_path(new_node)}

func _cmd_rename_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var new_name := String(params.get("new_name", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if new_name == "":
		return _fail("new_name is required")
	node.name = new_name
	return {"path": _rel_path(node)}

func _cmd_connect_signal(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var signal_name := String(params.get("signal_name", ""))
	var target_node_path := String(params.get("target_node_path", ""))
	var method_name := String(params.get("method_name", ""))
	var node := _resolve_node(node_path)
	var target := _resolve_node(target_node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if target == null:
		return _fail("target node not found: %s" % target_node_path)
	if not node.has_signal(signal_name):
		return _fail("node has no signal: %s" % signal_name)
	if not target.has_method(method_name):
		return _fail("target node has no method: %s" % method_name)
	var callable := Callable(target, method_name)
	if node.is_connected(signal_name, callable):
		return _fail("already connected")
	var err := node.connect(signal_name, callable)
	if err != OK:
		return _fail("connect failed with error code %d" % err)
	return {"ok": true}

func _cmd_disconnect_signal(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var signal_name := String(params.get("signal_name", ""))
	var target_node_path := String(params.get("target_node_path", ""))
	var method_name := String(params.get("method_name", ""))
	var node := _resolve_node(node_path)
	var target := _resolve_node(target_node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if target == null:
		return _fail("target node not found: %s" % target_node_path)
	var callable := Callable(target, method_name)
	if not node.is_connected(signal_name, callable):
		return _fail("not connected")
	node.disconnect(signal_name, callable)
	return {"ok": true}

func _cmd_get_node_groups(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	var groups := []
	for g in node.get_groups():
		var g_str := String(g)
		if not g_str.begins_with("_"):
			groups.append(g_str)
	return {"groups": groups}

func _cmd_set_node_groups(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	var new_groups: Array = params.get("groups", [])
	for g in node.get_groups():
		var g_str := String(g)
		if not g_str.begins_with("_"):
			node.remove_from_group(g_str)
	for g in new_groups:
		node.add_to_group(String(g))
	return {"ok": true}

func _cmd_get_editor_selection(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("editor selection is only available inside the editor")
	var selection := EditorInterface.get_selection()
	var paths := []
	for node in selection.get_selected_nodes():
		paths.append(_rel_path(node))
	return {"selected": paths}

func _cmd_select_nodes(params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("editor selection is only available inside the editor")
	var node_paths: Array = params.get("node_paths", [])
	var nodes := []
	for p in node_paths:
		var node := _resolve_node(String(p))
		if node == null:
			return _fail("node not found: %s" % String(p))
		nodes.append(node)

	var selection := EditorInterface.get_selection()
	selection.clear()
	for node in nodes:
		selection.add_node(node)
	return {"ok": true}

func _cmd_clear_editor_selection(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("editor selection is only available inside the editor")
	EditorInterface.get_selection().clear()
	return {"ok": true}

# ---- Token / port setup ----

func _load_or_create_token() -> String:
	var override := OS.get_environment("GODOT_LIVE_MCP_TOKEN")
	if override != "":
		return override
	var path := "user://godot_live_mcp_token.txt"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var existing := f.get_as_text().strip_edges()
		if existing != "":
			return existing
	var generated := _generate_token()
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string(generated)
	print("GodotLiveMCPBridge: generated token, stored at %s" % ProjectSettings.globalize_path(path))
	return generated

func _generate_token() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var out := ""
	for i in range(32):
		out += chars[randi() % chars.length()]
	return out

func _load_port() -> int:
	var override := OS.get_environment("GODOT_LIVE_MCP_PORT")
	if override != "":
		return int(override)
	return DEFAULT_PORT
