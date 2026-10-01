@tool
extends VBoxContainer

## Bottom-panel tab: "AI Assistant". Two independent on-ramps, offered
## together rather than as a mode switch: an external-terminal launcher
## (the native TUI, no parsing needed) and an in-editor structured session (this addition) that
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

## GUI apps on macOS get a minimal PATH, and a login shell there is zsh
## reading ~/.zprofile, not bash. Prepend the usual install locations
## (Node's .pkg and Homebrew on Intel -> /usr/local/bin, Homebrew on Apple
## Silicon -> /opt/homebrew/bin, Claude's native installer -> ~/.local/bin).
const _MAC_PATH_PREFIX := 'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '

var _external_button: Button       # header: open the chosen agent in a separate terminal window
var _term_emulator_found := true   # a terminal emulator exists for External (set by _refresh_status)
var _agent_button: MenuButton      # header: agent + model (+ effort) menu
var _agent_model_menu: PopupMenu
var _agent_effort_menu: PopupMenu
var _chat_button: Button           # header mode: Chat
var _agent_label: Label            # header: the current agent / model, after the Agent button
var _logo: TextureRect             # header robot: a status light (see _set_robot)
var _robot_textures := {}          # face name -> texture
var _robot_state := "idle"
var _robot_frame := 0
var _robot_timer: Timer            # steps the current state's frames
var _robot_hold_timer: Timer       # returns "done" / "angry" to idle after a while
# What is keeping the robot "busy": the chat's reply, the embedded CLI's own
# "esc to interrupt" hint, or calls arriving at the editor bridge (any client).
var _busy := {"chat": false, "cli": false, "bridge": false}
var _bridge_quiet_timer: Timer
var _cli_poll_timer: Timer
var _cli_busy_re: RegEx
var _mode := "chat"                # "chat" | "cli" | "external"
var _split_saved := false          # External mode shrinks the bottom panel; remembers its height
var _split_saved_offset := 0
var _chat_view: Control            # the transcript + input (the default view)
var _term_view: VBoxContainer      # the embedded terminal view (GodotXterm), if available
var _term_holder: Control          # where the Terminal control lives (or is popped out of)
var _term: Control                 # GodotXterm Terminal node
var _pty: Node                     # GodotXterm PTY node
var _term_button: Button           # header toggle: chat view <-> terminal view
var _term_size_spin: SpinBox
var _term_scheme_option: OptionButton
var _term_running := false
var _term_agent := ""
var _term_signature_started := ""   # the settings the running CLI was launched with
var _installed: Dictionary = {}    # cli id -> found on PATH (see _detect_clis)
var _new_session_button: Button
var _settings_button: Button
var _settings_popup: PopupPanel
var _sync_check: CheckBox
var _tests_check: CheckBox
var _save_check: CheckBox
# Codex and OpenCode in the panel run one process per message and resume the
# same thread for the next one; this is that thread's id and whose it is.
# (Claude's resumable session id is _claude_session_id, below.)
var _thread_id := ""
var _thread_agent := ""
var _session_kind := "claude"  # which CLI the running _pipe belongs to
# Claude's conversation id + display name, kept in project metadata so the
# conversation survives model/effort changes and editor restarts (the next
# process is started with --resume) until New session clears it.
var _claude_session_id := ""
var _session_name := ""
var _got_init := false       # the running process has reported its session
var _resuming := false       # the running process was started with --resume
const _TRANSCRIPT_PATH := "user://godot_live_mcp_transcript.bb"
const _TRANSCRIPT_KEEP_BYTES := 200000
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

# ---- The robot: a status light ----
#
# The header logo is a little robot (Material Design robot faces, outlines taken
# from the Nerd Font) that shows what the in-panel agent is doing: orange and
# blinking when idle, yellow and puzzled while it works, green and happy for a
# moment when a reply is done, red and angry on an error or when stopped.
# It only knows about the chat view; a CLI or External session isn't visible to it.
const _ROBOT_STATES := {
	"idle": {"color": "#d97757", "frames": ["plain", "happy"], "times": [2.6, 0.25]},
	"thinking": {"color": "#f2c94c", "frames": ["confused", "plain"], "times": [0.5, 0.5]},
	"done": {"color": "#7ec07e", "frames": ["excited"], "times": [1.0], "hold": 5.0},
	"angry": {"color": "#e06c75", "frames": ["angry"], "times": [1.0], "hold": 3.0},
}

func _setup_robot() -> void:
	for face in ["plain", "happy", "confused", "excited", "angry", "dead"]:
		_robot_textures[face] = _svg_icon("robot_%s.svg" % face, 2.0)  # 2x so the faces stay crisp
	_robot_timer = Timer.new()
	_robot_timer.one_shot = true
	_robot_timer.timeout.connect(_robot_tick)
	add_child(_robot_timer)
	_robot_hold_timer = Timer.new()
	_robot_hold_timer.one_shot = true
	_robot_hold_timer.timeout.connect(func(): _set_robot("thinking" if _any_busy() else "idle"))
	add_child(_robot_hold_timer)
	_bridge_quiet_timer = Timer.new()
	_bridge_quiet_timer.one_shot = true
	_bridge_quiet_timer.timeout.connect(func(): _set_busy("bridge", false))
	add_child(_bridge_quiet_timer)
	# CLIs print a hint while they work: "esc to interrupt" (Claude Code, Codex),
	# "esc interrupt" (OpenCode), "esc to cancel" (Gemini). Spaces can go missing
	# in the terminal's text, hence the \s*.
	_cli_busy_re = RegEx.create_from_string("(?i)esc\\s*(?:to\\s*)?(?:interrupt|cancel)")
	_cli_poll_timer = Timer.new()
	_cli_poll_timer.wait_time = 0.5
	_cli_poll_timer.timeout.connect(_poll_cli_state)
	add_child(_cli_poll_timer)
	_cli_poll_timer.start()
	_set_robot("idle")

func _any_busy() -> bool:
	return _busy.values().has(true)

## Marks a source busy or not; the robot goes yellow when the first source
## becomes busy and flashes green when the last one stops.
func _set_busy(source: String, on: bool) -> void:
	if _busy[source] == on:
		return
	var was := _any_busy()
	_busy[source] = on
	var now := _any_busy()
	if now and not was:
		_set_robot("thinking")
	elif was and not now:
		_set_robot("done")

## Like _set_busy(source, false) but without the green flash (a stopped or
## abandoned reply isn't "done").
func _clear_busy(source: String) -> void:
	_busy[source] = false
	if not _any_busy() and _robot_state == "thinking":
		_set_robot("idle")

## Called (through plugin.gd) for every request the editor bridge answers.
func on_bridge_activity(ok: bool) -> void:
	if _bridge_quiet_timer == null:
		return
	_bridge_quiet_timer.start(3.0)
	_set_busy("bridge", true)
	if not ok:
		_set_robot("angry", 1.2)  # a short flash; failed calls are normal

## Reads the embedded CLI's visible screen (not its scrollback) for the hint
## it prints while it works.
func _poll_cli_state() -> void:
	if not _term_running or _term == null:
		_set_busy("cli", false)
		return
	var rows := maxi(int(_term.call("get_rows")), 1)
	var lines: PackedStringArray = String(_term.call("copy_all")).split("\n")
	var screen := "\n".join(lines.slice(maxi(0, lines.size() - rows)))
	_set_busy("cli", _cli_busy_re.search(screen) != null)

func _set_robot(state: String, hold_override: float = -1.0) -> void:
	if _logo == null or not _ROBOT_STATES.has(state):
		return
	_robot_state = state
	_robot_frame = -1
	_robot_hold_timer.stop()
	_logo.modulate = Color(_ROBOT_STATES[state].color)
	_robot_tick()
	var hold := hold_override if hold_override >= 0.0 else float(_ROBOT_STATES[state].get("hold", 0.0))
	if hold > 0.0:
		_robot_hold_timer.start(hold)

func _robot_tick() -> void:
	var def: Dictionary = _ROBOT_STATES[_robot_state]
	var frames: Array = def.frames
	_robot_frame = (_robot_frame + 1) % frames.size()
	_logo.texture = _robot_textures.get(frames[_robot_frame])
	if frames.size() > 1:
		_robot_timer.start(float(def.times[_robot_frame]))
	else:
		_robot_timer.stop()

## Shrinks a button's vertical padding to roughly match Godot's own compact
## editor controls (default buttons render at 38px/33px min) by zeroing
## content_margin_top/bottom on each stylebox state, rather than relying on
## custom_minimum_size, which can only raise a button's minimum height.
func _compact_button_padding(b: Button) -> void:
	for state in [&"normal", &"hover", &"disabled", &"focus", &"pressed", &"hover_pressed"]:
		var style := b.get_theme_stylebox(state)
		if style == null:
			continue
		var compact: StyleBox = style.duplicate()
		compact.content_margin_top = 0
		compact.content_margin_bottom = 0
		b.add_theme_stylebox_override(state, compact)

func _ready() -> void:
	add_theme_constant_override("separation", 8)
	_detect_clis()

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 6)
	add_child(button_row)

	# The logo: a little robot (Material Design "robot-dead", outline taken from
	# the Nerd Font), tinted orange. It is a white SVG so it can be tinted.
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(26, 26)
	_logo = icon
	# TextureRect defaults to expand_mode EXPAND_KEEP_SIZE, which ignores
	# custom_minimum_size for shrinking and reports the texture's native
	# pixel size as its own minimum regardless — confirmed live: that alone
	# kept the whole button row taller than its compacted buttons.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button_row.add_child(icon)
	_setup_robot()

	var title := Label.new()
	title.text = "Godot LIVE MCP"
	title.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	button_row.add_child(title)

	# Godot control itself (mcp__godot-live-mcp__*) is always granted, not a
	# toggle — it's the entire point of this panel. The three optional,
	# broader grants live in the settings popup (see _make_permission_check).

	var editor_theme := EditorInterface.get_editor_theme()

	# The coding agent comes first: one menu for agent, model and effort, and
	# the current choice printed after it. It drives Chat, CLI and External.
	_agent_button = MenuButton.new()
	_agent_button.flat = false
	_agent_button.text = "Agent"
	_agent_button.get_popup().about_to_popup.connect(_rebuild_agent_menu)
	_agent_button.get_popup().id_pressed.connect(_on_agent_menu_id)
	_agent_model_menu = PopupMenu.new()
	_agent_model_menu.name = "ModelMenu"
	_agent_button.get_popup().add_child(_agent_model_menu)
	_agent_model_menu.id_pressed.connect(func(id: int): _choose_model(String(_agent_model_menu.get_item_metadata(id))))
	_agent_effort_menu = PopupMenu.new()
	_agent_effort_menu.name = "EffortMenu"
	_agent_button.get_popup().add_child(_agent_effort_menu)
	_agent_effort_menu.id_pressed.connect(func(id: int): _choose_effort(String(_agent_effort_menu.get_item_metadata(id))))
	button_row.add_child(_agent_button)
	_compact_button_padding(_agent_button)
	_agent_label = Label.new()
	_agent_label.add_theme_color_override("font_color", Color("#7ec07e"))
	_agent_label.add_theme_font_override("font", EditorInterface.get_editor_theme().get_font("bold", "EditorFonts"))
	button_row.add_child(_agent_label)

	# Three modes for the chosen agent, one word each, as a single toggle:
	# Chat (the chat box), CLI (its CLI inside the editor, with the optional
	# GodotXterm addon) and External (its CLI in a separate terminal window —
	# the panel then shrinks to just this header).
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 6)
	button_row.add_child(seg)
	var group := ButtonGroup.new()
	_chat_button = Button.new()
	_chat_button.text = "Chat"
	_chat_button.icon = _svg_icon("chat.svg")
	_tint_icon_button(_chat_button)
	_chat_button.toggle_mode = true
	_chat_button.button_group = group
	_chat_button.button_pressed = true
	_chat_button.toggled.connect(_on_mode_toggled.bind("chat"))
	seg.add_child(_chat_button)
	_compact_button_padding(_chat_button)
	_style_mode_button(_chat_button)
	if _xterm_available():
		_term_button = Button.new()
		_term_button.text = "CLI"
		_term_button.icon = _svg_icon("cli.svg")
		_tint_icon_button(_term_button)
		_term_button.toggle_mode = true
		_term_button.button_group = group
		_term_button.tooltip_text = "The chosen agent's full interactive CLI, running right here in the editor (GodotXterm)."
		_term_button.toggled.connect(_on_mode_toggled.bind("cli"))
		seg.add_child(_term_button)
		_compact_button_padding(_term_button)
		_style_mode_button(_term_button)
	_external_button = Button.new()
	_external_button.text = "External"
	_external_button.icon = _svg_icon("external.svg")
	_tint_icon_button(_external_button)
	_external_button.toggle_mode = true
	_external_button.button_group = group
	_external_button.toggled.connect(_on_mode_toggled.bind("external"))
	seg.add_child(_external_button)
	_compact_button_padding(_external_button)
	_style_mode_button(_external_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_row.add_child(spacer)

	_new_session_button = Button.new()
	_new_session_button.icon = editor_theme.get_icon("Reload", "EditorIcons")
	_new_session_button.flat = true
	_new_session_button.pressed.connect(_on_new_session_pressed)
	button_row.add_child(_new_session_button)
	_update_refresh_tooltip("chat")

	_settings_button = Button.new()
	_settings_button.icon = _svg_icon("cog.svg")
	_tint_icon_button(_settings_button)
	_settings_button.tooltip_text = "Settings"
	_settings_button.flat = true
	_settings_button.pressed.connect(_on_settings_pressed)
	button_row.add_child(_settings_button)

	_build_settings_popup()

	_build_session_ui()
	_restore_conversation()
	_update_agent_button()

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

## Which of the known CLIs are on PATH (`which`, or `command -v` on macOS).
## Only those are offered; if none are, everything stays visible so the
## install tooltips explain what to get.
func _detect_clis() -> void:
	_installed.clear()
	for cli in _CLIS:
		_installed[cli.id] = _has_command(cli.bin)

func _any_installed() -> bool:
	return _installed.values().has(true)

func _refresh_status() -> void:
	_detect_clis()
	_term_emulator_found = not _find_terminal().is_empty() or OS.get_name() in ["Windows", "macOS"]
	_update_mode_buttons()

## Chat only exists for some agents, and External needs the CLI plus a
## terminal emulator; keep the three mode buttons honest about that.
func _update_mode_buttons() -> void:
	var agent := _preferred_assistant()
	var name := _cli_name(agent)
	var can_chat := agent in _CHAT_AGENTS
	_chat_button.disabled = not can_chat
	_chat_button.tooltip_text = "The chat view." if can_chat else "%s has no chat view yet — use CLI or External." % name
	if not can_chat and _chat_button.button_pressed:
		if _term_button:
			_term_button.button_pressed = true
		elif not _external_button.disabled:
			_external_button.button_pressed = true
	var cli := _cli_info(agent)
	if not _installed.get(agent, false):
		_external_button.disabled = true
		_external_button.tooltip_text = "%s CLI (`%s`) not found on PATH. Install it first: %s — then reopen this panel." % [name, cli.get("bin", agent), cli.get("url", "")]
	elif not _term_emulator_found:
		_external_button.disabled = true
		_external_button.tooltip_text = (
			"%s found, but no supported terminal emulator was detected on PATH (tried " +
			"$TERMINAL, alacritty, kitty, foot, ghostty, gnome-terminal, konsole, xfce4-terminal, xterm)."
		) % name
	else:
		_external_button.disabled = false
		_external_button.tooltip_text = "Open %s in a separate terminal window, in this project (and shrink this panel). Switch away and back to open another." % name

func _on_external_pressed() -> void:
	_on_open_cli_pressed(_preferred_assistant())

func _build_allowed_tools() -> Array:
	var allowed := ["mcp__godot-live-mcp__*"]
	if _file_control_toggle.button_pressed:
		allowed.append_array(["Read", "Write", "Edit"])
	if _terminal_toggle.button_pressed:
		allowed.append("Bash")
	if _web_toggle.button_pressed:
		allowed.append_array(["WebFetch", "WebSearch"])
	return allowed

# ---- Agent / model menu (header) ----

## "Claude · Sonnet 5.5" on the header button.
func _update_agent_button() -> void:
	if _agent_button == null or _agent_label == null:
		return
	var agent := _preferred_assistant()
	var model := _current_setting(agent, "model")
	var short := "default"
	if model != "":
		short = _choice_label(agent, model)
		short = short.get_slice(" (", 0)
		short = short.get_slice("/", short.get_slice_count("/") - 1)
	_agent_label.text = "%s · %s" % [_cli_name(agent), short]
	var effort := _current_setting(agent, "effort")
	var tip := "Agent: %s\nModel: %s\nEffort: %s" % [
		_cli_name(agent), model if model != "" else "the CLI's default", effort if effort != "" else "the CLI's default"]
	_agent_label.tooltip_text = tip
	_agent_button.tooltip_text = tip + "\n(click to change)"
	_agent_label.mouse_filter = Control.MOUSE_FILTER_STOP

## Rebuilt each time it opens, since the model lists are dynamic.
func _rebuild_agent_menu() -> void:
	var menu := _agent_button.get_popup()
	var agent := _preferred_assistant()
	menu.clear()
	var agents := _all_agents()
	for i in agents.size():
		menu.add_radio_check_item(_cli_name(agents[i]), i)
		menu.set_item_checked(menu.get_item_index(i), agents[i] == agent)
		menu.set_item_metadata(menu.get_item_index(i), agents[i])
	menu.add_separator()
	if agent == "gemini":
		menu.add_item("Gemini uses its own model settings", 100)
		menu.set_item_disabled(menu.get_item_index(100), true)
		return
	for pair in [["model", _agent_model_menu, "Model"], ["effort", _agent_effort_menu, "Effort"]]:
		var what: String = pair[0]
		var sub: PopupMenu = pair[1]
		sub.clear()
		var override := String(_meta(what + "_" + agent, ""))
		var default_value := _cli_default(agent, what)
		sub.add_radio_check_item("Default (%s)" % (default_value if default_value != "" else "the CLI's own"), 0)
		sub.set_item_metadata(0, "default")
		sub.set_item_checked(0, override == "")
		var choices := _choices(agent, what)
		if override != "" and not choices.has(override):
			choices.append(override)  # a typed-in value not in the list
		for c in choices:
			sub.add_radio_check_item(_choice_label(agent, c))
			var idx := sub.item_count - 1
			sub.set_item_metadata(idx, c)
			sub.set_item_checked(idx, c == override)
		menu.add_submenu_node_item("%s…" % pair[2], sub)

func _on_agent_menu_id(id: int) -> void:
	var menu := _agent_button.get_popup()
	_choose_agent(String(menu.get_item_metadata(menu.get_item_index(id))))

## The choice is authoritative: end whatever process is running; the next
## message goes to the chosen agent, resuming its own saved session if it has
## one (the others keep theirs for switching back).
func _choose_agent(agent: String) -> void:
	if agent == _preferred_assistant():
		return
	_set_meta(_ASSISTANT_SETTING, agent)
	if _session_active:
		_stop_session("")
	_load_thread()
	if _term_running and _term_agent != _preferred_assistant():
		_restart_terminal()
	_update_agent_button()
	_update_mode_buttons()
	_append_transcript("%s [i]— your next message goes to it%s.[/i]" % [
		_agent_line(), " (resuming its saved session)" if _has_resumable() else " (new session)"])

func _choose_model(value: String) -> void:
	_set_model(_preferred_assistant(), value)

func _choose_effort(value: String) -> void:
	_effort_command(_preferred_assistant(), value)

func _update_refresh_tooltip(mode: String) -> void:
	_new_session_button.disabled = mode == "external"
	_new_session_button.tooltip_text = {
		"chat": "New session: end the current session; your next message starts a fresh one (and picks up a rebuilt MCP server).",
		"cli": "Restart the CLI (picks up a changed model, effort, permissions and preferences).",
		"external": "Nothing to restart here: the session is in its own terminal window.",
	}[mode]

## Terminal CLIs the header can open. Detection is just `which <bin>`; the
## only per-tool work is handing it this project's MCP server + token, which
## every CLI configures differently (see the _launch_* functions). To add
## one: an entry here, a _launch_<id> function, and a case in
## _on_open_cli_pressed.
const _CLIS := [
	{"id": "claude", "bin": "claude", "name": "Claude Code", "button": "Claude", "url": "https://docs.claude.com/en/docs/claude-code"},
	{"id": "codex", "bin": "codex", "name": "Codex", "button": "Codex", "url": "https://github.com/openai/codex"},
	{"id": "opencode", "bin": "opencode", "name": "OpenCode", "button": "OpenCode", "url": "https://opencode.ai"},
	{"id": "gemini", "bin": "gemini", "name": "Gemini CLI", "button": "Gemini", "url": "https://github.com/google-gemini/gemini-cli"},
]

## Agents whose in-panel chat runs one process per message (see _thread_id).
const _TURN_AGENTS := ["codex", "opencode"]

func _cli_info(id: String) -> Dictionary:
	for cli in _CLIS:
		if cli.id == id:
			return cli
	return {}

## Agents with an in-panel chat view (the others are terminal-only).
const _CHAT_AGENTS := ["claude", "codex", "opencode"]

func _cli_name(id: String) -> String:
	for cli in _CLIS:
		if cli.id == id:
			return cli.button
	return id.capitalize()

## The agent the panel is talking to: always the one chosen in settings.
func _active_agent() -> String:
	return _preferred_assistant()

## Each turn-based agent keeps its own resumable thread id (project
## metadata "thread_<agent>"), so switching agents and back resumes.
func _set_thread(agent: String, id: String) -> void:
	_thread_agent = agent
	_thread_id = id
	if agent != "":
		_set_meta("thread_" + agent, id)

## Loads the chosen agent's saved thread (empty for Claude, which has its own
## _claude_session_id, or when it has none yet).
func _load_thread() -> void:
	var agent := _preferred_assistant()
	_thread_agent = agent if agent in _TURN_AGENTS else ""
	_thread_id = String(_meta("thread_" + agent)) if _thread_agent != "" else ""

## True if the chosen agent has a saved session the next message would resume.
func _has_resumable() -> bool:
	return not _claude_session_id.is_empty() if _preferred_assistant() == "claude" else not _thread_id.is_empty()

func _on_open_cli_pressed(id: String) -> void:
	var spec := _launch_spec(id)
	_launch_in_terminal(spec.cli, spec.args, spec.env)

## What to run for a CLI's full interactive session in this project:
## {cli, args, env}. Used by the external-terminal buttons and by the
## embedded terminal view.
func _launch_spec(id: String) -> Dictionary:
	match id:
		"claude": return _spec_claude()
		"codex": return _spec_codex()
		"opencode": return _spec_opencode()
		_: return _spec_gemini()

func _spec_claude() -> Dictionary:
	# --mcp-config is variadic, so it goes last.
	return {"cli": "claude", "env": {}, "args": _model_args("claude") + _behavior_args() + _mcp_config_args(func(msg): _append_transcript("[color=yellow]%s[/color]" % msg))}

## Codex reads AGENTS.md (linked to CLAUDE.md by link-project) and takes the
## same server + project token and the settings popup's preferences through
## -c config overrides (values are TOML; JSON-quoted strings are valid TOML).
func _spec_codex() -> Dictionary:
	var args := _model_args("codex") + ["-c", "developer_instructions=" + JSON.stringify(_behavior_text())]
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if not entry.is_empty() and not token.is_empty():
		args += [
			"-c", 'mcp_servers.godot-live-mcp.command="node"',
			"-c", "mcp_servers.godot-live-mcp.args=[%s]" % JSON.stringify(entry),
			"-c", "mcp_servers.godot-live-mcp.env.GODOT_LIVE_MCP_TOKEN=%s" % JSON.stringify(token),
			"-c", "mcp_servers.godot-live-mcp.env.GODOT_LIVE_MCP_TOOL_DATA=%s" % JSON.stringify(_server_env(token).GODOT_LIVE_MCP_TOOL_DATA),
		]
	else:
		_append_transcript("[color=yellow]Couldn't find this project's server/token — Codex will use its own godot-live-mcp registration, if any.[/color]")
	# Godot control is always granted in this panel (like Claude's
	# mcp__godot-live-mcp__*); without this Codex asks per MCP tool call.
	args += ["-c", 'mcp_servers.godot-live-mcp.default_tools_approval_mode="approve"']
	return {"cli": "codex", "args": args, "env": {}}

## OpenCode reads AGENTS.md too, and takes its config as inline JSON in
## OPENCODE_CONFIG_CONTENT (merged over its own; confirmed live): this
## project's server + token, the panel's preferences as an instructions file,
## and — for in-panel chat only, where no approval prompt can be shown — the
## permission checkboxes as allow/deny (a denied tool is removed; confirmed).
## Returns "" if the server or token can't be found (OpenCode then uses its
## own godot-live-mcp registration, if any).
func _opencode_config(with_permissions: bool) -> String:
	var cfg := {}
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if entry.is_empty() or token.is_empty():
		_append_transcript("[color=yellow]Couldn't find this project's server/token — OpenCode will use its own godot-live-mcp registration, if any.[/color]")
	else:
		cfg["mcp"] = {"godot-live-mcp": {
			"type": "local", "command": ["node", entry], "environment": _server_env(token), "enabled": true}}
	var instructions_path := ProjectSettings.globalize_path("user://godot_live_mcp_opencode_instructions.md")
	var f := FileAccess.open(instructions_path, FileAccess.WRITE)
	if f:
		f.store_string(_behavior_text() + "\n")
		f.close()
		cfg["instructions"] = [instructions_path]
	if with_permissions:
		cfg["permission"] = {
			"edit": "allow" if _file_control_toggle.button_pressed else "deny",
			"bash": "allow" if _terminal_toggle.button_pressed else "deny",
			"webfetch": "allow" if _web_toggle.button_pressed else "deny",
		}
	return JSON.stringify(cfg)

func _spec_opencode() -> Dictionary:
	# The interactive UI takes -m but not `run`'s --variant, so only the model.
	var model := String(EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", "model_opencode", ""))
	return {"cli": "opencode", "args": ["-m", model] if model != "" else [], "env": {"OPENCODE_CONFIG_CONTENT": _opencode_config(false)}}

## Gemini CLI has no inline MCP config (its system-settings override must be
## root-owned), so the server + token go into the project's own
## .gemini/settings.json, merged into whatever is already there. That file
## holds the bridge token (localhost-only) — gitignore it if the project is
## shared. --skip-trust trusts this folder for the session; otherwise Gemini
## disables project MCP servers in untrusted folders. Model and permission
## settings from this panel aren't mapped for it.
func _spec_gemini() -> Dictionary:
	var entry := _resolve_server_entry()
	var token := _read_bridge_token()
	if not entry.is_empty() and not token.is_empty():
		var path := ProjectSettings.globalize_path("res://.gemini/settings.json")
		var cfg = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else {}
		if not (cfg is Dictionary):
			_append_transcript("[color=yellow]%s isn't valid JSON — left alone; Gemini will use its own godot-live-mcp registration, if any.[/color]" % path.xml_escape())
		else:
			if not (cfg.get("mcpServers") is Dictionary):
				cfg["mcpServers"] = {}
			cfg["mcpServers"]["godot-live-mcp"] = {
				"command": "node", "args": [entry], "env": _server_env(token), "trust": true}
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify(cfg, "  ") + "\n")
	else:
		_append_transcript("[color=yellow]Couldn't find this project's server/token — Gemini will use its own godot-live-mcp registration, if any.[/color]")
	return {"cli": "gemini", "args": ["--skip-trust"], "env": {}}

## `env` is extra environment variables for the CLI (set inline in the
## launch command, since a new terminal window doesn't inherit ours).
func _launch_in_terminal(cli: String, cli_args: Array, env: Dictionary = {}) -> void:
	var project_dir := ProjectSettings.globalize_path("res://")

	var env_prefix := ""
	if not env.is_empty():
		env_prefix = "env"
		for k in env:
			env_prefix += " " + _shell_quote("%s=%s" % [k, env[k]])
		env_prefix += " "

	if OS.get_name() == "Windows":
		# OS.create_process's open_console is a real native console window
		# on Windows; no terminal-emulator detection needed there. The child
		# inherits our environment, so set it here.
		for k in env:
			OS.set_environment(k, String(env[k]))
		OS.create_process(cli, cli_args, true)
		return

	if OS.get_name() == "macOS":
		# Terminal.app runs the command in the user's own interactive
		# shell, so PATH is already right there.
		var mac_cmd := "cd %s && %s%s" % [_shell_quote(project_dir), env_prefix, cli]
		for arg in cli_args:
			mac_cmd += " " + _shell_quote(arg)
		var script := mac_cmd.replace("\\", "\\\\").replace("\"", "\\\"")
		OS.create_process("osascript", [
			"-e", 'tell application "Terminal" to do script "%s"' % script,
			"-e", 'tell application "Terminal" to activate'])
		return

	var term := _find_terminal()
	if term.is_empty():
		_refresh_status()  # re-check in case something changed since panel opened
		return

	var shell_cmd := "cd %s && %s%s" % [_shell_quote(project_dir), env_prefix, cli]
	for arg in cli_args:
		shell_cmd += " " + _shell_quote(arg)

	match term.style:
		"xdg":
			if env.is_empty():
				OS.create_process(term.bin, ["--dir=%s" % project_dir, "--", cli] + cli_args)
			else:
				OS.create_process(term.bin, ["--dir=%s" % project_dir, "--", "bash", "-lc", shell_cmd])
		"direct":
			# No native workdir flag — same shell `cd` fallback as flag_e/
			# dashdash below, just without a leading terminal-specific flag.
			OS.create_process(term.bin, ["bash", "-lc", shell_cmd])
		"flag_e":
			OS.create_process(term.bin, ["-e", "bash", "-lc", shell_cmd])
		"dashdash":
			OS.create_process(term.bin, ["--", "bash", "-lc", shell_cmd])

func _find_terminal() -> Dictionary:
	if OS.get_name() == "macOS":
		return {}  # Terminal.app via osascript, see _launch_in_terminal
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

## Shortcut names as the user sees them: Cmd rather than Ctrl on macOS.
func _mac_keys(text: String) -> String:
	return text.replace("Ctrl+", "Cmd+") if OS.get_name() == "macOS" else text

## [program, args] running `cmd` in a login shell, so CLIs installed via
## version managers or per-user installers are on PATH.
func _login_shell(cmd: String) -> Array:
	if OS.get_name() == "macOS":
		return ["zsh", ["-lc", _MAC_PATH_PREFIX + cmd]]
	return ["bash", ["-lc", cmd]]

func _has_command(bin_name: String) -> bool:
	if bin_name.is_empty():
		return false
	var output: Array = []
	var code: int
	if OS.get_name() == "macOS":
		var sh := _login_shell("command -v " + _shell_quote(bin_name))
		code = OS.execute(sh[0], sh[1], output)
	else:
		code = OS.execute("which", [bin_name], output)
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
## Opt-in (off by default): usage logging for tool-candidate review.
func _tool_data_enabled() -> bool:
	return EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", _TOOL_DATA_SETTING, false)

## Environment for the MCP server process: this project's bridge token and
## whether usage data is collected (see server/src/callLog.ts).
func _server_env(token: String) -> Dictionary:
	return {"GODOT_LIVE_MCP_TOKEN": token, "GODOT_LIVE_MCP_TOOL_DATA": "on" if _tool_data_enabled() else "off"}

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
		"env": _server_env(token),
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
	var signature := "%s|%s|%s" % [entry, token, _tool_data_enabled()]
	var editor_settings := EditorInterface.get_editor_settings()
	if editor_settings.get_project_metadata("godot_live_mcp", "local_registration", "") == signature:
		return

	var add_cmd := "claude mcp add -s local godot-live-mcp -e %s -e %s -- node %s" % [
		_shell_quote("GODOT_LIVE_MCP_TOKEN=" + token),
		_shell_quote("GODOT_LIVE_MCP_TOOL_DATA=" + _server_env(token).GODOT_LIVE_MCP_TOOL_DATA),
		_shell_quote(entry)
	]
	var shell_cmd := "cd %s && { claude mcp remove -s local godot-live-mcp >/dev/null 2>&1; %s; }" % [
		_shell_quote(ProjectSettings.globalize_path("res://")), add_cmd
	]
	var output: Array = []
	var sh := _login_shell(shell_cmd)
	if OS.execute(sh[0], sh[1], output, true) != 0:
		_append_transcript("[color=yellow]Couldn't register godot-live-mcp for this project with Claude Code: %s[/color]" % "".join(output).strip_edges())
		return
	editor_settings.set_project_metadata("godot_live_mcp", "local_registration", signature)
	_append_transcript("[i]Registered godot-live-mcp for this project folder — any `claude` session started here can now control this editor.[/i]")

func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"

## One of the optional broader grants, each mapped to a real --allowedTools
## group — confirmed live: --allowedTools is ADDITIVE (a disallowed Bash
## command still runs unless excluded via --permission-prompts none), and
## --permission-prompts none cleanly denies anything not granted here rather
## than hanging (the panel has no prompt UI). The same state drives the
## in-editor session and the external-terminal launch. On by default; the
## choice is remembered per project and applies from the next message (the
## process restarts and resumes the conversation).
func _make_permission_check(label: String, tip: String, parent: Control) -> CheckBox:
	var b := CheckBox.new()
	b.text = label
	b.tooltip_text = tip
	var key := "permission_" + label.to_snake_case()
	b.button_pressed = EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", key, true)
	b.toggled.connect(func(on: bool):
		EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", key, on)
		_apply_on_next_message("%s permission %s" % [label, "granted" if on else "revoked"]))
	parent.add_child(b)
	return b

# ---- Embedded terminal (GodotXterm) ----

## The full interactive CLI inside the editor, via the optional GodotXterm
## addon (github.com/lihop/godot-xterm: a Terminal control + a PTY node that
## runs a process in a pseudo-terminal). Used only if its classes are
## registered, and created through ClassDB so nothing fails to parse when it
## isn't installed. Linux/macOS (the panel launches CLIs through a login shell).
func _xterm_available() -> bool:
	return OS.get_name() in ["Linux", "macOS"] and ClassDB.class_exists("Terminal") and ClassDB.class_exists("PTY")

func _build_term_view() -> void:
	if not _xterm_available():
		return
	_term_view = VBoxContainer.new()
	_term_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_term_view.visible = false
	add_child(_term_view)

	_term_holder = Control.new()
	_term_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_term_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_term_holder.custom_minimum_size = Vector2(0, 160)
	_term_view.add_child(_term_holder)

	_term = ClassDB.instantiate("Terminal")
	_term.set_anchors_preset(Control.PRESET_FULL_RECT)
	_term_holder.add_child(_term)

	_style_terminal()
	_term.data_sent.connect(func(data): if _pty: _pty.write(data))
	_term.size_changed.connect(func(size: Vector2i): if _pty: _pty.resizev(size))
	_make_pty()

## What a CLI session was launched with: the agent, its model and effort, the
## permissions and the preferences. A running CLI only reads these at launch,
## so when they differ from the current ones it is stale.
func _term_signature() -> String:
	var a := _preferred_assistant()
	return "|".join([a, str(_meta("model_" + a, "")), str(_meta("effort_" + a, "")),
		str(_file_control_toggle.button_pressed), str(_terminal_toggle.button_pressed), str(_web_toggle.button_pressed),
		str(_meta(_TESTS_SETTING, false)), str(_meta(_SAVE_SETTING, true)), str(_tool_data_enabled())])

## Restarts a running CLI whose launch settings are out of date — straight away
## if it is on screen, otherwise when the CLI view is next opened.
func _sync_terminal_to_settings() -> void:
	if _term_running and _term_signature() != _term_signature_started and _term_view and _term_view.visible:
		_restart_terminal()

## A PTY can only be forked once (a second fork fails with EBUSY), so every
## CLI start gets a fresh node. GodotXterm leaves the wiring to the user.
func _make_pty() -> void:
	if _pty:
		_retire_pty(_pty)
	var pty: Node = ClassDB.instantiate("PTY")
	_pty = pty
	_term_view.add_child(pty)
	pty.data_received.connect(_term.write)
	# Ignore a replaced PTY's late "exited".
	pty.exited.connect(func(code: int, sig: int): if pty == _pty: _on_term_exited(code, sig))

## The selected button of the Chat | CLI | External toggle: orange background,
## black text and icon.
func _style_mode_button(b: Button) -> void:
	var orange := Color("#d97757")
	var black := Color(0.05, 0.05, 0.05)
	for state in [&"pressed", &"hover_pressed"]:
		var base := b.get_theme_stylebox(state)
		var flat: StyleBoxFlat
		if base is StyleBoxFlat:
			flat = base.duplicate()
		else:
			flat = StyleBoxFlat.new()
			flat.set_corner_radius_all(3)
			flat.content_margin_left = 8
			flat.content_margin_right = 8
		flat.bg_color = orange if state == &"pressed" else orange.lightened(0.12)
		b.add_theme_stylebox_override(state, flat)
	for item in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(item, black)

## Our icons are white; tint one to the editor theme's text colour so it
## reads on light themes too.
func _tint_icon_button(b: Button) -> void:
	var c := EditorInterface.get_editor_theme().get_color("font_color", "Editor")
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(state, c)
	b.add_theme_color_override("icon_disabled_color", Color(c.r, c.g, c.b, 0.4))

## The editor's code font and text-editor colours, as GodotXterm's own editor
## terminal does.
func _style_terminal() -> void:
	# A monospace font is essential: a proportional one looks letter-spaced on
	# the terminal's fixed grid. The editor theme's "source" font is its code font.
	var theme := EditorInterface.get_editor_theme()
	var font: Font = theme.get_font("source", "EditorFonts") if theme.has_font("source", "EditorFonts") else null
	if font == null:
		var bundled := "res://addons/godot_xterm/themes/fonts/regular.tres"
		if ResourceLoader.exists(bundled):
			font = load(bundled)
	if font:
		for item in ["normal_font", "bold_font", "italics_font", "bold_italics_font"]:
			_term.add_theme_font_override(item, font)
	# The Terminal sizes its cells from its theme's default font size — the
	# *_font_size overrides GodotXterm's own editor terminal sets have no effect
	# here (checked: cell size stayed put) — so give it a small theme of its own.
	var size := _term_font_size()
	if size > 0:
		var term_theme := Theme.new()
		term_theme.default_font_size = size
		_term.theme = term_theme
	else:
		_term.theme = null
	_apply_term_scheme(String(_meta("term_scheme", _TERM_SCHEME_DEFAULT)))

## The chosen font size, else the editor's code font size (0 if unknown).
func _term_font_size() -> int:
	var chosen := int(_meta("term_font_size", 0))
	if chosen > 0:
		return chosen
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("interface/editor/code_font_size") and es.get_setting("interface/editor/code_font_size") is int:
		return es.get_setting("interface/editor/code_font_size")
	var theme := EditorInterface.get_editor_theme()
	return theme.get_font_size("source_size", "EditorFonts") if theme.has_font_size("source_size", "EditorFonts") else 0

const _TERM_SCHEME_DEFAULT := "Editor theme"
# name -> [background, foreground, the 16 ANSI colours (8 normal, 8 bright)]
const _TERM_SCHEMES := {
	"One Dark": ["#282c34", "#abb2bf", ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf", "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]],
	"Dracula": ["#282a36", "#f8f8f2", ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2", "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]],
	"Nord": ["#2e3440", "#d8dee9", ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0", "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]],
	"Gruvbox Dark": ["#282828", "#ebdbb2", ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984", "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]],
	"Monokai": ["#272822", "#f8f8f2", ["#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2", "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"]],
	"Solarized Dark": ["#002b36", "#839496", ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]],
	"Solarized Light": ["#fdf6e3", "#657b83", ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]],
	"Light": ["#ffffff", "#24292e", ["#24292e", "#d73a49", "#22863a", "#b08800", "#0366d6", "#6f42c1", "#1b7c83", "#6a737d", "#959da5", "#cb2431", "#28a745", "#dbab09", "#2188ff", "#8a63d2", "#3192aa", "#d1d5da"]],
}

## "Editor theme" derives the colours from the editor's text-editor theme
## (as GodotXterm's own editor terminal does); the others are fixed palettes.
func _apply_term_scheme(scheme: String) -> void:
	var colors := {}
	if _TERM_SCHEMES.has(scheme):
		var def: Array = _TERM_SCHEMES[scheme]
		colors["background_color"] = Color(def[0])
		colors["foreground_color"] = Color(def[1])
		for i in 16:
			colors["ansi_%d_color" % i] = Color(def[2][i])
	else:
		var es := EditorInterface.get_editor_settings()
		var map := {
			"background_color": "background_color", "foreground_color": "text_color",
			"ansi_0_color": "caret_background_color", "ansi_1_color": "brace_mismatch_color",
			"ansi_2_color": "gdscript/node_reference_color", "ansi_3_color": "executing_line_color",
			"ansi_4_color": "bookmark_color", "ansi_5_color": "control_flow_keyword_color",
			"ansi_6_color": "engine_type_color", "ansi_7_color": "comment_color",
			"ansi_8_color": "completion_background_color", "ansi_9_color": "keyword_color",
			"ansi_10_color": "base_type_color", "ansi_11_color": "string_color",
			"ansi_12_color": "function_color", "ansi_13_color": "gdscript/global_function_color",
			"ansi_14_color": "gdscript/function_definition_color", "ansi_15_color": "caret_color",
		}
		for key in map:
			var setting := "text_editor/theme/highlighting/%s" % map[key]
			if es.has_setting(setting) and es.get_setting(setting) is Color:
				colors[key] = es.get_setting(setting)
	for key in ["background_color", "foreground_color"] + range(16).map(func(i): return "ansi_%d_color" % i):
		if colors.has(key):
			_term.add_theme_color_override(key, colors[key])
		else:
			_term.remove_theme_color_override(key)

## The Terminal section of the Settings popup: font size and colour scheme.
func _build_term_settings(parent: Control) -> void:
	var bold: Font = EditorInterface.get_editor_theme().get_font("bold", "EditorFonts")
	var head := Label.new()
	head.text = "Terminal"
	head.add_theme_font_override("font", bold)
	parent.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	parent.add_child(grid)
	var l1 := Label.new()
	l1.text = "Font size"
	grid.add_child(l1)
	_term_size_spin = SpinBox.new()
	_term_size_spin.min_value = 6
	_term_size_spin.max_value = 40
	_term_size_spin.step = 1
	_term_size_spin.value_changed.connect(func(v: float):
		_set_meta("term_font_size", int(v))
		_style_terminal())
	grid.add_child(_term_size_spin)
	var l2 := Label.new()
	l2.text = "Colour scheme"
	grid.add_child(l2)
	_term_scheme_option = OptionButton.new()
	_term_scheme_option.add_item(_TERM_SCHEME_DEFAULT)
	for name in _TERM_SCHEMES:
		_term_scheme_option.add_item(name)
	_term_scheme_option.item_selected.connect(func(i: int):
		_set_meta("term_scheme", _term_scheme_option.get_item_text(i))
		_style_terminal())
	grid.add_child(_term_scheme_option)
	var reset := Button.new()
	reset.text = "Reset to editor defaults"
	reset.pressed.connect(func():
		_set_meta("term_font_size", 0)
		_set_meta("term_scheme", _TERM_SCHEME_DEFAULT)
		_style_terminal()
		_sync_term_settings_controls())
	parent.add_child(reset)

func _sync_term_settings_controls() -> void:
	_term_size_spin.set_value_no_signal(_term_font_size())
	var scheme := String(_meta("term_scheme", _TERM_SCHEME_DEFAULT))
	for i in _term_scheme_option.item_count:
		if _term_scheme_option.get_item_text(i) == scheme:
			_term_scheme_option.select(i)

func _on_mode_toggled(on: bool, mode: String) -> void:
	if not on:
		return
	_mode = mode
	_update_refresh_tooltip(mode)
	_chat_view.visible = mode == "chat"
	if _term_view:
		_term_view.visible = mode == "cli"
	if mode == "external":
		_on_external_pressed()
		_compact_panel(true)
		return
	_compact_panel(false)
	if mode == "cli":
		await get_tree().process_frame  # let the layout give the terminal its size
		if _term_running and _term_signature() != _term_signature_started:
			_stop_terminal()  # launched with other settings than the current ones
		if not _term_running:
			_start_terminal()
		_term.grab_focus()

## External mode has nothing below the header, so the panel gives its height
## back: move the editor's viewport/bottom-dock splitter, and restore it when
## leaving (and at shutdown, so a closed editor doesn't remember the small size).
func _bottom_split() -> SplitContainer:
	var n := get_parent()
	while n and not (n is SplitContainer):
		n = n.get_parent()
	return n as SplitContainer

func _compact_panel(on: bool) -> void:
	var split := _bottom_split()
	if split == null:
		return
	if on:
		if not _split_saved:
			_split_saved = true
			_split_saved_offset = split.split_offset
		await get_tree().process_frame  # let the hidden views drop out of the minimum size
		var dock := get_parent().get_parent() as Control
		var wanted := int(dock.get_combined_minimum_size().y) if dock else 90
		split.split_offset = -maxi(wanted, 60)
	elif _split_saved:
		split.split_offset = _split_saved_offset
		_split_saved = false

func _start_terminal() -> void:
	var agent := _preferred_assistant()
	var cli_name := _cli_name(agent)
	if not _installed.get(agent, false):
		_term.write("%s isn't installed (not found on PATH).\r\n" % cli_name)
		return
	var spec := _launch_spec(agent)
	var cmd := "exec "
	if not spec.env.is_empty():
		cmd += "env"
		for k in spec.env:
			cmd += " " + _shell_quote("%s=%s" % [k, spec.env[k]])
		cmd += " "
	cmd += spec.cli
	for a in spec.args:
		cmd += " " + _shell_quote(String(a))
	var sh := _login_shell(cmd)
	_make_pty()
	_term.call("clear")
	var cols := maxi(int(_term.call("get_cols")), 20)
	var rows := maxi(int(_term.call("get_rows")), 5)
	var err: int = _pty.call("fork", sh[0], sh[1], ProjectSettings.globalize_path("res://"), cols, rows)
	if err != OK:
		_term.write("Couldn't start %s (error %d).\r\n" % [cli_name, err])
		_set_robot("angry")
		return
	_pty.set_meta("forked", true)
	_term_signature_started = _term_signature()
	_term_running = true
	_term_agent = agent

## Stops the CLI the way closing a terminal window would (SIGHUP), so it can
## shut down cleanly — Claude Code otherwise opens its next session with a
## "didn't finish starting last time" warning. A process that ignores that
## gets SIGKILL after two seconds.
func _stop_terminal() -> void:
	if _term_running and _pty:
		_pty.call("kill", ClassDB.class_get_integer_constant("PTY", "IPCSIGNAL_SIGHUP"))
		_retire_pty(_pty)
	_term_running = false

## Keeps a stopped PTY node alive just long enough to see its process exit
## (or to SIGKILL it), then frees it.
func _retire_pty(pty: Node) -> void:
	if pty.has_meta("retired"):
		return
	pty.set_meta("retired", true)
	if not pty.has_meta("forked"):
		pty.queue_free()
		return
	var state := {"done": false}
	# Weak reference: the node is freed once its process exits, and a lambda
	# that captures a freed object errors when called.
	var ref: WeakRef = weakref(pty)
	pty.connect("exited", func(_code: int, _sig: int):
		state.done = true
		var p = ref.get_ref()
		if p:
			p.queue_free())
	get_tree().create_timer(2.0).timeout.connect(func():
		var p = ref.get_ref()
		if p and not state.done:
			p.call("kill", ClassDB.class_get_integer_constant("PTY", "IPCSIGNAL_SIGKILL"))
			p.queue_free())

func _restart_terminal() -> void:
	_stop_terminal()
	if _term_view and _term_view.visible:
		_start_terminal()
		_term.grab_focus()

func _on_term_exited(_exit_code: int, _signum: int) -> void:
	_term_running = false
	_term.write("\r\n[process exited — press the refresh icon for a new one]\r\n")

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
	_chat_view = splitter
	_build_term_view()

	_send_button = Button.new()
	_send_button.icon = _svg_icon("send.svg")
	_send_button.tooltip_text = "Send (Enter)"
	_send_button.custom_minimum_size.x = 48 * EditorInterface.get_editor_scale()
	_style_button(_send_button, Color(0.22, 0.6, 0.28))
	_send_button.pressed.connect(_on_send_pressed.bind(""))
	input_row.add_child(_send_button)

	_stop_button = Button.new()
	_stop_button.icon = _svg_icon("stop_hand.svg")
	_stop_button.tooltip_text = "Stop the current reply (the session is kept)"
	_stop_button.custom_minimum_size.x = 36 * EditorInterface.get_editor_scale()
	_style_button(_stop_button, Color(0.75, 0.2, 0.2))
	_stop_button.pressed.connect(_on_stop_pressed)
	input_row.add_child(_stop_button)

## An icon from this addon's icons/ folder, rasterized from the SVG directly
## (no import step, so it works the moment a project links the addon).
func _svg_icon(file_name: String, scale_mult: float = 1.0) -> Texture2D:
	var svg := FileAccess.get_file_as_string("res://addons/godot_live_mcp/icons/" + file_name)
	if svg.is_empty():
		return null
	var img := Image.new()
	if img.load_svg_from_string(svg, EditorInterface.get_editor_scale() * scale_mult) != OK:
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
## its context carry on); a Codex or OpenCode turn is its own process, so it's ended and
## the next message resumes the same thread.
func _on_stop_pressed() -> void:
	if not _session_active:
		return
	if _session_kind != "claude":
		if _pipe.has("pid") and OS.is_process_running(_pipe.pid):
			OS.kill(_pipe.pid)
		_stop_session("Stopped.")
		_set_robot("angry")
		return
	if _pipe.has("stdio") and _pipe.stdio:
		_pipe.stdio.store_string(JSON.stringify({
			"type": "control_request",
			"request_id": "stop-%d" % Time.get_ticks_msec(),
			"request": {"subtype": "interrupt"},
		}) + "\n")
		_append_transcript("[i]Stopped.[/i]")
		_clear_busy("chat")
		_set_robot("angry")

## Called by plugin.gd's _exit_tree so a running `claude` subprocess doesn't
## leak past a plugin reload/disable — reload_plugin (used constantly while
## developing this addon) would otherwise orphan one every time.
func shutdown() -> void:
	if _session_active:
		_stop_session("")
	if _pty:
		_stop_terminal()
	if _split_saved:
		var split := _bottom_split()
		if split:
			split.split_offset = _split_saved_offset
		_split_saved = false

## The panel runs the CLIs non-interactively, so their own slash commands
## (/model, /clear, ...) don't exist here. /model is handled by the panel;
## anything else points at the full terminal session.
func _handle_slash_command(text: String) -> void:
	var agent := _active_agent()
	var parts := text.split(" ", false, 1)
	if parts[0] == "/effort":
		_effort_command(agent, parts[1].strip_edges() if parts.size() > 1 else "")
		return
	if parts[0] == "/compact":
		_compact_command(agent, parts[1].strip_edges() if parts.size() > 1 else "")
		return
	if parts[0] != "/model":
		_append_transcript("[i]%s isn't available in the panel — use Open %s for the full terminal session. The panel handles /model, /effort and /compact; New session (refresh icon) replaces /clear.[/i]" % [
			parts[0].xml_escape(), _cli_name(agent)])
		return
	if parts.size() == 1:
		_show_choice_menu(agent, "model")
		return
	_set_model(agent, parts[1].strip_edges())

## /compact [instructions]: summarize the Claude conversation to free context.
## Sent to the running process as a normal user message (confirmed to work in
## stream-json mode); resumes the stored session first if none is running.
func _compact_command(agent: String, instructions: String) -> void:
	if agent != "claude":
		_append_transcript("[i]/compact isn't available for %s.[/i]" % _cli_name(agent))
		return
	if not _session_active and _claude_session_id.is_empty():
		_append_transcript("[i]Nothing to compact yet — no session.[/i]")
		return
	if not _session_active and not _start_session():
		return
	_append_transcript("[i]Compacting the session…[/i]")
	_pipe.stdio.store_string(JSON.stringify({
		"type": "user",
		"message": {"role": "user", "content": [{"type": "text", "text": ("/compact " + instructions).strip_edges()}]},
	}) + "\n")

func _set_model(agent: String, model: String) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(
		"godot_live_mcp", "model_" + agent, "" if model == "default" else model)
	if agent != "claude":
		_append_transcript("[i]%s model set to %s — used from your next message.[/i]" % [_cli_name(agent), model.xml_escape()])
	else:
		# The model is fixed at launch; restarting resumes the same conversation.
		_apply_on_next_message("Claude model set to %s" % model.xml_escape())
	_update_agent_button()
	_sync_terminal_to_settings()

## /effort [level]: reasoning effort per agent, saved per project, like /model.
## Codex: model_reasoning_effort (e.g. minimal, low, medium, high); Claude:
## --effort (e.g. low, medium, high); OpenCode: --variant (provider-specific,
## e.g. minimal, high, max). Empty = the CLI's own setting.
func _effort_command(agent: String, level: String) -> void:
	if level == "":
		_show_choice_menu(agent, "effort")
		return
	EditorInterface.get_editor_settings().set_project_metadata(
		"godot_live_mcp", "effort_" + agent, "" if level == "default" else level)
	if agent != "claude":
		_append_transcript("[i]%s effort set to %s — used from your next message.[/i]" % [_cli_name(agent), level.xml_escape()])
	else:
		_apply_on_next_message("Claude effort set to %s" % level.xml_escape())
	_update_agent_button()
	_sync_terminal_to_settings()

# ---- /model and /effort pickers ----

## The CLI's own default (what it uses when the panel doesn't override it):
## Codex from ~/.codex/config.toml, Claude from ~/.claude/settings.json,
## OpenCode's model from ~/.config/opencode/opencode.json.
func _cli_default(agent: String, what: String) -> String:
	if agent == "gemini":
		return ""
	var home := _home_dir()
	if agent == "opencode":
		var cfg = JSON.parse_string(FileAccess.get_file_as_string(home.path_join(".config/opencode/opencode.json")))
		return String(cfg.get("model", "")) if cfg is Dictionary and what == "model" else ""
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
## effort levels) from its live catalog; Claude's models (see _claude_models)
## and effort levels.
func _choices(agent: String, what: String) -> Array:
	if agent == "gemini":
		return []
	if agent == "claude":
		return _claude_models().keys() if what == "model" else ["low", "medium", "high", "xhigh", "max"]
	if agent == "opencode":
		return _opencode_models() if what == "model" else ["minimal", "low", "medium", "high", "max"]
	var models := _codex_models()
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

# Pinned Claude models by exact ID, so the version shown is the version used.
# The `claude` CLI has no way to list models, so this is the one static part;
# _claude_models() puts the always-latest aliases and the account's own
# extra models (from Claude Code's cache) around it.
const _CLAUDE_MODELS := {
	"claude-fable-5-1": "Fable 5.1",
	"claude-opus-5-5": "Opus 5.5",
	"claude-sonnet-5-5": "Sonnet 5.5",
	"claude-haiku-4-5-20251001": "Haiku 4.5",
}
const _CLAUDE_ALIASES := {
	"fable": "Fable (latest)", "opus": "Opus (latest)",
	"sonnet": "Sonnet (latest)", "haiku": "Haiku (latest)",
}

func _home_dir() -> String:
	return OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")

## value -> label: aliases (always the newest model, nothing to maintain),
## then models Claude Code itself reports for this account
## (~/.claude.json additionalModelOptionsCache), then the pinned list.
func _claude_models() -> Dictionary:
	var out := {}
	for k in _CLAUDE_ALIASES:
		out[k] = _CLAUDE_ALIASES[k]
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(_home_dir().path_join(".claude.json")))
	if cfg is Dictionary and cfg.get("additionalModelOptionsCache") is Array:
		for m in cfg["additionalModelOptionsCache"]:
			if m is Dictionary and String(m.get("value", "")) != "":
				var v := String(m["value"])
				out[v] = String(m.get("description", m.get("label", v))).split(" · ")[0]
	for k in _CLAUDE_MODELS:
		if not out.has(k):
			out[k] = _CLAUDE_MODELS[k]
	return out

var _opencode_models_cache: Array = []
var _opencode_models_at := -1000000

## OpenCode's "provider/model" ids from `opencode models` (about a second for
## the full catalog, so kept for five minutes).
func _opencode_models() -> Array:
	if Time.get_ticks_msec() - _opencode_models_at < 300000 and not _opencode_models_cache.is_empty():
		return _opencode_models_cache
	var models := []
	if _installed.get("opencode", false):
		var sh := _login_shell("opencode models")
		var output := []
		if OS.execute(sh[0], sh[1], output, false) == 0 and not output.is_empty():
			for line in String(output[0]).split("\n", false):
				if line.strip_edges().contains("/"):
					models.append(line.strip_edges())
	_opencode_models_cache = models
	_opencode_models_at = Time.get_ticks_msec()
	return models

var _codex_models_cache: Array = []
var _codex_models_at := -100000

## Codex's model catalog: asks `codex debug models` (fast, local, and newer
## than ~/.codex/models_cache.json, which only refreshes when Codex runs),
## falling back to that file.
func _codex_models() -> Array:
	if Time.get_ticks_msec() - _codex_models_at < 60000 and not _codex_models_cache.is_empty():
		return _codex_models_cache
	var models: Array = []
	if _has_command("codex"):
		var sh := _login_shell("codex debug models")
		var output := []
		if OS.execute(sh[0], sh[1], output, false) == 0 and not output.is_empty():
			var data = JSON.parse_string(String(output[0]))
			if data is Dictionary and data.get("models") is Array:
				models = data["models"]
	if models.is_empty():
		var cache = JSON.parse_string(FileAccess.get_file_as_string(_home_dir().path_join(".codex/models_cache.json")))
		models = cache.get("models", []) if cache is Dictionary else []
	_codex_models_cache = models
	_codex_models_at = Time.get_ticks_msec()
	return models

## Display text for a model/effort value, e.g. "Opus 5.5 (claude-opus-5-5)".
func _choice_label(agent: String, value: String) -> String:
	if agent == "claude":
		var models := _claude_models()
		if models.has(value):
			return value if models[value] == value else ("%s (%s)" % [models[value], value] if not _CLAUDE_ALIASES.has(value) else models[value])
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
		args += ["-m", model] if agent in _TURN_AGENTS else ["--model", model]
	if effort != "":
		match agent:
			"codex": args += ["-c", "model_reasoning_effort=%s" % JSON.stringify(effort)]
			"opencode": args += ["--variant", effort]
			_: args += ["--effort", effort]
	return args

## Every CLI the panel can drive that is installed (all of them, if none is,
## so the menu still shows something).
func _all_agents() -> Array:
	var found := []
	for cli in _CLIS:
		if _installed.get(cli.id, false):
			found.append(cli.id)
	if found.is_empty():
		for cli in _CLIS:
			found.append(cli.id)
	return found

## The chosen agent, or the first installed one if the choice isn't
## installed on this machine.
func _preferred_assistant() -> String:
	var chosen := String(EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _ASSISTANT_SETTING, "claude"))
	var agents := _all_agents()
	return chosen if agents.has(chosen) else agents[0]

func _on_new_session_pressed() -> void:
	if _term_view and _term_view.visible:
		_restart_terminal()  # in the terminal view this only restarts the CLI
		return
	_tokens_in = 0
	_tokens_out = 0
	if _session_active:
		_stop_session("")
	_clear_conversation()
	_append_transcript("[i]Session cleared — your next message starts a new one.[/i]")

# ---- Settings popup ----

const _TESTS_SETTING := "ai_runs_tests"
const _SAVE_SETTING := "ai_saves_changes"
const _TOOL_DATA_SETTING := "collect_tool_data"
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

# Always included, whatever the preferences. Learned the hard way: an agent
# that decided the live bridge was "unavailable" without trying it appended
# text to the open scene's .tscn and left the scene unloadable.
const _NO_DISK_EDITS_PROMPT := (
	"Scene safety: scenes and resources open in the Godot editor are edited ONLY " +
	"through the godot-live-mcp tools, never by writing their .tscn/.tres files on " +
	"disk (cat >>, sed, a patch, a script...) — the editor holds its own copy and a " +
	"disk edit can corrupt the scene or be overwritten. If a godot-live-mcp call " +
	"fails or times out, retry it (the bridge briefly drops while the plugin reloads) " +
	"and, if it keeps failing, tell the user instead of falling back to editing files. " +
	"Never decide the bridge is unavailable without making a call to check."
)

func _build_settings_popup() -> void:
	_settings_popup = PopupPanel.new()
	add_child(_settings_popup)
	# Two columns: permissions and preferences, and (with GodotXterm) the terminal.
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 18)
	_settings_popup.add_child(columns)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	columns.add_child(box)
	if _xterm_available():
		columns.add_child(VSeparator.new())
		var right := VBoxContainer.new()
		right.add_theme_constant_override("separation", 6)
		columns.add_child(right)
		_build_term_settings(right)

	var bold: Font = EditorInterface.get_editor_theme().get_font("bold", "EditorFonts")
	var perm_label := Label.new()
	perm_label.text = "Permissions"
	perm_label.add_theme_font_override("font", bold)
	box.add_child(perm_label)
	_file_control_toggle = _make_permission_check("File Control", "Let the AI read and edit files in the project folder.", box)
	_terminal_toggle = _make_permission_check("Terminal Commands", "Let the AI run shell commands.", box)
	_web_toggle = _make_permission_check("Web Access", "Let the AI fetch web pages and search the web.", box)

	box.add_child(HSeparator.new())
	var prefs_label := Label.new()
	prefs_label.text = "Preferences"
	prefs_label.add_theme_font_override("font", bold)
	box.add_child(prefs_label)

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
		"Applies from your next message (the session is kept)."
	)
	_tests_check.button_pressed = EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _TESTS_SETTING, false)
	_tests_check.toggled.connect(_on_tests_toggled)
	box.add_child(_tests_check)

	_save_check = CheckBox.new()
	_save_check.text = "AI saves its changes"
	_save_check.tooltip_text = (
		"On: the AI saves the scene after each step.\n" +
		_mac_keys("Off: changes stay unsaved (*) for you to save with Ctrl+S, like your own edits.\n") +
		"Applies from your next message (the session is kept)."
	)
	_save_check.button_pressed = EditorInterface.get_editor_settings().get_project_metadata(
		"godot_live_mcp", _SAVE_SETTING, true)
	_save_check.toggled.connect(func(on: bool):
		EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", _SAVE_SETTING, on)
		_apply_on_next_message("Saving preference changed"))
	box.add_child(_save_check)

	var data_check := CheckBox.new()
	data_check.text = "Collect usage data for tool improvement"
	data_check.tooltip_text = (
		"On: every tool call is logged (on this computer only, in ~/.local/share/godot-live-mcp)\n" +
		"so recurring problems can later be reviewed as candidates for new GodotLiveMCP tools,\n" +
		"and the AI mentions when a batch is ready to review.\n" +
		"Off: nothing is written to disk and nothing is offered for review.\n" +
		"Applies from your next message (the session is kept)."
	)
	data_check.button_pressed = _tool_data_enabled()
	data_check.toggled.connect(func(on: bool):
		EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", _TOOL_DATA_SETTING, on)
		_ensure_local_registration()
		_apply_on_next_message("Usage-data preference changed"))
	box.add_child(data_check)

func _panel_agent() -> String:
	return _preferred_assistant()

func _on_settings_pressed() -> void:
	if _term_size_spin:
		_sync_term_settings_controls()
	_sync_check.set_pressed_no_signal(_is_sync_enabled())
	_sync_check.disabled = _debug_menu_items().is_empty()
	var at := _settings_button.get_screen_position() + Vector2(0, _settings_button.size.y)
	_settings_popup.popup(Rect2i(Vector2i(at), Vector2i.ZERO))

func _on_tests_toggled(on: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", _TESTS_SETTING, on)
	_apply_on_next_message("Testing preference changed")

## Extra claude arguments from the settings popup (testing and saving preferences,
## as appended system-prompt text the user doesn't see in the transcript).
func _behavior_args() -> Array:
	return ["--append-system-prompt", _behavior_text()]

func _behavior_text() -> String:
	var es := EditorInterface.get_editor_settings()
	var tests: bool = es.get_project_metadata("godot_live_mcp", _TESTS_SETTING, false)
	var saves: bool = es.get_project_metadata("godot_live_mcp", _SAVE_SETTING, true)
	return "\n\n".join([
		_NO_DISK_EDITS_PROMPT,
		_TESTS_ON_PROMPT if tests else _TESTS_OFF_PROMPT,
		_SAVE_ON_PROMPT if saves else _mac_keys(_SAVE_OFF_PROMPT),
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

func _start_session(first_message: String = "") -> bool:
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
	_resuming = not _claude_session_id.is_empty()
	if _resuming:
		claude_cmd += " --resume " + _shell_quote(_claude_session_id)
	else:
		_session_name = first_message.replace("\n", " ").strip_edges().left(40).strip_edges()
		if _session_name.is_empty():
			_session_name = "Godot session " + Time.get_datetime_string_from_system().replace("T", " ")
		claude_cmd += " --name " + _shell_quote(_session_name)
	# Last on the line: --mcp-config is variadic, so anything after it would
	# be swallowed as another config.
	for arg in _mcp_config_args(func(msg): _append_transcript("[color=yellow]%s[/color]" % msg)):
		claude_cmd += " " + _shell_quote(arg)
	var shell_cmd := "cd %s && %s" % [_shell_quote(project_dir), claude_cmd]
	var sh := _login_shell(shell_cmd)
	_pipe = OS.execute_with_pipe(sh[0], sh[1], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start Claude session.[/color]")
		_set_robot("angry")
		_pipe = {}
		return false

	_session_kind = "claude"
	_tokens_in = 0
	_tokens_out = 0
	_read_buffer = ""
	_got_init = false
	_session_active = true
	# A resumed process stays quiet: the restore notice (editor restart) or
	# the "conversation continues" note (model/effort change) already said so.
	if not _resuming:
		_append_transcript("[i]Session started: “%s” (pid %d). Granted: %s.[/i]" % [
			_session_name.xml_escape(), _pipe.pid,
			", ".join(granted_labels) if not granted_labels.is_empty() else "Godot control only"])
	return true

func _stop_session(status_text: String) -> void:
	_clear_busy("chat")
	if _pipe.has("stdio") and _pipe.stdio:
		_pipe.stdio.close()
	if _pipe.has("pid") and OS.is_process_running(_pipe.pid):
		OS.kill(_pipe.pid)
	_pipe = {}
	_read_buffer = ""
	_session_active = false
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
	var agent := _active_agent()
	if not (agent in _CHAT_AGENTS):
		_append_transcript("[i]%s has no chat view yet — switch to Terminal or External.[/i]" % _cli_name(agent))
		return
	if _session_active and _session_kind != agent:
		_stop_session("")  # a leftover process from another agent
	if agent in _TURN_AGENTS:
		if _session_active:
			_append_transcript("[i]%s is still working on the last message — wait for it to finish.[/i]" % _cli_name(agent))
			return
		if _start_turn(agent, text):
			_append_transcript("[color=#e5c07b][b]You:[/b] %s[/color]" % text.xml_escape())
			_input_field.text = ""
			_set_busy("chat", true)
		return
	if not _session_active:
		if not _start_session(text):
			return
	_append_transcript("[color=#e5c07b][b]You:[/b] %s[/color]" % text.xml_escape())
	var payload := {
		"type": "user",
		"message": {"role": "user", "content": [{"type": "text", "text": text}]},
	}
	_pipe.stdio.store_string(JSON.stringify(payload) + "\n")
	_input_field.text = ""
	_set_busy("chat", true)

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
			if _session_kind != "claude":
				if not _read_buffer.strip_edges().is_empty():
					_handle_stream_event(_read_buffer)
				_stop_session("")  # one process per turn; the thread lives on
			elif _resuming and not _got_init:
				_claude_session_id = ""
				_set_meta("claude_session_id", "")
				_stop_session("Couldn't resume the previous session (its history is gone?) — your next message starts a new one.")
				_set_robot("angry")
			else:
				_stop_session("Session process exited.")
				_set_robot("angry")
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

## One line of the CLI's --output-format stream-json.
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
	if _session_kind == "opencode":
		_handle_opencode_event(evt)
		return
	var event_type := String(evt.get("type", ""))

	if event_type == "system":
		var subtype := String(evt.get("subtype", ""))
		if subtype == "init":
			_got_init = true
			_claude_session_id = String(evt.get("session_id", _claude_session_id))
			_set_meta("claude_session_id", _claude_session_id)
			_set_meta("claude_session_name", _session_name)
		elif subtype == "session_title_changed":
			_session_name = String(evt.get("title", _session_name))
			_set_meta("claude_session_name", _session_name)
		elif subtype == "compact_boundary":
			var meta: Dictionary = evt.get("compact_metadata", {})
			_append_transcript("[color=#7ec07e]— session compacted: %s → %s tokens —[/color]" % [
				_short_count(int(meta.get("pre_tokens", 0))), _short_count(int(meta.get("post_tokens", 0)))])
	elif event_type == "assistant":
		var content: Array = evt.get("message", {}).get("content", [])
		for block in content:
			var block_type := String(block.get("type", ""))
			if block_type == "text":
				_append_transcript("[b]Claude:[/b] %s" % String(block.get("text", "")).xml_escape())
			elif block_type == "tool_use":
				_append_transcript("[i]  → %s[/i]" % String(block.get("name", "")).xml_escape())
	elif event_type == "result":
		if int(evt.get("num_turns", 1)) == 0:
			return  # the reply to /compact: no model turn to report
		var usage: Dictionary = evt.get("usage", {})
		# Fresh input = uncached input + cache writes; cache reads are separate.
		var turn_in := int(usage.get("input_tokens", 0)) + int(usage.get("cache_creation_input_tokens", 0))
		_turn_complete(turn_in, int(usage.get("cache_read_input_tokens", 0)), int(usage.get("output_tokens", 0)), float(evt.get("total_cost_usd", -1.0)))
		if bool(evt.get("is_error", false)):
			_set_robot("angry")

## Starts `codex exec --json` for one message (resuming the thread after the
## first). Permission toggles map onto Codex's sandbox: File Control ->
## workspace-write (else read-only), Web Access -> network inside it.
## Approvals are "never" since the panel can't show a prompt: anything
## outside the sandbox just fails, like Claude's denied tools here.
func _start_turn(agent: String, text: String) -> bool:
	if _thread_id.is_empty():
		_session_name = text.replace("\n", " ").strip_edges().left(40).strip_edges()
		_set_meta("claude_session_name", _session_name)
	return _start_codex_turn(text) if agent == "codex" else _start_opencode_turn(text)

func _start_codex_turn(text: String) -> bool:
	if not _has_command("codex"):
		_append_transcript("[color=red]Codex CLI not found on PATH — install it first: https://github.com/openai/codex[/color]")
		return false
	var args := ["exec"]
	if not _thread_id.is_empty():
		args += ["resume", _thread_id]
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
			"-c", "mcp_servers.godot-live-mcp.env.GODOT_LIVE_MCP_TOOL_DATA=%s" % JSON.stringify(_server_env(token).GODOT_LIVE_MCP_TOOL_DATA),
		]
	# Godot control is always granted in this panel (like Claude's
	# mcp__godot-live-mcp__*); without this Codex asks per MCP tool call.
	args += ["-c", 'mcp_servers.godot-live-mcp.default_tools_approval_mode="approve"']
	args.append(text)
	var cmd := "exec codex"
	for a in args:
		cmd += " " + _shell_quote(a)
	var shell_cmd := "cd %s && %s < /dev/null" % [_shell_quote(ProjectSettings.globalize_path("res://")), cmd]
	var sh := _login_shell(shell_cmd)
	_pipe = OS.execute_with_pipe(sh[0], sh[1], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start Codex.[/color]")
		_set_robot("angry")
		_pipe = {}
		return false
	_session_kind = "codex"
	_read_buffer = ""
	_session_active = true
	if _thread_id.is_empty():
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
			_set_thread("codex", String(evt.get("thread_id", "")))
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
			# Codex's input_tokens includes the cached part; take it out.
			_turn_complete(int(usage.get("input_tokens", 0)) - int(usage.get("cached_input_tokens", 0)), int(usage.get("cached_input_tokens", 0)), int(usage.get("output_tokens", 0)), -1.0)
		"turn.failed":
			var msg := String(evt.get("error", {}).get("message", "unknown error"))
			_append_transcript("[color=red]Codex failed: %s[/color]" % msg.xml_escape())
			_set_robot("angry")
			if msg.contains("401") or msg.containsn("unauthorized"):
				_append_transcript("[color=yellow]Codex isn't logged in — run `codex login` in a terminal.[/color]")
		"error":
			pass  # reconnect chatter; a real failure also arrives as turn.failed

## Starts `opencode run --format json` for one message (resuming the thread
## after the first). One process per message, like Codex.
func _start_opencode_turn(text: String) -> bool:
	if not _installed.get("opencode", false):
		_append_transcript("[color=red]OpenCode CLI not found on PATH — install it first: https://opencode.ai[/color]")
		return false
	var args := ["run", "--format", "json"]
	if not _thread_id.is_empty():
		args += ["-s", _thread_id]
	else:
		args += ["--title", _session_name]
	args += _model_args("opencode")
	args.append(text)
	var cmd := "exec env " + _shell_quote("OPENCODE_CONFIG_CONTENT=" + _opencode_config(true)) + " opencode"
	for a in args:
		cmd += " " + _shell_quote(a)
	var shell_cmd := "cd %s && %s < /dev/null" % [_shell_quote(ProjectSettings.globalize_path("res://")), cmd]
	var sh := _login_shell(shell_cmd)
	_pipe = OS.execute_with_pipe(sh[0], sh[1], false)
	if _pipe.is_empty() or not _pipe.has("stdio") or _pipe.stdio == null:
		_append_transcript("[color=red]Failed to start OpenCode.[/color]")
		_set_robot("angry")
		_pipe = {}
		return false
	_session_kind = "opencode"
	_read_buffer = ""
	_session_active = true
	_oc_in = 0
	_oc_cached = 0
	_oc_out = 0
	_oc_cost = 0.0
	if _thread_id.is_empty():
		_tokens_in = 0
		_tokens_out = 0
		_append_transcript("[i]OpenCode session started: “%s”. Edit %s, shell %s, web %s.[/i]" % [
			_session_name.xml_escape(),
			"on" if _file_control_toggle.button_pressed else "off",
			"on" if _terminal_toggle.button_pressed else "off",
			"on" if _web_toggle.button_pressed else "off"])
	return true

# This turn's token/cost sums across OpenCode's steps (a turn with tool calls
# has several), reported once when the final step finishes.
var _oc_in := 0
var _oc_cached := 0
var _oc_out := 0
var _oc_cost := 0.0

## One JSON event from `opencode run --format json`: step_start, text,
## tool_use (arrives completed), step_finish (reason "stop" ends the turn),
## and error.
func _handle_opencode_event(evt: Dictionary) -> void:
	var sid := String(evt.get("sessionID", ""))
	if sid != "" and sid != _thread_id:
		_set_thread("opencode", sid)
	var part: Dictionary = evt.get("part", {}) if evt.get("part") is Dictionary else {}
	match String(evt.get("type", "")):
		"text":
			_append_transcript("[b]OpenCode:[/b] %s" % String(part.get("text", "")).xml_escape())
		"tool_use":
			var tool_name := String(part.get("tool", "")).trim_prefix("godot-live-mcp_")
			var status := String(part.get("state", {}).get("status", "")) if part.get("state") is Dictionary else ""
			_append_transcript("[i]  → %s%s[/i]" % [tool_name.xml_escape(), " (failed)" if status == "error" else ""])
		"step_finish":
			var tokens: Dictionary = part.get("tokens", {}) if part.get("tokens") is Dictionary else {}
			var cache: Dictionary = tokens.get("cache", {}) if tokens.get("cache") is Dictionary else {}
			_oc_in += int(tokens.get("input", 0)) + int(cache.get("write", 0))
			_oc_cached += int(cache.get("read", 0))
			_oc_out += int(tokens.get("output", 0))
			_oc_cost += float(part.get("cost", 0.0))
			if String(part.get("reason", "")) == "stop":
				_turn_complete(_oc_in, _oc_cached, _oc_out, _oc_cost)
		"error":
			var err = evt.get("error", {})
			var msg := String(err.get("data", {}).get("message", err.get("name", "unknown error"))) if err is Dictionary and err.get("data") is Dictionary else str(err)
			_append_transcript("[color=red]OpenCode failed: %s[/color]" % msg.xml_escape())
			_set_robot("angry")

## "— edits complete —" plus this turn's fresh tokens in/out (cached reads
## noted separately) and the conversation's running fresh totals.
func _turn_complete(turn_in: int, cached: int, turn_out: int, cost: float) -> void:
	_set_busy("chat", false)
	_tokens_in += turn_in
	_tokens_out += turn_out
	# Fresh tokens first; cached reads cost far less and mostly don't count
	# toward rate limits, so they're noted separately and left out of totals.
	var line := "— edits complete · %s in / %s out (+%s cached) · session %s / %s" % [
		_short_count(turn_in), _short_count(turn_out), _short_count(cached),
		_short_count(_tokens_in), _short_count(_tokens_out)]
	_append_transcript("[color=#7ec07e]%s —[/color]" % line)

func _short_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (n / 1000.0)
	return str(n)

func _append_transcript(bbcode_line: String) -> void:
	_transcript.append_text(bbcode_line + "\n")
	var f := FileAccess.open(_TRANSCRIPT_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(_TRANSCRIPT_PATH) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string(bbcode_line + "\n")

func _meta(key: String, default = ""):
	return EditorInterface.get_editor_settings().get_project_metadata("godot_live_mcp", key, default)

func _set_meta(key: String, value) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("godot_live_mcp", key, value)

## Reloads the saved transcript (its tail, if long) and the stored session
## id, so reopening the editor shows the same conversation and the next
## message continues it.
func _restore_conversation() -> void:
	_claude_session_id = String(_meta("claude_session_id"))
	_session_name = String(_meta("claude_session_name"))
	_load_thread()
	_show_header()
	if not FileAccess.file_exists(_TRANSCRIPT_PATH):
		return
	var text := FileAccess.get_file_as_string(_TRANSCRIPT_PATH)
	if text.length() > _TRANSCRIPT_KEEP_BYTES:
		var cut := text.find("\n", text.length() - _TRANSCRIPT_KEEP_BYTES)
		text = text.substr(cut + 1) if cut != -1 else ""
		var f := FileAccess.open(_TRANSCRIPT_PATH, FileAccess.WRITE)
		if f:
			f.store_string(text)
	_transcript.append_text(text)
	if _has_resumable():
		# Display only: logging it would pile up a copy per editor restart.
		_transcript.append_text("[color=orange][i]— previous session restored: “%s”. Your next message resumes it. —[/i][/color]\n" % _session_name.xml_escape())

## First line of the session box: which in-editor agent and model are in
## use. Display only (not saved with the transcript), so it always reflects
## the current settings when the editor opens or the session is cleared, and
## scrolls away as the conversation grows.
func _show_header() -> void:
	_transcript.append_text(_agent_line() + "\n")

## "In Editor Coding Agent: <name> · <model>" in bold green, as BBCode.
func _agent_line() -> String:
	var agent := _preferred_assistant()
	var model := _current_setting(agent, "model")
	return "[b][color=#7ec07e]In Editor Coding Agent: %s · %s[/color][/b]" % [
		_cli_name(agent).xml_escape(),
		_choice_label(agent, model).xml_escape() if model != "" else "default model"]

## Forget the stored conversation (id, name and saved transcript).
func _clear_conversation() -> void:
	_claude_session_id = ""
	_session_name = ""
	for agent in _TURN_AGENTS:
		_set_meta("thread_" + agent, "")
	_thread_id = ""
	_set_meta("claude_session_id", "")
	_set_meta("claude_session_name", "")
	_transcript.clear()
	_show_header()
	var f := FileAccess.open(_TRANSCRIPT_PATH, FileAccess.WRITE)
	if f:
		f.close()

## Settings that are launch flags: end the running process; the next message
## starts a new one with them, resuming the same conversation.
func _apply_on_next_message(what: String) -> void:
	_sync_terminal_to_settings()
	var running := _session_active and _session_kind == "claude"
	if running:
		_stop_session("")
	if running or not _claude_session_id.is_empty():
		_append_transcript("[i]%s — applies from your next message; the session continues.[/i]" % what)
