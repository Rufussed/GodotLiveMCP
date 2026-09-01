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
- **Correction (added 2026-09-01, after actually reading Pro's public tool
  list for the Inspiration section):** the claim below was wrong for Pro
  specifically. Pro's own public tool directory lists `execute_editor_script`
  (live in-editor eval) and a 19-tool Runtime category (`execute_game_script`,
  `get_game_scene_tree`, etc.) for live *running-game* access — a capability
  this project doesn't have yet (see "Out of scope for v1"). It stood
  uncorrected in this file for the whole session and got repeated as a
  differentiator before the user's question forced a re-check. ~~No existing
  Godot MCP server offers live REPL/eval against a running scene. This is the
  genuine gap and the main point of differentiation.~~ True only against the
  free base (`Coding-Solo/godot-mcp`, genuinely file/CLI-only, no live access
  at all) — not against Pro. Against Pro, the honest pitch is free/open-source
  vs. $15 proprietary, and a tool set sized to a measurable efficiency bar
  rather than 175 tools, not "does something Pro can't."

## Inspiration

For which API calls to expose as MCP tools, reference only Godot MCP Pro's
publicly documented tool list (names/descriptions of what it offers, from its
own README at github.com/youichi-uda/godot-mcp-pro) — never its source code.
It is proprietary and not a legitimate base for this project (see above);
using its docs for naming/coverage ideas is fine, reimplementing from or
referencing its actual implementation is not.

Its public list groups ~175 tools into 23 categories (Project, Scene, Node,
Script, Editor, Input, Runtime, Animation, TileMap, Theme/UI, Profiling,
Batch/Refactoring, Shader, Export, Resource, Physics, 3D Scene, Particle,
Navigation, Audio, AnimationTree, State Machine, Blend Tree, Analysis,
Testing/QA). v1 covers a slice of Node/Editor tools; later passes can pull
further category names as needed — same rule applies each time: names and
one-line descriptions only.

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

**The bar for a dedicated tool** (settled after auditing all tools built so
far): `eval_expression` has no state between calls — each call is a fresh
`Expression.parse()`/`execute()`, so anything needing more than one step
costs N separate round trips, not one awkward line. A dedicated tool earns
its place if `Expression` structurally can't do the op in one call
(it can't parse assignment statements — confirmed by Ruake's own
`RuakeAssignment` workaround — and can't do loops/multiple statements), if
it needs to capture and return a result eval would otherwise discard (e.g.
a duplicated/reparented node's new path), or if its validation prevents a
silent failure that would otherwise cost a follow-up diagnostic eval call.
Cut on this basis: `get_project_setting`/`set_project_setting` —
`ProjectSettings.get_setting()`/`set_setting()` are single global-singleton
method calls, no node context, no loop, no assignment; the tool call and
the equivalent eval call cost the same in round trips, so the dedicated
tool was pure tool-list token overhead. Use `eval_expression` directly for
project settings instead.

**v1.1 batch** (Node-tools-category slice, names taken from Godot MCP Pro's
public tool directory per the Inspiration section above):

- `add_node_live(parent_path, node_type, node_name)` — instantiate a
  ClassDB type and add it as a live child (distinct name from godot-mcp's
  existing file-based `add_node`, which edits a .tscn on disk, not the live
  tree)
- `rename_node(node_path, new_name)`
- `connect_signal(node_path, signal_name, target_node_path, method_name)`,
  `disconnect_signal(...)` — live signal wiring
- `get_node_groups(node_path)`, `set_node_groups(node_path, groups)`
- `get_editor_selection()`, `select_nodes(node_paths)`,
  `clear_editor_selection()` — read/drive the editor's own node selection

**v1.2**: `validate_script(script_path)` — parse a GDScript file through
Godot's own GDScript compiler and report success/failure. Note: plain script
CRUD (`create_script`/`read_script`/`edit_script` from Pro's public list) was
considered and dropped — the agent already has direct filesystem read/write
for `.gd` files and gains nothing from routing that through the bridge.
`validate_script` earns its place because it's the one thing only Godot's
own parser can tell you; a plain file tool can't replicate it.
`get_editor_errors`/`get_output_log` were also considered and dropped: Godot
4 doesn't expose the Output panel's contents through a public GDScript API
without a C++-level hook, so building it now would be flaky/half-working.

**v1.3** (Physics-tools slice): `setup_collision(node_path, shape_type,
shape_params)`, `get_collision_info(node_path)`, `set_physics_layers`/
`get_physics_layers(node_path, layers)` (as human layer numbers 1-32, not
raw bitmasks). Pro's `setup_physics_body` and `add_raycast` were considered
and dropped as redundant with the existing generic `set_property` /
`add_node_live` — those need no dedicated wrapper. `setup_collision` earns
its place because it's a multi-step operation (instantiate a Shape
*resource*, not just a node, and assign it) that generic tools can't do in
one call; `get_collision_info` earns its place because a shape resource's
own properties (radius, size, ...) don't survive `var_to_str()` usefully
when read back through `get_node_properties`.

**v1.4**: `set_properties(node_path, properties)` — batch version of
`set_property`, one round trip for N properties instead of N. Built after
noticing Pro's `setup_camera_3d`/`setup_lighting`/`add_gridmap` were all
really "create a node, then set several properties on it" — a gap in the
generic tooling, not something 3D-specific. Applied that fix, then re-scoped
the 3D Scene category down to only what still needed dedicated resource
handling: `add_mesh_instance(parent_path, mesh_type, mesh_params,
node_name)`, `setup_environment(node_path, environment_params)`,
`set_material_3d(node_path, material_params)` — each creates/configures a
Resource (Mesh, Environment, StandardMaterial3D) via loop+assignment, which
neither raw eval nor the generic property tools can do in one call.
`setup_camera_3d`, `setup_lighting`, `add_gridmap` dropped as now covered by
`add_node_live` + `set_properties`.

**v1.5** (Animation + Audio, applying the bar at design time): before
building Pro's Audio-tools category, checked for the same hidden gap as
`ProjectSettings` — confirmed `AudioServer` (bus volume/mute/solo/effects,
all single method calls) also wasn't reachable from `eval_expression`.
Added it to the singleton list, same fix as before. That left only:
`add_audio_bus(bus_name)` (bundles `AudioServer.add_bus()` +
`set_bus_name()` with the computed index — needs the result of the first
call to do the second, and `eval_expression` has no state across calls, so
this is genuinely 2 round trips otherwise), `add_audio_bus_effect(bus_name,
effect_type, effect_params)` (resource creation + loop, like
`setup_collision`), `get_audio_bus_layout()` (loop over every bus).
`add_audio_player`, `set_audio_bus`, `get_audio_info` dropped: the first is
covered by `add_node_live`/`set_properties`, the second is now a single
`eval_expression` call now that `AudioServer` is reachable, the third was
redundant with `get_node_properties`.

Animation tools: `create_animation(node_path, anim_name, length,
library_name)` (creates an `Animation` resource + `AnimationLibrary`
bookkeeping — assignment + resource creation), `add_animation_track(...)`
(returns `track_index`, needed because a later `track_insert_key` call has
to reference it and calls can't share state), `get_animation_info(...)`
(loops every track and every keyframe). `list_animations`,
`set_animation_keyframe`, `remove_animation` dropped: each is a single
method-chain call once the animation/track is already known
(`get_animation_list()`,
`get_animation(name).track_insert_key(idx, time, value)`,
`get_animation_library(lib).remove_animation(name)`) — no loop, no
assignment, no cross-call state needed, so a raw `eval_expression` call is
strictly cheaper than a dedicated tool for these.

**v1.6** (TileMap + Particle, and one category dropped outright): screened
Pro's Theme/UI-tools category first and skipped it entirely —
`set_theme_color`/`set_theme_constant`/`set_theme_font_size` are single
method calls on an already-loaded `Theme` resource (`theme.set_color(...)`,
no assignment needed), and `create_theme` is a single
`ResourceSaver.save(Theme.new(), path)` eval line; none needed a dedicated
tool, and Theme/UI editing isn't central to this project's purpose anyway.

TileMap: `tilemap_fill_rect(node_path, position, size, source_id,
atlas_coords, alternative_tile)` (needs a nested loop over every cell —
`tilemap_set_cell`/`tilemap_get_cell`/`tilemap_clear`/`tilemap_get_used_cells`
from Pro's list were all dropped as single `TileMapLayer` method calls
reachable directly via eval), `tilemap_get_info(node_path)` (loops the tile
set's sources).

Particle: `set_particle_material(node_path, material_params)` and
`get_particle_info(node_path)` (same shape as `setup_collision`/
`get_collision_info` — a `ParticleProcessMaterial` resource needs
creation/loop-assignment, and its own properties don't survive
`var_to_str()` through generic tools), `set_particle_color_gradient(...)`
(builds a `Gradient` + `GradientTexture1D` from a list of points — loop
required). `create_particles` dropped as redundant with `add_node_live`.
`apply_particle_preset` (canned "fire"/"smoke"/"sparks" property bundles)
dropped on a different basis: it's opinionated content, not mechanical API
access — a fixed recipe some agent/user might want and another might not.
That kind of thing belongs in the later Skill/CLAUDE.md layer (§3) as a
documented pattern, not baked into the bridge as fixed values.

**v1.7 — first real external use, two bugs found.**

**First real external bug report** (from an actual agent-driven session, not
our own live tests): `reparent_node` had no cycle check.
`node.get_parent().remove_child(node)` ran *before* `new_parent.add_child(node)`
was attempted, so when an agent tried to reparent a mesh under a physics body
that was itself already a child of that mesh, Godot's own `add_child()`
correctly refused the cycle — but the node had already been ripped out of its
old parent by then, leaving it orphaned mid-tree and triggering a cascade of
"node not in scene tree" errors in the editor's Scene dock. Fixed by checking
`node == new_parent` and `node.is_ancestor_of(new_parent)` *before* removing
anything, plus a no-op short-circuit if the node's already under that parent.
Also fixed the token-source ambiguity in the addon's own logging (see
`_load_or_create_token()`): it printed a message on generating a *new* token,
but silently reused both an env override and a cached per-project token file
with no distinguishing log line, making a real cross-project setup issue
(env var not reaching an app-launcher-spawned Godot process due to systemd
user-session timing) hard to diagnose from the Output panel alone.

**Second gap found via the same real session**: every bridge edit is
in-memory only in the running editor — nothing persists until the scene is
saved, and closing/reloading the editor silently discards it all. godot-mcp's
inherited `save_scene` tool doesn't help: it resaves a scene *file* through a
headless CLI subprocess and has no visibility into the live editor's memory,
so calling it wouldn't persist bridge changes at all — and worse, the name
collision could make an agent believe it had saved when it hadn't. Added
`save_scene_live(path?)`, wrapping `EditorInterface.save_scene()`/
`save_scene_as()`, with the disambiguating name matching the
`add_node_live` precedent. This is the one case where a single-eval-call
op got a dedicated tool anyway despite otherwise clearing the "redundant"
bar — justified by how safety-critical and easy to silently get wrong it
is, not by round-trip cost.

**v1.8: `set_physics_material(node_path, material_params)`** — same shape
as `setup_collision`/`set_material_3d`: `PhysicsMaterial` (bounce,
friction) lives on `PhysicsBody2D/3D.physics_material_override`, a
resource that needs creating and assigning, unreachable via a single
`eval_expression` call or `set_property`. Built on request to make a
RigidBody3D bouncy.

**v1.9: Theme/UI, revisited.** The original v1.6 call to drop Theme/UI
entirely was too broad — live-tested it (add a `Button`, try to style it)
and found the real gap: `set_property` with a `StyleBoxFlat.new()`-style
string silently failed, since `str_to_var()` only parses Variant literals,
not resource-constructor calls — no error surfaced, it just set the
property to nothing. That's a genuine resource-creation case, same family
as `setup_collision`. Added `set_theme_stylebox_override(node_path,
override_name, style_type, style_params)`. Left everything else from that
category dropped: `add_theme_color_override`/`add_theme_constant_override`/
`add_theme_font_size_override` take plain values (not a resource), so
they're still single `eval_expression` calls with no dedicated tool needed
— the earlier screening was right about those, just wrong to lump
stylebox overrides in with them without testing.

**v1.10 — silent property-name failures fixed across every resource
tool.** Found via another real external session: asked to recolor a
sphere red, an agent called `set_material_3d`, got `{"ok": true}` back,
and reported success — but nothing changed. Root cause: `_apply_properties()`
(shared by `setup_collision`, `add_mesh_instance`, `setup_environment`,
`set_material_3d`, `set_physics_material`, `set_theme_stylebox_override`,
`add_audio_bus_effect`, `set_particle_material`) sets properties via
`Object.set(name, value)`, which **silently no-ops on an unrecognized
property name** — no error, nothing — and none of these tools echoed back
the values they'd actually applied, so there was no way for the caller to
notice the mistake short of a manual follow-up read. Fixed at the root:
`_apply_properties()` now checks each name against
`obj.get_property_list()` first and returns any that don't exist; every
call site fails loudly (`_fail(...)`) if any are unknown, and every
successful call now returns a readback of what was actually set (e.g.
`{"material": {"albedo_color": "Color(1, 0, 0, 1)"}}`) instead of a bare
`{"ok": true}`. This is the same failure shape as the `StyleBoxFlat.new()`
string bug from v1.9 — Godot's dynamic property APIs fail silently by
design, and every tool built on top of them needs to check for that
explicitly rather than trust a bare success return.

**v1.11 — texture/resource-file assignment, and `set_property`/
`set_properties` got the same fixes.** While answering "have we added
texturing tools?", live-testing surfaced two more problems in the same
family. First: `str_to_var()` can construct a path-backed resource
reference from a bare `Resource("res://icon.svg")` literal (confirmed —
it resolves and loads for real), but a colon-delimited nested-property
path like `material_override:albedo_texture` is not a real property name
`get_property_list()` recognizes, so `set_property` on it silently zeroed
out `material_override` entirely instead of setting the sub-property —
a live regression that undid the v1.10 fix mid-session. Second:
`set_property`/`set_properties` themselves had never gotten the v1.10
unknown-property-name validation, since they predate it and weren't part
of the `_apply_properties()` refactor.

Fixed both: added a `"load:res://path"` value prefix, recognized by a new
`_decode_value()` used everywhere `str_to_var()` was previously called
directly (`_apply_properties`, `set_property`, `set_properties`) — this
resolves *actual files* via `load()` instead of trying to parse them as a
Variant literal, fixing texture/resource-file assignment universally
without a new dedicated tool. And `set_property`/`set_properties` now
route through `_apply_properties()` too, so they get the same
unknown-property validation and fail loudly instead of silently no-oping
— confirmed live: `material_override:albedo_texture` as a property name
now correctly fails with "unknown property" instead of corrupting state,
and `load:res://icon.svg` correctly assigned and read back via
`material_override.albedo_texture.resource_path`.

**v1.12 — shader materials + multi-surface meshes.** Regular
texture/material assignment was already well-covered (`set_material_3d` +
`load:`, plus flat properties like `Sprite2D.texture`), so screened what
was left before building anything: shader uniforms are set via
`ShaderMaterial.set_shader_parameter(name, value)` — a method call, not a
property — so `_apply_properties()`/`get_node_properties()` structurally
can't reach them at all, in either direction. Added
`set_shader_material(node_path, shader_path, shader_params)` and
`get_shader_material_info(node_path)`, working on either
`GeometryInstance3D.material_override` (3D) or `CanvasItem.material` (2D)
via a shared `_material_property_for()` helper. Also extended
`set_material_3d` with an optional `surface_index` — imported models with
multiple mesh surfaces need `MeshInstance3D.set_surface_override_material(idx, mat)`,
another method call `material_override` alone can't reach. Skipped a
dedicated 2D material tool (`CanvasItemMaterial` blend/light-mode
settings) — most 2D tinting is just `modulate`/`self_modulate`, already
flat properties `set_property` covers; no concrete use case yet to justify
it.

### 3. A companion Skill / CLAUDE.md (started 2026-09-01)

Trigger for starting this: a real external session (a Claude Code instance
in `test-godot-mcp`, not our own testing) built a working start-button UI
end to end, hit a Godot "reload from disk?" prompt partway through because
bridge edits are memory-only and nothing had told it to save at
checkpoints — a concrete usage pattern to write guidance from, not a
speculative one.

Lives at [`addon/godot_live_mcp/CLAUDE.md.template`](../addon/godot_live_mcp/CLAUDE.md.template)
— copied into each Godot project's root as `CLAUDE.md` (step 5 of the
addon README's install instructions), not into this repo's own root,
since it needs to reach agents working in *target* Godot projects, not
GodotLiveMCP itself. Currently covers:

- When to call `save_scene_live` (checkpoints, not every call) and why
  saving the scene doesn't prevent Godot's external-file-change reload
  prompt when a script file was also written directly (different Godot
  code path: file-watch vs. in-memory scene state)
- When to prefer a structured tool vs. `eval_expression`, and which
  singletons `eval_expression` can already reach
- The self-improvement rule: after any request that required falling
  back to `eval_expression` for something structured tools don't cover, if
  the pattern looks likely to recur (not a one-off), suggest to the user
  that it be promoted into a dedicated tool. Do not ask this after every
  single prompt — only when a repeatable gap is actually observed.

Project-specific scene/node conventions were deferred — none have emerged
yet across the two test projects to document.

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
