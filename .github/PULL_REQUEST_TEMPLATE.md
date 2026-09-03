## What gap does this close?

<!-- Structural (eval_expression/Expression genuinely can't do this — no
assignment, no loops, can't narrow a method's return type — or a missing
counterpart to an existing tool) or a repeated efficiency pattern (several
calls standing in for what should be one)? See TOOL_CANDIDATES.md for the
distinction and why it matters for whether one occurrence is enough
evidence. -->

## Evidence

<!-- The log entries, error messages, or reproduction steps that show the
gap is real. If this came from your own usage.ndjson, generalize/redact
anything you don't want to share publicly — see CONTRIBUTING.md's privacy
note. -->

## Live verification

<!-- Required, not optional — see CONTRIBUTING.md. Paste what you actually
ran and what came back: at least one success case (with the real returned
value, not just ok:true) and at least one failure case (bad input, wrong
node type, etc., failing with a clear message). If the tool mutates state,
confirm the mutation persisted via a separate read-back call. -->

- [ ] Success case verified, output included above
- [ ] Failure case verified, output included above
- [ ] If mutating: read back via a different call than the one that set it

## Scope

- [ ] Additive only — no existing tool's behavior changed
- [ ] If not additive-only, explained why above
