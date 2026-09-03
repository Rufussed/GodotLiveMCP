---
description: Review accumulated GodotLiveMCP usage data for tool-building candidates, with explicit consent at every step. Use when the user asks to review tool-call logs, check for tool candidates, or run a "tool candidate cycle" for this project.
---

# Review tool candidates from usage data

GodotLiveMCP's MCP server (`server/src/callLog.ts`) accumulates a usage log
and, once enough "candidate signal" (errors or bursts of rapid calls) has
built up, rotates a batch into a pending-review file. This skill is the
judgment step on that data — something the background server process
can't do itself, since deciding whether a pattern is worth a new tool
requires an LLM reading the actual entries, not just counting them.

**This skill never analyzes or discards anything without asking first.**
Follow the consent gates below in order — do not skip ahead to analysis or
to building because it seems obviously fine to do so.

## Step 1 — locate the data

The log path defaults to `~/.local/share/godot-live-mcp/`, or wherever
`GODOT_LIVE_MCP_LOG_PATH` points if that env var is set (check the user's
shell/MCP server config if unsure). Look for, in this order:

1. `calls.pending-review.ndjson` — a batch the server has already decided
   is worth a look (an error or burst threshold was crossed). This is the
   normal case.
2. If that doesn't exist but the user explicitly asked for an early
   review, fall back to the live `calls.ndjson` instead — note to the user
   that this is a partial, not-yet-rotated batch.

If neither file exists or is empty, say so plainly and stop. There's
nothing to review.

## Step 2 — Consent gate 1: analyze?

Read the file just enough to report **how many entries** it contains and
the **time range** they span (don't summarize content yet — that's the
next step, and it shouldn't happen before this gate). Ask the user
directly: *"Found N logged calls from [time range]. Analyze them for tool-
building candidates?"*

- **If declined**: clear the pending-review file (truncate it to empty;
  leave the live `calls.ndjson` alone if that's what was actually read).
  Stop here. Do not analyze, do not summarize further, do not ask again in
  this same invocation.
- **If accepted**: continue to Step 3.

If the user says they never want to be asked this again, tell them to set
`GODOT_LIVE_MCP_LOG_REVIEW=off` in their MCP server's environment — that
makes the mechanical rotation discard batches automatically from then on,
with no future prompt at all. Don't set this for them; it's a config
change to their own environment, and they should confirm the exact
mechanism (their server's env config) themselves.

## Step 3 — analyze

Apply the criteria in [`TOOL_CANDIDATES.md`](TOOL_CANDIDATES.md) (read
that file now if you haven't already — this skill doesn't duplicate it in
full, and the criteria may have been refined since this copy was made; if
you're inside the GodotLiveMCP repo itself, prefer the root-level
`TOOL_CANDIDATES.md` as canonical over this bundled copy). In short:

- **Structural gaps** (something `Expression`/the existing tools genuinely
  can't do, or a missing counterpart to an existing tool) — flag from a
  single occurrence in this batch.
- **Pure efficiency patterns** (a burst of several successful calls
  standing in for one conceptual request) — only propose if the same
  shape appears more than once, whether that's multiple bursts in this
  batch or you have reason to believe it's recurring across sessions.

For each candidate, cite the actual entries (timestamps, tool names,
params, error text) that justify it. Do not propose anything you can't
point at real evidence for.

Present the candidate list to the user, even if it's empty — an empty
result ("nothing here looked like a real gap") is a legitimate and useful
outcome, not a failure to find something.

## Step 4 — Consent gate 2: build, per candidate?

For each candidate the user wants to act on, ask *which* of these they
want, per candidate — don't assume:

- **Build it locally**: implement following
  [`CONTRIBUTING.md`](CONTRIBUTING.md)'s pattern (a `_cmd_*`
  function in the relevant bridge script, a matching MCP tool definition +
  dispatch case, build, `reload_plugin`/restart the game as appropriate),
  then live-verify it against their running Godot instance — at least one
  success case with the real returned value checked, and one failure case.
  Do not skip verification; a tool that only typechecks is not done, per
  this project's own established discipline.
- **Write a design brief instead**: fill out the template in
  `CONTRIBUTING.md`'s "Design briefs" section — no code, no verification
  needed from the user. If they want it pushed upstream, be upfront that
  there's no dedicated automation for this yet: the actual mechanism today
  is opening a GitHub issue or a code-less PR yourself via the `gh` CLI
  (`gh issue create`, or `gh pr create` if they'd rather it land as a PR),
  same as any other GitHub contribution — offer to do this for them if
  they confirm they want it submitted, rather than just handing them text
  and leaving submission as their own manual step.
- **Decline**: skip it, move to the next candidate.

## Step 5 — clear the batch

Once every candidate has been resolved (built, briefed, or declined),
clear `calls.pending-review.ndjson` (or the live log, if that's what was
read in Step 1). Confirm to the user what was done: how many candidates
were found, how many were built/briefed/declined, and that the batch is
now clear.

## What this skill is not

It's not an assertion that every batch will contain something worth
building — most won't, and saying so honestly is the correct outcome. It's
also not a substitute for `CONTRIBUTING.md`'s verification bar — building
something in Step 4 still means actually testing it live, not just writing
code that looks right.
