# Changelog

## 0.2.0

The editor now serves MCP itself, so no Node.js is needed to use it.

- **In-editor MCP server** over HTTP on `127.0.0.1`, with a bearer token and
  Host and Origin checks. It serves 105 tools: the editor tools, the
  running-game tools, screenshots, and Asset Library search and install.
- **Connect your AI app** card in the AI Assistant panel: one button each for
  Claude Code, Codex, VS Code and Cursor (opencode, Gemini CLI and Copy config
  under More). Each shows what it will write before it writes.
- **Lite and Full tool groups.** A clean install starts with Lite (28 tools).
- The panel's own Claude, Codex, opencode and Gemini sessions use the in-editor
  server.
- **Check for updates** button in Settings (only runs when pressed).
- The Node server, launcher and the Node-only tools remain for launching Godot
  from an agent, headless scene tools, language-server diagnostics and the
  opt-in usage log.

Tested on Godot 4.7 on Linux only.
