# In-editor MCP server — no Node, install from the store

Draft, 2026-10-10; restructured 2026-10-11 (HTTP mode first, stdio mode
conditional). Companion to the other plans in this folder.

## The goal

Someone new to Godot installs the addon from the Asset Library, enables it,
and presses **Connect to Claude Code** (or Cursor, VS Code, Codex). No Node,
no terminal, no config file to edit. Today the MCP server is a separate Node
program, which is the biggest install hurdle.

Code inside the editor has to be GDScript: C# only exists in the .NET edition
of Godot, and native extensions need a build per platform. GDScript is also
what the addon already is (about 10,000 lines), so this is more of the same.

## Terms

| Term | Meaning |
|---|---|
| **MCP client** | The AI app (Claude Code, Cursor, Claude Desktop, ChatGPT desktop). |
| **HTTP mode** | The client connects to a URL where the editor itself serves MCP. The client's config calls this a `url`. **The default.** |
| **stdio mode** | The client launches a program and talks to it through stdin and stdout. The client's config calls this a `command`. Optional, built later (phase 6). |
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
 HTTP mode (Claude Code, Cursor, VS Code, Codex, the AI Assistant panel)
        │  POST http://127.0.0.1:<port>/mcp  (token, Host/Origin checks)
        ▼
 ┌──────────────────────────────┐
 │  mcp_core.gd (in the editor) │  initialize · tools/list · tools/call · ping
 │  tool list (tools.json)      │  → the bridge's existing _cmd_* functions
 └──────────────────────────────┘
        ▲
        │  one authenticated local TCP request ("mcp_request")      [phase 6]
 stdio mode (Claude Desktop, anything that launches a program)
        │
   godot --headless --no-header --path <addon>/relay --script res://mcp_relay.gd -- <port> <token>
```

- **HTTP mode:** adapt Funplay's transport (MIT, about 220 lines; keep their
  copyright notice and license in `THIRD_PARTY_NOTICES`). Review each file we
  take; it's a two-day-old project. Funplay does check Host, Origin and
  Referer, but weakly (absent headers pass, the token is optional, the compare
  is not constant-time); we make all of them mandatory (see phase 1 and
  `docs/phase0_inventory.md`).
- **stdio mode, via the relay:** Godot itself, run with no window, acts as the
  program a stdio client launches. It reads JSON-RPC on stdin, forwards each
  message to the editor, and prints the reply. The config writer puts the
  editor's own executable path in the config (`OS.get_executable_path()`), so
  there is no PATH problem. The relay runs from a tiny separate project inside
  the addon, so the user's own autoloads are not loaded by it. Funplay's stdio
  option is an npm wrapper, so it needs Node; ours would not.
- **The relay outlives the editor.** It is the only part of the design that
  keeps running while the editor is stopped, so it can own the lifecycle:
  waiting for the editor, and launching or restarting it (see "Editor
  restarts" below).
- **One core:** both modes call the same dispatcher, so every tool works
  the same way through either.

## Which mode, for whom

**HTTP mode is the default for everything.** Stdio mode is optional and
built later, only if the decision gate in phase 6 says it is needed.

| Client | Mode | Notes |
|---|---|---|
| Claude Code, Codex, Cursor, VS Code | HTTP mode | Docs for Cursor and VS Code list `http` / `url` servers and use `localhost` in their examples; Codex supports Streamable HTTP with a bearer token. Each still needs one live test against our server. |
| ChatGPT desktop (the Codex host) | HTTP mode (probable) | Docs list Streamable HTTP and a `localhost` example; not yet tested. Plain ChatGPT web chat accepts only a public HTTPS address, so it cannot reach us (nor the Node server). |
| The AI Assistant panel (`assistant_panel.gd`): `claude` or `codex` started in the editor's GodotXterm terminal or chat view | HTTP mode, written by the panel | The editor is open by definition, and a URL plus token need no second process. |
| Claude Desktop | stdio mode, if it is a target | Cannot use HTTP mode. Its custom connectors are reached from Anthropic's servers, not from the user's machine, so a `127.0.0.1` URL is unreachable; a certificate (self-signed or real) does not change that. A public tunnel would work but exposes `eval_expression` and `run_script` to the internet, so we do not offer it. Local servers use its config file, which launches a command. The existing `mcp-remote` workaround needs Node. Only the relay is a Node-free route. |

Client facts come from vendor docs and third-party guides, not live tests.
HTTPS is not needed for clients that connect from the user's machine (Cursor,
VS Code, Codex, Claude Code): they accept `http://localhost`, and a
self-signed certificate would only add trust errors.

## What the spike proved (2026-10-10, Godot 4.7.2 on Linux)

This is about stdio mode. The spike script is `docs/spikes/mcp_relay_spike.gd`.

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

**Not yet verified:** any HTTP client against an in-editor server (this is
phase 1), and for the relay: Windows and macOS (stdout and stdin behaviour,
paths with spaces), `--no-header` on older Godot versions (we need 4.4+), and
the relay's memory use.

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
   running editor. In stdio mode the relay can take over launch and restart
   (see below).
5. **Tool groups:** a newcomer doesn't need 100 tools in every conversation.
   Let the user switch groups on and off (Lite / Full), as Funplay does with
   its `core` and `full` profiles. Ship this with phase 1; it is worth doing
   whichever mode is used.

## Editor restarts

Goal: an agent can ask for the editor to restart, wait, and carry on without
the user reconnecting anything.

**HTTP mode (best effort, the default):** the server dies with the editor and
the client's connection drops. Whether the client retries or loses the tools
until reconnected varies by client, so autonomy is not promised. Document this,
and tell users whose agent must restart the editor and continue to use an
external terminal, or stdio mode once it exists.

**Agents run from the AI Assistant panel** are children of the editor, so
`restart_editor` ends them in either mode. They recover through the panel's
saved session resume, not through any server. Document that an agent which must
survive editor restarts runs in an external terminal.

**Always:** `reload_plugin` and `restart_editor` stop the server that is
answering them, so the reply is flushed first. The port and token are fixed per
project and persisted (the token file already is), so a client's config stays
valid after a restart.

**stdio mode (planned, phase 6):**
- **Wait and retry.** When the editor is unreachable, a `tools/call` retries
  the connection for a bounded time (default 60 s, configurable) before it
  returns the "editor is not running" error. The agent's next call just blocks
  until the editor is back.
- **Relay-owned `restart_editor` and `launch_editor`.** The relay knows the
  Godot executable and the project path (both passed as relay arguments). To
  restart: ask the editor to save and quit, wait for the port to close,
  relaunch Godot on the project, then poll until the bridge answers. If the
  editor is simply not running, the same code launches it.
- **Tools before the editor opens.** The relay can answer `tools/list` from
  `tools.json` without the editor running.

## Phases

Each phase ends with a live test on a scratch editor.

**0. Review and inventory.** Read Funplay's transport, request handler and
config writer. List every Node-side adapter. Decide where the tool list lives.
*Done when:* a short note says what we take from Funplay, and a table lists
each tool as generic or adapter.

**1. Core and HTTP mode.** `mcp_core.gd` with `initialize`, `tools/list`,
`tools/call`, `ping` and notifications; the generated `tools.json` and the
Lite / Full tool groups; generic dispatch. Adapt Funplay's transport:
per-project port with a free port picked automatically and "attach to the
editor that already serves this project"; token header; Host and Origin checks
(mandatory, with no way to switch them off); body and header size limits;
persisted port and token.
*Done when:* Claude Code over HTTP can run our regression drivers
(`tests/script_io.mjs` and a tour scenario) against a scratch editor with the
Node server stopped, one live check each passes for Cursor, VS Code and Codex
(including whether `127.0.0.1` or only `localhost` is accepted), and tests show
rejection of a wrong token, a foreign Origin or Host, an oversized body and
malformed JSON.

*Status (2026-10-11):* core, `tools.json`, Lite / Full groups, generic
dispatch, the HTTP server and its security checks are built
(`mcp_core.gd`, `mcp_endpoint.gd`, `mcp_http_*.gd`). 51 headless checks cover
the rejection cases (`tests/mcp_http`). Live on a scratch editor: Claude Code
over HTTP, `tests/script_io.mjs` and `tests/tour_scenario.mjs` pass identically
through Node and through HTTP (`MCP_URL` / `MCP_TOKEN`); `reload_plugin`'s
reply arrives before the server restarts, and a second editor attaches instead
of clashing. Client checks: Codex (call tools, with
`default_tools_approval_mode="approve"`) and opencode (connects) pass, along
with Claude Code; `localhost` and `127.0.0.1` both work. Cursor and VS Code
are still unchecked (not installed / needs the UI), as are the Windows and
macOS runs (phase 4).

**2. Adapters to parity.** Port the special tools one by one. A parity harness
runs one call list through both the Node server and the in-editor server and
compares results.
*Done when:* every tool in the inventory is either at parity or deliberately
Node-only.

*Status (2026-10-11):* all 105 tools that belong in the editor are served
(27 Lite, 105 Full): generic editor tools, the running-game tools (the core
talks to the game's bridge on port 9090), the image, frame and table adapters,
and `search_assets` / `install_asset` (Godot `HTTPRequest` for the download;
the bridge's existing `install_asset_zip` unpacks, so `ZIPReader` was not
needed). `tests/parity.mjs` runs 56 calls through Node and through the editor
and they match, as do the 105 tool definitions; `GAME=1` adds the game tools
against a running game. An installed asset's reply is byte-identical.
`get_script_diagnostics`, the lifecycle tools and the usage-log tools stay in
Node. Not covered: screenshot and frame capture against a real renderer (a
headless editor has none; the result shaping is unit-tested instead,
`tests/mcp_http/adapters_test.gd`).

**3. Connect buttons.** Port Funplay's config writer for HTTP mode: Claude Code
(the project's `.mcp.json`, which VS Code's portable format also reads, so one
write may serve both; confirm each client's schema), Cursor
(`.cursor/mcp.json`), VS Code, Codex, and "copy config". Where a client
supports it, write the token as an environment or input reference
(`${env:…}` in Cursor, `${input:…}` in VS Code) instead of the raw value. A
first-run card in the panel. A three-step README. Update the AI Assistant
panel's config builders (`_mcp_config_args` for Claude and the
`-c mcp_servers.godot-live-mcp…` block for Codex) to hand out the HTTP mode URL
and token instead of the `node` entry.
*Done when:* on a clean machine with no Node, someone installs the addon,
presses Connect, and an agent controls the editor.

**4. Other systems (HTTP mode).** Windows and macOS runs of phases 1–3, and a
check on the Godot versions we support (4.4+).
*Done when:* the phase 3 clean-machine test passes on Windows and macOS.

**5. Packaging and submission.** Addon folder layout, `plugin.cfg`,
`THIRD_PARTY_NOTICES`, an install zip containing only the addon, version
number and update notice. Submit to the old Asset Library first. The editor's
Asset Store tab in 4.7 only searches the new store, so also submit there.
*Done when:* installing from the store works on a fresh project.

**6. stdio mode (the relay), conditional.** First apply the decision gate:

- *Skip it if both hold:* we decide Claude Desktop is not a target (it cannot
  use HTTP mode, see "Which mode, for whom"), and nobody needs agents outside
  the editor to restart the editor and carry on.
- *Build it if either fails.*

If built: make the relay production-ready (clear errors, `--no-header`, relay
arguments, version check), add a `mcp_request` bridge command, the wait-and-retry
mode, the relay-owned `restart_editor` / `launch_editor`, and a stdio option on
the Connect buttons (including Claude Desktop). Label it advanced or
experimental in the UI. Then verify Windows and macOS (stdin and stdout
behaviour, paths with spaces), `--no-header` on Godot 4.4–4.7 (with a fallback
that filters the banner if the flag is missing), and executable paths on
Flatpak and Steam installs.
*Done when:* Claude Code, configured with only the relay command, runs the
regression drivers with the Node server stopped; an agent can call
`restart_editor`, wait, and make its next tool call with no manual step; and
the same holds on Windows and macOS.

Until then, Node stays the stdio server for anyone who has it.

## Trade-offs and risks

- **It stops when the editor stops.** The Node server survives editor
  restarts. In HTTP mode clients show "failed to connect" until the editor is
  back, and may need a manual reconnect. Stdio mode would cover this (see
  "Editor restarts").
- **Browser-reachable code execution.** `eval_expression` and `run_script`
  become reachable from a web page via DNS rebinding or CSRF. Token plus
  Host and Origin checks are mandatory in phase 1, with no switch to turn them
  off. Funplay's own README warns that authenticated clients can run
  high-impact tools; keep the server enabled only with trusted local clients.
- **Two editors on one project.** The port clash we hit earlier. Per-project
  ports and "attach to existing" address it.
- **Long calls.** Godot's main thread is single, so an editor busy with a long
  operation answers late (the same as the Node path today). Keep client
  timeouts in mind. Also check that the server stays responsive when the
  editor window is unfocused.
- **Large replies.** Screenshots are big base64 strings; check the HTTP body
  limit and GDScript string handling.
- **Tokens in plain text.** The token ends up in config files, as it does now.
  Keep config files per project and out of version control; prefer
  environment or input references where the client supports them.
- **No Claude Desktop in HTTP mode.** Custom connectors are reached from
  Anthropic's servers, so localhost cannot work, with or without HTTPS. We do
  not offer a public tunnel because the server runs arbitrary code in the
  editor.
- **Managed setups.** Some Cursor admin setups restrict remote MCP URLs to
  approved patterns, so a localhost URL may be blocked there. VS Code blocks
  workspace servers in restricted mode.
- **Store review.** The Asset Library may object to an addon that writes
  config files outside the project (`~/.cursor`, user-level configs). Make
  writes explicit and opt-in, with "copy config" as the safe default.
- **Keep Node.** The Node server remains for CI, headless use and the tools
  that launch Godot. Both read the same `tools.json`, so they can't drift.
