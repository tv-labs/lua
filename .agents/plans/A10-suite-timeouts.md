---
id: A10
title: Investigate big.lua, closure.lua, utf8.lua timeouts
issue: 171
pr: null
branch: fix/suite-timeouts
base: main
status: ready
direction: A
unlocks:
  - big.lua
  - closure.lua
  - utf8.lua
---

## Goal

Diagnose why these three suite files hang past 8 seconds. They likely have
distinct root causes; this plan does the triage and either ships a fix or
splits into A10a/b/c.

## Out of scope

- Performance optimization (Direction B).
- Anything not directly causing the timeout.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] Each timeout reduced to a fast-failing unit test (or fixed)
- [ ] At least 2 of 3 files complete (pass or proper failure) within 30s.

## Implementation notes

Triage workflow per file:

1. Add line-print instrumentation to find where it stops printing — that's
   near the infinite loop.
2. Reduce to a unit test that hangs with the same pattern.
3. Investigate. Common timeout causes in this VM:
   - For-loop exit condition that never trips (integer comparison vs
     float comparison mismatch).
   - Multi-return that produces an infinite stream because of a missing
     base case.
   - Recursive function with broken base case (likely in upvalue/closure
     code, given `closure.lua` is one of them).
   - `utf8.lua` repeats "testing UTF-8 library" — strongly suggests it
     loops on the test setup itself.

If a single root cause unblocks all three, ship together. If they're
distinct, split.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- Timeouts can mask real bugs. Make sure a fix doesn't just speed up a
  buggy infinite loop; it should produce correct output.
- Some loops may be intentional stress tests (`big.lua` is named for
  size); the suite expects them to complete in seconds, not minutes.

## Discoveries

(populated during implementation)
