---
id: A23
title: Triage cluster — metamethod & control-flow Assertion Failed files
issue: null
pr: null
branch: triage/metamethod-control-flow
base: main
status: blocked
direction: A
unlocks:
  - events.lua
  - errors.lua
  - closure.lua
  - pm.lua
  - goto.lua
  - coroutine.lua
  - nextvar.lua
---

## Blocked on

- A19 — stdlib raises need line/source for actionable triage.

## Goal

Diagnose seven suite files that fail with `Assertion Failed` and that
exercise the metamethod / control-flow surface (the area we have
most-recently been wiring up across A7-A9, A14-A17). Produce per-file
fix sub-plans (`A23a`, `A23b`, …) or documented skips.

These are grouped because they share infrastructure: the executor's
metamethod dispatch, the call-stack/frame machinery, error-handling
paths (`pcall`, `xpcall`, `error`), and goto/label control flow.
Triage may find that fixing one unblocks several.

## Out of scope

- Implementing fixes inline. Fixes go in follow-up `A23<letter>` plans.
- The `Runtime Type Error` cluster (those are A21).
- The stdlib/data-structure cluster (A24).
- Performance work.

## Success criteria

- [ ] Each of the seven files has a written diagnosis: which assert
      fails, what was expected vs received, and the suspected root
      cause.
- [ ] Each file has either a follow-up fix plan (`A23a`, …) under
      `.agents/plans/` or an `@tag :skip` with a clear deferred
      comment.
- [ ] Where multiple files share a root cause, only one fix plan is
      written and the other files reference it as their unblock.
- [ ] `mix test --include skip` count is unchanged after triage
      (no regressions from the triage activity itself).

## Implementation notes

For each file, follow `triage-suite-failure`:

1. Repro standalone in `iex` against a fresh `Lua.new()`.
2. Read the line/source from the new error-message infrastructure
   (A18 wired this in). The `Assertion Failed` line tells us which
   assert in the suite file fired.
3. Print intermediate values to figure out what was expected vs
   received.
4. Reduce to a 5-20 line repro under `test/lua/vm/`.
5. Classify root cause and write `A23<letter>-<slug>.md`.

### Hypotheses to start with

- `events.lua` — exercises every metamethod. May be hitting something
  subtle in `__newindex` chains or `__call` on userdata.
- `errors.lua` — `pcall`/`xpcall`/`error` semantics. May be missing
  message-handler return value handling or error-object propagation.
- `closure.lua` — upvalue/closure semantics. A10a (deferred) hints
  weak-table-on-closures is a known gap. May also surface upvalue
  cell-sharing edge cases.
- `pm.lua` — pattern matching. A9b shipped the engine; this may now
  pass or be near-passing, just on a different assertion.
- `goto.lua` — goto/label/break. Compiler-level work probably; the
  `Assertion Failed` may follow a value mis-computed earlier.
- `coroutine.lua` — coroutine semantics. May fail before reaching
  the runtime-type-error in A21 if the cluster split was inexact.
  Re-confirm during triage.
- `nextvar.lua` — A7/A7a shipped dead-key handling. A new failing
  assert past line N is likely a different issue (length operator,
  array vs hash transition).

### Files

- `lib/lua/vm/executor.ex` — likely site for many fixes.
- `lib/lua/vm/stdlib.ex`, `stdlib/*.ex` — likely site for `errors.lua`
  fixes (pcall/xpcall/error).
- `lib/lua/compiler/*.ex` — likely site for `goto.lua` fixes.
- `.agents/plans/A23<letter>-*.md` — fix follow-ups.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test --include skip
```

After triage: each of the seven files has a follow-up plan or a
documented skip.

## Risks

- These are the "long tail" of metamethod/control-flow correctness.
  Some failures may require non-trivial VM work (e.g. proper
  coroutines). Triage must call out the size honestly so we can
  decide which to tackle for 1.0 vs defer to 1.1.
- `coroutine.lua` may belong in A21 instead. If triage shows the
  failure mode is in fact a Runtime Type Error, move it.
- Fix sub-plans must be small (one fix = one PR). Reject any sub-plan
  that touches >3 unrelated VM files.

## Discoveries

(populated during triage)
