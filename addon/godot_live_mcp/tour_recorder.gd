extends Node

## Record mode: do a task in the editor once, get a draft guided tour.
##
## Works by diffing, not by listening to individual events: on every undo
## history change it snapshots the edited scene (each node's name, parent,
## script, groups, signal connections and stored properties, plus the
## properties of embedded sub-resources such as a CollisionShape's shape)
## and compares it with the previous snapshot. That catches Inspector edits
## and viewport gizmo drags alike, and makes undo free: a value that goes
## back to where it started simply drops its step.
##
## Steps are kept as a model keyed by what they change ("prop:<id>:mass"),
## not as an event log, so 50 slider ticks are one step, renaming a node
## you just added folds into its "add" step, and deleting it again removes
## both.

const FORMAT := "godot-live-tour/1"
## Never recorded: editor bookkeeping, not something a learner does.
const SKIP_PROPS := ["script", "owner", "scene_file_path", "unique_name_in_owner"]

var _bridge: Node = null
var _runner: Node = null

var _root: Node = null
var _recording := false
var _prev := {}          # id -> node snapshot, as of the last change
var _baseline := {}      # id -> node snapshot when recording began (or when the node was added)
var _start_paths := {}   # id -> path at the start, for nodes that existed then
var _steps := {}         # key -> step
var _order: Array = []   # keys in first-seen order
var _saves := 0

var _bar: PanelContainer = null
var _bar_label: Label = null

func setup(bridge: Node, runner: Node) -> void:
	_bridge = bridge
	_runner = runner

func is_recording() -> bool:
	return _recording

# ---- Public API ------------------------------------------------------------

func start() -> Dictionary:
	if _recording:
		return {"error": "already recording"}
	_root = _bridge._get_scene_root()
	if _root == null:
		return {"error": "open a scene first — recording follows the scene that's open"}
	_prev = _snapshot()
	_baseline = _prev.duplicate(true)
	_start_paths = {}
	for id in _prev:
		_start_paths[id] = _prev[id].path
	_steps = {}
	_order = []
	_saves = 0
	_recording = true
	EditorInterface.get_editor_undo_redo().history_changed.connect(_on_change)
	EditorInterface.get_inspector().property_edited.connect(_on_property_edited)
	var plugin: EditorPlugin = _bridge._editor_plugin
	if plugin:
		plugin.scene_saved.connect(_on_saved)
	_show_bar()
	return {"recording": true, "scene": _root.scene_file_path}

## Stops recording. Unless discard, builds the tour; if save, writes it to
## res://tours/<title>.tour.json (or path). Returns {"tour", "path"?, "steps"}.
func stop(title: String, exact: bool, save := true, path := "", discard := false) -> Dictionary:
	if not _recording:
		return {"error": "not recording"}
	_on_change()
	_recording = false
	_disconnect()
	_hide_bar()
	if discard:
		return {"discarded": true}
	if _order.is_empty():
		return {"error": "nothing was recorded — no changes to the scene"}
	var tour := _build(title if title != "" else "Recorded tour", exact)
	var out := {"tour": tour, "steps": (tour.steps as Array).size()}
	if save:
		_runner._tour = tour
		_runner._source_path = ""
		var res: Dictionary = _runner.save(path)
		if res.has("error"):
			out["error"] = res.error
		else:
			out["path"] = res.path
	return out

func status() -> Dictionary:
	var lines := []
	for key in _order:
		lines.append(_describe(_steps[key]))
	return {"recording": _recording, "steps": lines}

# ---- Snapshots -------------------------------------------------------------

func _nodes() -> Array:
	if _root == null or not is_instance_valid(_root):
		return []
	var out := [_root]
	out.append_array(_root.find_children("*", "", true, false))
	return out

func _snapshot() -> Dictionary:
	var snap := {}
	for n in _nodes():
		var node := n as Node
		var s := {
			"name": str(node.name),
			"class": node.get_class(),
			"path": _bridge._rel_path(node),
			"parent": node.get_parent().get_instance_id() if node != _root else 0,
			"script": _script_key(node),
			"groups": _groups(node),
			"conns": _connections(node),
			"props": _props(node),
		}
		snap[node.get_instance_id()] = s
	return snap

func _script_key(n: Node) -> String:
	var sc = n.get_script()
	if sc == null:
		return ""
	return (sc as Script).resource_path if (sc as Script).resource_path != "" else "<built-in>"

func _groups(n: Node) -> Array:
	var out := []
	for g in n.get_groups():
		if not str(g).begins_with("_"):
			out.append(str(g))
	return out

## Persistent connections from this node, as "signal>target_id>method".
func _connections(n: Node) -> Array:
	var out := []
	for sig in n.get_signal_list():
		for c in n.get_signal_connection_list(sig.name):
			if not (int(c.flags) & CONNECT_PERSIST):
				continue
			var callable: Callable = c.callable
			var target = callable.get_object()
			if target is Node:
				out.append("%s>%d>%s" % [sig.name, (target as Node).get_instance_id(), callable.get_method()])
	return out

## Stored properties as {name: [var_to_str, type, is_enum]}; embedded
## sub-resources add "prop:sub" entries and record their class.
func _props(obj: Object, prefix := "") -> Dictionary:
	var out := {}
	for p in obj.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE) or (int(p.usage) & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP)):
			continue
		var name := str(p.name)
		if name in SKIP_PROPS or name.begins_with("metadata/_edit") or name.begins_with("_"):
			continue
		var v = obj.get(name)
		var key := prefix + name
		var is_enum := int(p.hint) == PROPERTY_HINT_ENUM or int(p.hint) == PROPERTY_HINT_FLAGS
		if v is Resource:
			var r := v as Resource
			if r.resource_path != "" and not r.resource_path.contains("::"):
				out[key] = ["load:" + r.resource_path, TYPE_OBJECT, false, r.get_class()]
			else:
				out[key] = ["<new %s>" % r.get_class(), TYPE_OBJECT, false, r.get_class()]
				if prefix == "":  # one level of sub-resource properties
					out.merge(_props(r, key + ":"))
		elif v is Object:
			continue
		else:
			out[key] = [var_to_str(v).strip_edges(), typeof(v), is_enum, ""]
	return out

# ---- Diffing into the step model -----------------------------------------

func _on_property_edited(_property: String) -> void:
	_on_change.call_deferred()

func _on_saved(_path: String) -> void:
	_on_change()
	if not _order.is_empty() and str(_order[-1]).begins_with("save:"):
		return
	_saves += 1
	_put("save:%d" % _saves, {"kind": "save"})
	_update_bar()

func _on_change() -> void:
	if not _recording:
		return
	var probe_t0 := Time.get_ticks_usec()
	_diff_scene()
	_bridge._perf_add("recorder_diff", Time.get_ticks_usec() - probe_t0)

func _diff_scene() -> void:
	if _bridge._get_scene_root() != _root:
		return  # another scene is open: only the recorded one counts
	var cur := _snapshot()
	for id in cur:
		if not _prev.has(id):
			_node_appeared(id, cur)
	for id in _prev:
		if not cur.has(id):
			_node_gone(id)
	for id in cur:
		if _prev.has(id):
			_node_changed(id, _prev[id], cur[id])
	_prev = cur
	_update_bar()

func _node_appeared(id: int, cur: Dictionary) -> void:
	if _start_paths.has(id):
		_erase("remove:%d" % id)  # an undone delete
		return
	_baseline[id] = cur[id].duplicate(true)
	_put("add:%d" % id, {"kind": "add", "id": id, "class": cur[id]["class"], "name": cur[id].name, "parent": cur[id].parent})

func _node_gone(id: int) -> void:
	if _steps.has("add:%d" % id):
		# Added and deleted again: as if it never happened.
		for key in _order.duplicate():
			var parts := str(key).split(":")
			if (parts.size() > 1 and parts[1] == str(id)) or str(key).contains(">%d>" % id):
				_erase(key)
		_baseline.erase(id)
		return
	_put("remove:%d" % id, {"kind": "remove", "id": id, "name": _prev[id].name})

func _node_changed(id: int, before: Dictionary, now: Dictionary) -> void:
	var added := _steps.has("add:%d" % id)
	var base: Dictionary = _baseline.get(id, before)
	if now.name != before.name:
		if added:
			_steps["add:%d" % id].name = now.name
		elif now.name == base.name:
			_erase("rename:%d" % id)
		else:
			_put("rename:%d" % id, {"kind": "rename", "id": id, "name": now.name})
	if now.parent != before.parent:
		if added:
			_steps["add:%d" % id].parent = now.parent
		elif now.parent == base.parent:
			_erase("move:%d" % id)
		else:
			_put("move:%d" % id, {"kind": "move", "id": id, "parent": now.parent})
	if now.script != before.script:
		if now.script == base.script:
			_erase("script:%d" % id)
		elif now.script != "":
			_put("script:%d" % id, {"kind": "script", "id": id, "script": now.script})
	for g in now.groups:
		if not g in base.groups:
			_put("group:%d:%s" % [id, g], {"kind": "group", "id": id, "group": g})
	for g in before.groups:
		if not g in now.groups:
			_erase("group:%d:%s" % [id, g])
	for c in now.conns:
		if not c in base.conns:
			_put("sig:%d:%s" % [id, c], {"kind": "signal", "id": id, "conn": c})
	for c in before.conns:
		if not c in now.conns:
			_erase("sig:%d:%s" % [id, c])
	var props: Dictionary = now.props
	var old: Dictionary = before.props
	var base_props: Dictionary = base.props
	for key in props:
		if old.has(key) and old[key][0] == props[key][0]:
			continue
		var k := "prop:%d:%s" % [id, key]
		if base_props.has(key) and base_props[key][0] == props[key][0]:
			_erase(k)
			continue
		# Sub-properties of a resource that was just swapped are part of
		# the new resource, not separate edits.
		if str(key).contains(":") and not (old.has(key)):
			continue
		_put(k, {"kind": "prop", "id": id, "prop": key, "value": props[key][0], "type": props[key][1],
			"enum": props[key][2], "res_class": props[key][3]})

func _put(key: String, step: Dictionary) -> void:
	if not _steps.has(key):
		_order.append(key)
	_steps[key] = step

func _erase(key: String) -> void:
	if _steps.has(key):
		_steps.erase(key)
		_order.erase(key)

func _disconnect() -> void:
	var undo := EditorInterface.get_editor_undo_redo()
	if undo.history_changed.is_connected(_on_change):
		undo.history_changed.disconnect(_on_change)
	var insp := EditorInterface.get_inspector()
	if insp.property_edited.is_connected(_on_property_edited):
		insp.property_edited.disconnect(_on_property_edited)
	var plugin: EditorPlugin = _bridge._editor_plugin if _bridge else null
	if plugin and plugin.scene_saved.is_connected(_on_saved):
		plugin.scene_saved.disconnect(_on_saved)

# ---- Building the tour -----------------------------------------------------

var _var_of := {}     # node id -> var name
var _vars := {}       # var name -> node path at tour start (existing nodes)
var _used_names := {}

## The tour's name for a node: existing nodes get a var by their starting
## path, added ones the capture var of their add step.
func _var(id: int) -> String:
	if _var_of.has(id):
		return _var_of[id]
	var name := "root" if _start_paths.get(id, "") == "." else _unique(str(_last_name(id)).to_snake_case())
	_var_of[id] = name
	if _start_paths.has(id):
		_vars[name] = _start_paths[id]
	return name

func _last_name(id: int) -> String:
	if _prev.has(id):
		return _prev[id].name
	if _baseline.has(id):
		return _baseline[id].name
	return "node"

func _unique(base: String) -> String:
	var name := base if base != "" else "node"
	var n := 2
	while _used_names.has(name):
		name = "%s%d" % [base, n]
		n += 1
	_used_names[name] = true
	return name

func _build(title: String, exact: bool) -> Dictionary:
	_var_of = {}
	_vars = {}
	_used_names = {"root": true}
	var steps := []
	for key in _order:
		var s: Dictionary = _steps[key]
		var step := _step_for(s, exact)
		if not step.is_empty():
			step["id"] = str(key).replace(":", "-").replace(">", "-")
			steps.append(step)
	var tour := {"format": FORMAT, "title": title, "vars": _vars, "steps": steps}
	if _root.scene_file_path != "":
		tour["requires"] = {"scene_open": _root.scene_file_path}
	return tour

func _step_for(s: Dictionary, exact: bool) -> Dictionary:
	match str(s.kind):
		"add":
			var cls := str(s["class"])
			var parent := _var(int(s.parent))
			var v := _var_for_new(int(s.id), str(s.name))
			var check := {"type": "node_added", "parent": "$" + parent, "class": cls, "capture": v}
			var text := "Click **+**, search for `%s`, and add it under **$%s**." % [cls, parent]
			if not _is_default_name(str(s.name), cls):
				check["name"] = s.name
			return {"text": text, "target": {"root": "scene_tree", "tooltip": "Add/Create a New Node"}, "done_when": check}
		"remove":
			var v := _var(int(s.id))
			return {"text": "Delete **$%s**: select it and press **Delete**." % v, "target": {"node_path": "$" + v},
				"done_when": {"type": "node_removed", "node_path": "$" + v}}
		"rename":
			var v := _var(int(s.id))
			return {"text": "Rename **$%s** to `%s` (double-click it in the Scene dock, or press **F2**)." % [v, s.name],
				"target": {"node_path": "$" + v}, "done_when": {"type": "node_renamed", "node_path": "$" + v, "name": s.name}}
		"move":
			var v := _var(int(s.id))
			var p := _var(int(s.parent))
			return {"text": "Drag **$%s** onto **$%s** in the Scene dock." % [v, p], "target": {"node_path": "$" + v},
				"done_when": {"type": "node_reparented", "node_path": "$" + v, "parent": "$" + p}}
		"script":
			var v := _var(int(s.id))
			var check := {"type": "script_attached", "node_path": "$" + v}
			var text := "Select **$%s** and click **Attach Script**." % v
			if str(s.script) != "<built-in>":
				text += " (We used `%s`.)" % s.script
				if exact:
					check["script"] = s.script
			return {"text": text, "target": {"root": "scene_tree", "tooltip": "Attach a new or existing script"}, "done_when": check}
		"group":
			var v := _var(int(s.id))
			return {"text": "Add **$%s** to the group `%s` (the **Groups** tab next to the Inspector)." % [v, s.group],
				"done_when": {"type": "in_group", "node_path": "$" + v, "group": s.group}}
		"signal":
			var parts := str(s.conn).split(">")
			var v := _var(int(s.id))
			var t := _var(int(parts[1]))
			return {"text": "In the **Signals** tab, connect **$%s**'s `%s` signal to **$%s** (method `%s`)." % [v, parts[0], t, parts[2]],
				"done_when": {"type": "signal_connected", "source": "$" + v, "signal": parts[0], "target": "$" + t, "method": parts[2]}}
		"save":
			return {"text": "Save the scene (**Ctrl+S**).", "done_when": {"type": "scene_saved"}}
		"prop":
			return _prop_step(s, exact)
	return {}

func _var_for_new(id: int, name: String) -> String:
	if not _var_of.has(id):
		_var_of[id] = _unique(name.to_snake_case())
	return _var_of[id]

func _is_default_name(name: String, cls: String) -> bool:
	return name == cls or (name.begins_with(cls) and name.substr(cls.length()).is_valid_int())

## Text and strings, switches, dropdowns and new resources are the lesson,
## so they must match; numbers, vectors and colours just have to change
## unless exact is on (the card still shows the value we used).
func _prop_step(s: Dictionary, exact: bool) -> Dictionary:
	var v := _var(int(s.id))
	var prop := str(s.prop)
	var base := prop.get_slice(":", 0)
	var label := "**%s**" % " → ".join(Array(prop.split(":")).map(func(p): return str(p).capitalize()))
	var target := {"node_path": "$" + v, "property": base}
	var value := str(s.value)
	var t := int(s.type)
	if value.begins_with("<new "):
		var cls := str(s.res_class)
		return {"text": "Set **$%s**'s %s to a new **%s** (click the value, then **New %s**)." % [v, label, cls, cls], "target": target,
			"done_when": {"type": "property_class", "node_path": "$" + v, "property": prop, "class": cls}}
	if value.begins_with("load:"):
		var file := value.substr(5)
		if exact:
			return {"text": "Set **$%s**'s %s to `%s` (drag it from the FileSystem dock)." % [v, label, file], "target": target,
				"done_when": {"type": "property_equals", "node_path": "$" + v, "property": prop, "value": value}}
		return {"text": "Set **$%s**'s %s, e.g. drag `%s` onto it from the FileSystem dock." % [v, label, file], "target": target,
			"done_when": {"type": "property_class", "node_path": "$" + v, "property": prop, "class": str(s.res_class)},
			"show_me": [_set_action(v, prop, value)]}
	var must_match := exact or bool(s.enum) or t in [TYPE_STRING, TYPE_STRING_NAME, TYPE_BOOL, TYPE_NODE_PATH]
	var shown := value.trim_prefix("\"").trim_suffix("\"") if t == TYPE_STRING or t == TYPE_STRING_NAME else value
	if t == TYPE_BOOL:
		return {"text": "%s **$%s**'s %s." % ["Turn on" if value == "true" else "Turn off", v, label], "target": target,
			"done_when": {"type": "property_equals", "node_path": "$" + v, "property": prop, "value": value}}
	if must_match:
		var check := {"type": "property_equals", "node_path": "$" + v, "property": prop, "value": value}
		if t in [TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_COLOR]:
			check["tolerance"] = 0.01
		return {"text": "Set **$%s**'s %s to `%s`." % [v, label, shown], "target": target, "done_when": check}
	return {"text": "Change **$%s**'s %s (we used `%s`)." % [v, label, shown], "target": target,
		"done_when": {"type": "property_changed", "node_path": "$" + v, "property": prop},
		"show_me": [_set_action(v, prop, value)]}

## Show me for a recorded value: the value the recording used.
func _set_action(v: String, prop: String, value: String) -> Dictionary:
	if prop.contains(":"):
		return {"command": "set_nested_property", "node_path": "$" + v, "property_path": prop, "value": value}
	return {"command": "set_property", "node_path": "$" + v, "property_name": prop, "value": value}

func _describe(s: Dictionary) -> String:
	match str(s.kind):
		"add": return "add %s '%s'" % [s["class"], s.name]
		"remove": return "delete '%s'" % s.name
		"rename": return "rename to '%s'" % s.name
		"move": return "move node"
		"script": return "attach script %s" % s.script
		"group": return "add to group '%s'" % s.group
		"signal": return "connect %s" % str(s.conn).get_slice(">", 0)
		"save": return "save scene"
		"prop": return "set %s = %s" % [s.prop, str(s.value).left(40)]
	return str(s.kind)

# ---- Recording bar -----------------------------------------------------------

func _show_bar() -> void:
	_bar = PanelContainer.new()
	_bar.name = "GodotLiveMCPRecordingBar"
	_bar.z_index = 101
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.1, 0.1, 0.96)
	sb.border_color = Color(0.9, 0.25, 0.25)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	_bar.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_bar.add_child(row)
	_bar_label = Label.new()
	_bar_label.add_theme_color_override("font_color", Color(1, 0.55, 0.55))
	row.add_child(_bar_label)
	var stop_b := Button.new()
	stop_b.text = "Stop & save…"
	stop_b.focus_mode = Control.FOCUS_NONE
	stop_b.pressed.connect(_ask_title)
	row.add_child(stop_b)
	var cancel_b := Button.new()
	cancel_b.text = "Cancel"
	cancel_b.focus_mode = Control.FOCUS_NONE
	cancel_b.pressed.connect(func() -> void: stop("", false, false, "", true))
	row.add_child(cancel_b)
	var base := EditorInterface.get_base_control()
	base.add_child(_bar)
	_update_bar()

func _update_bar() -> void:
	if _bar == null or not is_instance_valid(_bar):
		return
	_bar_label.text = "● Recording a tour — %d step%s so far" % [_order.size(), "" if _order.size() == 1 else "s"]
	var base := EditorInterface.get_base_control().get_global_rect()
	_bar.size = _bar.get_combined_minimum_size()
	_bar.global_position = Vector2(base.get_center().x - _bar.size.x / 2.0, base.position.y + 34)

func _hide_bar() -> void:
	if _bar != null and is_instance_valid(_bar):
		_bar.queue_free()
	_bar = null

## Stop & save…: asks for a title and whether values must match exactly.
func _ask_title() -> void:
	var d := ConfirmationDialog.new()
	d.title = "Save recorded tour"
	d.ok_button_text = "Save"
	var box := VBoxContainer.new()
	d.add_child(box)
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Tour title, e.g. A bouncing ball"
	name_edit.custom_minimum_size = Vector2(360, 0)
	box.add_child(name_edit)
	var exact := CheckBox.new()
	exact.text = "Require exact values (numbers, colours, sizes)"
	exact.tooltip_text = "Off: learners just have to change those values, and the card shows what you used. Text, switches, dropdowns and new resources always have to match."
	box.add_child(exact)
	d.confirmed.connect(func() -> void:
		var res := stop(name_edit.text.strip_edges(), exact.button_pressed)
		if res.has("error"):
			_runner._alert("Couldn't save the tour: " + str(res.error))
		else:
			_runner._alert("Saved %d steps to %s.\n\nPlay it from Project ▸ Tools ▸ Guided Tours…, edit the text in the file, or ask the agent to add Why? explanations." % [res.steps, res.path]))
	d.visibility_changed.connect(func() -> void:
		if not d.visible:
			d.queue_free.call_deferred())
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered()
	name_edit.grab_focus()
