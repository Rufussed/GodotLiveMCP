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
const SHOW_ME_COMMANDS := ["select_nodes", "add_node_live", "set_property", "set_properties", "set_nested_property",
	"set_resource_property", "set_transform", "duplicate_node", "add_mesh_instance", "setup_collision",
	"set_material_3d", "set_physics_material", "setup_environment", "rename_node", "reparent_node", "remove_node",
	"connect_signal", "set_node_groups", "attach_script", "edit_script_text", "save_scene_live", "open_scene",
	"play_scene"]
## Event types that mean a step isn't going well: what the agent is shown
## (get_tour_status.problems) and what the Ask the agent button sends.
const PROBLEM_TYPES := ["verify_failed", "show_me_failed", "show_me_refused", "wrong_action", "stuck", "target_missing"]
const AUTO_ASK_GAP_SEC := 20.0   # minimum time between automatic hand-offs
const GAME_OPS := [">", "<", ">=", "<=", "==", "~="]
const SHOW_ME_ANNOUNCE_SEC := 1.6   # how long the card announces before Show me acts

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
	"script_contains": ["text"],
	"script_ok": [],
	"output_contains": ["text"],
	"no_errors": [],
	"game_property": ["node_path", "property", "op", "value"],
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
var _validated := false   # set when _validate runs to completion
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
var _manual_done := false     # Next was pressed on a manual step
var _onfail_done := {}        # steps whose on_fail already ran (once each)
var _fixup_active := false    # inside the fix-up steps of an on_fail
var _verify_only := false     # re-entered the original step just to re-verify it
var _resume_origin := -1      # the step whose verify failed
var _resume_next := -1        # where to continue once it verifies
var _saved_v := {}            # verify baseline from when the fix-ups began
var _verify_since := 0        # msec the step's verify started failing/waiting; 0 = not started
var _script_err_cache := {}   # script text hash -> parse error ("" = ok)
var _game_vals := {}          # "node|prop" -> {"v", "err", "t"}: last value read from the running game
var _game_peer: StreamPeerTCP = null
var _game_buf := ""
var _game_key := ""
var _game_started := 0
var _hint_hold_until := 0 # msec: a Show me result/refusal note stays up until then
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
var _card_ask: Button = null
var _auto_asked := {}         # steps the agent was already asked about automatically
var _last_auto_msec := 0
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
	# A runtime error inside _validate (e.g. unexpected JSON types) aborts
	# it and returns an empty list — which would read as "valid". Only
	# trust the result if validation actually reached its end.
	_validated = false
	var errors := _validate(tour, warnings)
	if not _validated:
		errors = ["couldn't finish checking this tour (unexpected data — e.g. a value of the wrong type); compare it with the format in the start_tour description"]
	if not errors.is_empty() or dry_run:
		return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "dry_run": dry_run}
	stop()
	_tour = tour
	_source_path = source_path
	_steps = tour.steps
	_events = []
	_done = false
	_onfail_done = {}
	_auto_asked = {}
	_last_auto_msec = 0
	_fixup_active = false
	_verify_only = false
	_vars = {}
	var initial: Dictionary = tour.get("vars", {})
	for name in initial:
		_vars[str(name)] = weakref(_resolve_var(initial[name]))
	_start_msec = Time.get_ticks_msec()
	_connect_signals()
	_build_card()
	set_process(true)
	# Not awaited: the reply shouldn't wait on target reveal or an
	# already-done pause.
	_enter_step(0)
	return {"ok": true, "errors": [], "warnings": warnings, "steps": _steps.size(), "title": str(tour.get("title", ""))}

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
		"title": str(_tour.get("title", "")),
		"steps": _steps.size(),
		"source": _source_path if _source_path != "" else "agent",
		"vars": vars,
		"events": _events,
	}
	if is_running() and not _done:
		out["step"] = _index + 1
		out["step_id"] = str(_steps[_index].get("id", ""))
		out["step_elapsed_sec"] = (Time.get_ticks_msec() - _step_start_msec) / 1000.0
		var cur: Dictionary = _steps[_index]
		out["current_step"] = {"text": str(cur.get("text", "")), "done_when": cur.get("done_when"),
			"verify": cur.get("verify"), "fixup": bool(cur.get("_fixup", false))}
		var problems := []
		for e in _events:
			if str(e.type) in PROBLEM_TYPES:
				problems.append(e)
		out["problems"] = problems.slice(maxi(0, problems.size() - 6))
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
		var slug := str(_tour.get("title", "tour")).to_snake_case().validate_filename()
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
				entry["title"] = str(res.tour.get("title", file))
				entry["steps"] = (res.tour.get("steps", []) as Array).size() if typeof(res.tour.get("steps")) == TYPE_ARRAY else 0
				var req = res.tour.get("requires", {})
				if typeof(req) == TYPE_DICTIONARY and req.has("scene_open"):
					entry["scene"] = str(req.scene_open)
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
		var want := str(req.scene_open)
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
				_alert(str(res.error)))
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var tours := list_files()
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(460, 240)
	for entry in tours:
		var label := str(entry.get("title", entry.path))
		if entry.has("error"):
			label += "  (unreadable)"
		elif entry.has("steps"):
			label += "  ·  %d steps" % entry.steps
		list.add_item(label)
		list.set_item_tooltip(list.item_count - 1, str(entry.path))
	box.add_child(list)
	var hint := Label.new()
	hint.text = "Tours are *%s files in your project. Record one (do the task yourself while recording), or ask the agent for a tour and press Save on its last card." % TOUR_EXT if tours.is_empty() \
		else "Double-click a tour, or select it and press Start tour. Record new tour… captures a task you do yourself."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(460, 0)
	box.add_child(hint)
	var play := func(i: int) -> void:
		dialog.hide()
		var result: Dictionary = await play_file(str(tours[i].path))
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
	if str(tour.get("format", "")) != FORMAT:
		errors.append("format must be \"%s\"" % FORMAT)
	var steps = tour.get("steps", null)
	if typeof(steps) != TYPE_ARRAY or (steps as Array).is_empty():
		errors.append("steps must be a non-empty array")
		_validated = true
		return errors
	var root: Node = _bridge._get_scene_root()
	if root == null:
		errors.append("no scene is open in the editor")
		_validated = true
		return errors
	var req = tour.get("requires", {})
	if typeof(req) == TYPE_DICTIONARY:
		if req.has("scene_open") and typeof(req.scene_open) != TYPE_STRING:
			errors.append("requires.scene_open must be a res:// scene path (got %s)" % str(req.scene_open))
		elif req.has("scene_open") and root.scene_file_path != str(req.scene_open):
			errors.append("requires.scene_open: %s is not the scene open in the editor (%s)" % [req.scene_open, root.scene_file_path])
		for p in req.get("node_exists", []):
			if _bridge._resolve_node(str(p)) == null:
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
			if typeof(spec) == TYPE_DICTIONARY and not ClassDB.class_exists(str(spec.get("class", ""))):
				errors.append("vars.%s: unknown class '%s'" % [name, spec.get("class", "")])
				continue
			var n: Node = _resolve_var(spec)
			if n == null:
				if typeof(spec) == TYPE_DICTIONARY:
					var msg := "vars.%s: this tour needs a %s in the scene" % [name, spec["class"]]
					if str(spec.get("name", "")) != "":
						msg += " named '%s'" % spec.name
					if str(spec.get("hint", "")) != "":
						msg += " — " + str(spec.hint)
					errors.append(msg)
				else:
					errors.append("vars.%s: node not found: %s" % [name, spec])
			var_class[str(name)] = n.get_class() if n != null else ""
	for i in (steps as Array).size():
		_validate_step(steps[i], "step %d" % (i + 1), var_class, errors, warnings, false)
	_validated = true
	return errors

## One step's checks. nested = a fix-up step from an on_fail (one level only).
func _validate_step(step, where: String, var_class: Dictionary, errors: Array, warnings: Array, nested: bool) -> void:
	if typeof(step) != TYPE_DICTIONARY:
		errors.append("%s: must be an object" % where)
		return
	if str(step.get("id", "")) != "":
		where += " (%s)" % step.id
	if str(step.get("text", "")) == "":
		errors.append("%s: text is required" % where)
	var target = step.get("target", {})
	if typeof(target) == TYPE_DICTIONARY and not (target as Dictionary).is_empty():
		for v in _vars_used(target, var_class):
			errors.append("%s: target uses %s before it is defined" % [where, v])
		if target.has("property") and target.has("node_path"):
			_check_property(str(target.node_path), str(target.property), var_class, where + ": target", errors)
		elif not target.has("node_path") and not target.has("property"):
			# An editor control: may legitimately appear later (a dialog),
			# so only a warning when it can't be found right now.
			var found = _bridge._ctl_find(target, "path", "text", "class")
			if found is String:
				warnings.append("%s: target not found right now (%s); fine if it only appears later" % [where, found])
	var check = step.get("done_when", null)
	if typeof(check) != TYPE_DICTIONARY:
		errors.append("%s: done_when is required" % where)
		return
	if not check.has("type"):
		errors.append("%s: done_when needs a \"type\", e.g. {\"type\": \"node_added\", \"parent\": \"$root\", \"class\": \"StaticBody3D\"}" % where)
		return
	_validate_check(check, step, where + ": done_when", var_class, errors)
	for key in ["verify", "skip_if"]:
		if step.has(key):
			if typeof(step[key]) != TYPE_DICTIONARY or not (step[key] as Dictionary).has("type"):
				errors.append("%s: %s must be a check object with a \"type\" (e.g. {\"type\": \"script_ok\", \"node_path\": \"$ball\"})" % [where, key])
			else:
				_validate_check(step[key], step, "%s: %s" % [where, key], var_class, errors)
	if step.has("on_fail"):
		if nested:
			errors.append("%s: fix-up steps can't have their own on_fail" % where)
		elif typeof(step.on_fail) != TYPE_DICTIONARY:
			errors.append("%s: on_fail must be {note?, steps?}" % where)
		else:
			if not step.has("verify"):
				errors.append("%s: on_fail only applies to a step that has a verify" % where)
			var fixups = step.on_fail.get("steps", [])
			if typeof(fixups) != TYPE_ARRAY:
				errors.append("%s: on_fail.steps must be an array of steps" % where)
			else:
				var fixup_vars := var_class.duplicate()  # captures made by fix-ups don't leak past them
				for j in (fixups as Array).size():
					_validate_step(fixups[j], "%s, fix-up %d" % [where, j + 1], fixup_vars, errors, warnings, true)
	if step.has("why") and typeof(step.why) != TYPE_STRING:
		errors.append("%s: why must be a string" % where)
	if step.has("show_me"):
		if typeof(step.show_me) != TYPE_ARRAY:
			errors.append("%s: show_me must be an array of {command, ...params}" % where)
		else:
			for action in step.show_me:
				if typeof(action) != TYPE_DICTIONARY or not str(action.get("command", "")) in SHOW_ME_COMMANDS:
					errors.append("%s: show_me commands must be one of %s" % [where, ", ".join(SHOW_ME_COMMANDS)])
					break
				if str(action.command) == "attach_script" and not ResourceLoader.exists(str(action.get("script_path", ""))):
					errors.append("%s: show_me can only attach a script that already exists in the project (%s)" % [where, action.get("script_path", "")])

func _validate_check(check: Dictionary, step: Dictionary, where: String, var_class: Dictionary, errors: Array) -> void:
	var type := str(check.get("type", ""))
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
	if type == "script_ok" and not (check.has("script") or check.has("node_path")):
		errors.append("%s: type 'script_ok' needs 'script' (a res:// path) or 'node_path' (a node that has the script)" % where)
	if type == "game_property" and not str(check.get("op", "")) in GAME_OPS:
		errors.append("%s: game_property op must be one of %s (got '%s')" % [where, " ".join(GAME_OPS), check.get("op", "")])
	if type == "script_contains":
		if not (check.has("script") or check.has("node_path")):
			errors.append("%s: type 'script_contains' needs 'script' (a res:// path) or 'node_path' (a node that has the script)" % where)
		if check.has("script") and not str(check.script).begins_with("res://"):
			errors.append("%s: script must be a res:// path (got %s)" % [where, check.script])
	if type == "node_added" and check.has("name") and str(check.name).validate_node_name() != str(check.name):
		errors.append("%s: '%s' isn't a valid node name" % [where, check.name])
	if check.has("class") and type in ["node_added", "property_class"] and not ClassDB.class_exists(str(check["class"])):
		errors.append("%s: unknown class '%s'" % [where, check["class"]])
	if type in ["property_equals", "property_changed", "property_class"] and check.has("node_path") and check.has("property"):
		_check_property(str(check.node_path), str(check.property), var_class, where, errors)
	if type == "signal_connected" and check.has("source") and check.has("signal"):
		var cls := _class_of(str(check.source), var_class)
		if cls != "" and not ClassDB.class_has_signal(cls, str(check.signal)):
			var n: Node = _bridge._resolve_node(str(check.source)) if not str(check.source).begins_with("$") else null
			if n == null or not n.has_signal(str(check.signal)):
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
			var_class[str(check.capture)] = str(check.get("class", ""))

## The class a node path will have: the node's own class for an existing
## node or initial var, the node_added class for a capture, "" if unknown.
func _class_of(path: String, var_class: Dictionary) -> String:
	if path.begins_with("$"):
		var name := path.substr(1).get_slice("/", 0)
		if path.contains("/"):
			return ""
		return str(var_class.get(name, ""))
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
		var cls := str(spec.get("class", ""))
		var want_name := str(spec.get("name", ""))
		for n in _all_nodes():
			if n.is_class(cls) and (want_name == "" or str(n.name) == want_name):
				return n
		return null
	return _bridge._resolve_node(str(spec))

# ---- Verifying a step's result ----------------------------------------------

## The step's done_when has passed. With a `verify`, the step only
## completes once that passes too; if it still fails after its wait, the
## card says what's wrong (and the event log records it) and keeps
## re-checking, so it moves on by itself once the learner fixes things.
func _complete_step() -> void:
	var step: Dictionary = _steps[_index]
	var v = step.get("verify", null)
	if typeof(v) != TYPE_DICTIONARY:
		await _advance("step_done")
		return
	if _verify_since == 0:
		_verify_since = Time.get_ticks_msec()
	if _passes(v, "v"):
		await _advance("step_done")
		return
	var waited := (Time.get_ticks_msec() - _verify_since) / 1000.0
	if waited < float(v.get("wait_sec", _default_verify_wait(str(v.type)))):
		_note_hint = "Checking the result…"
		_refresh_card()
		return
	var why := _check_failure(v, "v")
	var of = step.get("on_fail", null)
	var key := str(step.get("text", "")).hash()
	if typeof(of) == TYPE_DICTIONARY and not _onfail_done.has(key):
		_onfail_done[key] = true
		var note := str(of.get("note", "")) if str(of.get("note", "")) != "" else "That didn't work: " + why
		_log("verify_failed", {"check": str(v.type), "saw": why})
		var fixups = of.get("steps", [])
		if typeof(fixups) == TYPE_ARRAY and not (fixups as Array).is_empty():
			_log("on_fail", {"steps": (fixups as Array).size()})
			_snapshot(v, "v")  # the check starts counting from here
			_saved_v = _baseline.get("v", {})
			var start := _index + 1
			for j in (fixups as Array).size():
				var fs: Dictionary = (fixups[j] as Dictionary).duplicate(true)
				fs["_fixup"] = true
				_steps.insert(start + j, fs)
			_resume_origin = _index
			_resume_next = start + (fixups as Array).size()
			_fixup_active = true
			await _enter_step(start)
			_note_hint = "✗ " + note
			_hint_hold_until = Time.get_ticks_msec() + 15000
			_refresh_card()
			return
		_note_hint = "✗ " + note
		_refresh_card()
		_maybe_auto_ask()
		return
	var msg := "✗ That didn't work: " + why
	if msg != _note_hint:
		_note_hint = msg
		_log("verify_failed", {"check": str(v.type), "saw": why})
		_refresh_card()
	_maybe_auto_ask()

func _default_verify_wait(type: String) -> float:
	match type:
		"script_ok": return 0.6
		"output_contains", "game_property": return 4.0
		"no_errors": return 3.0
	return 0.5

## What went wrong with a failing verify, in plain words.
func _check_failure(check: Dictionary, key: String) -> String:
	match str(check.type):
		"script_ok":
			var err := _script_error(check)
			return "the script has an error — %s" % err if err != "" else "the script couldn't be checked"
		"output_contains":
			return "I haven't seen \"%s\" in the output yet" % str(check.text)
		"no_errors":
			var errs := _new_errors(key)
			return "there's an error — %s" % str(errs[0]).left(160) if not errs.is_empty() else "there are errors"
		"game_property":
			if not EditorInterface.is_playing_scene():
				return "the game isn't running"
			var got = _game_vals.get(_game_cache_key(check), {})
			if got.get("err", "") != "":
				return "couldn't read %s from the game (%s)" % [check.property, got.err]
			var who := str(_sub(str(check.node_path))).get_file()
			if who == "." or who == "":
				who = str(_bridge._get_scene_root().name)
			return "%s · %s is %s, but should be %s %s" % [who, str(check.property).replace(":", " "),
				_show(got.get("v")), check.op, _show(_bridge._decode_value(str(check.value)))]
	return "the check didn't pass"

func _script_error(check: Dictionary) -> String:
	var path := _script_path_for(check)
	if path == "":
		return "no script on that node"
	var got = _bridge._cmd_get_script_text({"path": path})  # includes unsaved edits
	if typeof(got) != TYPE_DICTIONARY or got.has("__error__"):
		return "couldn't read %s" % path
	var src := str(got.text)
	var h := src.hash()
	if not _script_err_cache.has(h):
		_script_err_cache[h] = _bridge._script_text_error(src)
	return str(_script_err_cache[h])

## Output since the step started: the editor's Output panel (which also
## carries the running game's prints) after the line count at step start.
func _editor_log_lines() -> PackedStringArray:
	var logs := EditorInterface.get_base_control().find_children("*", "EditorLog", true, false)
	if logs.is_empty():
		return PackedStringArray()
	var labels: Array = logs[0].find_children("*", "RichTextLabel", true, false)
	if labels.is_empty():
		return PackedStringArray()
	return (labels[0] as RichTextLabel).get_parsed_text().strip_edges().split("\n")

func _game_error_rows() -> Array:
	var got = _bridge._cmd_get_output_log({"lines": 1})
	return got.game_errors if typeof(got) == TYPE_DICTIONARY and got.has("game_errors") else []

func _new_output(key: String) -> String:
	var lines := _editor_log_lines()
	var base: int = int(_baseline.get(key, {}).get("lines", 0))
	if lines.size() < base:
		base = 0  # the panel was cleared (e.g. the game restarted)
	return "\n".join(lines.slice(base))

## Error lines since the step started: the editor's captured errors plus
## new rows in the debugger's Errors tab (errors in the running game).
func _new_errors(key: String) -> Array:
	var base: Dictionary = _baseline.get(key, {})
	var out := []
	if _bridge._output_capture != null:
		for e in _bridge._output_capture.read(int(base.get("seq", 0)), true, 20).entries:
			if str(e.get("kind", "")) in ["error", "script_error", "shader_error"]:
				out.append(str(e.get("text", "")))
	var game := _game_error_rows()
	var gbase := int(base.get("game_errs", 0))
	for i in range(gbase, game.size()):
		var row = game[i]
		out.append(str(row.get("error", row)) if typeof(row) == TYPE_DICTIONARY else str(row))
	return out

# ---- Reading the running game (game_property) -------------------------------
#
# The check can't wait for a network reply, so it answers from the last value
# read; _game_pump() (every frame) keeps one request in flight to the game's
# runtime bridge (the same port and token the MCP server uses).

func _game_cache_key(check: Dictionary) -> String:
	return "%s|%s" % [_sub(str(check.node_path)), check.property]

func _game_property_ok(check: Dictionary) -> bool:
	if not EditorInterface.is_playing_scene():
		return false
	var key := _game_cache_key(check)
	var got: Dictionary = _game_vals.get(key, {})
	if _game_peer == null and Time.get_ticks_msec() - int(got.get("t", 0)) > 400:
		_game_request(key, _sub(str(check.node_path)), str(check.property).replace(":", "."))
	if not got.has("v") or got.get("err", "") != "":
		return false
	return _compare(got.v, str(check.op), _bridge._decode_value(str(check.value)), float(check.get("tolerance", 0.05)))

func _compare(a, op: String, b, tol: float) -> bool:
	match op:
		"==": return _matches(a, b, tol)
		"~=": return _matches(a, b, maxf(tol, absf(float(b)) * 0.05 if typeof(b) in [TYPE_INT, TYPE_FLOAT] else tol))
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		match op:
			">": return float(a) > float(b)
			"<": return float(a) < float(b)
			">=": return float(a) >= float(b)
			"<=": return float(a) <= float(b)
	return false

func _game_request(key: String, node_path: String, expression: String) -> void:
	_game_peer = StreamPeerTCP.new()
	var port := int(OS.get_environment("GODOT_LIVE_MCP_RUNTIME_PORT")) if OS.get_environment("GODOT_LIVE_MCP_RUNTIME_PORT") != "" else 9090
	if _game_peer.connect_to_host("127.0.0.1", port) != OK:
		_game_vals[key] = {"err": "can't connect to the game", "t": Time.get_ticks_msec()}
		_game_peer = null
		return
	_game_key = key
	_game_buf = JSON.stringify({"id": 1, "token": _bridge._token, "command": "eval_expression",
		"params": {"node_path": node_path, "expression": expression}}) + "\n"
	_game_started = Time.get_ticks_msec()

func _game_pump() -> void:
	if _game_peer == null:
		return
	_game_peer.poll()
	var status := _game_peer.get_status()
	var fail := ""
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if _game_buf.ends_with("\n") and _game_buf.begins_with("{"):
			_game_peer.put_data(_game_buf.to_utf8_buffer())  # the request, sent once
			_game_buf = "<sent>"
		elif _game_peer.get_available_bytes() > 0:
			var got := _game_peer.get_data(_game_peer.get_available_bytes())
			_game_buf = (_game_buf if _game_buf != "<sent>" else "") + (got[1] as PackedByteArray).get_string_from_utf8()
			if _game_buf.contains("\n"):
				var reply = JSON.parse_string(_game_buf.get_slice("\n", 0))
				if typeof(reply) == TYPE_DICTIONARY and reply.get("ok", false):
					var val = reply.result.value if typeof(reply.result) == TYPE_DICTIONARY else null
					_game_vals[_game_key] = {"v": str_to_var(str(val)), "t": Time.get_ticks_msec()}
				else:
					_game_vals[_game_key] = {"err": str(reply.get("error", "bad reply")) if typeof(reply) == TYPE_DICTIONARY else "bad reply", "t": Time.get_ticks_msec()}
				_game_peer.disconnect_from_host()
				_game_peer = null
				return
	elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		fail = "can't reach the game"
	if fail == "" and Time.get_ticks_msec() - _game_started > 2500:
		fail = "the game didn't answer"
	if fail != "":
		_game_vals[_game_key] = {"err": fail, "t": Time.get_ticks_msec()}
		_game_peer.disconnect_from_host()
		_game_peer = null

## Names of $vars referenced in d's string values that aren't defined yet.
func _vars_used(d, defined: Dictionary) -> Array:
	var missing := []
	if typeof(d) != TYPE_DICTIONARY:
		return missing
	for key in d:
		if key == "capture" or key == "checks":
			continue
		var v = d[key]
		if typeof(v) == TYPE_STRING and str(v).begins_with("$"):
			var name := str(v).substr(1).get_slice("/", 0)
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
		out[key] = _sub(str(d[key])) if typeof(d[key]) == TYPE_STRING else d[key]
	return out

## True if the step refers to a var that a skipped step should have set.
func _needs_missing_var(step: Dictionary) -> bool:
	for d in [step.get("target", {}), step.done_when]:
		if typeof(d) == TYPE_DICTIONARY:
			for key in d:
				if typeof(d[key]) == TYPE_STRING and _sub(str(d[key])).begins_with("<missing"):
					return true
	return false

# ---- Steps -----------------------------------------------------------------

func _enter_step(i: int, revisit := false) -> void:
	_gen += 1
	var gen := _gen
	_index = i
	_showing = false
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
	_manual_done = false
	_verify_since = 0
	_snapshot(step.done_when, "c")
	if typeof(step.get("verify")) == TYPE_DICTIONARY:
		if _verify_only:
			_baseline["v"] = _saved_v  # what happened since the fix-ups began counts
		else:
			_snapshot(step.verify, "v")
	# skip_if: already true, so don't show the step at all.
	if typeof(step.get("skip_if")) == TYPE_DICTIONARY and not revisit and not _verify_only:
		_snapshot(step.skip_if, "s")
		if _passes(step.skip_if, "s"):
			_log("skipped_if")
			await _advance("step_done")
			return
	_log("back_to_step" if revisit else ("rechecking" if _verify_only else "step_started"))
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
	if not _verify_only and str(step.done_when.type) != "manual" and _passes(step.done_when, "c"):
		_log("already_done")
		_note_hint = "✓ Already done — moving on…"
		_refresh_card()
		_holding = true
		await get_tree().create_timer(ALREADY_DONE_SEC).timeout
		_holding = false
		if gen != _gen:
			return
		_queue_check()
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
		var label := str(target.get("label", ""))
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
		var prop := str(target.get("property", ""))
		for ep in EditorInterface.get_inspector().find_children("*", "EditorProperty", true, false):
			if str((ep as EditorProperty).get_edited_property()) == prop and (ep as Control).is_visible_in_tree():
				_pointing_at_fold = false
				_overlay.clear()
				_overlay.add_control(ep, str(target.get("label", "")))
				_note_target = ""
				_refresh_card()
				return
		return
	if _overlay.first_target() != null:
		return
	if target.has("property") and target.has("node_path"):
		var n := _node(str(target.node_path))
		if n != null and EditorInterface.get_inspector().get_edited_object() != n:
			var note := "Select **%s** again to see this setting." % n.name
			if _note_target != note:
				_note_target = note
				_refresh_card()
			return
	await _point(_gen)

func _advance(event: String) -> void:
	_log(event)
	var nxt := _index + 1
	if _fixup_active and _index == _resume_next - 1:
		# The last fix-up is done: back to the step whose result failed, to
		# check it again before going on.
		_fixup_active = false
		_verify_only = true
		await _enter_step(_resume_origin)
		return
	if _verify_only and _index == _resume_origin:
		nxt = _resume_next  # verified at last: continue after the fix-ups
		_verify_only = false
	if nxt >= _steps.size():
		_finish()
	else:
		await _enter_step(nxt)

func _finish() -> void:
	_done = true
	_gen += 1
	_overlay.clear()
	_log("tour_done")
	_card_title.text = "Done!"
	_card_text.text = "You finished [b]%s[/b]." % _escape(str(_tour.get("title", "the tour")))
	_card_back.visible = false
	_card_skip.visible = false
	_card_next.visible = false
	_card_show.visible = false
	_card_ask.visible = false
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
	if not is_running() or _done:
		return
	if _revisit:
		await _advance("step_done")
	elif str(_steps[_index].done_when.type) == "manual":
		# Through the normal check, so a verify on the step still runs.
		_manual_done = true
		_queue_check()

## Something on the card says the step isn't working.
func _has_problem() -> bool:
	return _note_hint.begins_with("✗") or _note_hint.begins_with("Couldn't show") or _note_hint.begins_with("Show me won't") \
		or _note_stuck != "" or _note_target.begins_with("I can't point")

## What to tell the agent: where the learner is, what went wrong, and to
## fix the plan (revise_tour), not the scene.
func _build_digest() -> String:
	var step: Dictionary = _steps[_index]
	var lines := []
	if _note_hint != "":
		lines.append(_note_hint)
	if _note_target != "":
		lines.append(_note_target)
	if _note_stuck != "":
		lines.append("The learner has been on this step a long time.")
	for e in _events:
		if str(e.type) in PROBLEM_TYPES and int(e.get("step", 0)) == _index + 1:
			var detail := str(e.get("saw", e.get("error", e.get("hint", ""))))
			lines.append("%s%s" % [e.type, ": " + detail if detail != "" else ""])
	# One line per problem: drop an event line whose detail the card note already says.
	var uniq := []
	for l in lines:
		var text := str(l).left(300)
		var detail := text.get_slice(": ", 1) if text.contains(": ") and str(l).split(": ")[0] in PROBLEM_TYPES else ""
		var covered := false
		for other in lines:
			if other != l and detail != "" and str(other).contains(detail):
				covered = true
		if not covered and not text in uniq:
			uniq.append(text)
	return "[Guided tour \"%s\", step %d/%d: %s]\nSomething isn't working here:\n- %s\n\nThe step's checks: %s\n\nFix the PLAN, not the scene: call revise_tour to replace the remaining steps (from step %d) with ones that get me past this. Keep using $vars for my node names, and don't change the scene yourself. Call get_tour_status if you need more detail." % [
		str(_tour.get("title", "")), _index + 1, _steps.size(), _name_vars(str(step.get("text", ""))),
		"\n- ".join(uniq), JSON.stringify({"done_when": step.get("done_when"), "verify": step.get("verify")}).left(500), _index + 1]

## Teach mode hands hard failures (a verify that won't pass, a Show me that
## errors) to the agent by itself, so the learner doesn't have to notice and
## press the button. Costs one short agent turn; so: Teach mode only, once
## per step, never while the agent is busy, and with a gap between asks.
func _maybe_auto_ask() -> void:
	if not is_running() or _done:
		return
	if not bool(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", "tutorial_mode", false)):
		return
	var key := str(_steps[_index].get("text", "")).hash()
	if _auto_asked.has(key):
		return
	if (Time.get_ticks_msec() - _last_auto_msec) / 1000.0 < AUTO_ASK_GAP_SEC and _last_auto_msec != 0:
		return
	var panel := _agent_panel()
	if panel == null:
		return
	var busy = panel.get("_busy")
	if typeof(busy) == TYPE_DICTIONARY and bool(busy.get("chat", false)):
		return  # try again at the next check
	var err: String = panel.ask(_build_digest())
	if err != "":
		return
	_auto_asked[key] = true
	_last_auto_msec = Time.get_ticks_msec()
	_log("asked_agent", {"sent": true, "auto": true})
	_note_why = "Asked the agent automatically — see the AI Assistant panel."
	_refresh_card()

func _on_ask_pressed() -> void:
	if not is_running() or _done:
		return
	var panel := _agent_panel()
	if panel == null:
		return
	var err: String = panel.ask(_build_digest())
	_log("asked_agent", {"sent": err == ""} if err == "" else {"sent": false, "error": err})
	if err == "":
		_bridge._editor_plugin.make_bottom_panel_item_visible(panel)
		_note_why = "Asked the agent — see the AI Assistant panel."
	else:
		_note_why = "Couldn't ask the agent: " + err
	_refresh_card()

## revise_tour: replace the steps from from_step (1-based; default the
## current one) with new ones, keeping progress, variables and the log.
## Returns {"ok", "errors", "warnings"[, "steps", "from_step"]}.
func revise(new_steps: Array, from_step: int, note: String, dry_run: bool) -> Dictionary:
	if not is_running() or _done:
		return {"ok": false, "errors": ["no tour is running — start one with start_tour"], "warnings": []}
	var in_fixup := _fixup_active or _verify_only
	var cur := _resume_origin if in_fixup else _index
	var from := from_step if from_step > 0 else cur + 1
	if from < 1 or from > cur + 2:
		return {"ok": false, "errors": ["from_step must be between 1 and %d (the step after the current one)" % (cur + 2)], "warnings": []}
	var prefix := []
	for st in _steps.slice(0, from - 1):
		if not st.get("_fixup", false):
			prefix.append((st as Dictionary).duplicate(true))
	var candidate := _tour.duplicate(true)
	candidate["steps"] = prefix + new_steps
	var warnings := []
	_validated = false
	var errors := _validate(candidate, warnings)
	if not _validated:
		errors = ["couldn't finish checking the new steps (unexpected data)"]
	if not errors.is_empty() or dry_run:
		return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "dry_run": dry_run}
	_steps = candidate.steps
	_tour["steps"] = _steps
	_fixup_active = false
	_verify_only = false
	_log("revised", {"from_step": from, "steps": new_steps.size(), "note": note})
	var banner := "🛠 The agent changed the plan from here" + (": " + note if note != "" else ".")
	if from - 1 <= cur:
		if from - 1 >= _steps.size():
			_finish()
			return {"ok": true, "errors": [], "warnings": warnings, "steps": _steps.size(), "from_step": from}
		await _enter_step(from - 1)
	else:
		if in_fixup:
			await _enter_step(cur)
		_refresh_card()
	_note_hint = banner
	_hint_hold_until = Time.get_ticks_msec() + 15000
	_refresh_card()
	return {"ok": true, "errors": [], "warnings": warnings, "steps": _steps.size(), "from_step": from}

## "Why?": the step's own why text first (works offline, in saved tours);
## pressed again, or when there is none, the question goes to the agent in
## the AI Assistant panel with the tour context.
func _on_why_pressed() -> void:
	if not is_running() or _done:
		return
	var step: Dictionary = _steps[_index]
	var why := _name_vars(str(step.get("why", "")))
	if why != "" and _note_why != why:
		_note_why = why
		_log("why_shown")
		_refresh_card()
		return
	var panel := _agent_panel()
	if panel == null:
		return
	var question := "[Guided tour \"%s\", step %d/%d: %s] Why do I do this step? Explain briefly in plain language — don't do it for me, and don't change the scene." % [
		str(_tour.get("title", "")), _index + 1, _steps.size(), _name_vars(str(step.text))]
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
	var step: Dictionary = _steps[_index]
	var actions := _show_me_actions(step)
	var gen := _gen
	if actions.is_empty():
		# An explanation-only step has nothing to do: Show me just moves on.
		if str(step.done_when.type) == "manual":
			_showing = true
			_note_hint = "▶ Nothing to do for this one — moving on…"
			_refresh_card()
			_log("show_me")
			await get_tree().create_timer(1.2).timeout
			_showing = false
			if gen == _gen:
				await _advance("step_done")
		return
	for a in actions:
		var refusal := _show_me_refusal(a)
		if refusal != "":
			_note_hint = refusal
			_hint_hold_until = Time.get_ticks_msec() + 8000
			_log("show_me_refused", {"why": refusal})
			_refresh_card()
			return
	_showing = true
	# Announce exactly what's about to happen (code included), then pause so
	# it can be read before anything changes.
	var lines := []
	for a in actions:
		lines.append("• " + _describe_action(a))
	_note_hint = "▶ Doing this for you:\n" + "\n".join(lines)
	_refresh_card()
	_log("show_me")
	await get_tree().create_timer(SHOW_ME_ANNOUNCE_SEC).timeout
	if gen != _gen:
		_showing = false
		return
	for action in actions:
		var params: Dictionary = action.duplicate()
		var command := str(params.get("command", ""))
		params.erase("command")
		var res = await _bridge.call("_cmd_" + command, params)
		if gen != _gen:
			_showing = false
			return
		if typeof(res) == TYPE_DICTIONARY and res.has("__error__"):
			_showing = false
			_log("show_me_failed", {"command": command, "error": res["__error__"]})
			_note_hint = "Couldn't show this one: %s" % res["__error__"]
			_hint_hold_until = Time.get_ticks_msec() + 8000
			_refresh_card()
			_maybe_auto_ask()
			return
	_showing = false
	_note_hint = "✓ Done for you — Ctrl+Z%s to undo." % (" %d times" % actions.size() if actions.size() > 1 else "")
	_hint_hold_until = Time.get_ticks_msec() + 4000
	_refresh_card()
	_queue_check()

## Show me writes real code, so it keeps to the safe side: never a @tool
## script (those run inside the editor the moment they're saved) and never
## anything under addons/.
func _show_me_refusal(a: Dictionary) -> String:
	if str(a.get("command", "")) != "edit_script_text":
		return ""
	var path := str(a.get("path", ""))
	if not path.begins_with("res://") or path.begins_with("res://addons/"):
		return "Show me won't write to %s (only scripts in your own project, not addons). You can type it in yourself." % path
	for key in ["text", "new_text"]:
		if str(a.get(key, "")).contains("@tool"):
			return "Show me won't write a @tool script — those run inside the editor as soon as they're saved. You can type it in yourself."
	return ""

## One line for the announcement; code is shown in full, in a block.
func _describe_action(a: Dictionary) -> String:
	var node := str(a.get("node_path", ""))
	match str(a.get("command", "")):
		"edit_script_text":
			var code := str(a.get("new_text", a.get("text", ""))).strip_edges()
			if code.length() > 900:
				code = code.left(900) + "\n…"
			var where := ""
			var new_text := str(a.get("text", ""))
			var old_text := ""
			if FileAccess.file_exists(str(a.path)):
				var cur = _bridge._cmd_get_script_text({"path": str(a.path)})
				old_text = str(cur.text) if typeof(cur) == TYPE_DICTIONARY and not cur.has("__error__") else ""
			if a.has("old_text"):
				new_text = old_text.replace(str(a.old_text), str(a.get("new_text", "")))
			var lines: Array = _bridge._changed_lines(old_text, new_text)
			where = ", line %d" % lines[0] if lines[0] == lines[1] else ", lines %d–%d" % [lines[0], lines[1]]
			return "write to `%s`%s (opened in the Script editor, then saved):\n```\n%s\n```" % [str(a.path).get_file(), where, code]
		"add_node_live":
			return "add a **%s** named **%s** under **%s**" % [a.get("node_type", "node"), a.get("node_name", a.get("node_type", "")), str(a.get("parent_path", ".")).get_file()]
		"set_property":
			return "set **%s** · %s to `%s`" % [node.get_file(), str(a.get("property_name", "")).capitalize(), a.get("value", "")]
		"set_nested_property":
			return "set **%s** · %s to `%s`" % [node.get_file(), str(a.get("property_path", "")).replace(":", " → ").capitalize(), a.get("value", "")]
		"set_resource_property":
			return "give **%s** a new %s as %s" % [node.get_file(), a.get("resource_type", "resource"), str(a.get("property_name", "")).capitalize()]
		"rename_node":
			return "rename **%s** to **%s**" % [node.get_file(), a.get("new_name", "")]
		"attach_script":
			return "attach `%s` to **%s** and open it" % [str(a.get("script_path", "")).get_file(), node.get_file()]
		"interact_control":
			return "press the highlighted button"
		"save_scene_live":
			return "save the scene"
		"play_scene":
			return "play the game"
		"open_scene":
			return "open `%s`" % str(a.get("path", "")).get_file()
	return str(a.get("command", "")).replace("_", " ") + (" on **%s**" % node.get_file() if node != "" else "")

## The step's show_me actions with $vars filled in, or ones derived from its
## done_when check; [] when the step can't be shown.
func _show_me_actions(step: Dictionary) -> Array:
	var raw = step.get("show_me", null)
	_derive_step_text = str(step.get("text", ""))
	var actions: Array = raw if typeof(raw) == TYPE_ARRAY else _derive_show_me(step.done_when)
	if typeof(raw) != TYPE_ARRAY and str(step.done_when.type) == "control_pressed" and typeof(step.get("target")) == TYPE_DICTIONARY:
		# Press the very control the step outlines.
		var press: Dictionary = (step.target as Dictionary).duplicate()
		press["command"] = "interact_control"
		press["action"] = "press"
		actions = [press]
	var out := []
	for action in actions:
		var a := {}
		for key in action:
			var v = action[key]
			if typeof(v) == TYPE_STRING:
				v = _sub(str(v))
				if str(v).begins_with("<missing"):
					return []
			elif typeof(v) == TYPE_ARRAY:
				var arr := []
				for item in v:
					arr.append(_sub(str(item)) if typeof(item) == TYPE_STRING else item)
				v = arr
			a[key] = v
		out.append(a)
	# Attaching a script that doesn't exist yet: write a minimal one for the
	# node's class first (a later script_contains step can fill in the code),
	# and open it in the Script editor afterwards.
	var final := []
	for a in out:
		if str(a.get("command", "")) == "attach_script":
			var sp := str(a.get("script_path", ""))
			if sp != "" and not FileAccess.file_exists(sp):
				var target: Node = _bridge._resolve_node(str(a.get("node_path", ".")))
				final.append({"command": "edit_script_text", "path": sp, "save": true,
					"text": "extends %s\n" % (target.get_class() if target != null else "Node")})
			a["open"] = true
		final.append(a)
	return final

func _script_path_for(check: Dictionary) -> String:
	if check.has("script"):
		return str(check.script)
	var n := _node(str(check.get("node_path", "")))
	if n != null and n.get_script() != null:
		return (n.get_script() as Script).resource_path
	return ""

## Whitespace collapsed, so a check isn't defeated by indentation or blank lines.
func _squash(text: String) -> String:
	return RegEx.create_from_string("\\s+").sub(text, " ", true).strip_edges()

## A different value of the same type, for steps that only ask the learner
## to change something. null when there's no sensible nudge.
func _nudge(v):
	match typeof(v):
		TYPE_BOOL: return not v
		TYPE_INT: return v + 1
		TYPE_FLOAT: return v + maxf(1.0, absf(v) * 0.5)
		TYPE_VECTOR2: return v + Vector2(50, 50)
		TYPE_VECTOR3: return v + Vector3(0, 1, 0)
		TYPE_COLOR: return (v as Color).lightened(0.3) if (v as Color).v < 0.9 else (v as Color).darkened(0.3)
		TYPE_STRING: return str(v) + "!"
	return null

var _derive_step_text := ""   # the step being derived for (some derivations read its text)

func _derive_show_me(check: Dictionary) -> Array:
	match str(check.type):
		"script_contains":
			var path := _script_path_for(check)
			if path == "":
				return []
			var code := str(check.text)
			if FileAccess.file_exists(path):
				if check.has("replace"):
					return [{"command": "edit_script_text", "path": path, "old_text": str(check.replace), "new_text": code, "save": true}]
				var cur = _bridge._cmd_get_script_text({"path": path})
				var base: String = str(cur.text) if typeof(cur) == TYPE_DICTIONARY and not cur.has("__error__") else ""
				return [{"command": "edit_script_text", "path": path, "text": base.rstrip("\n") + "\n" + code + "\n", "save": true}]
			return [{"command": "edit_script_text", "path": path, "save": true,
				"text": "extends %s\n\n%s\n" % [str(check.get("extends", "Node")), code]}]
		"property_changed":
			var n := _node(str(check.node_path))
			if n == null:
				return []
			var nv = _nudge(n.get_indexed(NodePath(str(check.property))))
			if nv == null:
				return []
			if str(check.property).contains(":"):
				return [{"command": "set_nested_property", "node_path": check.node_path, "property_path": check.property, "value": var_to_str(nv)}]
			return [{"command": "set_property", "node_path": check.node_path, "property_name": check.property, "value": var_to_str(nv)}]
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
			if str(check.property).contains(":"):
				return [{"command": "set_nested_property", "node_path": check.node_path, "property_path": check.property, "value": check.value}]
			return [{"command": "set_property", "node_path": check.node_path, "property_name": check.property, "value": check.value}]
		"property_class":
			# A new resource of that class (mesh, shape, material…), undoably.
			var cls := str(check["class"])
			if not str(check.property).contains(":") and ClassDB.can_instantiate(cls):
				return [{"command": "set_resource_property", "node_path": check.node_path, "property_name": check.property,
					"resource_type": cls, "reuse_existing": false}]
		"scene_open":
			return [{"command": "open_scene", "path": check.path}]
		"game_running":
			return [{"command": "play_scene"}]
		"script_attached":
			var script_path := str(check.get("script", ""))
			if script_path == "":
				# The check only says "has a script": take the file from the
				# step's text ("Save it as res://cube.gd"), else name it after
				# the node. A missing file is created, then attached.
				var found := RegEx.create_from_string("res://[A-Za-z0-9_/.\\-]+\\.gd").search(_derive_step_text)
				if found != null:
					script_path = found.get_string()
				else:
					var target := _node(str(check.node_path))
					if target == null:
						return []
					script_path = "res://%s.gd" % str(target.name).to_snake_case()
			return [{"command": "attach_script", "node_path": check.node_path, "script_path": script_path}]
		"signal_connected":
			if check.has("method"):
				return [{"command": "connect_signal", "node_path": check.source, "signal_name": check.signal, "target_node_path": check.target, "method_name": check.method}]
		"in_group":
			var n := _node(str(check.node_path))
			if n != null:
				var groups := []
				for g in n.get_groups():
					if not str(g).begins_with("_"):
						groups.append(str(g))
				groups.append(str(check.group))
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
		_card_text.text += "\n[color=#e0b050]Couldn't save: %s[/color]" % _escape(str(res.error))
	else:
		_card_save.visible = false
		_card_text.text += "\n[color=#60e080]Saved to %s — replay it from Project ▸ Tools ▸ Guided Tours…[/color]" % _escape(str(res.path))

## The node_added step's new node now needs renaming: outline its Scene
## dock row instead of the + button.
func _point_at_new_node(check: Dictionary) -> void:
	var cap := str(check.get("capture", ""))
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
	if not _check_queued and not _holding and not _showing and is_running() and not _done:
		_check_queued = true
		_run_check.call_deferred()

func _run_check() -> void:
	_check_queued = false
	# While Show me is announcing or acting, the card's notes are its own
	# (a check would overwrite them, or advance mid-action).
	if not is_running() or _done or _holding or _showing:
		return
	var check: Dictionary = _steps[_index].done_when
	if _verify_only or _passes(check, "c"):
		if _revisit:
			if _note_hint != "✓ Already done — press Next to continue.":
				_note_hint = "✓ Already done — press Next to continue."
				_refresh_card()
			return
		await _complete_step()
		return
	_verify_since = 0
	var hint := _hint(check, "c")
	if hint.begins_with("✓ Added!") and not _pointed_at_new:
		_pointed_at_new = true
		_point_at_new_node(check)
	if hint != _note_hint and Time.get_ticks_msec() >= _hint_hold_until:
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
	match str(check.type):
		"node_added":
			var ids := {}
			var parent := _node(str(check.parent))
			if parent != null:
				for c in parent.get_children():
					ids[c.get_instance_id()] = true
			_baseline[key] = ids
			_baseline[key + ":all"] = _all_node_ids()
		"node_removed", "node_renamed", "node_reparented":
			var n := _node(str(check.node_path))
			_baseline[key] = weakref(n) if n != null else null
			if n != null:
				_baseline[key + ":name"] = str(n.name)
		"property_equals", "property_changed":
			var n := _node(str(check.node_path))
			if n != null:
				_baseline[key] = n.get_indexed(NodePath(str(check.property)))
				_baseline[key + ":node"] = weakref(n)
		"output_contains", "no_errors":
			_baseline[key] = {
				"lines": _editor_log_lines().size(),
				"seq": _bridge._output_capture.last_seq() if _bridge._output_capture != null else 0,
				"game_errs": _game_error_rows().size(),
			}
		"all", "any":
			for j in (check.checks as Array).size():
				_snapshot(check.checks[j], "%s.%d" % [key, j])

func _passes(check: Dictionary, key: String) -> bool:
	match str(check.type):
		"manual":
			return _manual_done  # the card's Next button
		"node_selected":
			var n := _node(str(check.node_path))
			return n != null and n in EditorInterface.get_selection().get_selected_nodes()
		"node_exists":
			return _node(str(check.node_path)) != null
		"node_added":
			var parent := _node(str(check.parent))
			if parent == null:
				return false
			var known: Dictionary = _baseline.get(key, {})
			for c in parent.get_children():
				if known.has(c.get_instance_id()):
					continue
				if check.has("class") and not c.is_class(str(check["class"])):
					continue
				if check.has("capture"):
					_vars[str(check.capture)] = weakref(c)
				# With a name, the step goes on to "now rename it" (see
				# _hint and _point_at_new_node) and completes once it's named.
				return not check.has("name") or str(c.name) == str(check.name)
			return false
		"node_removed":
			var ref = _baseline.get(key, null)
			if ref == null:
				return _node(str(check.node_path)) == null
			var n = ref.get_ref()
			return not (n is Node) or not (n as Node).is_inside_tree()
		"node_renamed":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			return n is Node and str(n.name) == str(check.name)
		"node_reparented":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			var parent := _node(str(check.parent))
			return n is Node and parent != null and (n as Node).get_parent() == parent
		"property_equals":
			var n := _node(str(check.node_path))
			if n == null:
				return false
			var actual = n.get_indexed(NodePath(str(check.property)))
			var expected = _bridge._decode_value(str(check.value))
			return _matches(actual, expected, float(check.get("tolerance", 0.0001)))
		"property_changed":
			var n := _node(str(check.node_path))
			if n == null or not _baseline.has(key):
				return false
			var actual = n.get_indexed(NodePath(str(check.property)))
			return not _matches(actual, _baseline[key], float(check.get("tolerance", 0.0001)))
		"property_class":
			var n := _node(str(check.node_path))
			if n == null:
				return false
			var v = n.get_indexed(NodePath(str(check.property)))
			return v is Object and (v as Object).is_class(str(check["class"]))
		"script_attached":
			var n := _node(str(check.node_path))
			if n == null or n.get_script() == null:
				return false
			return not check.has("script") or (n.get_script() as Script).resource_path == str(check.script)
		"signal_connected":
			var src := _node(str(check.source))
			var dst := _node(str(check.target))
			if src == null or dst == null or not src.has_signal(str(check.signal)):
				return false
			for conn in src.get_signal_connection_list(str(check.signal)):
				var callable: Callable = conn.callable
				if callable.get_object() == dst and (not check.has("method") or str(callable.get_method()) == str(check.method)):
					return true
			return false
		"in_group":
			var n := _node(str(check.node_path))
			return n != null and n.is_in_group(str(check.group))
		"script_contains":
			var path := _script_path_for(check)
			if path == "":
				return false
			# Includes unsaved edits in the open script tab.
			var got = _bridge._cmd_get_script_text({"path": path})
			if typeof(got) != TYPE_DICTIONARY or got.has("__error__"):
				return false
			return _squash(str(got.text)).contains(_squash(str(check.text)))
		"script_ok":
			return _script_error(check) == ""
		"output_contains":
			return _new_output(key).contains(str(check.text))
		"no_errors":
			return _new_errors(key).is_empty()
		"game_property":
			return _game_property_ok(check)
		"scene_open":
			var root: Node = _bridge._get_scene_root()
			return root != null and root.scene_file_path == str(check.path)
		"scene_saved":
			return _saved_during_step
		"file_exists":
			var p := str(check.path)
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
	match str(check.type):
		"node_added":
			var parent := _node(str(check.parent))
			if parent == null:
				return ""
			var want := str(check.get("class", ""))
			var known: Dictionary = _baseline.get(key, {})
			for c in parent.get_children():
				if not known.has(c.get_instance_id()) and want != "" and not c.is_class(want):
					return "That added a **%s**; this step wants a **%s**. Undo it with Ctrl+Z." % [c.get_class(), want]
			if check.has("name"):
				for c in parent.get_children():
					if not known.has(c.get_instance_id()) and (want == "" or c.is_class(want)) and str(c.name) != str(check.name):
						return "✓ Added! Now rename it to **%s**: double-click it in the Scene dock (or press F2) and type `%s`." % [check.name, check.name]
			if want != "":
				var all_known: Dictionary = _baseline.get(key + ":all", {})
				for n in _all_nodes():
					if not all_known.has(n.get_instance_id()) and n.is_class(want) and n.get_parent() != parent:
						return "That **%s** went under **%s**; it needs to be a child of **%s**. Drag it onto %s in the Scene dock." % [want, n.get_parent().name, parent.name, parent.name]
		"node_selected":
			var n := _node(str(check.node_path))
			var sel := EditorInterface.get_selection().get_selected_nodes()
			if n != null and not sel.is_empty() and not n in sel:
				return "You selected **%s**; this step wants **%s**." % [_node_label(sel[0]), _node_label(n)]
		"node_renamed":
			var n = _baseline[key].get_ref() if _baseline.get(key) != null else null
			if n is Node and str(n.name) != str(_baseline.get(key + ":name", "")) and str(n.name) != str(check.name):
				return "It's called **%s** now; this step wants **%s**." % [n.name, check.name]
		"property_equals":
			var n := _node(str(check.node_path))
			if n == null or not _baseline.has(key):
				return ""
			var actual = n.get_indexed(NodePath(str(check.property)))
			var tol := float(check.get("tolerance", 0.0001))
			if not _matches(actual, _baseline[key], tol):
				return "**%s** is now `%s`; this step wants `%s`." % [check.property, _show(actual), _show(_bridge._decode_value(str(check.value)))]
		"all", "any":
			for j in (check.checks as Array).size():
				var h := _hint(check.checks[j], "%s.%d" % [key, j])
				if h != "":
					return h
	return ""

## A node's name, or its path under the scene root when it has a parent —
## "MeshInstance3D" alone is ambiguous when two nodes share that name.
func _node_label(n: Node) -> String:
	var path: String = _bridge._rel_path(n)
	return str(n.name) if path == "." or path == str(n.name) else path

func _show(v) -> String:
	return str(v) if typeof(v) == TYPE_STRING else var_to_str(v).strip_edges()

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
	_game_pump()
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
	_card.tooltip_text = "Drag the title to move · double-click to let it follow the outline again"
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
	# Selectable and copyable (e.g. a line of code to paste into a script).
	# Dragging the card therefore works from the title and button row.
	_card_text.selection_enabled = true
	_card_text.context_menu_enabled = true
	_card_text.mouse_filter = Control.MOUSE_FILTER_STOP
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
	_card_ask = _card_button("Ask the agent", "Tell the agent what went wrong so it can change the plan", _on_ask_pressed)
	_card_ask.visible = false
	buttons.add_child(_card_ask)
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
	_card_title.text = "%s  ·  Step %d/%d%s" % [str(_tour.get("title", "Tour")), _index + 1, _steps.size(),
		"  ·  fix-up" if step.get("_fixup", false) else ("  ·  checking again" if _verify_only else "")]
	var text := _markdown(_name_vars(str(step.text)))
	if _note_why != "":
		text += "\n[color=#8cc4ff]%s[/color]" % _markdown(_note_why)
	for note in [_note_target, _note_hint, _note_stuck]:
		if note != "":
			var colour := "#60e080" if note.begins_with("✓") else "#e0b050"
			text += "\n[i][color=%s]%s[/color][/i]" % [colour, _markdown(note)]
	_card_text.text = text
	_card_back.disabled = _index == 0
	_card_next.visible = _revisit or str(step.done_when.type) == "manual"
	_card_show.visible = (not _show_me_actions(step).is_empty() or str(step.done_when.type) == "manual") and not _revisit
	_card_show.disabled = _showing
	_card_ask.visible = _has_problem() and _agent_panel() != null and not _showing
	_card_why.visible = str(step.get("why", "")) != "" or _agent_panel() != null

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
	names.sort_custom(func(a, b): return str(a).length() > str(b).length())
	for name in names:
		var n = _vars[name].get_ref()
		if n is Node:
			text = text.replace("$" + str(name), str(n.name))
	return text

## **bold** and `code` only; everything else is literal text.
func _markdown(src: String) -> String:
	var out := _escape(src)
	var bold := RegEx.create_from_string("\\*\\*(.+?)\\*\\*")
	out = bold.sub(out, "[b]$1[/b]", true)
	# Fenced blocks first (multi-line code); newlines are kept.
	var fenced := RegEx.create_from_string("(?s)```[a-zA-Z]*\\n?(.*?)```")
	out = fenced.sub(out, "[code]$1[/code]", true)
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
