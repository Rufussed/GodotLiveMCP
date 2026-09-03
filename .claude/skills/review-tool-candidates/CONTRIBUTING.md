# Contributing to GodotLiveMCP

Two ways to contribute a new tool: build and verify it yourself, or write
up a design brief for someone else (including the maintainers) to build.
Both are welcome — see [Submitting](#submitting) below.

## How a bridge tool is built

Every tool in this project follows the same shape, whether it's an editor
tool (`bridge.gd` / `server/src/bridgeTools.ts`) or a running-game tool
(`addon/godot_live_mcp/runtime_bridge.gd` / `server/src/runtimeTools.ts`):

1. **A `_cmd_*` function in the addon script.** Name it `_cmd_snake_case`,
   matching the MCP tool name. Include a doc comment explaining *why* it
   earns its place — which gap it closes, per the bar in
   [`TOOL_CANDIDATES.md`](TOOL_CANDIDATES.md) (structural, or a repeated
   efficiency pattern). Validate inputs and fail loudly
   (`return _fail("...")`) rather than silently doing nothing — this
   project has hit real bugs from `Object.set()`'s silent no-op on an
   unknown property name, and every mutating tool now validates against
   `get_property_list()` and returns a readback of what was actually
   applied rather than a bare `{"ok": true}`. New tools should follow that
   same discipline.
2. **A matching tool definition + dispatch case** in `bridgeTools.ts` (or
   `runtimeTools.ts`) — the `inputSchema`, a description written for the
   calling agent (explain *when* to use this over `eval_expression` or
   another tool, not just what it does), and the `case` in the dispatch
   `switch` that forwards to the bridge command.
3. **Build**: `cd server && npm run build`.
4. **Reload**: call the `reload_plugin` tool (editor tools) — it rescans
   the filesystem and re-toggles the plugin itself, no manual step needed.
   A running-game (`runtime_bridge.gd`) tool needs the game restarted
   (`stop_scene` then `play_scene`), since runtime scripts aren't part of
   the editor's hot-reload system.

## Live verification is required, not optional

A tool that typechecks is not a tool that works. Every new tool needs a
real round-trip against a running Godot instance before it's considered
done:

- At least one **success** case, with the actual returned value checked,
  not just `ok: true` — this project has shipped tools that reported
  success while silently changing nothing, more than once, before this
  became a hard rule.
- At least one **failure** case (bad input, wrong node type, out-of-range
  value, whatever's relevant) — confirm it fails with a clear message
  instead of silently no-oping or crashing.
- If the tool mutates state, confirm the mutation actually persists (read
  it back via a *different* call than the one that set it).

Include what you actually ran and what came back in the PR description —
screenshots, terminal output, or a short transcript. "I tested it" without
evidence isn't verification.

## Design briefs — contributing without writing code

If you've found a real gap (via your own usage, or the
`review-tool-candidates` skill) but can't or don't want to implement and
verify it yourself, write a design brief instead. Use this shape:

```markdown
### Problem observed

What couldn't the existing tools do, or what took more calls than it
should have?

### Evidence

The actual log entries (or manual reproduction steps) that show this
happening. Redact/generalize anything from your own project you don't
want to share (see Privacy below) — a fabricated example that reproduces
the same shape is fine if the real one contains data you'd rather not post.

### Proposed tool shape

- Tool name
- Parameters (name, type, what they mean)
- What it does / returns
- Which existing Godot API(s) it would call

### Why existing tools don't cover it

Structural gap, or a repeated efficiency pattern? (See the bar in
TOOL_CANDIDATES.md.) If it's the efficiency case, note where else the same
pattern showed up.
```

A brief doesn't need to be complete or even correct in every detail — it
needs to describe a real, evidenced need clearly enough that someone else
could implement and verify it.

## Submitting

- **A built tool**: fork, implement following the pattern above, verify
  live, open a PR. Fill in the PR template (`.github/PULL_REQUEST_TEMPLATE.md`)
  — it mirrors this document's bar.
- **A design brief**: open a GitHub issue using the shape above, or include
  it in a PR that's just the brief (no code) if you'd rather not use
  issues.
- Either way, tools are additive by default — a PR that also changes the
  behavior of an existing tool should say so explicitly and explain why.

## Privacy note

`calls.ndjson` / `calls.pending-review.ndjson` (see `TOOL_CANDIDATES.md`
and the `review-tool-candidates` skill) can contain project-specific file
paths, node names, and property values from your own real usage. Don't
attach or paste raw log content into a public issue or PR — describe the
pattern, or use a generalized/fabricated example that reproduces the same
shape.
