---
id: A7b
title: "table library functions honor __index/__newindex/__len"
issue: null
pr: null
branch: fix/table-lib-metamethods
base: main
status: in-progress
direction: A
unlocks:
  - nextvar.lua (partial — combined with A7c)
  - any user code that wraps a backing table in a proxy with a metatable
---

## Goal

Make `table.insert`, `table.remove`, `table.concat`, `table.move`, and
`table.sort` honor the `__index`, `__newindex`, and `__len` metamethods
on their target table, per Lua 5.3 §6.6 and the reference
implementation in `ltablib.c`. Today these functions read and write the
table's underlying data directly, bypassing metamethods.

## Out of scope

- Promoting `nextvar.lua` to `@ready_tests` — that is gated on A7c
  landing as well; a small follow-up plan can flip the suite once both
  are in.
- `pairs`/`ipairs` metamethod support (`__pairs`/`__ipairs`). Those are
  separate dispatch points and don't currently block the suite.
- Generalizing the dispatch helper to other stdlib modules. Scope this
  plan to `table.*` only.

## Success criteria

- [ ] `table.insert(proxy, v)` calls `__newindex` on `proxy`'s
      metatable when the slot is missing on the underlying table.
- [ ] `table.remove(proxy)` reads via `__index` to find the last
      element and writes `nil` via `__newindex`.
- [ ] `table.concat(proxy, sep)` reads element via `__index` and uses
      `__len` for the upper bound when present.
- [ ] `table.move(src, ...)` reads via `__index` on `src` and writes
      via `__newindex` on `dst`.
- [ ] `table.sort(proxy, cmp)` reads and writes via the metamethod
      pair. (Sort needs both reads and writes in the same call.)
- [ ] Unit tests in `test/lua/vm/stdlib/table_test.exs` (or new file)
      pinning each behavior with a proxy + backing-table fixture.
- [ ] `mix test` passes; no regressions in non-proxy paths.
- [ ] `mix test --only lua53`: 5 ready / 24 skipped (no change). The
      suite promotion happens in a follow-up after A7c lands.

## Implementation notes

Currently `lib/lua/vm/stdlib/table.ex` reaches into the table through
`Table.put/3` and direct map access. The fix is to route every read and
write through the same helpers the VM uses for `t[k]` and `t[k] = v` —
which already honor metamethods. Those helpers are `index_value/3` and
the `set_table` opcode path in `lib/lua/vm/executor.ex`.

Likely shape:

1. Extract the metamethod-aware read/write into small helpers inside
   `lib/lua/vm/state.ex` (or wherever `Table.put/3` lives) so the
   stdlib doesn't need to know about metamethod dispatch directly.
2. Replace direct `Table.put/3` calls in `stdlib/table.ex` with the
   new helpers. Length lookups should go through `__len` first, falling
   back to `Value.sequence_length/1` only on raw tables.

Repro that fails today (verified on main):

```lua
local backing = {1, 2, 3}
local proxy = setmetatable({}, {
  __index = backing,
  __newindex = backing,
  __len = function() return #backing end,
})
table.insert(proxy, 4)
assert(#backing == 4)            -- fails: backing unchanged
assert(table.concat(proxy, ",") == "1,2,3")  -- fails: returns "4"
```

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

Plus: re-run the standalone `nextvar.lua` survey to confirm we advance
past the table-library section. The suite file should still fail at
A7c's site (numeric-for string coercion at line 510); flag it as a
follow-up if it doesn't.

## Risks

- Sort algorithms that mutate in place may behave differently when
  every read goes through `__index` (e.g. extra metamethod calls during
  partition). Most plausible workaround is to materialize the slice
  into an Elixir list, sort, then write back via `__newindex` — which
  matches `ltablib.c`'s approach.
- `__newindex` set as a *table* (not a function) is recursive: writing
  to the proxy writes to the inner table, which may itself have a
  metatable. The VM already handles this for `t[k] = v`; reusing those
  helpers gets it for free.
- `__len` returning a non-integer or negative number must raise per
  spec. Check existing `#` handling for the precedent.

## Background

Discovered in A7a's Discoveries section (`A7b — table library
metamethods on __index/__newindex/__len`). Re-verified on main on
2026-05-07: `table.insert`/`table.concat` repro confirmed still failing.
