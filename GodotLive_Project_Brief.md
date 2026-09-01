# GodotLive — Project Brief

## What this is

An MCP (Model Context Protocol) server that lets an AI coding agent (Claude Code,
Cursor, etc.) drive a **running** Godot 4 editor/game session directly — not just
edit files on disk. It combines two things:

1. **Structured tools** for common editor operations (add/move/scale nodes, attach
   scripts, set properties, change project settings).
2. **A live REPL/eval tool** — the agent can send an arbitrary GDScript expression
   to a specific node in the running scene and get the result back immediately,
   for anything the structured tools don't cover.

The goal is parity with (or improvement on) what Unity's CLI + Pipeline package +
Unity MCP already offer Unity developers: an agent that can observe a live
project, act on it, and verify the result, without a human relaying context back
and forth.

## Why build this instead of using what exists

- Free/open Godot MCP servers (e.g. `Coding-Solo/godot-mcp`) cover project
  lifecycle (launch editor, run, capture debug output) and basic scene/node
  creation, but have **no** transform manipulation, script attachment, generic
  property editing, or live eval.
- A paid option exists (Godot MCP Pro, ~175 tools) but is **proprietary** —
  purchasing it does not grant rights to fork, redistribute, or build derivative
  works from its source. It is not a legitimate base for this project.
- No existing Godot MCP server offers live REPL/eval against a running scene.
  This is the genuine gap and the main point of differentiation.

<!--
## Inspiration (deferred — not in scope for v1)

For which API calls to expose as MCP tools, reference only Godot MCP Pro's
publicly documented tool list (names/descriptions of what it offers) — never
its source code. It is proprietary and not a legitimate base for this project
(see above); using its docs for naming/coverage ideas is fine, reimplementing
from or referencing its actual implementation is not.
-->

## Components to build

### 1. In-editor GDScript autoload/plugin (the "runtime bridge")

A lightweight Godot addon that runs inside the live game/editor process. Core
job: listen on a local socket for `{node_path, expression}` messages, resolve
the target node, evaluate the expression with that node as `self` (via GDScript's
`Expression` class or an equivalent runtime-eval mechanism), and return
`{result, error}`.

- Base this on the eval/context-selection approach used by **Ruake**
  (github.com/Fanny-Pack-Studios/Ruake, MIT license, Godot 4.1+) — specifically
  its pattern of evaluating an expression against a chosen scene-tree node as
  context. Reuse/adapt that logic; you do not need its console UI.
- Strip out the visual in-game console UI entirely — this bridge only needs to
  be headless (socket in, JSON out). No human-facing UI required.
- Should also expose: list current scene tree, get/set arbitrary node property,
  set node script, remove/reparent/duplicate node, read/set project settings.
- **Security:** `eval_expression` is effectively remote code execution against
  a live process. The socket must bind to `127.0.0.1` only (never `0.0.0.0`),
  and should require a shared handshake token before accepting messages.

### 2. MCP server (language pinned to whatever `godot-mcp` uses)

Fork `Coding-Solo/godot-mcp` (MIT-licensed, confirm license file before starting)
as the base. Check its actual implementation language before forking — this
also decides the socket-framing code the runtime bridge (component 1) needs to
speak. It already provides:

- `launch_editor`, `run_project`, `stop_project`, `get_debug_output`
- `get_godot_version`, `list_projects`, `get_project_info`
- `create_scene`, `add_node`, `load_sprite`, `save_scene`
- UID management (Godot 4.4+)

Add new tools that talk to the runtime bridge (component 1) over its local
socket:

- `eval_expression(node_path, expression)` — the core REPL tool
- `set_transform(node_path, position, rotation, scale)`
- `set_property(node_path, property_name, value)` — generic property setter
- `attach_script(node_path, script_path)` — set an existing script on a node
- `create_and_attach_script(node_path, template)` — generate + attach in one step
- `remove_node(node_path)`, `reparent_node(node_path, new_parent_path)`,
  `duplicate_node(node_path)`
- `get_node_properties(node_path)`, `list_scene_tree()` — read-back/inspection
- `set_project_setting(key, value)` — project-wide settings (input maps,
  rendering, autoloads)

### 3. (Later) A companion Skill / CLAUDE.md

Once the server is working end to end, write a `CLAUDE.md` / skill file that
teaches an agent working in this repo:

- When to prefer a structured tool vs. `eval_expression`
- Project-specific scene/node conventions as they get established
- A lightweight self-improvement rule: after any request that required falling
  back to `eval_expression` for something structured tools don't cover, if the
  pattern looks likely to recur (not a one-off), suggest to the user that it be
  promoted into a dedicated tool. Do not ask this after every single prompt —
  only when a repeatable gap is actually observed.

This is explicitly a later step. Do not build it before the server itself works.

## Suggested build order

1. Confirm licenses of `Coding-Solo/godot-mcp` and `Fanny-Pack-Studios/Ruake`
   before writing any code. Also confirm `godot-mcp`'s implementation language
   at this point, since it pins the language for the rest of the MCP server
   and the wire format the runtime bridge must speak.
2. Fork `godot-mcp`. Get it running against a real local Godot 4 project,
   confirm the existing tools work as documented.
3. Build the headless runtime bridge addon (adapted from Ruake's eval logic),
   test it standalone inside the Godot editor (no MCP yet) — send it an
   expression manually, confirm it evaluates against a chosen node and returns
   a result.
4. Wire the bridge into the MCP server: add `eval_expression` as the first new
   tool. Get this working end-to-end from an AI client before adding anything
   else — it's the highest-value, most-general capability.
5. Add the remaining structured tools (`set_transform`, `attach_script`,
   `set_property`, node CRUD, project settings) — these are mostly thin
   wrappers over Godot's own API and can be built incrementally.
6. Add read-back tools (`get_node_properties`, `list_scene_tree`) so the agent
   can verify its own changes rather than acting blind.
7. Write the CLAUDE.md / skill layer once real usage patterns exist to learn
   from.

## Out of scope for v1

- Visual/rendering feedback (screenshots, framerate, "how does it look") — not
  solved by any current Godot MCP approach, including this one. Worth
  revisiting later, not a blocker for v1.
- Export/build pipeline automation — nice to have, not core to the "live
  editing" value proposition.
- A polished human-facing UI for the runtime bridge — it's headless by design.

## Success criteria for v1

An AI agent, given a running Godot project via this MCP server, can: list the
current scene tree, select a node, change a physics-relevant property (e.g.
friction) via `eval_expression`, and confirm via read-back that the value
changed — all without the human touching the editor.
