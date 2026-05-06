---
id: A10b
title: Make big.lua's 263k-element table-build complete in seconds
issue: null
pr: null
branch: perf/big-suite
base: main
status: deferred
direction: B
unlocks:
  - big.lua
---

## Goal

`big.lua` builds a `2^18 + 1000` (≈ 263,144) element source-string array
with a hot loop:

```lua
local prog = { "local y = {0" }
for i = 1, lim do prog[#prog + 1] = i  end
```

That `#prog + 1` call is currently O(n) because `Lua.VM.Value.sequence_length/1`
is a linear scan from key 1 upward (lib/lua/vm/value.ex:97). With ~263k
iterations, the loop is O(n²) and never returns within the suite's 8-
second budget.

This plan makes the loop fast enough that `big.lua` finishes in seconds.

## Out of scope

- Implementing a full LuaJIT-style array part. The minimum bar is
  amortized O(1) `t[#t + 1] = x`, not full numeric-index optimization.
- Other large-input perf issues. This plan is scoped to whatever
  `big.lua` exposes.

## Why deferred

This is Direction B (performance). Direction A is wrapping up the 0.5.0
suite triage; perf work happens after. Filing as deferred so the
timeout investigation in A10 has somewhere to point.

## Implementation notes (sketch, for future reference)

Two reasonable directions:

1. **Cache sequence length on the table struct.** Track the contiguous
   prefix length on every insert/delete that affects key `len + 1` or
   `len`. `sequence_length/1` becomes a struct read, `#t` becomes O(1).
   This is the closest analog to reference Lua's array-part length
   bookkeeping.
2. **Split storage into array + hash parts.** More invasive but matches
   PUC-Lua/LuaJIT internal layout. Likely needed eventually for any
   serious benchmark work.

Option 1 is sufficient for `big.lua` and a much smaller change. Start
there. Option 2 is its own plan if benchmarks show the array+hash split
matters.

Once the table is fast, also verify:

- `string.rep("\0", ssize)` for `ssize ≈ 2^32 / 192` doesn't itself
  blow up on the test that exercises 32-bit string-length overflow.
  (That test is gated on `2^32 == 0`, i.e. small-integer Lua, so it
  may not even run here — confirm during implementation.)

## Risks

- Cached length must stay correct across every code path that mutates
  table data (raw assignment, `table.insert`, `table.remove`,
  metamethod-driven writes, etc.). Easy to get subtly wrong.
- Performance regression elsewhere if the bookkeeping is hot enough on
  small tables to matter. Bench before/after.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

`big.lua` should complete (pass or proper failure) within 30 seconds —
ideally under 10.
