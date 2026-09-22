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

var _status_label: Label
var _launch_button: Button

# In-editor session state
var _session_status_label: Label
var _session_button: Button
var _transcript: RichTextLabel
var _input_field: LineEdit
var _send_button: Button
var _pipe: Dictionary = {}       # result of OS.execute_with_pipe while a session is active
var _read_buffer: String = ""    # accumulates partial reads until a full "\n"-terminated line exists
var _session_active: bool = false

func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)

	_launch_button = Button.new()
	_launch_button.text = "Open Claude Code in Terminal"
	_launch_button.pressed.connect(_on_launch_pressed)
	add_child(_launch_button)

	add_child(HSeparator.new())
	_build_session_ui()

	_refresh_status()

func _process(_delta: float) -> void:
	_poll_session()

func _refresh_status() -> void:
	if not _has_command("claude"):
		_status_label.text = (
			"Claude Code CLI not found on PATH. Install it first: " +
			"https://docs.claude.com/en/docs/claude-code — then reopen this panel."
		)
		_launch_button.disabled = true
		return

	var term := _find_terminal()
	if term.is_empty():
		_status_label.text = (
			"Claude Code CLI found, but no supported terminal emulator was " +
			"detected on PATH (tried $TERMINAL, alacritty, kitty, foot, " +
			"ghostty, gnome-terminal, konsole, xfce4-terminal, xterm)."
		)
		_launch_button.disabled = true
		return

	_status_label.text = "Ready. Opens a Claude Code session in %s, in this project's directory." % term.bin
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

# ---- In-editor session (Phase 1 flagship) ----

func _build_session_ui() -> void:
	_session_status_label = Label.new()
	_session_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_session_status_label.text = "In-editor session: not started."
	add_child(_session_status_label)

	_session_button = Button.new()
	_session_button.text = "Start In-Editor Session"
	_session_button.pressed.connect(_on_session_toggle_pressed)
	add_child(_session_button)

	_transcript = RichTextLabel.new()
	_transcript.bbcode_enabled = true
	_transcript.scroll_following = true
	_transcript.custom_minimum_size = Vector2(0, 160)
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_transcript)

	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(input_row)

	_input_field = LineEdit.new()
	_input_field.placeholder_text = "Type a message and press Enter…"
	_input_field.editable = false
	_input_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_field.text_submitted.connect(_on_send_pressed)
	input_row.add_child(_input_field)

	_send_button = Button.new()
	_send_button.text = "Send"
	_send_button.disabled = true
	_send_button.pressed.connect(_on_send_pressed.bind(""))
	input_row.add_child(_send_button)

## Called by plugin.gd's _exit_tree so a running `claude` subprocess doesn't
## leak past a plugin reload/disable — reload_plugin (used constantly while
## developing this addon) would otherwise orphan one every time.
func shutdown() -> void:
	if _session_active:
		_stop_session("")

func _on_session_toggle_pressed() -> void:
	if _session_active:
		_stop_session("Session stopped.")
	else:
		_start_session()

func _start_session() -> void:
	if not _has_command("claude"):
		_session_status_label.text = "Claude Code CLI not found on PATH — install it first."
		return

	var project_dir := ProjectSettings.globalize_path("res://")
	# `exec` replaces the shell with claude directly, rather than leaving an
	# extra bash process sitting between us and it — same reasoning as the
	# terminal-launch path, just without a terminal emulator in between here.
	var shell_cmd := "cd %s && exec claude -p --input-format stream-json --output-format stream-json --verbose" % _shell_quote(project_dir)
	_pipe = OS.execute_with_pipe("bash", ["-lc", shell_cmd], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_session_status_label.text = "Failed to start Claude session."
		_pipe = {}
		return

	_read_buffer = ""
	_session_active = true
	_session_button.text = "Stop Session"
	_session_status_label.text = "In-editor session running (pid %d)." % _pipe.pid
	_input_field.editable = true
	_send_button.disabled = false
	_input_field.grab_focus()
	_append_transcript("[i]Session started.[/i]")

func _stop_session(status_text: String) -> void:
	if _pipe.has("stdio") and _pipe.stdio:
		_pipe.stdio.close()
	if _pipe.has("pid") and OS.is_process_running(_pipe.pid):
		OS.kill(_pipe.pid)
	_pipe = {}
	_read_buffer = ""
	_session_active = false
	_session_button.text = "Start In-Editor Session"
	_session_status_label.text = status_text
	_input_field.editable = false
	_send_button.disabled = true

func _on_send_pressed(_submitted_text: String = "") -> void:
	if not _session_active:
		return
	var text := _input_field.text.strip_edges()
	if text.is_empty():
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
