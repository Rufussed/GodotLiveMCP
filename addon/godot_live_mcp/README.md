# GodotLive MCP Bridge (Godot addon)

Headless runtime bridge for `GodotLiveMCP`. Runs inside the Godot editor
process and listens on `127.0.0.1` for JSON commands from the MCP server —
live eval, scene tree inspection, node/property editing.

## Install

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
   the MCP server's environment.

## Configuration

Both are optional; defaults shown.

| Env var | Default | Purpose |
|---|---|---|
| `GODOT_LIVE_MCP_PORT` | `9080` | TCP port the bridge listens on |
| `GODOT_LIVE_MCP_TOKEN` | (generated) | Overrides the auto-generated token |

The bridge only ever binds to `127.0.0.1` — it is not reachable from other
machines, and every request must include the token.

## Scope for v1

Operates on the scene currently open in the editor (`EditorInterface.get_edited_scene_root()`).
Not yet wired to a *running* exported game — see the project brief's "out of
scope for v1" section.
