@tool
extends RefCounted
## The "Connect your AI app" UI: a first-run card at the top of the AI Assistant
## panel and the same controls as a section of its Settings popup. Nothing is
## written anywhere until the user confirms a dialog that shows exactly what
## goes where (the token is masked on screen). File writing is connect_clients.gd.

const Clients = preload("res://addons/godot_live_mcp/connect_clients.gd")

const META_DISMISSED := "connect_card_dismissed"
const META_SEEN := "connect_client_seen"

const MAIN_CLIENTS := [
	{"id": "claude", "label": "Claude Code"},
	{"id": "codex", "label": "Codex"},
	{"id": "vscode", "label": "VS Code"},
	{"id": "cursor", "label": "Cursor"},
]
const MORE_CLIENTS := [
	{"id": "opencode", "label": "opencode"},
	{"id": "gemini", "label": "Gemini CLI"},
]
const NOTES := {
	"claude": "Stored in ~/.claude.json against this project folder, not in your project, so nothing secret lands in version control. Start `claude` in this folder afterwards.",
	"codex": "Codex will ask before each tool call unless you approve this server in Codex's own settings. Start Codex afterwards.",
	"vscode": "The file holds no secret. VS Code asks for the token the first time it starts the server: use Copy token below and paste it when asked. Then start the server from MCP: List Servers.",
	"cursor": "Written to your Cursor user config, outside this project, readable only by you. Restart Cursor (or reload its MCP servers) afterwards.",
	"opencode": "Written to your opencode user config, outside this project, readable only by you.",
	"gemini": "Gemini ignores project servers in a folder it has not been told to trust: trust this folder when Gemini asks. The token is in a file inside the project; keep .gemini/ out of version control.",
}

var _panel: Control          # hosts dialogs; provides register_claude_local()
var _endpoint: Node
var _bridge: Node
var _clients := Clients.new()
var _card: PanelContainer
var _status_labels: Array = []
var _group_buttons: Array = []
var _notes: Array = []       # transient result lines, one label per UI copy
var _last_client := ""
var _was_seen_before := false


## Builds the card (inserted into `panel` right below its button row) and
## returns the controls for the Settings popup via build_section().
func setup(panel: Control, endpoint: Node, bridge: Node) -> void:
	_panel = panel
	_endpoint = endpoint
	_bridge = bridge
	_was_seen_before = bool(_meta(META_SEEN, false))
	_connect_core()
	_endpoint.availability_changed.connect(_on_availability_changed)
	_card = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.05)
	style.border_color = Color(1, 1, 1, 0.18)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	_card.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_card.add_child(box)
	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "Connect your AI app"
	title.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "Done"
	close.flat = true
	close.tooltip_text = "Hide this. The same controls stay in Settings (the cog)."
	close.pressed.connect(_dismiss)
	header.add_child(close)
	_build_controls(box, true)
	_panel.add_child(_card)
	_panel.move_child(_card, 1)
	_card.visible = _should_show_card()


## One button for the Settings popup that brings the card back (after "Done"),
## rather than a second copy of the controls: the popup is tall enough already.
func build_section(parent: Control) -> void:
	parent.add_child(HSeparator.new())
	var b := Button.new()
	b.text = "Connect your AI app…"
	b.tooltip_text = "Show the card with the Claude Code, Codex, VS Code and Cursor buttons again."
	b.pressed.connect(_show_card)
	parent.add_child(b)


func _show_card() -> void:
	_set_meta(META_DISMISSED, false)
	if _card:
		_card.visible = _url() != ""
	if _panel.get("_settings_popup") != null:
		_panel._settings_popup.hide()
	_refresh()


## The endpoint creates its core when it starts, which is after this UI is built.
func _connect_core() -> void:
	var core = _endpoint.get_core()
	if core != null and not core.client_seen.is_connected(_on_client_seen):
		core.client_seen.connect(_on_client_seen)


func _on_availability_changed() -> void:
	_connect_core()
	_refresh()


func _build_controls(parent: Control, with_intro: bool) -> void:
	if with_intro:
		var intro := Label.new()
		intro.text = "Pick your app. You confirm exactly what is written, and where."
		intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		intro.custom_minimum_size.x = 380
		parent.add_child(intro)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 4)
	parent.add_child(row)
	for c in MAIN_CLIENTS:
		var b := Button.new()
		b.text = c.label
		b.pressed.connect(_on_client_pressed.bind(c.id))
		row.add_child(b)
	var more := MenuButton.new()
	more.text = "More…"
	more.flat = false
	var menu := more.get_popup()
	for i in MORE_CLIENTS.size():
		menu.add_item(MORE_CLIENTS[i].label, i)
	menu.add_separator()
	menu.add_item("Copy config…", 100)
	menu.id_pressed.connect(func(id: int):
		if id == 100:
			_show_copy_config()
		else:
			_on_client_pressed(MORE_CLIENTS[id].id))
	row.add_child(more)

	var group := OptionButton.new()
	group.tooltip_text = "Lite is the set a newcomer needs. Full adds the rest (scripts that run arbitrary code, animation, audio, tours, the running game…).\nApplies to the next conversation in your AI app; apps that are already connected keep the list they have."
	group.item_selected.connect(_on_group_selected)
	row.add_child(group)
	_group_buttons.append(group)

	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 380
	parent.add_child(status)
	_status_labels.append(status)
	var note := Label.new()
	note.visible = false
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 380
	note.add_theme_color_override("font_color", Color(0.75, 0.77, 0.8))
	parent.add_child(note)
	_notes.append(note)
	_refresh()


# ---- state ------------------------------------------------------------------

func _url() -> String:
	return _endpoint.get_url() if _endpoint != null else ""


func _token() -> String:
	return _bridge.get_token() if _bridge != null else ""


func _project_dir() -> String:
	return ProjectSettings.globalize_path("res://")


func _project_name() -> String:
	return str(ProjectSettings.get_setting("application/config/name", "project"))


func _meta(key: String, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", key, default)


func _set_meta(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", key, value)


func _should_show_card() -> bool:
	return _url() != "" and not bool(_meta(META_DISMISSED, false)) and not _was_seen_before


func _dismiss() -> void:
	_set_meta(META_DISMISSED, true)
	if _card:
		_card.visible = false


func _on_client_seen(client_name: String, client_version: String) -> void:
	_last_client = "%s %s connected at %s" % [client_name, client_version, Time.get_time_string_from_system()]
	_set_meta(META_SEEN, true)
	_refresh()


func _refresh() -> void:
	var core = _endpoint.get_core() if _endpoint != null else null
	var url := _url()
	var text: String
	if url == "":
		text = "The editor's MCP endpoint is not running (it is switched off, or its port could not be opened; see the Output panel)."
	else:
		text = "Serving MCP at %s" % url
		if _last_client != "":
			text += " · ✓ " + _last_client
		else:
			text += " · no AI app has connected yet"
	for l in _status_labels:
		if is_instance_valid(l):
			(l as Label).text = text
	for g in _group_buttons:
		if not is_instance_valid(g):
			continue
		var opt := g as OptionButton
		opt.clear()
		if core != null:
			opt.add_item("Lite (%d tools)" % core.tool_count_for("lite"), 0)
			opt.add_item("Full (%d tools)" % core.tool_count_for("full"), 1)
			opt.selected = 1 if _endpoint.get_profile() == "full" else 0
		opt.disabled = core == null
	if _card:
		_card.visible = url != "" and (_card.visible or _should_show_card())


func _show_note(text: String) -> void:
	for n in _notes:
		if is_instance_valid(n):
			(n as Label).text = text
			(n as Label).visible = text != ""


func _on_group_selected(index: int) -> void:
	_endpoint.set_profile("full" if index == 1 else "lite")
	_show_note("Tool group set to %s. Your AI app sees it from its next conversation." % ("Full" if index == 1 else "Lite"))
	_refresh()


# ---- the confirm dialogs -------------------------------------------------------

func _on_client_pressed(client: String) -> void:
	if _url() == "":
		_show_note("The endpoint is not running, so there is nothing to connect to yet.")
		return
	if client == "claude":
		_confirm_claude()
	else:
		_confirm_file(client)


func _label_for(client: String) -> String:
	for c in MAIN_CLIENTS + MORE_CLIENTS:
		if c.id == client:
			return c.label
	return client


func _confirm_file(client: String) -> void:
	var t: Dictionary = _clients.target(client, _project_dir(), _project_name())
	var masked: String = _clients.snippet(client, _url(), _token(), _project_dir(), _project_name(), true)
	var existing := FileAccess.file_exists(t.path)
	var where := "inside this project" if not t.user_level else "outside this project (your user config)"
	var body := "%s %s\n%s" % ["Update" if existing else "Create", t.path, "(%s)" % where]
	if existing:
		body += "\nYour other servers and settings in it are kept, and a .bak copy of the file is made first."
	var d := _dialog("Connect %s" % _label_for(client), body, masked, "Write file")
	d.dialog.confirmed.connect(func():
		var r: Dictionary = _clients.configure(client, _url(), _token(), _project_dir(), _project_name())
		_show_note(("✓ " if r.ok else "✗ ") + r.message + ("\n" + NOTES[client] if r.ok else "")))
	_add_copy_button(d.dialog, "Copy config", _clients.snippet(client, _url(), _token(), _project_dir(), _project_name()))
	if client == "vscode":
		_add_copy_button(d.dialog, "Copy token", _token())
	d.dialog.popup_centered()


func _confirm_claude() -> void:
	var args: Array = _clients.claude_add_args(_url(), "<token>")
	var shown := "claude " + " ".join(PackedStringArray(args.map(func(a): return ("'%s'" % a) if str(a).contains(" ") else str(a))))
	var full := "claude " + " ".join(PackedStringArray(_clients.claude_add_args(_url(), _token()).map(func(a): return ("'%s'" % a) if str(a).contains(" ") else str(a))))
	var windows := OS.get_name() == "Windows"
	var body := "Register the editor with Claude Code for this project folder by running this in it:"
	if windows:
		body += "\n(The panel can't run it on Windows yet: use Copy command and run it in a terminal in this folder.)"
	var d := _dialog("Connect Claude Code", body, shown, "Register")
	d.dialog.get_ok_button().disabled = windows
	d.dialog.confirmed.connect(func():
		var r: Dictionary = _panel.register_claude_local()
		_show_note(("✓ " if r.ok else "✗ ") + r.message + ("\n" + NOTES.claude if r.ok else "")))
	_add_copy_button(d.dialog, "Copy command", full)
	d.dialog.popup_centered()


func _show_copy_config() -> void:
	if _url() == "":
		_show_note("The endpoint is not running, so there is no config to copy yet.")
		return
	var generic := JSON.stringify({"url": _url(), "headers": {"Authorization": "Bearer <token>"}}, "\t", false)
	var full := JSON.stringify({"url": _url(), "headers": {"Authorization": "Bearer " + _token()}}, "\t", false)
	var d := _dialog("Copy config",
		"For any app that takes a remote (URL) MCP server. Send the header with every request; the server only answers on this computer.",
		generic, "Close")
	d.dialog.get_cancel_button().visible = false
	_add_copy_button(d.dialog, "Copy config", full)
	_add_copy_button(d.dialog, "Copy URL", _url())
	_add_copy_button(d.dialog, "Copy token", _token())
	d.dialog.popup_centered()


## A ConfirmationDialog with a description, a read-only text area and an OK button.
func _dialog(title: String, body: String, text: String, ok_text: String) -> Dictionary:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.ok_button_text = ok_text
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	dialog.add_child(box)
	var label := Label.new()
	label.text = body
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 560
	box.add_child(label)
	var edit := TextEdit.new()
	edit.text = text
	edit.editable = false
	edit.custom_minimum_size = Vector2(560, 170)
	box.add_child(edit)
	var hint := Label.new()
	hint.text = "The token is hidden here; Copy puts the real one on your clipboard."
	hint.add_theme_color_override("font_color", Color(0.75, 0.77, 0.8))
	box.add_child(hint)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	_panel.add_child(dialog)
	return {"dialog": dialog}


func _add_copy_button(dialog: ConfirmationDialog, label: String, text: String) -> void:
	var b := dialog.add_button(label, false, "copy_" + label)
	b.pressed.connect(func(): DisplayServer.clipboard_set(text))
