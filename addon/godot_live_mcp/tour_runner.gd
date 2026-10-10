extends Node

## Guided tours: a chain of highlights that advances by itself when each
## step's done_when check passes against the real editor state. The agent
## hands over a whole tour once (start_tour); from then on the editor
## drives it — no agent round trips between steps, and the same runner can
## play a saved tour with no AI at all. See TUTORIAL_TOOLS_PLAN.md.
##
## Unlike highlight_editor_control, outlines here survive unrelated edits:
## they only change when the step does.

const HighlightOverlay = preload("res://addons/godot_live_mcp/highlight_overlay.gd")
const FORMAT := "godot-live-tour/1"
const CHECK_TYPES := ["manual", "node_selected", "node_exists", "node_added", "property_equals", "scene_saved"]
const POLL_SEC := 0.5
const ALREADY_DONE_SEC := 1.5

var _bridge: Node = null  # bridge.gd: target resolution and node paths

var _tour := {}
var _steps: Array = []
var _index := -1
var _vars := {}           # name -> WeakRef(Node); follows renames and moves
var _events: Array = []
var _start_msec := 0
var _step_start_msec := 0
var _baseline := {}       # per-step snapshot for change-based checks
var _saved_during_step := false
var _done := false
var _check_queued := false
var _holding := false     # showing an already-done step; checks wait
var _poll := 0.0
var _gen := 0             # bumped on every step change; stale awaits bail out

var _overlay := HighlightOverlay.new()
var _card: PanelContainer = null
var _card_title: Label = null
var _card_text: RichTextLabel = null
var _card_next: Button = null

func setup(bridge: Node) -> void:
	_bridge = bridge

func _ready() -> void:
	set_process(false)

func is_running() -> bool:
	return _index >= 0

# ---- Public API (called by bridge.gd's _cmd_* wrappers) --------------------

## Validates the tour; unless dry_run, stops any running tour and starts
## this one. Returns {"ok", "errors"[, "steps"]}.
func start(tour: Dictionary, dry_run: bool) -> Dictionary:
	var errors := _validate(tour)
	if not errors.is_empty() or dry_run:
		return {"ok": errors.is_empty(), "errors": errors, "dry_run": dry_run}
	stop()
	_tour = tour
	_steps = tour.steps
	_events = []
	_done = false
	_vars = {}
	var initial: Dictionary = tour.get("vars", {})
	for name in initial:
		_vars[String(name)] = weakref(_bridge._resolve_node(String(initial[name])))
	_start_msec = Time.get_ticks_msec()
	_connect_signals()
	_build_card()
	set_process(true)
	# Not awaited: the reply shouldn't wait on target reveal or an
	# already-done pause.
	_enter_step(0)
	return {"ok": true, "errors": [], "steps": _steps.size(), "title": String(tour.get("title", ""))}

func stop() -> void:
	if _index >= 0 and not _done:
		_log("stopped")
	_gen += 1
	_index = -1
	_holding = false
	_overlay.clear()
	if _card != null and is_instance_valid(_card):
		_card.queue_free()
	_card = null
	_disconnect_signals()
	set_process(false)

func status() -> Dictionary:
	var vars := {}
	for name in _vars:
		var n = _vars[name].get_ref()
		vars[name] = _bridge._rel_path(n) if n is Node else null
	var out := {
		"running": is_running(),
		"done": _done,
		"title": String(_tour.get("title", "")),
		"steps": _steps.size(),
		"vars": vars,
		"events": _events,
	}
	if is_running() and not _done:
		out["step"] = _index + 1
		out["step_id"] = String(_steps[_index].get("id", ""))
		out["step_elapsed_sec"] = (Time.get_ticks_msec() - _step_start_msec) / 1000.0
	return out

# ---- Validation ------------------------------------------------------------

func _validate(tour: Dictionary) -> Array:
	var errors := []
	if String(tour.get("format", "")) != FORMAT:
		errors.append("format must be \"%s\"" % FORMAT)
	var steps = tour.get("steps", null)
	if typeof(steps) != TYPE_ARRAY or (steps as Array).is_empty():
		errors.append("steps must be a non-empty array")
		return errors
	if _bridge._get_scene_root() == null:
		errors.append("no scene is open in the editor")
		return errors
	var defined := {}
	var initial = tour.get("vars", {})
	if typeof(initial) != TYPE_DICTIONARY:
		errors.append("vars must be an object of name -> node path")
	else:
		for name in initial:
			if _bridge._resolve_node(String(initial[name])) == null:
				errors.append("vars.%s: node not found: %s" % [name, initial[name]])
			defined[String(name)] = true
	for i in (steps as Array).size():
		var step = steps[i]
		var where := "step %d" % (i + 1)
		if typeof(step) != TYPE_DICTIONARY:
			errors.append("%s: must be an object" % where)
			continue
		if String(step.get("id", "")) != "":
			where += " (%s)" % step.id
		if String(step.get("text", "")) == "":
			errors.append("%s: text is required" % where)
		for err in _vars_used(step.get("target", {}), defined):
			errors.append("%s: target uses %s before it is defined" % [where, err])
		var check = step.get("done_when", null)
		if typeof(check) != TYPE_DICTIONARY:
			errors.append("%s: done_when is required" % where)
			continue
		for err in _vars_used(check, defined):
			errors.append("%s: done_when uses %s before it is defined" % [where, err])
		var type := String(check.get("type", ""))
		if not type in CHECK_TYPES:
			errors.append("%s: unknown done_when type '%s' (expected one of %s)" % [where, type, ", ".join(CHECK_TYPES)])
			continue
		var need: Array = {
			"node_selected": ["node_path"], "node_exists": ["node_path"],
			"node_added": ["parent"], "property_equals": ["node_path", "property", "value"],
		}.get(type, [])
		for key in need:
			if not check.has(key):
				errors.append("%s: done_when type '%s' needs '%s'" % [where, type, key])
		if type == "node_added" and check.has("class") and not ClassDB.class_exists(String(check["class"])):
			errors.append("%s: unknown class '%s'" % [where, check["class"]])
		if check.has("capture"):
			if type != "node_added":
				errors.append("%s: capture only works with node_added" % where)
			defined[String(check.capture)] = true
	return errors

## Names of $vars referenced in d's string values that aren't defined yet.
func _vars_used(d, defined: Dictionary) -> Array:
	var missing := []
	if typeof(d) != TYPE_DICTIONARY:
		return missing
	for key in d:
		if key == "capture":
			continue
		var v = d[key]
		if typeof(v) == TYPE_STRING and String(v).begins_with("$"):
			var name := String(v).substr(1).get_slice("/", 0)
			if not defined.has(name):
				missing.append("$" + name)
	return missing

# ---- Variables -------------------------------------------------------------

## "$player" -> the node's current path; "$player/Sprite" -> child of it.
func _sub(path: String) -> String:
	if not path.begins_with("$"):
		return path
	var name := path.substr(1).get_slice("/", 0)
	var rest := path.substr(1 + name.length())
	var n = _vars[name].get_ref() if _vars.has(name) else null
	if not n is Node:
		return "<missing $%s>" % name
	return _bridge._rel_path(n) + rest

func _node(path: String) -> Node:
	return _bridge._resolve_node(_sub(path))

func _sub_all(d: Dictionary) -> Dictionary:
	var out := {}
	for key in d:
		out[key] = _sub(String(d[key])) if typeof(d[key]) == TYPE_STRING else d[key]
	return out

# ---- Steps -----------------------------------------------------------------

func _enter_step(i: int) -> void:
	_gen += 1
	var gen := _gen
	_index = i
	_step_start_msec = Time.get_ticks_msec()
	_saved_during_step = false
	_overlay.clear()
	var step: Dictionary = _steps[i]
	var check: Dictionary = step.done_when
	_baseline = {}
	if String(check.type) == "node_added":
		var parent := _node(String(check.parent))
		var ids := {}
		if parent != null:
			for c in parent.get_children():
				ids[c.get_instance_id()] = true
		_baseline["children"] = ids
	_log("step_started")
	_show_card(step, "")
	var target = step.get("target", null)
	if typeof(target) == TYPE_DICTIONARY and not (target as Dictionary).is_empty():
		var t := _sub_all(target)
		var res: Dictionary = await _bridge._hl_resolve_target(t, false)
		if gen != _gen:
			return
		if res.has("error"):
			_log("target_missing", {"error": res.error})
			_show_card(step, "I can't point at this one — " + String(res.error))
		elif res.has("tree"):
			_overlay.add_tree_item(res.tree, res.item_path, String(target.get("label", "")))
		else:
			_overlay.add_control(res.control, String(target.get("label", "")))
	# Already true before the user did anything (e.g. the node was selected
	# anyway): still show the step for a moment so it isn't skipped unseen.
	if String(check.type) != "manual" and _check_passes(check):
		_log("already_done")
		_show_card(step, "✓ Already done — moving on…")
		_holding = true
		await get_tree().create_timer(ALREADY_DONE_SEC).timeout
		_holding = false
		if gen != _gen:
			return
		await _advance()
		return
	_queue_check()

func _advance() -> void:
	_log("step_done")
	if _index + 1 >= _steps.size():
		_finish()
	else:
		await _enter_step(_index + 1)

func _finish() -> void:
	_done = true
	_gen += 1
	_overlay.clear()
	_log("tour_done")
	_card_title.text = "Done!"
	_card_text.text = "You finished [b]%s[/b]." % _escape(String(_tour.get("title", "the tour")))
	_card_next.visible = false

# ---- Completion checks -----------------------------------------------------

func _queue_check() -> void:
	if not _check_queued and not _holding and is_running() and not _done:
		_check_queued = true
		_run_check.call_deferred()

func _run_check() -> void:
	_check_queued = false
	if not is_running() or _done:
		return
	var check: Dictionary = _steps[_index].done_when
	if _check_passes(check):
		await _advance()

func _check_passes(check: Dictionary) -> bool:
	match String(check.type):
		"manual":
			return false  # the card's Next button advances
		"node_selected":
			var n := _node(String(check.node_path))
			return n != null and n in EditorInterface.get_selection().get_selected_nodes()
		"node_exists":
			return _node(String(check.node_path)) != null
		"node_added":
			var parent := _node(String(check.parent))
			if parent == null:
				return false
			var known: Dictionary = _baseline.get("children", {})
			for c in parent.get_children():
				if known.has(c.get_instance_id()):
					continue
				if check.has("class") and not c.is_class(String(check["class"])):
					continue
				if check.has("capture"):
					_vars[String(check.capture)] = weakref(c)
				return true
			return false
		"property_equals":
			var n := _node(String(check.node_path))
			if n == null:
				return false
			var actual = n.get_indexed(NodePath(String(check.property)))
			var expected = _bridge._decode_value(String(check.value))
			return _matches(actual, expected, float(check.get("tolerance", 0.0001)))
		"scene_saved":
			return _saved_during_step
	return false

func _matches(a, b, tol: float) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return absf(float(a) - float(b)) <= tol
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			return (a - b).length() <= tol
		TYPE_COLOR:
			return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol and absf(a.a - b.a) <= tol
	return a == b

## Editor signals that cover nearly every user change; the poll in
## _process is the backstop for anything they miss.
func _connect_signals() -> void:
	EditorInterface.get_editor_undo_redo().history_changed.connect(_queue_check)
	EditorInterface.get_inspector().property_edited.connect(_on_property_edited)
	EditorInterface.get_selection().selection_changed.connect(_queue_check)
	var plugin: EditorPlugin = _bridge._editor_plugin
	if plugin:
		plugin.scene_saved.connect(_on_scene_saved)
		plugin.scene_changed.connect(_on_scene_changed)

func _disconnect_signals() -> void:
	var undo := EditorInterface.get_editor_undo_redo()
	if undo.history_changed.is_connected(_queue_check):
		undo.history_changed.disconnect(_queue_check)
	var inspector := EditorInterface.get_inspector()
	if inspector.property_edited.is_connected(_on_property_edited):
		inspector.property_edited.disconnect(_on_property_edited)
	var sel := EditorInterface.get_selection()
	if sel.selection_changed.is_connected(_queue_check):
		sel.selection_changed.disconnect(_queue_check)
	var plugin: EditorPlugin = _bridge._editor_plugin if _bridge else null
	if plugin:
		if plugin.scene_saved.is_connected(_on_scene_saved):
			plugin.scene_saved.disconnect(_on_scene_saved)
		if plugin.scene_changed.is_connected(_on_scene_changed):
			plugin.scene_changed.disconnect(_on_scene_changed)

func _on_property_edited(_property: String) -> void:
	_queue_check()

func _on_scene_saved(_path: String) -> void:
	_saved_during_step = true
	_queue_check()

func _on_scene_changed(_root: Node) -> void:
	_queue_check()

func _process(delta: float) -> void:
	if not _overlay.is_empty():
		_overlay.update()
	_place_card()
	_poll += delta
	if _poll >= POLL_SEC:
		_poll = 0.0
		_queue_check()

# ---- Tour card -------------------------------------------------------------

func _build_card() -> void:
	_card = PanelContainer.new()
	_card.name = "GodotLiveMCPTourCard"
	_card.z_index = 101
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.custom_minimum_size = Vector2(320, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.17, 0.97)
	sb.border_color = Color(0.25, 0.95, 0.4, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	_card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_card.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	_card_title = Label.new()
	_card_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_title.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	head.add_child(_card_title)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.tooltip_text = "End the tour"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(stop)
	head.add_child(close)
	_card_text = RichTextLabel.new()
	_card_text.bbcode_enabled = true
	_card_text.fit_content = true
	_card_text.scroll_active = false
	_card_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_text.custom_minimum_size = Vector2(300, 0)
	_card_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_card_text)
	_card_next = Button.new()
	_card_next.text = "Next ▸"
	_card_next.focus_mode = Control.FOCUS_NONE
	_card_next.size_flags_horizontal = Control.SIZE_SHRINK_END
	_card_next.pressed.connect(_on_next_pressed)
	box.add_child(_card_next)
	EditorInterface.get_base_control().add_child(_card)

func _show_card(step: Dictionary, note: String) -> void:
	if _card == null:
		return
	_card_title.text = "%s  ·  Step %d/%d" % [String(_tour.get("title", "Tour")), _index + 1, _steps.size()]
	var text := _markdown(String(step.text))
	if note != "":
		var colour := "#60e080" if note.begins_with("✓") else "#e0b050"
		text += "\n[i][color=%s]%s[/color][/i]" % [colour, _escape(note)]
	_card_text.text = text
	_card_next.visible = String(step.done_when.type) == "manual"

func _on_next_pressed() -> void:
	if is_running() and not _done and String(_steps[_index].done_when.type) == "manual":
		await _advance()

## Beside the outline (right of it, else left, else below), or the
## bottom-right corner when nothing is outlined. Kept on screen.
func _place_card() -> void:
	if _card == null or not is_instance_valid(_card):
		return
	var screen := EditorInterface.get_base_control().get_global_rect()
	var size := _card.get_combined_minimum_size()
	_card.size = size
	var target := _overlay.visible_rect()
	var pos: Vector2
	if not target.has_area():
		pos = screen.end - size - Vector2(24, 48)
	elif target.end.x + 12 + size.x <= screen.end.x:
		pos = Vector2(target.end.x + 12, target.position.y)
	elif target.position.x - 12 - size.x >= screen.position.x:
		pos = Vector2(target.position.x - 12 - size.x, target.position.y)
	else:
		pos = Vector2(target.position.x, target.end.y + 28)
	pos.x = clampf(pos.x, screen.position.x + 8, screen.end.x - size.x - 8)
	pos.y = clampf(pos.y, screen.position.y + 8, screen.end.y - size.y - 8)
	_card.global_position = pos

## **bold** and `code` only; everything else is literal text.
func _markdown(src: String) -> String:
	var out := _escape(src)
	var bold := RegEx.create_from_string("\\*\\*(.+?)\\*\\*")
	out = bold.sub(out, "[b]$1[/b]", true)
	var code := RegEx.create_from_string("`(.+?)`")
	out = code.sub(out, "[code]$1[/code]", true)
	return out

func _escape(s: String) -> String:
	return s.replace("[", "[lb]")

func _log(type: String, extra := {}) -> void:
	var e := {"t": (Time.get_ticks_msec() - _start_msec) / 1000.0, "type": type}
	if _index >= 0 and _index < _steps.size():
		e["step"] = _index + 1
	e.merge(extra)
	_events.append(e)
