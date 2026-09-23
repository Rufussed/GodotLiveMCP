extends Control

## Setup GUI for GodotLiveMCP: checks prerequisites, runs the server's
## `npm install`, and links Godot projects picked with a folder browser.
## Linking always goes through server/scripts/link-project.js (via
## `npm run link-project`), so this app only runs npm commands and shows
## their output — the actual logic lives in one place.

const CONFIG_PATH := "user://launcher.cfg"

var _repo_root: String
var _server_dir: String
var _addon_dir: String

var _status_label: RichTextLabel
var _install_button: Button
var _new_button: Button
var _add_button: Button
var _refresh_button: Button
var _project_list: VBoxContainer
var _server_state: Label
var _step2: Control
var _step3: Control
var _open_last_button: Button
var _log: RichTextLabel
var _folder_dialog: FileDialog
var _force_dialog: ConfirmationDialog
var _new_dialog: ConfirmationDialog
var _new_name: LineEdit
var _new_dest: LineEdit
var _dest_dialog: FileDialog

var _projects: PackedStringArray = []
var _pending_force_path := ""

# The one command allowed to run at a time.
var _proc: Dictionary = {}
var _proc_partial := {"stdio": "", "stderr": ""}
var _on_proc_done: Callable

func _ready() -> void:
	_repo_root = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	_server_dir = _repo_root.path_join("server")
	_addon_dir = _repo_root.path_join("addon/godot_live_mcp")
	_build_ui()
	_load_projects()
	_refresh()

func _process(_delta: float) -> void:
	_poll_proc()

# ---- UI ----

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title := Label.new()
	title.text = "GodotLiveMCP Launcher"
	title.add_theme_font_size_override("font_size", 22)
	root.add_child(title)

	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	root.add_child(_status_label)

	root.add_child(_step_title("Step 1 — Install the MCP server"))
	var server_row := HBoxContainer.new()
	server_row.add_theme_constant_override("separation", 8)
	root.add_child(server_row)

	_install_button = Button.new()
	_install_button.text = "Install / rebuild MCP server"
	_install_button.pressed.connect(_on_install_pressed)
	server_row.add_child(_install_button)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.pressed.connect(_refresh)
	server_row.add_child(_refresh_button)

	_server_state = Label.new()
	server_row.add_child(_server_state)

	# Step 2 appears once the server is built; step 3 once a project is added.
	var step2 := VBoxContainer.new()
	step2.add_theme_constant_override("separation", 10)
	root.add_child(step2)
	_step2 = step2
	step2.add_child(_step_title("Step 2 — Create or add a Godot project"))
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	step2.add_child(buttons)

	_new_button = Button.new()
	_new_button.text = "Create new Godot project…"
	_new_button.pressed.connect(_on_new_pressed)
	buttons.add_child(_new_button)

	_add_button = Button.new()
	_add_button.text = "Add existing Godot project…"
	_add_button.pressed.connect(func(): _folder_dialog.popup_centered_ratio(0.7))
	buttons.add_child(_add_button)

	var step3 := VBoxContainer.new()
	step3.add_theme_constant_override("separation", 10)
	root.add_child(step3)
	_step3 = step3
	step3.add_child(_step_title("Step 3 — Your projects"))

	# The most recently created, added or opened project is first in the list.
	var open_last_row := HBoxContainer.new()
	step3.add_child(open_last_row)
	_open_last_button = Button.new()
	_open_last_button.add_theme_font_size_override("font_size", 16)
	_open_last_button.pressed.connect(func(): _open_in_godot(_projects[0]))
	open_last_row.add_child(_open_last_button)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	step3.add_child(scroll)
	_project_list = VBoxContainer.new()
	_project_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_project_list)

	var log_title := Label.new()
	log_title.text = "Output"
	root.add_child(log_title)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Secondary to the controls above, so dimmer than the interface text.
	_log.add_theme_color_override("default_color", Color(0.62, 0.62, 0.66))
	_log.add_theme_font_size_override("normal_font_size", 13)
	root.add_child(_log)

	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.use_native_dialog = true
	_folder_dialog.title = "Select a Godot project folder (the one containing project.godot)"
	_folder_dialog.dir_selected.connect(_on_folder_selected)
	add_child(_folder_dialog)

	_force_dialog = ConfirmationDialog.new()
	_force_dialog.ok_button_text = "Replace with link"
	_force_dialog.confirmed.connect(func(): _link(_pending_force_path, true))
	add_child(_force_dialog)

	_build_new_dialog()

func _build_new_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New Godot project"
	_new_dialog.ok_button_text = "Create and link"
	_new_dialog.confirmed.connect(_on_new_confirmed)
	add_child(_new_dialog)

	var form := GridContainer.new()
	form.columns = 2
	form.custom_minimum_size = Vector2(480, 0)
	form.add_theme_constant_override("h_separation", 8)
	form.add_theme_constant_override("v_separation", 8)
	_new_dialog.add_child(form)

	var name_label := Label.new()
	name_label.text = "Name"
	form.add_child(name_label)
	_new_name = LineEdit.new()
	_new_name.placeholder_text = "My Game"
	_new_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_name.text_changed.connect(func(_t): _validate_new())
	form.add_child(_new_name)

	var dest_label := Label.new()
	dest_label.text = "Destination"
	form.add_child(dest_label)
	var dest_row := HBoxContainer.new()
	dest_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(dest_row)
	_new_dest = LineEdit.new()
	_new_dest.placeholder_text = "Folder the project folder is created in"
	_new_dest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_dest.text_changed.connect(func(_t): _validate_new())
	dest_row.add_child(_new_dest)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(func(): _dest_dialog.popup_centered_ratio(0.7))
	dest_row.add_child(browse)

	_dest_dialog = FileDialog.new()
	_dest_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dest_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dest_dialog.use_native_dialog = true
	_dest_dialog.title = "Choose where to create the project"
	_dest_dialog.dir_selected.connect(func(dir: String):
		_new_dest.text = dir.simplify_path()
		_validate_new()
	)
	add_child(_dest_dialog)

var _has_npm := false
var _server_built := false

## Re-checks prerequisites (spawns node/npm/claude, so only on demand).
func _refresh() -> void:
	var node := _version_of("node")
	var npm := _version_of("npm")
	var claude := _version_of("claude")
	_has_npm = not npm.is_empty()
	_server_built = FileAccess.file_exists(_server_dir.path_join("build/index.js"))
	var lines := [
		_check_line("Node.js", node, "install from https://nodejs.org"),
		_check_line("npm", npm, "comes with Node.js"),
		_check_line("Claude Code CLI", claude, "see https://docs.claude.com/en/docs/claude-code"),
	]
	_status_label.text = "\n".join(lines)
	_update_controls()

func _update_controls() -> void:
	_install_button.disabled = not _has_npm or _busy()
	_install_button.tooltip_text = "" if _has_npm else "Install Node.js first."
	if _busy():
		_server_state.text = "Working…"
		_server_state.modulate = Color(1, 1, 1, 0.6)
	elif _server_built:
		_server_state.text = "✔ MCP server installed"
		_server_state.modulate = Color(0.5, 0.85, 0.5)
	else:
		_server_state.text = "Not installed yet"
		_server_state.modulate = Color(1, 1, 1, 0.6)
	for b in [_new_button, _add_button]:
		b.disabled = _busy()
	_refresh_button.disabled = _busy()
	_step2.visible = _server_built
	_step3.visible = _server_built and not _projects.is_empty()
	if not _projects.is_empty():
		var last := _projects[0]
		_open_last_button.text = "Open %s in Godot" % last.get_file()
		_open_last_button.tooltip_text = last
		_open_last_button.disabled = _link_state(last) == "missing_project"
	_rebuild_project_list()

func _step_title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	return l

func _check_line(label: String, value: String, hint: String) -> String:
	if value.is_empty():
		return "[color=#e06c6c]✘ %s[/color] — %s" % [label, hint]
	return "[color=#7ec07e]✔ %s[/color]  %s" % [label, value]

func _rebuild_project_list() -> void:
	for c in _project_list.get_children():
		c.queue_free()
	if _projects.is_empty():
		var empty := Label.new()
		empty.text = "No projects yet — create a new project or open an existing one."
		empty.modulate = Color(1, 1, 1, 0.6)
		_project_list.add_child(empty)
		return
	for path in _projects:
		_project_list.add_child(_make_project_row(path))

func _make_project_row(path: String) -> Control:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 4)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	card.add_child(header)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 6)

	var state := _link_state(path)
	var state_label := Label.new()
	state_label.custom_minimum_size = Vector2(90, 0)
	match state:
		"linked":
			state_label.text = "✔ linked"
			state_label.modulate = Color(0.5, 0.85, 0.5)
		"copy":
			state_label.text = "old copy"
			state_label.modulate = Color(0.95, 0.8, 0.4)
		"missing_project":
			state_label.text = "folder missing"
			state_label.modulate = Color(0.9, 0.45, 0.45)
		_:
			state_label.text = "not linked"
			state_label.modulate = Color(0.9, 0.45, 0.45)
	header.add_child(state_label)

	var path_label := Label.new()
	path_label.text = path
	path_label.tooltip_text = path
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(path_label)
	card.add_child(row)

	if state != "missing_project":
		var open := Button.new()
		open.text = "Open in Godot"
		open.pressed.connect(_open_in_godot.bind(path))
		row.add_child(open)

	if state == "linked":
		var unlink := Button.new()
		unlink.text = "Unlink"
		unlink.disabled = _busy()
		unlink.pressed.connect(_unlink.bind(path))
		row.add_child(unlink)
	elif state != "missing_project":
		var relink := Button.new()
		relink.text = "Link"
		relink.disabled = _busy()
		relink.pressed.connect(_link.bind(path, false))
		row.add_child(relink)

	var remove := Button.new()
	remove.text = "✕"
	remove.tooltip_text = "Remove from this list (doesn't change the project)"
	remove.pressed.connect(_forget_project.bind(path))
	header.add_child(remove)
	card.add_child(HSeparator.new())
	return card

func _log_line(bbcode: String) -> void:
	_log.append_text(bbcode + "\n")

func _log_plain(text: String) -> void:
	_log.append_text(text.replace("[", "[lb]") + "\n")

# ---- Actions ----

func _on_install_pressed() -> void:
	_build_server(func(): pass)

## Runs the server's `npm install` (which also builds it), then `then` on success.
func _build_server(then: Callable) -> void:
	_run_async("npm", ["install", "--prefix", _server_dir], func(code: int):
		_log_line("[color=#7ec07e]Server installed and built.[/color]" if code == 0
			else "[color=#e06c6c]npm install failed (exit %d) — see output above.[/color]" % code)
		_refresh()
		if code == 0:
			then.call()
	)

func _on_folder_selected(path: String) -> void:
	path = path.simplify_path()
	if not FileAccess.file_exists(path.path_join("project.godot")):
		_log_line("[color=#e06c6c]No project.godot in %s — pick the folder that contains it.[/color]" % path.replace("[", "[lb]"))
		return
	_link(path, false)

func _on_new_pressed() -> void:
	_new_name.text = ""
	if _new_dest.text.is_empty():
		_new_dest.text = _repo_root.get_base_dir()
	_validate_new()
	_new_dialog.popup_centered()
	_new_name.grab_focus()

func _new_project_path() -> String:
	return _new_dest.text.strip_edges().path_join(_new_name.text.strip_edges())

func _validate_new() -> void:
	var name := _new_name.text.strip_edges()
	var dest := _new_dest.text.strip_edges()
	var ok := not name.is_empty() and name.is_valid_filename() \
		and DirAccess.dir_exists_absolute(dest) \
		and not DirAccess.dir_exists_absolute(_new_project_path())
	_new_dialog.get_ok_button().disabled = not ok

func _on_new_confirmed() -> void:
	var name := _new_name.text.strip_edges()
	var path := _new_project_path().simplify_path()
	if DirAccess.make_dir_recursive_absolute(path) != OK:
		_log_line("[color=#e06c6c]Couldn't create %s.[/color]" % path.replace("[", "[lb]"))
		return
	var f := FileAccess.open(path.path_join("project.godot"), FileAccess.WRITE)
	if f == null:
		_log_line("[color=#e06c6c]Couldn't write project.godot in %s.[/color]" % path.replace("[", "[lb]"))
		return
	var v := Engine.get_version_info()
	f.store_string((
		"config_version=5\n\n[application]\n\nconfig/name=\"%s\"\n" +
		"config/features=PackedStringArray(\"%d.%d\", \"Forward Plus\")\n"
	) % [name.c_escape(), v.major, v.minor])
	f.close()
	_log_line("[color=#7ec07e]Created project %s.[/color]" % path.replace("[", "[lb]"))
	_link(path, false)

func _link(path: String, force: bool) -> void:
	var args := ["run", "link-project", "--prefix", _server_dir, "--", path]
	if force:
		args.append("--force")
	_run_async("npm", args, func(code: int):
		if code == 0:
			_remember_project(path)
		elif code == 2:
			_pending_force_path = path
			_force_dialog.dialog_text = (
				"%s already has a copied GodotLiveMCP addon (an older install).\n\n" +
				"Replace it with a link to this repo? The copied folder will be deleted."
			) % path
			_force_dialog.popup_centered()
		_update_controls()
	)

func _unlink(path: String) -> void:
	_run_async("npm", ["run", "link-project", "--prefix", _server_dir, "--", path, "--unlink"], func(_code: int):
		_update_controls()
	)

func _open_in_godot(path: String) -> void:
	_remember_project(path)
	# OS.get_executable_path() is the Godot binary running this launcher, so
	# the project opens in the same Godot version.
	if OS.create_process(OS.get_executable_path(), ["--editor", "--path", path]) == -1:
		_log_line("[color=#e06c6c]Couldn't start Godot for %s.[/color]" % path.replace("[", "[lb]"))
		return
	get_tree().quit()

## Adds `path` (or moves it) to the front, so it's the "last touched" project.
func _remember_project(path: String) -> void:
	var i := _projects.find(path)
	if i != -1:
		_projects.remove_at(i)
	_projects.insert(0, path)
	_save_projects()

func _forget_project(path: String) -> void:
	var i := _projects.find(path)
	if i != -1:
		_projects.remove_at(i)
		_save_projects()
	_update_controls()

# ---- Project state ----

## "linked" (points at this repo's addon), "copy" (a real folder — an older
## copied install), "other" (missing, or a link to somewhere else), or
## "missing_project" (the project folder itself is gone).
func _link_state(path: String) -> String:
	if not FileAccess.file_exists(path.path_join("project.godot")):
		return "missing_project"
	var da := DirAccess.open(path.path_join("addons"))
	if da == null:
		return "other"
	if da.is_link("godot_live_mcp"):
		var target := da.read_link("godot_live_mcp")
		if target.is_relative_path():
			target = path.path_join("addons").path_join(target)
		return "linked" if target.simplify_path() == _addon_dir else "other"
	if da.dir_exists("godot_live_mcp"):
		return "copy"
	return "other"

func _load_projects() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		_projects = cfg.get_value("launcher", "projects", PackedStringArray())

func _save_projects() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("launcher", "projects", _projects)
	cfg.save(CONFIG_PATH)

# ---- Running commands ----

## npm/claude are .cmd shims on Windows, so they need cmd.exe. Elsewhere a
## login shell is used so tools installed via version managers (nvm, mise,
## ...) are on PATH even when Godot was started from a desktop launcher.
func _wrap(cmd: String, args: Array) -> Array:
	if OS.get_name() == "Windows":
		return ["cmd.exe", ["/c", cmd] + args]
	var parts := [cmd]
	for a in args:
		parts.append(_shell_quote(String(a)))
	return ["bash", ["-lc", " ".join(parts)]]

func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

func _version_of(cmd: String) -> String:
	var w := _wrap(cmd, ["--version"])
	var output: Array = []
	if OS.execute(w[0], w[1], output, true) != 0 or output.is_empty():
		return ""
	return String(output[0]).strip_edges().split("\n")[0]

func _busy() -> bool:
	return not _proc.is_empty()

func _run_async(cmd: String, args: Array, on_done: Callable) -> void:
	if _busy():
		_log_line("[color=#e06c6c]Another command is still running.[/color]")
		return
	_log_plain("$ %s %s" % [cmd, " ".join(args)])
	var w := _wrap(cmd, args)
	_proc = OS.execute_with_pipe(w[0], w[1], false)
	if _proc.is_empty():
		_log_line("[color=#e06c6c]Couldn't start %s.[/color]" % cmd)
		return
	_proc_partial = {"stdio": "", "stderr": ""}
	_on_proc_done = on_done
	_update_controls()

func _poll_proc() -> void:
	if _proc.is_empty():
		return
	var running := OS.is_process_running(_proc.pid)
	_drain("stdio")
	_drain("stderr")
	if running:
		return
	for key in ["stdio", "stderr"]:
		if not _proc_partial[key].is_empty():
			_log_plain(_proc_partial[key])
		var pipe: FileAccess = _proc.get(key)
		if pipe:
			pipe.close()
	var code := OS.get_process_exit_code(_proc.pid)
	_proc = {}
	_on_proc_done.call(code)

## Pipes are non-blocking and not line-atomic, so partial lines are held
## until their newline arrives.
func _drain(key: String) -> void:
	var pipe: FileAccess = _proc.get(key)
	if pipe == null:
		return
	while true:
		var chunk := pipe.get_buffer(4096)
		if chunk.is_empty():
			break
		_proc_partial[key] += chunk.get_string_from_utf8()
	var lines: PackedStringArray = _proc_partial[key].split("\n")
	_proc_partial[key] = lines[lines.size() - 1]
	for i in lines.size() - 1:
		_log_plain(lines[i].strip_edges(false, true))
