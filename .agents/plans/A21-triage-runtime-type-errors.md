---
id: A21
title: Triage cluster — Runtime Type Error suite files
issue: null
pr: null
branch: triage/runtime-type-errors
base: main
status: blocked
direction: A
unlocks:
  - math.lua
  - all.lua
  - utf8.lua
  - coroutine.lua
---

## Blocked on

- A19 — stdlib bad-arg raises need to carry line/source first, or the
  triage repros will lack source location and waste cycles.

## Goal

Diagnose why `math.lua`, `all.lua`, `utf8.lua`, and `coroutine.lua`
each raise a `Runtime Type Error` early in execution. Produce per-file
fix sub-plans (`A21a`, `A21b`, …) or, if a deferred decision is
appropriate, a documented skip annotation.

These files raise outright (rather than failing an `assert`), so the
failure point is already pinned by the line/source data A18 wired in.
Triage should be quick: read the line, decide if it's a missing
stdlib feature, a metamethod gap, or an actual VM bug.

## Out of scope

- Implementing fixes inline. This plan only triages — fixes go in
  follow-up `A21<letter>` plans.
- Triage of the `Assertion Failed` cluster files (those are A23/A24).
- Performance work.

## Success criteria

- [ ] Each of `math.lua`, `all.lua`, `utf8.lua`, `coroutine.lua` has
      a written diagnosis: which feature is missing or which VM path
      is wrong, with a representative repro.
- [ ] Each file has either a follow-up fix plan (`A21a`, …) under
      `.agents/plans/` or an `@tag :skip` with a clear deferred
      comment.
- [ ] `mix test --include skip` count is unchanged (no regressions
      from the triage activity itself).

## Implementation notes

For each of the four files, follow the `triage-suite-failure` skill:

1. Repro standalone in `iex` against a fresh `Lua.new()`.
2. Read the error: line, source, message, and the offending opcode if
   the stack trace points into the executor.
3. Classify: missing stdlib function, missing metamethod, executor
   bug, parser issue, or compiler issue.
4. If reducible to a 5-20 line `test/lua/vm/*_test.exs` repro, write
   the test (skipped or pending) and link it from the fix plan.
5. Write `A21<letter>-<slug>.md` describing the fix.

### Hypotheses to start with

- `math.lua` — likely `math.type`, `math.tointeger`, or
  `math.maxinteger`/`math.mininteger` constants missing or wrong.
- `utf8.lua` — `utf8.char`, `utf8.codepoint`, `utf8.len`, or
  `utf8.charpattern` may be unimplemented or partially correct.
- `coroutine.lua` — coroutine support has been historically minimal
  in this codebase. May fail on `coroutine.wrap` returning a callable,
  or on `coroutine.status` semantics.
- `all.lua` — this is the suite's harness; it might be choking on
  something the runner expects (`require`, `assert`, etc.).

### Files

- `.agents/plans/A21<letter>-*.md` — fix-now follow-ups.
- `test/lua/vm/*_test.exs` — per-file reduced repros.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test --include skip
```

After triage: either all four files have follow-up plans, or the ones
deferred have explanatory `@tag :skip` comments.

## Risks

- Triage may find the failures cascade — e.g., `all.lua` might just
  be choking on the same issue blocking other files. If so, fold the
  diagnosis into whichever cluster is the root cause.
- Some failures may be deeper than expected (whole missing subsystems
  like coroutines). Defer those with clear notes; they should not
  block 1.0 if the rest of the suite is solid.

## Discoveries

(populated during triage)
