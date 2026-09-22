@tool
extends VBoxContainer

## Bottom-panel tab: "AI Assistant". Phase 1a of PLUGIN_OUTPUT_PANEL_PLAN.md —
## external-terminal on-ramp only. The in-editor stream-json tab is a
## separate, later piece; this just proves out the panel + subprocess
## plumbing with the lowest-risk path first.

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

func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)

	_launch_button = Button.new()
	_launch_button.text = "Open Claude Code in Terminal"
	_launch_button.pressed.connect(_on_launch_pressed)
	add_child(_launch_button)

	_refresh_status()

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
