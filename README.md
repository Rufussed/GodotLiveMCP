# GodotLiveMCP

An MCP server that lets an AI coding agent drive a **running** Godot 4 editor
session directly, not just edit files on disk. See
[GodotLive_Project_Brief.md](GodotLive_Project_Brief.md) for the full rationale and scope.

Two parts:

- **`addon/godot_live_mcp/`** — a headless Godot editor plugin (the "runtime
  bridge"). Listens on `127.0.0.1` for JSON commands and executes them
  against the live scene tree: eval, property get/set, transform, node
  CRUD, signals, groups, physics/collision, 3D materials and shaders,
  animation, audio buses, tilemaps, particles, theme overrides. Property
  mutations are routed through Godot's own `EditorUndoRedoManager`, so
  bridge-driven edits get the same save-prompt and Ctrl+Z behavior as
  manual edits. See its own
  [README](addon/godot_live_mcp/README.md) for install steps.
- **`server/`** — the MCP server (Node.js/TypeScript, forked from
  [`Coding-Solo/godot-mcp`](https://github.com/Coding-Solo/godot-mcp), MIT).
  Adds ~49 bridge-backed tools (`eval_expression`, `set_property`,
  `set_nested_property`, `set_resource_property`, `list_scene_tree`, etc.)
  on top of godot-mcp's existing project-lifecycle tools (`launch_editor`,
  `run_project`, `create_scene`, ...).

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
end to end, without touching the editor by hand), and the project has moved
into additive "v1.x" batches (currently v1.14) adding tool coverage for
nodes, physics, 3D resources, animation, audio, tilemaps, particles, theme
overrides, shader materials, routing edits through Godot's own undo/redo
system, generic nested-resource-property editing (`set_nested_property`,
`set_resource_property`), and a `reload_plugin` command so new tools can
take effect without a manual plugin toggle.
