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
const TourRecorder = preload("res://addons/godot_live_mcp/tour_recorder.gd")
const FORMAT := "godot-live-tour/1"
const TOURS_DIR := "res://tours"
const TOUR_EXT := ".tour.json"
const POLL_SEC := 0.5
const ALREADY_DONE_SEC := 1.5
const STUCK_SEC := 90.0
const RESOLVE_TRIES := 3
const RESOLVE_RETRY_SEC := 0.35

## Bridge commands a step's show_me may run (all undoable). Params use the
## bridge's own names; "$var" works in any string value or node_paths entry.
const SHOW_ME_COMMANDS := ["select_nodes", "add_node_live", "set_property", "rename_node",
	"reparent_node", "remove_node", "connect_signal", "set_node_groups", "attach_script", "save_scene_live"]

## Required fields per done_when type ("@target" = the step itself must have
## a target, the control to watch).
const CHECK_FIELDS := {
	"manual": [],
	"node_selected": ["node_path"],
	"node_exists": ["node_path"],
	"node_added": ["parent"],
	"node_removed": ["node_path"],
	"node_renamed": ["node_path", "name"],
	"node_reparented": ["node_path", "parent"],
	"property_equals": ["node_path", "property", "value"],
	"property_changed": ["node_path", "property"],
	"property_class": ["node_path", "property", "class"],
	"script_attached": ["node_path"],
	"signal_connected": ["source", "signal", "target"],
	"in_group": ["node_path", "group"],
	"scene_open": ["path"],
	"scene_saved": [],
	"file_exists": ["path"],
	"control_pressed": ["@target"],
	"game_running": [],
	"all": ["checks"],
	"any": ["checks"],
}

var _bridge: Node = null  # bridge.gd: target resolution and node paths

var _tour := {}
var _source_path := ""    # the file the running tour was loaded from ("" = from the agent)
var _steps: Array = []
var _index := -1
var _vars := {}           # name -> WeakRef(Node); follows renames and moves
var _events: Array = []
var _start_msec := 0
var _step_start_msec := 0
var _baseline := {}       # per-step snapshots for change-based checks, by check key
var _saved_during_step := false
var _pressed_during_step := false
var _pressed_conn := []   # [BaseButton (WeakRef), Callable] while a step listens for a press
var _done := false
var _revisit := false     # entered with Back: no auto-advance, Next continues
var _check_queued := false
var _holding := false     # showing an already-done step; checks wait
var _resolving := false
var _poll := 0.0
var _lost_poll := 0.0
var _gen := 0             # bumped on every step change; stale awaits bail out

# Card notes, shown in this order under the step text.
var _note_target := ""    # can't point / select the node again
var _note_hint := ""      # wrong-turn hint
var _note_stuck := ""
var _note_why := ""       # the step's why text, or "asked the agent"
var _showing := false     # a Show me is running
var _pointed_at_new := false   # a node_added+name step moved its outline to the new node
var _pointing_at_fold := false  # outlining a folded section until it's opened
var _hints_logged := {}
var _stuck_logged := false

var _overlay := HighlightOverlay.new()
var _card: PanelContainer = null
var _card_title: Label = null
var _card_text: RichTextLabel = null
var _card_back: Button = null
var _card_skip: Button = null
var _card_next: Button = null
var _card_show: Button = null
var _card_why: Button = null
var _card_save: Button = null
var _card_close: Button = null  # the Done card's main action
var _card_pinned := false   # the user dragged the card: keep it where they put it
var _card_drag := Vector2.ZERO  # grab offset while dragging
var _card_dragging := false

func setup(bridge: Node) -> void:
	_bridge = bridge

var _recorder: Node = null

## Record mode (tour_recorder.gd), created on first use.
func recorder() -> Node:
	if _recorder == null or not is_instance_valid(_recorder):
		_recorder = TourRecorder.new()
		_recorder.name = "TourRecorder"
		_recorder.setup(_bridge, self)
		add_child(_recorder)
	return _recorder

func _ready() -> void:
	set_process(false)

func is_running() -> bool:
	return _index >= 0

# ---- Public API (called by bridge.gd's _cmd_* wrappers) --------------------

## Validates the tour; unless dry_run, stops any running tour and starts
## this one. Returns {"ok", "errors", "warnings"[, "steps", "title"]}.
func start(tour: Dictionary, dry_run: bool, source_path := "") -> Dictionary:
	var warnings := []
	var errors := _validate(tour, warnings)
	if not errors.is_empty() or dry_run:
		return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "dry_run": dry_run}
	stop()
	_tour = tour
	_source_path = source_path
	_steps = tour.steps
	_events = []
	_done = false
	_vars = {}
	var initial: Dictionary = tour.get("vars", {})
	for name in initial:
		_vars[String(name)] = weakref(_resolve_var(initial[name]))
	_start_msec = Time.get_ticks_msec()
	_connect_signals()
	_build_card()
	set_process(true)
	# Not awaited: the reply shouldn't wait on target reveal or an
	# already-done pause.
	_enter_step(0)
	return {"ok": true, "errors": [], "warnings": warnings, "steps": _steps.size(), "title": String(tour.get("title", ""))}

func stop() -> void:
	if _index >= 0 and not _done:
		_log("stopped")
	_gen += 1
	_index = -1
	_holding = false
	_resolving = false
	_showing = false
	_overlay.clear()
	_unlisten_press()
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
		"source": _source_path if _source_path != "" else "agent",
		"vars": vars,
		"events": _events,
	}
	if is_running() and not _done:
		out["step"] = _index + 1
		out["step_id"] = String(_steps[_index].get("id", ""))
		out["step_elapsed_sec"] = (Time.get_ticks_msec() - _step_start_msec) / 1000.0
		for key in ["target", "hint", "stuck"]:
			var note: String = {"target": _note_target, "hint": _note_hint, "stuck": _note_stuck}[key]
			if note != "":
				out["note_" + key] = note
	return out

# ---- Tour files ------------------------------------------------------------
#
# A tour file is the same JSON the agent sends to start_tour. Tours are data:
# completion checks are declarative, there are no expressions, and Show me
# only runs the allow-listed undoable editor commands, on the user's click.
# A tour can't bring code with it: show_me may only attach scripts that
# already exist in the project.

## {"tour": Dictionary} or {"error": String}.
func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "no such file: %s" % path}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"error": "%s is not a JSON object" % path}
	return {"tour": parsed}

## Writes the running (or last) tour to path, default
## res://tours/<title>.tour.json. Returns {"path"} or {"error"}.
func save(path := "") -> Dictionary:
	if _tour.is_empty():
		return {"error": "no tour has been started in this editor session"}
	if path == "":
		var slug := String(_tour.get("title", "tour")).to_snake_case().validate_filename()
		path = "%s/%s%s" % [TOURS_DIR, slug if slug != "" else "tour", TOUR_EXT]
	if not path.begins_with("res://") or not path.ends_with(TOUR_EXT):
		return {"error": "path must be under res:// and end in %s" % TOUR_EXT}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "can't write %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(JSON.stringify(_tour, "\t", false))
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	_log("saved", {"path": path})
	return {"path": path}

## Every *.tour.json in the project (outside addons/ and .godot/).
func list_files() -> Array:
	var out := []
	_scan_tours("res://", out)
	return out

func _scan_tours(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		if sub.begins_with(".") or (dir == "res://" and sub == "addons"):
			continue
		_scan_tours(dir.path_join(sub), out)
	for file in d.get_files():
		if file.ends_with(TOUR_EXT):
			var path := dir.path_join(file)
			var res := load_file(path)
			var entry := {"path": path}
			if res.has("error"):
				entry["error"] = res.error
			else:
				entry["title"] = String(res.tour.get("title", file))
				entry["steps"] = (res.tour.get("steps", []) as Array).size() if typeof(res.tour.get("steps")) == TYPE_ARRAY else 0
				var req = res.tour.get("requires", {})
				if typeof(req) == TYPE_DICTIONARY and req.has("scene_open"):
					entry["scene"] = String(req.scene_open)
			out.append(entry)

## Plays a tour file. If it requires a scene that isn't the one open, opens
## that scene first. Returns start()'s result, or {"ok": false, "errors"}.
func play_file(path: String) -> Dictionary:
	var res := load_file(path)
	if res.has("error"):
		return {"ok": false, "errors": [res.error], "warnings": []}
	var tour: Dictionary = res.tour
	var req = tour.get("requires", {})
	if typeof(req) == TYPE_DICTIONARY and req.has("scene_open"):
		var want := String(req.scene_open)
		var root: Node = _bridge._get_scene_root()
		if (root == null or root.scene_file_path != want) and ResourceLoader.exists(want):
			EditorInterface.open_scene_from_path(want)
			await get_tree().process_frame
			await get_tree().process_frame
	return await start(tour, false, path)

## Editor menu: Project > Tools > Guided Tours… — pick a tour file and
## play it, no agent involved.
func open_picker() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Guided Tours"
	dialog.ok_button_text = "Start tour"
	# Record mode: do the task once yourself and get a draft tour.
	dialog.add_button("Record new tour…", true, "record")
	dialog.custom_action.connect(func(action: StringName) -> void:
		if action == &"record":
			dialog.hide()
			var res: Dictionary = recorder().start()
			if res.has("error"):
				_alert(String(res.error)))
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var tours := list_files()
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(460, 240)
	for entry in tours:
		var label := String(entry.get("title", entry.path))
		if entry.has("error"):
			label += "  (unreadable)"
		elif entry.has("steps"):
			label += "  ·  %d steps" % entry.steps
		list.add_item(label)
		list.set_item_tooltip(list.item_count - 1, String(entry.path))
	box.add_child(list)
	var hint := Label.new()
	hint.text = "Tours are *%s files in your project. Record one (do the task yourself while recording), or ask the agent for a tour and press Save on its last card." % TOUR_EXT if tours.is_empty() \
		else "Double-click a tour, or select it and press Start tour. Record new tour… captures a task you do yourself."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(460, 0)
	box.add_child(hint)
	var play := func(i: int) -> void:
		dialog.hide()
		var result: Dictionary = await play_file(String(tours[i].path))
		if not result.get("ok", false):
			_alert("This tour can't start here:\n\n• " + "\n• ".join(result.get("errors", [])))
	list.item_activated.connect(play)
	dialog.confirmed.connect(func() -> void:
		var sel := list.get_selected_items()
		if not sel.is_empty():
			play.call(sel[0]))
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free.call_deferred())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	if not tours.is_empty():
		list.select(0)

func _alert(text: String) -> void:
	var d := AcceptDialog.new()
	d.title = "Guided Tours"
	d.dialog_text = text
	d.visibility_changed.connect(func() -> void:
		if not d.visible:
			d.queue_free.call_deferred())
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered()

# ---- Validation ------------------------------------------------------------

func _validate(tour: Dictionary, warnings: Array) -> Array:
	var errors := []
	if String(tour.get("format", "")) != FORMAT:
		errors.append("format must be \"%s\"" % FORMAT)
	var steps = tour.get("steps", null)
	if typeof(steps) != TYPE_ARRAY or (steps as Array).is_empty():
		errors.append("steps must be a non-empty array")
		return errors
	var root: Node = _bridge._get_scene_root()
	if root == null:
		errors.append("no scene is open in the editor")
		return errors
	var req = tour.get("requires", {})
	if typeof(req) == TYPE_DICTIONARY:
		if req.has("scene_open") and root.scene_file_path != String(req.scene_open):
			errors.append("requires.scene_open: %s is not the scene open in the editor (%s)" % [req.scene_open, root.scene_file_path])
		for p in req.get("node_exists", []):
			if _bridge._resolve_node(String(p)) == null:
				errors.append("requires.node_exists: node not found: %s" % p)
	# var name -> class name (initial vars: the node's class; captures: the
	# node_added class, or "" when any class is accepted)
	var var_class := {}
	var initial = tour.get("vars", {})
	if typeof(initial) != TYPE_DICTIONARY:
		errors.append("vars must be an object of name -> node path or {class, hint?}")
	else:
		for name in initial:
			var spec = initial[name]
			if typeof(spec) == TYPE_DICTIONARY and not ClassDB.class_exists(String(spec.get("class", ""))):
				errors.append("vars.%s: unknown class '%s'" % [name, spec.get("class", "")])
				continue
			var n: Node = _resolve_var(spec)
			if n == null:
				if typeof(spec) == TYPE_DICTIONARY:
					var msg := "vars.%s: this tour needs a %s in the scene" % [name, spec["class"]]
					if String(spec.get("name", "")) != "":
						msg += " named '%s'" % spec.name
					if String(spec.get("hint", "")) != "":
						msg += " — " + String(spec.hint)
					errors.append(msg)
				else:
					errors.append("vars.%s: node not found: %s" % [name, spec])
			var_class[String(name)] = n.get_class() if n != null else ""
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
		var target = step.get("target", {})
		if typeof(target) == TYPE_DICTIONARY and not (target as Dictionary).is_empty():
			for v in _vars_used(target, var_class):
				errors.append("%s: target uses %s before it is defined" % [where, v])
			if target.has("property") and target.has("node_path"):
				_check_property(String(target.node_path), String(target.property), var_class, where + ": target", errors)
			elif not target.has("node_path") and not target.has("property"):
				# An editor control: may legitimately appear later (a dialog),
				# so only a warning when it can't be found right now.
				var found = _bridge._ctl_find(target, "path", "text", "class")
				if found is String:
					warnings.append("%s: target not found right now (%s); fine if it only appears later" % [where, found])
		var check = step.get("done_when", null)
		if typeof(check) != TYPE_DICTIONARY:
			errors.append("%s: done_when is required" % where)
			continue
		_validate_check(check, step, where + ": done_when", var_class, errors)
		if step.has("why") and typeof(step.why) != TYPE_STRING:
			errors.append("%s: why must be a string" % where)
		if step.has("show_me"):
			if typeof(step.show_me) != TYPE_ARRAY:
				errors.append("%s: show_me must be an array of {command, ...params}" % where)
			else:
				for action in step.show_me:
					if typeof(action) != TYPE_DICTIONARY or not String(action.get("command", "")) in SHOW_ME_COMMANDS:
						errors.append("%s: show_me commands must be one of %s" % [where, ", ".join(SHOW_ME_COMMANDS)])
						break
					if String(action.command) == "attach_script" and not ResourceLoader.exists(String(action.get("script_path", ""))):
						errors.append("%s: show_me can only attach a script that already exists in the project (%s)" % [where, action.get("script_path", "")])
	return errors

func _validate_check(check: Dictionary, step: Dictionary, where: String, var_class: Dictionary, errors: Array) -> void:
	var type := String(check.get("type", ""))
	if not CHECK_FIELDS.has(type):
		errors.append("%s: unknown type '%s' (expected one of %s)" % [where, type, ", ".join(CHECK_FIELDS.keys())])
		return
	for v in _vars_used(check, var_class):
		errors.append("%s uses %s before it is defined" % [where, v])
	for field in CHECK_FIELDS[type]:
		if field == "@target":
			if typeof(step.get("target", null)) != TYPE_DICTIONARY:
				errors.append("%s: type '%s' needs the step to have a target (the control to press)" % [where, type])
		elif not check.has(field):
			errors.append("%s: type '%s' needs '%s'" % [where, type, field])
	if type == "node_added" and check.has("name") and String(check.name).validate_node_name() != String(check.name):
		errors.append("%s: '%s' isn't a valid node name" % [where, check.name])
	if check.has("class") and type in ["node_added", "property_class"] and not ClassDB.class_exists(String(check["class"])):
		errors.append("%s: unknown class '%s'" % [where, check["class"]])
	if type in ["property_equals", "property_changed", "property_class"] and check.has("node_path") and check.has("property"):
		_check_property(String(check.node_path), String(check.property), var_class, where, errors)
	if type == "signal_connected" and check.has("source") and check.has("signal"):
		var cls := _class_of(String(check.source), var_class)
		if cls != "" and not ClassDB.class_has_signal(cls, String(check.signal)):
			var n: Node = _bridge._resolve_node(String(check.source)) if not String(check.source).begins_with("$") else null
			if n == null or not n.has_signal(String(check.signal)):
				errors.append("%s: %s has no signal '%s'" % [where, cls, check.signal])
	if type in ["all", "any"]:
		var subs = check.get("checks", [])
		if typeof(subs) != TYPE_ARRAY or (subs as Array).is_empty():
			errors.append("%s: '%s' needs a non-empty checks array" % [where, type])
		else:
			for j in (subs as Array).size():
				if typeof(subs[j]) != TYPE_DICTIONARY:
					errors.append("%s.checks[%d]: must be an object" % [where, j])
				else:
					_validate_check(subs[j], step, "%s.checks[%d]" % [where, j], var_class, errors)
	if check.has("capture"):
		if type != "node_added":
			errors.append("%s: capture only works with node_added" % where)
		else:
			var_class[String(check.capture)] = String(check.get("class", ""))

## The class a node path will have: the node's own class for an existing
## node or initial var, the node_added class for a capture, "" if unknown.
func _class_of(path: String, var_class: Dictionary) -> String:
	if path.begins_with("$"):
		var name := path.substr(1).get_slice("/", 0)
		if path.contains("/"):
			return ""
		return String(var_class.get(name, ""))
	var n: Node = _bridge._resolve_node(path)
	return n.get_class() if n != null else ""

func _check_property(path: String, prop: String, var_class: Dictionary, where: String, errors: Array) -> void:
	var base := prop.get_slice(":", 0)
	if not path.begins_with("$"):
		var n: Node = _bridge._resolve_node(path)
		if n != null:
			for p in n.get_property_list():
				if p.name == base:
					return
			errors.append("%s: %s has no property '%s'" % [where, n.get_class(), base])
		return
	var cls := _class_of(path, var_class)
	if cls == "" or not ClassDB.class_exists(cls):
		return
	for p in ClassDB.class_get_property_list(cls):
		if p.name == base:
			return
	errors.append("%s: %s has no property '%s'" % [where, cls, base])

## A vars entry: a node path, or {"class": "CharacterBody2D"} for the first
## node of that class in the scene (whatever the user named it), optionally
## {"name": …} too when the scene may hold several — lets one tour build on
## what an earlier tour made.
func _resolve_var(spec) -> Node:
	if typeof(spec) == TYPE_DICTIONARY:
		var cls := String(spec.get("class", ""))
		var want_name := String(spec.get("name", ""))
		for n in _all_nodes():
			if n.is_class(cls) and (want_name == "" or String(n.name) == want_name):
				return n
		return null
	return _bridge._resolve_node(String(spec))

## Names of $vars referenced in d's string values that aren't defined yet.
func _vars_used(d, defined: Dictionary) -> Array:
	var missing := []
	if typeof(d) != TYPE_DICTIONARY:
		return missing
	for key in d:
		if key == "capture" or key == "checks":
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
	var p := _sub(path)
	return null if p.begins_with("<missing") else _bridge._resolve_node(p)

func _sub_all(d: Dictionary) -> Dictionary:
	var out := {}
	for key in d:
		out[key] = _sub(String(d[key])) if typeof(d[key]) == TYPE_STRING else d[key]
	return out

## True if the step refers to a var that a skipped step should have set.
func _needs_missing_var(step: Dictionary) -> bool:
	for d in [step.get("target", {}), step.done_when]:
		if typeof(d) == TYPE_DICTIONARY:
			for key in d:
				if typeof(d[key]) == TYPE_STRING and _sub(String(d[key])).begins_with("<missing"):
					return true
	return false

# ---- Steps -----------------------------------------------------------------

func _enter_step(i: int, revisit := false) -> void:
	_gen += 1
	var gen := _gen
	_index = i
	_revisit = revisit
	_step_start_msec = Time.get_ticks_msec()
	_saved_during_step = false
	_pressed_during_step = false
	_note_target = ""
	_note_hint = ""
	_note_stuck = ""
	_note_why = ""
	_hints_logged = {}
	_stuck_logged = false
	_overlay.clear()
	_unlisten_press()
	_pointing_at_fold = false
	_pointed_at_new = false
	var step: Dictionary = _steps[i]
	_baseline = {}
	_snapshot(step.done_when, "c")
	_log("back_to_step" if revisit else "step_started")
	if _needs_missing_var(step):
		_note_target = "This step depends on an earlier one that was skipped — go Back, or Skip this one too."
	_refresh_card()
	await _point(gen)
	if gen != _gen:
		return
	if revisit:
		if _passes(step.done_when, "c"):
			_note_hint = "✓ Already done — press Next to continue."
			_refresh_card()
		return
	# Already true before the user did anything (e.g. the node was selected
	# anyway): still show the step for a moment so it isn't skipped unseen.
	if String(step.done_when.type) != "manual" and _passes(step.done_when, "c"):
		_log("already_done")
		_note_hint = "✓ Already done — moving on…"
		_refresh_card()
		_holding = true
		await get_tree().create_timer(ALREADY_DONE_SEC).timeout
		_holding = false
		if gen != _gen:
			return
		await _advance("step_done")
		return
	_queue_check()

## Outlines the current step's target, retrying briefly while the editor
## settles. If it still can't be found, the step runs without an outline
## and says so on the card — a broken pointer never blocks the tour.
func _point(gen: int) -> void:
	var step: Dictionary = _steps[_index]
	var target = step.get("target", null)
	if typeof(target) != TYPE_DICTIONARY or (target as Dictionary).is_empty() or _needs_missing_var(step):
		return
	_resolving = true
	var t := _sub_all(target)
	var res := {}
	for attempt in RESOLVE_TRIES:
		res = await _bridge._hl_resolve_target(t, false)
		if gen != _gen:
			return
		if not res.has("error"):
			break
		await get_tree().create_timer(RESOLVE_RETRY_SEC).timeout
		if gen != _gen:
			return
	_resolving = false
	_overlay.clear()
	if res.has("error"):
		if _note_target == "":
			_log("target_missing", {"error": res.error})
		_note_target = "I can't point at this one (%s)." % res.error
	else:
		_note_target = ""
		var label := String(target.get("label", ""))
		if res.has("tree"):
			_overlay.add_tree_item(res.tree, res.item_path, label)
		else:
			_overlay.add_control(res.control, label)
			_pointing_at_fold = bool(res.entry.get("folded", false))
			if _pointing_at_fold:
				_note_target = "It's inside the outlined section — click its heading to open it."
			if res.control is BaseButton:
				_unlisten_press()
				var cb := _on_target_pressed.bind(gen)
				(res.control as BaseButton).pressed.connect(cb)
				_pressed_conn = [weakref(res.control), cb]
	_refresh_card()

## The outlined control was freed (e.g. the Inspector switched node): point
## again. A property row is only re-found once the Inspector shows that
## node again — re-opening it ourselves would yank the user's view away.
func _repoint_if_lost() -> void:
	if _resolving or _holding or _done or not is_running():
		return
	var step: Dictionary = _steps[_index]
	var target = step.get("target", null)
	if typeof(target) != TYPE_DICTIONARY or (target as Dictionary).is_empty() or _needs_missing_var(step):
		return
	if _pointing_at_fold:
		# Once the section is opened, swap to the property row itself.
		var prop := String(target.get("property", ""))
		for ep in EditorInterface.get_inspector().find_children("*", "EditorProperty", true, false):
			if String((ep as EditorProperty).get_edited_property()) == prop and (ep as Control).is_visible_in_tree():
				_pointing_at_fold = false
				_overlay.clear()
				_overlay.add_control(ep, String(target.get("label", "")))
				_note_target = ""
				_refresh_card()
				return
		return
	if _overlay.first_target() != null:
		return
	if target.has("property") and target.has("node_path"):
		var n := _node(String(target.node_path))
		if n != null and EditorInterface.get_inspector().get_edited_object() != n:
			var note := "Select **%s** again to see this setting." % n.name
			if _note_target != note:
				_note_target = note
				_refresh_card()
			return
	await _point(_gen)

func _advance(event: String) -> void:
	_log(event)
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
	_card_back.visible = false
	_card_skip.visible = false
	_card_next.visible = false
	_card_show.visible = false
	_card_why.visible = false
	_card_save.visible = _source_path == ""
	_card_close.visible = true

func _on_back_pressed() -> void:
	if is_running() and not _done and _index > 0:
		_holding = false
		await _enter_step(_index - 1, true)

func _on_skip_pressed() -> void:
	if is_running() and not _done:
		_holding = false
		await _advance("skipped")

func _on_next_pressed() -> void:
	if is_running() and not _done and (_revisit or String(_steps[_index].done_when.type) == "manual"):
		await _advance("step_done")

## "Why?": the step's own why text first (works offline, in saved tours);
## pressed again, or when there is none, the question goes to the agent in
## the AI Assistant panel with the tour context.
func _on_why_pressed() -> void:
	if not is_running() or _done:
		return
	var step: Dictionary = _steps[_index]
	var why := _name_vars(String(step.get("why", "")))
	if why != "" and _note_why != why:
		_note_why = why
		_log("why_shown")
		_refresh_card()
		return
	var panel := _agent_panel()
	if panel == null:
		return
	var question := "[Guided tour \"%s\", step %d/%d: %s] Why do I do this step? Explain briefly in plain language — don't do it for me, and don't change the scene." % [
		String(_tour.get("title", "")), _index + 1, _steps.size(), _name_vars(String(step.text))]
	var err: String = panel.ask(question)
	_log("why_asked", {"sent": err == ""} if err == "" else {"sent": false, "error": err})
	if err == "":
		_bridge._editor_plugin.make_bottom_panel_item_visible(panel)
		_note_why = (why + "\n" if why != "" else "") + "Asked the agent — see the AI Assistant panel."
	else:
		_note_why = (why + "\n" if why != "" else "") + "Couldn't ask the agent: " + err
	_refresh_card()

## The in-editor AI Assistant panel, if the plugin has one.
func _agent_panel() -> Node:
	var plugin = _bridge._editor_plugin if _bridge else null
	if plugin == null:
		return null
	var panel = plugin.get("_assistant_panel")
	return panel if panel is Node and is_instance_valid(panel) and panel.has_method("ask") else null

## "Show me": does the step for the user through the bridge's own undoable
## commands; the step then completes through its normal check.
func _on_show_me_pressed() -> void:
	if not is_running() or _done or _showing:
		return
	var actions := _show_me_actions(_steps[_index])
	if actions.is_empty():
		return
	var gen := _gen
	_showing = true
	_refresh_card()
	_log("show_me")
	for action in actions:
		var params: Dictionary = action.duplicate()
		var command := String(params.get("command", ""))
		params.erase("command")
		var res = await _bridge.call("_cmd_" + command, params)
		if gen != _gen:
			_showing = false
			return
		if typeof(res) == TYPE_DICTIONARY and res.has("__error__"):
			_showing = false
			_log("show_me_failed", {"command": command, "error": res["__error__"]})
			_note_hint = "Couldn't show this one: %s" % res["__error__"]
			_refresh_card()
			return
	_showing = false
	if actions.size() > 1:
		_note_hint = "Done for you — Ctrl+Z %d times to undo." % actions.size()
	else:
		_note_hint = "Done for you — Ctrl+Z to undo."
	_refresh_card()
	_queue_check()

## The step's show_me actions with $vars filled in, or ones derived from its
## done_when check; [] when the step can't be shown.
func _show_me_actions(step: Dictionary) -> Array:
	var raw = step.get("show_me", null)
	var actions: Array = raw if typeof(raw) == TYPE_ARRAY else _derive_show_me(step.done_when)
	var out := []
	for action in actions:
		var a := {}
		for key in action:
			var v = action[key]
			if typeof(v) == TYPE_STRING:
				v = _sub(String(v))
				if String(v).begins_with("<missing"):
					return []
			elif typeof(v) == TYPE_ARRAY:
				var arr := []
				for item in v:
					arr.append(_sub(String(item)) if typeof(item) == TYPE_STRING else item)
				v = arr
			a[key] = v
		out.append(a)
	return out

func _derive_show_me(check: Dictionary) -> Array:
	match String(check.type):
		"node_selected":
			return [{"command": "select_nodes", "node_paths": [check.node_path]}]
		"node_added":
			if check.has("class"):
				return [{"command": "add_node_live", "parent_path": check.parent, "node_type": check["class"], "node_name": check.get("name", check["class"])}]
		"node_removed":
			return [{"command": "remove_node", "node_path": check.node_path}]
		"node_renamed":
			return [{"command": "rename_node", "node_path": check.node_path, "new_name": check.name}]
		"node_reparented":
			return [{"command": "reparent_node", "node_path": check.node_path, "new_parent_path": check.parent}]
		"property_equals":
			if not String(check.property).contains(":"):
				return [{"command": "set_property", "node_path": check.node_path, "property_name": check.property, "value": check.value}]
		"script_attached":
			if check.has("script"):
				return [{"command": "attach_script", "node_path": check.node_path, "script_path": check.script}]
		"signal_connected":
			if check.has("method"):
				return [{"command": "connect_signal", "node_path": check.source, "signal_name": check.signal, "target_node_path": check.target, "method_name": check.method}]
		"in_group":
			var n := _node(String(check.node_path))
			if n != null:
				var groups := []
				for g in n.get_groups():
					if not String(g).begins_with("_"):
						groups.append(String(g))
				groups.append(String(check.group))
				return [{"command": "set_node_groups", "node_path": check.node_path, "groups": groups}]
		"scene_saved":
			return [{"command": "save_scene_live"}]
		"all":
			var out := []
			for sub in check.checks:
				var part := _derive_show_me(sub)
				if part.is_empty():
					return []
				out.append_array(part)
			return out
	return []

func _on_save_pressed() -> void:
	var res := save()
	if res.has("error"):
		_card_text.text += "\n[color=#e0b050]Couldn't save: %s[/color]" % _escape(String(res.error))
	else:
		_card_save.visible = false
		_card_text.text += "\n[color=#60e080]Saved to %s — replay it from Project ▸ Tools ▸ Guided Tours…[/color]" % _escape(String(res.path))

## The node_added step's new node now needs renaming: outline its Scene
## dock row instead of the + button.
func _point_at_new_node(check: Dictionary) -> void:
	var cap := String(check.get("capture", ""))
	var n = _vars[cap].get_ref() if cap != "" and _vars.has(cap) else null
	if not n is Node:
		return
	var gen := _gen
	var res: Dictionary = await _bridge._hl_resolve_target({"node_path": _bridge._rel_path(n)}, false)
	if gen != _gen or res.has("error") or not res.has("tree"):
		return
	_unlisten_press()
	_overlay.clear()
	_overlay.add_tree_item(res.tree, res.item_path, "")

func _unlisten_press() -> void:
	if _pressed_conn.is_empty():
		return
	var b = _pressed_conn[0].get_ref()
	if b is BaseButton and (b as BaseButton).pressed.is_connected(_pressed_conn[1]):
		(b as BaseButton).pressed.disconnect(_pressed_conn[1])
	_pressed_conn = []

func _on_target_pressed(gen: int) -> void:
	if gen == _gen:
		_pressed_during_step = true
		_queue_check()

# ---- Completion checks -----------------------------------------------------

func _queue_check() -> void:
	if not _check_queued and not _holding and is_running() and not _done:
		_check_queued = true
		_run_check.call_deferred()

func _run_check() -> void:
	_check_queued = false
	if not is_running() or _done or _holding:
		return
	var check: Dictionary = _steps[_index].done_when
	if _passes(check, "c"):
		if _revisit:
			if _note_hint != "✓ Already done — press Next to continue.":
				_note_hint = "✓ Already done — press Next to continue."
				_refresh_card()
			return
		await _advance("step_done")
		return
	var hint := _hint(check, "c")
	if hint.begins_with("✓ Added!") and not _pointed_at_new:
		_pointed_at_new = true
		_point_at_new_node(check)
	if hint != _note_hint:
		_note_hint = hint
		if hint != "" and not _hints_logged.has(hint):
			_hints_logged[hint] = true
			_log("rename_prompted" if hint.begins_with("✓ Added!") else "wrong_action", {"hint": hint})
		_refresh_card()
	var stuck_after := float(_tour.get("stuck_after_sec", STUCK_SEC))
	if not _stuck_logged and stuck_after > 0 and (Time.get_ticks_msec() - _step_start_msec) / 1000.0 >= stuck_after:
		_stuck_logged = true
		_log("stuck")
		_note_stuck = "Stuck? You can **Skip** this step, or ask the agent for help."
		_refresh_card()

## Records what a change-based check compares against, at step start.
## Keys follow the check's position ("c", "c.0", "c.1"…) so all/any work.
func _snapshot(check: Dictionary, key: String) -> void:
	match String(check.type):
		"node_added":
			var ids := {}
			var parent := _node(String(check.parent))
			if parent != null:
				for c in parent.get_children():
					ids[c.get_instance_id()] = true
			_baseline[key] = ids
			_baseline[key + ":all"] = _all_node_ids()
		"node_removed", "node_renamed", "node_reparented":
			var n := _node(String(check.node_path))
			_baseline[key] = weakref(n) if n != null else null
			if n != null:
				_baseline[key + ":name"] = String(n.name)
		"property_equals", "property_changed":
			var n := _node(String(check.node_path))
			if n != null:
				_baseline[key] = n.get_indexed(NodePath(String(check.property)))
				_baseline[key + ":node"] = weakref(n)
		"all", "any":
			for j in (check.checks as Array).size():
				_snapshot(check.checks[j], "%s.%d" % [key, j])

func _passes(check: Dictionary, key: String) -> bool:
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
			var known: Dictionary = _baseline.get(key, {})
			for c in parent.get_children():
				if known.has(c.get_instance_id()):
					continue
				if check.has("class") and not c.is_class(String(check["class"])):
					continue
				if check.has("capture"):
					_vars[String(check.capture)] = weakref(c)
				# With a name, the step goes on to "now rename it" (see
				# _hint and _point_at_new_node) and completes once it's named.
				return not check.has("name") or String(c.name) == String(check.name)
			return false
		"node_removed":
			var ref = _baseline.get(key, null)
			if ref == null:
				return _node(String(check.node_path)) == null
			var n = ref.get_ref()
			return not (n is Node) or not (n as Node).is_inside_tree()
		"node_renamed":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			return n is Node and String(n.name) == String(check.name)
		"node_reparented":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			var parent := _node(String(check.parent))
			return n is Node and parent != null and (n as Node).get_parent() == parent
		"property_equals":
			var n := _node(String(check.node_path))
			if n == null:
				return false
			var actual = n.get_indexed(NodePath(String(check.property)))
			var expected = _bridge._decode_value(String(check.value))
			return _matches(actual, expected, float(check.get("tolerance", 0.0001)))
		"property_changed":
			var n := _node(String(check.node_path))
			if n == null or not _baseline.has(key):
				return false
			var actual = n.get_indexed(NodePath(String(check.property)))
			return not _matches(actual, _baseline[key], float(check.get("tolerance", 0.0001)))
		"property_class":
			var n := _node(String(check.node_path))
			if n == null:
				return false
			var v = n.get_indexed(NodePath(String(check.property)))
			return v is Object and (v as Object).is_class(String(check["class"]))
		"script_attached":
			var n := _node(String(check.node_path))
			if n == null or n.get_script() == null:
				return false
			return not check.has("script") or (n.get_script() as Script).resource_path == String(check.script)
		"signal_connected":
			var src := _node(String(check.source))
			var dst := _node(String(check.target))
			if src == null or dst == null or not src.has_signal(String(check.signal)):
				return false
			for conn in src.get_signal_connection_list(String(check.signal)):
				var callable: Callable = conn.callable
				if callable.get_object() == dst and (not check.has("method") or String(callable.get_method()) == String(check.method)):
					return true
			return false
		"in_group":
			var n := _node(String(check.node_path))
			return n != null and n.is_in_group(String(check.group))
		"scene_open":
			var root: Node = _bridge._get_scene_root()
			return root != null and root.scene_file_path == String(check.path)
		"scene_saved":
			return _saved_during_step
		"file_exists":
			var p := String(check.path)
			return FileAccess.file_exists(p) or DirAccess.dir_exists_absolute(p)
		"control_pressed":
			return _pressed_during_step
		"game_running":
			return EditorInterface.is_playing_scene()
		"all":
			for j in (check.checks as Array).size():
				if not _passes(check.checks[j], "%s.%d" % [key, j]):
					return false
			return true
		"any":
			for j in (check.checks as Array).size():
				if _passes(check.checks[j], "%s.%d" % [key, j]):
					return true
			return false
	return false

## A gentle note when the user changed the right kind of thing in the wrong
## way; "" when there's nothing specific to say.
func _hint(check: Dictionary, key: String) -> String:
	match String(check.type):
		"node_added":
			var parent := _node(String(check.parent))
			if parent == null:
				return ""
			var want := String(check.get("class", ""))
			var known: Dictionary = _baseline.get(key, {})
			for c in parent.get_children():
				if not known.has(c.get_instance_id()) and want != "" and not c.is_class(want):
					return "That added a **%s**; this step wants a **%s**. Undo it with Ctrl+Z." % [c.get_class(), want]
			if check.has("name"):
				for c in parent.get_children():
					if not known.has(c.get_instance_id()) and (want == "" or c.is_class(want)) and String(c.name) != String(check.name):
						return "✓ Added! Now rename it to **%s**: double-click it in the Scene dock (or press F2) and type `%s`." % [check.name, check.name]
			if want != "":
				var all_known: Dictionary = _baseline.get(key + ":all", {})
				for n in _all_nodes():
					if not all_known.has(n.get_instance_id()) and n.is_class(want) and n.get_parent() != parent:
						return "That **%s** went under **%s**; it needs to be a child of **%s**. Drag it onto %s in the Scene dock." % [want, n.get_parent().name, parent.name, parent.name]
		"node_selected":
			var n := _node(String(check.node_path))
			var sel := EditorInterface.get_selection().get_selected_nodes()
			if n != null and not sel.is_empty() and not n in sel:
				return "You selected **%s**; this step wants **%s**." % [sel[0].name, n.name]
		"node_renamed":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			if n is Node and String(n.name) != String(_baseline.get(key + ":name", "")) and String(n.name) != String(check.name):
				return "It's called **%s** now; this step wants **%s**." % [n.name, check.name]
		"property_equals":
			var n := _node(String(check.node_path))
			if n == null or not _baseline.has(key):
				return ""
			var actual = n.get_indexed(NodePath(String(check.property)))
			var tol := float(check.get("tolerance", 0.0001))
			if not _matches(actual, _baseline[key], tol):
				return "**%s** is now `%s`; this step wants `%s`." % [check.property, _show(actual), _show(_bridge._decode_value(String(check.value)))]
		"all", "any":
			for j in (check.checks as Array).size():
				var h := _hint(check.checks[j], "%s.%d" % [key, j])
				if h != "":
					return h
	return ""

func _show(v) -> String:
	return String(v) if typeof(v) == TYPE_STRING else var_to_str(v).strip_edges()

func _all_nodes() -> Array:
	var root: Node = _bridge._get_scene_root()
	if root == null:
		return []
	var out := [root]
	out.append_array(root.find_children("*", "", true, false))
	return out

func _all_node_ids() -> Dictionary:
	var ids := {}
	for n in _all_nodes():
		ids[n.get_instance_id()] = true
	return ids

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
	_lost_poll += delta
	if _lost_poll >= 1.0:
		_lost_poll = 0.0
		_repoint_if_lost()

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
	_card.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_card.tooltip_text = "Drag to move · double-click to let it follow the outline again"
	_card.gui_input.connect(_on_card_input)
	_card_pinned = false
	# Layout nodes pass clicks through, so a drag can start anywhere that
	# isn't a button.
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_theme_constant_override("separation", 6)
	_card.add_child(box)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(head)
	_card_title = Label.new()
	_card_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_title.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	head.add_child(_card_title)
	head.add_child(_card_button("✕", "End the tour", stop, true))
	_card_text = RichTextLabel.new()
	_card_text.bbcode_enabled = true
	_card_text.fit_content = true
	_card_text.scroll_active = false
	_card_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_text.custom_minimum_size = Vector2(300, 0)
	_card_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_card_text)
	var buttons := HBoxContainer.new()
	buttons.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(buttons)
	_card_back = _card_button("◂ Back", "Previous step", _on_back_pressed)
	buttons.add_child(_card_back)
	_card_skip = _card_button("Skip", "Skip this step", _on_skip_pressed)
	buttons.add_child(_card_skip)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_PASS
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	_card_why = _card_button("Why?", "Why this step?", _on_why_pressed)
	buttons.add_child(_card_why)
	_card_show = _card_button("Show me", "Do this step for me (undo with Ctrl+Z)", _on_show_me_pressed)
	buttons.add_child(_card_show)
	_card_next = _card_button("Next ▸", "Next step", _on_next_pressed)
	buttons.add_child(_card_next)
	_card_save = _card_button("Save tour", "Save this tour to res://tours/ so it can be replayed without the agent", _on_save_pressed)
	_card_save.visible = false
	buttons.add_child(_card_save)
	# Done card: Close is the main (green) action, to the right of Save.
	_card_close = _card_button("Close", "Close the tour", stop)
	var green := StyleBoxFlat.new()
	green.bg_color = Color(0.22, 0.6, 0.28)
	green.set_corner_radius_all(4)
	green.set_content_margin_all(6)
	green.content_margin_left = 14
	green.content_margin_right = 14
	_card_close.add_theme_stylebox_override("normal", green)
	var green_hover := green.duplicate()
	green_hover.bg_color = green.bg_color.lightened(0.12)
	_card_close.add_theme_stylebox_override("hover", green_hover)
	var green_down := green.duplicate()
	green_down.bg_color = green.bg_color.darkened(0.15)
	_card_close.add_theme_stylebox_override("pressed", green_down)
	_card_close.add_theme_color_override("font_color", Color.WHITE)
	_card_close.add_theme_color_override("font_hover_color", Color.WHITE)
	_card_close.visible = false
	buttons.add_child(_card_close)
	EditorInterface.get_base_control().add_child(_card)

## Drag the card anywhere (not on its buttons, which take their own
## clicks); it then stays put for the rest of the tour. Double-click hands
## placement back to the outline-following logic.
func _on_card_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.double_click:
			_card_pinned = false
			_card_dragging = false
		elif mb.pressed:
			_card_dragging = true
			_card_drag = mb.global_position - _card.global_position
		else:
			_card_dragging = false
		_card.accept_event()
	elif event is InputEventMouseMotion and _card_dragging:
		_card_pinned = true
		_card.global_position = (event as InputEventMouseMotion).global_position - _card_drag
		_card.accept_event()

func _card_button(text: String, tip: String, action: Callable, flat := false) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.flat = flat
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b

func _refresh_card() -> void:
	if _card == null or not is_instance_valid(_card) or _done or not is_running():
		return
	var step: Dictionary = _steps[_index]
	_card_title.text = "%s  ·  Step %d/%d" % [String(_tour.get("title", "Tour")), _index + 1, _steps.size()]
	var text := _markdown(_name_vars(String(step.text)))
	if _note_why != "":
		text += "\n[color=#8cc4ff]%s[/color]" % _markdown(_note_why)
	for note in [_note_target, _note_hint, _note_stuck]:
		if note != "":
			var colour := "#60e080" if note.begins_with("✓") else "#e0b050"
			text += "\n[i][color=%s]%s[/color][/i]" % [colour, _markdown(note)]
	_card_text.text = text
	_card_back.disabled = _index == 0
	_card_next.visible = _revisit or String(step.done_when.type) == "manual"
	_card_show.visible = not _show_me_actions(step).is_empty() and not _revisit
	_card_show.disabled = _showing
	_card_why.visible = String(step.get("why", "")) != "" or _agent_panel() != null

## Places the card where it doesn't cover what the user needs. When the
## outline is inside a narrow dock (Scene, Inspector, FileSystem), the card
## goes just outside that dock, towards the middle of the screen, so it
## never hides the dock's other rows. Otherwise beside the outline, or the
## bottom-right corner when nothing is outlined. Always kept on screen.
func _place_card() -> void:
	if _card == null or not is_instance_valid(_card):
		return
	var screen := EditorInterface.get_base_control().get_global_rect()
	var size := _card.get_combined_minimum_size()
	_card.size = size
	if _card_pinned or _card_dragging:
		# Where the user put it; only kept on screen (e.g. after a resize).
		_card.global_position = Vector2(
			clampf(_card.global_position.x, screen.position.x, screen.end.x - size.x),
			clampf(_card.global_position.y, screen.position.y, screen.end.y - size.y))
		return
	var target := _overlay.visible_rect()
	var pos: Vector2
	if not target.has_area():
		pos = screen.end - size - Vector2(24, 48)
	else:
		var dock := _dock_rect(_overlay.first_target(), screen)
		if dock.has_area():
			var left_side := dock.get_center().x > screen.get_center().x
			pos.x = dock.position.x - 12 - size.x if left_side else dock.end.x + 12
			pos.y = target.position.y
		elif target.end.x + 12 + size.x <= screen.end.x:
			pos = Vector2(target.end.x + 12, target.position.y)
		elif target.position.x - 12 - size.x >= screen.position.x:
			pos = Vector2(target.position.x - 12 - size.x, target.position.y)
		else:
			pos = Vector2(target.position.x, target.end.y + 28)
	pos.x = clampf(pos.x, screen.position.x + 8, screen.end.x - size.x - 8)
	pos.y = clampf(pos.y, screen.position.y + 8, screen.end.y - size.y - 8)
	_card.global_position = pos

## The outermost ancestor of c that is still a narrow side column (under a
## third of the screen wide and most of its height) — i.e. the dock it
## sits in. Empty when c isn't in one.
func _dock_rect(c: Control, screen: Rect2) -> Rect2:
	var best := Rect2()
	var n: Node = c
	while n != null and n is Control:
		var r := (n as Control).get_global_rect()
		if r.size.x >= screen.size.x / 3.0:
			break
		if r.size.y >= screen.size.y * 0.3:
			best = r
		n = n.get_parent()
	return best

## "$name" in step text -> the node's current name, so text can name the
## user's own nodes (longest var names first, so $label2 beats $label).
func _name_vars(text: String) -> String:
	var names := _vars.keys()
	names.sort_custom(func(a, b): return String(a).length() > String(b).length())
	for name in names:
		var n = _vars[name].get_ref()
		if n is Node:
			text = text.replace("$" + String(name), String(n.name))
	return text

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
