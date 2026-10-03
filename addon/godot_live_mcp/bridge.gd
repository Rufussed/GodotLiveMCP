@tool
class_name GodotLiveMCPBridge
extends Node

## Emitted once per request the bridge answers (ok = whether it succeeded). The
## AI Assistant panel's robot uses it to show that an AI is working in the
## editor, whichever client (chat, CLI, a separate terminal, another tool) it is.
signal activity(ok: bool)

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
const _SINGLETON_NAMES := ["ProjectSettings", "ClassDB", "Engine", "Input", "OS", "Time", "Performance", "AudioServer", "ResourceLoader", "ResourceSaver"]

## KEY_* constant values, mirrored from runtime_bridge.gd's own table
## (confirmed live there: global enums like Key aren't exposed through
## ClassDB reflection, and Expression can't resolve free-standing global
## constants either — special/non-printable keys need this table;
## printable letters/digits are just their Unicode code point). Bound into
## eval_expression's Expression context below so expressions like
## "Input.is_key_pressed(KEY_A)" parse instead of failing with "Invalid
## named index 'KEY_A'" — hit twice independently in real usage
## (TOOL_CANDIDATES.md review, 2026-09-10).
const _SPECIAL_KEYS := {
	"KEY_ESCAPE": 4194305, "KEY_TAB": 4194306, "KEY_BACKSPACE": 4194308,
	"KEY_ENTER": 4194309, "KEY_HOME": 4194317, "KEY_END": 4194318,
	"KEY_LEFT": 4194319, "KEY_UP": 4194320, "KEY_RIGHT": 4194321,
	"KEY_DOWN": 4194322, "KEY_DELETE": 4194312, "KEY_SHIFT": 4194325,
	"KEY_CTRL": 4194326, "KEY_ALT": 4194328, "KEY_SPACE": 32,
}
const _F_KEY_BASE := 4194332  # KEY_F1; KEY_F2..KEY_F12 sequential from here

static var _KEY_CONSTANTS: Dictionary = _build_key_constants()

static func _build_key_constants() -> Dictionary:
	var d := _SPECIAL_KEYS.duplicate()
	for i in range(1, 13):
		d["KEY_F%d" % i] = _F_KEY_BASE + (i - 1)
	for c in range(65, 91):  # A-Z
		d["KEY_%s" % char(c)] = c
	for c in range(48, 58):  # 0-9
		d["KEY_%s" % char(c)] = c
	return d

var _server: TCPServer
var _peers: Array = []
var _peer_buffers: Dictionary = {}
var _token: String = ""
var _port: int = DEFAULT_PORT
var _scene_root: Node = null
var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin
	# Only used to message a running game (see _reload_game_scripts).
	_debugger_plugin = EditorDebuggerPlugin.new()
	plugin.add_debugger_plugin(_debugger_plugin)

var _debugger_plugin: EditorDebuggerPlugin = null

func _exit_tree() -> void:
	if _editor_plugin and _debugger_plugin:
		_editor_plugin.remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null

## Tells a game running from the editor to reload its scripts. The editor's
## own Synchronize Script Changes doesn't fire for plugin-driven saves (not
## even through the script editor's File > Save), so it's sent directly.
func _reload_game_scripts() -> void:
	if _debugger_plugin == null:
		return
	for session in _debugger_plugin.get_sessions():
		if session.is_active():
			session.send_message("reload_all_scripts", [])

## Presses the script editor's File > Save for the current tab, so the tab
## is saved the same way Ctrl+S does (and stops showing as unsaved).
func _press_script_editor_save() -> bool:
	for node in EditorInterface.get_script_editor().find_children("*", "PopupMenu", true, false):
		var menu := node as PopupMenu
		for i in menu.item_count:
			if menu.get_item_text(i) == "Save":
				menu.id_pressed.emit(menu.get_item_id(i))
				return true
	return false

const OutputCapture = preload("res://addons/godot_live_mcp/output_capture.gd")
var _output_capture: Logger

func _ready() -> void:
	_output_capture = OutputCapture.new()
	OS.add_logger(_output_capture)
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
	if _output_capture:
		OS.remove_logger(_output_capture)
		_output_capture = null
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
		# No scene open: don't fall back to the editor's own UI tree, which
		# is ~30k nodes of editor internals (listing it stalls the editor).
		return edited
	return get_tree().root if is_inside_tree() else null

## Socket I/O only happens here, once per rendered frame — so any command
## that itself runs long and synchronous (a script's own expensive
## regeneration logic, EditorInterface.open_scene_from_path() on a large
## scene, ...) blocks this loop, and with it every other bridge command,
## until it returns. Confirmed live (recurring across two usage-log
## reviews, 2026-09-10): calls made right after such an operation —
## including trivial ones — can time out at the client's 5s limit,
## sometimes repeatedly, before this resumes polling. Not fixable by a new
## tool; inherent to single-threaded GDScript. See README's "Known
## limitations".
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
		# Awaited so a command can wait a frame for the editor (a no-op for
		# the ones that don't suspend).
		var watch := command in _RAW_EDIT_COMMANDS
		_fp_total_us = 0
		_fp_worst = {"us": 0}
		var before := _scene_fingerprint() if watch else {}
		var root_before: Node = _get_scene_root() if watch else null
		var response = await call("_cmd_" + command, params)
		if typeof(response) == TYPE_DICTIONARY and response.has("__error__"):
			ok = false
			error = response["__error__"]
			# The usual reason a path that worked a moment ago stops
			# resolving — or a property that should exist "doesn't" — is
			# that a different scene tab is now being edited; seen in real
			# use, where the agent had no way to tell. Name the scene on any
			# failed call that targeted a node.
			if params.has("node_path") or params.has("node_paths") or params.has("parent_path") or params.has("edits"):
				error = "%s (the edited scene is %s)" % [error, _edited_scene_label()]
		else:
			result = response
		# Also on errors: a script can change the scene before it fails.
		# Opening or switching to another scene changes the fingerprint too,
		# but isn't an edit — it used to be flagged as one.
		if watch and _get_scene_root() == root_before and await _scene_edited_since(before):
			if typeof(result) != TYPE_DICTIONARY:
				result = {"value": result} if ok else {}
			result["scene_changed_note"] = _mac_keys(_RAW_EDIT_NOTE)
			if not ok:
				error = "%s (%s)" % [error, _mac_keys(_RAW_EDIT_NOTE)]
		if watch and _fp_total_us >= _slow_scene_check_us():
			# Also logged in the editor: a call that runs past the server's
			# timeout never delivers this response, but get_output_log can
			# still show the warning.
			var slow := "the before/after scene check took %d ms (slowest: %s %s, %d ms)" % [
				_fp_total_us / 1000, _fp_worst.get("label", "?"), _fp_worst.get("class", ""), int(_fp_worst.us) / 1000]
			push_warning("GodotLiveMCP: %s" % slow)
			if ok:
				if typeof(result) != TYPE_DICTIONARY:
					result = {"value": result}
				result["scene_check_note"] = slow
			else:
				error = "%s (%s)" % [error, slow]

	activity.emit(ok)
	_send(peer, {"id": id, "ok": ok, "result": result, "error": error})

func _edited_scene_label() -> String:
	var root := _get_scene_root()
	if root == null:
		return "none (no scene open)"
	return root.scene_file_path if root.scene_file_path != "" else "an unsaved scene (%s)" % root.name

## Commands that run arbitrary code on the editor's scene. Their changes
## bypass Godot's undo system and never reach a running game, so the scene
## is fingerprinted before and after, and a change is reported back.
const _RAW_EDIT_COMMANDS := ["run_script", "eval_expression"]
const _RAW_EDIT_NOTE := ("This changed the editor's scene directly: the change can't be undone " +
	"with Ctrl+Z and won't show in a running game. Tell the user, and prefer the structured " +
	"tools (set_property, set_properties, add_node_live, ...) for edits to the scene.")

## The edited scene's structure and saved property values as {key: hash},
## including built-in sub-resources (materials, meshes, shapes...). Values are
## hashed rather than printed so big arrays (mesh data) stay cheap.
func _scene_fingerprint() -> Dictionary:
	var parts := {}
	var root := _get_scene_root()
	if root == null:
		return parts
	var seen := {}
	var start := Time.get_ticks_usec()
	for n in [root] + root.find_children("*", "", true, false):
		var label := str(root.get_path_to(n))
		var node_start := Time.get_ticks_usec()
		parts["%s|class" % label] = n.get_class()
		_fingerprint_object(n, label, parts, seen)
		var node_us := Time.get_ticks_usec() - node_start
		if node_us > int(_fp_worst.us):
			_fp_worst = {"us": node_us, "label": label, "class": n.get_class()}
	_fp_total_us += Time.get_ticks_usec() - start
	return parts

# Cost of the scene checks around the current run_script/eval_expression,
# summed over the before/after (and re-sample) passes, plus the one node
# whose own properties and sub-resources took longest. Reported when slow.
var _fp_total_us := 0
var _fp_worst := {"us": 0}

func _slow_scene_check_us() -> int:
	var ms := OS.get_environment("GODOT_LIVE_MCP_SLOW_MS")
	return (int(ms) if ms != "" else 250) * 1000

## Whether the scene changed since `before` was taken, ignoring values that
## change by themselves. Tool scripts animate properties on their own (the
## Sky3D addon drifts its cloud shader parameters every frame), so with a
## plain before/after comparison any command that let a frame pass — a
## reimport, a filesystem scan — was reported as a raw scene edit, in real
## use (reimport_files on some textures). When something differs, sample the
## scene again a couple of frames later: what still moves without anyone
## touching it is not an edit. Costs nothing unless something differs.
func _scene_edited_since(before: Dictionary) -> bool:
	var after := _scene_fingerprint()
	var differing := _differing_keys(before, after)
	if differing.is_empty():
		return false
	await get_tree().process_frame
	await get_tree().process_frame
	var later := _scene_fingerprint()
	for key in _differing_keys(after, later):
		differing.erase(key)
	return not differing.is_empty()

func _differing_keys(a: Dictionary, b: Dictionary) -> Dictionary:
	var keys := {}
	for key in a:
		if not b.has(key) or a[key] != b[key]:
			keys[key] = true
	for key in b:
		if not a.has(key):
			keys[key] = true
	return keys

func _fingerprint_object(obj: Object, label: String, parts: Dictionary, seen: Dictionary) -> void:
	for prop in obj.get_property_list():
		if not (prop.usage & PROPERTY_USAGE_STORAGE):
			continue
		var value = obj.get(prop.name)
		var key := "%s|%s" % [label, prop.name]
		if value is Resource:
			var res := value as Resource
			parts[key] = "res:%s" % res.resource_path
			_fingerprint_owned_resource(res, parts, seen)
		elif value is Object:
			parts[key] = "obj"
		else:
			parts[key] = hash(value)
			# Resources held in containers (AnimationPlayer's libraries ->
			# AnimationLibrary -> Animation) are part of the scene too.
			if value is Dictionary or value is Array:
				for item in (value.values() if value is Dictionary else value):
					if item is Resource:
						_fingerprint_owned_resource(item, parts, seen)

## Built-in resources are part of the scene; files are not.
func _fingerprint_owned_resource(res: Resource, parts: Dictionary, seen: Dictionary) -> void:
	if (res.resource_path == "" or res.resource_path.contains("::")) and not seen.has(res):
		# Numbered in the order found, so resources with no path of their own
		# still get a stable key.
		seen[res] = true
		var label := res.resource_path if res.resource_path != "" else "res#%d" % seen.size()
		_fingerprint_object(res, label, parts, seen)

func _send(peer: StreamPeerTCP, payload: Dictionary) -> void:
	var text := JSON.stringify(payload) + "\n"
	peer.put_data(text.to_utf8_buffer())

## Shortcut names as the user sees them: Cmd rather than Ctrl on macOS.
func _mac_keys(text: String) -> String:
	return text.replace("Ctrl+", "Cmd+") if OS.get_name() == "macOS" else text

## What the user would see in the Output and Debugger panels, in memory
## only: the Output panel's last `lines` lines (game prints included, since
## a game played from the editor sends them there), the Debugger's Errors
## tab for the current/last run (game errors and warnings never reach this
## process's own Logger — the game is a separate process), the stack the
## game is paused at, if any, and the editor's own errors/warnings captured
## by output_capture.gd (`editor_since` returns only newer ones).
func _cmd_get_output_log(params: Dictionary):
	var lines := int(params.get("lines", 60))
	var result := {"output": "", "game_errors": [], "game_paused_at": []}
	var logs := EditorInterface.get_base_control().find_children("*", "EditorLog", true, false)
	if not logs.is_empty():
		var labels: Array = logs[0].find_children("*", "RichTextLabel", true, false)
		if not labels.is_empty():
			var text_lines: PackedStringArray = labels[0].get_parsed_text().strip_edges().split("\n")
			result.output = "\n".join(text_lines.slice(maxi(0, text_lines.size() - lines)))
	# ScriptEditorDebugger's tabs are built in a fixed order: Stack Trace,
	# then Errors. Found by position since tab titles are translated.
	for dbg in EditorInterface.get_base_control().find_children("*", "ScriptEditorDebugger", true, false):
		var tabs: Array = dbg.find_children("*", "TabContainer", false, false)
		if tabs.is_empty() or tabs[0].get_child_count() < 2:
			continue
		var stack_trees: Array = tabs[0].get_child(0).find_children("*", "Tree", true, false)
		if not stack_trees.is_empty():
			result.game_paused_at += _tree_rows(stack_trees[0], false)
		var error_trees: Array = tabs[0].get_child(1).find_children("*", "Tree", true, false)
		if not error_trees.is_empty():
			result.game_errors += _tree_rows(error_trees[0], true)
	result.game_errors = result.game_errors.slice(maxi(0, result.game_errors.size() - 50))
	if _output_capture:
		var editor: Dictionary = _output_capture.read(int(params.get("editor_since", 0)), true, 30)
		result.editor_errors = editor.entries
		result.editor_next_since = editor.next_since
	return result

## Top-level rows of a debugger Tree as text: "time  message" plus, with
## `details`, each child row ("<GDScript Source> main.gd:7 @ _ready()").
func _tree_rows(tree: Tree, details: bool) -> Array:
	var rows := []
	var root := tree.get_root()
	if root == null:
		return rows
	var item := root.get_first_child()
	while item:
		var text := item.get_text(0) if tree.columns == 1 else "%s  %s" % [item.get_text(0), item.get_text(1)]
		if details:
			var row := {"error": text, "details": []}
			var child := item.get_first_child()
			while child:
				row.details.append(("%s %s" % [child.get_text(0), child.get_text(1)]).strip_edges())
				child = child.get_next()
			rows.append(row)
		else:
			rows.append(text)
		item = item.get_next()
	return rows

func _fail(msg: String) -> Dictionary:
	if msg.begins_with("node not found") and _get_scene_root() == null:
		msg += " (no scene is open in the editor; open or create one first)"
	return {"__error__": msg}

func _resolve_node(node_path: String) -> Node:
	var root := _get_scene_root()
	if root == null:
		return null
	if node_path == "" or node_path == ".":
		return root
	return root.get_node_or_null(NodePath(node_path))

# The editor debugger, whose live-edit methods mirror scene-structure edits
# into a game running from the editor (Debug > Synchronize Scene Changes).
# Property edits don't need them: the debugger already watches UndoRedo.
var _debugger_node: Node = null

func _find_debugger_node() -> Node:
	if not is_instance_valid(_debugger_node):
		_debugger_node = null
		for n in EditorInterface.get_base_control().get_tree().root.find_children("*", "EditorDebuggerNode", true, false):
			_debugger_node = n
			break
	return _debugger_node

## Scene-structure edits go through Godot's undo system as one action each,
## built the way the editor's own Scene dock builds them: do/undo method
## pairs on the scene nodes, plus the editor debugger's live-edit calls so
## a running game follows along (and follows undo/redo too).
var _node_action_ur: EditorUndoRedoManager = null

func _begin_node_action(action_name: String) -> bool:
	if _editor_plugin == null:
		return false
	_node_action_ur = _editor_plugin.get_undo_redo()
	# The scene root as context keeps this in the scene's own undo history.
	_node_action_ur.create_action("GodotLiveMCP: " + action_name, UndoRedo.MERGE_DISABLE, _get_scene_root())
	return true

func _do(obj: Object, method: String, args: Array = []) -> void:
	_node_action_ur.callv("add_do_method", [obj, method] + args)

func _undo(obj: Object, method: String, args: Array = []) -> void:
	_node_action_ur.callv("add_undo_method", [obj, method] + args)

func _do_live(method: String, args: Array) -> void:
	var dbg := _find_debugger_node()
	if dbg and dbg.has_method(method):
		_do(dbg, method, args)

func _undo_live(method: String, args: Array) -> void:
	var dbg := _find_debugger_node()
	if dbg and dbg.has_method(method):
		_undo(dbg, method, args)

func _commit_node_action() -> void:
	_node_action_ur.commit_action()
	_node_action_ur = null

## A child name that's free under parent, numbered the way the editor does
## ("Box" -> "Box2"), so the names sent to a running game are known up front.
func _unique_child_name(parent: Node, base: String, exclude: Node = null) -> String:
	var existing := parent.get_node_or_null(NodePath(base))
	if existing == null or existing == exclude:
		return base
	var stem := base
	var n := 2
	var m := RegEx.create_from_string("^(.*?)(\\d+)$").search(base)
	if m:
		stem = m.get_string(1)
		n = int(m.get_string(2)) + 1
	while true:
		var candidate := "%s%d" % [stem, n]
		var other := parent.get_node_or_null(NodePath(candidate))
		if other == null or other == exclude:
			return candidate
		n += 1
	return base

## Taking a node out of the tree clears its owner (and its descendants'), so
## a moved or restored node would silently drop out of the saved .tscn.
## These record the subtree's owners before an edit and put them back.
## A node with no owner yet gets the scene root.
func _capture_owners(node: Node) -> Array:
	var root := _get_scene_root()
	var pairs := []
	for n in [node] + node.find_children("*", "", true, false):
		var o: Node = n.owner
		if o == null and n == node:
			o = root
		pairs.append([n, o])
	return pairs

func _apply_owners(pairs: Array) -> void:
	for pair in pairs:
		if is_instance_valid(pair[0]):
			pair[0].owner = pair[1]

func _rel_path(node: Node) -> String:
	var root := _get_scene_root()
	if root == null or node == root:
		return "."
	return String(root.get_path_to(node))

## A value string prefixed "load:" is loaded from disk via load() instead of
## parsed by str_to_var() — needed for textures/resources that only exist as
## files, since str_to_var() can't construct arbitrary resource references
## from a bare res:// path the way it can for e.g. Vector2/Color literals.
##
## Takes a Variant, not a String, and normalizes via str() rather than the
## String() constructor. Every param value here is documented as a
## var_to_str()-encoded string, but a caller can easily send raw JSON
## instead (an Array for a Vector, a Dictionary for a Color) — that arrives
## here as a genuine Array/Dictionary, not a String, and String(Array) is a
## hard runtime error ("Invalid arguments to construct 'String'"), confirmed
## live via eval_expression, unlike str(Array) which stringifies anything
## without erroring. That crash was the actual root cause of tool calls
## reporting ok:true while silently leaving properties at their default
## (found live 2026-09-22, see _apply_properties): GDScript's non-fatal
## script-error handling let execution continue past it as null, which
## then set the target property to null and got silently dropped by
## Object.set(). str() first means str_to_var() gets valid syntax to parse
## (correctly, if oddly-typed — e.g. an Array where a Vector2 was wanted)
## instead of crashing before _apply_properties' own mismatch check ever
## runs.
func _decode_value(raw_value):
	var value_str := str(raw_value)
	if value_str.begins_with("load:"):
		return load(value_str.substr(5))
	var value = str_to_var(value_str)
	# str_to_var only takes Godot's stored form, e.g. Color with all four
	# components; a constructor call like "Color(0.2, 0.4, 0.9)" comes back
	# null. Evaluate those as an expression instead.
	if value == null and value_str.strip_edges() != "null" \
			and RegEx.create_from_string("^\\s*[A-Z][A-Za-z0-9]*\\(.*\\)\\s*$").search(value_str):
		var expr := Expression.new()
		if expr.parse(value_str) == OK:
			var evaluated = expr.execute([], null, false)
			if not expr.has_execute_failed():
				return evaluated
	return value

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

## Type-aware equality for _apply_properties' post-commit verification.
## Two issues found live, in this order, while chasing what looked like a
## "set_physics_material corrupts the object" bug that turned out to be
## this check's own false positive:
##   1. GDScript's != throws "Invalid operands" comparing incompatible
##      types (e.g. Vector2 != Array) instead of returning true, and since
##      that's a non-fatal script error, execution continues past it
##      treating the whole condition as false — silently skipping
##      detection. Callers must check typeof() equality first, before ever
##      reaching this function.
##   2. Real float-precision false positive, confirmed live:
##      PhysicsMaterial.bounce stores as real_t (float32 in a standard
##      build); GDScript's own float literals/str_to_var() results are
##      always 64-bit doubles. Setting bounce = 0.9 (a double) rounds to
##      the nearest float32 on the way in, so reading it back and
##      comparing to the original double 0.9 with == is false even though
##      both print as "0.9" — a real, legitimate value that this
##      function's own strict-equality predecessor was about to report as
##      "did not match what was requested".
## is_equal_approx() (global function for float, instance method for the
## vector/color types below) fixes both — but note it does NOT exist for
## every Variant type (confirmed live: calling .has_method("is_equal_approx")
## on a Vector3 is a compile-time error, since built-in math types aren't
## Objects; calling .is_equal_approx() directly works, but only for the
## types it's actually defined on). Scoped here to the specific types
## verified live and actually used as tool params in this codebase
## (float/Vector2/Vector3/Color cover the overwhelming majority) rather
## than guessing at the full Variant type list and risking a runtime
## "Invalid call" on some untested type silently passing the same way (1)
## did — everything else falls back to plain ==, unchanged from before.
## Whether a property read back after a set holds what was requested.
## Godot converts int <-> float on assignment, so "66" (decoded as an int)
## that reads back as 66.0 from a float property like offset_top did take —
## a strict type comparison reported those as failures after they'd been
## committed (seen in real use on Control offsets).
func _value_took(actual, requested) -> bool:
	var numeric := [TYPE_INT, TYPE_FLOAT]
	if typeof(actual) in numeric and typeof(requested) in numeric:
		return is_equal_approx(float(actual), float(requested))
	return typeof(actual) == typeof(requested) and _values_approximately_equal(actual, requested)

func _values_approximately_equal(actual, requested) -> bool:
	match typeof(actual):
		TYPE_FLOAT:
			return is_equal_approx(actual, requested)
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR:
			return actual.is_equal_approx(requested)
		_:
			return actual == requested

## Sets each property via Object.set() (through _commit_properties, so it's
## undo/dirty-tracked). Object.set() silently no-ops on an unknown name (no
## error), so this validates every name against obj.get_property_list()
## FIRST and applies nothing at all if any are unknown — atomic, rather
## than partially applying the valid ones before reporting failure.
##
## Object.set() ALSO silently no-ops when the decoded value's type doesn't
## match the property's declared type — e.g. a caller sends the documented
## var_to_str() string ("Vector2(40, 40)") but the tool schema is easy to
## misread as plain JSON, so a raw array/object ([40, 40], {"x":40,"y":40})
## decodes via str_to_var() into an Array/Dictionary instead of a Vector2,
## and the property is silently left at its default while the tool still
## reports ok:true. Found live (2026-09-22) via a peer agent's real tool
## calls — add_mesh_instance, set_nested_property, set_material_3d, and
## setup_collision all returned ok while the property stayed untouched.
## Same failure class as the set_transform rotation no-op fixed in
## 90e4bd1, but that fix only covered one property on one tool; this
## closes it for every tool that goes through this shared helper (see the
## _apply_properties call sites throughout this file). Read every
## property back after commit and compare against what was requested,
## rather than trying to predict which conversions Object.set() accepts —
## note this can theoretically false-positive if a property's own setter
## legitimately clamps/normalizes the value it's given, which is an
## acceptable tradeoff for loud-failure-over-silent-corruption here.
##
## Returns "" on success, or a ready-to-use error message describing
## either unknown property names or the properties that didn't take.
func _apply_properties(obj: Object, props: Dictionary) -> String:
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
		to_apply[name_str] = _decode_value(props[prop_name])
	if not unknown.is_empty():
		return "unknown %s propert%s: %s" % [
			obj.get_class(), "y" if unknown.size() == 1 else "ies", ", ".join(unknown)
		]

	_commit_properties(obj, to_apply)

	var mismatched := []
	for name_str in to_apply:
		var actual = obj.get(name_str)
		var requested = to_apply[name_str]
		if not _value_took(actual, requested):
			mismatched.append("%s (requested %s, property is a %s — check the var_to_str() encoding, e.g. \"Vector2(1, 2)\" not a JSON array/object)" % [
				name_str, var_to_str(requested), type_string(typeof(actual))
			])
	if not mismatched.is_empty():
		return "failed to set %s propert%s — value written did not match what was requested: %s" % [
			obj.get_class(), "y" if mismatched.size() == 1 else "ies", "; ".join(mismatched)
		]

	return ""

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
	# With no scene open, a root-level eval still runs (against the bridge
	# itself), so singletons like EditorInterface can open or create one.
	if node == null and (node_path == "" or node_path == ".") and _get_scene_root() == null:
		node = self
	if node == null:
		return _fail("node not found: %s" % node_path)

	var input_names: Array = _SINGLETON_NAMES.duplicate()
	var input_values: Array = [ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader, ResourceSaver]
	for key_name in _KEY_CONSTANTS:
		input_names.append(key_name)
		input_values.append(_KEY_CONSTANTS[key_name])
	if Engine.is_editor_hint():
		input_names.append("EditorInterface")
		input_values.append(EditorInterface)

	var statement_hint := _eval_statement_hint(expr_src)
	if statement_hint != "":
		return _fail(statement_hint)

	var expr := Expression.new()
	var parse_err := expr.parse(expr_src, input_names)
	if parse_err != OK:
		return _fail("parse error: %s" % expr.get_error_text())

	var value = expr.execute(input_values, node, true)
	if expr.has_execute_failed():
		return _fail("execute error: %s%s" % [expr.get_error_text(), _eval_named_index_hint(expr.get_error_text())])

	return {"value": var_to_str(value)}

## Expression takes a single expression. Statements used to come back as
## "Invalid named index 'var' for base type Object" or "Expected '='",
## which doesn't say what went wrong or where to go instead (seen in real
## use, several times). Returns "" when src looks like an expression.
func _eval_statement_hint(src: String) -> String:
	var stripped := RegEx.create_from_string("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'").sub(src, "\"\"", true)
	var is_statement := RegEx.create_from_string("^\\s*(var|const|for|while|if|match|return|await)\\b").search(stripped) != null \
			or stripped.contains(";") \
			or RegEx.create_from_string("[^=!<>+\\-*/%&|^]=[^=]").search(stripped) != null
	if not is_statement:
		return ""
	return "eval_expression takes one expression, not statements (var, loops, `;`, `=` assignment). Use run_script for statements, or set_property / set_nested_property to change a value (undoable, and reaches a running game)."

## "Invalid named index 'x' for base type Object" is what Expression says
## both for a name that isn't in scope (only the singletons it was given
## are) and for `.x` read off a null — a find_child() that found nothing, an
## unset material or override. Real use hit both and retried blind. Checked
## live on 4.7: chained reads off a non-null call result work fine.
func _eval_named_index_hint(error_text: String) -> String:
	var m := RegEx.create_from_string("Invalid named index '([^']+)' for base type Object").search(error_text)
	if m == null:
		return ""
	var index_name := m.get_string(1)
	var first := index_name.substr(0, 1)
	if first == first.to_upper() and first != "_":
		return " — %s isn't available inside Expression (only the built-in singletons are); use run_script" % index_name
	return " — the value `.%s` was read from is null (a lookup that found nothing, or an unset property)" % index_name

## eval_expression's Expression class can only parse a single statement — no
## var declarations, no loops, no `;`-chained assignments. This runs actual
## GDScript source as a compiled function body instead, for anything that
## genuinely needs multiple statements. `source` becomes the body of
## `func _run(node):`, so it can reference the target node as `node` and
## must end with its own `return` statement — there's no implicit return of
## the last expression like eval_expression has.
func _cmd_run_script(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var source := String(params.get("source", ""))
	if source.strip_edges() == "":
		return _fail("source is required")
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var run := _run_source(node, source)
	if run[0] != "":
		return _fail(run[0])
	return {"value": var_to_str(run[1])}

## Compiles `source` as the body of func _run(node) and calls it.
## Returns [error_message_or_empty, value].
func _run_source(node: Node, source: String) -> Array:
	var lines := source.split("\n")
	# Indent the body with the same character the caller indented with: a
	# tab in front of space-indented lines is "mixed tabs and spaces", a
	# compile error the caller never wrote (seen in real use).
	var unit := "\t"
	for line in lines:
		if line.begins_with(" "):
			unit = "    "
			break
		if line.begins_with("\t"):
			break
	var indented := ""
	for line in lines:
		indented += unit + line + "\n"
	var script := GDScript.new()
	# @tool, so a parse error is reported with its message — see _compile_script.
	script.source_code = "@tool\nextends RefCounted\nfunc _run(node):\n%s" % indented
	var compile_error := _compile_script(script, 3)
	if compile_error != "":
		return ["script compile error: %s (the body runs inside func _run(node) on a RefCounted, so reach the scene through `node`, e.g. node.get_tree())" % compile_error, null]
	var runner = script.new()
	if not (runner is RefCounted and runner.has_method("_run")):
		return ["internal error: compiled script has no _run() method", null]
	return ["", runner.call("_run", node)]

## Compiles `script` and returns "" on success, or the parser's own messages
## with line numbers counted from the caller's first line (`line_offset` is
## how many wrapper lines come before it). GDScript.reload() only returns an
## error code — before this, run_script and validate_script answered every
## mistake with "code 43", leaving the caller to guess. The message goes to
## the Output panel instead, and only for a script that may run in the
## editor (@tool), so it's read back from the in-memory log capture.
func _compile_script(script: GDScript, line_offset: int) -> String:
	var since: int = _output_capture.last_seq() if _output_capture else 0
	var err := script.reload()
	if err == OK:
		return ""
	var messages := []
	if _output_capture:
		for entry in _output_capture.read(since, true, 20).entries:
			var text: String = entry.text
			if text.begins_with("Parse Error: "):
				text = text.substr(13)
			var line_match := RegEx.create_from_string(":(\\d+) @").search(String(entry.get("where", "")))
			if line_match:
				text = "line %d: %s" % [int(line_match.get_string(1)) - line_offset, text]
			messages.append(text)
	if messages.is_empty():
		return "error code %d, no message reported (check the editor's Output panel)" % err
	return "; ".join(messages)

## Different property values on many nodes as ONE undoable action (one
## Ctrl+Z), live-synced to a running game like any property edit. Everything
## is validated before anything changes. For the same values on every node
## matching a filter, batch_set_properties is simpler.
func _cmd_set_properties_multi(params: Dictionary):
	var edits: Array = params.get("edits", [])
	if edits.is_empty():
		return _fail("edits is required: [{node_path, properties}, ...]")
	var planned := []  # [node, {name: decoded value}]
	for edit in edits:
		if typeof(edit) != TYPE_DICTIONARY:
			return _fail("each edit must be {node_path, properties}")
		var node_path := String(edit.get("node_path", ""))
		var node := _resolve_node(node_path)
		if node == null:
			return _fail("node not found: %s (nothing was changed)" % node_path)
		var valid := {}
		for p in node.get_property_list():
			valid[p.name] = true
		var decoded := {}
		var props: Dictionary = edit.get("properties", {})
		for prop_name in props:
			var name_str := String(prop_name)
			if not valid.has(name_str):
				return _fail("unknown %s property on %s: %s (nothing was changed)" % [node.get_class(), node_path, name_str])
			decoded[name_str] = _decode_value(props[prop_name])
		planned.append([node, decoded])

	if _editor_plugin:
		var ur := _editor_plugin.get_undo_redo()
		ur.create_action("GodotLiveMCP: set properties on %d nodes" % planned.size(), UndoRedo.MERGE_DISABLE, _get_scene_root())
		for item in planned:
			for name_str in item[1]:
				ur.add_do_property(item[0], name_str, item[1][name_str])
				ur.add_undo_property(item[0], name_str, item[0].get(name_str))
		ur.commit_action()
	else:
		for item in planned:
			for name_str in item[1]:
				item[0].set(name_str, item[1][name_str])

	var mismatched := []
	for item in planned:
		for name_str in item[1]:
			var actual = item[0].get(name_str)
			var requested = item[1][name_str]
			if not _value_took(actual, requested):
				mismatched.append("%s.%s (requested %s, property is a %s)" % [
					_rel_path(item[0]), name_str, var_to_str(requested), type_string(typeof(actual))])
	if not mismatched.is_empty():
		return _fail("values didn't take — check the var_to_str() encoding: %s" % "; ".join(mismatched))
	return {"ok": true, "nodes": planned.size()}

## Runs a GDScript body that builds an Image or a Resource and saves it as a
## file (Image -> .png/.jpg/.webp, Resource -> .tres/.res), registered with
## the editor. Files, unlike in-memory resources, can be sent to a running
## game: assign the result with "load:<path>" via set_property etc.
func _cmd_save_resource_file(params: Dictionary):
	var path := String(params.get("path", ""))
	var source := String(params.get("source", ""))
	if not path.begins_with("res://"):
		return _fail("path must be a res:// path")
	if source.strip_edges() == "":
		return _fail("source is required: a GDScript body that returns an Image or Resource")
	var run := _run_source(_get_scene_root(), source)
	if run[0] != "":
		return _fail(run[0])
	var value = run[1]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var ext := path.get_extension().to_lower()
	var err := OK
	if value is Image:
		match ext:
			"png": err = (value as Image).save_png(path)
			"jpg", "jpeg": err = (value as Image).save_jpg(path)
			"webp": err = (value as Image).save_webp(path)
			_: return _fail("an Image must be saved as .png, .jpg or .webp")
	elif value is Resource:
		if not ext in ["tres", "res"]:
			return _fail("a Resource must be saved as .tres or .res")
		err = ResourceSaver.save(value, path)
	else:
		return _fail("source must return an Image or a Resource (got %s)" % type_string(typeof(value)))
	if err != OK:
		return _fail("saving %s failed (error %d)" % [path, err])
	var fs := EditorInterface.get_resource_filesystem()
	if value is Image:
		# Images need importing before load() returns a texture. A scan picks
		# up new files and folders (update_file alone misses a new folder);
		# then import, and wait (up to ~5 s) so "load:<path>" works as soon
		# as this returns.
		fs.scan()
		var imported := false
		for i in 300:
			await get_tree().process_frame
			if fs.is_scanning():
				continue
			if ResourceLoader.exists(path) and load(path) != null:
				break
			if not imported:
				fs.reimport_files(PackedStringArray([path]))
				imported = true
	else:
		fs.update_file(path)
		if load(path) == null:
			return _fail("saved %s but Godot hasn't imported it yet — try assigning it again shortly" % path)
	return {"ok": true, "path": path, "assign_with": "load:%s" % path}

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

## node_paths reads several nodes in one call, and properties narrows what
## comes back — real use read 5-25 nodes one call at a time, each returning
## every property, several times in one session (the read-side counterpart
## to set_properties_multi).
func _cmd_get_node_properties(params: Dictionary):
	var wanted: Array = params.get("properties", [])
	var node_paths: Array = params.get("node_paths", [])
	if node_paths.is_empty():
		var node_path := String(params.get("node_path", "."))
		var node := _resolve_node(node_path)
		if node == null:
			return _fail("node not found: %s" % node_path)
		var single := _node_properties(node, wanted)
		if not wanted.is_empty() and single.is_empty():
			return _fail("%s has none of these properties: %s" % [node.get_class(), ", ".join(wanted)])
		return single

	var nodes := {}
	var not_found := []
	var any_matched := false
	for path in node_paths:
		var node := _resolve_node(String(path))
		if node == null:
			not_found.append(String(path))
			continue
		var props := _node_properties(node, wanted)
		any_matched = any_matched or not props.is_empty()
		nodes[String(path)] = props
	if nodes.is_empty():
		return _fail("none of these nodes were found: %s" % ", ".join(not_found))
	if not wanted.is_empty() and not any_matched:
		return _fail("none of the nodes have any of these properties: %s" % ", ".join(wanted))
	var result := {"nodes": nodes}
	if not not_found.is_empty():
		result["not_found"] = not_found
	return result

## Every editor-visible property of node (or just the `wanted` names it
## has), var_to_str()-encoded.
func _node_properties(node: Node, wanted: Array) -> Dictionary:
	var props := {}
	for prop in node.get_property_list():
		if prop.usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		var prop_name: String = prop.name
		props[prop_name] = var_to_str(node.get(prop_name))

	# position/rotation/scale above are LOCAL (relative to the parent) —
	# real properties (already settable via set_property/eval_expression)
	# but not flagged PROPERTY_USAGE_EDITOR, so they never appeared in this
	# dump at all. World-space values matter more for an agent reasoning
	# about where something actually is, especially under nested parents,
	# so add them explicitly rather than relying on the editor-visibility
	# flag Godot uses for its own inspector UI curation.
	if node is Node2D:
		props["global_position"] = var_to_str(node.global_position)
		props["global_rotation"] = var_to_str(node.global_rotation)
		props["global_scale"] = var_to_str(node.global_scale)
	elif node is Node3D:
		props["global_position"] = var_to_str(node.global_position)
		props["global_rotation"] = var_to_str(node.global_rotation)
		props["global_transform"] = var_to_str(node.global_transform)

	if wanted.is_empty():
		return props
	var picked := {}
	for prop_name in wanted:
		var name_str := String(prop_name)
		if props.has(name_str):
			picked[name_str] = props[name_str]
		elif name_str in node:
			picked[name_str] = var_to_str(node.get(name_str))
	return picked

## Opens a scene in the editor, or switches to its tab if it's already open.
## Real use reached for EditorInterface.open_scene_from_path() through
## eval_expression after the edited scene had changed under it — which was
## also flagged as a raw scene edit, since the fingerprint changed.
func _cmd_open_scene(params: Dictionary):
	var path := String(params.get("path", ""))
	if not path.begins_with("res://"):
		return _fail("path must be a res:// path: %s" % path)
	if not ResourceLoader.exists(path):
		return _fail("no such scene: %s" % path)
	if not ResourceLoader.load(path) is PackedScene:
		return _fail("not a scene: %s" % path)
	EditorInterface.open_scene_from_path(path)
	await get_tree().process_frame
	var root := _get_scene_root()
	if root == null or root.scene_file_path != path:
		return _fail("the editor didn't switch to %s (edited scene is %s)" % [path, _edited_scene_label()])
	return {"scene": path, "root": root.name, "root_type": root.get_class(), "open_scenes": Array(EditorInterface.get_open_scenes())}

func _cmd_set_property(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var prop_name := String(params.get("property_name", ""))
	var value_str := str(params.get("value", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if prop_name == "":
		return _fail("property_name is required")

	var apply_err := _apply_properties(node, {prop_name: value_str})
	if apply_err != "":
		return _fail(apply_err)
	return {"value": var_to_str(node.get(prop_name))}

func _cmd_set_properties(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var properties: Dictionary = params.get("properties", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var apply_err := _apply_properties(node, properties)
	if apply_err != "":
		return _fail(apply_err)

	var result := {}
	for prop_name in properties:
		var name_str := String(prop_name)
		result[name_str] = var_to_str(node.get(name_str))
	return result

func _is_indexable_container(value) -> bool:
	return typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_DICTIONARY

## Reads `key` out of an Array (parsed as an integer index) or Dictionary
## (used as a literal string key). Returns [ok, value, error_message].
func _container_get(container, key: String) -> Array:
	if container is Array:
		if not key.is_valid_int():
			return [false, null, "array index must be an integer: %s" % key]
		var idx := int(key)
		if idx < 0 or idx >= container.size():
			return [false, null, "array index out of range: %d (size %d)" % [idx, container.size()]]
		return [true, container[idx], ""]
	# Dictionary
	if not container.has(key):
		return [false, null, "dictionary has no key: %s" % key]
	return [true, container[key], ""]

## Sets a property reached through a colon-separated path (e.g.
## "material_override:albedo_color", or "items:0:color" through an Array,
## or "presets:default:radius" through a Dictionary), the same shape the
## editor inspector's own revert-arrow UI uses for sub-resource properties.
## Object.set() treats a colon-path as a single literal property name,
## which either fails as "unknown" (now caught) or — before that
## validation existed — silently zeroed the top-level property instead of
## touching the sub-property.
##
## Root cause found live (after three failed attempts across a full
## session): Godot returns an @export'd Array/Dictionary property via
## Object.get() as READ-ONLY (confirmed: items.is_read_only() == true even
## though var_to_str() prints it normally and a PURELY LOCAL Array/
## Dictionary is never read-only) — mutating it directly throws a runtime
## error that our own dispatcher can't distinguish from a legitimate null
## return (a real gap in _handle_line, noted but not fixed here), which is
## why every earlier attempt silently no-oped no matter how the UndoRedo
## side was wired. The fix: duplicate the top-level Array/Dictionary
## (.duplicate(true), confirmed live to produce a genuinely mutable copy),
## replay the same path segments through the duplicate to reach the
## corresponding mutable nested container, mutate THAT, and commit the
## whole duplicate back through the standard add_do_property/
## add_undo_property path — never mutate the original read-only reference.
## Object-typed intermediates (Resources) don't have this problem — those
## are still walked and mutated via the existing validated
## _apply_properties path, unchanged.
func _cmd_set_nested_property(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var property_path := String(params.get("property_path", ""))
	var value_str := str(params.get("value", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if property_path == "":
		return _fail("property_path is required")

	var parts := property_path.split(":")
	if parts.size() < 2:
		return _fail('property_path must contain at least one ":" (e.g. "material_override:albedo_color" or "items:0:color")')

	var obj = node
	var resolved_path := node_path
	var owner: Object = node
	var owner_prop := ""
	var container_start := -1
	for i in range(parts.size() - 1):
		var seg := parts[i]
		var next
		if obj is Object:
			var valid_names := {}
			for p in obj.get_property_list():
				valid_names[p.name] = true
			if not valid_names.has(seg):
				return _fail("unknown property: %s (in path %s)" % [seg, property_path])
			next = obj.get(seg)
			owner = obj
			owner_prop = seg
			container_start = i + 1
		elif _is_indexable_container(obj):
			var res := _container_get(obj, seg)
			if not res[0]:
				return _fail("%s (in path %s)" % [res[2], property_path])
			next = res[1]
		else:
			return _fail("%s is a %s value — can't index into it (only Object properties, Array indices, and Dictionary keys are supported)" % [resolved_path, type_string(typeof(obj))])
		resolved_path += ":" + seg
		if next == null:
			return _fail("%s is null — assign/create it first (e.g. via set_resource_property) before setting a nested property on it" % resolved_path)
		if not (next is Object or _is_indexable_container(next)):
			return _fail("%s is a %s value, not an Object/Array/Dictionary — nested set only works through those container types" % [resolved_path, type_string(typeof(next))])
		obj = next

	var last := parts[parts.size() - 1]
	if obj is Object:
		var apply_err := _apply_properties(obj, {last: value_str})
		if apply_err != "":
			return _fail(apply_err)
		return {"value": var_to_str(obj.get(last))}

	# obj is an Array/Dictionary reached through owner.owner_prop, possibly
	# read-only — duplicate the top-level container and replay the
	# container-only segments (container_start .. second-to-last) through
	# the duplicate to find the mutable counterpart of `obj`.
	var old_top = owner.get(owner_prop)
	var new_top = old_top.duplicate(true)
	var mutable_target = new_top
	for i in range(container_start, parts.size() - 1):
		var seg = parts[i]
		if mutable_target is Array:
			mutable_target = mutable_target[int(seg)]
		else:
			mutable_target = mutable_target[seg]

	var decoded = _decode_value(value_str)
	if mutable_target is Array:
		if not last.is_valid_int():
			return _fail("array index must be an integer: %s (on %s)" % [last, resolved_path])
		var idx := int(last)
		if idx < 0 or idx >= mutable_target.size():
			return _fail("array index out of range: %d (size %d, on %s)" % [idx, mutable_target.size(), resolved_path])
		mutable_target[idx] = decoded
	else:
		# Dictionary — assigning a new key is always valid, unlike
		# Object.set()'s unknown-property landmine, so no existence check
		# is needed before writing.
		mutable_target[last] = decoded

	_commit_properties(owner, {owner_prop: new_top})

	if mutable_target is Array:
		return {"value": var_to_str(mutable_target[int(last)])}
	return {"value": var_to_str(mutable_target[last])}

## Generic resource-property setter: instantiates a fresh Resource of any
## class by name, applies properties to it through the same validated path
## as every other resource tool, and assigns it to a node property. This is
## the generalized version of the ad hoc pattern used by
## set_theme_stylebox_override/set_shader_material/set_physics_material/
## setup_environment (each hardcoded to one resource type) — covers any
## Resource subclass without a dedicated tool. Reuses the node's existing
## resource in place (rather than replacing it) when it's already the
## requested type, matching those tools' behavior.
## Result entry for a tool that just created a new resource (material, mesh,
## shape...) while a game is running. A new in-memory resource has no file
## path, so Godot can't send it to the game (true for Inspector edits too);
## it appears on the next Play. Later edits to it do sync once it's saved.
func _with_live_note(result: Dictionary, created_new: bool) -> Dictionary:
	if created_new and EditorInterface.is_playing_scene():
		result["live_note"] = ("A new resource was created, and new resources can't be sent to a " +
			"running game (same as in the Inspector) — this change appears on the next Play. " +
			"Tell the user; to show it live, save it as a .tres/.png file and assign it with " +
			"\"load:res://...\" instead.")
	return result

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
	var created_new := false
	if reuse_existing and current != null and current.get_class() == resource_type:
		res = current
	else:
		res = ClassDB.instantiate(resource_type)
		created_new = true

	var apply_err := _apply_properties(res, resource_params)
	if apply_err != "":
		return _fail(apply_err)

	_commit_properties(node, {property_name: res})
	return _with_live_note({"ok": true, "resource_type": res.get_class(), "resource": _read_back(res, resource_params.keys())}, created_new)

func _cmd_set_transform(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is Node2D or node is Node3D):
		return _fail("node is not a Node2D or Node3D: %s" % node_path)

	var values := {}
	if params.has("position"):
		values["position"] = _decode_value(params["position"])
	if params.has("rotation"):
		var rotation_value = _decode_value(params["rotation"])
		if node is Node3D:
			if rotation_value is Vector3:
				values["rotation"] = rotation_value
			else:
				return _fail("rotation must be a Vector3 for a Node3D (got: %s)" % params["rotation"])
		else:
			if rotation_value is float or rotation_value is int:
				values["rotation"] = float(rotation_value)
			else:
				return _fail("rotation must be a float for a Node2D (got: %s)" % params["rotation"])
	if params.has("scale"):
		values["scale"] = _decode_value(params["scale"])
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
	_commit_properties(node, {"script": script})
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
	# @tool so the parser reports its message (see _compile_script); a
	# script that already has it would fail on a second one.
	var has_tool := RegEx.create_from_string("(?m)^@tool\\b").search(source) != null
	scr.source_code = source if has_tool else "@tool\n" + source
	var compile_error := _compile_script(scr, 0 if has_tool else 1)
	if compile_error != "":
		return _fail("parse failed: %s" % compile_error)
	return {"ok": true}

## Replaces a script's or shader's text the way a person would: opens it in
## Godot's own script/shader editor and swaps the text inside that editor's
## CodeEdit as one undoable edit. The tab is left unsaved, so nothing hits
## disk (and no "reload from disk?" prompt fires) until Ctrl+S or Play. A
## file that doesn't exist yet is created on disk first, like the editor's
## own New Script dialog does.
func _cmd_edit_script_text(params: Dictionary):
	var path := String(params.get("path", ""))
	var text := String(params.get("text", ""))
	if not path.begins_with("res://"):
		return _fail("path must be a res:// path: %s" % path)
	if params.has("old_text") or params.has("new_text"):
		# Partial edit: replace exactly one occurrence in the current text
		# (the open tab's, including unsaved edits), then carry on as a
		# full replacement with the result.
		if params.has("text"):
			return _fail("give either text, or old_text and new_text — not both")
		if not (params.has("old_text") and params.has("new_text")):
			return _fail("old_text and new_text go together")
		var old_text := String(params.old_text)
		if old_text.is_empty():
			return _fail("old_text is empty")
		var current = _cmd_get_script_text({"path": path})
		if current.has("__error__"):
			return current
		var found := String(current.text).count(old_text)
		if found == 0:
			return _fail("old_text not found in %s — it must match the current text exactly, whitespace included" % path)
		if found > 1:
			return _fail("old_text appears %d times in %s — include more surrounding lines so it matches once" % [found, path])
		text = String(current.text).replace(old_text, String(params.new_text))
	elif not params.has("text"):
		return _fail("give text (the whole file), or old_text and new_text (a partial edit)")
	var created := false
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return _fail("could not create %s (error %d)" % [path, FileAccess.get_open_error()])
		f.store_string(text)
		f.close()
		EditorInterface.get_resource_filesystem().update_file(path)
		created = true
	var res := load(path)
	if res == null:
		return _fail("could not load %s" % path)
	var code_edit := await _open_code_editor(res)
	if code_edit == null:
		return _fail("could not find the editor for %s (only scripts and shaders are supported)" % path)
	# Also for a new file: a tab for a since-deleted file of the same name
	# can still be open with stale text.
	if code_edit.text != text:
		code_edit.begin_complex_operation()
		code_edit.select_all()
		code_edit.delete_selection()
		code_edit.insert_text_at_caret(text)
		code_edit.end_complex_operation()
		code_edit.set_caret_line(0)
		code_edit.text_changed.emit()
	if EditorInterface.is_playing_scene() and res is Script:
		# With a game running, save straight away (like a person pressing
		# Ctrl+S) and have the game reload it, so the change shows up live.
		# edit_script() above made this script the current tab.
		if not _press_script_editor_save():
			var scr := res as Script
			scr.source_code = text
			var err := ResourceSaver.save(scr, path)
			if err != OK:
				return _fail("could not save %s (error %d)" % [path, err])
		_reload_game_scripts()
		return {"ok": true, "created": created, "unsaved": false,
			"note": "Saved right away and reloaded in the running game."}
	return {"ok": true, "created": created, "unsaved": not created,
		"note": _mac_keys("Saved on Ctrl+S or when the scene is played.") if not created else "New file written to disk."}

## Reads a script's or shader's current text, including unsaved edits in an
## open editor tab (the file on disk can be older than what's on screen).
func _cmd_get_script_text(params: Dictionary):
	var path := String(params.get("path", ""))
	if not ResourceLoader.exists(path):
		return _fail("not found: %s" % path)
	var res := load(path)
	var code_edit := _find_open_code_editor(res)
	if code_edit:
		return {"ok": true, "text": code_edit.text, "source": "editor"}
	if res is Script:
		return {"ok": true, "text": (res as Script).source_code, "source": "file"}
	if res is Shader:
		return {"ok": true, "text": (res as Shader).code, "source": "file"}
	return _fail("%s is not a script or shader" % path)

# Shader path -> the shader editor's CodeEdit for it. The shader editor has no
# public API to reach its text box, so it's found by matching the shader's
# code once and remembered, since that match stops working after an edit.
var _shader_code_edits := {}

func _open_code_editor(res: Resource) -> CodeEdit:
	if res is Script:
		EditorInterface.edit_script(res as Script)
	elif res is Shader:
		EditorInterface.edit_resource(res)
		# The shader editor builds its tab over the next frames.
		for i in 3:
			await get_tree().process_frame
	else:
		return null
	return _find_open_code_editor(res)

func _find_open_code_editor(res: Resource) -> CodeEdit:
	if res is Script:
		var se := EditorInterface.get_script_editor()
		var scripts := se.get_open_scripts()
		var editors := se.get_open_script_editors()
		for i in scripts.size():
			if scripts[i] == res and i < editors.size():
				return editors[i].get_base_editor() as CodeEdit
		return null
	if res is Shader:
		var cached = _shader_code_edits.get(res.resource_path)
		if is_instance_valid(cached) and (cached as Node).is_inside_tree():
			return cached as CodeEdit
		var code := (res as Shader).code
		for node in EditorInterface.get_base_control().find_children("*", "CodeEdit", true, false):
			var ce := node as CodeEdit
			if ce.get_parent().get_class() == "ShaderTextEditor" and ce.text == code:
				_shader_code_edits[res.resource_path] = ce
				return ce
	return null

func _cmd_remove_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if node == _get_scene_root():
		return _fail("cannot remove the scene root")
	var parent := node.get_parent()
	var rel := NodePath(_rel_path(node))
	var parent_rel := NodePath(_rel_path(parent))
	var index := node.get_index()
	if not _begin_node_action("remove node"):
		parent.remove_child(node)
		node.queue_free()
		return {"ok": true}
	# Kept alive (not freed) so undo can put it back, owners and all.
	_do(parent, "remove_child", [node])
	_do_live("live_debug_remove_and_keep_node", [rel, node.get_instance_id()])
	_undo(parent, "add_child", [node])
	_undo(parent, "move_child", [node, index])
	_undo(self, "_apply_owners", [_capture_owners(node)])
	_undo_live("live_debug_restore_node", [node.get_instance_id(), parent_rel, index])
	_node_action_ur.add_undo_reference(node)
	_commit_node_action()
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

	var root := _get_scene_root()
	var old_parent := node.get_parent()
	var old_rel := NodePath(_rel_path(node))
	var old_parent_rel := NodePath(_rel_path(old_parent))
	var old_index := node.get_index()
	var old_name := String(node.name)
	var new_name := _unique_child_name(new_parent, old_name)
	if not _begin_node_action("reparent node"):
		old_parent.remove_child(node)
		node.name = new_name
		new_parent.add_child(node)
		if root:
			_fix_owner_recursive(node, root)
		return {"path": _rel_path(node)}
	_do(old_parent, "remove_child", [node])
	if new_name != old_name:
		_do(node, "set_name", [new_name])
	_do(new_parent, "add_child", [node])
	# Godot's serializer silently drops any node whose owner isn't set —
	# reparenting without this once left moved nodes visible in the editor
	# but missing from the saved .tscn. Restored over the whole subtree.
	var owners := _capture_owners(node)
	_do(self, "_apply_owners", [owners])
	_do_live("live_debug_reparent_node", [old_rel, NodePath(_rel_path(new_parent)), new_name, -1])
	_undo(new_parent, "remove_child", [node])
	if new_name != old_name:
		_undo(node, "set_name", [old_name])
	_undo(old_parent, "add_child", [node])
	_undo(old_parent, "move_child", [node, old_index])
	_undo(self, "_apply_owners", [owners])
	var new_rel := NodePath(String(_rel_path(new_parent)).path_join(new_name) if new_parent != root else new_name)
	_undo_live("live_debug_reparent_node", [new_rel, old_parent_rel, old_name, old_index])
	_commit_node_action()
	return {"path": _rel_path(node)}

func _fix_owner_recursive(node: Node, root: Node) -> void:
	if node != root:
		node.owner = root
	for child in node.get_children():
		_fix_owner_recursive(child, root)

func _cmd_duplicate_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if node == _get_scene_root():
		return _fail("cannot duplicate the scene root")
	var parent := node.get_parent()
	var root := _get_scene_root()
	var dup: Node = node.duplicate()
	dup.name = _unique_child_name(parent, String(node.name))
	if not _begin_node_action("duplicate node"):
		parent.add_child(dup)
		if root:
			_fix_owner_recursive(dup, root)
		return {"path": _rel_path(dup)}
	_do(parent, "add_child", [dup])
	_do(parent, "move_child", [dup, node.get_index() + 1])
	# Same owners as the original: this scene's own nodes are owned by the
	# scene root, an instanced scene's inner nodes by that instance.
	var dup_owners := [[dup, root]]
	for n in node.find_children("*", "", true, false):
		var twin := dup.get_node_or_null(node.get_path_to(n))
		if twin:
			dup_owners.append([twin, dup if n.owner == node else n.owner])
	_do(self, "_apply_owners", [dup_owners])
	_do_live("live_debug_duplicate_node", [NodePath(_rel_path(node)), String(dup.name)])
	_node_action_ur.add_do_reference(dup)
	_undo(parent, "remove_child", [dup])
	var parent_rel := _rel_path(parent)
	_undo_live("live_debug_remove_node", [NodePath(String(dup.name) if parent == root else parent_rel.path_join(String(dup.name)))])
	_commit_node_action()
	return {"path": _rel_path(dup)}

func _cmd_add_node_live(params: Dictionary):
	var parent_path := String(params.get("parent_path", "."))
	var node_type := String(params.get("node_type", ""))
	var scene_path := String(params.get("scene_path", ""))
	var node_name := String(params.get("node_name", ""))
	var parent := _resolve_node(parent_path)
	if parent == null:
		return _fail("parent not found: %s" % parent_path)

	var new_node: Node
	if scene_path != "":
		# An instance of a saved scene, like dragging a .tscn into the tree.
		var packed = load(scene_path) if ResourceLoader.exists(scene_path) else null
		if not packed is PackedScene:
			return _fail("not a scene file: %s" % scene_path)
		new_node = (packed as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	else:
		if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type):
			return _fail("cannot instantiate node type: %s" % node_type)
		new_node = ClassDB.instantiate(node_type)
	if node_name != "":
		new_node.name = node_name
	elif scene_path == "":
		new_node.name = node_type
	new_node.name = _unique_child_name(parent, String(new_node.name))
	var root := _get_scene_root()
	if not _begin_node_action("add node"):
		parent.add_child(new_node)
		if root:
			new_node.owner = root
		return {"path": _rel_path(new_node)}
	_do(parent, "add_child", [new_node])
	# Only the new node itself is owned by this scene; an instanced scene's
	# own children stay owned by it.
	if root:
		_do(new_node, "set_owner", [root])
	var parent_rel := NodePath(_rel_path(parent))
	var new_rel := NodePath(String(new_node.name) if parent == root else String(parent_rel).path_join(String(new_node.name)))
	if scene_path != "":
		_do_live("live_debug_instantiate_node", [parent_rel, scene_path, String(new_node.name)])
	else:
		_do_live("live_debug_create_node", [parent_rel, node_type, String(new_node.name)])
	_node_action_ur.add_do_reference(new_node)
	_undo(parent, "remove_child", [new_node])
	_undo_live("live_debug_remove_node", [new_rel])
	_commit_node_action()
	return {"path": _rel_path(new_node)}

## Adds a freshly made node (its own properties already set) under parent as
## one undoable action, live-synced to a running game — the shared tail of
## add_node_live / setup_collision / add_mesh_instance. The game gets a node
## of the same class; resources created in memory (a new mesh or shape)
## can't be sent to it, so those appear on the next Play.
func _commit_add_node(parent: Node, new_node: Node) -> void:
	if String(new_node.name) == "" or String(new_node.name).begins_with("@"):
		new_node.name = new_node.get_class()
	new_node.name = _unique_child_name(parent, String(new_node.name))
	var root := _get_scene_root()
	if not _begin_node_action("add " + new_node.get_class()):
		parent.add_child(new_node)
		if root:
			new_node.owner = root
		return
	_do(parent, "add_child", [new_node])
	if root:
		_do(new_node, "set_owner", [root])
	var parent_rel := NodePath(_rel_path(parent))
	var new_rel := NodePath(String(new_node.name) if parent == root else String(parent_rel).path_join(String(new_node.name)))
	_do_live("live_debug_create_node", [parent_rel, new_node.get_class(), String(new_node.name)])
	_node_action_ur.add_do_reference(new_node)
	_undo(parent, "remove_child", [new_node])
	_undo_live("live_debug_remove_node", [new_rel])
	_commit_node_action()

func _cmd_rename_node(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var new_name := String(params.get("new_name", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if new_name == "":
		return _fail("new_name is required")
	var old_name := String(node.name)
	if node.get_parent() and node != _get_scene_root():
		new_name = _unique_child_name(node.get_parent(), new_name, node)
	if new_name == old_name:
		return {"path": _rel_path(node)}
	if not _begin_node_action("rename node"):
		node.name = new_name
		return {"path": _rel_path(node)}
	_do(node, "set_name", [new_name])
	_undo(node, "set_name", [old_name])
	if node != _get_scene_root():
		# The editor's own rename is a reparent-in-place under a new name.
		var parent_rel := _rel_path(node.get_parent())
		var at_root := node.get_parent() == _get_scene_root()
		var old_rel := NodePath(old_name if at_root else parent_rel.path_join(old_name))
		var renamed_rel := NodePath(new_name if at_root else parent_rel.path_join(new_name))
		_do_live("live_debug_reparent_node", [old_rel, NodePath(parent_rel), new_name, -1])
		_undo_live("live_debug_reparent_node", [renamed_rel, NodePath(parent_rel), old_name, -1])
	_commit_node_action()
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
	# CONNECT_PERSIST is what the editor's own Node > Signals dock uses; without
	# it the connection works live but is never saved to the .tscn.
	if _begin_node_action("connect signal"):
		_do(node, "connect", [signal_name, callable, CONNECT_PERSIST])
		_undo(node, "disconnect", [signal_name, callable])
		_commit_node_action()
	else:
		node.connect(signal_name, callable, CONNECT_PERSIST)
	if not node.is_connected(signal_name, callable):
		return _fail("connect failed")
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
	var flags := 0
	for c in node.get_signal_connection_list(signal_name):
		if c.callable == callable:
			flags = c.flags
	if _begin_node_action("disconnect signal"):
		_do(node, "disconnect", [signal_name, callable])
		_undo(node, "connect", [signal_name, callable, flags])
		_commit_node_action()
	else:
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
	var old_groups := []
	for g in node.get_groups():
		if not String(g).begins_with("_"):
			old_groups.append(String(g))
	# persistent = true, as the editor's Groups dock does, so they're saved.
	if _begin_node_action("set node groups"):
		for g in old_groups:
			_do(node, "remove_from_group", [g])
		for g in new_groups:
			_do(node, "add_to_group", [String(g), true])
		for g in new_groups:
			_undo(node, "remove_from_group", [String(g)])
		for g in old_groups:
			_undo(node, "add_to_group", [g, true])
		_commit_node_action()
	else:
		for g in old_groups:
			node.remove_from_group(g)
		for g in new_groups:
			node.add_to_group(String(g), true)
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
## bridge.gd code can take effect without a manual reload. First forces a
## filesystem rescan (EditorInterface.get_resource_filesystem().scan()) —
## confirmed live: without this, the plugin toggle alone would keep running
## whatever version of bridge.gd Godot had already compiled, and picking up
## an edited script otherwise required the user to click into the editor
## window (which triggers Godot's own external-change scan on focus-in).
## scan() plus a short delay for it to complete does the same thing
## programmatically, so bridge.gd changes no longer need any manual step at
## all. Deferred to the next idle frame: disabling frees `self` via
## stop()+queue_free() inside plugin.gd's _exit_tree(), and queue_free()
## only marks the object for deletion at end-of-frame, so it's safe to keep
## running (including the re-enable call) for the rest of this call — but
## not safe to run synchronously inside the request handler that's still
## using this same peer/socket. The response is sent before the reload
## actually happens, so the calling client should expect the connection to
## drop and reconnect.
func _cmd_reload_plugin(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("reload_plugin is only available inside the editor")
	call_deferred("_do_reload_plugin")
	return {"ok": true, "note": "rescanning + reloading plugin — the connection will drop; reconnect after a moment"}

func _do_reload_plugin() -> void:
	EditorInterface.get_resource_filesystem().scan()
	await get_tree().create_timer(0.5).timeout
	EditorInterface.set_plugin_enabled(PLUGIN_ADDON_NAME, false)
	EditorInterface.set_plugin_enabled(PLUGIN_ADDON_NAME, true)

## Restarts the WHOLE editor process (EditorInterface.restart_editor()) —
## closes Godot and reopens the same project, distinct from reload_plugin
## (which only re-toggles this one plugin) and from a filesystem rescan.
## This is what a boot-only project setting (e.g. debug/file_logging) or
## stubborn cached state actually needs — the kind of restart that, before
## this, required the user to manually close and reopen the editor.
## Deferred for the same reason as reload_plugin: let this response reach
## the caller before the process starts tearing itself down.
func _cmd_restart_editor(params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("restart_editor is only available inside the editor")
	var save := bool(params.get("save", true))
	call_deferred("_do_restart_editor", save)
	return {"ok": true, "note": "editor restarting — the connection will drop; reconnect once the editor has relaunched (this takes a few seconds)"}

func _do_restart_editor(save: bool) -> void:
	EditorInterface.restart_editor(save)

## Starts the project running the SAME way the editor's own Play button
## does (EditorInterface.play_main_scene()/play_custom_scene()) — distinct
## from godot-mcp's inherited run_project, which spawns a separate `godot
## -d` CLI process the MCP server itself owns. That CLI-spawned process
## turned out to be unreliable in practice (confirmed live: it vanished
## entirely partway through a test with no coredump, OOM, or journal
## trace — likely something about its relationship with the still-running
## editor's remote-debug connection). This path reuses the editor's own
## well-exercised internal play mechanism instead of a second bespoke
## process-spawn path.
func _cmd_play_scene(params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("play_scene is only available inside the editor")
	var scene_path := String(params.get("scene_path", ""))
	if scene_path != "":
		if not ResourceLoader.exists(scene_path):
			return _fail("scene not found: %s" % scene_path)
		EditorInterface.play_custom_scene(scene_path)
	else:
		EditorInterface.play_main_scene()
	return {"ok": true}

func _cmd_stop_scene(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("stop_scene is only available inside the editor")
	EditorInterface.stop_playing_scene()
	return {"ok": true}

func _cmd_is_playing_scene(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("is_playing_scene is only available inside the editor")
	return {"playing": EditorInterface.is_playing_scene(), "scene": EditorInterface.get_playing_scene()}

## Rescans the project filesystem so Godot notices externally-edited files
## (e.g. a script edited on disk outside the editor) without a full
## restart_editor. This is the reload_project counterpart to reload_plugin
## and restart_editor: cheapest first, escalate only if it isn't enough.
func _cmd_reload_project(_params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("reload_project is only available inside the editor")
	EditorInterface.get_resource_filesystem().scan()
	return {"ok": true}

## Lists every signal a node declares, and every live connection on each —
## one structured call replacing get_signal_list() + a get_signal_connection_list()
## call per signal, each returning raw Dictionaries that would need manual
## parsing. Connection targets are reported as a scene-relative path when
## they're a Node under the current scene root, else by class name.
func _cmd_get_signals(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var signals := []
	for sig in node.get_signal_list():
		var sig_name: String = sig.name
		var connections := []
		for conn in node.get_signal_connection_list(sig_name):
			var callable: Callable = conn["callable"]
			var target: Object = callable.get_object()
			var target_desc := "<freed>"
			if target:
				if target is Node and _get_scene_root() and (target == _get_scene_root() or _get_scene_root().is_ancestor_of(target)):
					target_desc = _rel_path(target)
				else:
					target_desc = "<%s>" % target.get_class()
			connections.append({
				"target": target_desc,
				"method": String(callable.get_method()),
			})
		signals.append({"name": sig_name, "connections": connections})
	return {"signals": signals}

## Recursively finds nodes under node_path matching a type and/or name glob
## pattern, returning just matching paths — not the whole subtree like
## list_scene_tree, which matters once a scene has more than a handful of
## nodes. type_filter uses Object.is_class() (inheritance-aware: "Control"
## matches a Button). name_pattern uses String.match() glob syntax ("*" and
## "?"). Either or both may be given; neither given returns every descendant.
func _cmd_find_nodes(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var type_filter := String(params.get("type", ""))
	var name_pattern := String(params.get("name_pattern", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var matches := []
	_find_nodes_recursive(node, type_filter, name_pattern, matches)
	return {"matches": matches}

func _find_nodes_recursive(node: Node, type_filter: String, name_pattern: String, matches: Array) -> void:
	for child in node.get_children():
		var type_ok := type_filter == "" or child.is_class(type_filter)
		var name_ok := name_pattern == "" or String(child.name).match(name_pattern)
		if type_ok and name_ok:
			matches.append({"name": child.name, "type": child.get_class(), "path": _rel_path(child)})
		_find_nodes_recursive(child, type_filter, name_pattern, matches)

## Applies the same properties to every node matched by find_nodes'
## type/name_pattern filter, in one call — the alternative is a find_nodes
## round trip followed by one set_properties call per match, which doesn't
## scale as a scene grows. Validates every property against every matched
## node FIRST (matched nodes can be different concrete types under one
## filter, e.g. "Control" matching both a Button and a Label with different
## property sets) and applies nothing if any is unknown anywhere — same
## atomic, all-or-nothing philosophy as _apply_properties. Batches every
## node's every property into ONE UndoRedo action, so one MCP call is one
## Ctrl+Z step regardless of how many nodes matched.
func _cmd_batch_set_properties(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var type_filter := String(params.get("type", ""))
	var name_pattern := String(params.get("name_pattern", ""))
	var properties: Dictionary = params.get("properties", {})
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if properties.is_empty():
		return _fail("properties is required and must be non-empty")

	var matches := []
	_find_nodes_recursive(node, type_filter, name_pattern, matches)
	if matches.is_empty():
		return {"matched": 0, "results": {}}

	var decoded := {}
	for prop_name in properties:
		decoded[String(prop_name)] = _decode_value(properties[prop_name])

	for m in matches:
		var target := _resolve_node(m["path"])
		var valid_names := {}
		for p in target.get_property_list():
			valid_names[p.name] = true
		for prop_name in decoded:
			if not valid_names.has(prop_name):
				return _fail("unknown property %s on %s (%s)" % [prop_name, m["path"], m["type"]])

	if _editor_plugin:
		var undo_redo := _editor_plugin.get_undo_redo()
		undo_redo.create_action("GodotLiveMCP: batch set properties")
		for m in matches:
			var target := _resolve_node(m["path"])
			for prop_name in decoded:
				undo_redo.add_do_property(target, prop_name, decoded[prop_name])
				undo_redo.add_undo_property(target, prop_name, target.get(prop_name))
		undo_redo.commit_action()
	else:
		for m in matches:
			var target := _resolve_node(m["path"])
			for prop_name in decoded:
				target.set(prop_name, decoded[prop_name])

	var results := {}
	for m in matches:
		var target := _resolve_node(m["path"])
		results[m["path"]] = _read_back(target, decoded.keys())
	return {"matched": matches.size(), "results": results}

## Captures the live editor viewport as a PNG, base64-encoded — genuine
## visual awareness with no other path to it (nothing exposes the Output
## panel's pixels or the 3D/2D viewport render through get_node_properties
## or eval_expression). max_dimension downscales before encoding so a
## screenshot doesn't dominate the response with a multi-megabyte payload;
## aspect ratio is preserved.
func _cmd_get_editor_screenshot(params: Dictionary):
	if not Engine.is_editor_hint():
		return _fail("get_editor_screenshot is only available inside the editor")
	var max_dimension := int(params.get("max_dimension", 800))

	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return _fail("no 3D editor viewport available")
	var img := viewport.get_texture().get_image()
	if img == null:
		return _fail("could not capture viewport image")

	var w := img.get_width()
	var h := img.get_height()
	if max_dimension > 0 and max(w, h) > max_dimension:
		var scale: float = float(max_dimension) / float(max(w, h))
		img.resize(int(w * scale), int(h * scale))

	var png_bytes := img.save_png_to_buffer()
	return {
		"format": "png",
		"base64": Marshalls.raw_to_base64(png_bytes),
		"width": img.get_width(),
		"height": img.get_height(),
	}

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
	var apply_err := _apply_properties(shape, shape_params)
	if apply_err != "":
		return _fail(apply_err)

	var collision_node: Node = ClassDB.instantiate(collision_node_type)
	collision_node.shape = shape
	_commit_add_node(parent, collision_node)

	return _with_live_note({"path": _rel_path(collision_node), "shape": _read_back(shape, shape_params.keys())}, true)

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

	var values := {}
	if params.has("layers"):
		values["collision_layer"] = _layers_to_bitmask(params["layers"])
	if params.has("mask"):
		values["collision_mask"] = _layers_to_bitmask(params["mask"])
	_commit_properties(node, values)
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
	var apply_err := _apply_properties(mesh, mesh_params)
	if apply_err != "":
		return _fail(apply_err)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	if node_name != "":
		mesh_instance.name = node_name
	_commit_add_node(parent, mesh_instance)

	return _with_live_note({"path": _rel_path(mesh_instance), "mesh": _read_back(mesh, mesh_params.keys())}, true)

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
	var apply_err := _apply_properties(env, environment_params)
	if apply_err != "":
		return _fail(apply_err)
	_commit_properties(node, {"environment": env})

	return {"ok": true, "environment": _read_back(env, environment_params.keys())}

## set_material_3d only edits StandardMaterial3D; it used to silently replace
## any other material (a real case: a checker ShaderMaterial was thrown away
## by a "tint it blue" request). Now it refuses unless told to replace.
func _other_material_msg(existing: Material) -> String:
	var what := existing.get_class()
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader:
		what += " using %s" % (existing as ShaderMaterial).shader.resource_path
		return ("this node already has a %s — set_material_3d would replace it. To change it, use " +
			"set_shader_material (shader_params) or edit the shader; pass replace_existing: true " +
			"only if the user wants it replaced.") % what
	return ("this node already has a %s — set_material_3d would replace it. Pass " +
		"replace_existing: true only if the user wants it replaced.") % what

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
		var surf_new := false
		if current_surf is StandardMaterial3D:
			surf_mat = current_surf
		elif current_surf != null and not bool(params.get("replace_existing", false)):
			return _fail(_other_material_msg(current_surf))
		else:
			surf_mat = StandardMaterial3D.new()
			surf_new = true
		var apply_err := _apply_properties(surf_mat, material_params)
		if apply_err != "":
			return _fail(apply_err)
		mesh_instance.set_surface_override_material(idx, surf_mat)
		return _with_live_note({"ok": true, "material": _read_back(surf_mat, material_params.keys())}, surf_new)

	var mat: StandardMaterial3D
	var created_new := false
	if node.material_override is StandardMaterial3D:
		mat = node.material_override
	elif node.material_override != null and not bool(params.get("replace_existing", false)):
		return _fail(_other_material_msg(node.material_override))
	else:
		mat = StandardMaterial3D.new()
		created_new = true
	var apply_err := _apply_properties(mat, material_params)
	if apply_err != "":
		return _fail(apply_err)
	if created_new:
		# Through UndoRedo like an Inspector edit (dirty marker, Ctrl+Z).
		_commit_properties(node, {"material_override": mat})

	return _with_live_note({"ok": true, "material": _read_back(mat, material_params.keys())}, created_new)

## Reads back a GeometryInstance3D's material_override (or one surface's
## override, via surface_index) — the missing counterpart to set_material_3d.
## Every other resource-setter tool in this bridge has a paired getter
## (setup_collision/get_collision_info, set_shader_material/
## get_shader_material_info, particle material/get_particle_info); this one
## didn't, which meant reading a single property meant either an
## eval_expression chain that fails on method-return type narrowing (e.g.
## get_surface_override_material(0).albedo_color errors — Expression can't
## see past the generic Object return type) or a full eval_expression dump
## of every one of StandardMaterial3D's ~90 properties just to find one.
## Filters to editor-visible properties, same as get_node_properties/
## get_collision_info, instead of returning everything.
func _cmd_get_material_info(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is GeometryInstance3D):
		return _fail("node is not a GeometryInstance3D (e.g. MeshInstance3D): %s" % node_path)

	var mat
	if params.has("surface_index"):
		if not (node is MeshInstance3D):
			return _fail("surface_index requires a MeshInstance3D: %s" % node_path)
		var mesh_instance: MeshInstance3D = node
		var idx := int(params["surface_index"])
		if idx < 0 or idx >= mesh_instance.get_surface_override_material_count():
			return _fail("surface_index %d out of range (mesh has %d surfaces)" % [idx, mesh_instance.get_surface_override_material_count()])
		mat = mesh_instance.get_surface_override_material(idx)
	else:
		mat = node.material_override

	if mat == null:
		return {"has_material": false}

	var props := {}
	for prop in mat.get_property_list():
		if prop.usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		props[prop.name] = var_to_str(mat.get(prop.name))
	return {"has_material": true, "material_type": mat.get_class(), "properties": props}

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
	var apply_err := _apply_properties(mat, material_params)
	if apply_err != "":
		return _fail(apply_err)
	_commit_properties(node, {"physics_material_override": mat})
	return {"ok": true, "material": _read_back(mat, material_params.keys())}

## Applies a layout preset to a live Control (Control.set_anchors_preset())
## — a method call, unreachable through property tools, and the standard
## way to lay out UI (e.g. "make this fill its parent" / PRESET_FULL_RECT)
## without hand-computing four anchor values. Preset is a string constant
## name (e.g. "PRESET_FULL_RECT", "PRESET_CENTER") resolved dynamically via
## ClassDB rather than hardcoding Godot's LayoutPreset integer values,
## which keeps this correct across Godot versions without needing to know
## them. class_has_integer_constant guards against
## class_get_integer_constant's silent "returns 0 for unknown names"
## behavior, since 0 is also a real, valid preset value.
func _cmd_set_anchors_preset(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var preset_name := String(params.get("preset", ""))
	var keep_offsets := bool(params.get("keep_offsets", false))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is Control):
		return _fail("node is not a Control: %s" % node_path)
	if preset_name == "":
		return _fail("preset is required, e.g. \"PRESET_FULL_RECT\"")
	if not ClassDB.class_has_integer_constant("Control", preset_name):
		return _fail("unknown Control.LayoutPreset constant: %s" % preset_name)

	var preset_value := ClassDB.class_get_integer_constant("Control", preset_name)
	# Apply to find the resulting anchors/offsets, then put the old values
	# back and commit the new ones as one undoable property change.
	var keys := ["anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
		"offset_left", "offset_top", "offset_right", "offset_bottom"]
	var before := {}
	for k in keys:
		before[k] = node.get(k)
	node.set_anchors_preset(preset_value, keep_offsets)
	var after := {}
	for k in keys:
		after[k] = node.get(k)
	for k in keys:
		node.set(k, before[k])
	_commit_properties(node, after)
	return {
		"ok": true,
		"anchor_left": node.anchor_left, "anchor_top": node.anchor_top,
		"anchor_right": node.anchor_right, "anchor_bottom": node.anchor_bottom,
	}

## Returns a node's bounding box — genuinely not reachable any other way
## for the two node families that actually have one. VisualInstance3D
## exposes get_aabb() (local-space); world-space is derived via
## global_transform * aabb, Transform3D's own AABB-transform operator, not
## a separate method. Control exposes get_global_rect() directly.
func _cmd_get_node_bounds(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	if node is VisualInstance3D:
		var local_aabb: AABB = node.get_aabb()
		var world_aabb: AABB = node.global_transform * local_aabb
		return {
			"kind": "aabb_3d",
			"local_aabb": var_to_str(local_aabb),
			"world_aabb": var_to_str(world_aabb),
		}
	if node is Control:
		return {
			"kind": "rect_2d",
			"rect": var_to_str(node.get_rect()),
			"global_rect": var_to_str(node.get_global_rect()),
		}
	return _fail("node has no bounding box (not a VisualInstance3D or Control): %s" % node_path)

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
	var apply_err := _apply_properties(stylebox, style_params)
	if apply_err != "":
		return _fail(apply_err)
	_commit_properties(node, {"theme_override_styles/" + override_name: stylebox})
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
	var created_new := not (current is ShaderMaterial)
	mat = ShaderMaterial.new() if created_new else current

	var new_shader: Shader = null
	if shader_path != "":
		if not ResourceLoader.exists(shader_path):
			return _fail("shader not found: %s" % shader_path)
		new_shader = load(shader_path)
	if new_shader == null and mat.shader == null:
		return _fail("no shader set — pass shader_path, or the node's existing material must already have one")

	# Shader parameters are the material's "shader_parameter/<name>"
	# properties; setting them that way (through UndoRedo, not
	# set_shader_parameter()) makes them undoable and live-synced.
	var values := {}
	if new_shader and new_shader != mat.shader:
		values["shader"] = new_shader
	for pname in shader_params:
		values["shader_parameter/" + String(pname)] = _decode_value(shader_params[pname])

	if created_new:
		for key in values:
			mat.set(key, values[key])
		_commit_properties(node, {prop_name: mat})
	else:
		_commit_properties(mat, values)

	var applied := {}
	for pname in shader_params:
		applied[String(pname)] = var_to_str(mat.get_shader_parameter(String(pname)))
	return _with_live_note({"ok": true, "shader_path": mat.shader.resource_path, "shader_params": applied}, created_new)

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
	var library: AnimationLibrary = player.get_animation_library(library_name) if player.has_animation_library(library_name) else null
	if library and library.has_animation(anim_name):
		return _fail("animation already exists: %s" % anim_name)

	var anim := Animation.new()
	anim.length = length
	if not _begin_node_action("create animation"):
		return _fail("no editor undo system available")
	if library == null:
		library = AnimationLibrary.new()
		_do(player, "add_animation_library", [library_name, library])
		_undo(player, "remove_animation_library", [library_name])
		_node_action_ur.add_do_reference(library)
	_do(library, "add_animation", [anim_name, anim])
	_undo(library, "remove_animation", [anim_name])
	_node_action_ur.add_do_reference(anim)
	_commit_node_action()
	return _with_live_note({"ok": true}, true)

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
	var idx := anim.get_track_count()
	if not _begin_node_action("add animation track"):
		return _fail("no editor undo system available")
	_do(anim, "add_track", [_TRACK_TYPES[track_type]])
	_do(anim, "track_set_path", [idx, NodePath(track_node_path)])
	_undo(anim, "remove_track", [idx])
	_commit_node_action()
	return {"track_index": idx}

## Points an existing track at a different node/property ("LegLPivot:rotation"),
## one undoable action — instead of track_set_path through run_script.
func _cmd_set_animation_track_path(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var anim_name := String(params.get("anim_name", ""))
	var library_name := String(params.get("library_name", ""))
	var track_index := int(params.get("track_index", -1))
	var track_node_path := String(params.get("track_node_path", ""))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _fail("node is not an AnimationPlayer: %s" % node_path)
	var player: AnimationPlayer = node
	if not player.has_animation_library(library_name) or not player.get_animation_library(library_name).has_animation(anim_name):
		return _fail("animation not found: %s" % anim_name)
	var anim: Animation = player.get_animation_library(library_name).get_animation(anim_name)
	if track_index < 0 or track_index >= anim.get_track_count():
		return _fail("track_index %d out of range (animation has %d tracks)" % [track_index, anim.get_track_count()])
	if track_node_path == "":
		return _fail("track_node_path is required, e.g. \"LegLPivot:rotation\"")
	var old_path := anim.track_get_path(track_index)
	if not _begin_node_action("set animation track path"):
		return _fail("no editor undo system available")
	_do(anim, "track_set_path", [track_index, NodePath(track_node_path)])
	_undo(anim, "track_set_path", [track_index, old_path])
	_commit_node_action()
	return {"ok": true, "track_index": track_index, "path": String(anim.track_get_path(track_index))}

## Replaces one track's keyframes (and optionally the animation length) as
## ONE undoable action, instead of a string of eval_expression
## track_remove_key/track_insert_key calls that can't be undone and never
## reach a running game.
func _cmd_set_animation_keys(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var anim_name := String(params.get("anim_name", ""))
	var library_name := String(params.get("library_name", ""))
	var track_index := int(params.get("track_index", -1))
	var keys: Array = params.get("keys", [])
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
	if track_index < 0 or track_index >= anim.get_track_count():
		return _fail("track_index %d out of range (animation has %d tracks)" % [track_index, anim.get_track_count()])

	var new_keys := []
	for k in keys:
		if typeof(k) != TYPE_DICTIONARY or not k.has("time") or not k.has("value"):
			return _fail("each key must be {time, value[, transition]}")
		new_keys.append([float(k["time"]), _decode_value(k["value"]), float(k.get("transition", 1.0))])
	var old_keys := []
	for i in anim.track_get_key_count(track_index):
		old_keys.append([anim.track_get_key_time(track_index, i), anim.track_get_key_value(track_index, i),
			anim.track_get_key_transition(track_index, i)])

	if not _begin_node_action("set animation keys"):
		return _fail("no editor undo system available")
	for i in range(old_keys.size() - 1, -1, -1):
		_do(anim, "track_remove_key", [track_index, i])
	for k in new_keys:
		_do(anim, "track_insert_key", [track_index, k[0], k[1], k[2]])
	for i in range(new_keys.size() - 1, -1, -1):
		_undo(anim, "track_remove_key", [track_index, i])
	for k in old_keys:
		_undo(anim, "track_insert_key", [track_index, k[0], k[1], k[2]])
	if params.has("length"):
		_node_action_ur.add_do_property(anim, "length", float(params["length"]))
		_node_action_ur.add_undo_property(anim, "length", anim.length)
	_commit_node_action()

	var result := []
	for i in anim.track_get_key_count(track_index):
		result.append({"time": anim.track_get_key_time(track_index, i), "value": var_to_str(anim.track_get_key_value(track_index, i))})
	return {"ok": true, "length": anim.length, "keys": result}

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

## Resolves an AnimationTree node's tree_root, requiring it to already be an
## AnimationNodeStateMachine — set via set_resource_property first if it
## isn't (e.g. resource_type "AnimationNodeStateMachine" on property
## "tree_root"). Shared by add_animation_state/add_animation_transition.
func _resolve_state_machine(node_path: String):
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)
	if not (node is AnimationTree):
		return _fail("node is not an AnimationTree: %s" % node_path)
	var root = node.tree_root
	if not (root is AnimationNodeStateMachine):
		return _fail("AnimationTree's tree_root is not an AnimationNodeStateMachine — set it first via set_resource_property (property_name \"tree_root\", resource_type \"AnimationNodeStateMachine\")")
	return root

## Adds a state to an AnimationTree's state machine — a method call
## (AnimationNodeStateMachine.add_node()), not a property, so unreachable
## through set_property/set_resource_property. Wraps the named animation in
## a fresh AnimationNodeAnimation, matching what the state machine editor
## UI creates when you drag an animation into the graph.
func _cmd_add_animation_state(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var state_name := String(params.get("state_name", ""))
	var animation_name := String(params.get("animation_name", ""))
	if state_name == "":
		return _fail("state_name is required")

	var root = _resolve_state_machine(node_path)
	if root is Dictionary:
		return root

	if root.has_node(state_name):
		return _fail("state already exists: %s" % state_name)

	var anim_node := AnimationNodeAnimation.new()
	if animation_name != "":
		anim_node.animation = animation_name
	root.add_node(state_name, anim_node)
	return {"ok": true}

## Adds a transition between two states in an AnimationTree's state
## machine — a method call (AnimationNodeStateMachine.add_transition()),
## not a property. The transition itself is a generic Resource
## (AnimationNodeStateMachineTransition), so its properties (switch_mode,
## advance_mode, xfade_time, ...) go through the same validated
## _apply_properties path as everything else.
func _cmd_add_animation_transition(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var from_state := String(params.get("from_state", ""))
	var to_state := String(params.get("to_state", ""))
	var transition_params: Dictionary = params.get("transition_params", {})
	if from_state == "" or to_state == "":
		return _fail("from_state and to_state are required")

	var root = _resolve_state_machine(node_path)
	if root is Dictionary:
		return root

	if not root.has_node(from_state):
		return _fail("unknown from_state: %s" % from_state)
	if not root.has_node(to_state):
		return _fail("unknown to_state: %s" % to_state)

	var transition := AnimationNodeStateMachineTransition.new()
	var apply_err := _apply_properties(transition, transition_params)
	if apply_err != "":
		return _fail(apply_err)
	root.add_transition(from_state, to_state, transition)
	return {"ok": true, "transition": _read_back(transition, transition_params.keys())}

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
	var apply_err := _apply_properties(effect, effect_params)
	if apply_err != "":
		return _fail(apply_err)
	AudioServer.add_bus_effect(idx, effect)
	return {"ok": true, "bus_index": idx, "effect": _read_back(effect, effect_params.keys())}

## Adjusts an existing audio bus effect's properties after creation —
## add_audio_bus_effect only covers setting properties at creation time,
## with no way to change them afterward or read them back individually
## (get_audio_bus_layout only reports effect class names, not properties).
func _cmd_set_audio_bus_effect_params(params: Dictionary):
	var bus_name := String(params.get("bus_name", ""))
	var effect_index := int(params.get("effect_index", -1))
	var effect_params: Dictionary = params.get("effect_params", {})
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return _fail("bus not found: %s" % bus_name)
	if effect_index < 0 or effect_index >= AudioServer.get_bus_effect_count(idx):
		return _fail("effect_index %d out of range (bus has %d effects)" % [effect_index, AudioServer.get_bus_effect_count(idx)])

	var effect := AudioServer.get_bus_effect(idx, effect_index)
	var apply_err := _apply_properties(effect, effect_params)
	if apply_err != "":
		return _fail(apply_err)
	return {"ok": true, "effect": _read_back(effect, effect_params.keys())}

## Removes an audio bus effect by index — AudioServer.remove_bus_effect()
## is a method call with no property-tool equivalent.
func _cmd_remove_audio_bus_effect(params: Dictionary):
	var bus_name := String(params.get("bus_name", ""))
	var effect_index := int(params.get("effect_index", -1))
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return _fail("bus not found: %s" % bus_name)
	if effect_index < 0 or effect_index >= AudioServer.get_bus_effect_count(idx):
		return _fail("effect_index %d out of range (bus has %d effects)" % [effect_index, AudioServer.get_bus_effect_count(idx)])
	AudioServer.remove_bus_effect(idx, effect_index)
	return {"ok": true}

func _cmd_get_audio_bus_layout(_params: Dictionary):
	var buses := []
	for i in range(AudioServer.bus_count):
		var effects := []
		for e in range(AudioServer.get_bus_effect_count(i)):
			var effect := AudioServer.get_bus_effect(i, e)
			var effect_props := {}
			for prop in effect.get_property_list():
				if prop.usage & PROPERTY_USAGE_EDITOR == 0:
					continue
				effect_props[prop.name] = var_to_str(effect.get(prop.name))
			effects.append({"index": e, "type": effect.get_class(), "properties": effect_props})
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

	var pos: Vector2i = _decode_value(params.get("position", "Vector2i(0, 0)"))
	var size: Vector2i = _decode_value(params.get("size", "Vector2i(1, 1)"))
	var atlas_coords: Vector2i = _decode_value(params.get("atlas_coords", "Vector2i(0, 0)"))
	var source_id := int(params.get("source_id", 0))
	var alternative_tile := int(params.get("alternative_tile", 0))
	if size.x <= 0 or size.y <= 0:
		return _fail("size must have positive x and y")

	var count := 0
	# Paint, read back the layer's tile_map_data, restore it, then commit
	# the new data as one undoable (and live-synced) property change.
	var before: PackedByteArray = layer.tile_map_data
	for x in range(pos.x, pos.x + size.x):
		for y in range(pos.y, pos.y + size.y):
			layer.set_cell(Vector2i(x, y), source_id, atlas_coords, alternative_tile)
			count += 1
	var after: PackedByteArray = layer.tile_map_data
	layer.tile_map_data = before
	_commit_properties(layer, {"tile_map_data": after})
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
	var apply_err := _apply_properties(mat, material_params)
	if apply_err != "":
		return _fail(apply_err)
	_commit_properties(node, {"process_material": mat})
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
		colors.append(_decode_value(p.get("color", "Color(1, 1, 1, 1)")))

	var mat := _get_or_create_particle_material(node)
	# An existing gradient is edited in place (undoable, and it reaches a
	# running game); only a first-time gradient needs new resources, which
	# can't be sent to a running game until the next Play.
	var ramp = mat.color_ramp
	if ramp is GradientTexture1D and (ramp as GradientTexture1D).gradient:
		_commit_properties((ramp as GradientTexture1D).gradient, {"offsets": offsets, "colors": colors})
		if mat != node.get("process_material"):
			_commit_properties(node, {"process_material": mat})
		return {"ok": true}
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient
	_commit_properties(mat, {"color_ramp": gradient_texture})
	if mat != node.get("process_material"):
		_commit_properties(node, {"process_material": mat})
	return _with_live_note({"ok": true}, true)

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

## Configures and bakes a NavigationRegion2D/3D's nav mesh/polygon in one
## call — creating the resource, applying properties to it, and baking are
## three separate steps otherwise, and baking specifically is a method call
## (bake_navigation_mesh()/bake_navigation_polygon()), unreachable through
## property tools. Forces on_thread=false (synchronous) rather than the
## default threaded bake, since this is a request/response bridge with no
## way to push a bake_finished signal back to the caller — the response
## only means something if baking has actually completed by the time it's
## sent. Bakes from whatever geometry already exists under the region node
## in the scene tree, same as the manual "Bake NavigationMesh" editor button.
func _cmd_setup_navigation(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var nav_params: Dictionary = params.get("nav_params", {})
	var bake := bool(params.get("bake", true))
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	if node is NavigationRegion3D:
		var navmesh: NavigationMesh = node.navigation_mesh
		if navmesh == null:
			navmesh = NavigationMesh.new()
		var apply_err := _apply_properties(navmesh, nav_params)
		if apply_err != "":
			return _fail(apply_err)
		_commit_properties(node, {"navigation_mesh": navmesh})
		if bake:
			node.bake_navigation_mesh(false)
		return {"ok": true, "baked": bake, "navigation_mesh": _read_back(navmesh, nav_params.keys())}

	if node is NavigationRegion2D:
		var navpoly: NavigationPolygon = node.navigation_polygon
		if navpoly == null:
			navpoly = NavigationPolygon.new()
		var apply_err := _apply_properties(navpoly, nav_params)
		if apply_err != "":
			return _fail(apply_err)
		_commit_properties(node, {"navigation_polygon": navpoly})
		if bake:
			node.bake_navigation_polygon(false)
		return {"ok": true, "baked": bake, "navigation_polygon": _read_back(navpoly, nav_params.keys())}

	return _fail("node is not a NavigationRegion2D/3D: %s" % node_path)

## Returns a resource file's dependencies (other files it references) via
## ResourceLoader.get_dependencies() — a genuine capability gap, nothing
## else exposes a project's resource dependency graph. Each raw entry is
## either a plain path or "uid://...::TypeHint::fallback/path" — this
## splits out the path/uid for a cleaner response rather than making the
## caller parse Godot's "::"-joined format.
func _cmd_get_resource_dependencies(params: Dictionary):
	var path := String(params.get("path", ""))
	if path == "":
		return _fail("path is required")
	if not ResourceLoader.exists(path):
		return _fail("resource not found: %s" % path)

	var deps := []
	for raw in ResourceLoader.get_dependencies(path):
		var raw_str := String(raw)
		var parts := raw_str.split("::")
		if parts.size() >= 3:
			deps.append({"uid": parts[0], "type_hint": parts[1], "path": parts[2]})
		else:
			deps.append({"uid": "", "type_hint": "", "path": raw_str})
	return {"dependencies": deps}

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
