# Adaptive tours — changing course when a step goes wrong

Draft, 2026-10-10. Extends `TUTORIAL_TOOLS_PLAN.md` (tours) and
`WATCH_MODE_PLAN.md`.

## The problem

A tour is a plan, and plans meet reality. Today a tour carries on as if
every step worked. Cases seen or easy to foresee:

- **A script has an error** after Show me writes it, or after the learner
  types it. The next step assumes it works.
- **The game runs but misbehaves** (the ball falls through the floor).
- **A Show me fails** (the missing-script case).
- **The scene differs** from what the plan assumed.
- **The learner is stuck** in a way the card can't explain.

The runner already adapts in small ways: it follows the learner's node
names (`capture`), hints at wrong turns, shows steps that are already done,
and notes when someone is stuck. But it can't *replan*, and the agent isn't
told anything went wrong. It only finds out if the learner returns to chat
and the agent happens to call `get_tour_status`.

## Principle

Keep tours simple and declarative, and make the **agent the replanner**:
it's good at that, and a tour made on the spot already came from it.
Saved tours with no agent (classrooms) get only small, built-in recovery.
Anything that makes the format a programming language is out of scope.

| | Agent present (on-the-spot tour) | No agent (saved tour in a classroom) |
|---|---|---|
| Notices a problem | built-in checks, plus the agent is told | built-in checks |
| Responds | the agent revises the remaining steps | the step's own fallback steps, or a plain "this didn't work: …" note |

## 1. Checks that can see problems

New `done_when` types, all read-only and declarative (no expressions, like
the rest). Each one can also be used as a step's *verification*, which is
the point: a tour can notice failure instead of assuming success.

| Check | Completes / passes when | Built on |
|---|---|---|
| `script_ok` `{script \| node_path}` | the script parses with no errors | `validate_script` / `get_script_diagnostics` |
| `output_contains` `{text, since: "step"}` | the editor or game output since the step began contains `text` | `get_output_log` (output and `game_errors`) |
| `no_errors` `{since: "step"}` | no new error lines in the output since the step began | `get_output_log` |
| `game_property` `{node_path, property, op, value}` | a property in the **running game** compares true (`>`, `<`, `==`, `~=`) | the runtime bridge's `get_node_properties`; only valid while the game runs |

Verification steps need a way to say "this step is a check, not an action":
`done_when` alone isn't enough, because *failing* should do something.

## 2. What happens on failure

A step gets an optional **`on_fail`**, tried when its check hasn't passed
after the learner says they're done (or after a timeout, for checks that
run by themselves):

```json
{
  "text": "Press F6. The ball should land on the floor.",
  "done_when": { "type": "game_running" },
  "verify": { "type": "game_property", "node_path": "Ball", "property": "position:y", "op": ">", "value": "-5" },
  "on_fail": {
    "note": "The ball fell through. Check the floor has a CollisionShape3D with a shape.",
    "steps": [ { "text": "Select **Floor** and add a **CollisionShape3D** …", "done_when": { … } } ]
  }
}
```

- **`verify`** runs after `done_when` passes (or when the learner presses
  **Next** on a step that has one). If it passes, the tour moves on.
- **If it fails:** the card shows `on_fail.note` (or a generic "that didn't
  work: <check description>") and, if `on_fail.steps` exist, inserts them
  before the next step. Then the verify runs again.
- **No agent needed:** this is plain data, so a teacher can write recovery
  into a saved tour. It nests one level only (fallback steps can't have their
  own `on_fail`), to keep it from turning into a program.

## 3. Telling the agent

The runner already records events: `wrong_action`, `stuck`, `show_me_failed`,
`target_missing`. Add **`verify_failed`** (with the check and what it saw),
and a **problem digest**: the last few events plus the current error lines
for the step.

- **"Ask the agent" button** on the card, shown whenever a note says
  something went wrong (verify failed, Show me failed, stuck). It sends the
  digest to the in-editor agent panel through the same path **Why?** uses
  (`AssistantPanel.ask`): the tour title, the step, what went wrong and the
  relevant output, with an instruction to fix the plan with `revise_tour`
  and not to make the changes itself.
- **Automatic in Teach mode,** for hard failures only: `verify_failed` and
  `show_me_failed`. Not for "stuck" or hints, which are cheap to leave for
  the button. Rate-limited to once per step, so a loop can't run up tokens.
  The cost is one short turn per failure.
- **External agents** (Claude Code in a terminal, Cursor) can't be messaged
  by the editor. They see the same digest in `get_tour_status` (new
  `problems` field) and are told in the `start_tour` description to check it
  when the learner comes back.

## 4. `revise_tour`

A new tool: `revise_tour {from_step?, steps, note?}`.

- Replaces the **remaining** steps (from the current step, or `from_step`)
  with new ones. Steps already done are kept as they are.
- **State is preserved:** variables and captures stay, so new steps can say
  `$ball` and the learner's own names still resolve. Done steps and the
  event log are untouched.
- Validated like `start_tour` (all problems at once, `dry_run` allowed).
- The card shows "The agent changed the plan from here" with the note, so
  the learner understands why the steps changed, and the step counter
  updates ("Step 4/7" becomes "Step 4/6").
- It records a `revised` event.
- **It never touches the scene.** Fixing the scene is the tour's job; the
  agent only edits the plan. This keeps Teach mode honest, and keeps Watch's
  "the agent made a change" distinct from "the agent changed the plan".

## 5. Smaller built-ins

- **`skip_if`** on a step: a check; if it's already true when the step
  starts, the step is skipped silently. This is today's "already done" pause
  made explicit, for steps that shouldn't be shown at all (e.g. "add a
  floor" when one exists).
- **Better messages for what we already catch:** a failed Show me says what
  failed and offers **Ask the agent**; a script error after a code step
  shows the error line.

## Phases

Each phase ends with a live check on a scratch editor (separate port).

1. **Checks and `verify`.** `script_ok`, `output_contains`, `no_errors`,
   `game_property`, plus the `verify` field and the `verify_failed` event,
   with a generic failure note. *Done when* a tour step that writes broken
   code fails its `script_ok` verify with the error line on the card, and a
   ball that falls through a floor fails `game_property`.
2. **`on_fail` and `skip_if`.** Fallback steps inserted on failure;
   one level of nesting. *Done when* a saved tour recovers from a missing
   collision shape with no agent.
3. **"Ask the agent" and `revise_tour`.** The button, the digest,
   `get_tour_status.problems`, the tool, and the "plan changed" card note.
   *Done when* a deliberately broken step makes the agent revise the plan
   once, and the tour completes on the new steps with the learner's node
   names intact.
4. **Automatic hand-off in Teach mode** (hard failures only, rate-limited)
   and the `start_tour` description / `CLAUDE.md.template` guidance on
   *planning with verifications* (verify after code and after running; keep
   fallbacks short).
5. **Recorder support (later).** When recording, a game run followed by a
   fix could suggest a verify step. Probably skip.

## Risks and open questions

- **Format creep.** `verify`, `on_fail` and `skip_if` are the three
  additions; resist any more. Each is data a teacher can read.
- **Flaky checks.** Output and game properties depend on timing: a check run
  too early reports failure. Verifies should wait for the game to be running
  and for a short settle time, and `game_property` needs a sensible timeout.
- **Cost.** The automatic hand-off is the only unprompted token spend; it's
  limited to hard failures, once per step.
- **Agents that edit the scene** when asked about a failure. The digest
  says not to, and `revise_tour` is the only action offered, but nothing
  enforces it beyond that (Watch would at least show it).
- **Locating errors:** a script error's line and message come from the
  editor's own parser, which changes between Godot versions; test on 4.7 and
  fall back to a plain "the script has errors" message.
