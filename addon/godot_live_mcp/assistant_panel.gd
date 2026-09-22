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
var _input_field: LineEdit
var _send_button: Button
var _pipe: Dictionary = {}       # result of OS.execute_with_pipe while a session is active
var _read_buffer: String = ""    # accumulates partial reads until a full "\n"-terminated line exists
var _session_active: bool = false

func _ready() -> void:
	add_theme_constant_override("separation", 8)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 6)
	add_child(button_row)

	# Anthropic's Claude logomark — same asset Omarchy's own agents bar
	# panel ships (assets/claude.svg there), copied in rather than
	# referenced from /usr/share/omarchy so this doesn't depend on Omarchy
	# being installed. Godot imports SVGs as textures natively; no font
	# dependency needed (icon fonts were the other option raised, but a
	# real brand SVG we already had on hand is simpler and unambiguous).
	var icon := TextureRect.new()
	icon.texture = load("res://addons/godot_live_mcp/icons/claude.svg")
	icon.custom_minimum_size = Vector2(20, 20)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button_row.add_child(icon)

	_launch_button = Button.new()
	_launch_button.text = "Open in Terminal"
	_launch_button.pressed.connect(_on_launch_pressed)
	button_row.add_child(_launch_button)

	button_row.add_child(VSeparator.new())

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
	# allowing it.
	_file_control_toggle = _make_permission_toggle("Grant File Control", button_row)
	_terminal_toggle = _make_permission_toggle("Grant Terminal Commands", button_row)
	_web_toggle = _make_permission_toggle("Grant Web Access", button_row)

	add_child(HSeparator.new())
	_build_session_ui()

	_refresh_status()

func _process(_delta: float) -> void:
	_poll_session()

func _refresh_status() -> void:
	if not _has_command("claude"):
		_launch_button.tooltip_text = (
			"Claude Code CLI not found on PATH. Install it first: " +
			"https://docs.claude.com/en/docs/claude-code — then reopen this panel."
		)
		_launch_button.disabled = true
		return

	var term := _find_terminal()
	if term.is_empty():
		_launch_button.tooltip_text = (
			"Claude Code CLI found, but no supported terminal emulator was " +
			"detected on PATH (tried $TERMINAL, alacritty, kitty, foot, " +
			"ghostty, gnome-terminal, konsole, xfce4-terminal, xterm)."
		)
		_launch_button.disabled = true
		return

	_launch_button.tooltip_text = "Opens a Claude Code session in %s, in this project's directory." % term.bin
	_launch_button.disabled = false

func _on_launch_pressed() -> void:
	var project_dir := ProjectSettings.globalize_path("res://")

	if OS.get_name() == "Windows":
		# OS.create_process's open_console is a real native console window
		# on Windows; no terminal-emulator detection needed there.
		OS.create_process("claude", [], true)
		return

	var term := _find_terminal()
	if term.is_empty():
		_refresh_status()  # re-check in case something changed since panel opened
		return

	match term.style:
		"xdg":
			OS.create_process(term.bin, ["--dir=%s" % project_dir, "--", "claude"])
		"direct":
			# No native workdir flag — same shell `cd` fallback as flag_e/
			# dashdash below, just without a leading terminal-specific flag.
			OS.create_process(term.bin, ["bash", "-lc", "cd %s && claude" % _shell_quote(project_dir)])
		"flag_e":
			OS.create_process(term.bin, ["-e", "bash", "-lc", "cd %s && claude" % _shell_quote(project_dir)])
		"dashdash":
			OS.create_process(term.bin, ["--", "bash", "-lc", "cd %s && claude" % _shell_quote(project_dir)])

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

func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

func _make_permission_toggle(label: String, parent: Control) -> Button:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	b.button_pressed = false  # opt-in, not opt-out — safe by default
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
	green.content_margin_top = 4
	green.content_margin_bottom = 4
	b.add_theme_stylebox_override("pressed", green)
	b.add_theme_stylebox_override("hover_pressed", green)
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_color_override("font_hover_pressed_color", Color(1, 1, 1))
	parent.add_child(b)
	return b

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
	add_child(_transcript)

	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(input_row)

	_input_field = LineEdit.new()
	_input_field.placeholder_text = "Type a message and press Enter — starts the session automatically…"
	_input_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_field.text_submitted.connect(_on_send_pressed)
	input_row.add_child(_input_field)

	_send_button = Button.new()
	_send_button.text = "Send"
	_send_button.pressed.connect(_on_send_pressed.bind(""))
	input_row.add_child(_send_button)

## Called by plugin.gd's _exit_tree so a running `claude` subprocess doesn't
## leak past a plugin reload/disable — reload_plugin (used constantly while
## developing this addon) would otherwise orphan one every time.
func shutdown() -> void:
	if _session_active:
		_stop_session("")

func _start_session() -> bool:
	if not _has_command("claude"):
		_append_transcript("[color=red]Claude Code CLI not found on PATH — install it first: https://docs.claude.com/en/docs/claude-code[/color]")
		return false

	var project_dir := ProjectSettings.globalize_path("res://")

	var allowed := ["mcp__godot-live-mcp__*"]
	var granted_labels := []
	if _file_control_toggle.button_pressed:
		allowed.append_array(["Read", "Write", "Edit"])
		granted_labels.append("file control")
	if _terminal_toggle.button_pressed:
		allowed.append("Bash")
		granted_labels.append("terminal commands")
	if _web_toggle.button_pressed:
		allowed.append_array(["WebFetch", "WebSearch"])
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
	var shell_cmd := "cd %s && %s" % [_shell_quote(project_dir), claude_cmd]
	_pipe = OS.execute_with_pipe("bash", ["-lc", shell_cmd], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start Claude session.[/color]")
		_pipe = {}
		return false

	_read_buffer = ""
	_session_active = true
	# Toggles only take effect at launch (no live "change permissions"
	# protocol), so lock them once a session is running.
	_file_control_toggle.disabled = true
	_terminal_toggle.disabled = true
	_web_toggle.disabled = true
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
	_file_control_toggle.disabled = false
	_terminal_toggle.disabled = false
	_web_toggle.disabled = false
	if not status_text.is_empty():
		_append_transcript("[i]%s[/i]" % status_text)

## No explicit "start" affordance — typing a message and pressing Enter (or
## clicking Send) starts the session on the first call, same as any other
## turn. Simpler than a separate Start button, at the cost of the first
## message's round trip including a process-spawn delay the user doesn't
## get separate feedback for; acceptable since _start_session already
## posts its own "Session started" line to the transcript immediately.
func _on_send_pressed(_submitted_text: String = "") -> void:
	var text := _input_field.text.strip_edges()
	if text.is_empty():
		return
	if not _session_active:
		if not _start_session():
			return
	_append_transcript("[b]You:[/b] %s" % text.xml_escape())
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
	if _pipe.has("pid") and not OS.is_process_running(_pipe.pid):
		_stop_session("Session process exited.")
		return

	var chunk: PackedByteArray = _pipe.stdio.get_buffer(65536)
	if chunk.size() == 0:
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
		_append_transcript("[color=gray]— turn complete —[/color]")

func _append_transcript(bbcode_line: String) -> void:
	_transcript.append_text(bbcode_line + "\n")
