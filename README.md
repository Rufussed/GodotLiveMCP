# GodotLiveMCP

An MCP server that lets an AI coding agent drive a **running** Godot 4 editor
session directly, not just edit files on disk. See
[GodotLive_Project_Brief.md](GodotLive_Project_Brief.md) for the full rationale and scope.

Two parts:

- **`addon/godot_live_mcp/`** — two headless bridges. `bridge.gd` is a Godot
  editor plugin listening on `127.0.0.1:9080` for JSON commands against the
  editor's live scene tree: eval, property get/set (including nested
  sub-resources, array elements, and dictionary keys), transform, node CRUD,
  signals, groups, physics/collision, 3D materials and shaders, animation
  (including state machines), navigation baking, audio buses, tilemaps,
  particles, theme/UI, editor screenshots, and its own Play/Stop/reload/
  restart control. Property mutations route through Godot's own
  `EditorUndoRedoManager`, so bridge-driven edits get the same save-prompt
  and Ctrl+Z behavior as manual edits. `runtime_bridge.gd` is an optional
  Autoload singleton (listening on `127.0.0.1:9090`) giving the same kind of
  access to an actual **running game** — a separate OS process the editor
  plugin has no presence in — plus keyboard/mouse input simulation and a
  frame-polling condition-wait helper. See its own
  [README](addon/godot_live_mcp/README.md) for install steps for both.
- **`server/`** — the MCP server (Node.js/TypeScript, forked from
  [`Coding-Solo/godot-mcp`](https://github.com/Coding-Solo/godot-mcp), MIT).
  Adds ~70 bridge-backed tools (`eval_expression`, `set_property`,
  `set_nested_property`, `game_eval_expression`, `simulate_key`, etc.) on
  top of godot-mcp's existing project-lifecycle tools (`launch_editor`,
  `create_scene`, ...) — prefer this project's own `play_scene`/
  `stop_scene` over godot-mcp's inherited `run_project`, which spawns a
  separate CLI process that proved unreliable in practice.

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

v1's success criteria are met (list the live scene tree, select a node,
change a property via `eval_expression`, confirm the change via read-back —
end to end, without touching the editor by hand). The project has since
moved through additive "v1.x" batches covering nodes, physics, 3D resources,
animation, audio, tilemaps, particles, theme/UI, shader materials, generic
nested-property editing (objects, arrays, and dictionaries), routing edits
through Godot's own undo/redo system, and self-sufficient editor
reload/restart/rescan (`reload_plugin`, `restart_editor`, `reload_project`)
needing zero manual steps. v2.0 expands scope from editor-only to a genuinely
running game via a second bridge (`runtime_bridge.gd`, an optional Autoload):
scene/property access, input simulation, screenshots, and frame-accurate
condition polling for a live game instance, plus `play_scene`/`stop_scene`
to start/stop it without leaving the agent.
