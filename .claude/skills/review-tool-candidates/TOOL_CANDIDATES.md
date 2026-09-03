# Reviewing usage data for tool candidates

This is the criteria GodotLiveMCP has actually used, across its own
development, to decide when a new bridge tool earns its place versus when
`eval_expression` (or the existing tool set) already covers it well enough.
It's written to be usable on its own — by a person reading their own
`calls.ndjson`/`calls.pending-review.ndjson` by hand with any MCP client,
or by the `review-tool-candidates` Claude Code skill, which follows this
document rather than duplicating it.

The usage log itself (`server/src/callLog.ts`) only does mechanical
bookkeeping — counting errors and bursts, batching, rotating. It never
judges content. Everything below is the judgment step, and it requires
reading the actual log entries, not just their count.

## The bar: token/turn efficiency, not strict impossibility

The question is never "is this the *only* way to do it" — it's "is a
dedicated tool the more direct, efficient path to the result." A case can
be technically possible without a new tool but only via several
exploratory round-trips, where a dedicated tool would clearly be cheaper
overall; that case still earns a tool. Conversely, don't build a tool for
something a general-purpose call already does in one shot.

## Two shapes of evidence, two different confidence bars

### Structural gaps — flag from a single sighting

A structural gap is a case where the current tools **genuinely cannot** do
the thing, not just where doing it takes more calls than ideal. Evidence:

- A call fails (`ok: false`) with an error that points at something
  `Expression` cannot do at all — it can't parse assignment statements or
  run loops, and it can't narrow a method's return type (e.g. a chained
  call like `get_surface_override_material(0).albedo_color` fails because
  `Expression` only knows the method returns a generic `Object`).
- A missing counterpart to something that already exists — e.g. a `set_*`
  tool with no matching `get_*`, when every sibling tool in that category
  has one. That asymmetry is itself evidence, independent of how many
  times the gap has actually been hit.
- A validation gap that let a call silently do nothing, or silently
  corrupt something, instead of failing loudly.

One real occurrence of any of these is enough to propose a tool. Don't
wait for it to repeat — a structural gap doesn't get less real by
happening only once.

### Pure efficiency patterns — need repetition before proposing

A pure efficiency pattern is a sequence of calls that all **succeed**, but
where several round trips stand in for what should conceptually be one
request. Evidence:

- A burst of several calls, all targeting the same node/resource/area, to
  accomplish one apparent goal (this is exactly what a "burst" signal in
  the log is a mechanical proxy for).
- The same multi-call shape recurring — in a fresh burst, a different
  session, or a different point in time — rather than appearing once and
  never again.

A single occurrence here is a hypothesis, not a decision — check whether
the same shape shows up more than once before proposing a dedicated tool
for it. Building a tool has a real cost (another surface to validate,
document, and live-verify); that cost should be paid back by actual
repetition, not a single convenient-looking case.

## What "propose a candidate" means

For every candidate, cite the actual evidence: the specific log line(s) —
timestamp, tool name, params, error message if any — that justify it.
Never propose a tool from a vague sense of "this seems useful" without
pointing at what actually happened. A candidate without evidence isn't
ready to propose yet.

## What NOT to flag

- A single failed call caused by an obvious typo or wrong parameter,
  with no sign the underlying operation is otherwise hard — that's the
  validation working as intended, not a gap.
- A one-off multi-call sequence that never repeats and isn't a structural
  gap — hold it, don't propose it.
- Anything already achievable via a documented `eval_expression` pattern
  in one call (check `CONTRIBUTING.md`/the existing tool descriptions
  before assuming something is missing).

## After a candidate is identified

Proposing a candidate is not the same as building it, and building it is
not automatic — see `CONTRIBUTING.md` for what a dedicated tool actually
needs (a live-verified implementation, or a design brief for someone else
to implement) and for the consent expectations around ever touching
someone's own usage data at all.
