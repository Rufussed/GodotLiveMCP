# GodotLive MCP Bridge (Godot addon)

Headless runtime bridge for `GodotLiveMCP`. Runs inside the Godot editor
process and listens on `127.0.0.1` for JSON commands from the MCP server —
live eval, scene tree inspection, node/property editing.

## Install

### Easiest: the launcher app (recommended)

Prerequisites: [Node.js](https://nodejs.org) 18+ (it runs the MCP server) and at
least one coding agent CLI, installed and logged in:
[Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex), [OpenCode](https://opencode.ai) or
[Gemini CLI](https://github.com/google-gemini/gemini-cli).

1. Clone the GodotLiveMCP repo.
2. Open the launcher: open `launcher/project.godot` in Godot and press Play,
   or run `godot --path launcher` from the repo root.
3. The launcher checks for Git, Node, npm and which agent CLIs you have (at least
   one is needed). Click
   **Install / rebuild MCP server** to build the MCP server (it's shared by all
   your projects). The project buttons appear once it's installed.
4. Click **Create new Godot project…** to name a new project and choose where
   it goes, or **Add existing Godot project…** to pick a folder that already
   has a `project.godot`. The launcher links this addon into the project's
   `addons/` folder and enables the plugin in `project.godot`.
5. The project appears in the list with **Open in Godot** and **Unlink**
   buttons. Open it and the AI Assistant panel sets up the server and token
   by itself. You don't need the manual steps below. (If the project was
   already open in Godot while you added it, reopen it.)
6. Optional, Linux and macOS: the launcher's **terminal panel** section downloads
   GodotXterm once; **Add terminal** on a project then gives its AI Assistant tab
   a **CLI** mode (the agent's full interactive CLI inside the editor). See the main
   README for details.

### Command line

If you'd rather not use the launcher, the main README's Quick start does
the same from a terminal: `npm run link-project` links this folder into
your project and enables the plugin. After that, the AI Assistant panel
sets up the server and token by itself, so you can skip the steps below.

### Manual

Use these steps if you're copying the addon by hand or using an MCP client
other than Claude Code.

1. Copy this `godot_live_mcp/` folder into your project's `addons/` directory,
   so you end up with `res://addons/godot_live_mcp/plugin.cfg`.
2. In the Godot editor: **Project > Project Settings > Plugins**, enable
   "GodotLive MCP Bridge".
3. Check the editor's Output panel for a line like:
   ```
   GodotLiveMCPBridge: listening on 127.0.0.1:9080
   ```
4. The bridge generates an auth token on first run and stores it at
   `user://godot_live_mcp_token.txt` (its Output panel line shows the
   globalized path). Read that file and set it as `GODOT_LIVE_MCP_TOKEN` in
   the MCP server's environment — or set `GODOT_LIVE_MCP_TOKEN` in your own
   environment *before* launching Godot, so every project uses the same
   fixed token and you never have to re-read a per-project generated one.
   The Output panel tells you which source it used
   (`_load_or_create_token()` logs it either way).
5. Copy [`CLAUDE.md.template`](CLAUDE.md.template) to your Godot project's
   root as `CLAUDE.md` (or merge it into an existing one). It teaches an
   agent working in that project when to call `save_scene_live`, when to
   prefer a structured tool vs. `eval_expression`, and what singletons
   `eval_expression` can already reach — without it, bridge edits can be
   silently lost on editor reload since nothing warns the agent that
   they're memory-only.

## Configuration

Both are optional; defaults shown.

| Env var | Default | Purpose |
|---|---|---|
| `GODOT_LIVE_MCP_PORT` | `9080` | TCP port the editor bridge listens on |
| `GODOT_LIVE_MCP_TOKEN` | (generated) | Overrides the auto-generated token (shared by both bridges) |
| `GODOT_LIVE_MCP_RUNTIME_PORT` | `9090` | TCP port the runtime (game) bridge listens on |

The bridge only ever binds to `127.0.0.1` — it is not reachable from other
machines, and every request must include the token.

## Live running-game control (optional)

The runtime bridge only starts when the game is launched from the editor
(`OS.has_feature("editor_runtime")`), so it never opens a port in an
exported build.

The steps above only wire up the **editor** bridge — it has no presence in
an actual running game, since a game is a separate OS process an
`EditorPlugin` never touches. To let the agent inspect/control a *running*
game (scene tree, properties, keyboard/mouse simulation, screenshots), add
`runtime_bridge.gd` as an Autoload:

1. **Project > Project Settings > Autoload**, add
   `res://addons/godot_live_mcp/runtime_bridge.gd` (any name works, e.g.
   `GodotLiveMCPRuntime`), leave "Enable" checked.
2. Prefer setting this up via `eval_expression`'s access to
   `ProjectSettings` from the *running* editor
   (`ProjectSettings.set_setting("autoload/GodotLiveMCPRuntime",
   "*res://addons/godot_live_mcp/runtime_bridge.gd")` then
   `ProjectSettings.save()`) rather than hand-editing `project.godot` on
   disk — confirmed live that editing the file directly while the editor
   has the project open is fragile: the editor can resave the file from
   its own in-memory settings and silently drop the change.
3. Restart the editor (`restart_editor`) so the new autoload registers,
   then start the game (`play_scene`, or press Play) — the runtime
   bridge prints its own `listening on 127.0.0.1:9090` line once the game
   boots. Both bridges run simultaneously; they're independent processes.

## Scope

v1 covered the editor's own scene (`EditorInterface.get_edited_scene_root()`)
only. As of v2.0, a running game is reachable too, via the runtime bridge
above — see the main [README](../../README.md) for the current tool list.
