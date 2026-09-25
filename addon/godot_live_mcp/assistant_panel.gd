@tool
extends VBoxContainer

## Bottom-panel tab: "AI Assistant". Two independent on-ramps, offered
## together rather than as a mode switch (per PLUGIN_OUTPUT_PANEL_PLAN.md
## Phase 1): an external-terminal launcher (Phase 1a, the native TUI, no
## parsing needed) and an in-editor structured session (this addition) that
## drives `claude` via stream-json and renders it as native Godot UI
## instead of a terminal emulation. Both can run at once; they're separate
## subprocesses with no shared state.

## Terminal launchers tried in order. "style" controls both how the target
## command is appended and whether a native workdir flag exists:
##   "xdg"    - xdg-terminal-exec: command appended directly, has --dir
##              (checked first: it's the portal-compliant "ask the desktop
##              which terminal to use" launcher, confirmed present on this
##              machine via $TERMINAL during live testing 2026-09-22 — a
##              flag-style entry like the others below would have silently
##              passed it an unsupported "-e" and failed).
##   "direct" - command appended directly, no flag (kitty, foot)
##   "flag_e" - needs "-e" before the command (alacritty, ghostty, konsole,
##              xfce4-terminal, xterm)
##   "dashdash" - needs "--" before the command (gnome-terminal)
const _TERMINALS := [
	{"bin": "xdg-terminal-exec", "style": "xdg"},
	{"bin": "kitty", "style": "direct"},
	{"bin": "foot", "style": "direct"},
	{"bin": "alacritty", "style": "flag_e"},
	{"bin": "ghostty", "style": "flag_e"},
	{"bin": "gnome-terminal", "style": "dashdash"},
	{"bin": "konsole", "style": "flag_e"},
	{"bin": "xfce4-terminal", "style": "flag_e"},
	{"bin": "xterm", "style": "flag_e"},
]

var _launch_button: Button
var _codex_button: Button
var _new_session_button: Button
var _settings_button: Button
var _settings_popup: PopupPanel
var _sync_check: CheckBox
var _tests_check: CheckBox
var _save_check: CheckBox
var _assistant_option: OptionButton
var _model_option: OptionButton
var _effort_option: OptionButton
# Codex in the panel runs one `codex exec --json` process per message and
# resumes the same thread for the next one; this is that thread's id.
var _codex_thread_id := ""
var _session_kind := "claude"  # which CLI the running _pipe belongs to
# Token totals for the current conversation, shown after each turn.
var _tokens_in := 0
var _tokens_out := 0

# Permission toggles (in-editor session only — these configure the flags
# `claude` launches with, so they only take effect at Start; there is no
# live "change a running session's permissions" protocol, hence disabling
# them once a session is active rather than pretending they still do
# something).
var _file_control_toggle: Button
var _terminal_toggle: Button
var _web_toggle: Button

# In-editor session state
var _transcript: RichTextLabel
var _input_field: TextEdit
var _send_button: Button
var _stop_button: Button
var _pipe: Dictionary = {}       # result of OS.execute_with_pipe while a session is active
var _read_buffer: String = ""    # accumulates partial reads until a full "\n"-terminated line exists
var _session_active: bool = false

func _compact_button_padding(b: Button) -> void:
	for state in [&"normal", &"hover", &"disabled", &"focus", &"pressed", &"hover_pressed"]:
		var style := b.get_theme_stylebox(state)
		if style == null:
			continue
		var compact: StyleBox = style.duplicate()
		compact.content_margin_top = 0
		compact.content_margin_bottom = 0
		b.add_theme_stylebox_override(state, compact)
	# Re-stash the now-compacted "pressed" style so _set_toggle_disabled
	# applies the shrunk version, not the original taller one from before
	# this function ran — otherwise a toggle disabled while on would jump
	# back to the old height instead of staying compact.
	if b.has_meta("green_style"):
		b.set_meta("green_style", b.get_theme_stylebox("pressed"))
	# Same problem the other way: _set_toggle_disabled's re-enable path
	# used to call remove_theme_stylebox_override("disabled"), which falls
	# back to Godot's ORIGINAL uncompacted default (6px margin), not this
	# function's compacted one — and Button.get_minimum_size() factors in
	# the disabled stylebox's size even while the button is enabled, so
	# that alone was enough to make the whole button look tall again.
	# Confirmed live: this is exactly what my own toggle-disable test hit.
	# Stash the compacted grey version too so re-enabling can restore it
	# instead of discarding the override outright.
	b.set_meta("default_disabled_style", b.get_theme_stylebox("disabled"))

func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 6)
	add_child(button_row)

	# "Clawd" — Claude Code's own mascot, from the official VS Code
	# extension's bundled assets (resources/clawd.svg), copied in rather
	# than referenced from the extension install so this doesn't depend on
	# VS Code being installed. Native aspect ratio 47:38.
	var icon := TextureRect.new()
	icon.texture = load("res://addons/godot_live_mcp/icons/claude.svg")
	icon.custom_minimum_size = Vector2(25, 20)
	# TextureRect defaults to expand_mode EXPAND_KEEP_SIZE, which ignores
	# custom_minimum_size for shrinking and reports the texture's native
	# pixel size (47x38) as its own minimum regardless — confirmed live:
	# this alone was forcing the whole button row to stay 38px tall even
	# after every button's own minimum was correctly compacted to 21px.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button_row.add_child(icon)

	var permissions_label := Label.new()
	permissions_label.text = "Permissions:"
	button_row.add_child(permissions_label)

	# Godot control itself (mcp__godot-live-mcp__*) is always granted, not a
	# toggle — it's the entire point of this panel, and it's the thing this
	# project has spent its effort hardening for safety (see the
	# _apply_properties fix and this tool set's own validation). These three
	# are the genuinely optional, broader grants, each mapped to a real
	# --allowedTools group — confirmed live before wiring up: --allowedTools
	# is ADDITIVE (a real risk if left too broad by default — a disallowed
	# Bash command was confirmed to still run unless explicitly excluded via
	# --permission-prompts none), and --permission-prompts none was confirmed
	# to cleanly deny anything not explicitly granted here, rather than
	# hanging (there is no prompt-answering UI in this panel) or silently
	# allowing it. Same toggle state is used for both the in-editor session
	# and the external-terminal launch below, so "granted" means the same
	# thing regardless of which one you use.
	_file_control_toggle = _make_permission_toggle("File Control", button_row)
	_terminal_toggle = _make_permission_toggle("Terminal Commands", button_row)
	_web_toggle = _make_permission_toggle("Web Access", button_row)

	button_row.add_child(VSeparator.new())

	_launch_button = Button.new()
	_launch_button.text = "Open Claude"
	_launch_button.pressed.connect(_on_launch_pressed)
	button_row.add_child(_launch_button)
	_compact_button_padding(_launch_button)

	_codex_button = Button.new()
	_codex_button.text = "Open Codex"
	_codex_button.pressed.connect(_on_launch_codex_pressed)
	button_row.add_child(_codex_button)
	_compact_button_padding(_codex_button)

	var editor_theme := EditorInterface.get_editor_theme()
	_new_session_button = Button.new()
	_new_session_button.icon = editor_theme.get_icon("Reload", "EditorIcons")
	_new_session_button.tooltip_text = "New session: end the current conversation; your next message starts a fresh one (and picks up a rebuilt MCP server)."
	_new_session_button.flat = true
	_new_session_button.pressed.connect(_on_new_session_pressed)
	button_row.add_child(_new_session_button)

	_settings_button = Button.new()
	_settings_button.icon = editor_theme.get_icon("Tools", "EditorIcons")
	_settings_button.tooltip_text = "Settings"
	_settings_button.flat = true
	_settings_button.pressed.connect(_on_settings_pressed)
	button_row.add_child(_settings_button)
	_build_settings_popup()

	# Distribute the interactive buttons across the row's full width —
	# icon/label/separator stay their natural size, only the buttons
	# (toggles + terminal launcher) expand and share the leftover space.
	for b in [_file_control_toggle, _terminal_toggle, _web_toggle, _launch_button, _codex_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_build_session_ui()

	_refresh_status()
	# Deferred so the editor finishes loading first; a no-op unless the
	# server path or token changed since the last registration.
	call_deferred("_ensure_local_registration")
	call_deferred("_keep_panel_open_on_play")

## Godot switches the bottom panel to Output on every Play by default, which
## hides this chat mid-conversation. Once per editor install, if that
## setting is still the default, switch it to "Do Nothing" and say so. A
## marker setting records it, so a user who turns it back on keeps it.
func _keep_panel_open_on_play() -> void:
	var es := EditorInterface.get_editor_settings()
	const MARKER := "godot_live_mcp/adjusted_action_on_play"
	const SETTING := "run/bottom_panel/action_on_play"
	if es.has_setting(MARKER) or not es.has_setting(SETTING):
		return
	es.set_setting(MARKER, true)
	if int(es.get_setting(SETTING)) == 1:  # "Open Output", Godot's default
		es.set_setting(SETTING, 0)  # "Do Nothing"
		_append_transcript("[i]Set Editor Settings > Run > Bottom Panel > Action On Play to \"Do Nothing\", so pressing Play keeps this chat open. Change it back there if you prefer the Output tab.[/i]")

func _process(_delta: float) -> void:
	_poll_session()

func _refresh_status() -> void:
	var term := _find_terminal()
	for pair in [[_launch_button, "claude", "Claude Code", "https://docs.claude.com/en/docs/claude-code"],
			[_codex_button, "codex", "Codex", "https://github.com/openai/codex"]]:
		var button: Button = pair[0]
		button.disabled = true
		if not _has_command(pair[1]):
			button.tooltip_text = "%s CLI (`%s`) not found on PATH. Install it first: %s — then reopen this panel." % [pair[2], pair[1], pair[3]]
		elif term.is_empty() and OS.get_name() != "Windows":
			button.tooltip_text = (
				"%s found, but no supported terminal emulator was detected on PATH (tried " +
				"$TERMINAL, alacritty, kitty, foot, ghostty, gnome-terminal, konsole, xfce4-terminal, xterm)."
			) % pair[2]
		else:
			button.disabled = false
			button.tooltip_text = "Opens a %s session in %s, in this project's directory." % [
				pair[2], "a console" if term.is_empty() else term.bin]

func _build_allowed_tools() -> Array:
	var allowed := ["mcp__godot-live-mcp__*"]
	if _file_control_toggle.button_pressed:
		allowed.append_array(["Read", "Write", "Edit"])
	if _terminal_toggle.button_pressed:
		allowed.append("Bash")
	if _web_toggle.button_pressed:
		allowed.append_array(["WebFetch", "WebSearch"])
	return allowed

func _on_launch_pressed() -> void:
	# --mcp-config is variadic, so it goes last.
	_launch_in_terminal("claude", _model_args("claude") + _behavior_args() + _mcp_config_args(func(msg): _append_transcript("[color=yellow]%s[/color]" % msg)))

## Codex reads AGENTS.md (linked to CLAUDE.md by link-project) and takes the
## same server + project token and the settings popup's preferences through
## -c config overrides (values are TOML; JSON-quoted strings are valid TOML).
func _on_launch_codex_pressed() -> void:
	var args := _model_args("codex") + ["-c", "developer_instructions=" + JSON.stringify(_behavior_text())]
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if not entry.is_empty() and not token.is_empty():
		args += [
			"-c", 'mcp_servers.godot-live-mcp.command="node"',
			"-c", "mcp_servers.godot-live-mcp.args=[%s]" % JSON.stringify(entry),
			"-c", "mcp_servers.godot-live-mcp.env.GODOT_LIVE_MCP_TOKEN=%s" % JSON.stringify(token),
		]
	else:
		_append_transcript("[color=yellow]Couldn't find this project's server/token — Codex will use its own godot-live-mcp registration, if any.[/color]")
	# Godot control is always granted in this panel (like Claude's
	# mcp__godot-live-mcp__*); without this Codex asks per MCP tool call.
	args += ["-c", 'mcp_servers.godot-live-mcp.default_tools_approval_mode="approve"']
	_launch_in_terminal("codex", args)

func _launch_in_terminal(cli: String, cli_args: Array) -> void:
	var project_dir := ProjectSettings.globalize_path("res://")

	if OS.get_name() == "Windows":
		# OS.create_process's open_console is a real native console window
		# on Windows; no terminal-emulator detection needed there.
		OS.create_process(cli, cli_args, true)
		return

	var term := _find_terminal()
	if term.is_empty():
		_refresh_status()  # re-check in case something changed since panel opened
		return

	var shell_cmd := "cd %s && %s" % [_shell_quote(project_dir), cli]
	for arg in cli_args:
		shell_cmd += " " + _shell_quote(arg)

	match term.style:
		"xdg":
			OS.create_process(term.bin, ["--dir=%s" % project_dir, "--", cli] + cli_args)
		"direct":
			# No native workdir flag — same shell `cd` fallback as flag_e/
			# dashdash below, just without a leading terminal-specific flag.
			OS.create_process(term.bin, ["bash", "-lc", shell_cmd])
		"flag_e":
			OS.create_process(term.bin, ["-e", "bash", "-lc", shell_cmd])
		"dashdash":
			OS.create_process(term.bin, ["--", "bash", "-lc", shell_cmd])

func _find_terminal() -> Dictionary:
	var env_term := OS.get_environment("TERMINAL")
	if not env_term.is_empty() and _has_command(env_term):
		for t in _TERMINALS:
			if t.bin == env_term:
				return t
		# $TERMINAL set to something not in our known-style list — best
		# effort, assume it accepts a bare command the way most do.
		return {"bin": env_term, "style": "direct"}
	for t in _TERMINALS:
		if _has_command(t.bin):
			return t
	return {}

func _has_command(bin_name: String) -> bool:
	if bin_name.is_empty():
		return false
	var output: Array = []
	var code := OS.execute("which", [bin_name], output)
	return code == 0 and not output.is_empty() and not String(output[0]).strip_edges().is_empty()

## Finds the built MCP server. The preferred install links
## res://addons/godot_live_mcp to the cloned repo (server/scripts/
## link-project.js), so resolving that link leads back to the repo's
## server/build/index.js with no configuration. Falls back to a copy bundled
## inside the addon folder, if one exists. Returns "" if neither is found.
func _resolve_server_entry() -> String:
	var addons_dir := ProjectSettings.globalize_path("res://addons")
	var da := DirAccess.open(addons_dir)
	if da and da.is_link("godot_live_mcp"):
		var target := da.read_link("godot_live_mcp")
		if target.is_relative_path():
			target = addons_dir.path_join(target)
		var linked_entry := target.path_join("../../server/build/index.js").simplify_path()
		if FileAccess.file_exists(linked_entry):
			return linked_entry
	var bundled := ProjectSettings.globalize_path("res://addons/godot_live_mcp/server/build/index.js")
	if FileAccess.file_exists(bundled):
		return bundled
	return ""

## Same precedence as bridge.gd's _load_or_create_token(): an env override
## wins, otherwise the per-project token the bridge generated on first enable.
func _read_bridge_token() -> String:
	var override := OS.get_environment("GODOT_LIVE_MCP_TOKEN")
	if override != "":
		return override
	var f := FileAccess.open("user://godot_live_mcp_token.txt", FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().strip_edges()

## Hands `claude` this project's MCP server + token directly at launch, so
## the user never registers the server or copies a token by hand — and each
## project gets its own token, which a single globally-registered server
## can't do. Returns [] (after explaining why) if the server or token can't
## be found; the session then falls back to whatever MCP config the user
## already has.
func _mcp_config_args(report: Callable) -> Array:
	var entry := _resolve_server_entry()
	if entry.is_empty():
		report.call("Couldn't find the GodotLiveMCP server (expected addons/godot_live_mcp to link to the cloned repo — run `npm run link-project -- <this project>` in the repo's server/ folder). Falling back to any manually registered godot-live-mcp server.")
		return []
	var token := _read_bridge_token()
	if token.is_empty():
		report.call("No bridge token found yet — is the GodotLive MCP Bridge plugin enabled? Falling back to any manually registered godot-live-mcp server.")
		return []
	var config := {"mcpServers": {"godot-live-mcp": {
		"command": "node",
		"args": [entry],
		"env": {"GODOT_LIVE_MCP_TOKEN": token},
	}}}
	return ["--mcp-config", JSON.stringify(config)]

## Registers this project's server + token with Claude Code at local scope
## (stored in ~/.claude.json against this project folder, never in the
## project's own files), so ANY `claude` session started in this folder —
## not just ones this panel launches — reaches this editor with the right
## token. Local scope takes precedence over a user-scope registration of the
## same name (confirmed live). `claude mcp add` refuses an existing name, so
## an update is remove-then-add. Skipped when the entry/token pair matches
## what was last registered, since each `claude` invocation blocks the
## editor for a moment.
func _ensure_local_registration() -> void:
	if OS.get_name() == "Windows" or not _has_command("claude"):
		return
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if entry.is_empty() or token.is_empty():
		return
	var signature := "%s|%s" % [entry, token]
	var editor_settings := EditorInterface.get_editor_settings()
	if editor_settings.get_project_metadata("godot_live_mcp", "local_registration", "") == signature:
		return

	var add_cmd := "claude mcp add -s local godot-live-mcp -e %s -- node %s" % [
		_shell_quote("GODOT_LIVE_MCP_TOKEN=" + token), _shell_quote(entry)
	]
	var shell_cmd := "cd %s && { claude mcp remove -s local godot-live-mcp >/dev/null 2>&1; %s; }" % [
		_shell_quote(ProjectSettings.globalize_path("res://")), add_cmd
	]
	var output: Array = []
	if OS.execute("bash", ["-lc", shell_cmd], output, true) != 0:
		_append_transcript("[color=yellow]Couldn't register godot-live-mcp for this project with Claude Code: %s[/color]" % "".join(output).strip_edges())
		return
	editor_settings.set_project_metadata("godot_live_mcp", "local_registration", signature)
	_append_transcript("[i]Registered godot-live-mcp for this project folder — any `claude` session started here can now control this editor.[/i]")

func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

func _make_permission_toggle(label: String, parent: Control) -> Button:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	# On by default; turning one off is remembered per project.
	var key := "permission_" + label.to_snake_case()
	b.button_pressed = EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", key, true)
	b.toggled.connect(func(on: bool):
		EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", key, on))
	# Toggle-mode buttons render with the "pressed" stylebox whenever
	# button_pressed is true, automatically — no signal handler needed, this
	# just needs to be a visibly different style from the default "normal"/
	# grey one that shows when off.
	var green := StyleBoxFlat.new()
	green.bg_color = Color(0.22, 0.6, 0.28)
	green.corner_radius_top_left = 4
	green.corner_radius_top_right = 4
	green.corner_radius_bottom_left = 4
	green.corner_radius_bottom_right = 4
	green.content_margin_left = 8
	green.content_margin_right = 8
	green.content_margin_top = 0
	green.content_margin_bottom = 0
	b.add_theme_stylebox_override("pressed", green)
	b.add_theme_stylebox_override("hover_pressed", green)
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_color_override("font_hover_pressed_color", Color(1, 1, 1))
	# Stashed so _set_toggle_disabled (below) can reapply it as the
	# "disabled" stylebox too — Godot's disabled state otherwise overrides
	# pressed/hover_pressed outright, so a toggle switched on then disabled
	# (which is exactly what happens once a session starts) fell back to
	# the plain grey "disabled" look and the on/off state became invisible.
	# Confirmed live: this was the actual bug, not a timing issue.
	b.set_meta("green_style", green)
	parent.add_child(b)
	_compact_button_padding(b)
	return b

## Shrinks a button's vertical padding to roughly match Godot's own compact
## editor controls (confirmed live: default buttons render at 38px/33px
## min, close to 70% of that is the target here) — reduces content_margin_
## top/bottom on whichever stylebox states are actually in play (normal/
## hover/disabled from the inherited editor theme, plus pressed/
## hover_pressed if already overridden, e.g. by _make_permission_toggle's
## green) rather than relying on custom_minimum_size, which can only raise
## a button's minimum height, never shrink it below what its stylebox
## padding already demands.
## Disabling a toggle-mode Button normally forces Godot's plain "disabled"
## stylebox regardless of button_pressed, hiding whether it was on or off.
## Reapplies the same green style as "disabled" too when the toggle is on,
## and clears that override when re-enabling (so a later disable while off
## falls back to the normal grey look, not a stale green one).
func _set_toggle_disabled(toggle: Button, disabled: bool) -> void:
	toggle.disabled = disabled
	if disabled and toggle.button_pressed:
		toggle.add_theme_stylebox_override("disabled", toggle.get_meta("green_style"))
		toggle.add_theme_color_override("font_disabled_color", Color(1, 1, 1))
	else:
		# Reapply the compacted grey default, not remove_theme_stylebox_
		# override — removing it falls back to Godot's ORIGINAL uncompacted
		# style, and Button.get_minimum_size() factors the disabled
		# stylebox's size in even while enabled, so that alone makes the
		# whole button look tall again. Confirmed live.
		toggle.add_theme_stylebox_override("disabled", toggle.get_meta("default_disabled_style"))
		toggle.remove_theme_color_override("font_disabled_color")

# ---- In-editor session (Phase 1 flagship) ----

func _build_session_ui() -> void:
	_transcript = RichTextLabel.new()
	_transcript.bbcode_enabled = true
	_transcript.scroll_following = true
	_transcript.custom_minimum_size = Vector2(0, 160)
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# RichTextLabel defaults to non-selectable — off by default in Godot,
	# not something that needed live-verifying, just easy to forget to set.
	_transcript.selection_enabled = true
	_transcript.context_menu_enabled = true  # right-click → Copy, standard shortcuts too
	_transcript.deselect_on_focus_loss_enabled = false

	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# TextEdit, not LineEdit — LineEdit is single-line only by design, no
	# way to grow it, so it can't do "resize to show more input lines".
	# Starts at one line's height, like the LineEdit it replaces; the
	# VSplitContainer's drag handle (below) is what lets it grow.
	_input_field = TextEdit.new()
	_input_field.placeholder_text = "Type a message and press Enter — starts the session automatically… (Shift+Enter for a newline)"
	_input_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_field.custom_minimum_size = Vector2(0, 24)
	_input_field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input_field.gui_input.connect(_on_input_gui_input)
	input_row.add_child(_input_field)

	# VSplitContainer instead of two plain add_child calls — its drag
	# handle is what makes the input box resizable, per the request. Needs
	# exactly two children (transcript, input row) to show one handle.
	var splitter := VSplitContainer.new()
	splitter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	splitter.add_child(_transcript)
	splitter.add_child(input_row)
	add_child(splitter)

	_send_button = Button.new()
	_send_button.icon = _svg_icon("send.svg")
	_send_button.tooltip_text = "Send (Enter)"
	_send_button.custom_minimum_size.x = 48 * EditorInterface.get_editor_scale()
	_style_button(_send_button, Color(0.22, 0.6, 0.28))
	_send_button.pressed.connect(_on_send_pressed.bind(""))
	input_row.add_child(_send_button)

	_stop_button = Button.new()
	_stop_button.icon = _svg_icon("stop_hand.svg")
	_stop_button.tooltip_text = "Stop the current reply (the conversation is kept)"
	_stop_button.custom_minimum_size.x = 36 * EditorInterface.get_editor_scale()
	_style_button(_stop_button, Color(0.75, 0.2, 0.2))
	_stop_button.pressed.connect(_on_stop_pressed)
	input_row.add_child(_stop_button)

## An icon from this addon's icons/ folder, rasterized from the SVG directly
## (no import step, so it works the moment a project links the addon).
func _svg_icon(file_name: String) -> Texture2D:
	var svg := FileAccess.get_file_as_string("res://addons/godot_live_mcp/icons/" + file_name)
	if svg.is_empty():
		return null
	var img := Image.new()
	if img.load_svg_from_string(svg, EditorInterface.get_editor_scale()) != OK:
		return null
	return ImageTexture.create_from_image(img)

func _style_button(b: Button, color: Color) -> void:
	for state in ["normal", "hover", "pressed", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = color.lightened(0.12) if state == "hover" else (color.darkened(0.15) if state == "pressed" else color)
		box.set_corner_radius_all(4)
		box.content_margin_left = 8
		box.content_margin_right = 8
		if state == "focus":
			box.draw_center = false
		b.add_theme_stylebox_override(state, box)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		b.add_theme_color_override(c, Color.WHITE)

## Stops the reply in progress without ending the conversation: Claude gets
## the stream-json "interrupt" control request (confirmed: the session and
## its context carry on); a Codex turn is its own process, so it's ended and
## the next message resumes the same thread.
func _on_stop_pressed() -> void:
	if not _session_active:
		return
	if _session_kind == "codex":
		if _pipe.has("pid") and OS.is_process_running(_pipe.pid):
			OS.kill(_pipe.pid)
		_stop_session("Stopped.")
		return
	if _pipe.has("stdio") and _pipe.stdio:
		_pipe.stdio.store_string(JSON.stringify({
			"type": "control_request",
			"request_id": "stop-%d" % Time.get_ticks_msec(),
			"request": {"subtype": "interrupt"},
		}) + "\n")
		_append_transcript("[i]Stopped.[/i]")

## Called by plugin.gd's _exit_tree so a running `claude` subprocess doesn't
## leak past a plugin reload/disable — reload_plugin (used constantly while
## developing this addon) would otherwise orphan one every time.
func shutdown() -> void:
	if _session_active:
		_stop_session("")

## The panel runs the CLIs non-interactively, so their own slash commands
## (/model, /clear, ...) don't exist here. /model is handled by the panel;
## anything else points at the full terminal session.
func _handle_slash_command(text: String) -> void:
	var agent := "codex" if (_preferred_assistant() == "codex" or not _codex_thread_id.is_empty()) else "claude"
	var parts := text.split(" ", false, 1)
	if parts[0] == "/effort":
		_effort_command(agent, parts[1].strip_edges() if parts.size() > 1 else "")
		return
	if parts[0] != "/model":
		_append_transcript("[i]%s isn't available in the panel — use Open %s for the full terminal session. The panel handles /model and /effort; New session (refresh icon) replaces /clear.[/i]" % [
			parts[0].xml_escape(), "Codex" if agent == "codex" else "Claude"])
		return
	if parts.size() == 1:
		_show_choice_menu(agent, "model")
		return
	_set_model(agent, parts[1].strip_edges())

func _set_model(agent: String, model: String) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(
		"godot_live_mcp", "model_" + agent, "" if model == "default" else model)
	if agent == "codex":
		_append_transcript("[i]Codex model set to %s — used from your next message.[/i]" % model.xml_escape())
	else:
		# Claude's panel session is one long process; the model is fixed at
		# launch, so start a fresh session with it.
		if _session_active:
			_stop_session("")
		_append_transcript("[i]Claude model set to %s — your next message starts a new session with it.[/i]" % model.xml_escape())

## /effort [level]: reasoning effort per agent, saved per project, like /model.
## Codex: model_reasoning_effort (e.g. minimal, low, medium, high); Claude:
## --effort (e.g. low, medium, high). Empty = the CLI's own setting.
func _effort_command(agent: String, level: String) -> void:
	if level == "":
		_show_choice_menu(agent, "effort")
		return
	EditorInterface.get_editor_settings().set_project_metadata(
		"godot_live_mcp", "effort_" + agent, "" if level == "default" else level)
	if agent == "codex":
		_append_transcript("[i]Codex effort set to %s — used from your next message.[/i]" % level.xml_escape())
	else:
		if _session_active:
			_stop_session("")
		_append_transcript("[i]Claude effort set to %s — your next message starts a new session with it.[/i]" % level.xml_escape())

# ---- /model and /effort pickers ----

## The CLI's own default (what it uses when the panel doesn't override it):
## Codex from ~/.codex/config.toml, Claude from ~/.claude/settings.json.
func _cli_default(agent: String, what: String) -> String:
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	if agent == "codex":
		var toml := FileAccess.get_file_as_string(home.path_join(".codex/config.toml"))
		var key := "model" if what == "model" else "model_reasoning_effort"
		var m := RegEx.create_from_string("(?m)^%s\\s*=\\s*\"([^\"]*)\"" % key).search(toml)
		return m.get_string(1) if m else ""
	var settings = JSON.parse_string(FileAccess.get_file_as_string(home.path_join(".claude/settings.json")))
	if settings is Dictionary:
		return String(settings.get("model" if what == "model" else "effortLevel", ""))
	return ""

## Choices for the picker: Codex's listed models (and the chosen model's
## effort levels) from its model cache; Claude's model aliases and levels.
func _choices(agent: String, what: String) -> Array:
	if agent == "claude":
		return _CLAUDE_MODELS.keys() if what == "model" else ["low", "medium", "high", "xhigh", "max"]
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	var cache = JSON.parse_string(FileAccess.get_file_as_string(home.path_join(".codex/models_cache.json")))
	var models: Array = cache.get("models", []) if cache is Dictionary else []
	if what == "model":
		var out := []
		for m in models:
			if String(m.get("visibility", "list")) == "list":
				out.append(String(m.get("slug", "")))
		return out
	var current := _current_setting(agent, "model")
	for m in models:
		if String(m.get("slug", "")) == current:
			return m.get("supported_reasoning_levels", []).map(func(l): return String(l.get("effort", "")))
	return ["low", "medium", "high"]

# Claude models by exact ID, so the version shown is the version used (the
# opus/sonnet/haiku aliases move to newer models on their own; they still
# work typed in, and as a CLI default). Update this list when new models
# ship.
const _CLAUDE_MODELS := {
	"claude-fable-5-1": "Fable 5.1",
	"claude-opus-5-5": "Opus 5.5",
	"claude-sonnet-5": "Sonnet 5",
	"claude-haiku-4-5-20251001": "Haiku 4.5",
}

## Display text for a model/effort value: Claude model IDs get their name
## and version, e.g. "Opus 5.5 (claude-opus-5-5)".
func _choice_label(agent: String, value: String) -> String:
	if agent == "claude" and _CLAUDE_MODELS.has(value):
		return "%s (%s)" % [_CLAUDE_MODELS[value], value]
	return value

func _current_setting(agent: String, what: String) -> String:
	var v := String(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", what + "_" + agent, ""))
	return v if v != "" else _cli_default(agent, what)

func _show_choice_menu(agent: String, what: String) -> void:
	var override := String(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", what + "_" + agent, ""))
	var default_value := _cli_default(agent, what)
	var menu := PopupMenu.new()
	add_child(menu)
	var values := [""]
	menu.add_radio_check_item("Default (currently %s)" % (default_value if default_value != "" else "the CLI's own"))
	menu.set_item_checked(0, override == "")
	for c in _choices(agent, what):
		values.append(c)
		menu.add_radio_check_item(_choice_label(agent, c))
		menu.set_item_checked(values.size() - 1, c == override)
	menu.id_pressed.connect(func(id: int):
		var value: String = values[id] if values[id] != "" else "default"
		if what == "model":
			_set_model(agent, value)
		else:
			_effort_command(agent, value))
	menu.popup_hide.connect(menu.queue_free)
	_append_transcript("[i]%s %s: %s — pick one from the menu.[/i]" % [
		agent.capitalize(), what, override if override != "" else "default (%s)" % (default_value if default_value != "" else "CLI's own")])
	menu.popup(Rect2i(Vector2i(_send_button.get_screen_position()) - Vector2i(0, 24 * (values.size() + 1)), Vector2i.ZERO))

## ["--model"/"-m", name] for the agent's chosen model, or [] for its default.
func _model_args(agent: String) -> Array:
	var es := EditorInterface.get_editor_settings()
	var model := String(es.get_project_metadata("godot_live_mcp", "model_" + agent, ""))
	var effort := String(es.get_project_metadata("godot_live_mcp", "effort_" + agent, ""))
	var args := []
	if model != "":
		args += ["-m", model] if agent == "codex" else ["--model", model]
	if effort != "":
		args += ["-c", "model_reasoning_effort=%s" % JSON.stringify(effort)] if agent == "codex" else ["--effort", effort]
	return args

func _preferred_assistant() -> String:
	return String(EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _ASSISTANT_SETTING, "claude"))

func _on_new_session_pressed() -> void:
	_tokens_in = 0
	_tokens_out = 0
	if not _codex_thread_id.is_empty() and not _session_active:
		_codex_thread_id = ""
		_append_transcript("[i]Session ended — your next message starts a new one.[/i]")
		return
	_codex_thread_id = ""
	if _session_active:
		_stop_session("Session ended — your next message starts a new one.")
	else:
		_append_transcript("[i]No session running — your next message starts a new one.[/i]")

# ---- Settings popup ----

const _TESTS_SETTING := "ai_runs_tests"
const _SAVE_SETTING := "ai_saves_changes"
const _ASSISTANT_SETTING := "panel_assistant"

const _SAVE_ON_PROMPT := (
	"Saving preference (set by the user in the Godot AI Assistant settings): save the scene " +
	"with save_scene_live after finishing each step of a task."
)
const _SAVE_OFF_PROMPT := (
	"Saving preference (set by the user in the Godot AI Assistant settings): don't save — " +
	"leave changes unsaved in the editor (the scene tab shows (*)) for the user to save " +
	"with Ctrl+S, like their own edits. Don't call save_scene_live unless the user asks. " +
	"Pressing Play still saves everything first, as it does for the user."
)

const _TESTS_ON_PROMPT := (
	"Testing preference (set by the user in the Godot AI Assistant settings): " +
	"after making changes, verify them yourself — play the scene, check the result " +
	"(game state, screenshots) and fix problems before reporting back."
)
const _TESTS_OFF_PROMPT := (
	"Testing preference (set by the user in the Godot AI Assistant settings): the user " +
	"tests changes themselves to save tokens. Don't play the scene, take screenshots, " +
	"simulate input or run other verification steps unless the user asks. Make the " +
	"change, then briefly say what to try. Quick checks that catch outright errors " +
	"(like a script parse check) are still fine."
)

func _build_settings_popup() -> void:
	_settings_popup = PopupPanel.new()
	add_child(_settings_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_settings_popup.add_child(box)

	var assistant_row := HBoxContainer.new()
	box.add_child(assistant_row)
	var assistant_label := Label.new()
	assistant_label.text = "Coding agent:"
	assistant_row.add_child(assistant_label)
	_assistant_option = OptionButton.new()
	_assistant_option.add_item("Claude")
	_assistant_option.add_item("Codex")
	_assistant_option.selected = 1 if _preferred_assistant() == "codex" else 0
	_assistant_option.item_selected.connect(func(i: int):
		EditorInterface.get_editor_settings().set_project_metadata(
			"godot_live_mcp", _ASSISTANT_SETTING, "codex" if i == 1 else "claude")
		_refresh_model_effort_options()
		if _session_active or not _codex_thread_id.is_empty():
			_append_transcript("[i]Assistant changed — it applies from the next session (New session button).[/i]"))
	assistant_row.add_child(_assistant_option)

	# Model and effort for the chosen agent, in two columns.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	box.add_child(grid)
	for text in ["Model", "Effort"]:
		var l := Label.new()
		l.text = text
		grid.add_child(l)
	_model_option = OptionButton.new()
	_model_option.item_selected.connect(func(i: int):
		_set_model(_panel_agent(), String(_model_option.get_item_metadata(i)))
		_refresh_model_effort_options())
	grid.add_child(_model_option)
	_effort_option = OptionButton.new()
	_effort_option.item_selected.connect(func(i: int):
		_effort_command(_panel_agent(), String(_effort_option.get_item_metadata(i))))
	grid.add_child(_effort_option)

	_sync_check = CheckBox.new()
	_sync_check.text = "Sync editor changes to the running game"
	_sync_check.tooltip_text = (
		"Godot's Debug > Synchronize Scene Changes / Script Changes. While the game runs from\n" +
		"the editor, edits made in the editor (by you or the AI) also appear in the game.\n" +
		"They're real editor edits, so they're kept after the game stops."
	)
	_sync_check.toggled.connect(_on_sync_toggled)
	box.add_child(_sync_check)

	_tests_check = CheckBox.new()
	_tests_check.text = "AI tests its own changes (uses more tokens)"
	_tests_check.tooltip_text = (
		"On: the AI plays the scene and checks its work before reporting back.\n" +
		"Off: the AI makes the change and tells you what to try; you test it.\n" +
		"Applies from the next session (use the New session button)."
	)
	_tests_check.button_pressed = EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _TESTS_SETTING, false)
	_tests_check.toggled.connect(_on_tests_toggled)
	box.add_child(_tests_check)

	_save_check = CheckBox.new()
	_save_check.text = "AI saves its changes"
	_save_check.tooltip_text = (
		"On: the AI saves the scene after each step.\n" +
		"Off: changes stay unsaved (*) for you to save with Ctrl+S, like your own edits.\n" +
		"Applies from the next session (use the New session button)."
	)
	_save_check.button_pressed = EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _SAVE_SETTING, false)
	_save_check.toggled.connect(func(on: bool):
		EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", _SAVE_SETTING, on)
		if _session_active:
			_append_transcript("[i]Saving preference changed — it applies from the next session (New session button).[/i]"))
	box.add_child(_save_check)

func _panel_agent() -> String:
	return "codex" if _preferred_assistant() == "codex" else "claude"

## Fills the Model/Effort drop-downs for the current agent: "Default
## (currently X)" first, then the choices, selecting the active override.
func _refresh_model_effort_options() -> void:
	var agent := _panel_agent()
	for pair in [[_model_option, "model"], [_effort_option, "effort"]]:
		var opt: OptionButton = pair[0]
		var what: String = pair[1]
		var override := String(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", what + "_" + agent, ""))
		var default_value := _cli_default(agent, what)
		opt.clear()
		opt.add_item("Default (%s)" % (default_value if default_value != "" else "CLI's own"))
		opt.set_item_metadata(0, "default")
		var selected := 0
		var choices := _choices(agent, what)
		if override != "" and not choices.has(override):
			choices.append(override)  # a typed-in value not in the list
		for c in choices:
			opt.add_item(_choice_label(agent, c))
			opt.set_item_metadata(opt.item_count - 1, c)
			if c == override:
				selected = opt.item_count - 1
		opt.select(selected)

func _on_settings_pressed() -> void:
	_refresh_model_effort_options()
	_sync_check.set_pressed_no_signal(_is_sync_enabled())
	_sync_check.disabled = _debug_menu_items().is_empty()
	var at := _settings_button.get_screen_position() + Vector2(0, _settings_button.size.y)
	_settings_popup.popup(Rect2i(Vector2i(at), Vector2i.ZERO))

func _on_tests_toggled(on: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", _TESTS_SETTING, on)
	if _session_active:
		_append_transcript("[i]Testing preference changed — it applies from the next session (New session button).[/i]")

## Extra claude arguments from the settings popup (testing and saving preferences,
## as appended system-prompt text the user doesn't see in the transcript).
func _behavior_args() -> Array:
	return ["--append-system-prompt", _behavior_text()]

func _behavior_text() -> String:
	var es := EditorInterface.get_editor_settings()
	var tests: bool = es.get_project_metadata("godot_live_mcp", _TESTS_SETTING, false)
	var saves: bool = es.get_project_metadata("godot_live_mcp", _SAVE_SETTING, false)
	return "\n\n".join([
		_TESTS_ON_PROMPT if tests else _TESTS_OFF_PROMPT,
		_SAVE_ON_PROMPT if saves else _SAVE_OFF_PROMPT,
	])

## The editor's Debug menu and the indices of its two "Synchronize ... Changes"
## check items. Godot doesn't expose these options to plugins, so they're
## found in the menu by their (English) labels; empty if not found.
func _debug_menu_items() -> Dictionary:
	for node in EditorInterface.get_base_control().find_children("*", "PopupMenu", true, false):
		var menu := node as PopupMenu
		var found := []
		for i in menu.item_count:
			if menu.get_item_text(i) in ["Synchronize Scene Changes", "Synchronize Script Changes"]:
				found.append(i)
		if found.size() == 2:
			return {"menu": menu, "indices": found}
	return {}

func _is_sync_enabled() -> bool:
	var items := _debug_menu_items()
	if items.is_empty():
		return false
	var menu: PopupMenu = items.menu
	for i in items.indices:
		if not menu.is_item_checked(i):
			return false
	return true

func _on_sync_toggled(on: bool) -> void:
	var items := _debug_menu_items()
	if items.is_empty():
		return
	var menu: PopupMenu = items.menu
	# Pressing the menu items (rather than just setting the check marks) runs
	# the editor's own handler, which applies and remembers the option.
	for i in items.indices:
		if menu.is_item_checked(i) != on:
			menu.id_pressed.emit(menu.get_item_id(i))

func _start_session() -> bool:
	if not _has_command("claude"):
		_append_transcript("[color=red]Claude Code CLI not found on PATH — install it first: https://docs.claude.com/en/docs/claude-code[/color]")
		return false

	var project_dir := ProjectSettings.globalize_path("res://")
	var allowed := _build_allowed_tools()
	var granted_labels := []
	if _file_control_toggle.button_pressed:
		granted_labels.append("file control")
	if _terminal_toggle.button_pressed:
		granted_labels.append("terminal commands")
	if _web_toggle.button_pressed:
		granted_labels.append("web access")

	# `exec` replaces the shell with claude directly, rather than leaving an
	# extra bash process sitting between us and it — same reasoning as the
	# terminal-launch path, just without a terminal emulator in between here.
	# --permission-prompts none + --allowedTools is the whole safety story
	# here: confirmed live that a genuinely mutating action outside the
	# allowed set gets cleanly denied ("Permission for this tool use was
	# denied... this session has no approval surface"), not silently run and
	# not hung waiting for an approval this panel has no way to deliver.
	var claude_cmd := (
		"exec claude -p --input-format stream-json --output-format stream-json --verbose " +
		"--permission-prompts none --allowedTools %s" % _shell_quote(",".join(allowed))
	)
	for arg in _model_args("claude") + _behavior_args():
		claude_cmd += " " + _shell_quote(arg)
	# Last on the line: --mcp-config is variadic, so anything after it would
	# be swallowed as another config.
	for arg in _mcp_config_args(func(msg): _append_transcript("[color=yellow]%s[/color]" % msg)):
		claude_cmd += " " + _shell_quote(arg)
	var shell_cmd := "cd %s && %s" % [_shell_quote(project_dir), claude_cmd]
	_pipe = OS.execute_with_pipe("bash", ["-lc", shell_cmd], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start Claude session.[/color]")
		_pipe = {}
		return false

	_session_kind = "claude"
	_tokens_in = 0
	_tokens_out = 0
	_read_buffer = ""
	_session_active = true
	# Toggles only take effect at launch (no live "change permissions"
	# protocol), so lock them once a session is running.
	_set_toggle_disabled(_file_control_toggle, true)
	_set_toggle_disabled(_terminal_toggle, true)
	_set_toggle_disabled(_web_toggle, true)
	_append_transcript("[i]Session started (pid %d). Granted: %s.[/i]" % [
		_pipe.pid, ", ".join(granted_labels) if not granted_labels.is_empty() else "Godot control only"
	])
	return true

func _stop_session(status_text: String) -> void:
	if _pipe.has("stdio") and _pipe.stdio:
		_pipe.stdio.close()
	if _pipe.has("pid") and OS.is_process_running(_pipe.pid):
		OS.kill(_pipe.pid)
	_pipe = {}
	_read_buffer = ""
	_session_active = false
	_set_toggle_disabled(_file_control_toggle, false)
	_set_toggle_disabled(_terminal_toggle, false)
	_set_toggle_disabled(_web_toggle, false)
	if not status_text.is_empty():
		_append_transcript("[i]%s[/i]" % status_text)

## No explicit "start" affordance — typing a message and pressing Enter (or
## clicking Send) starts the session on the first call, same as any other
## turn. Simpler than a separate Start button, at the cost of the first
## message's round trip including a process-spawn delay the user doesn't
## TextEdit has no text_submitted signal the way LineEdit does (it's
## multi-line by nature, so Enter means "newline" unless told otherwise) —
## this is that "otherwise": plain Enter sends, Shift+Enter inserts a
## newline like a normal multi-line editor.
func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if not event.shift_pressed:
				get_viewport().set_input_as_handled()
				_on_send_pressed()

## get separate feedback for; acceptable since _start_session already
## posts its own "Session started" line to the transcript immediately.
func _on_send_pressed(_submitted_text: String = "") -> void:
	var text := _input_field.text.strip_edges()
	if text.is_empty():
		return
	if text.begins_with("/"):
		_input_field.text = ""
		_handle_slash_command(text)
		return
	if _preferred_assistant() == "codex" or not _codex_thread_id.is_empty():
		if _session_active:
			_append_transcript("[i]Codex is still working on the last message — wait for it to finish.[/i]")
			return
		if _start_codex_turn(text):
			_append_transcript("[color=#7ec07e][b]You:[/b] %s[/color]" % text.xml_escape())
			_input_field.text = ""
		return
	if not _session_active:
		if not _start_session():
			return
	_append_transcript("[color=#7ec07e][b]You:[/b] %s[/color]" % text.xml_escape())
	var payload := {
		"type": "user",
		"message": {"role": "user", "content": [{"type": "text", "text": text}]},
	}
	_pipe.stdio.store_string(JSON.stringify(payload) + "\n")
	_input_field.text = ""

## Polled every frame from _process(). OS.execute_with_pipe's stdio is
## non-blocking but NOT newline-atomic — confirmed live: get_buffer()
## returns whatever bytes are currently available even mid-write, not "wait
## for a full line." So this accumulates into _read_buffer and only treats
## a segment as a real event once a "\n" has actually been seen, exactly
## mirroring bridge.gd's own _drain_lines pattern for its socket protocol.
## Known limitation, accepted rather than engineered around for v1: a
## multi-byte UTF-8 character split exactly across two reads could render
## as a mangled character — rare in practice, not worth the complexity here.
func _poll_session() -> void:
	if not _session_active or not _pipe.has("stdio") or _pipe.stdio == null:
		return
	var running: bool = _pipe.has("pid") and OS.is_process_running(_pipe.pid)
	var chunk: PackedByteArray = _pipe.stdio.get_buffer(65536)
	if chunk.size() == 0:
		if not running:
			if _session_kind == "codex":
				if not _read_buffer.strip_edges().is_empty():
					_handle_stream_event(_read_buffer)
				_stop_session("")  # one process per Codex turn; the thread lives on
			else:
				_stop_session("Session process exited.")
		return
	_read_buffer += chunk.get_string_from_utf8()

	while true:
		var nl := _read_buffer.find("\n")
		if nl == -1:
			break
		var line := _read_buffer.substr(0, nl)
		_read_buffer = _read_buffer.substr(nl + 1)
		if not line.strip_edges().is_empty():
			_handle_stream_event(line)

## One line of the CLI's --output-format stream-json — see
## PLUGIN_OUTPUT_PANEL_PLAN.md Phase 1 for the confirmed event shape.
## Only "assistant" (rendered) and "result" (a turn-complete marker) are
## surfaced; "system"/"rate_limit_event" are real events but not
## conversation content, so skipped rather than cluttering the transcript.
func _handle_stream_event(line: String) -> void:
	var evt = JSON.parse_string(line)
	if evt == null or not (evt is Dictionary):
		return
	if _session_kind == "codex":
		_handle_codex_event(evt)
		return
	var event_type := String(evt.get("type", ""))

	if event_type == "assistant":
		var content: Array = evt.get("message", {}).get("content", [])
		for block in content:
			var block_type := String(block.get("type", ""))
			if block_type == "text":
				_append_transcript("[b]Claude:[/b] %s" % String(block.get("text", "")).xml_escape())
			elif block_type == "tool_use":
				_append_transcript("[i]  → %s[/i]" % String(block.get("name", "")).xml_escape())
	elif event_type == "result":
		var usage: Dictionary = evt.get("usage", {})
		var turn_in := int(usage.get("input_tokens", 0)) + int(usage.get("cache_creation_input_tokens", 0)) + int(usage.get("cache_read_input_tokens", 0))
		_turn_complete(turn_in, int(usage.get("cache_read_input_tokens", 0)), int(usage.get("output_tokens", 0)), float(evt.get("total_cost_usd", -1.0)))

## Starts `codex exec --json` for one message (resuming the thread after the
## first). Permission toggles map onto Codex's sandbox: File Control ->
## workspace-write (else read-only), Web Access -> network inside it.
## Approvals are "never" since the panel can't show a prompt: anything
## outside the sandbox just fails, like Claude's denied tools here.
func _start_codex_turn(text: String) -> bool:
	if not _has_command("codex"):
		_append_transcript("[color=red]Codex CLI not found on PATH — install it first: https://github.com/openai/codex[/color]")
		return false
	var args := ["exec"]
	if not _codex_thread_id.is_empty():
		args += ["resume", _codex_thread_id]
	args += _model_args("codex")
	args += ["--json", "--skip-git-repo-check",
		"-c", 'sandbox_mode="%s"' % ("workspace-write" if _file_control_toggle.button_pressed else "read-only"),
		"-c", "sandbox_workspace_write.network_access=%s" % ("true" if _web_toggle.button_pressed else "false"),
		"-c", 'approval_policy="never"',
		"-c", "developer_instructions=" + JSON.stringify(_behavior_text())]
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if not entry.is_empty() and not token.is_empty():
		args += [
			"-c", 'mcp_servers.godot-live-mcp.command="node"',
			"-c", "mcp_servers.godot-live-mcp.args=[%s]" % JSON.stringify(entry),
			"-c", "mcp_servers.godot-live-mcp.env.GODOT_LIVE_MCP_TOKEN=%s" % JSON.stringify(token),
		]
	# Godot control is always granted in this panel (like Claude's
	# mcp__godot-live-mcp__*); without this Codex asks per MCP tool call.
	args += ["-c", 'mcp_servers.godot-live-mcp.default_tools_approval_mode="approve"']
	args.append(text)
	var cmd := "exec codex"
	for a in args:
		cmd += " " + _shell_quote(a)
	var shell_cmd := "cd %s && %s < /dev/null" % [_shell_quote(ProjectSettings.globalize_path("res://")), cmd]
	_pipe = OS.execute_with_pipe("bash", ["-lc", shell_cmd], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start Codex.[/color]")
		_pipe = {}
		return false
	_session_kind = "codex"
	_read_buffer = ""
	_session_active = true
	if _codex_thread_id.is_empty():
		_tokens_in = 0
		_tokens_out = 0
		_append_transcript("[i]Codex session started. Sandbox: %s%s.[/i]" % [
			"can edit project files" if _file_control_toggle.button_pressed else "read-only",
			", network on" if _web_toggle.button_pressed else ""])
	return true

## One JSONL event from `codex exec --json`.
func _handle_codex_event(evt: Dictionary) -> void:
	var event_type := String(evt.get("type", ""))
	match event_type:
		"thread.started":
			_codex_thread_id = String(evt.get("thread_id", ""))
		"item.started", "item.completed":
			var item: Dictionary = evt.get("item", {})
			var item_type := String(item.get("type", ""))
			if event_type == "item.started":
				if item_type == "command_execution":
					_append_transcript("[i]  → shell: %s[/i]" % String(item.get("command", "")).xml_escape())
				elif item_type == "mcp_tool_call":
					_append_transcript("[i]  → %s[/i]" % String(item.get("tool", "")).xml_escape())
				elif item_type == "web_search":
					_append_transcript("[i]  → web search: %s[/i]" % String(item.get("query", "")).xml_escape())
			elif item_type == "agent_message":
				_append_transcript("[b]Codex:[/b] %s" % String(item.get("text", "")).xml_escape())
			elif item_type == "file_change":
				_append_transcript("[i]  → edited files[/i]")
			elif item_type == "error":
				_append_transcript("[color=gray]%s[/color]" % String(item.get("message", "")).xml_escape())
		"turn.completed":
			var usage: Dictionary = evt.get("usage", {})
			_turn_complete(int(usage.get("input_tokens", 0)), int(usage.get("cached_input_tokens", 0)), int(usage.get("output_tokens", 0)), -1.0)
		"turn.failed":
			var msg := String(evt.get("error", {}).get("message", "unknown error"))
			_append_transcript("[color=red]Codex failed: %s[/color]" % msg.xml_escape())
			if msg.contains("401") or msg.containsn("unauthorized"):
				_append_transcript("[color=yellow]Codex isn't logged in — run `codex login` in a terminal.[/color]")
		"error":
			pass  # reconnect chatter; a real failure also arrives as turn.failed

## "— edits complete —" plus this turn's tokens (in, of which cached, and
## out) and the conversation's running totals; Claude also reports cost.
func _turn_complete(turn_in: int, cached: int, turn_out: int, cost: float) -> void:
	_tokens_in += turn_in
	_tokens_out += turn_out
	var line := "— edits complete · %s in (%s cached) / %s out · session %s / %s" % [
		_short_count(turn_in), _short_count(cached), _short_count(turn_out),
		_short_count(_tokens_in), _short_count(_tokens_out)]
	if cost >= 0.0:
		line += " · $%.2f" % cost
	_append_transcript("[color=gray]%s —[/color]" % line)

func _short_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (n / 1000.0)
	return str(n)

func _append_transcript(bbcode_line: String) -> void:
	_transcript.append_text(bbcode_line + "\n")
