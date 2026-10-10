extends Node

## Live bridge for a RUNNING GAME instance — the runtime counterpart to
## bridge.gd (which only runs inside the editor process via the
## EditorPlugin registration and has zero presence in an actual game,
## since Run Project launches a separate OS process the editor plugin
## never touches). Not @tool — this only runs during real gameplay.
##
## Must be added as a Project Settings > Autoload singleton to take
## effect; installing the addon alone does not wire this up, since an
## editor plugin and an autoload are two independent Godot mechanisms.
##
## Same newline-delimited JSON protocol as bridge.gd, on a SEPARATE port
## (both can be listening at once — the editor and a running game are
## different processes). No EditorUndoRedoManager here (nothing to undo
## at runtime) — property mutations are direct Object.set() calls.

const DEFAULT_PORT := 9090
const HOST := "127.0.0.1"

const _SINGLETON_NAMES := ["ProjectSettings", "ClassDB", "Engine", "Input", "OS", "Time", "Performance", "AudioServer", "ResourceLoader", "ResourceSaver"]

var _server: TCPServer
var _peers: Array = []
var _peer_buffers: Dictionary = {}
var _token: String = ""
var _port: int = DEFAULT_PORT

func _ready() -> void:
	# Only when the game was launched from the editor (Play / play_scene):
	# never open a control port in an exported build of the game.
	if not OS.has_feature("editor_runtime"):
		set_process(false)
		queue_free()
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_token = _load_or_create_token()
	_port = _load_port()
	_server = TCPServer.new()
	var err := _server.listen(_port, HOST)
	if err != OK:
		push_error("GodotLiveMCPRuntimeBridge: failed to listen on %s:%d (err %d)" % [HOST, _port, err])
		return
	print("GodotLiveMCPRuntimeBridge: listening on %s:%d" % [HOST, _port])
	set_process(true)

func _get_scene_root() -> Node:
	return get_tree().current_scene

## Same caveat as bridge.gd's _process(): socket I/O only happens here,
## once per frame, so a long synchronous command blocks every other bridge
## command until it returns — see README's "Known limitations".
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
		# await is required here even though most _cmd_* handlers are plain
		# synchronous functions — confirmed live: wait_for_condition (which
		# internally awaits get_tree().process_frame in a loop) returned a
		# raw GDScriptFunctionState object instead of its actual result when
		# called via plain call(), since Object.call() doesn't transparently
		# wait for a callee's internal await to resolve on its own. await
		# on a call that DOESN'T suspend just passes the value through
		# immediately, so this is safe for every other command too.
		var response = await call("_cmd_" + command, params)
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

func _decode_value(value_str: String):
	if value_str.begins_with("load:"):
		return load(value_str.substr(5))
	return str_to_var(value_str)

## Sets each property via Object.set(), validated against get_property_list()
## first (same silent-failure protection as bridge.gd's _apply_properties)
## — no UndoRedo at runtime, direct assignment.
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

	for name_str in to_apply:
		obj.set(name_str, to_apply[name_str])
	return unknown

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
	var input_values: Array = [ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader, ResourceSaver]
	for key_name in _KEY_CONSTANTS:
		input_names.append(key_name)
		input_values.append(_KEY_CONSTANTS[key_name])

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

	if node is Node2D:
		props["global_position"] = var_to_str(node.global_position)
		props["global_rotation"] = var_to_str(node.global_rotation)
	elif node is Node3D:
		props["global_position"] = var_to_str(node.global_position)
		props["global_transform"] = var_to_str(node.global_transform)

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

## Captures the running game's main viewport as a PNG, base64-encoded —
## visual awareness of actual gameplay, distinct from
## get_editor_screenshot (which only sees the editor's 3D viewport gizmo
## view, not a running game).
func _cmd_get_game_screenshot(params: Dictionary):
	var shot := _capture_viewport(int(params.get("max_dimension", 800)))
	if shot.is_empty():
		return _fail("could not capture viewport image")
	return shot

func _capture_viewport(max_dimension: int) -> Dictionary:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return {}

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

## Upper bound on how long a capture/monitor command may run; the MCP
## server sizes its per-call timeout from the same limit. Socket I/O for
## other commands waits while one of these runs (see _process()).
const _MAX_SAMPLE_DURATION_SEC := 10.0

## Waits interval_sec of real time (ignores Engine.time_scale and pause),
## or one rendered frame when interval_sec is 0.
func _wait_interval(interval_sec: float) -> void:
	if interval_sec <= 0.0:
		await get_tree().process_frame
	else:
		await get_tree().create_timer(interval_sec, true, false, true).timeout

## Several screenshots spaced interval_sec apart — motion, not a single
## still. The first frame is taken immediately.
func _cmd_capture_game_frames(params: Dictionary):
	var count := clampi(int(params.get("count", 4)), 1, 8)
	var interval_sec: float = max(float(params.get("interval_sec", 0.25)), 0.0)
	var max_dimension := int(params.get("max_dimension", 400))
	if interval_sec * (count - 1) > _MAX_SAMPLE_DURATION_SEC:
		return _fail("(count - 1) * interval_sec exceeds %ss" % _MAX_SAMPLE_DURATION_SEC)

	var start := Time.get_ticks_msec()
	var frames := []
	for i in count:
		if i > 0:
			await _wait_interval(interval_sec)
		var shot := _capture_viewport(max_dimension)
		if shot.is_empty():
			return _fail("could not capture viewport image")
		shot["t"] = (Time.get_ticks_msec() - start) / 1000.0
		frames.append(shot)
	return {"frames": frames}

## Samples node properties (and/or expressions) every interval_sec for
## duration_sec and returns a time series. Every watch is validated
## before sampling starts, so a misspelled property fails up front
## instead of producing a column of nulls.
func _cmd_monitor_properties(params: Dictionary):
	var watch: Array = params.get("watch", [])
	if watch.is_empty():
		return _fail("watch is empty")
	var duration_sec: float = float(params.get("duration_sec", 2.0))
	var interval_sec: float = max(float(params.get("interval_sec", 0.1)), 0.0)
	if duration_sec <= 0.0 or duration_sec > _MAX_SAMPLE_DURATION_SEC:
		return _fail("duration_sec must be in (0, %s]" % _MAX_SAMPLE_DURATION_SEC)
	var max_samples := clampi(int(params.get("max_samples", 200)), 1, 1000)

	var input_names: Array = _SINGLETON_NAMES.duplicate()
	var input_values: Array = [ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader, ResourceSaver]
	for key_name in _KEY_CONSTANTS:
		input_names.append(key_name)
		input_values.append(_KEY_CONSTANTS[key_name])

	# Each entry: [label, node, property-or-"", Expression-or-null]
	var columns := []
	for item in watch:
		if typeof(item) != TYPE_DICTIONARY:
			return _fail("each watch entry must be an object")
		var node_path := String(item.get("node_path", "."))
		var node := _resolve_node(node_path)
		if node == null:
			return _fail("node not found: %s" % node_path)
		var prop := String(item.get("property", ""))
		var expr_src := String(item.get("expression", ""))
		if (prop == "") == (expr_src == ""):
			return _fail("watch entry for %s needs exactly one of property or expression" % node_path)
		var expr: Expression = null
		if prop != "":
			# Sub-paths like "position:x" are read with get_indexed();
			# validate the base property name.
			var base := prop.get_slice(":", 0)
			var known := false
			for p in node.get_property_list():
				if p.name == base:
					known = true
					break
			if not known:
				return _fail("unknown property on %s: %s" % [node_path, base])
		else:
			expr = Expression.new()
			if expr.parse(expr_src, input_names) != OK:
				return _fail("parse error in %s: %s" % [expr_src, expr.get_error_text()])
		var what := prop if prop != "" else expr_src
		var label := String(item.get("label", what if node_path == "." else "%s.%s" % [node_path, what]))
		columns.append([label, node, prop, expr])

	var labels := []
	for c in columns:
		labels.append(c[0])

	var start := Time.get_ticks_msec()
	var rows := []
	while true:
		var t := (Time.get_ticks_msec() - start) / 1000.0
		var row := [t]
		for c in columns:
			var node = c[1]
			if not is_instance_valid(node):
				row.append("<freed>")
			elif c[3] == null:
				row.append(var_to_str(node.get_indexed(NodePath(c[2]))))
			else:
				var expr: Expression = c[3]
				var value = expr.execute(input_values, node, true)
				row.append("<error: %s>" % expr.get_error_text() if expr.has_execute_failed() else var_to_str(value))
		rows.append(row)
		if t >= duration_sec or rows.size() >= max_samples:
			break
		await _wait_interval(interval_sec)

	return {"columns": ["t"] + labels, "rows": rows}

## Key enum constant values for Godot 4.7, fetched directly from a live
## instance via compiled GDScript rather than guessed — confirmed live
## that ClassDB.class_get_integer_constant("@GlobalScope", ...) does NOT
## work for these (global enums, unlike a class's own enum such as
## Control.LayoutPreset, aren't exposed through ClassDB at all — also
## confirmed Expression can't resolve them either). Special/non-printable
## keys only; printable characters (letters, digits, punctuation) don't
## need a table at all — Godot's Key enum values for those are literally
## their Unicode code point (KEY_A == 65 == 'A'.unicode_at(0), KEY_SPACE
## == 32 == ' '.unicode_at(0)), confirmed live.
const _SPECIAL_KEYS := {
	"KEY_ESCAPE": 4194305, "KEY_TAB": 4194306, "KEY_BACKSPACE": 4194308,
	"KEY_ENTER": 4194309, "KEY_HOME": 4194317, "KEY_END": 4194318,
	"KEY_LEFT": 4194319, "KEY_UP": 4194320, "KEY_RIGHT": 4194321,
	"KEY_DOWN": 4194322, "KEY_DELETE": 4194312, "KEY_SHIFT": 4194325,
	"KEY_CTRL": 4194326, "KEY_ALT": 4194328, "KEY_SPACE": 32,
}
const _F_KEY_BASE := 4194332  # KEY_F1; KEY_F2..KEY_F12 confirmed live as +1 sequential

## KEY_* names bound into eval_expression/wait_for_condition's Expression
## context (see _build_key_constants below) — a real GDScript context has
## these as ordinary @GlobalScope constants, but Expression only resolves
## names explicitly passed to parse()/execute(), so without this an
## expression like "Input.is_key_pressed(KEY_A)" fails to parse with
## "Invalid named index 'KEY_A'". Confirmed live (see TOOL_CANDIDATES.md
## review, 2026-09-10): hit twice independently, forcing callers to fall
## back to raw ASCII codes.
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

## Resolves a keycode name to its integer value, or -1 if unresolvable.
## Accepts "KEY_XXX" names (the special-key table, or "KEY_F1".."KEY_F12"
## computed from the confirmed base), or a single printable character
## directly (e.g. "a", "5", " ").
func _resolve_keycode(name: String) -> int:
	if _SPECIAL_KEYS.has(name):
		return _SPECIAL_KEYS[name]
	if name.begins_with("KEY_F"):
		var suffix := name.substr(5)
		if suffix.is_valid_int():
			var n := int(suffix)
			if n >= 1 and n <= 12:
				return _F_KEY_BASE + (n - 1)
	if name.length() == 1:
		return name.unicode_at(0)
	return -1

## MouseButton enum values, confirmed live the same way.
const _MOUSE_BUTTONS := {
	"MOUSE_BUTTON_LEFT": 1, "MOUSE_BUTTON_RIGHT": 2, "MOUSE_BUTTON_MIDDLE": 3,
	"MOUSE_BUTTON_WHEEL_UP": 4, "MOUSE_BUTTON_WHEEL_DOWN": 5,
}

## Simulates a keyboard key press/release via Input.parse_input_event() —
## a real OS-level-shaped input event fed into the engine's input pipeline
## (reaches _input()/_unhandled_input()/Input.is_action_pressed() the same
## way an actual keypress would), not just flipping an internal flag.
func _cmd_simulate_key(params: Dictionary):
	var keycode_name := String(params.get("keycode", ""))
	var pressed := bool(params.get("pressed", true))
	if keycode_name == "":
		return _fail("keycode is required, e.g. \"KEY_SPACE\", \"KEY_ENTER\", or a single character like \"a\"")
	var keycode := _resolve_keycode(keycode_name)
	if keycode == -1:
		return _fail("unknown keycode: %s" % keycode_name)

	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	return {"ok": true}

## Simulates a mouse button press/release at the given viewport position.
func _cmd_simulate_mouse_button(params: Dictionary):
	var button_name := String(params.get("button", "MOUSE_BUTTON_LEFT"))
	var pressed := bool(params.get("pressed", true))
	var position: Vector2 = str_to_var(String(params.get("position", "Vector2(0, 0)")))
	if not _MOUSE_BUTTONS.has(button_name):
		return _fail("unknown MouseButton constant: %s" % button_name)

	var event := InputEventMouseButton.new()
	event.button_index = _MOUSE_BUTTONS[button_name]
	event.pressed = pressed
	event.position = position
	event.global_position = position
	Input.parse_input_event(event)
	return {"ok": true}

## Simulates mouse movement to the given viewport position.
func _cmd_simulate_mouse_motion(params: Dictionary):
	var position: Vector2 = str_to_var(String(params.get("position", "Vector2(0, 0)")))
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	Input.parse_input_event(event)
	Input.warp_mouse(position)
	return {"ok": true}

## Polls an eval_expression-style boolean expression once per frame until
## it's true or timeout_sec elapses — the alternative is the caller
## repeatedly calling eval_expression itself in a loop, one bridge round
## trip per frame, which is far more wasteful than one call that awaits
## frames internally. Capped at 4s so a hung condition still returns
## within this bridge's default 5s client timeout rather than the
## connection just going dead with no informative response.
func _cmd_wait_for_condition(params: Dictionary):
	var node_path := String(params.get("node_path", "."))
	var expr_src := String(params.get("expression", ""))
	var timeout_sec: float = min(float(params.get("timeout_sec", 2.0)), 4.0)
	var node := _resolve_node(node_path)
	if node == null:
		return _fail("node not found: %s" % node_path)

	var input_names: Array = _SINGLETON_NAMES.duplicate()
	var input_values: Array = [ProjectSettings, ClassDB, Engine, Input, OS, Time, Performance, AudioServer, ResourceLoader, ResourceSaver]
	for key_name in _KEY_CONSTANTS:
		input_names.append(key_name)
		input_values.append(_KEY_CONSTANTS[key_name])
	var expr := Expression.new()
	var parse_err := expr.parse(expr_src, input_names)
	if parse_err != OK:
		return _fail("parse error: %s" % expr.get_error_text())

	var elapsed := 0.0
	while elapsed < timeout_sec:
		var value = expr.execute(input_values, node, true)
		if expr.has_execute_failed():
			return _fail("execute error: %s" % expr.get_error_text())
		if value:
			return {"met": true, "elapsed_sec": elapsed}
		await get_tree().process_frame
		elapsed += get_process_delta_time()

	return {"met": false, "elapsed_sec": elapsed}

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
	return generated

func _generate_token() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var out := ""
	for i in range(32):
		out += chars[randi() % chars.length()]
	return out

func _load_port() -> int:
	var override := OS.get_environment("GODOT_LIVE_MCP_RUNTIME_PORT")
	if override != "":
		return int(override)
	return DEFAULT_PORT
