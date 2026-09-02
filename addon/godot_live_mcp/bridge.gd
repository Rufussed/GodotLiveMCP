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

## The addons/<name>/plugin.cfg folder name — what EditorInterface.set_plugin_enabled()
## expects, not plugin.cfg's display "name" field. Used by _cmd_reload_plugin.
const PLUGIN_ADDON_NAME := "godot_live_mcp"

## Global singletons exposed by name to eval_expression, in the same order
## as the values built alongside them (see _cmd_eval_expression). Without
## this, Expression has no way to resolve "ProjectSettings", "ClassDB", etc.
const _SINGLETON_NAMES := ["ProjectSettings", "ClassDB", "Engine", "Input", "OS", "Time", "Performance", "AudioServer"]

var _server: TCPServer
var _peers: Array = []
var _peer_buffers: Dictionary = {}
var _token: String = ""
var _port: int = DEFAULT_PORT
var _scene_root: Node = null
var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

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

## Releases the listening socket synchronously. Must be called before
## freeing the bridge (plugin.gd's _exit_tree) — queue_free() alone defers
## actual destruction to the next idle frame, which can race a fresh
## bridge's _ready() trying to bind the same port on plugin re-enable: the
## new bridge's listen() fails silently (a push_error, easy to miss in the
## Output panel) and the OLD bridge — with whatever code was loaded before
## the edit that prompted the reload — is left as the only thing serving
## requests, with no obvious symptom besides "unknown command" for anything
## added since.
func stop() -> void:
	set_process(false)
	for peer in _peers:
		var stream: StreamPeerTCP = peer
		stream.disconnect_from_host()
	_peers.clear()
	_peer_buffers.clear()
	if _server:
		_server.stop()
		_server = null

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

## A value string prefixed "load:" is loaded from disk via load() instead of
## parsed by str_to_var() — needed for textures/resources that only exist as
## files, since str_to_var() can't construct arbitrary resource references
## from a bare res:// path the way it can for e.g. Vector2/Color literals.
func _decode_value(value_str: String):
	if value_str.begins_with("load:"):
		return load(value_str.substr(5))
	return str_to_var(value_str)

## Applies already-decoded values (no unknown-property check — caller's
## responsibility) through the editor's UndoRedo, batched as one action, so
## Godot's own dirty-tracking / save-prompt / Ctrl+Z all see the change.
## Falls back to a direct Object.set() loop if no EditorPlugin is wired up
## (shouldn't happen in normal operation, but keeps this safe either way).
func _commit_properties(obj: Object, values: Dictionary) -> void:
	if values.is_empty():
		return
	if _editor_plugin:
		var undo_redo := _editor_plugin.get_undo_redo()
		undo_redo.create_action("GodotLiveMCP: set properties")
		for name_str in values:
			undo_redo.add_do_property(obj, name_str, values[name_str])
			undo_redo.add_undo_property(obj, name_str, obj.get(name_str))
		undo_redo.commit_action()
	else:
		for name_str in values:
			obj.set(name_str, values[name_str])

## Sets each property via Object.set() (through _commit_properties, so it's
## undo/dirty-tracked). Object.set() silently no-ops on an unknown name (no
## error), so this validates every name against obj.get_property_list()
## FIRST and applies nothing at all if any are unknown — atomic, rather
## than partially applying the valid ones before reporting failure.
## Returns any property names that don't actually exist on obj.
func _apply_properties(obj: Object, props: Dictionary) -> Array:
	var valid_names := {}
	for p in obj.get_property_list():
		valid_names[p.name] = true

	var unknown := []
	var to_apply := {}
	for prop_name in props:
		var name_str := String(prop_name)
		if not valid_names.has(name_str):
			unknown.append(name_str)
			continue
		to_apply[name_str] = _decode_value(String(props[prop_name]))
	if not unknown.is_empty():
		return unknown

	_commit_properties(obj, to_apply)
	return unknown

## Reads back the given property names from obj as var_to_str()-encoded values.
func _read_back(obj: Object, prop_names) -> Dictionary:
	var result := {}
	for prop_name in prop_names:
		var name_str := String(prop_name)
		result[name_str] = var_to_str(obj.get(name_str))
	return result

# ---- Commands ----

func _cmd_ping(_params: Dictionary):
	return "pong"

func _cmd_eval_expression(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var expr_src := String(params.get("expression", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var input_names: Array = _SINGLETON_NAMES.duplicate()
	var input_values: Array = [ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer]
	if Engine.is_editor_hint():
		input_names.append("EditorInterface")
		input_values.append(EditorInterface)

	var expr := Expression.new()
	var parse_err := expr.parse(expr_src, input_names)
	if parse_err != OK:
		return _fail("parse error: %s" % expr.get_error_text())

	var value = expr.execute(input_values, node, true)
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

	var unknown := _apply_properties(node, {prop_name: value_str})
	if not unknown.is_empty():
		return _fail("unknown property: %s" % prop_name)
	return {"value": var_to_str(node.get(prop_name))}

func _cmd_set_properties(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var properties: Dictionary = params.get("properties", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var unknown := _apply_properties(node, properties)
	if not unknown.is_empty():
		return _fail("unknown properties: %s" % ", ".join(unknown))

	var result := {}
	for prop_name in properties:
		var name_str := String(prop_name)
		result[name_str] = var_to_str(node.get(name_str))
	return result

## Sets a property reached through a colon-separated path (e.g.
## "material_override:albedo_color"), the same path shape the editor
## inspector's own revert-arrow UI uses. Object.set() treats a colon-path as
## a single literal property name, which either fails as "unknown" (now
## caught) or — before that validation existed — silently zeroed the
## top-level property instead of touching the sub-property. This walks each
## intermediate segment via .get(), requires every intermediate value to be
## an Object (a Resource, typically) since only reference types alias back
## into the original — a Vector2/Rect2/etc. intermediate is a copy and
## can't be mutated in place, so those fail loudly instead of silently
## no-oping. The final segment is applied through the same validated,
## UndoRedo-tracked path as set_property.
func _cmd_set_nested_property(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var property_path := String(params.get("property_path", ""))
	var value_str := String(params.get("value", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if property_path == "":
		return _fail("property_path is required")

	var parts := property_path.split(":")
	if parts.size() < 2:
		return _fail('property_path must contain at least one ":" (e.g. "material_override:albedo_color")')

	var obj: Object = node
	var resolved_path := node_path
	for i in range(parts.size() - 1):
		var seg := parts[i]
		var valid_names := {}
		for p in obj.get_property_list():
			valid_names[p.name] = true
		if not valid_names.has(seg):
			return _fail("unknown property: %s (in path %s)" % [seg, property_path])
		var next = obj.get(seg)
		resolved_path += ":" + seg
		if next == null:
			return _fail("%s is null — assign/create the resource first (e.g. via set_resource_property) before setting a nested property on it" % resolved_path)
		if not (next is Object):
			return _fail("%s is a %s value, not an Object — nested set only works through Resource/Object-typed intermediate properties" % [resolved_path, type_string(typeof(next))])
		obj = next

	var last_prop := parts[parts.size() - 1]
	var unknown := _apply_properties(obj, {last_prop: value_str})
	if not unknown.is_empty():
		return _fail("unknown property: %s (on %s)" % [last_prop, resolved_path])
	return {"value": var_to_str(obj.get(last_prop))}

## Generic resource-property setter: instantiates a fresh Resource of any
## class by name, applies properties to it through the same validated path
## as every other resource tool, and assigns it to a node property. This is
## the generalized version of the ad hoc pattern used by
## set_theme_stylebox_override/set_shader_material/set_physics_material/
## setup_environment (each hardcoded to one resource type) — covers any
## Resource subclass without a dedicated tool. Reuses the node's existing
## resource in place (rather than replacing it) when it's already the
## requested type, matching those tools' behavior.
func _cmd_set_resource_property(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var property_name := String(params.get("property_name", ""))
	var resource_type := String(params.get("resource_type", ""))
	var resource_params: Dictionary = params.get("resource_params", {})
	var reuse_existing := bool(params.get("reuse_existing", true))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if property_name == "":
		return _fail("property_name is required")
	if resource_type == "":
		return _fail("resource_type is required")

	var valid_names := {}
	for p in node.get_property_list():
		valid_names[p.name] = true
	if not valid_names.has(property_name):
		return _fail("unknown property: %s" % property_name)
	if not ClassDB.class_exists(resource_type) or not ClassDB.is_parent_class(resource_type, "Resource"):
		return _fail("not a Resource subclass: %s" % resource_type)
	if not ClassDB.can_instantiate(resource_type):
		return _fail("cannot instantiate resource type: %s" % resource_type)

	var res: Resource
	var current = node.get(property_name)
	if reuse_existing and current != null and current.get_class() == resource_type:
		res = current
	else:
		res = ClassDB.instantiate(resource_type)

	var unknown := _apply_properties(res, resource_params)
	if not unknown.is_empty():
		return _fail("unknown %s properties: %s" % [resource_type, ", ".join(unknown)])

	_commit_properties(node, {property_name: res})
	return {"ok": true, "resource_type": res.get_class(), "resource": _read_back(res, resource_params.keys())}

func _cmd_set_transform(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is Node2D or node is Node3D):
		return _fail("node is not a Node2D or Node3D: %s" % node_path)

	var values := {}
	if params.has("position"):
		values["position"] = str_to_var(String(params["position"]))
	if params.has("rotation"):
		values["rotation"] = float(str_to_var(String(params["rotation"])))
	if params.has("scale"):
		values["scale"] = str_to_var(String(params["scale"]))
	_commit_properties(node, values)
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

func _cmd_validate_script(params: Dictionary):
	var script_path := String(params.get("script_path", ""))
	if not FileAccess.file_exists(script_path):
		return _fail("script not found: %s" % script_path)
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f == null:
		return _fail("could not open for reading: %s (error %d)" % [script_path, FileAccess.get_open_error()])
	var source := f.get_as_text()
	f.close()

	var scr := GDScript.new()
	scr.source_code = source
	var err := scr.reload()
	if err != OK:
		return _fail("parse failed with error code %d (see the editor's Output panel for the message)" % err)
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
	if node == new_parent:
		return _fail("cannot reparent a node under itself: %s" % node_path)
	if node.is_ancestor_of(new_parent):
		return _fail("cannot reparent %s under %s: %s is already a parent of %s (cyclic)" % [node_path, new_parent_path, node_path, new_parent_path])
	if node.get_parent() == new_parent:
		return {"path": _rel_path(node)}

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

func _cmd_save_scene_live(params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("save_scene_live is only available inside the editor")
	var path := String(params.get("path", ""))
	if path == "":
		var err: int = EditorInterface.save_scene()
		if err != OK:
			return _fail("save failed with error code %d" % err)
	else:
		# save_scene_as() returns void, unlike save_scene() — no error code to check.
		EditorInterface.save_scene_as(path)
	return {"ok": true}

## Toggles the plugin off/on via EditorInterface.set_plugin_enabled(), the
## same call the manual Project Settings > Plugins checkbox makes — so new
## bridge.gd code can take effect without a manual reload. Deferred to the
## next idle frame: disabling frees `self` via stop()+queue_free() inside
## plugin.gd's _exit_tree(), and queue_free() only marks the object for
## deletion at end-of-frame, so it's safe to keep running (including the
## re-enable call) for the rest of this call — but not safe to run
## synchronously inside the request handler that's still using this same
## peer/socket. The response is sent before the reload actually happens, so
## the calling client should expect the connection to drop and reconnect.
func _cmd_reload_plugin(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("reload_plugin is only available inside the editor")
	call_deferred("_do_reload_plugin")
	return {"ok": true, "note": "plugin reloading — the connection will drop; reconnect after a moment"}

func _do_reload_plugin() -> void:
	EditorInterface.set_plugin_enabled(PLUGIN_ADDON_NAME, false)
	EditorInterface.set_plugin_enabled(PLUGIN_ADDON_NAME, true)

const _SHAPE_2D_TYPES := [
	"RectangleShape2D", "CircleShape2D", "CapsuleShape2D", "SegmentShape2D",
	"SeparationRayShape2D", "ConvexPolygonShape2D", "ConcavePolygonShape2D",
]
const _SHAPE_3D_TYPES := [
	"BoxShape3D", "SphereShape3D", "CapsuleShape3D", "CylinderShape3D",
	"SeparationRayShape3D", "ConvexPolygonShape3D", "ConcavePolygonShape3D", "WorldBoundaryShape3D",
]

func _cmd_setup_collision(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var shape_type := String(params.get("shape_type", ""))
	var shape_params: Dictionary = params.get("shape_params", {})
	var parent := _resolve_node(node_path)
	if parent == null:
		return _fail("node not found: %s" % node_path)

	var collision_node_type := ""
	if shape_type in _SHAPE_2D_TYPES:
		collision_node_type = "CollisionShape2D"
	elif shape_type in _SHAPE_3D_TYPES:
		collision_node_type = "CollisionShape3D"
	else:
		return _fail("unknown or unsupported shape_type: %s" % shape_type)

	if not (parent is CollisionObject2D or parent is CollisionObject3D):
		return _fail("node is not a CollisionObject2D/3D (e.g. Area2D, StaticBody2D, RigidBody3D): %s" % node_path)

	var shape: Resource = ClassDB.instantiate(shape_type)
	var unknown := _apply_properties(shape, shape_params)
	if not unknown.is_empty():
		return _fail("unknown shape properties for %s: %s" % [shape_type, ", ".join(unknown)])

	var collision_node: Node = ClassDB.instantiate(collision_node_type)
	collision_node.shape = shape
	parent.add_child(collision_node)
	var root := _get_scene_root()
	if root:
		collision_node.owner = root

	return {"path": _rel_path(collision_node), "shape": _read_back(shape, shape_params.keys())}

func _cmd_get_collision_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is CollisionShape2D or node is CollisionShape3D):
		return _fail("node is not a CollisionShape2D/3D: %s" % node_path)
	if node.shape == null:
		return {"shape_type": null, "properties": {}}

	var shape: Resource = node.shape
	var props := {}
	for prop in shape.get_property_list():
		if prop.usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		props[prop.name] = var_to_str(shape.get(prop.name))
	return {"shape_type": shape.get_class(), "properties": props}

func _layers_to_bitmask(layers: Array) -> int:
	var mask := 0
	for layer in layers:
		var n := int(layer)
		if n >= 1 and n <= 32:
			mask |= (1 << (n - 1))
	return mask

func _bitmask_to_layers(mask: int) -> Array:
	var layers := []
	for i in range(1, 33):
		if mask & (1 << (i - 1)) != 0:
			layers.append(i)
	return layers

func _cmd_set_physics_layers(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not ("collision_layer" in node):
		return _fail("node has no collision_layer/collision_mask (not a CollisionObject2D/3D or similar): %s" % node_path)

	if params.has("layers"):
		node.collision_layer = _layers_to_bitmask(params["layers"])
	if params.has("mask"):
		node.collision_mask = _layers_to_bitmask(params["mask"])
	return {
		"layers": _bitmask_to_layers(node.collision_layer),
		"mask": _bitmask_to_layers(node.collision_mask),
	}

func _cmd_get_physics_layers(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not ("collision_layer" in node):
		return _fail("node has no collision_layer/collision_mask (not a CollisionObject2D/3D or similar): %s" % node_path)
	return {
		"layers": _bitmask_to_layers(node.collision_layer),
		"mask": _bitmask_to_layers(node.collision_mask),
	}

func _cmd_add_mesh_instance(params: Dictionary):
	var parent_path := String(params.get("parent_path", "."))
	var mesh_type := String(params.get("mesh_type", ""))
	var mesh_params: Dictionary = params.get("mesh_params", {})
	var node_name := String(params.get("node_name", ""))
	var parent := _resolve_node(parent_path)
	if parent == null:
		return _fail("parent not found: %s" % parent_path)
	if not ClassDB.class_exists(mesh_type) or not ClassDB.is_parent_class(mesh_type, "Mesh"):
		return _fail("not a Mesh subclass: %s" % mesh_type)
	if not ClassDB.can_instantiate(mesh_type):
		return _fail("cannot instantiate mesh type: %s" % mesh_type)

	var mesh: Mesh = ClassDB.instantiate(mesh_type)
	var unknown := _apply_properties(mesh, mesh_params)
	if not unknown.is_empty():
		return _fail("unknown mesh properties for %s: %s" % [mesh_type, ", ".join(unknown)])

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	if node_name != "":
		mesh_instance.name = node_name
	parent.add_child(mesh_instance)
	var root := _get_scene_root()
	if root:
		mesh_instance.owner = root

	return {"path": _rel_path(mesh_instance), "mesh": _read_back(mesh, mesh_params.keys())}

func _cmd_setup_environment(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var environment_params: Dictionary = params.get("environment_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is WorldEnvironment):
		return _fail("node is not a WorldEnvironment: %s" % node_path)

	var env: Environment = node.environment
	if env == null:
		env = Environment.new()
	var unknown := _apply_properties(env, environment_params)
	if not unknown.is_empty():
		return _fail("unknown environment properties: %s" % ", ".join(unknown))
	node.environment = env

	return {"ok": true, "environment": _read_back(env, environment_params.keys())}

func _cmd_set_material_3d(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var material_params: Dictionary = params.get("material_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is GeometryInstance3D):
		return _fail("node is not a GeometryInstance3D (e.g. MeshInstance3D): %s" % node_path)

	if params.has("surface_index"):
		if not (node is MeshInstance3D):
			return _fail("surface_index requires a MeshInstance3D: %s" % node_path)
		var mesh_instance: MeshInstance3D = node
		var idx := int(params["surface_index"])
		if idx < 0 or idx >= mesh_instance.get_surface_override_material_count():
			return _fail("surface_index %d out of range (mesh has %d surfaces)" % [idx, mesh_instance.get_surface_override_material_count()])

		var surf_mat: StandardMaterial3D
		var current_surf = mesh_instance.get_surface_override_material(idx)
		if current_surf is StandardMaterial3D:
			surf_mat = current_surf
		else:
			surf_mat = StandardMaterial3D.new()
		var surf_unknown := _apply_properties(surf_mat, material_params)
		if not surf_unknown.is_empty():
			return _fail("unknown material properties: %s" % ", ".join(surf_unknown))
		mesh_instance.set_surface_override_material(idx, surf_mat)
		return {"ok": true, "material": _read_back(surf_mat, material_params.keys())}

	var mat: StandardMaterial3D
	if node.material_override is StandardMaterial3D:
		mat = node.material_override
	else:
		mat = StandardMaterial3D.new()
	var unknown := _apply_properties(mat, material_params)
	if not unknown.is_empty():
		return _fail("unknown material properties: %s" % ", ".join(unknown))
	node.material_override = mat

	return {"ok": true, "material": _read_back(mat, material_params.keys())}

func _cmd_set_physics_material(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var material_params: Dictionary = params.get("material_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is PhysicsBody2D or node is PhysicsBody3D):
		return _fail("node is not a PhysicsBody2D/3D (e.g. RigidBody3D, StaticBody2D): %s" % node_path)

	var mat: PhysicsMaterial
	var current = node.get("physics_material_override")
	if current is PhysicsMaterial:
		mat = current
	else:
		mat = PhysicsMaterial.new()
	var unknown := _apply_properties(mat, material_params)
	if not unknown.is_empty():
		return _fail("unknown physics material properties: %s" % ", ".join(unknown))
	node.set("physics_material_override", mat)
	return {"ok": true, "material": _read_back(mat, material_params.keys())}

func _cmd_set_theme_stylebox_override(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var override_name := String(params.get("override_name", ""))
	var style_type := String(params.get("style_type", "StyleBoxFlat"))
	var style_params: Dictionary = params.get("style_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is Control):
		return _fail("node is not a Control: %s" % node_path)
	if override_name == "":
		return _fail("override_name is required")
	if not ClassDB.class_exists(style_type) or not ClassDB.is_parent_class(style_type, "StyleBox"):
		return _fail("not a StyleBox subclass: %s" % style_type)
	if not ClassDB.can_instantiate(style_type):
		return _fail("cannot instantiate style type: %s" % style_type)

	var stylebox: StyleBox = ClassDB.instantiate(style_type)
	var unknown := _apply_properties(stylebox, style_params)
	if not unknown.is_empty():
		return _fail("unknown style properties for %s: %s" % [style_type, ", ".join(unknown)])
	node.add_theme_stylebox_override(override_name, stylebox)
	return {"ok": true, "style": _read_back(stylebox, style_params.keys())}

## Resolves which property holds a node's material: material_override for
## 3D GeometryInstance3D, material for 2D CanvasItem. Returns "" if neither.
func _material_property_for(node: Node) -> String:
	if node is GeometryInstance3D:
		return "material_override"
	if node is CanvasItem:
		return "material"
	return ""

func _cmd_set_shader_material(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var shader_path := String(params.get("shader_path", ""))
	var shader_params: Dictionary = params.get("shader_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var prop_name := _material_property_for(node)
	if prop_name == "":
		return _fail("node is not a GeometryInstance3D or CanvasItem: %s" % node_path)

	var mat: ShaderMaterial
	var current = node.get(prop_name)
	if current is ShaderMaterial:
		mat = current
	else:
		mat = ShaderMaterial.new()

	if shader_path != "":
		if not ResourceLoader.exists(shader_path):
			return _fail("shader not found: %s" % shader_path)
		mat.shader = load(shader_path)
	if mat.shader == null:
		return _fail("no shader set — pass shader_path, or the node's existing material must already have one")

	var applied := {}
	for pname in shader_params:
		var pname_str := String(pname)
		mat.set_shader_parameter(pname_str, _decode_value(String(shader_params[pname])))
		applied[pname_str] = var_to_str(mat.get_shader_parameter(pname_str))

	node.set(prop_name, mat)
	return {"ok": true, "shader_path": mat.shader.resource_path, "shader_params": applied}

func _cmd_get_shader_material_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var prop_name := _material_property_for(node)
	if prop_name == "":
		return _fail("node is not a GeometryInstance3D or CanvasItem: %s" % node_path)

	var mat = node.get(prop_name)
	if not (mat is ShaderMaterial):
		return {"has_shader_material": false}

	var shader_path := ""
	var uniforms := {}
	if mat.shader:
		shader_path = mat.shader.resource_path
		for u in mat.shader.get_shader_uniform_list():
			var uname: String = u.name
			uniforms[uname] = var_to_str(mat.get_shader_parameter(uname))

	return {"has_shader_material": true, "shader_path": shader_path, "shader_params": uniforms}

const _TRACK_TYPES := {
	"value": Animation.TYPE_VALUE,
	"position_3d": Animation.TYPE_POSITION_3D,
	"rotation_3d": Animation.TYPE_ROTATION_3D,
	"scale_3d": Animation.TYPE_SCALE_3D,
	"blend_shape": Animation.TYPE_BLEND_SHAPE,
	"method": Animation.TYPE_METHOD,
	"bezier": Animation.TYPE_BEZIER,
	"audio": Animation.TYPE_AUDIO,
	"animation": Animation.TYPE_ANIMATION,
}

func _get_or_create_library(player: AnimationPlayer, library_name: String) -> AnimationLibrary:
	if player.has_animation_library(library_name):
		return player.get_animation_library(library_name)
	var library := AnimationLibrary.new()
	player.add_animation_library(library_name, library)
	return library

func _cmd_create_animation(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var anim_name := String(params.get("anim_name", ""))
	var length := float(params.get("length", 1.0))
	var library_name := String(params.get("library_name", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _fail("node is not an AnimationPlayer: %s" % node_path)
	if anim_name == "":
		return _fail("anim_name is required")

	var player: AnimationPlayer = node
	var library := _get_or_create_library(player, library_name)
	if library.has_animation(anim_name):
		return _fail("animation already exists: %s" % anim_name)

	var anim := Animation.new()
	anim.length = length
	library.add_animation(anim_name, anim)
	return {"ok": true}

func _cmd_add_animation_track(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var anim_name := String(params.get("anim_name", ""))
	var library_name := String(params.get("library_name", ""))
	var track_type := String(params.get("track_type", ""))
	var track_node_path := String(params.get("track_node_path", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _fail("node is not an AnimationPlayer: %s" % node_path)
	if not _TRACK_TYPES.has(track_type):
		return _fail("unknown track_type: %s (expected one of %s)" % [track_type, ", ".join(_TRACK_TYPES.keys())])
	var player: AnimationPlayer = node
	if not player.has_animation_library(library_name):
		return _fail("animation library not found: %s" % library_name)
	var library: AnimationLibrary = player.get_animation_library(library_name)
	if not library.has_animation(anim_name):
		return _fail("animation not found: %s" % anim_name)

	var anim: Animation = library.get_animation(anim_name)
	var idx: int = anim.add_track(_TRACK_TYPES[track_type])
	anim.track_set_path(idx, NodePath(track_node_path))
	return {"track_index": idx}

func _cmd_get_animation_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var anim_name := String(params.get("anim_name", ""))
	var library_name := String(params.get("library_name", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _fail("node is not an AnimationPlayer: %s" % node_path)
	var player: AnimationPlayer = node
	if not player.has_animation_library(library_name):
		return _fail("animation library not found: %s" % library_name)
	var library: AnimationLibrary = player.get_animation_library(library_name)
	if not library.has_animation(anim_name):
		return _fail("animation not found: %s" % anim_name)

	var anim: Animation = library.get_animation(anim_name)
	var tracks := []
	for i in range(anim.get_track_count()):
		var keys := []
		for k in range(anim.track_get_key_count(i)):
			keys.append({
				"time": anim.track_get_key_time(i, k),
				"value": var_to_str(anim.track_get_key_value(i, k)),
			})
		tracks.append({
			"index": i,
			"type": _TRACK_TYPES.find_key(anim.track_get_type(i)),
			"path": String(anim.track_get_path(i)),
			"keys": keys,
		})
	return {"length": anim.length, "tracks": tracks}

func _cmd_add_audio_bus(params: Dictionary):
	var bus_name := String(params.get("bus_name", ""))
	if bus_name == "":
		return _fail("bus_name is required")
	if AudioServer.get_bus_index(bus_name) != -1:
		return _fail("bus already exists: %s" % bus_name)

	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	return {"bus_index": idx}

func _cmd_add_audio_bus_effect(params: Dictionary):
	var bus_name := String(params.get("bus_name", ""))
	var effect_type := String(params.get("effect_type", ""))
	var effect_params: Dictionary = params.get("effect_params", {})
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return _fail("bus not found: %s" % bus_name)
	if not ClassDB.class_exists(effect_type) or not ClassDB.is_parent_class(effect_type, "AudioEffect"):
		return _fail("not an AudioEffect subclass: %s" % effect_type)
	if not ClassDB.can_instantiate(effect_type):
		return _fail("cannot instantiate effect type: %s" % effect_type)

	var effect: AudioEffect = ClassDB.instantiate(effect_type)
	var unknown := _apply_properties(effect, effect_params)
	if not unknown.is_empty():
		return _fail("unknown effect properties for %s: %s" % [effect_type, ", ".join(unknown)])
	AudioServer.add_bus_effect(idx, effect)
	return {"ok": true, "bus_index": idx, "effect": _read_back(effect, effect_params.keys())}

func _cmd_get_audio_bus_layout(_params: Dictionary):
	var buses := []
	for i in range(AudioServer.bus_count):
		var effects := []
		for e in range(AudioServer.get_bus_effect_count(i)):
			effects.append(AudioServer.get_bus_effect(i, e).get_class())
		buses.append({
			"index": i,
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"mute": AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i),
			"bypass_effects": AudioServer.is_bus_bypassing_effects(i),
			"send": AudioServer.get_bus_send(i),
			"effects": effects,
		})
	return {"buses": buses}

func _cmd_tilemap_fill_rect(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is TileMapLayer):
		return _fail("node is not a TileMapLayer: %s" % node_path)
	var layer: TileMapLayer = node

	var pos: Vector2i = str_to_var(String(params.get("position", "Vector2i(0, 0)")))
	var size: Vector2i = str_to_var(String(params.get("size", "Vector2i(1, 1)")))
	var atlas_coords: Vector2i = str_to_var(String(params.get("atlas_coords", "Vector2i(0, 0)")))
	var source_id := int(params.get("source_id", 0))
	var alternative_tile := int(params.get("alternative_tile", 0))
	if size.x <= 0 or size.y <= 0:
		return _fail("size must have positive x and y")

	var count := 0
	for x in range(pos.x, pos.x + size.x):
		for y in range(pos.y, pos.y + size.y):
			layer.set_cell(Vector2i(x, y), source_id, atlas_coords, alternative_tile)
			count += 1
	return {"ok": true, "cells_set": count}

func _cmd_tilemap_get_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is TileMapLayer):
		return _fail("node is not a TileMapLayer: %s" % node_path)
	var layer: TileMapLayer = node

	var sources := []
	var tile_set := layer.tile_set
	if tile_set:
		for i in range(tile_set.get_source_count()):
			sources.append(tile_set.get_source_id(i))

	return {
		"used_rect": var_to_str(layer.get_used_rect()),
		"used_cells_count": layer.get_used_cells().size(),
		"tile_set_sources": sources,
	}

func _get_or_create_particle_material(node: Node) -> ParticleProcessMaterial:
	var current = node.get("process_material")
	if current is ParticleProcessMaterial:
		return current
	return ParticleProcessMaterial.new()

func _cmd_set_particle_material(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var material_params: Dictionary = params.get("material_params", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is GPUParticles2D or node is GPUParticles3D):
		return _fail("node is not a GPUParticles2D/3D: %s" % node_path)

	var mat := _get_or_create_particle_material(node)
	var unknown := _apply_properties(mat, material_params)
	if not unknown.is_empty():
		return _fail("unknown particle material properties: %s" % ", ".join(unknown))
	node.set("process_material", mat)
	return {"ok": true, "material": _read_back(mat, material_params.keys())}

func _cmd_set_particle_color_gradient(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var points: Array = params.get("points", [])
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is GPUParticles2D or node is GPUParticles3D):
		return _fail("node is not a GPUParticles2D/3D: %s" % node_path)
	if points.is_empty():
		return _fail("points must be a non-empty array of {offset, color}")

	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for pt in points:
		var p: Dictionary = pt
		offsets.append(float(p.get("offset", 0.0)))
		colors.append(str_to_var(String(p.get("color", "Color(1, 1, 1, 1)"))))

	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient

	var mat := _get_or_create_particle_material(node)
	mat.color_ramp = gradient_texture
	node.set("process_material", mat)
	return {"ok": true}

func _cmd_get_particle_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is GPUParticles2D or node is GPUParticles3D):
		return _fail("node is not a GPUParticles2D/3D: %s" % node_path)

	var mat_props := {}
	var mat_type = null
	var mat = node.get("process_material")
	if mat:
		mat_type = mat.get_class()
		for prop in mat.get_property_list():
			if prop.usage & PROPERTY_USAGE_EDITOR == 0:
				continue
			mat_props[prop.name] = var_to_str(mat.get(prop.name))

	return {
		"amount": node.get("amount"),
		"lifetime": node.get("lifetime"),
		"emitting": node.get("emitting"),
		"process_material_type": mat_type,
		"process_material_properties": mat_props,
	}

# ---- Token / port setup ----

func _load_or_create_token() -> String:
	var override := OS.get_environment("GODOT_LIVE_MCP_TOKEN")
	if override != "":
		print("GodotLiveMCPBridge: using GODOT_LIVE_MCP_TOKEN from environment")
		return override
	var path := "user://godot_live_mcp_token.txt"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var existing := f.get_as_text().strip_edges()
		if existing != "":
			print("GodotLiveMCPBridge: reusing token cached at %s (no GODOT_LIVE_MCP_TOKEN in environment)" % ProjectSettings.globalize_path(path))
			return existing
	var generated := _generate_token()
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string(generated)
	print("GodotLiveMCPBridge: generated token, stored at %s (no GODOT_LIVE_MCP_TOKEN in environment)" % ProjectSettings.globalize_path(path))
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
