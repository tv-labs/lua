---
id: A7
title: Fix nextvar.lua "concatenate nil" failure
issue: null
pr: null
branch: fix/nextvar-suite
base: main
status: blocked
direction: A
unlocks:
  - nextvar.lua
---

## Goal

Make `nextvar.lua` pass. Current failure is "attempt to concatenate a nil
value", which is likely a downstream symptom of A1 (table reads returning
nil correctly will let downstream code distinguish absent from present).

## Out of scope

- Anything outside the specific failure(s) in `nextvar.lua`.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] Each fixed issue has a unit test in `test/lua/vm/nextvar_*_test.exs`
- [ ] `nextvar.lua` passes end-to-end.

## Implementation notes

Blocked until A1 lands. After A1:

1. Re-run `nextvar.lua`. If it passes, close this plan as resolved.
2. If still failing, run `triage-suite-failure` workflow.
3. The "concatenate nil" pattern strongly suggests `next()` or `pairs()`
   returning `nil` where the test expects a real value. Inspect
   `lib/lua/vm/stdlib.ex` `lua_next` and `lua_pairs`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- May reveal multiple issues; split into sub-plans if needed.

## Discoveries

(populated during implementation)
