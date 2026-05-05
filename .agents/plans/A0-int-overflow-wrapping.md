---
id: A0
title: 64-bit integer overflow wrapping for arithmetic and bitwise ops
issue: 161
pr: null
branch: feat/int-overflow-wrapping
base: main
status: ready
direction: A
unlocks:
  - bitwise.lua
---

## Goal

Make integer operations wrap to signed 64-bit per the Lua 5.3 spec, so
`maxint + 1 == minint` and `1 << 63 == minint` instead of overflowing into
arbitrary-precision Erlang integers.

## Out of scope

- Float arithmetic (already IEEE 754 — leave as-is).
- Float-to-integer coercion edge cases beyond what's already implemented.
- Any compiler/codegen changes.
- Suite triage of `bitwise.lua` failures unrelated to overflow (those go in
  a follow-up plan if any remain after this lands).

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit tests in `test/lua/vm/arithmetic_test.exs`:
  - `maxint + 1 == minint`
  - `minint - 1 == maxint`
  - `maxint * 2 == -2`
  - `1 << 63 == minint`
  - `~0 == -1`
  - `bnot(0xffffffffffffffff) == 0`
  - `0x8000000000000000 // 1 == minint` (no overflow into bignum)
- [ ] `mix test --only lua53` count is unchanged or improved (target:
      `bitwise.lua` flips green if it was failing solely on this).

## Implementation notes

The historical `phase-17-suite-triage` branch (commit `796e384`) had this
fix. Its approach:

- Add a `to_signed_int64/1` helper in `lib/lua/vm/executor.ex` (or a new
  `Lua.VM.Numeric` module if cleaner) that masks a value to 64 bits then
  converts to Erlang's signed range:
  ```elixir
  defp to_signed_int64(n) when is_integer(n) do
    masked = Bitwise.band(n, 0xffffffffffffffff)
    if masked >= 0x8000000000000000, do: masked - 0x10000000000000000, else: masked
  end
  ```
- Apply to integer arithmetic results: `:add`, `:subtract`, `:multiply`,
  `:floor_divide`, `:modulo`, unary `:negate`. Only when both operands are
  integers (not floats).
- Apply to bitwise ops: `:band`, `:bor`, `:bxor`, `:bnot`, `:shift_left`,
  `:shift_right`.
- The CPS executor (PR #156) reorganized these handlers — the helper goes
  in the same file where they live now.

NOTE: Main has moved significantly since `796e384` was written. The CPS
executor refactor (PR #156) and earlier perf PRs (#153–#155) changed the
shape of `executor.ex`. Do NOT cherry-pick the old commit blindly — read
the current code, then write fresh patches that fit the new structure.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/arithmetic_test.exs
```

## Risks

- Float operations must be untouched. If the helper accidentally fires on
  floats, IEEE 754 behavior breaks.
- Bitwise ops in Lua 5.3 are technically defined on 64-bit unsigned, but
  the result is presented as signed. Make sure tests cover the boundary
  cases (e.g. `0xffffffffffffffff + 1` should be `0` after wrapping).
- Some property tests in the existing test suite may rely on the current
  (incorrect) bignum behavior — they'll need updating to match Lua 5.3.
