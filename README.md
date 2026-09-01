# GodotLiveMCP

An MCP server that lets an AI coding agent drive a **running** Godot 4 editor
session directly, not just edit files on disk. See
[GodotLive_Project_Brief.md](GodotLive_Project_Brief.md) for the full
rationale and scope.

Two parts:

- **`addon/godot_live_mcp/`** — a headless Godot editor plugin (the "runtime
  bridge"). Listens on `127.0.0.1` for JSON commands and executes them
  against the live scene tree: eval, property get/set, transform, node
  CRUD, project settings. See its own
  [README](addon/godot_live_mcp/README.md) for install steps.
- **`server/`** — the MCP server (Node.js/TypeScript, forked from
  [`Coding-Solo/godot-mcp`](https://github.com/Coding-Solo/godot-mcp), MIT).
  Adds bridge-backed tools (`eval_expression`, `set_property`,
  `list_scene_tree`, etc.) on top of godot-mcp's existing project-lifecycle
  tools (`launch_editor`, `run_project`, `create_scene`, ...).

## Quick start

1. Install the addon into your Godot project and enable it (see its README).
   Note the token it prints/stores.
2. Build the server:
   ```
   cd server
   npm install
   npm run build
   ```
3. Point your MCP client (Claude Code, etc.) at `server/build/index.js`, with
   `GODOT_LIVE_MCP_TOKEN` set to the token from step 1.
4. With the Godot editor open and the addon enabled, try `list_scene_tree`
   then `eval_expression` from your agent to confirm the round trip works.

## Status

v1 in progress. Success criteria (see the brief): list the live scene tree,
select a node, change a property via `eval_expression`, confirm the change
via read-back — end to end, without touching the editor by hand.
