# Phase 3 design: Connect buttons

Draft, 2026-10-11. Implements phase 3 of `IN_EDITOR_MCP_PLAN.md`. Nothing here
is built yet. Items marked **(confirm)** are client behaviour I have not tested
and the first step of building will be to test them.

## Goal and test

On a machine with no Node, a newcomer enables the addon, presses one button,
and their AI app controls the editor. *Done when* that works with the Node
server absent (empty `PATH` entry for `node`, a throwaway `HOME`), for Claude
Code, Codex and VS Code at least.

## What exists today (so we change as little as needed)

`assistant_panel.gd` already launches `claude`, `codex`, `opencode` and
`gemini` for this project, and each launcher hands the agent a **Node** server
entry plus the token (`_spec_claude`, `_spec_codex`, `_opencode_config`,
`_spec_gemini`, `_mcp_config_args`, `_ensure_local_registration`). Two things
about it are worth keeping:

- Claude is registered with `claude mcp add -s local`, which stores the token in
  `~/.claude.json` against the project folder, never in a project file.
- The server name is `godot-live-mcp`, and the panel's permission lists and
  `CLAUDE.md.template` refer to `mcp__godot-live-mcp__*`. Project-scoped
  entries keep that name.

One thing to fix while we are there: Codex gets the token on its command line
(`-c …env.GODOT_LIVE_MCP_TOKEN=…`), which any local user can read with `ps`.

## 1. The server entry, per client

Every entry points at the endpoint (`http://127.0.0.1:<port>/mcp`, from
`mcp_endpoint.gd`) and carries `Authorization: Bearer <token>`.

| Client | Where the entry goes | Token handling | Notes |
|---|---|---|---|
| Claude Code | `claude mcp add -s local --transport http godot-live-mcp <url> -H "Authorization: Bearer …"` (the CLI supports `-H`) | In `~/.claude.json` per project, as today | Same mechanism as now, so no change in where secrets live. Skipped on Windows today; phase 4 decides the Windows route |
| VS Code | project `.vscode/mcp.json`, `"type": "http"` | `"Authorization": "Bearer ${input:godot-token}"` plus a `promptString` input; VS Code asks once and remembers **(confirm)** | The file holds no secret, so it is safe to commit |
| Cursor | user-level `~/.cursor/mcp.json`, entry `godot-<project>` | Literal token in a file outside the project | Project-level `.cursor/mcp.json` would need `${env:…}`, which asks the user to set an environment variable; we avoid that **(confirm both)** |
| Codex | user-level `~/.codex/config.toml`, section `[mcp_servers.godot-<project>]`, `url` plus `http_headers` | Literal token in a file outside the project | `codex mcp add` only takes `--bearer-token-env-var`, so we write the TOML ourselves; confirm `http_headers` works **(confirm)**. Do **not** set auto-approve for external use (the panel's own Codex launch keeps it) |
| opencode | `mcp` block `{type: "remote", url, headers}` in `OPENCODE_CONFIG_CONTENT` (panel) | Env var of the launched process | Connected in the phase 1 check |
| Gemini CLI | project `.gemini/settings.json` (as now), HTTP form | Literal token in a project file, as today (the panel already warns to gitignore it) | Field name for the URL **(confirm)**; Gemini's `mcp add -H` exists as a cross-check |
| Any other / "Copy config" | A dialog with two tabs, **URL** and **Command**, each a ready snippet | Token shown masked with a Show button | Command tab is the stdio relay and stays hidden until phase 6 exists |

User-level entries are named `godot-<project slug>` so two projects don't
overwrite each other. Project-scoped entries keep `godot-live-mcp`.

## 2. Panel-launched agents

Switch the four launchers to the HTTP entry, built by one helper
(`_server_connection()` returns `{mode, url, token}`), instead of four copies of
the Node entry.

- **Default: HTTP.** It is what a newcomer gets, so it is also what we test.
- **Node when usage data is on.** The opt-in tool-usage log (`callLog.ts`,
  `log_intent` / `log_result`) exists only in the Node server, and the
  tool-candidate review depends on it. So `_tool_data_enabled()` selects the
  Node entry, exactly as today. No setting to add.
- **Fallback.** If the endpoint is not serving (disabled, no port), use the Node
  entry when it can be found, as now; otherwise say so in the transcript.
- Codex and opencode carry the token in the launched process's environment
  (`bearer_token_env_var` / `OPENCODE_CONFIG_CONTENT`), not on a command line.

Cost: panel agents lose the 17 Node-only tools unless usage data is on.
`get_script_diagnostics` is the only one that matters in practice;
`validate_script` covers most of it.

## 3. The Connect UI

Lives in the AI Assistant panel, two places:

1. **First-run card** at the top of the panel until dismissed, shown when the
   endpoint is serving and no client has called it yet:
   *"Connect your AI app"* with buttons **Claude Code · Codex · VS Code ·
   Cursor · More…** (More opens the copy-config dialog and opencode / Gemini).
2. **Settings popup → "Connect" section**, always available, same buttons plus
   the tool group (**Lite / Full**) and a *Regenerate token* button.

Each button: shows exactly what will be written (file path, the entry with the
token masked), asks to confirm, writes, then shows "Waiting for Claude Code…"
until the endpoint sees that client's `initialize` (its `clientInfo`), then
"Connected". That live line is how a newcomer knows it worked. The core records
the last client name and time; the panel reads it.

Writes are opt-in and explicit. First write to any file makes a `.bak` copy, a
file that is not valid JSON is never touched (Funplay's rule, kept), user-level
files holding a token are set to owner-only permissions where the OS allows.
"Copy config" is the no-write path for anyone, including store reviewers.

**Tool group** is saved in `godot_live_mcp_http.cfg` and applies to the next
client session. The endpoint has no event stream, so it cannot push a
tools-changed notice; the panel says so.

**Upgrade rule:** a first run that finds an existing bridge token file (an
earlier install) defaults to Full, so people already using the addon don't lose
tools; a clean install defaults to Lite.

## 4. Code layout

- `connect_clients.gd` (new, no UI): the table above as data, `build_entry()`,
  `target_path()`, JSON merge, TOML merge (adapted from Funplay's writer, which
  is why `THIRD_PARTY_NOTICES` already names it), backup, permissions. Pure
  functions over strings and paths, so it can be tested headless.
- `connect_ui.gd` (new): the card, the dialogs, the status line. Called from
  `assistant_panel.gd`, which gains a few lines rather than a big edit.
- `mcp_core.gd`: remember the last `clientInfo` and a timestamp; a signal.
- `assistant_panel.gd`: `_server_connection()` and the four launcher edits.

## 5. Build order and tests

1. **`connect_clients.gd` plus tests, no UI.** Headless tests with a temporary
   `HOME`: merges keep other servers, invalid JSON is refused, TOML merge
   keeps nested tables, re-running changes nothing, backup is made,
   permissions are set. Then **confirm** each client's format by pointing the
   real CLI at the written file: `claude mcp list`, `codex mcp list`,
   `opencode mcp list`, `gemini mcp list`, all with a throwaway `HOME`, so no
   real config is touched.
2. **Panel launchers on HTTP**, with the Node fallback; live-check a Claude and
   a Codex turn through the panel.
3. **Connect UI and status line.** Needs a real display to see; I'll build it
   and ask you to look rather than guess at layout.
4. **README** (three steps) and a pass over `CLAUDE.md.template`, then the
   no-Node clean-machine test from the goal.

## Decisions I need from you

1. **Panel default = HTTP, Node only when usage data is on?** (My
   recommendation, section 2.) The alternative is to keep Node first and use
   HTTP only when Node is missing; that changes nothing for you today but means
   the maintainer never exercises the path newcomers get.
2. **Where tokens may live.** My plan: Claude in `~/.claude.json`, Cursor and
   Codex in their user-level files, VS Code via an input prompt (nothing in the
   file), Gemini in its project file as now. Say if any of those writes is more
   than you want an addon to do, in which case that client gets "Copy config"
   only.
3. **Endpoint on by default?** It is today. With the Connect card it could
   instead start only after the first Connect press. (My recommendation: leave
   it on; it is token-protected and loopback-only like the bridge.)
4. **Upgrade rule** (existing installs default to Full, clean installs to Lite):
   fine, or always Lite?
