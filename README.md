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

## Self-improvement loop

Every tool call (bridge-backed or lifecycle) is logged to
`~/.local/share/godot-live-mcp/calls.ndjson` — shared across every
workspace pointed at this server, since it's registered once at MCP-client
user scope. The log doesn't grow forever: once enough "candidate signal"
(an error, or a burst of several rapid calls — a proxy for a multi-call
workaround standing in for what should be one request) accumulates, it's
rotated into `calls.pending-review.ndjson`, a bounded batch ready to look
at.

Two plain logging tools, `log_intent`/`log_result`, let an agent bracket
one conceptual step with a short note before its calls and a short
outcome note after — the call/error count for that step is stamped onto
the result entry automatically. That turns the log from an undifferentiated
pile of tool calls into self-contained `{intent, calls, result}` units,
which is what actually makes review useful instead of guesswork
reconstructed from timestamps. See `addon/godot_live_mcp/CLAUDE.md.template`
for the guidance an agent working in your project should follow.

Nothing is ever analyzed automatically. Run the `/review-tool-candidates`
skill (Claude Code; see [`.claude/skills/review-tool-candidates/`](.claude/skills/review-tool-candidates/SKILL.md))
when you want to look — it asks before analyzing, presents any candidates
with the actual evidence behind them, then asks again before building
anything. You can build a candidate locally and verify it against your own
project, write up a design brief for someone else to build instead, or
just decline. See [`TOOL_CANDIDATES.md`](TOOL_CANDIDATES.md) for the
review criteria and [`CONTRIBUTING.md`](CONTRIBUTING.md) for what
"building it" actually requires (live verification, not just code that
typechecks) and how to submit a tool or a brief upstream.

Logging behavior is configurable via env vars on the MCP server:

| Env var | Default | Purpose |
|---|---|---|
| `GODOT_LIVE_MCP_LOG` | (on) | Set to `off` to disable logging entirely |
| `GODOT_LIVE_MCP_LOG_REVIEW` | (on) | Set to `off` to permanently skip review — batches are discarded at rotation instead of held for review, with no further prompting |
| `GODOT_LIVE_MCP_LOG_PATH` | `~/.local/share/godot-live-mcp/calls.ndjson` | Override the log location |
| `GODOT_LIVE_MCP_LOG_CANDIDATE_THRESHOLD` | `3` | Candidate-signal count that triggers rotation |
| `GODOT_LIVE_MCP_LOG_BURST_SIZE` | `5` | Calls within the burst gap window counted as one burst signal |
| `GODOT_LIVE_MCP_LOG_BURST_GAP_MS` | `10000` | Max gap between calls to count as the same burst |
| `GODOT_LIVE_MCP_LOG_MAX_MB` | `10` | Byte-size backstop, independent of the candidate-signal count |

All thresholds are untuned starting points, not fixed defaults to rely on —
adjust them once you've seen how they behave against real usage.

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

## Known limitations

**The bridge can go unresponsive for several seconds after a heavy
synchronous call.** Both bridges poll their socket from `_process()`, which
only runs between frames of Godot's single-threaded main loop — so a call
that itself runs long and synchronous (e.g. loading a large scene via
`EditorInterface.open_scene_from_path()` inside `eval_expression`, or a
project script's own expensive regeneration logic) blocks that loop, and
with it every other pending or subsequent bridge command, until it
returns. Confirmed live (recurring across two separate usage-log reviews,
2026-09-10): calls immediately following such an operation — even a
trivial `eval_expression("1+1")` — can time out at the client's 5s limit,
sometimes more than once in a row, before the bridge responds again. This
isn't a bug to work around with a new tool; it's inherent to a
single-threaded socket-in-`_process()` design. If a call times out right
after something heavy, retry rather than treating it as a hang or a dead
bridge.
