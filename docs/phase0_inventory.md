# Phase 0: Funplay review and tool inventory

2026-10-11. Part of `IN_EDITOR_MCP_PLAN.md`. Funplay reviewed at commit
`ec595d2` (MIT, 2026-10-10), files under `addons/funplay_mcp/core/`.

## 1. Funplay: take, change, skip

**Correction to the plan:** Funplay *does* check Host, Origin and Referer
(`funplay_mcp_server.gd`, `_validate_post_request_security`). The plan said it
doesn't. What is wrong is how: the checks pass when the header is absent, the
token is optional (an empty token means no auth), the token compare is plain
`==`, and `GET /health` answers without a token. Our rules stay mandatory
(phase 1); we change these.

| File | Take | Change | Skip |
|---|---|---|---|
| `funplay_http_transport.gd` (221 lines) | The `TCPServer` poll loop driven from the editor, per-connection state, 32 KB header / 8 MB body limits, 10 s request timeout, 400/413/431/408 replies, `Connection: close` | Buffer **bytes**, not text: `get_utf8_string` on a partial chunk can split a multi-byte character, and `to_utf8_buffer().size()` on every poll is quadratic on a large body (screenshots). Make the body limit a constant we can test. Reject a missing `Content-Length` on POST. | Nothing; it is small |
| `funplay_mcp_request_handler.gd` (237 lines) | Protocol-version negotiation (`2025-11-25` down to `2024-11-05`), notification handling (no reply), JSON-RPC error shapes, `isError` plus `structuredContent` on results | Drop `resources/*` and `prompts/*` (not needed; return method-not-found). Tool errors: ours come from the bridge's `{ok:false,error}`, not an `"Error:"` text prefix. Add tool-argument validation from the schema (Node's `validateArgs.ts` does this today). | The interaction logger, project-skill and prompt providers, the `data:image/png` text sniffing for screenshots (we return images from structured bridge results) |
| `funplay_mcp_server.gd` (395 lines) | "Attach to the editor that already serves this project": probe `/health`, compare a hash of `res://`; fallback port when taken; the id float-to-int fix before output; the `localhost` / `127.0.0.1` / `::1` host parser | Port and token live in our existing files and are fixed per project (no random fallback port: a client's config must stay valid across restarts). Host **and** Origin checks are mandatory when present *and* a token is mandatory always. Constant-time token compare. `/health` returns only name and version unless authenticated. Accept `Authorization: Bearer` only (drop the custom `X-Funplay-MCP-Token` header). | Settings UI, tool profiles (ours are Lite / Full from `tools.json`), update checker, localisation |
| `funplay_client_config_writer.gd` (266 lines) | JSON merge that keeps other servers and **refuses to touch invalid JSON**; the TOML section replace that keeps nested `[mcp_servers.x.env]` tables; per-OS home and VS Code paths; `build_snippet` for "copy config" | Entries are HTTP (`url` + `Authorization` header), not `npx` stdio. Claude Code and VS Code write the **project's** `.mcp.json` / `.vscode/mcp.json` by default, with user-level files only on an explicit second button. Use `${env:…}` / `${input:…}` for the token where the client supports it. Back up the file before the first write. Check each client's schema (`type: "http"` vs `url` only). | The `funplay-godot-mcp` npm wrapper package, tool-profile settings |

Not reviewed: the 5,500-line tool implementations, which we don't use.
Add `THIRD_PARTY_NOTICES` with the Funplay MIT notice when the first adapted
file lands (phase 1).

## 2. Tool inventory (122 tools)

Source: `server/src/` (`bridgeTools.ts` 93, `runtimeTools.ts` 12,
`index.ts` 14 lifecycle, `intentTools.ts` 2, `lspTools.ts` 1).

**Generic** means the Node handler only fills defaults and calls the bridge
command of the same name. I checked the defaults against `bridge.gd`: the bridge
already applies the same ones (`node_path` `"."`, `lines` 60, `max_depth` 6,
`max_nodes` 400, `save` true, `style_type`, `length`, `bake`, and so on), so the
Node-side `?? default` can be dropped. This was a sample, not every tool; the
phase 2 parity harness proves it.

Two generic-path duties to remember: unknown-parameter rejection
(`validateArgs.ts`) moves into the core, driven by the schema in `tools.json`;
and results are `JSON.stringify(result, null, 2)` text unless the tool returns
an image.

### Generic: 89 tools (all bridge commands)

All 93 bridge-tool names **except** the four below. That includes
`get_perf_stats` and `highlight_editor_control` / `interact_control` (they pass
`{...params}` through), which the plan listed as adapters or special: they are not.
Plain list: `eval_expression`, `run_script`, `list_scene_tree`,
`get_node_properties`, `open_scene`, `set_property`, `set_properties`,
`set_transform`, `attach_script`, `remove_node`, `reparent_node`,
`duplicate_node`, `add_node_live`, `rename_node`, `connect_signal`,
`disconnect_signal`, `get_node_groups`, `set_node_groups`,
`get_editor_selection`, `select_nodes`, `clear_editor_selection`,
`validate_script`, `edit_script_text`, `save_scripts`, `get_script_text`,
`set_properties_multi`, `set_animation_keys`, `set_animation_track_path`,
`save_resource_file`, `setup_collision`, `get_collision_info`,
`set_physics_layers`, `get_physics_layers`, `add_mesh_instance`,
`setup_environment`, `set_material_3d`, `get_material_info`,
`create_animation`, `add_animation_track`, `get_animation_info`,
`add_animation_state`, `add_animation_transition`, `add_audio_bus`,
`add_audio_bus_effect`, `get_audio_bus_layout`, `set_audio_bus_effect_params`,
`remove_audio_bus_effect`, `tilemap_fill_rect`, `tilemap_get_info`,
`set_particle_material`, `set_particle_color_gradient`, `get_particle_info`,
`save_scene_live`, `set_physics_material`, `set_theme_stylebox_override`,
`set_shader_material`, `get_shader_material_info`, `set_nested_property`,
`set_resource_property`, `set_anchors_preset`, `get_node_bounds`,
`setup_navigation`, `get_resource_dependencies`, `reload_plugin`,
`restart_editor`, `play_scene`, `stop_scene`, `is_playing_scene`,
`reload_project`, `get_signals`, `find_nodes`, `batch_set_properties`,
`get_output_log`, `dump_control_tree`, `highlight_editor_control`,
`clear_editor_highlights`, `interact_control`, `refresh_editor_scripts`,
`get_perf_stats`, `start_tour`, `get_tour_status`, `stop_tour`, `revise_tour`,
`save_tour`, `list_tours`, `start_recording`, `stop_recording`,
`get_recording_status`, `set_watch_mode`.

`reload_plugin` and `restart_editor` are generic but need the "flush the reply
before the server stops" rule (plan, "Editor restarts").

### Adapters: 4 bridge tools + 12 runtime (+ 1 LSP, moved to Node-only in section 4)

| Tool | Why it is an adapter |
|---|---|
| `get_editor_screenshot` | Result is `{base64, format}`; must become an MCP `image` content block (`image/<format>`), not text |
| `get_inspector_screenshot` | Same image reshaping |
| `search_assets` | Lives only in Node (`assetLibrary.ts`): fetches the Asset Library JSON API and asks the editor its version. Redo with `HTTPRequest` |
| `install_asset` | Node-only: downloads the zip, checks host allow-list, size cap and hash, then hands it to the editor. Redo with `HTTPRequest` + `ZIPReader`; the bridge-side extraction with path checks already exists |
| `get_game_screenshot` | Image reshaping, **and** the target is the running game's bridge (port 9090, `runtime_bridge.gd`), a different process |
| `capture_game_frames` | Port 9090; result `{frames[]}` becomes alternating text and image blocks; 15 s timeout instead of 5 s |
| `monitor_game_properties` | Port 9090; command renamed `monitor_properties`; columns/rows become compact one-row-per-line text; 15 s timeout |
| `wait_for_game_condition` | Port 9090; command renamed `wait_for_condition` |
| `game_eval_expression`, `game_list_scene_tree`, `game_get_node_properties`, `game_set_property`, `game_set_properties` | Port 9090 and command renamed (drop `game_`). Pure routing and renaming, no reshaping: these are a **table** (tool → port, command), not code |
| `simulate_key`, `simulate_mouse_button`, `simulate_mouse_motion` | Port 9090 only; same command name. Table entry. `simulate_mouse_button` defaults `button` to `MOUSE_BUTTON_LEFT`; confirm `runtime_bridge.gd` does too |
| `get_script_diagnostics` | Lives only in Node: speaks LSP to Godot's language server on a separate port with a script's text. Inside the editor, use the in-process script validation (`validate_script`) or connect to the editor's own LSP port; decide in phase 2. Likely deliberately different |

So the adapter *code* is small: three image tools, `capture_game_frames`,
`monitor_game_properties`, two asset tools, and one diagnostics tool. The
other eight runtime tools are routing-table entries.

### Node-only, stay in Node: 16 tools

| Tools | Reason |
|---|---|
| `launch_editor`, `run_project`, `get_debug_output`, `stop_project` | Launch or own a Godot **process**; meaningless inside the running editor (relay takes over launch/restart in phase 6) |
| `get_godot_version`, `list_projects`, `get_project_info` | Find Godot or scan the disk with no editor needed. (`get_project_info` and `get_godot_version` could be answered in-editor later; not in scope.) |
| `create_scene`, `add_node`, `load_sprite`, `export_mesh_library`, `save_scene`, `get_uid`, `update_project_uids` | Run `godot_operations.gd` in a separate headless Godot process, editing files on disk. Inside the editor the live equivalents already exist (`add_node_live`, `save_scene_live`, `set_property` with `load:`). Not ported; tool descriptions for Lite mode should steer to the live tools |
| `log_intent`, `log_result` | Write the opt-in usage log (`callLog.ts`, `GODOT_LIVE_MCP_TOOL_DATA=on`); a Node feature, not part of the editor server. Revisit only if the usage-review workflow is meant to work without Node |

Count check: generic 89 + adapters 16 (4 bridge, 12 runtime) + Node-only 17 (14 lifecycle, 2 intent, `get_script_diagnostics`) = 122. (Section 4 moves `get_script_diagnostics` from adapter to Node-only.)

## 3. Where `tools.json` lives

**`addon/godot_live_mcp/tools.json`, generated and committed.**

- The addon is the thing that ships to the store, and the in-editor server must
  read it from `res://addons/godot_live_mcp/`. Node can read the same file
  from the repo (`../addon/godot_live_mcp/tools.json`), so there is one copy.
- Generated by a script in `server/scripts/` (`export-tools.js`) from the
  TypeScript definitions, which stay the source of truth for now. The script
  runs in `npm run build`; a check fails when the committed file is stale
  (diff against a fresh export), so the two cannot drift.
- Each entry is the MCP tool object (`name`, `description`, `inputSchema`) plus
  two of our own keys that are **stripped before `tools/list`**:
  - `route`: `"bridge"` (default), `"runtime"` (port 9090), or `"adapter"`
    (named GDScript function), so generic vs adapter is data, not code.
  - `group`: `"lite"` or `"full"` for the tool groups.
  - A runtime entry also carries `command` when the name differs.
- Node-only tools get `"route": "node"` and are **listed in `tools.json` but
  omitted by the in-editor server**, so the relay (phase 6) and Node still
  share one list.
- Flip the source of truth to `tools.json` (and generate the TypeScript from
  it) only after phase 2 reaches parity. Not before.

## 4. Decisions (step 1 of phase 1)

**Lite group (28 tools).** What a newcomer needs to build and debug a scene,
and nothing that runs arbitrary code beyond `eval_expression`. Everything else
is Full. Default for a new install: Lite.

- Look: `list_scene_tree`, `get_node_properties`, `find_nodes`, `get_signals`,
  `get_editor_selection`, `get_output_log`, `get_editor_screenshot`,
  `get_script_text`
- Scenes and nodes: `open_scene`, `save_scene_live`, `add_node_live`,
  `remove_node`, `rename_node`, `reparent_node`, `duplicate_node`,
  `select_nodes`
- Change: `set_property`, `set_properties`, `set_transform`, `connect_signal`
- Scripts: `attach_script`, `edit_script_text`, `validate_script`,
  `save_scripts`
- Run: `play_scene`, `stop_scene`, `is_playing_scene`
- Escape hatch: `eval_expression`

Judgment calls, easy to change in `tools.json`: `run_script` is Full only
(whole-script execution is the bigger hammer; `eval_expression` covers small
needs); runtime-game tools are Full because they need the autoload;
`restart_editor` and `reload_plugin` are Full.
A Lite server simply omits Full tools; the panel says how to switch.

**`get_script_diagnostics` in the editor:** not ported. `validate_script`
(Lite) already reports parse errors from inside the editor. The language-server
version stays Node-only (`route: "node"`), so it is absent from the in-editor
list. Revisit only if `validate_script` proves too weak for parity tests.

## Still open for Phase 1

- Confirm the bridge's reply for images (`{base64, format}`) survives the
  8 MB response path and GDScript string handling (test with the transport).
