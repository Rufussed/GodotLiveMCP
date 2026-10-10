extends Node

## Watch mode: shows each action the agent takes, as it takes it. The
## bridge's dispatcher calls observe() after every command; that only queues
## a "beat" (caption, plus what to outline) and returns, so the agent is never
## slowed down. _process() then plays the beats: a brief outline on the
## Scene dock row (and the Inspector property, if that node is already
## open) plus a line in a small log panel. See WATCH_MODE_PLAN.md.

const HighlightOverlay = preload("res://addons/godot_live_mcp/highlight_overlay.gd")

const BEAT_SEC := 0.9        # how long a beat is shown when nothing else is waiting
const MIN_BEAT_SEC := 0.12
const MAX_LAG_SEC := 2.0     # whatever is queued clears in about this long
const KEEP_AFTER_SKIP := 5
const SKIP_AFTER := 20       # queued beats before jumping ahead

## Commands that don't change anything worth watching: reads, the editor's
## own UI tools, and tour/recording bookkeeping.
const IGNORED := ["ping", "get_output_log", "list_scene_tree", "get_node_properties", "validate_script",
	"get_script_text", "get_node_groups", "get_editor_selection", "select_nodes", "clear_editor_selection",
	"reload_plugin", "restart_editor", "is_playing_scene", "reload_project", "get_signals", "find_nodes",
	"get_editor_screenshot", "get_inspector_screenshot", "dump_control_tree", "interact_control",
	"highlight_editor_control", "clear_editor_highlights", "start_tour", "save_tour", "start_recording",
	"stop_recording", "get_recording_status", "list_tours", "get_tour_status", "stop_tour",
	"refresh_editor_scripts", "get_collision_info", "get_physics_layers", "get_material_info",
	"get_node_bounds", "get_shader_material_info", "get_animation_info", "get_audio_bus_layout",
	"tilemap_get_info", "get_particle_info", "get_resource_dependencies", "set_watch_mode", "get_watch_mode"]

var _bridge: Node = null
var _queue: Array = []       # beats waiting to be shown
## The log, grouped by response: [{title, entries: [{line, node?, property?}],
## expanded}], newest group first, entries newest first within a group.
var _groups: Array = []
var _pending_title := ""     # the user's latest message, for the next group
var _last_observed := 0      # msec of the last observed command
const IDLE_NEW_GROUP_SEC := 20.0   # agents outside the panel: a pause starts a new group
const MAX_GROUPS := 20
const MAX_ENTRIES := 300
var _skipped := 0            # beats dropped while catching up
var _beat_left := 0.0
var _beat_gen := 0         # stale async outline lookups check this
var _overlay := HighlightOverlay.new()

var _panel: Control = null
var _panel_text: RichTextLabel = null
var _panel_title: Label = null

func setup(bridge: Node) -> void:
	_bridge = bridge

func _ready() -> void:
	set_process(true)

## Called by the dispatcher after every command while Watch is on.
func observe(command: String, params: Dictionary, result, ok: bool, error) -> void:
	if command in IGNORED or command.begins_with("get_") or command.begins_with("list_"):
		return
	var beat := _describe(command, params, result if typeof(result) == TYPE_DICTIONARY else {})
	if beat.is_empty():
		return
	if not ok:
		beat.caption = "✗ failed: %s — %s" % [beat.caption, str(error).get_slice("\n", 0).get_slice(" (the edited scene", 0).left(80)]
		beat.erase("node")
		beat.erase("merge_key")  # a failure is its own line
		beat["failed"] = true
	# Resolve the node now, while its path is certainly right: by the time
	# the beat is shown the agent may have renamed or moved it.
	var path := str(beat.get("node", ""))
	if path != "":
		var n: Node = _bridge._resolve_node(path)
		if n != null:
			beat["ref"] = weakref(n)
	beat["group"] = _group_for_now()
	_enqueue(beat)

## The panel calls this when the user sends a message: the steps that
## follow are grouped under it.
func begin_response(title: String) -> void:
	_pending_title = title.replace("\n", " ").strip_edges()

## Which group a command observed now belongs to. Decided when the agent
## acts, not when Watch shows it, so a lagging display still files each
## step under the right response.
func _group_for_now() -> Dictionary:
	var now := Time.get_ticks_msec()
	var idle := _groups.is_empty() or (now - _last_observed) / 1000.0 > IDLE_NEW_GROUP_SEC
	_last_observed = now
	if _pending_title != "" or idle:
		var title := _pending_title if _pending_title != "" else "Agent at %s" % Time.get_time_string_from_system().left(5)
		_pending_title = ""
		for g in _groups:
			g.expanded = false  # older responses collapse
		var group := {"title": title, "entries": [], "expanded": true}
		_groups.push_front(group)
		if _groups.size() > MAX_GROUPS:
			_groups.resize(MAX_GROUPS)
		return group
	return _groups[0]

func clear() -> void:
	_queue.clear()
	_groups.clear()
	_pending_title = ""
	_current_entry = {}
	_skipped = 0
	_overlay.clear()
	_remove_panel()

# ---- Describing commands ---------------------------------------------------

## {caption, node?, property?, merge_key?} for one command; {} to skip it.
func _describe(command: String, p: Dictionary, r: Dictionary) -> Dictionary:
	var node := str(p.get("node_path", ""))
	match command:
		"add_node_live":
			var path := str(r.get("path", ""))
			var name := path.get_file() if path != "" else str(p.get("node_name", p.get("node_type", "a node")))
			return {"caption": "added **%s** (%s) under **%s**" % [name, p.get("node_type", "?"), _short(str(p.get("parent_path", ".")))], "node": path}
		"remove_node":
			return {"caption": "deleted **%s**" % _short(node)}
		"rename_node":
			return {"caption": "renamed **%s** → **%s**" % [_short(node), p.get("new_name", "?")], "node": str(r.get("path", ""))}
		"reparent_node":
			return {"caption": "moved **%s** under **%s**" % [_short(node), _short(str(p.get("new_parent_path", "?")))], "node": str(r.get("path", node))}
		"duplicate_node":
			return {"caption": "duplicated **%s**" % _short(node), "node": str(r.get("path", ""))}
		"set_property":
			var prop := str(p.get("property_name", "?"))
			return {"caption": "**%s** · %s → %s" % [_short(node), prop.capitalize(), _value(p.get("value", ""))], "node": node,
				"property": prop, "merge_key": node, "props": [prop.capitalize()]}
		"set_properties", "batch_set_properties":
			var props: Array = (p.get("properties", {}) as Dictionary).keys() if typeof(p.get("properties")) == TYPE_DICTIONARY else []
			var names := props.map(func(x): return str(x).capitalize())
			return {"caption": "**%s** · %s" % [_short(node), ", ".join(names)], "node": node,
				"property": str(props[0]) if props.size() == 1 else "", "merge_key": node, "props": names}
		"set_nested_property":
			var pp := str(p.get("property_path", "?"))
			return {"caption": "**%s** · %s → %s" % [_short(node), pp.replace(":", " → ").capitalize(), _value(p.get("value", ""))],
				"node": node, "property": pp.get_slice(":", 0), "merge_key": node, "props": [pp.capitalize()]}
		"set_resource_property":
			var prop := str(p.get("property_name", "?"))
			return {"caption": "**%s** · %s → new %s" % [_short(node), prop.capitalize(), p.get("resource_type", "?")], "node": node,
				"property": prop, "merge_key": node, "props": [prop.capitalize()]}
		"set_transform":
			return {"caption": "**%s** · moved / rotated / scaled" % _short(node), "node": node, "merge_key": node, "props": ["Transform"]}
		"attach_script":
			return {"caption": "attached `%s` to **%s**" % [str(p.get("script_path", "a script")).get_file(), _short(node)], "node": node}
		"connect_signal":
			return {"caption": "connected **%s**.%s → **%s**.%s" % [_short(node), p.get("signal_name", "?"), _short(str(p.get("target_node_path", "?"))), p.get("method_name", "?")], "node": node}
		"disconnect_signal":
			return {"caption": "disconnected **%s**.%s" % [_short(node), p.get("signal_name", "?")], "node": node}
		"set_node_groups":
			return {"caption": "**%s** · groups → %s" % [_short(node), ", ".join(p.get("groups", []))], "node": node}
		"edit_script_text":
			var lines: Array = r.get("lines", []) if typeof(r.get("lines")) == TYPE_ARRAY else []
			var where := ""
			if lines.size() == 2:
				where = " · line %d" % lines[0] if int(lines[0]) == int(lines[1]) else " · lines %d–%d" % [lines[0], lines[1]]
			return {"caption": "edited `%s`%s" % [str(p.get("path", "a script")).get_file(), where],
				"script": str(p.get("path", "")), "lines": lines}
		"save_scene_live":
			return {"caption": "saved the scene"}
		"open_scene":
			return {"caption": "opened `%s`" % str(p.get("path", "?")).get_file()}
		"play_scene":
			return {"caption": "started the game"}
		"stop_scene":
			return {"caption": "stopped the game"}
		"run_script", "eval_expression":
			# Agents often run scripts just to read things: only show the
			# ones that changed the scene.
			if not r.has("scene_changed_note"):
				return {}
			return {"caption": ("ran a script" if command == "run_script" else "evaluated an expression") + " that changed the scene directly"}
		"save_resource_file":
			return {"caption": "saved `%s`" % str(p.get("path", "a resource")).get_file()}
		"set_material_3d", "set_physics_material", "set_shader_material", "set_particle_material", "set_particle_color_gradient":
			return {"caption": "**%s** · %s" % [_short(node), command.trim_prefix("set_").capitalize()], "node": node, "merge_key": node,
				"props": [command.trim_prefix("set_").capitalize()]}
	# Anything else that changes something: name the command and its node.
	var label := command.replace("_", " ")
	return {"caption": label + (" on **%s**" % _short(node) if node != "" else ""), "node": node}

func _short(path: String) -> String:
	if path == "" or path == ".":
		var root: Node = _bridge._get_scene_root()
		return str(root.name) if root != null else "the scene root"
	return path.get_file()

func _value(v) -> String:
	var s := str(v).strip_edges()
	if s.begins_with("\"") and s.ends_with("\"") and s.length() >= 2:
		s = s.substr(1, s.length() - 2)
	if s.begins_with("load:"):
		s = s.substr(5).get_file()
	return "`%s`" % (s.left(36) + "…" if s.length() > 36 else s)

# ---- Queue and pacing -----------------------------------------------------
#
# Two pacings, chosen by the "Watch step time" setting:
# - rhythm (step time > 0, default 2 s): every change gets its own turn of
#   that length — its log line highlighted, its node and property outlined —
#   and Watch simply runs behind a fast agent ("3 more coming").
# - keep up (step time 0): beats shrink and merge so the display is never
#   more than about MAX_LAG_SEC behind the agent.

const STEP_SETTING := "watch_step_sec"
const FOLLOW_SETTING := "watch_follow"
const RHYTHM_SKIP_AFTER := 100   # rhythm mode only drops beats if hopelessly behind

func _step_sec() -> float:
	return float(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", STEP_SETTING, 2.0))

## Open the touched node in the Inspector so the changed property can be
## outlined (rhythm mode's default); off keeps the user's view untouched.
func _follow() -> bool:
	return bool(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", FOLLOW_SETTING, true))

func _enqueue(beat: Dictionary) -> void:
	beat["t"] = Time.get_ticks_msec()
	var rhythm := _step_sec() > 0.0
	# Keep-up mode merges consecutive property edits on one node into one
	# beat ("**Ball** · Mass, Gravity Scale"); rhythm mode shows each.
	if not rhythm and not _queue.is_empty() and beat.has("merge_key"):
		var last: Dictionary = _queue[-1]
		if last.get("merge_key", null) == beat.merge_key and not last.get("failed", false):
			var props: Array = last.get("props", [])
			for x in beat.get("props", []):
				if not x in props:
					props.append(x)
			last.props = props
			last.caption = "**%s** · %s" % [_short(str(beat.node)), ", ".join(props)]
			last.t = beat.t
			last.property = ""
			return
	_queue.append(beat)
	if not rhythm and _beat_left > 0.0:
		# The beat on screen was timed before this one arrived: cut it
		# short if its time is now needed to keep up.
		_beat_left = minf(_beat_left, _beat_duration())
	var limit := RHYTHM_SKIP_AFTER if rhythm else SKIP_AFTER
	if _queue.size() > limit:
		var drop := _queue.size() - KEEP_AFTER_SKIP
		_skipped += drop
		_queue = _queue.slice(drop)
	if _panel != null and is_instance_valid(_panel):
		_refresh_title()

func _process(delta: float) -> void:
	if not _overlay.is_empty():
		_overlay.update()
	_place_panel()
	if _beat_left > 0.0:
		_beat_left -= delta
		if _beat_left > 0.0:
			return
	if _queue.is_empty():
		_beat_left = 0.0
		if _current:
			# The last beat's turn is over: un-highlight it.
			_current = false
			_overlay.clear()
			_refresh_panel()
		return
	var step := _step_sec()
	if step > 0.0:
		_beat_left = step
		_show(_queue.pop_front())
		_refresh_panel()
		return
	# Keep-up mode, paced by wall-clock time, not frames: an unfocused editor
	# runs at ~10 fps, so a late frame logs the beats that should already
	# have ended and only outlines the current one.
	var overdue := -_beat_left
	while not _queue.is_empty():
		var beat: Dictionary = _queue.pop_front()
		var dur := _beat_duration()
		if overdue >= dur and not _queue.is_empty():
			overdue -= dur
			_add_to_log(beat)
			continue
		_beat_left = maxf(dur - overdue, MIN_BEAT_SEC)
		_show(beat)
		break
	_refresh_panel()

## Keep-up mode: every action should be on screen within MAX_LAG_SEC of
## happening, so the time left until the newest queued beat's deadline is
## shared between the beats still to show.
func _beat_duration() -> float:
	if _queue.is_empty():
		return BEAT_SEC
	var newest_age := (Time.get_ticks_msec() - int(_queue[-1].get("t", 0))) / 1000.0
	var left := MAX_LAG_SEC - newest_age
	return clampf(left / (_queue.size() + 1), MIN_BEAT_SEC, BEAT_SEC)

func _add_to_log(beat: Dictionary) -> Dictionary:
	var group: Dictionary = beat.get("group", {}) if typeof(beat.get("group")) == TYPE_DICTIONARY else {}
	if group.is_empty():
		group = _group_for_now()
	var entries: Array = group.entries
	if _skipped > 0:
		entries.push_front({"line": "[i]…%d skipped[/i]" % _skipped})
		_skipped = 0
	var mark := "[color=#e08080]✗[/color] " if beat.get("failed", false) else "[color=#5aa0ff]▸[/color] "
	var text := _markdown(str(beat.caption).trim_prefix("✗ "))
	var entry := {"step": true, "line": mark + (text if not beat.get("failed", false) else "[color=#e08080]%s[/color]" % text)}
	# A reference to the node itself, so a later rename or move doesn't
	# break the link.
	if beat.has("ref"):
		entry["node"] = beat.ref
		entry["property"] = str(beat.get("property", ""))
	if str(beat.get("script", "")) != "":
		entry["script"] = str(beat.script)
		entry["lines"] = beat.get("lines", [])
	entries.push_front(entry)
	if entries.size() > MAX_ENTRIES:
		entries.resize(MAX_ENTRIES)
	return entry

var _current := false          # a beat is on screen now
var _current_entry := {}       # its log entry, highlighted

## One header per response ("▾ "make a floor…" · 12 steps"; click to fold),
## then its steps, newest first. Lines about a node are links (see
## _on_log_clicked); the beat on screen is highlighted.
func _refresh_panel() -> void:
	_ensure_panel()
	var lines := []
	for gi in _groups.size():
		var g: Dictionary = _groups[gi]
		var title := str(g.title)
		if title.length() > 48:
			title = title.left(48) + "…"
		var n_steps := (g.entries as Array).filter(func(e): return e.get("step", false)).size()
		lines.append("[url=g:%d][color=#9ec3ff]%s %s[/color][color=#7a8aa0]  ·  %d step%s[/color][/url]" % [
			gi, "▾" if g.expanded else "▸", _markdown(title).replace("[url", "[lb]url"), n_steps, "" if n_steps == 1 else "s"])
		if not g.expanded:
			continue
		for ei in (g.entries as Array).size():
			var e: Dictionary = g.entries[ei]
			var n = e.node.get_ref() if e.has("node") else null
			var linked: bool = (n is Node and (n as Node).is_inside_tree()) or e.has("script")
			var line: String = "   [url=e:%d:%d]%s[/url]" % [gi, ei, e.line] if linked else "   " + str(e.line)
			if _current and is_same(e, _current_entry):
				line = "[bgcolor=#2b4f86]%s[/bgcolor]" % line
			lines.append(line)
	_panel_text.text = "\n".join(lines)
	_refresh_title()

func _refresh_title() -> void:
	if _panel_title == null:
		return
	_panel_title.text = "Watching the agent" + ("  ·  %d more coming" % _queue.size() if _queue.size() > 0 else "")

## Clicking a log line: select the node and outline it (or, for a property
## change, open it in the Inspector and outline the property). The user
## asked for it, so changing selection is fine here — unlike the automatic
## outlines, which never do.
func _on_log_clicked(meta) -> void:
	var parts := str(meta).split(":")
	if parts[0] == "g" and parts.size() == 2:
		var gi := int(parts[1])
		if gi >= 0 and gi < _groups.size():
			_groups[gi].expanded = not _groups[gi].expanded
			_refresh_panel()
		return
	if parts[0] != "e" or parts.size() != 3:
		return
	var gi := int(parts[1])
	var ei := int(parts[2])
	if gi < 0 or gi >= _groups.size() or ei < 0 or ei >= (_groups[gi].entries as Array).size():
		return
	var entry: Dictionary = _groups[gi].entries[ei]
	if entry.has("script"):
		var lines: Array = entry.get("lines", [1, 1])
		_bridge._focus_script(str(entry.script), int(lines[0]), int(lines[-1]))
		return
	if not entry.has("node"):
		return
	var n = entry.node.get_ref()
	if not (n is Node) or not (n as Node).is_inside_tree():
		return
	var target := {"node_path": _bridge._rel_path(n), "timeout": 4}
	var prop := str(entry.get("property", ""))
	if prop != "":
		target["property"] = prop
	var res = await _bridge._cmd_highlight_editor_control(target)
	if typeof(res) == TYPE_DICTIONARY and res.has("__error__") and prop != "":
		# e.g. the property is hidden by a filter: fall back to the node.
		target.erase("property")
		await _bridge._cmd_highlight_editor_control(target)

## One beat's turn: its log line highlighted, plus outlines on the node's
## Scene dock row and (when it changed a property) that property in the
## Inspector. Without Follow, the property is only outlined if that node is
## already in the Inspector, so the user's view never changes.
func _show(beat: Dictionary) -> void:
	_beat_gen += 1
	var gen := _beat_gen
	_current_entry = _add_to_log(beat)
	_current = true
	_overlay.clear()
	# A running tour owns the outlines; Watch still logs.
	var runner: Node = _bridge._tour_runner if _bridge.get("_tour_runner") != null else null
	if runner != null and is_instance_valid(runner) and runner.is_running():
		return
	var n = beat.ref.get_ref() if beat.has("ref") else null
	if not (n is Node) or not (n as Node).is_inside_tree():
		return
	var node: Node = n
	var path: String = _bridge._rel_path(node)
	var prop := str(beat.get("property", ""))
	if prop != "" and (_follow() or EditorInterface.get_inspector().get_edited_object() == node):
		var pres: Dictionary = await _bridge._hl_resolve_target({"node_path": path, "property": prop}, false)
		if gen != _beat_gen or _beat_left <= 0.0:
			return
		if not pres.has("error") and pres.has("control"):
			_overlay.add_control(pres.control, "")
	var res: Dictionary = await _bridge._hl_resolve_target({"node_path": path}, false)
	if gen != _beat_gen or _beat_left <= 0.0:
		return
	if not res.has("error"):
		if res.has("tree"):
			_overlay.add_tree_item(res.tree, res.item_path, "")
		else:
			_overlay.add_control(res.control, "")

# ---- Log dock -------------------------------------------------------------
#
# A real editor dock ("Watch Log", lower-right slot by default), so it can be
# resized, moved to another dock slot, or floated as its own window — all
# Godot's own dock handling. Added when Watch first has something to show,
# removed when Watch is turned off.

func _ensure_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		return
	var scale := EditorInterface.get_editor_scale()  # sizes are pixels; HiDPI editors scale 2x
	_panel = VBoxContainer.new()
	_panel.name = "Watch Log"
	_panel.tooltip_text = "What the agent did, grouped by message, newest first. Click a line to point at that node or setting."
	_panel.custom_minimum_size = Vector2(240 * scale, 160 * scale)
	_panel_title = Label.new()
	_panel_title.text = "Watching the agent"
	_panel_title.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	_panel.add_child(_panel_title)
	_panel_text = RichTextLabel.new()
	_panel_text.bbcode_enabled = true
	# Fills the dock and scrolls (newest at the top).
	_panel_text.fit_content = false
	_panel_text.scroll_active = true
	_panel_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_text.add_theme_constant_override("line_separation", int(7 * scale))  # air between actions
	_panel_text.meta_underlined = false
	_panel_text.selection_enabled = true   # lines can be selected and copied; clicks still follow links
	_panel_text.meta_clicked.connect(_on_log_clicked)
	_panel.add_child(_panel_text)
	var plugin: EditorPlugin = _bridge._editor_plugin
	if plugin == null:
		return
	plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _panel)
	# Bring it to the front once, when it first appears; after that the
	# user decides which dock tab is showing.
	# (Godot 4.6+ wraps the control in an EditorDock: walk up to the tabs.)
	var tab: Node = _panel
	while tab != null and tab.get_parent() != null and not (tab.get_parent() is TabContainer):
		tab = tab.get_parent()
	if tab != null and tab.get_parent() is TabContainer:
		var tabs := tab.get_parent() as TabContainer
		tabs.current_tab = tabs.get_tab_idx_from_control(tab as Control)

func _remove_panel() -> void:
	if _panel == null or not is_instance_valid(_panel):
		_panel = null
		return
	var plugin: EditorPlugin = _bridge._editor_plugin if _bridge else null
	if plugin != null and _panel.get_parent() != null:
		plugin.remove_control_from_docks(_panel)
	_panel.queue_free()
	_panel = null
	_panel_title = null
	_panel_text = null

func _exit_tree() -> void:
	_overlay.clear()
	_remove_panel()

func _place_panel() -> void:
	pass  # docked: Godot places and sizes it

func _markdown(src: String) -> String:
	var out := src.replace("[", "[lb]")
	out = RegEx.create_from_string("\\*\\*(.+?)\\*\\*").sub(out, "[b]$1[/b]", true)
	out = RegEx.create_from_string("`(.+?)`").sub(out, "[code]$1[/code]", true)
	return out
