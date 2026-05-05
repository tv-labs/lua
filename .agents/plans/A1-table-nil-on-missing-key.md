---
id: A1
title: Empty/missing-key table reads return nil instead of crashing
issue: 162
pr: null
branch: fix/table-nil-on-missing-key
base: main
status: review
direction: A
unlocks:
  - errors.lua
  - sort.lua
  - strings.lua
  - verybig.lua
  - nextvar.lua
---

## Goal

Reading a missing key from a table must return `nil`, not raise
`Map.fetch!` (which currently surfaces as `Lua runtime error: key N not
found in: %{}`).

This is the highest-leverage Direction A fix: it unblocks at least 4 suite
files that all share the same root cause.

## Out of scope

- Metatable `__index` resolution (this is already implemented and must keep
  working — fix must not break it).
- Performance optimization of table access.
- Any other suite failures that surface downstream of this fix; those go in
  follow-up plans.
- Behavior of `rawget` (also already correct — don't touch).

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit tests in `test/lua/vm/table_index_test.exs`:
  - `local t = {}; return t[5]` → returns `[nil]`
  - `local t = {1,2,3}; return t[10]` → returns `[nil]`
  - `local t = {a=1}; return t.b` → returns `[nil]`
  - `local t = {}; return t[5] == nil` → returns `[true]`
  - Metatable `__index` still resolves correctly (regression test)
- [ ] `mix test --only lua53` count improves: at least 2 of the 4 listed
      `unlocks:` files pass (some may surface new downstream failures —
      that's acceptable; track in `## Discoveries`).

## Implementation notes

Find the failing path: it's currently a `Map.fetch!` in `executor.ex`
somewhere in the table-read instruction handler(s).

After the CPS executor refactor (PR #156), the relevant handlers are likely
named differently from the old design. Search for:

```bash
grep -nE "Map.fetch!|\\\\[.*\\\\]" lib/lua/vm/executor.ex
grep -nE "(get_field|get_table|get_index|table_get)" lib/lua/vm/executor.ex
```

Replace the offending `Map.fetch!(table.data, key)` with
`Map.get(table.data, key, nil)` — but only AFTER the metatable `__index`
chain has been consulted. The order is:

1. Direct lookup in `table.data`.
2. If not present and table has metatable with `__index`, walk the chain.
3. If still not found, return `nil`.

The bug is likely that step 1 raises instead of falling through to step 2,
or that step 3 never runs because step 1 raises.

Also check `lib/lua/vm/stdlib.ex` `pairs` / `ipairs` / `next` — they may
have similar `Map.fetch!` calls that should be `Map.get`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/table_index_test.exs
```

Compare suite count before/after; capture in PR body.

## Risks

- If `__index` metamethod resolution depended on the raise (using
  rescue/try as control flow), the metamethod path needs explicit reordering.
- A test may currently rely on the raise — search for it before changing,
  update the test if needed.
- Some ipairs/next implementations may use the raise to detect end-of-array;
  if so, switch them to explicit `Map.has_key?` checks.

## Discoveries

The four explicit success-criteria cases (`local t = {}; return t[5]`,
out-of-bounds array read, missing string field, `t[5] == nil`) **already
returned `nil` correctly** when this plan was picked up. Same for
metatable `__index` resolution (function and table forms), `rawget`,
`pairs`/`ipairs` over empty tables, and `next({})`. The underlying fix
appears to have landed earlier — most likely as part of the CPS executor
refactor in PR #156.

The error message the plan describes (`Lua runtime error: key N not found
in: %{}`) does still appear in some Lua 5.3 suite files (`sort.lua`,
`strings.lua`, `verybig.lua`), but the source is **not** a missing
`table.data` key. It is `Map.fetch!(state.open_upvalues, reg)` in
`lib/lua/vm/executor.ex` at lines 301 and 310 — an open-upvalue tracking
bug that surfaces with the same exception class. Tracked separately in
plan **A15** (`fix/open-upvalue-missing-cell`).

`nextvar.lua` fails with a different shape (`attempt to concatenate a nil
value`); reproducer points at the same area as the for-loop register
regression covered by plan **A14**.

This PR therefore does not change runtime behaviour. It locks in the
existing correct behaviour with a regression test file
(`test/lua/vm/table_index_test.exs`, 10 cases) so the bug cannot
silently come back, and opens A15 to handle the unlocked-files
slice that is in fact a different bug.

## What changed

- New file: `test/lua/vm/table_index_test.exs` — 10 regression tests
  covering missing-key reads (empty table, out-of-bounds array, missing
  string field, `nil` comparison), metatable `__index` fall-through
  (function form, table form, and direct-hit short-circuit), and stdlib
  helpers (`rawget`, `next`, `pairs`).
- New plan: `.agents/plans/A15-open-upvalue-missing-cell.md` — covers the
  `set_open_upvalue` / `get_open_upvalue` crash that this plan originally
  attributed to table-data reads.
- No production code changes. Suite count unchanged. `mix test` 1284 → 1294
  (10 new tests, 0 failures).
