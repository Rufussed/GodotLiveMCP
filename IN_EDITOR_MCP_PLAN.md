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

## Terms

| Term | Meaning |
|---|---|
| **MCP client** | The AI app (Claude Code, Cursor, Claude Desktop, ChatGPT desktop). |
| **HTTP mode** | The client connects to a URL where the editor itself serves MCP. The client's config calls this a `url`. |
| **stdio mode** | The client launches a program and talks to it through stdin and stdout. The client's config calls this a `command`. |
| **Relay** | The program used in stdio mode: Godot run with no window, translating stdio MCP into bridge calls. It outlives the editor. |
| **Bridge** | The existing token-authenticated local TCP link into the editor (`_cmd_*` commands). The relay and the Node server both use it. |
| **Core** | `mcp_core.gd`, the MCP dispatcher inside the editor that both modes share. |

Use these terms everywhere in the plan, code and docs. Say "stdio mode (via
the relay)", never "pipes", and never treat the relay as a rival to HTTP: it
is how stdio mode works. Users never see "HTTP" or "stdio": each Connect
button picks the mode, and the "copy config" view labels the two by what the
client asks for, **URL** or **Command**.

## Two modes, one core

```
 HTTP mode (Claude Code, Cursor, VS Code, Codex)
        │  POST http://127.0.0.1:<port>/mcp  (token, Host/Origin checks)
        ▼
 ┌──────────────────────────────┐
 │  mcp_core.gd (in the editor) │  initialize · tools/list · tools/call · ping
 │  tool list (tools.json)      │  → the bridge's existing _cmd_* functions
 └──────────────────────────────┘
        ▲
        │  one authenticated local TCP request ("mcp_request")
 stdio mode (Claude Desktop, anything that launches a program)
        │
   godot --headless --no-header --path <addon>/relay --script res://mcp_relay.gd -- <port> <token>
```

- **HTTP mode:** adapt Funplay's (MIT, about 220 lines; keep their
  copyright notice and license in `THIRD_PARTY_NOTICES`). Review each file we
  take; it's a two-day-old project.
- **stdio mode, via the relay:** Godot itself, run with no window, acts as the program a
  stdio client launches. It reads JSON-RPC on stdin, forwards each message to
  the editor, and prints the reply. The config writer puts the editor's own
  executable path in the config (`OS.get_executable_path()`), so there is no
  PATH problem. The relay runs from a tiny separate project inside the addon,
  so the user's own autoloads are not loaded by it.
- **The relay outlives the editor.** It is the only part of the design that
  keeps running while the editor is stopped, so it also owns the lifecycle:
  waiting for the editor, and launching or restarting it (see "Editor
  restarts" below). HTTP mode cannot do this, so stdio mode is the
  recommended mode for agents that restart the editor.
- **One core:** both modes call the same dispatcher, so every tool works
  the same way through either.

## Which mode, for whom

**Default for external clients: stdio mode.** HTTP mode is the alternative.
This holds only if stdio mode verifies on Windows and macOS (phase 6); if it
does not, HTTP mode becomes the default and restart support is documented as
limited.

| Client | Mode | Why |
|---|---|---|
| External: Claude Code or Codex in an outside terminal, Claude Desktop, ChatGPT desktop, Cursor, VS Code | stdio mode (Connect button default), HTTP mode on request | The relay outlives the editor: wait-and-retry, tools listed before the editor opens, relay-owned launch and restart. Every client that takes a local server supports stdio. |
| The AI Assistant panel (`assistant_panel.gd`): `claude` or `codex` started in the editor's GodotXterm terminal or chat view | HTTP mode, written by the panel | The agent is a child of the editor, so an editor restart kills it and the relay with it. The panel's saved session resume already covers that. The editor is open by definition. A URL and token need no second Godot process. |

Client support is confirmed for Codex and probable for ChatGPT desktop
(HTTP mode) and for Claude Desktop (stdio mode). Cursor and VS Code are not
yet checked, and whether Claude Desktop accepts a localhost URL is open.

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

## Editor restarts

Goal: an agent can ask for the editor to restart, wait, and carry on without
the user reconnecting anything.

**stdio mode (supported):**
- **Wait and retry.** When the editor is unreachable, a `tools/call` retries
  the connection for a bounded time (default 60 s, configurable) before it
  returns the "editor is not running" error. The agent's next call just blocks
  until the editor is back.
- **Relay-owned `restart_editor` and `launch_editor`.** The relay knows the
  Godot executable and the project path (both passed as relay arguments). To
  restart: ask the editor to save and quit, wait for the port to close,
  relaunch Godot on the project, then poll until the bridge answers. If the
  editor is simply not running, the same code launches it. This keeps both
  tools in the in-editor design.
- **Stable port and token.** The port and token are fixed per project and
  persisted (the token file already is). Otherwise the relay's launch
  arguments would be stale after a restart.
- **Reply before teardown.** `reload_plugin` and `restart_editor` stop the
  server that is answering them, so the reply is flushed first.

**HTTP mode (best effort):** the server dies with the editor and the
client's connection drops. Whether the client retries or loses the tools until
reconnected varies by client, so autonomy is not promised. Document this, and
tell HTTP mode users to switch to stdio mode if their agent restarts the editor.

**Agents run from the AI Assistant panel** are children of the editor, so
`restart_editor` ends them in either mode. They recover through the panel's
saved session resume, not through the relay. Document that an agent which must
survive editor restarts runs in an external terminal.

## Phases

Each phase ends with a live test on a scratch editor.

**0. Review and inventory.** Read Funplay's transport, request handler and
config writer. List every Node-side adapter. Decide where the tool list lives.
*Done when:* a short note says what we take from Funplay, and a table lists
each tool as generic or adapter.

**1. Core and stdio mode (the relay).** `mcp_core.gd` with `initialize`, `tools/list`,
`tools/call`, `ping` and notifications; the generated `tools.json`; generic
dispatch; the relay made production-ready (clear errors, `--no-header`, relay
arguments, version check) and a `mcp_request` bridge command. Also the wait-and-retry mode, the relay-owned
`restart_editor` / `launch_editor`, and the persisted per-project port and
token (see "Editor restarts").
*Done when:* Claude Code, configured with only the relay command, can run our
regression drivers (`tests/script_io.mjs` and a tour scenario) against a
scratch editor with the Node server stopped, and an agent can call
`restart_editor`, wait, and make its next tool call with no manual step.

**2. HTTP mode.** Adapt Funplay's transport; per-project port with a free
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
config". A first-run card in the panel. A three-step README. Update the
AI Assistant panel's config builders (`_mcp_config_args` for Claude and the
`-c mcp_servers.godot-live-mcp…` block for Codex) to hand out the HTTP mode
URL and token instead of the `node` entry. Connect buttons write stdio mode by
default, with an HTTP mode option.
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
  restarts. In stdio mode this is covered by wait-and-retry and relay-owned
  restart (see "Editor restarts"). In HTTP mode clients show "failed to connect"
  until the editor is back, and may need a manual reconnect.
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
