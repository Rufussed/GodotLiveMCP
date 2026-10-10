# Watch mode — plan

Draft, 2026-10-10. A companion to guided tours (`TUTORIAL_TOOLS_PLAN.md`).

## The idea

Teach mode turns "how do I…?" into a tour: **you** do each step, and the
editor guides you. Watch mode is the other half: when the **agent** does the
work, the editor shows you each action as it happens. It outlines the node
or property it touched, gives a one-line caption ("Agent: added **Ball**
(RigidBody3D)", "Agent: **Ball** · Mass → 2"), and keeps a short running log.

| Mode | Who acts | What the editor shows |
|---|---|---|
| Teach | you | a tour: the next step, waiting for you |
| Watch | the agent | each action the agent takes, as it takes it |
| neither | the agent | nothing extra (full speed) |

**Why it matters.** It makes AI-driven changes *visible* to someone who
can't read tool calls. That's the same "safe for someone who can't check
it" argument as angle 4 of the pitch, and it's a teaching tool in its own
right: you watch it done once, then do it yourself (see phase 5).

Watch lives in the editor addon, not in the agent, so it works for any MCP
client: the in-editor panel, Claude Code in a terminal, Cursor, and so on.

## What exists to build on

- **One dispatcher.** Every bridge command goes through
  `bridge.gd:_handle_line`, which already emits `activity(ok)` after each one
  (the panel's busy indicator uses it). Watch hooks in at the same point.
- **Before/after scene snapshots** for raw commands (`run_script`,
  `eval_expression`): `_scene_fingerprint()` returns `{"Ball|position": hash, …}`,
  and `_differing_keys()` gives exactly what changed. Today that's reduced to
  a yes/no `scene_changed_note`; Watch needs the keys themselves.
- **Pointing:** `_hl_resolve_target(t, select=false)` (Scene dock rows,
  Inspector properties including folded sections, editor controls by
  tooltip) and `HighlightOverlay`.
- **The tour card**, which already handles dragging, placement and
  markdown captions. Watch's log panel can borrow its building blocks.
- **The recorder** (`tour_recorder.gd`), which turns scene changes into tour
  steps. That's the basis of "save what the agent did as a tour".

## Design

### Capturing actions (never slow the agent)

After each command, the dispatcher calls
`_watch().observe(command, params, result, ok, changed_keys)`. That only
appends a *beat* to a queue and returns; the reply to the agent is not
delayed. Each command is classified once, in a table in `watch.gd`:

| Kind | Commands (examples) | Beat |
|---|---|---|
| node | `add_node_live`, `remove_node`, `rename_node`, `reparent_node`, `duplicate_node` | outline the Scene dock row; "added **Ball** (RigidBody3D) under **Level**" |
| property | `set_property(ies)`, `set_nested_property`, `set_resource_property`, `set_transform`, `set_material_3d`, `setup_collision`, … | "**Ball** · Mass → 2" (values shortened; resources as "new BoxMesh") |
| wiring | `connect_signal`, `set_node_groups`, `attach_script` | "**Button** pressed → **Main**._on_button_pressed" |
| code | `edit_script_text`, script creation | "edited `player.gd` lines 12–15" (see Code below) |
| scene | `open_scene`, `create_scene`, `save_scene_live` | caption only |
| run | `play_scene`, `stop_scene`, `simulate_*` | caption only |
| raw | `run_script`, `eval_expression` | "ran a script — changed **Ball** · position, **Floor** · mesh" (from `changed_keys`), or "ran a script (no scene changes)" |
| ignored | reads (`get_*`, `list_*`, `dump_*`, screenshots), tour and highlight commands | nothing |

Failed commands get a muted "tried to … — failed" beat. That's honest and
useful: it shows the agent correcting itself.

### Showing beats

- **Pacing.** Each beat shows for about 0.9 s: the outline, plus the caption
  added to the log. When the agent outpaces the display:
  - consecutive beats on the same node merge ("set 5 properties on
    **Ball**");
  - with more than about 5 beats waiting, beats are shortened to about
    0.3 s;
  - with more than about 20 waiting, the log jumps ahead and shows "+12
    more".

  Outlines must never trail far behind reality.
- **The Watch log.** A small panel, bottom-right by default and draggable
  like the tour card. It shows the last ~6 beats, newest first, each
  clickable to point at that thing again. It has a header with the
  **Watch** state, a **Follow** toggle, and **Save as tour…** (phase 5).
- **Outlines are brief** and fade with their beat. Watch uses its own
  `HighlightOverlay`, separate from the tour's and the simple highlight's.

### Not taking over the editor

- **Follow is off by default.** Watch outlines Scene dock rows (which
  doesn't change your selection), and outlines an Inspector property only
  if that node is *already* open in the Inspector. Otherwise it just shows
  the caption. It never switches docks, tabs or main screens on its own.
- **Follow on** means Watch opens each touched node in the Inspector (to
  show the property) and opens scripts in the Script editor (to show code
  edits). That's good for demos and teaching, intrusive while you're
  working yourself.
- **During a tour,** Watch outlines pause, because the tour owns your
  attention. Beats still go to the log.

### Turning it on

- **A Watch toggle** next to Teach in the panel's input row, styled the same
  way (blue when on). Watch and Teach exclude each other: in Teach mode the
  agent doesn't edit, so there's nothing to watch.
- **The state lives in the bridge** (project metadata), not the panel, so it
  applies to any agent connected to this editor. The panel button just shows
  and sets it. It could also go in **Project ▸ Tools**, for users who keep
  the panel closed.
- **A `set_watch_mode` tool,** so an agent can turn Watch on when the user
  says "let me watch you do it".

### Code edits

`edit_script_text` knows the file and the exact text it wrote (`old_text` →
`new_text`, or the whole `text`). After the edit, Watch finds where
`new_text` landed and works out the changed line range.

- **Follow off:** "edited `player.gd` lines 12–15". Clicking the log entry
  opens the script at those lines.
- **Follow on:** opens the script at line 12 with
  `EditorInterface.edit_script()`, and tints the changed lines on the
  script's `CodeEdit` (via `set_line_background_color`), then fades them
  back after the beat.
- **Spike first:** confirm on Godot 4.7 that `ScriptEditor` →
  `get_current_editor().get_base_editor()` gives the `CodeEdit`, and that
  the line tint coexists with Godot's own current-line highlight.

### Code in tours (extends tours, not Watch)

Watching code edits leads naturally to *teaching* them. Today the signals
tour's "type this line" step is a manual click-Next.

- **A new check, `script_contains`:** `{script | node_path, text | regex}`,
  compared with whitespace normalised. Optional hint: "close — you have
  `$Mesage.text`; check the spelling".
- **A new target, `script`:** `{script, find: "func _on_button_pressed"}` opens
  the script and tints that line, the code equivalent of outlining a
  property.
- **Show me** applies the edit through `edit_script_text`.
- **The recorder** could record script edits too, by diffing file text, as
  `script_contains` steps.
- **Safety (open question).** Tours are currently "data, not code". Show me
  inserting code from a shared tour changes that. Proposal:
  - the card always shows the exact code before inserting it;
  - Show me refuses to add or edit `@tool` scripts, because those run
    inside the editor immediately;
  - for tours loaded from a file, Show me's code edits need a one-time
    "this tour will insert code" confirmation.

### Save what the agent did as a tour

With **Record while watching** on (in the Watch log header), the recorder
runs alongside the agent. **Save as tour…** then turns everything the
agent changed into a tour you can redo yourself. Watch once, then do it.
The recorder already handles undo, merged repeats and naming. Two limits:
`run_script` edits aren't undoable, so they're picked up by the next diff
rather than as their own step; and code is only covered once "code in
tours" exists.

## Phases

Each phase ends with a live check, in a separate editor on another port
(`GODOT_LIVE_MCP_PORT`), then a by-hand try.

1. **Watch for scene actions.** `watch.gd`, the dispatcher hook, the
   classification table, the beat queue with pacing and merging, the log
   panel, Scene-dock outlines and Inspector outlines (when already open),
   the panel toggle, bridge-held state and `set_watch_mode`.
   *Done when:* an agent building a small scene (about 15 commands in 5 s)
   produces a readable log, outlines that never lag more than about 2 s
   behind, and no change to selection or docks with Follow off.
2. **Raw command captions.** `_scene_edited_since` returns the differing
   keys, which Watch turns into "changed **Ball** · position". *Done when:*
   a `run_script` that moves two nodes is captioned with both.
3. **Follow mode, code edits included.** Inspector follow, the Script
   editor spike, then opening scripts at the changed lines and tinting
   them. *Done when:* with Follow on, an `edit_script_text` opens the script
   at the right lines with the tint, and it fades.
4. **Code in tours.** `script_contains`, script targets, Show me through
   `edit_script_text`, the safety rules, and a recorder pass for script
   edits. The signals tour's code step becomes a real check. *Done when:*
   the signals tour completes with its code step checked, not clicked
   through.
5. **Save the agent's work as a tour.** Record while watching, then Save as
   tour. *Done when:* "build a bouncing ball" done by the agent in Watch
   mode saves as a tour that plays back in a fresh scene.

## Risks and open questions

- **Noise.** A busy agent can fire dozens of commands. Merging and
  speed-up should keep it readable; the by-hand try will tell. A "captions
  only" option may be wanted.
- **Lag versus truth.** Beats show *after* the action. The log should say
  when it's catching up, so nothing looks like it's happening now when it
  happened 5 s ago.
- **Slow-motion option?** For demos, the bridge could hold each reply until
  its beat has shown. That's simple, but it must stay under the client's
  5 s timeout, and it changes agent timing. Leave it until a real need
  appears.
- **Focus stealing** is the main way this could annoy. Follow stays opt-in.
- **Code safety** in tours, above, needs a decision before phase 4.
- **Godot internals:** the Script editor and `CodeEdit` access are less
  stable across versions than Scene and Inspector access. Phase 3 starts
  with a spike.
