---
id: A7a
title: Dead-key tracking for `next` so nextvar.lua passes end-to-end
issue: null
pr: 202
branch: fix/nextvar-dead-keys
base: main
status: review
direction: A
unlocks:
  - nextvar.lua  # partial — full pass requires A7b (table-lib metamethods)
                 # and A7c (numeric-for string coercion)
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

- [x] `mix test` passes (≥ 1420, no regressions) — 1430 tests, 0 failures.
- [x] `next(t, k)` raises "invalid key to 'next'" when `k` was *never* a
      key in `t` (Lua 5.3 §6.1; nextvar.lua line 230).
- [x] `for k, v in pairs(t) do t[k] = nil end` iterates every key once
      without raising (nextvar.lua line 320–326).
- [ ] `nextvar.lua` passes end-to-end and is promoted to
      `@ready_tests` in `test/lua53_suite_test.exs` — **deferred**.
      With dead-key tracking landed, bisecting nextvar.lua revealed
      additional pre-existing semantic gaps that block end-to-end pass.
      See Discoveries below for the follow-up plans.
- [x] Unit tests in `test/lua/vm/nextvar_dead_keys_test.exs`:
      one for the "never-existed key" error, one for the
      "iterate-then-clear" loop, one for "clear, re-assign, iterate"
      to make sure dead-key state doesn't leak across same-key reuse.
      (10 cases total, covering each contract plus a few neighbors.)

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

### Dead-key implementation shape

Went with the plan's recommended approach (1) — add an explicit `order`
list and `dead` MapSet to `Lua.VM.Table`. To avoid scattering the
bookkeeping across every write site, introduced `Table.put/3` (operates
on the full struct) and `Table.replace_data/2` (for wholesale rewrites
like `table.sort`). Routed every mutation site through `Table.put/3`:

  - `lib/lua/vm/state.ex` — `set_global/3`, `alloc_table/2`.
  - `lib/lua/vm/executor.ex` — `set_list` (both variants), `table_newindex`.
  - `lib/lua/vm/stdlib.ex` — `rawset`.
  - `lib/lua/vm/stdlib/table.ex` — `table_insert`, `table_remove`,
    `table_sort`, `table_move`.
  - `lib/lua.ex` — public-API `set_in_table` helpers.

`Table.put_data/3` is kept for callers that only have a raw data map
and don't care about iteration order.

### `table.remove` shape correction

While converting `table_remove` to use `Table.put/3`, fixed two
pre-existing semantic gaps that fell out of mirroring Lua 5.3's
`ltablib.c tremove` more closely:

  - `table.remove(t)` when `#t == 0` now removes (and returns) `t[0]`
    instead of returning `nil` early. nextvar.lua line 362 explicitly
    relies on this: `a = {[0] = 'ban'}; assert(table.remove(a) == 'ban')`.
  - `table.remove(t, pos)` raises `position out of bounds` when
    `pos < 1 or pos > #t + 1` (with the `pos == #t` shortcut so that
    `table.remove(t, 0)` works when `#t == 0`). Previously returned
    `nil` silently for any out-of-range pos. nextvar.lua line 382 relies
    on the raise: `assert(not pcall(table.remove, a, 0))`.

The `do_table_remove/5` helper centralizes the shift+clear loop that
mirrors the loop in the Lua C source.

### Why `nextvar.lua` is not yet promoted to `@ready_tests`

After landing dead-key tracking, bisecting `nextvar.lua` from a clean
slate showed two distinct pre-existing failures further down the file
that have nothing to do with iteration semantics:

1. **Stdlib metamethod virtualization (lines 389–433).** The block
   testing `table.insert`/`table.remove`/`table.sort`/`table.concat` on
   a table that uses `__index`/`__newindex`/`__len` to virtualize a
   wrapped table fails immediately. The library functions read
   `table.data` and call `get_table_length` directly instead of going
   through `__len` and `__index`/`__newindex` metamethods. This was true
   on `main` before A7a touched anything (verified via `git stash`).
   Worth its own plan — call it **A7b — table library metamethods**.

2. **String-to-number coercion in numeric `for` (line 510).** The line
   `for i="10","1","-2" do a=a+1 end` should coerce its three string
   arguments to numbers (Lua 5.3 §3.3.5 — "the loop variables and the
   limits must be numbers; if any of them is a string, it is coerced
   to a number"). Today the loop never enters the body. Also pre-existing.
   Call it **A7c — numeric `for` string coercion**.

There are likely more downstream gaps (the bisect was halted once the
pattern of "pre-existing, unrelated to iteration" became clear). They
will surface as A7b/A7c land. The dead-key contracts the plan was
written to fix are all green; promoting the suite file should happen in
a small follow-up plan once the rest of the gates are closed.

### Files touched

- `lib/lua/vm/table.ex` — added `from_data/1`, `replace_data/2`, `put/3`,
  `next_entry/2`; documented the `order`/`dead` invariant.
- `lib/lua/vm/state.ex` — `alloc_table/2` builds tables via `from_data`
  so the iteration `order` mirrors initial map keys; `set_global/3`
  goes through `Table.put/3`.
- `lib/lua/vm/executor.ex` — `set_list` (both forms) and
  `table_newindex` write via `Table.put/3`.
- `lib/lua/vm/stdlib.ex` — `lua_next` uses `Table.next_entry/2` and
  raises `bad argument #2 to 'next' (invalid key to 'next')` on
  unknown keys; `rawset` uses `Table.put/3`.
- `lib/lua/vm/stdlib/table.ex` — `table_insert`/`table_remove`/
  `table_sort`/`table_move` route through `Table.put/3` (and
  `Table.replace_data/2` for `table_sort`); `table_remove` now matches
  Lua 5.3 ltablib.c semantics for `pos == 0` / `pos == #t + 1`.
- `lib/lua.ex` — `set_in_table` helpers go through `Table.put/3`.
- `test/lua/vm/nextvar_dead_keys_test.exs` — new file pinning each
  dead-key contract.

## What changed

- PR: #202 (`fix(vm): track dead keys so pairs survives mid-iteration deletion`)
- `mix test`: 1420 → 1430 (+10 unit tests in
  `test/lua/vm/nextvar_dead_keys_test.exs`; 0 failures, 31 skipped).
- `mix test --only lua53`: 5 ready / 24 skipped (unchanged — `nextvar.lua`
  promotion is deferred to A7b/A7c per Discoveries).
- Files touched (7): `lib/lua/vm/table.ex`, `lib/lua/vm/state.ex`,
  `lib/lua/vm/executor.ex`, `lib/lua/vm/stdlib.ex`,
  `lib/lua/vm/stdlib/table.ex`, `lib/lua.ex`, plus new
  `test/lua/vm/nextvar_dead_keys_test.exs`.
- Follow-ups identified during bisecting `nextvar.lua`:
  - **A7b** — table library metamethods on `__index`/`__newindex`/`__len`.
  - **A7c** — numeric `for` string-to-number coercion (Lua 5.3 §3.3.5).
  Once both land, a small follow-up plan can promote `nextvar.lua` to
  `@ready_tests`.
