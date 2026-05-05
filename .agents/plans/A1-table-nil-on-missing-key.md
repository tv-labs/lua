---
id: A1
title: Empty/missing-key table reads return nil instead of crashing
issue: 162
pr: null
branch: fix/table-nil-on-missing-key
base: main
status: in-progress
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

(populated during implementation)
