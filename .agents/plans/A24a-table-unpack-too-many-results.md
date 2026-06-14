---
id: A24a
title: "table.unpack raises 'too many results' for out-of-range slices"
issue: 262
pr: 293
branch: fix/stdlib-data-structure
base: main
status: merged
direction: A
---

## Goal

Make `table.unpack(list, i, j)` reject ranges that would produce more
than `INT_MAX` results (raising `too many results to unpack`) before it
tries to materialise the slice, matching Lua 5.3 `ltablib.c`.

This is the single most tractable concrete failure in the A24 cluster
(parent plan `.agents/plans/A24-triage-stdlib-data-structure.md`,
issue #262): the first assertion `sort.lua` hits is at line 16, driven
by `checkerror("too many results", unpack, {}, 0, maxi)` on line 48.

## Out of scope

- `constructs.lua` os/debug/short-circuit cases (other PRs in the batch).
- `literals.lua` parse-error wording and `debug.getinfo` line skips.
- `table.sort` "too big" / "invalid order function" checks (sort.lua
  lines 199, 204) — those remain behind the narrowed skip range.
- The `os.clock`-driven timing section of `sort.lua`.
- Stable/quadratic sort behaviour and performance.

## Success criteria

- [x] `table.unpack({}, 0, math.maxinteger)` raises an error whose
      message contains `too many results` instead of hanging.
- [x] Small/valid `table.unpack` ranges are unaffected.
- [x] Regression test under `test/lua/vm/` covering the boundary.
- [x] `mix test` passes.
- [x] `mix test test/lua53_suite_test.exs --only lua53` passes.

## Implementation notes

- `lib/lua/vm/stdlib/table.ex` `table_unpack/2`: after resolving `i`/`j`
  and the integer checks, if `i <= j and j - i >= INT_MAX` raise
  `Lua.VM.RuntimeError` with `too many results to unpack`. The
  subtraction is on Elixir bignums so it cannot overflow.
- `INT_MAX` is `2_147_483_647`; PUC rejects `(j - i) >= INT_MAX`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua53_suite_test.exs --only lua53
```

## Discoveries

- `sort.lua` does not fully unlock with this fix. The first assertion it
  hit (line 16, via the unpack range checks) is now resolved, but the
  file remains a whole-file skip for performance: the 2000-element
  `unpack` loop plus the `perm`/`timesort` sections drive an O(n^2)
  `table.sort` that runs for *minutes* (measured: ~350s to reach line
  162 standalone), and the `os.clock` timing harness is unimplemented.
  The skip entry's `reason` is updated and now carries `issue: 262`.
- `table.move` shares the "materialise the whole range before writing"
  shape (`table.move(a, 1, math.maxinteger, 0)` at sort.lua line 174),
  so it cannot interrupt on the first `__newindex` the way PUC does.
  That is a separate, larger fix — left for a follow-up.

## Risks

- The fix changes `table.unpack` error behaviour for very large ranges.
  Mitigated by unit tests covering both the rejected and the
  normal-range paths.
