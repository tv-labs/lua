---
id: A14
title: Fix for-loop register regression (consecutive for loops corrupt state)
issue: 146
pr: null
branch: fix/for-loop-register-regression
base: main
status: ready
direction: A
unlocks: []
---

## Goal

Fix the regression where two consecutive numeric `for` loops in any scope
produce a runtime type error on the second loop. This was originally fixed
in PR #141 (Phase 17) but reintroduced by the perf rewrites (likely the
CPS executor in PR #156).

## Reproduction

```lua
local sum = 0
for i = 1, 3 do sum = sum + i end
for i = 1, 3 do sum = sum + i end
return sum
```

Expected: `12`. Actual: `Lua runtime error: Runtime Type Error — attempt
to perform arithmetic on a nil value`.

A single for loop works fine. The bug appears only with two or more
consecutive `for` loops that share scope.

Stack trace points to:

```
lib/lua/vm/executor.ex:1594 anonymous fn/1 in safe_add/2
lib/lua/vm/executor.ex:1485 try_binary_metamethod/5
lib/lua/vm/executor.ex:713 do_execute/8
```

## Out of scope

- Other for-loop edge cases not directly tied to this regression.
- Architectural changes to the CPS executor (PR #156).
- Performance optimization of for-loop dispatch.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit test in `test/lua/vm/for_loop_register_test.exs`:
  - Two consecutive `for i = 1, n` loops produce correct sum.
  - Three consecutive `for i = 1, n` loops produce correct sum.
  - Two consecutive loops with different variable names work.
  - Two consecutive loops with the same variable name work (was the
    original #146 case).
- [ ] `mix test --only lua53` count: should not regress; may improve.
- [ ] Issue #146 closed automatically by the merging PR.

## Implementation notes

The original Phase 17 fix (commit `e7c50e5`) reserved 3 registers in scope
for the for-loop's internal counter/limit/step to prevent body-local
conflicts. The CPS refactor (PR #156, commit `13b2964`) reorganized the
executor and likely lost the register-clearing logic between iterations.

Steps:

1. Reproduce in isolation as a unit test (already verified above).
2. Inspect the current `:numeric_for` (or equivalent) handler in
   `lib/lua/vm/executor.ex` after the CPS rewrite. The handler may have
   been renamed.
3. Compare against what Phase 17 did: when a for loop completes, ensure
   the loop's local registers (counter, limit, step, loop_var) are not
   left polluting the parent scope's register file.
4. Fix the leak. Likely a missing register-clear between for-loop end and
   the next instruction, or a missing `open_upvalues` reset that was
   present in `e7c50e5`.

Read `lib/lua/compiler/codegen.ex` for how the for loop emits its
internal-register reservations — the codegen side may also need
adjustment if the bug is at compile time, not runtime.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/for_loop_register_test.exs
```

## Risks

- The CPS refactor was substantial; the fix needs to fit the new shape
  without re-introducing the perf cost it eliminated.
- If the bug is in codegen rather than executor, the unit test still
  passes after the fix but a downstream test may break — keep the suite
  test running throughout.
- The original fix (Phase 17) also touched upvalue handling; verify
  closures-over-loop-variables still work after this fix.

## Discoveries

(populated during implementation)
