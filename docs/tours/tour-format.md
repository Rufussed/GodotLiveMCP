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

Machine-readable schema: [`tour.schema.json`](tour.schema.json). Example:
[`first-label.tour.json`](first-label.tour.json), which works in any
project with a scene open.

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
| `vars` | no | Names for nodes that already exist: `name` → node path relative to the scene root (`"."` is the root). |
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
| `text` | yes | The instruction. `**bold**` and `` `code` `` are rendered; `$name` is replaced by that node's current name. |
| `why` | no | One plain sentence on why the step matters, shown by the card's **Why?** button. |
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

`root` is one of `inspector` (default), `scene_tree`, `filesystem`,
`bottom_panel` or `editor`. An optional `label` adds a caption under the
outline. If a target can't be found, the step still runs, and the card
says it can't point at it.

### Completion checks (`done_when`)

| `type` | Fields | Completes when |
|---|---|---|
| `node_selected` | `node_path` | The node is selected in the editor. |
| `node_exists` | `node_path` | The node exists. |
| `node_added` | `parent`, `class`?, `capture`? | A new child appears under `parent` (of `class`, if given). `capture` binds it to a variable. |
| `node_removed` | `node_path` | The node is deleted. |
| `node_renamed` | `node_path`, `name` | The node is renamed to `name`. |
| `node_reparented` | `node_path`, `parent` | The node now sits under `parent`. |
| `property_equals` | `node_path`, `property`, `value`, `tolerance`? | The property equals `value`. |
| `property_changed` | `node_path`, `property`, `tolerance`? | The property differs from its value when the step began. |
| `property_class` | `node_path`, `property`, `class` | The property holds a resource of `class` (e.g. a `RectangleShape2D`). |
| `script_attached` | `node_path`, `script`? | The node has a script (that script, if given). |
| `signal_connected` | `source`, `signal`, `target`, `method`? | `source.signal` is connected to `target` (that `method`, if given). |
| `in_group` | `node_path`, `group` | The node is in the group. |
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

### Show me

**Show me** does the current step for the user, undoably. It is derived
automatically for `node_selected`, `node_added` (with `class`),
`node_removed`, `node_renamed`, `node_reparented`, `property_equals`
(without a sub-path), `script_attached` (with `script`),
`signal_connected` (with `method`), `in_group`, `scene_saved`, and `all` of
those. For anything else, give it explicitly:

```json
"show_me": [
	{ "command": "set_property", "node_path": "$label", "property_name": "position", "value": "Vector2(100, 80)" }
]
```

`command` is one of `select_nodes` (`node_paths`), `add_node_live`
(`parent_path`, `node_type`, `node_name`), `set_property`
(`node_path`, `property_name`, `value`), `rename_node` (`node_path`,
`new_name`), `reparent_node` (`node_path`, `new_parent_path`),
`remove_node` (`node_path`), `connect_signal` (`node_path`, `signal_name`,
`target_node_path`, `method_name`), `set_node_groups` (`node_path`,
`groups`), `attach_script` (`node_path`, `script_path`) or
`save_scene_live`. Each action is one undo step.

## Safety

Tours are **data, not code**, so they are safe to share:

- Completion checks are declarative. There are no expressions or scripts
  to evaluate.
- **Show me** runs only the allow-listed editor commands above. It runs
  only when the user presses the button, and every action can be undone.
- A tour can't bring code with it: `attach_script` may only attach a
  script that already exists in the project, and validation rejects
  anything else.
- Every tour is validated before it starts: unknown fields and types,
  properties and signals that don't exist on the target class, and
  variables used before they're defined are all reported at once.
