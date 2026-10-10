# Guided tour format (`godot-live-tour/1`)

A guided tour is a short, step-by-step walkthrough that runs **inside the
Godot editor**. Each step outlines a part of the editor UI, shows a card
with an instruction, and moves on by itself once the step has actually been
done: the runner checks the real editor state, not clicks.

Tours come from two places:

- **Spontaneous:** an AI agent connected through GodotLiveMCP writes one for
  the user's own project when asked "how do I…?" (`start_tour`).
- **Saved:** a `*.tour.json` file in the project. Tours are played from
  **Project ▸ Tools ▸ Guided Tours…** with **no AI involved**: no account,
  no network, nothing leaves the machine. Any tour can be saved from its
  last card ("Save tour") or with the `save_tour` tool, then edited by hand.

Machine-readable schema: [`tour.schema.json`](tour.schema.json). Examples, a beginner series that works in any project with a 2D scene
open, in this order: [`first-label`](first-label.tour.json),
[`collisions`](collisions.tour.json),
[`player-movement`](player-movement.tour.json),
[`ui-button`](ui-button.tour.json), [`signals`](signals.tour.json).

## Recording a tour

Instead of writing JSON, do the task once yourself:

1. **Project ▸ Tools ▸ Guided Tours… ▸ Record new tour…** (or the
   `start_recording` tool). A red bar shows it's recording.
2. Work normally in the open scene: add, rename, move and delete nodes,
   edit properties in the Inspector or drag things in the viewport, attach
   scripts, connect signals, and save.
3. **Stop & save…**, give the tour a title, and choose whether values must
   match exactly.

The recorder compares the scene before and after each undoable change, so
undone work disappears, 50 slider ticks become one step, and a node you add
and then rename becomes one "add it and name it **Ball**" step. By default,
text, switches, dropdowns and new resources must match, while numbers,
vectors and colours only have to *change* (the card shows the value you
used). Turn on **Require exact values** to make those match too.

The draft has no `why` lines; add them by hand, or ask the agent to.

## File layout

```json
{
	"format": "godot-live-tour/1",
	"title": "Your first Label",
	"vars": { "root": "." },
	"requires": { "scene_open": "res://main.tscn", "node_exists": ["Player"] },
	"stuck_after_sec": 90,
	"steps": [ … ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | Always `"godot-live-tour/1"`. |
| `title` | no | Shown on the card and in the tour list. |
| `vars` | no | Names for nodes that already exist: `name` → a node path relative to the scene root (`"."` is the root), or `{"class": "CharacterBody2D", "hint": "…"}` for the first node of that class, whatever the user named it (add `"name"` when the scene may hold several). If there's none, the tour won't start and shows the hint, e.g. "play the Collisions tour first". |
| `requires` | no | `scene_open`: the tour's scene, opened automatically when played from the menu. `node_exists`: node paths that must exist. |
| `stuck_after_sec` | no | Seconds before a "Stuck?" note appears (default 90, `0` = never). |
| `steps` | yes | One or more steps, run in order. |

Save tours under `res://tours/`. Files anywhere in the project are listed,
except under `addons/` and hidden folders.

## Steps

```json
{
	"id": "add-label",
	"text": "Click **+**, search for `Label`, and press **Create**.",
	"why": "A Label is the simplest way to show text in a game.",
	"target": { "root": "scene_tree", "tooltip": "Add/Create a New Node" },
	"done_when": { "type": "node_added", "parent": "$root", "class": "Label", "capture": "label" },
	"show_me": [ … ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | no | For your own reference; appears in status and errors. |
| `text` | yes | The instruction. `**bold**` and `` `code` `` are rendered; `$name` is replaced by that node's current name (write `$$name` to get a literal `$` before it, e.g. `$$label.text` → `$Label.text`). |
| `why` | no | One plain sentence on why the step matters, shown by the card's **Why?** button. `$name` works here too. |
| `target` | no | What to outline (below). Omit for a card-only step. |
| `done_when` | yes | The check that completes the step (below). |
| `show_me` | no | What **Show me** does (below). Usually derived automatically. |

### Variables

Anywhere a node path is expected, `"$name"` means the node bound to `name`,
and `"$name/Child"` means a child of it. Variables come from `vars`, or from
a `node_added` check's `capture`, which binds *whatever node the user
actually created*. Later steps then keep working however the user named it.
Variables follow their node through renames and moves.

### Targets

The same fields as the `highlight_editor_control` tool:

| Target | Outlines |
|---|---|
| `{ "node_path": "$player" }` | The node's row in the Scene dock (without selecting it). |
| `{ "node_path": "$player", "property": "speed" }` | That property's row in the Inspector (the node is opened in the Inspector). In a folded section, the section heading is outlined until the user opens it. |
| `{ "root": "scene_tree", "tooltip": "Add/Create a New Node" }` | An editor control matched by tooltip (case-insensitive substring); best for icon-only buttons. |
| `{ "root": "editor", "text": "2D", "index": 0 }` | An editor control matched by its visible text, plus `class`/`index` to disambiguate. |
| `{ "root": "inspector", "path": "…" }` | An editor control by path, as listed by `dump_control_tree`. Fragile across Godot versions; prefer `tooltip` or `text`. |

Entries in the editor's top menu bar (Scene, Project, Debug…) can't be
outlined; describe them in the step text instead.

`root` is one of `inspector` (default), `scene_tree`, `filesystem`,
`bottom_panel` or `editor`. An optional `label` adds a caption under the
outline. If a target can't be found, the step still runs, and the card
says it can't point at it.

### Completion checks (`done_when`)

| `type` | Fields | Completes when |
|---|---|---|
| `node_selected` | `node_path` | The node is selected in the editor. |
| `node_exists` | `node_path` | The node exists. |
| `node_added` | `parent`, `class`?, `name`?, `capture`? | A new child appears under `parent` (of `class`, if given). `capture` binds it to a variable. `name` is a *suggestion*: the step then asks the user to rename it (the card says "Now rename it to … or similar" and the outline moves to the new node) and completes once they give it a name of their own, the suggested one or another. Later text and node paths that use the suggested name are mapped to theirs. |
| `node_removed` | `node_path` | The node is deleted. |
| `node_renamed` | `node_path`, `name` | The node is renamed to `name`. |
| `node_reparented` | `node_path`, `parent` | The node now sits under `parent`. |
| `property_equals` | `node_path`, `property`, `value`, `tolerance`? | The property equals `value`. |
| `property_changed` | `node_path`, `property`, `tolerance`? | The property differs from its value when the step began. |
| `property_class` | `node_path`, `property`, `class` | The property holds a resource of `class` (e.g. a `RectangleShape2D`). |
| `script_attached` | `node_path`, `script`? | The node has a script (that script, if given). |
| `signal_connected` | `source`, `signal`, `target`, `method`? | `source.signal` is connected to `target` (that `method`, if given). |
| `in_group` | `node_path`, `group` | The node is in the group. |
| `script_contains` | `script` (a `res://` path) or `node_path` (a node with the script), `text`, `extends`?, `replace`? | The script's text, including unsaved edits, contains `text` (whitespace ignored). `extends` and `replace` only affect Show me. |
| `script_ok` | `script` or `node_path` | The script (including unsaved edits) parses with no errors. |
| `output_contains` | `text` | The Output panel (which also carries the running game's prints) shows `text` after the step began. |
| `no_errors` | none | No new error lines since the step began, in the editor or in the running game. |
| `game_property` | `node_path`, `property`, `op` (`>` `<` `>=` `<=` `==` `~=`), `value`, `tolerance`? | A property **in the running game** compares true. Needs the game's runtime bridge (the `GodotLiveMCPRuntime` autoload). |
| `scene_open` | `path` | That scene is the one being edited. |
| `scene_saved` | none | The scene is saved during the step. |
| `file_exists` | `path` | The file or folder exists. |
| `control_pressed` | none (uses the step's `target`) | The outlined button is pressed. Last resort: it misses keyboard shortcuts. |
| `game_running` | none | The game is running. |
| `manual` | none | The user presses **Next**. For explanation-only steps. |
| `all` / `any` | `checks: [ … ]` | All / any of the nested checks pass. |

`value` uses Godot's `var_to_str()` form: `"5"`, `"true"`, `"\"Hello\""`,
`"Vector2(100, 80)"`, `"Color(1, 0, 0, 1)"`. `"load:res://icon.svg"` refers
to a resource file. Numbers, vectors and colours are compared with
`tolerance` (default `0.0001`). `property` may be a sub-path such as
`"position:x"`.

A step whose check is already true when it starts is shown briefly ("✓
Already done") before moving on. When the user does something close but
wrong, such as the wrong class, wrong parent, or a different value or
name, the card says what's different.

### Verifying a step's result (`verify`)

`done_when` says the learner did the thing; an optional `verify` says it
**worked**. It's any check, usually one of the four above:

```json
{
	"text": "Press **F6**. The ball should land on the floor.",
	"done_when": { "type": "game_running" },
	"verify": { "type": "game_property", "node_path": "$ball", "property": "position:y", "op": ">", "value": "-5" }
}
```

After `done_when` passes, the step only completes once `verify` passes. If
it hasn't passed after a short wait (`wait_sec`; by default 0.6 s for
`script_ok`, 3–4 s for output and game checks), the card says what's wrong,
for example "✗ That didn't work: the script has an error — line 7: Expected
closing ")"", and records a `verify_failed` event for the agent. It keeps
re-checking, so the tour moves on by itself once the learner fixes it.

### Recovering when a verify fails (`on_fail`)

A step with a `verify` can say what to do if it fails, as plain data (so it
works in a saved tour with no agent):

```json
{
	"text": "Press **Next** when your script is written.",
	"done_when": { "type": "manual" },
	"verify": { "type": "script_ok", "script": "res://player.gd" },
	"on_fail": {
		"note": "The script has an error. Let's fix it first.",
		"steps": [
			{ "text": "Fix the error shown in the Script editor.", "done_when": { "type": "script_ok", "script": "res://player.gd" } }
		]
	}
}
```

When the verify fails, the card shows `note` (or the generic "That didn't
work: …") and the `steps` are inserted as **fix-up steps** (the title says
"fix-up"). When the last one is done, the original step is checked again
("checking again"), and only then does the tour go on. This happens **once
per step**; if the check fails a second time the card just keeps saying what
is wrong. Fix-up steps can't have their own `on_fail`, so it can't nest.

### Skipping a step that's already satisfied (`skip_if`)

`"skip_if": { …a check… }` on a step: if it is already true when the step
would start, the step is skipped without being shown (and logged as
`skipped_if`). Use it for steps like "add a floor" when one may exist.

### Show me

**Show me** does the current step for the user. It **announces first**: the
card lists exactly what it is about to do (code included), waits a moment
so it can be read, then does it. Almost every step can be shown:

- derived from `done_when` for `node_selected`, `node_added` (with `class`;
  and `name`), `node_removed`, `node_renamed`, `node_reparented`,
  `property_equals`, `property_class` (creates a new resource, e.g. a
  `BoxMesh`), `property_changed` (nudges the current value: flips a switch,
  adds to a number or vector, lightens a colour), `script_attached` (with
  `script`), `script_contains` (creates the script, or edits it, with the
  code; opens it in the Script editor and saves it), `signal_connected`
  (with `method`), `in_group`, `scene_open`, `scene_saved`, `game_running`,
  `control_pressed` (presses the outlined button), and `all` of those;
- `manual` steps: Show me just moves on.

Anything else can give an explicit `show_me` (below). Action effects can be
undone with Ctrl+Z, except written script files.

```json
"show_me": [
	{ "command": "set_property", "node_path": "$label", "property_name": "position", "value": "Vector2(100, 80)" }
]
```

`command` is one of `select_nodes` (`node_paths`), `add_node_live`
(`parent_path`, `node_type`, `node_name`), `set_property` (`node_path`,
`property_name`, `value`), `set_nested_property` (`node_path`,
`property_path` such as `"shape:size"`, `value`), `set_properties`, `set_transform`,
`duplicate_node`, `add_mesh_instance`, `setup_collision`, `set_material_3d`,
`set_physics_material`, `setup_environment`, `edit_script_text` (`path`, `text` or
`old_text`/`new_text`, `save`), `set_resource_property`
(`node_path`, `property_name`, `resource_type`), `rename_node`
(`node_path`, `new_name`), `reparent_node` (`node_path`,
`new_parent_path`), `remove_node` (`node_path`), `connect_signal`
(`node_path`, `signal_name`, `target_node_path`, `method_name`),
`set_node_groups` (`node_path`, `groups`), `attach_script` (`node_path`,
`script_path`), `save_scene_live`, `open_scene` (`path`) or `play_scene`.
Each action is one undo step.

## Safety

Tours are **data, not code**, so they are safe to share:

- Completion checks are declarative. There are no expressions or scripts
  to evaluate.
- **Show me** runs only the allow-listed editor commands above. It runs
  only when the user presses the button, and every action can be undone.
- Show me never writes a `@tool` script (they run inside the editor as
  soon as they're saved) and never writes under `addons/`; it says so and
  leaves it to the learner.
- The card's text can be selected and copied, so code can be pasted.
- A tour can't bring code with it: `attach_script` may only attach a
  script that already exists in the project, and validation rejects
  anything else.
- Every tour is validated before it starts: unknown fields and types,
  properties and signals that don't exist on the target class, and
  variables used before they're defined are all reported at once.
