# Guided tours: multi-step highlighting and spontaneous tutorials — plan

Detailed plan for the "Roadmap: guided tours" section of
`GodotLive_Project_Brief.md`. Draft, written 2026-10-10.

## The experience

1. The user asks, in the agent panel or any MCP client: *"How would I make
   my player collide with walls?"*
2. The agent looks at the open project with the existing read tools, then
   drafts a short tour (3–8 steps) for **this** project: the user's own
   node names, scenes and dock layout.
3. The tour starts in the editor. A pulsing outline marks the first
   control, and a small tour card shows: *Step 1/4: Select **Player** in
   the Scene dock.*
4. The user does it. The runner sees the scene is now in the expected
   state and moves on: the outline jumps to the next control, the card
   updates. No agent round trip is needed between steps.
5. At any point the user can go **Back**, **Skip**, ask **Show me** (the
   step is done for them, undoably), or ask **Why?** (the question goes to
   the agent with the tour context).
6. At the end the user can **save** the tour. A saved tour replays
   later, for anyone, with no AI involved.

## Two tools, not one

- **Simple highlight (`highlight_editor_control`, already built, kept
  as-is):** "where is X?" The agent points once and the outline disappears
  as soon as the user acts (an edit, undo action or scene change) or
  after the timeout. That release-on-use behaviour is the point of it,
  and tours must not change it.
- **Chained highlight (tours, new):** "how do I do X?" A sequence of
  highlights that persist through unrelated edits and advance only when
  each step is done.

Both share target-finding and drawing code (step 0 below), but each owns
its own lifecycle.

## Architecture

```
agent ──MCP──▶ server ──TCP──▶ bridge.gd ──▶ tour_runner.gd (new)
                                              ├─ overlay (highlight drawing, refactored out)
                                              ├─ tour card UI
                                              ├─ completion checker (signals + poll)
                                              └─ event log  ◀── get_tour_status
                     assistant_panel.gd ◀── "Why?" / "I'm stuck" ──┘
```

**The runner lives in the addon, not in the agent.** The agent hands over
a whole tour in one call. From then on the editor drives itself: step
changes are instant, cost no tokens, and keep working if the agent
session ends. That's also what makes no-AI playback of saved tours
possible, because it's the same runner either way.

New file `addon/godot_live_mcp/tour_runner.gd`. `bridge.gd` is already
very large, so the bridge only gets thin `_cmd_*` wrappers.

## Step 0: separate the overlay from its release rules

Today `_cmd_highlight_editor_control` combines three things: target
resolution, drawing, and a lifecycle that clears the highlight on *any*
edit, undo action, scene change or timeout. A tour needs the first two
and must not use the third: an unrelated edit mid-step must not drop the
highlight.

- Extract `_resolve_highlight_target(t) -> {control | tree+item_path} or
  error` and the `_hl_make` / `_hl_update` drawing into an `Overlay`
  helper owned by either caller.
- `highlight_editor_control` keeps its current behaviour exactly; it
  becomes one client of the helper.
- The tour runner is the other client, with its own lifecycle.
- **Acceptance:** the existing highlight tool behaves exactly as before,
  re-verified live.

## Tour format (v1)

JSON, used both over MCP and as a saved `*.tour.json` file.

```json
{
  "format": "godot-live-tour/1",
  "title": "Make the player collide with walls",
  "godot_version": "4.7",
  "requires": { "scene_open": "res://main.tscn", "node_exists": ["Player"] },
  "vars": { "player": "Player" },
  "steps": [
    {
      "id": "select",
      "text": "Select **Player** in the Scene dock.",
      "target": { "node_path": "$player" },
      "done_when": { "type": "node_selected", "node_path": "$player" }
    },
    {
      "id": "add_shape",
      "text": "Add a **CollisionShape2D** as a child of Player: click **+** (Add Child Node) and search for it.",
      "why": "A physics body only collides through child collision shapes.",
      "target": { "root": "scene_tree", "class": "Button", "tooltip": "Add Child Node" },
      "done_when": { "type": "node_added", "parent": "$player", "class": "CollisionShape2D", "capture": "shape" }
    },
    {
      "id": "pick_shape",
      "text": "In the Inspector, set **Shape** to a new **RectangleShape2D**.",
      "target": { "node_path": "$shape", "property": "shape" },
      "done_when": { "type": "property_class", "node_path": "$shape", "property": "shape", "class": "RectangleShape2D" }
    },
    {
      "id": "save",
      "text": "Save the scene (Ctrl+S).",
      "done_when": { "type": "scene_saved" }
    }
  ]
}
```

- **`target`** uses exactly the fields `highlight_editor_control` already
  accepts (`property`, `node_path`, `path`, `root`, `text`, `class`,
  `index`), plus `targets` for several at once. Optional: a step with no
  target just shows the card, as in step 4.
- **`vars` and `capture`:** users name things their own way. When a step
  creates a node, `capture` binds *whatever node the user actually made*
  to a variable that later steps use (`$shape`). Without this, every tour
  breaks the moment someone types `Shape` instead of `CollisionShape2D`.
- **`text`** uses a small subset of Markdown (bold, inline code), rendered
  with a RichTextLabel. **`why`** is optional; for saved tours it answers
  "Why?" offline.
- **Localization (later):** `text` may become `{ "en": ..., "de": ... }`.

### Completion checks (`done_when`)

These are declarative and checked by the runner. They're sorted by how
robust they are; prefer the first group.

| Type | Meaning |
|---|---|
| `node_exists` / `node_added` | Node at path, or a new child of `parent` with an optional `class`. `node_added` diffs against the step's starting state and supports `capture`. |
| `node_removed`, `node_renamed`, `node_reparented` | Structural changes. |
| `property_equals` | `node_path`, `property` (sub-paths allowed), `value` in var_to_str form, optional `tolerance` for floats and vectors. |
| `property_changed` | Any change from the step's starting value. Good for "try dragging this slider." |
| `property_class` | The property holds a resource of this class. |
| `script_attached`, `signal_connected`, `in_group` | As named. |
| `scene_saved`, `scene_open`, `file_exists` | Editor and filesystem state. |
| `node_selected` | The editor selection contains the node. |
| `control_pressed` | The target control was pressed. **Fallback only**, because clicks miss keyboard shortcuts and drag-and-drop. |
| `game_running` | The game is playing (for "now press F5" steps). |
| `manual` | The user clicks **Next**. For explanation-only steps. |
| `all` / `any` | Combine the above. |

**No arbitrary expressions in v1.** An `expression` check would be
powerful, but a saved tour from a stranger would then run code on load.
If it's added later, accept it only for tours started by the agent in
this session, never from files, or behind an explicit trust prompt.

**How checks run:** re-check on the editor signals that cover almost
everything — `EditorUndoRedoManager.history_changed`,
`Inspector.property_edited`, `EditorSelection.selection_changed`,
`scene_changed`, `resource_saved`, `EditorFileSystem.filesystem_changed`.
Add a 0.5s poll as a backstop. Checks are cheap reads, so this is well
within budget.

### Wrong turns

- If the change the user made doesn't satisfy the step, the card says
  so gently (for example, "That added a **Sprite2D**; this step wants a
  **CollisionShape2D**. Ctrl+Z to undo.") when the runner can tell. That
  covers wrong class, wrong parent, and property set to something else.
- If a step goes unfinished for N seconds, a "Stuck?" hint appears,
  linking to **Show me** and **Why?**.

## Target resolution and graceful degradation

- Targets are resolved **when the step starts**, not when the tour is
  created, because a target may not exist yet (`$shape`'s Inspector row
  only exists after step 2).
- If a target can't be found or revealed: retry for about 1s while the
  layout settles, then show the card **without** an outline, prefixed
  with "I can't point at this one." Also log a `target_missing` event so
  the agent (or the tour's author) learns of it. The step stays
  completable, so a broken pointer never blocks the tour.
- Editor controls change between Godot versions. Prefer targets in this
  order: property > node > visible `text` / `tooltip` > `class` +
  `index` > `path`. Add a `tooltip` matcher to `_ctl_find`; many toolbar
  buttons are icon-only, but their tooltips are stable.

## Preflight validation (`start_tour` dry run)

Before anything appears, validate:
- the JSON schema;
- that every `$var` is defined before use;
- that each property name exists on the expected class (via `ClassDB`);
- that targets resolvable *now* actually resolve (editor controls, nodes
  that already exist);
- that `requires` is met.

Return every problem at once, so the agent fixes its draft in one round
trip. This is the same fail-loudly approach the rest of the tool set
uses. `dry_run: true` validates without starting.

## Tour card UI

- A small floating panel placed next to the outlined control and moved
  aside so it never covers it. With no target, it docks to a corner.
- It shows the step count (2/4), the step text, and the buttons
  **Back · Skip · Show me · Why? · ✕**. Keyboard: Alt+→ (next, for
  `manual` steps) and Alt+← (back).
- It's non-modal: `mouse_filter` only on the card itself, and it never
  takes keyboard focus away from the editor.
- **Back** re-shows the previous step. It doesn't undo the user's work,
  because their editor history is theirs.
- **Show me** performs the step with existing bridge commands (add node,
  set property, connect signal), routed through the undo system so one
  Ctrl+Z reverses it. Steps opt in with a declarative `demo` field built
  from a small fixed set of actions that mirrors the `done_when` types,
  not arbitrary code.
- **Why?** shows the step's `why` text if there is one. If the in-editor
  agent panel is running, it also sends "[tour '<title>', step 2/4]
  Why …?" to the agent, so the user gets a live answer next to the tour.
- When the tour finishes: "Done!", a **Save this tour** button, and a
  short summary of what was built.

## MCP tools

| Tool | Purpose |
|---|---|
| `start_tour` | `{tour, dry_run?}`. Validates and starts. Replaces any running tour. Returns the preflight report. |
| `get_tour_status` | Current step, elapsed time per step, event log (`step_done`, `wrong_action`, `target_missing`, `skipped`, `show_me`, `why_asked`, `stuck`), captured vars. Lets the agent pick up where the user is. |
| `stop_tour` | Ends the tour and clears the overlay. |
| `save_tour` | Writes the running or last-finished tour to `res://tours/<slug>.tour.json` (path overridable). It replaces captured node names with `$vars` again, so the tour generalises. |
| `list_tours` | Saved tours in the project and their `requires`. |

**Playing a tour without AI:** an editor menu entry (**Project → Tools →
Guided Tours…**) lists `*.tour.json` files and starts one with the same
runner. No MCP, agent or network involved.

## Agent guidance (CLAUDE.md.template)

- **When to tour versus do it:** tour when the user asks "how do I…",
  "show me", or "teach me". Just do it when they say "do X". If it's
  ambiguous, offer: "Want me to do it, or walk you through it?"
- **Writing good tours:** inspect the scene first; use the user's real
  node names through `vars`; 3–8 steps; one action per step; prefer state
  checks over `control_pressed`; give every step a `why`; dry-run first.
- **During a tour:** don't make edits that change the steps under the
  user's feet. When the user comes back to chat, call `get_tour_status`
  first.

## Phases

Each phase ends with a live check against a running editor (project
rule), plus a short screen recording from phase 1 onwards.

**Phase 0: overlay refactor.** Done when `highlight_editor_control` is
unchanged and verified live.

**Phase 1: walking skeleton.** The runner, the card (Next, ✕ only),
`start_tour`, `stop_tour` and `get_tour_status`, and the checks
`node_selected`, `node_added` (with `capture`), `property_equals` and
`manual`. Done when the 4-step "collide with walls" tour above runs end
to end with a human doing the steps, and also when the steps are done
through `interact_control` and the bridge. Record it: this is the
demo for the application.

**Phase 2: robustness.** All check types, Back and Skip, wrong-turn
hints, the stuck timer, graceful degradation, preflight validation and
dry-run, and the `tooltip` matcher. Done when a test set of deliberately
broken tours each fails preflight with a clear message, and a tour whose
target is hidden degrades instead of stopping.

**Phase 3: spontaneous tours.** Agent guidance, Why? wired to the
in-editor panel, and Show me through `demo`. Done when five different
"how do I…" questions, asked cold in fresh sessions, each produce a tour
that passes preflight and can be completed by hand.

**Phase 4: saved tours and no-AI playback.** `save_tour` with var
re-generalisation, `list_tours`, the Tools menu player, a published
format spec (`docs/tour-format.md` plus a JSON Schema), and the no-code
trust model. Done when a tour saved in one project plays in a fresh
project with no MCP server running.

**Phase 5: content and learners.** About five beginner tours (first
scene, a moving player, collisions, a UI button, signals), tested with
real beginners. `get_tour_status` logs, kept local with consent, show
where people get stuck. Done when there are notes from at least one real
session, fed back into the tours and the runner.

**Later:**
- **Record mode:** the user performs a task and the runner turns the
  undo history into a draft tour.
- Localised text, starting with German.
- Tours that span running the game (`game_running` plus runtime checks).
- Sharing and importing tours.

## Risks and open questions

- **Editor UI drift across Godot versions** is the biggest maintenance
  risk. Mitigations: state-based checks, the target preference order,
  degradation, and `godot_version` in the file so the player can warn.
- **Native-only interactions** (some Tree drags, dialogs such as Create
  New Node) may be hard to outline *inside*. Outline the button that
  opens them and describe the rest in the card. Spike this in phase 1.
- **Card placement** around small or edge targets needs care. Prototype
  early.
- **Name:** "tour" is the working name; worth settling before the format
  string is fixed (`godot-live-tour/1`).
- **Running tours versus the agent editing:** should the runner pause or
  warn if the bridge receives mutating commands mid-tour? Proposal: warn
  in the result, don't block.
