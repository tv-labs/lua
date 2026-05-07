---
id: A7a
title: Dead-key tracking for `next` so nextvar.lua passes end-to-end
issue: null
pr: null
branch: fix/nextvar-dead-keys
base: main
status: ready
direction: A
unlocks:
  - nextvar.lua
---

## Goal

Finish the work of plan A7 by making `nextvar.lua` pass end-to-end.
The remaining gap is the "dead-key" semantics that real Lua uses to
keep `next(t, k)` working when `t[k]` was just set to `nil` during
`pairs` iteration.

Lua 5.3 §6.1 says:

> The behavior of next is undefined if, during the traversal, you assign
> any value to a non-existent field in the table. You may, however, modify
> existing fields. In particular, you may clear existing fields.

The reference implementation supports the second sentence by leaving
removed keys reachable in the hash chain (marked `TDEADKEY`) so iteration
that already passed through that slot can still find the next live entry.

## Out of scope

- Anything outside dead-key tracking and the strict-`next` error path it
  unblocks. In particular: the table representation rewrite, faster
  `next`/`pairs`/`ipairs` implementations, stricter NaN-key handling.
- Promoting other suite files to `@ready_tests`.

## Success criteria

- [ ] `mix test` passes (≥ 1420, no regressions).
- [ ] `next(t, k)` raises "invalid key to 'next'" when `k` was *never* a
      key in `t` (Lua 5.3 §6.1; nextvar.lua line 230).
- [ ] `for k, v in pairs(t) do t[k] = nil end` iterates every key once
      without raising (nextvar.lua line 320–326).
- [ ] `nextvar.lua` passes end-to-end and is promoted to
      `@ready_tests` in `test/lua53_suite_test.exs`.
- [ ] Unit tests in `test/lua/vm/nextvar_dead_keys_test.exs`:
      one for the "never-existed key" error, one for the
      "iterate-then-clear" loop, one for "clear, re-assign, iterate"
      to make sure dead-key state doesn't leak across same-key reuse.

## Implementation notes

A few candidate shapes:

1. **Per-table iteration order list.** Add `Lua.VM.Table` an `order` list
   that mirrors keys in insertion order, plus a `dead` MapSet for keys
   whose slot is still in `order` but whose value has been cleared.
   `next(t, k)` walks `order` until it sees `k`, then returns the next
   `order` entry whose key is in `data`. `t[k] = nil` removes the key
   from `data` and adds to `dead`. `t[k] = v` (re-assignment) removes
   from `dead` and from `order`, and re-appends to `order`. This gives
   the same observable behavior as Lua's dead-key trick without changing
   the data map shape.

2. **Track a "tombstones" map.** Same idea but separate from `order` —
   `data` holds live values, `tombstones` holds previously-seen keys.
   `next` falls through `tombstones` to the next live entry. Slightly
   simpler than maintaining `order`.

3. **Use `:maps.iterator/1` snapshot once per pairs call.** Less
   faithful to Lua semantics; doesn't survive `t[k] = v` for new `v`.

Recommend (1). Consequences:

- Insertion order is deterministic (we already get this from Erlang maps,
  but it's not guaranteed for large maps). Storing it explicitly removes
  the dependency.
- `for k in pairs(t)` will iterate in insertion order, matching the
  closest thing Lua specifies.
- `Table.put_data/3` becomes the single place that has to maintain
  `order` and `dead`. Read paths don't change.

After landing:

1. Add the strict-`next` raise back in `lib/lua/vm/stdlib.ex` (the comment
   in `find_next_entry` calls this out — drop the comment when removing
   the leniency).
2. Move `nextvar.lua` from `@skipped_tests` to `@ready_tests` in
   `test/lua53_suite_test.exs`.
3. Verify the rest of the suite still passes.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- Changing the table representation (adding `order`/`dead`) touches
  every write path. Plenty of risk for subtle regressions in
  `pairs`/`ipairs`/`#`. Land behind the existing `Table.put_data`
  helpers from A7 to keep the surface narrow.
- Performance: `order` is an O(n) list. For tables with frequent
  re-assignments to the same key, list churn could matter. Defer the
  perf fix until benchmarks demand it.

## Discoveries

(populated during implementation)
