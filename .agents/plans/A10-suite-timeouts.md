---
id: A10
title: Investigate big.lua, closure.lua, utf8.lua timeouts
issue: 171
pr: 191
branch: fix/suite-timeouts
base: main
status: merged
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

The three files turned out to have three distinct root causes. Only one
is in scope for Direction A's 0.5.0 cut; the other two are deferred
into split plans.

### utf8.lua — IN SCOPE, FIXED HERE

`utf8.lua` line 6 is `local utf8 = require'utf8'`. There is no `utf8`
stdlib module installed in this VM, so `require` falls through to the
filesystem search. `package.path` includes `test/lua53_tests/?.lua`,
so it finds — and runs — `utf8.lua` itself. That recursive load hits
the same `require'utf8'`, loops, and prints "testing UTF-8 library"
repeatedly forever.

This is a real `require` bug independent of utf8: any module file
whose name collides with itself on the search path would loop. Reference
Lua avoids this by caching a sentinel (`true`) in `package.loaded`
*before* executing the module body, so re-entrant `require` calls during
load resolve to the sentinel instead of re-loading.

Fix in `lib/lua/vm/stdlib.ex`:`parse_and_execute_module/4`: cache `true`
under `modname` in `package.loaded` immediately, then run the body, then
overwrite with the real return value.

After the fix, `utf8.lua` fast-fails in ~20 ms with "key 1 not found in
%{}" — the test code dereferences `utf8.charpattern` on what is now the
sentinel boolean, which is the correct, expected failure given that no
`utf8` stdlib module exists. That's the natural stopping point until
the `utf8` library itself is implemented (separate concern).

### closure.lua — OUT OF SCOPE → A10a (deferred)

Lines 27-32 are a "spin until GC" loop using `__mode = 'kv'` weak
references. Without weak-table semantics, the inner table is never
collected and the loop is infinite. Implementing weak tables is a
multi-day feature with implications for every table read/write/alloc
path; not worth blocking 0.5.0 on. See `A10a-closure-weak-tables.md`.

### big.lua — OUT OF SCOPE → A10b (deferred)

Builds a ≈263k-element source-string array via `for i=1,lim do
prog[#prog + 1] = i end`. `Lua.VM.Value.sequence_length/1` is a linear
scan, so `#prog + 1` is O(n) and the loop is O(n²) — runs for tens of
seconds, not the few seconds the suite expects. This is a Direction B
(performance) concern. See `A10b-big-perf.md`.

## What changed

- `lib/lua/vm/stdlib.ex` — `parse_and_execute_module/4` now writes a
  `true` sentinel to `package.loaded[modname]` before executing the
  module body, mirroring reference Lua. Prevents infinite recursion
  on self-requiring modules.
- `test/lua/vm/stdlib/package_test.exs` — added a `require recursion
  guard` describe block with three tests:
  1. A module that self-requires returns the sentinel without re-loading.
  2. Two modules that mutually require each other don't loop.
  3. `require` returns the cached value on a second call (and the
     module body is only evaluated once).
- `.agents/plans/A10a-closure-weak-tables.md` — new deferred plan for
  the `closure.lua` weak-table issue.
- `.agents/plans/A10b-big-perf.md` — new deferred plan for the
  `big.lua` table-append performance issue.

Suite count: 4/29 ready → 4/29 ready (utf8.lua now fails fast but
`utf8` stdlib still missing, so it stays in `@skipped_tests`).
Test count: 1354 → 1357 (+3 new). No regressions.
