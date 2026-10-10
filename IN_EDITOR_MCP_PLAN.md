# In-editor MCP server — no Node, install from the store

Draft, 2026-10-10. Companion to the other plans in this folder.

## The goal

Someone new to Godot installs the addon from the Asset Library, enables it,
and presses **Connect to Claude Code** (or Cursor, VS Code, Codex, Claude
Desktop). No Node, no terminal, no config file to edit. Today the MCP server
is a separate Node program, which is the biggest install hurdle.

Code inside the editor has to be GDScript: C# only exists in the .NET edition
of Godot, and native extensions need a build per platform. GDScript is also
what the addon already is (about 10,000 lines), so this is more of the same.

## Two front doors, one core

```
 HTTP clients (Claude Code, Cursor, VS Code, Codex)
        │  POST http://127.0.0.1:<port>/mcp  (token, Host/Origin checks)
        ▼
 ┌──────────────────────────────┐
 │  mcp_core.gd (in the editor) │  initialize · tools/list · tools/call · ping
 │  tool list (tools.json)      │  → the bridge's existing _cmd_* functions
 └──────────────────────────────┘
        ▲
        │  one authenticated local TCP request ("mcp_request")
 stdio clients (Claude Desktop, anything that launches a program)
        │
   godot --headless --no-header --path <addon>/relay --script res://mcp_relay.gd -- <port> <token>
```

- **HTTP transport:** adapt Funplay's (MIT, about 220 lines; keep their
  copyright notice and license in `THIRD_PARTY_NOTICES`). Review each file we
  take; it's a two-day-old project.
- **stdio relay:** Godot itself, run with no window, acts as the program a
  stdio client launches. It reads JSON-RPC on stdin, forwards each message to
  the editor, and prints the reply. The config writer puts the editor's own
  executable path in the config (`OS.get_executable_path()`), so there is no
  PATH problem. The relay runs from a tiny separate project inside the addon,
  so the user's own autoloads are not loaded by it.
- **One core:** both front doors call the same dispatcher, so every tool works
  the same way through either.

## What the spike proved (2026-10-10, Godot 4.7.2 on Linux)

The spike script is `docs/spikes/mcp_relay_spike.gd`.

| Question | Result |
|---|---|
| Can `godot --headless --script` serve MCP over stdio? | Yes |
| Startup to first reply | 0.14 s |
| A tool call relayed to a live editor | 17 ms |
| stdout is clean JSON only? | Yes, with `--no-header` |
| Ids come back as integers? | Yes, after converting (Godot's JSON turns every number into a float) |
| stderr clean, exit code 0 when stdin closes? | Yes |
| Editor not running | A clear error: "the editor is not running (no bridge on port N)" |
| A real client? | Claude Code launched it as a stdio server, called `list_scene_tree`, and got the live editor's answer ("Level, Node3D") |

Gotchas found: `--quiet` silences **all** printing, including our replies, so
use `--no-header` instead; the stdin-reading thread must be finished before
quitting; ids must be converted back to integers.

**Not yet verified:** Windows and macOS (stdout and stdin behaviour,
paths with spaces), `--no-header` on older Godot versions (we need 4.4+),
the relay's memory use, and any HTTP client against an in-editor server.

## Tool list and dispatch

Our tool definitions are in TypeScript (about 24,000 tokens for 100 tools).

1. **Export them to `tools.json`** at build time and ship that in the addon.
   The TypeScript stays the source of truth at first, and the in-editor server
   serves the same list.
2. **Generic dispatch:** most tools pass their arguments straight to a bridge
   command of the same name. One generic path handles those.
3. **Adapters** for the tools that reshape arguments or results: images
   (`get_*_screenshot`, `capture_game_frames`), tables (`monitor_game_properties`),
   argument defaults and renames, and the tools that live only in Node
   (`search_assets`, `install_asset`: redo with Godot's `HTTPRequest` and
   `ZIPReader`), the runtime-game tools, and `get_perf_stats`. Phase 0 makes
   the exact list.
4. **Node-only tools stay in Node:** the ones that launch Godot from a command
   line (`launch_editor`, `run_project`), which don't make sense inside a
   running editor.
5. **Tool groups:** a newcomer doesn't need 100 tools in every conversation.
   Let the user switch groups on and off (Lite / Full), as Funplay does.

## Phases

Each phase ends with a live test on a scratch editor.

**0. Review and inventory.** Read Funplay's transport, request handler and
config writer. List every Node-side adapter. Decide where the tool list lives.
*Done when:* a short note says what we take from Funplay, and a table lists
each tool as generic or adapter.

**1. Core and stdio relay.** `mcp_core.gd` with `initialize`, `tools/list`,
`tools/call`, `ping` and notifications; the generated `tools.json`; generic
dispatch; the relay made production-ready (clear errors, `--no-header`, relay
arguments, version check) and a `mcp_request` bridge command.
*Done when:* Claude Code, configured with only the relay command, can run our
regression drivers (`tests/script_io.mjs` and a tour scenario) against a
scratch editor with the Node server stopped.

**2. HTTP transport.** Adapt Funplay's transport; per-project port with a free
port picked automatically and "attach to the editor that already serves this
project"; token header; Host and Origin checks; body and header size limits.
*Done when:* Claude Code over HTTP works, and tests show rejection of a wrong
token, a foreign Origin or Host, an oversized body and malformed JSON.

**3. Adapters to parity.** Port the special tools one by one. A parity harness
runs one call list through both the Node server and the in-editor server and
compares results.
*Done when:* every tool in the inventory is either at parity or deliberately
Node-only.

**4. Connect buttons.** Port Funplay's config writer: Claude Code (the
project's `.mcp.json`), Cursor, VS Code, Codex, Claude Desktop, and "copy
config". A first-run card in the panel. A three-step README.
*Done when:* on a clean machine with no Node, someone installs the addon,
presses Connect, and an agent controls the editor.

**5. Packaging and submission.** Addon folder layout, `plugin.cfg`,
`THIRD_PARTY_NOTICES`, an install zip containing only the addon, version
number and update notice. Submit to the old Asset Library first. The editor's
Asset Store tab in 4.7 only searches the new store, so also submit there.
*Done when:* installing from the store works on a fresh project.

**6. Other systems.** Windows and macOS runs of phases 1–4, paths with spaces,
`--no-header` on Godot 4.4–4.7 (with a fallback that filters the banner if the
flag is missing).

## Trade-offs and risks

- **It stops when the editor stops.** The Node server survives editor
  restarts. Clients show "failed to connect" until the editor is back, and
  `restart_editor` stops being something an agent can do and then continue.
- **Two editors on one project.** The port clash we hit earlier. Per-project
  ports and "attach to existing" address it.
- **Long calls.** Godot's main thread is single, so an editor busy with a long
  operation answers late (the same as the Node path today). Keep client
  timeouts in mind.
- **Large replies.** Screenshots are big base64 strings; check the HTTP body
  limit and GDScript string handling.
- **Tokens in plain text.** The token ends up in config files, as it does now.
  Keep config files per project and out of version control.
- **Keep Node.** The Node server remains for CI, headless use and the tools
  that launch Godot. Both read the same `tools.json`, so they can't drift.
