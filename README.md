# GodotLiveMCP

An MCP server that lets an AI coding agent drive a **running** Godot 4.x editor
session directly, not just edit files on disk. See
[GodotLive_Project_Brief.md](GodotLive_Project_Brief.md) for the full rationale and scope.

Two parts:

- **`addon/godot_live_mcp/`** — two headless bridges. `bridge.gd` is a Godot
  editor plugin listening on `127.0.0.1:9080` for JSON commands against the
  editor's live scene tree: eval, property get/set (including nested
  sub-resources, array elements, and dictionary keys), transform, node CRUD,
  signals, groups, physics/collision, 3D materials and shaders, animation
  (including state machines), navigation baking, audio buses, tilemaps,
  particles, theme/UI, editor screenshots, the Output/Debugger panels'
  errors (`get_output_log`, in memory only), tools to see and operate the
  editor's own UI (screenshots, control-tree dumps, clicks, drops), and its own Play/Stop/reload/
  restart control. Property changes and node add/remove/rename/reparent/
  duplicate route through Godot's own `EditorUndoRedoManager`, so
  bridge-driven edits get the same save-prompt and Ctrl+Z behavior as
  manual edits, and follow along in a game running from the editor. `runtime_bridge.gd` is an optional
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

Prerequisites: [Node.js](https://nodejs.org) 18+ and at least one coding agent CLI,
installed and logged in: [Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex), [OpenCode](https://opencode.ai) or
[Gemini CLI](https://github.com/google-gemini/gemini-cli).

Why Node.js? The MCP server, the program your agent CLI starts to talk to the editor, is a
Node.js program (`node server/build/index.js`); `npm install` builds it. Nothing else here
needs Node.

**Easiest: the launcher app.** Clone the repo, then start the launcher with
the script for your system, from the repo folder:

```
git clone https://github.com/Rufussed/GodotLiveMCP.git
```

- **macOS:** double-click `launch.command` in Finder. It finds Godot via
  `$GODOT`, a `godot` command, or any `Godot*.app` in `/Applications` or
  `~/Applications`. If macOS says it isn't allowed to run, run
  `chmod +x launch.command` once.
- **Windows:** double-click `launch.bat`. It uses `%GODOT%` or `godot` on
  PATH; otherwise it asks you to drag the Godot `.exe` into its window
  once and remembers it (in `launcher/.godot_path`).
- **Linux:** run `./launch.sh`. It uses `$GODOT`, `godot`, `godot4` or the
  Flatpak (`org.godotengine.Godot`).

You can also open `launcher/project.godot` in Godot and press Play, or run
`godot --path launcher` (on macOS:
`/Applications/Godot.app/Contents/MacOS/Godot --path launcher`).

Run from a clone, the launcher `git pull`s it on every launch (only when
it's on `main` with no uncommitted changes) and rebuilds the server when
updates arrive. Copied somewhere on
its own (just the `launcher/` folder), it downloads GodotLiveMCP itself with
git into a per-user folder (`~/.local/share/GodotLiveMCP`,
`~/Library/Application Support/GodotLiveMCP` or `%APPDATA%\GodotLiveMCP`),
pulls updates on every launch and rebuilds the server when they arrive.

The launcher checks for Git, Node, npm and which coding agent CLIs are installed (at least one is
needed), then walks through three
steps: **Install / rebuild MCP server**; **Create new Godot project…** or
**Add existing Godot project…**, which links the addon, enables the plugin
and adds `CLAUDE.md` / `AGENTS.md`; then **Open in Godot** (which closes
the launcher) or **Unlink**. On macOS, if a popup asks to install the
command line developer tools, accept it (or run `xcode-select --install`).
The steps below do the same from a terminal.

**Optional: the in-editor CLI view (Linux and macOS).** The launcher also has an
"Optional — terminal panel" section. **Download GodotXterm** fetches the latest release of
[GodotXterm](https://github.com/lihop/godot-xterm) (MIT, about 11 MB) once into a per-user folder;
**Add terminal** on a project then links it in, the way the addon is linked, so one download
serves every project and **Update GodotXterm** updates them all. With it, the AI Assistant tab
gets a **CLI** mode. Restart the editor if the project is open. From a terminal:
`npm run link-project -- /path/to/project --xterm /path/to/godot_xterm` (and `--unlink-xterm`).
Installing GodotXterm yourself, for example from the AssetLib, works just as well.

1. Clone this repo and build the server (`npm install` builds it too):
   ```
   git clone https://github.com/Rufussed/GodotLiveMCP.git
   cd GodotLiveMCP/server
   npm install
   ```
2. Link the addon into your Godot project (the folder containing
   `project.godot`). This also enables the plugin in `project.godot` and
   adds the agent instructions as `CLAUDE.md`, with `AGENTS.md` linked to
   it for Codex (existing files are left alone):
   ```
   npm run link-project -- /path/to/your/godot/project
   ```
   This creates `addons/godot_live_mcp` in the project as a link back to
   this repo (a directory junction on Windows, no admin rights needed), so
   a later `git pull` updates every linked project at once. If the project
   already has a copied `addons/godot_live_mcp` from an older install, the
   script refuses to touch it; re-run with `--force` to replace it with the
   link.
3. Open the project in Godot. The plugin is already enabled (if the project
   was open while you linked it, reopen it). The bridge generates its auth
   token automatically.
4. Open the **AI Assistant** tab in the bottom panel and type a message (or
   use the **CLI** or **External** modes for a full interactive CLI). The panel
   finds the server through the link and passes it to Claude along with
   this project's token, so there's no MCP config file to edit and no token
   to copy. When the plugin loads, the panel also registers the server for
   this project folder with Claude Code (`claude mcp add -s local`, stored
   in your own Claude config, not in the project's files). That means any
   `claude` session you start in the project folder yourself (a terminal,
   VS Code, a session manager) can control the editor too, alongside the
   panel's own session.

**Optional: one global token.** By default each project gets its own
token, which the panel passes along automatically. If you also want to use
`claude` (or another MCP client) outside the panel, set one token for every
project instead:

1. Generate a token, e.g. `openssl rand -hex 16`.
2. Set it as `GODOT_LIVE_MCP_TOKEN` somewhere Godot will see it. Godot
   launched from a desktop launcher or file manager doesn't read your
   shell's `.bashrc`:
   - **Linux:** add `GODOT_LIVE_MCP_TOKEN=<token>` to
     `~/.config/environment.d/godot-live-mcp.conf`, then log out and back
     in. Also `export` it in `~/.bashrc` if you launch Godot from a
     terminal.
   - **Windows:** `setx GODOT_LIVE_MCP_TOKEN <token>` (or System Properties >
     Environment Variables), then fully restart Godot.
   - **macOS:** `launchctl setenv GODOT_LIVE_MCP_TOKEN <token>` (lasts until
     reboot; use a LaunchAgent to make it permanent).
3. Register the server once with the same token:
   ```
   claude mcp add godot-live-mcp -s user -e GODOT_LIVE_MCP_TOKEN=<token> -- node /path/to/GodotLiveMCP/server/build/index.js
   ```

To confirm, restart Godot and check the Output panel for
`GodotLiveMCPBridge: using GODOT_LIVE_MCP_TOKEN from environment`. If it
says "reusing token cached" or "generated token" instead, Godot didn't see
the variable. The panel keeps working either way, since it reads the token
in the same order the bridge does.

**Codex.** Codex reads `AGENTS.md` (linked to `CLAUDE.md` by
`link-project`) and can only register MCP servers globally:
```
codex mcp add godot-live-mcp -- node /path/to/GodotLiveMCP/server/build/index.js
```
Then start `codex` inside the Godot project folder. The server finds that
project's token itself (from `project.godot`'s name and the token file the
bridge saved), so no token is needed in the registration unless you use a
global one (add `--env GODOT_LIVE_MCP_TOKEN=<token>`); a wrong configured
token also falls back to the project's. The panel's **Codex** button passes the server, token and
the settings popup's preferences (as `developer_instructions`) for you.

**Other MCP clients / manual setup:** you can instead copy
`addon/godot_live_mcp/` into the project's `addons/` folder and register
the server with your MCP client yourself: point it at
`server/build/index.js` with `GODOT_LIVE_MCP_TOKEN` set to the token the
plugin prints in the Output panel. A copied addon doesn't update with
`git pull`; re-copy it after updating.

## How AI edits behave in the editor

The aim is that the AI works in the editor the way a person does.

**Scenes** change in the editor's memory: the tab shows unsaved (*), Godot
asks to save on close, and each tool call is one Ctrl+Z. Nearly every
editing tool goes through Godot's own `EditorUndoRedoManager`: properties
(`set_property`, `set_properties`, `set_properties_multi`,
`batch_set_properties`, `set_transform`, `set_nested_property`), nodes
(`add_node_live` incl. `scene_path` instances, `remove_node`,
`rename_node`, `reparent_node`, `duplicate_node`, `add_mesh_instance`,
`setup_collision`), materials and shaders, animations
(`create_animation`, `add_animation_track`, `set_animation_track_path`,
`set_animation_keys`), scripts attached, signals, groups, physics layers,
anchors, environment, navigation, particles and tilemaps. Signal
connections and groups are saved to the `.tscn`, as with the editor's own
docks. Whether the AI saves as it goes is a panel setting (on by default).

**Scripts and shaders** are edited inside Godot's own script/shader editor
(`edit_script_text`), so there are no "reload from disk?" prompts and
Ctrl+Z works in the tab.

**While a game runs from the editor**, those edits also appear in the game
live (Godot's Debug > Synchronize Scene/Script Changes) and are kept
afterwards, as for a person's editor edits; undo and redo follow along.
Scripts are saved and reloaded in the game. What doesn't reach a running
game:

- **Brand-new resources** (a first material, a new mesh or shape). Godot's
  live sync can only point the game at a file, and a new resource lives
  inside the scene until saved. It appears on the next Play; the tool says
  so (`live_note`). Later edits to it sync live. To use a generated
  texture/resource live, save it as a file with `save_resource_file` and
  assign it with `"load:res://..."`.
- **`run_script` / `eval_expression` edits.** These are for reading and
  calculating (they can reach `ResourceLoader`/`ResourceSaver`; plain
  `load()` doesn't work in Expression). A call that changes the scene
  returns a `scene_changed_note` and is logged as `raw_scene_edit` for
  the tool-candidate review.
- **Audio buses**, a project-wide layout the game reads at startup.

Values can be written as constructor calls, e.g. `"Color(0.2, 0.4, 0.9)"`.

**Wayland note:** on native Wayland a window that isn't visible gets no
frames, so a game (embedded in the Game tab or not) pauses while the editor
is hidden and catches up when shown. Keep the editor on screen while
testing, or run Godot under X11 for unattended play.

## Making Godot your own: building and testing editor UI

The editor is itself a Godot scene, so an agent can write custom editor
tooling in GDScript — an `EditorInspectorPlugin` with a bespoke Inspector
UI for one of your classes, a dock, a tool script — and, with these four
tools, **see the result and use it**, which is what it lacks when it can
only write code:

| Tool | What it does |
| --- | --- |
| `get_inspector_screenshot` | PNG of the Inspector (or `scene_tree`, `filesystem`, `bottom_panel`, the whole `editor`, or any control by node path), cropped to the dock |
| `dump_control_tree` | The live Control tree of an editor UI as compact JSON: class, script, text, global position and size, visibility, and a path. Check layout numerically ("do these pickers share one x?"); `filter_script` returns only the subtrees running your script |
| `interact_control` | `press`, `set_value`, `select_menu_item`, `drop_files` (a FileSystem-dock drop) and `drag_drop` on a control found by path or by text/class. Returns the control's state afterwards and whether the **undo history gained an action**, so a UI and its Ctrl+Z behaviour can be tested end to end |
| `refresh_editor_scripts` | The reload dance after editing `@tool` scripts, in one call: saves open scripts, re-parses them and returns **parse errors with file and line**, toggles the addon plugin each belongs to, re-selects the inspected object so the Inspector rebuilds, and lists typed members that read `null` on live nodes |

A typical loop: write the plugin with `edit_script_text`, call
`refresh_editor_scripts`, look at it with `get_inspector_screenshot`, check
alignment with `dump_control_tree`, drive it with `interact_control` (drop a
scene on the empty slot, confirm a row appeared and one undo step was
added), edit, repeat.

Limits: `interact_control` calls the control's signals and methods (it is
not a real mouse), so drag-and-drop works on scripted controls
(`_get_drag_data` / `_can_drop_data` / `_drop_data`) but not on native-only
ones such as the Tree docks. Docks that are hidden or scrolled off-screen
can't be screenshotted (the error says so). Custom Inspector controls
should use `EditorInterface.get_editor_scale()` for pixel sizes.

## AI Assistant panel

The panel's header is one line: the title, the **Agent** menu with the current choice printed after it,
a **Chat | CLI | External** toggle (defaults to Chat), and refresh and settings on the right. You
choose the agent and model once, and all three modes use that choice.

- **Agent** (menu, then e.g. "Claude · Sonnet 5.5"): the agent (Claude, Codex, OpenCode or Gemini;
  only CLIs found on PATH are listed) with **Model…** and **Effort…** submenus ("Default" shows the
  CLI's own setting; Gemini uses its own). Switching the agent keeps each agent's own saved session.
- **Chat**: the structured chat box (Claude, Codex and OpenCode; Gemini has no chat view yet, so
  Chat greys out for it).
- **CLI** (shown if the optional [GodotXterm](https://github.com/lihop/godot-xterm) addon is
  installed, Linux/macOS): the chosen agent's full interactive CLI running right in the editor —
  same server, token and settings as External. Its font size and colour scheme are in **Settings**,
  under the Terminal subhead.
- **External**: the same CLI in a separate terminal window, in this project. Claude, Codex and
  OpenCode also get the model/effort and preferences; Gemini uses its own, and its server entry is
  written to the project's `.gemini/settings.json`, which holds the local bridge token. The panel
  then shrinks to just its header, giving the height back to the editor, and returns to its size
  when you switch back to Chat or CLI. Switch away and back to open another window.
- **The robot** (the logo) is a status light: orange and blinking when idle, yellow while an AI is
  working, green for a moment when it finishes, red when something fails. It watches three things:
  the chat's reply, the editor bridge (any call an AI makes to the editor, from Chat, CLI, a separate
  terminal window or another client), and the embedded CLI's own "esc to interrupt" hint. A CLI in
  an External window is only seen through its editor calls.
- **Refresh icon**: in Chat, the next message starts a fresh session (and picks up a rebuilt
  server); in CLI, it restarts the CLI (picking up changed settings); in External it's off.
- **Settings** (cog), in two columns. Left: **Permissions** (File Control, Terminal Commands, Web
  Access; on by default, remembered per project) and **Preferences**: sync editor changes to the running game, whether
  the AI tests its own changes (off by default, to save tokens), and whether it saves its changes
  (on by default). The last two reach the session as a hidden system-prompt addition
  (`developer_instructions` for Codex). A fourth, **Collect usage data for tool improvement** (off
  by default), turns on the self-improvement log below for this project's sessions.
  Right: **Terminal** (font size, colour scheme; shown with GodotXterm).
- **Chat:** each turn ends with its token use and the session total
  (`— edits complete · 6.4k in / 61 out (+16.3k cached) · session 12.7k /
  122 —`; in/out are fresh tokens, cached reads noted separately). Your messages in yellow, the edits-complete line in green; **Send** (paper plane) and **Stop**
  (hand), which stops the current reply but keeps the conversation.
- **Slash commands:** the CLIs' own ones don't exist in the panel. It
  handles `/model` and `/effort`: on their own they open a menu showing the
  current choice (the CLI default is labelled), or take a value directly
  (`/model <name>`, `/effort <level>`; per agent, saved per
  project; `default` resets; otherwise each CLI's own settings apply) and
  points others at the external-CLI buttons.
- Codex in the panel runs `codex exec --json` per message and resumes the
  same thread; File Control / Web Access map to its sandbox, approvals are
  off, and the Godot tools are pre-approved.
- On first load the plugin sets Editor Settings > Run > Bottom Panel >
  Action On Play to "Do Nothing" (once), so Play doesn't switch away from
  the chat.

Server changes need only **New session**; changes to the addon's `.gd`
files need **Project > Reload Current Project**.

## Self-improvement loop

**Opt-in, off by default.** Nothing below happens unless the server runs
with `GODOT_LIVE_MCP_TOOL_DATA=on` (the panel's "Collect usage data"
setting sets it). Off, nothing is written to disk, `log_intent` /
`log_result` aren't offered, and the agent never brings up review.

When on, every tool call (bridge-backed or lifecycle) is logged to
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
| `GODOT_LIVE_MCP_TOOL_DATA` | (off) | Set to `on` to opt in to the usage log and review prompts |
| `GODOT_LIVE_MCP_LOG` | (on) | Set to `off` to disable logging even when opted in |
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
