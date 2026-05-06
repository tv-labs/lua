---
id: A10a
title: Implement weak-table semantics so closure.lua's GC loop terminates
issue: null
pr: null
branch: feat/weak-tables
base: main
status: deferred
direction: A
unlocks:
  - closure.lua
---

## Goal

`closure.lua` lines 27-32 contain a "spin until GC" loop that uses a
weak-keyed/valued table to detect when garbage collection has reclaimed
an unreachable inner table:

```lua
local x = {[1] = {}}   -- to detect a GC
setmetatable(x, {__mode = 'kv'})
while x[1] do          -- repeat until GC
  local a = A..A..A..A -- create garbage
  A = A+1
end
```

This VM has no garbage collector and ignores `__mode`, so `x[1]` is
never reclaimed and the loop is infinite. The whole rest of the file
runs after this loop.

This plan would teach the runtime to honor `__mode = 'k'`, `'v'`, and
`'kv'` on tables — at minimum well enough to satisfy this loop — so
that `closure.lua` can be moved to `@ready_tests`.

## Out of scope

- A full tracing GC. Phoenix's garbage collector is fine for our
  Elixir-side memory; what we need is *visibility* into when a Lua-side
  reference becomes the last reference.
- Optimizing weak-reference performance.

## Why deferred

Weak tables are a multi-day feature with implications for every
table-allocation, table-read, and table-write path in `lib/lua/vm/`.
Bringing them in just to unblock one suite file isn't a good trade for
the 0.5.0 cut. Revisit after 0.5.0 ships.

## Status: deferred

Not blocking any other plan. No concrete unlock criteria — pick this up
when weak-table semantics is worth the surface-area cost.

## Implementation notes (sketch, for future reference)

- Add a `mode` field to `Lua.VM.Table` (`nil`, `:k`, `:v`, or `:kv`).
- On `setmetatable`, if the metatable has a string `__mode` field, set
  the table's mode accordingly.
- During table reads/writes, when the mode is set, treat any value/key
  whose only reference path is through a weak table as collectible.
  - In an Elixir/BEAM-hosted VM, the cleanest implementation is
    probably `:ets` with appropriate concurrency settings, OR a
    periodic sweep keyed off `Process.info(self(), :reductions)`.
- A weaker fix (sufficient for this loop only) is to special-case
  `__mode='kv'` to *immediately* drop entries whose value is a freshly
  allocated table that has no other references — but detecting "no
  other references" without GC integration is non-trivial.

## Risks

- Subtle semantics drift if our weak-table model differs from
  reference Lua.
- Performance regression on every table operation if weakness checks
  aren't carefully gated.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

`closure.lua` should complete (pass or proper failure) in well under
10 seconds.
