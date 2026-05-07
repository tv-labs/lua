---
id: A8c
title: "// and % with float-zero divisor return inf/nan, not raise"
issue: null
pr: null
branch: fix/floor-div-mod-float-zero
base: main
status: ready
direction: A
unlocks:
  - any code path exercising Lua 5.3 §3.4.1 float semantics for `//`/`%`
---

## Goal

Make `a // 0.0` and `a % 0.0` follow Lua 5.3 §3.4.1: the float branch
of floor-division and modulo must return ±inf or nan, never raise.
Today both raise (`"attempt to divide by zero"` and `"attempt to
perform modulo by zero"`). The integer branch of both operators
*should* keep raising — that's correct per spec.

## Out of scope

- `/` (regular division) — already correct, was fixed in A8a.
- Negative-zero handling, signaling NaN distinctions, or any IEEE 754
  edge case beyond what A8a's "finite stand-in" model already supports.
- `events.lua` promotion — gated separately on A8b and possibly more.

## Success criteria

- [ ] `1.0 // 0.0` returns `math.huge` (currently raises).
- [ ] `-1.0 // 0.0` returns `-math.huge`.
- [ ] `0.0 // 0.0` returns `:nan` (using A8a's sentinel) and survives
      the equality rule `nan ~= nan`.
- [ ] `1.0 % 0.0` returns `:nan` (per Lua 5.3: `a % b = a - floor(a/b)*b`,
      and `a/0.0 = inf`, so `floor(inf)*0.0 = nan`).
- [ ] `1 // 0` (integer) still raises `"attempt to divide by zero"`.
- [ ] `1 % 0` (integer) still raises `"attempt to perform modulo by zero"`.
- [ ] Mixed integer/float zero divisor: `1 // 0.0` follows the float
      path (returns inf), `1.0 // 0` raises (integer divisor).
- [ ] Unit tests in `test/lua/vm/float_div_zero_test.exs` (extend the
      file A8a created) pinning each combination.
- [ ] `mix test` passes; no regressions.

## Implementation notes

The fix is local to `safe_floor_divide/2` and `safe_modulo/2` in
`lib/lua/vm/executor.ex` (around lines 1620–1662). Today both functions
collapse "any zero divisor" into a single raise:

```elixir
nb == 0 or nb == 0.0 ->
  raise RuntimeError, value: "attempt to divide by zero"
```

The fix splits this into two cases: integer divisor → raise; float
divisor → produce the `safe_divide`-style sentinel.

For `safe_floor_divide`, the float branch already does
`Float.floor(na / nb) * 1.0`. With `nb = 0.0`, `na / nb` should now go
through `safe_divide` (which already handles the inf/nan case) and
`Float.floor(:nan)`/`Float.floor(1.0e308)` need handling. Probably
simpler: short-circuit when `is_float(nb) and nb == 0.0` to return the
right sentinel directly without going through `Float.floor`.

For `safe_modulo`, by Lua's definition `a % 0.0` is always nan
(integer-zero divisor still raises). Short-circuit to `:nan`.

Repros confirmed on main on 2026-05-07:

```elixir
{r, _} = Lua.eval!(Lua.new(), "return 1.0 // 0.0")     # raises
{r, _} = Lua.eval!(Lua.new(), "return 1.0 % 0.0")      # raises
```

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- The `:nan` sentinel was introduced in A8a but only flows through
  `safe_divide`. Modulo using `:nan` needs to make sure subsequent
  arithmetic and equality on the result behave (the `lua_equal/2`
  helper already special-cases `:nan`). Verify ordering / comparison
  ops too.
- `Float.floor(1.0e308)` returns `1.0e308` cleanly in BEAM, so the
  inf-via-stand-in path is fine. Confirm in a test rather than by
  inspection.
- `is_float(nb)` in Elixir distinguishes from `is_integer(nb)` — but
  `0.0 == 0` is `true`, so guard ordering matters. Use
  `is_float/1` explicitly, not `nb == 0.0`.

## Background

Discovered in A8a's PR Discoveries section as follow-up #2:
"`//` and `%` with float-zero divisor still raise (separate plan)."
Re-verified on main on 2026-05-07: both `1.0 // 0.0` and `1.0 % 0.0`
still raise.
