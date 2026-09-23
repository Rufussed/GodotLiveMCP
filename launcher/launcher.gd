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
var _add_button: Button
var _refresh_button: Button
var _project_list: VBoxContainer
var _log: RichTextLabel
var _folder_dialog: FileDialog
var _force_dialog: ConfirmationDialog

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

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	root.add_child(buttons)

	_install_button = Button.new()
	_install_button.text = "Install / rebuild server"
	_install_button.pressed.connect(_on_install_pressed)
	buttons.add_child(_install_button)

	_add_button = Button.new()
	_add_button.text = "Add Godot project…"
	_add_button.pressed.connect(func(): _folder_dialog.popup_centered_ratio(0.7))
	buttons.add_child(_add_button)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.pressed.connect(_refresh)
	buttons.add_child(_refresh_button)

	var projects_title := Label.new()
	projects_title.text = "Projects"
	root.add_child(projects_title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
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
		_check_line("Server built", "yes" if _server_built else "", "click \"Install / rebuild server\""),
	]
	_status_label.text = "\n".join(lines)
	_update_controls()

func _update_controls() -> void:
	_install_button.disabled = not _has_npm or _busy()
	_add_button.disabled = not _server_built or _busy()
	_add_button.tooltip_text = "" if _server_built else "Build the server first."
	_refresh_button.disabled = _busy()
	_rebuild_project_list()

func _check_line(label: String, value: String, hint: String) -> String:
	if value.is_empty():
		return "[color=#e06c6c]✘ %s[/color] — %s" % [label, hint]
	return "[color=#7ec07e]✔ %s[/color]  %s" % [label, value]

func _rebuild_project_list() -> void:
	for c in _project_list.get_children():
		c.queue_free()
	if _projects.is_empty():
		var empty := Label.new()
		empty.text = "No projects yet — click \"Add Godot project…\"."
		empty.modulate = Color(1, 1, 1, 0.6)
		_project_list.add_child(empty)
		return
	for path in _projects:
		_project_list.add_child(_make_project_row(path))

func _make_project_row(path: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var state := _link_state(path)
	var state_label := Label.new()
	state_label.custom_minimum_size = Vector2(110, 0)
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
	row.add_child(state_label)

	var path_label := Label.new()
	path_label.text = path
	path_label.tooltip_text = path
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(path_label)

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
	row.add_child(remove)
	return row

func _log_line(bbcode: String) -> void:
	_log.append_text(bbcode + "\n")

func _log_plain(text: String) -> void:
	_log.append_text(text.replace("[", "[lb]") + "\n")

# ---- Actions ----

func _on_install_pressed() -> void:
	_run_async("npm", ["install", "--prefix", _server_dir], func(code: int):
		_log_line("[color=#7ec07e]Server installed and built.[/color]" if code == 0
			else "[color=#e06c6c]npm install failed (exit %d) — see output above.[/color]" % code)
		_refresh()
	)

func _on_folder_selected(path: String) -> void:
	path = path.simplify_path()
	if not FileAccess.file_exists(path.path_join("project.godot")):
		_log_line("[color=#e06c6c]No project.godot in %s — pick the folder that contains it.[/color]" % path.replace("[", "[lb]"))
		return
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
	# OS.get_executable_path() is the Godot binary running this launcher, so
	# the project opens in the same Godot version.
	OS.create_process(OS.get_executable_path(), ["--editor", "--path", path])

func _remember_project(path: String) -> void:
	if not _projects.has(path):
		_projects.append(path)
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
