---
id: A0
title: 64-bit integer overflow wrapping for arithmetic and bitwise ops
issue: 161
pr: 177
branch: feat/int-overflow-wrapping
base: main
status: review
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

## What changed

PR #177.

Files touched:

- `lib/lua/vm/numeric.ex` (new) — `to_signed_int64/1`, `max_int/0`,
  `min_int/0`, `signed?/1`, with module docs spelling out the
  Lua-vs-Luerl divergence.
- `lib/lua/vm/executor.ex` — wrapped integer-only results in `+`, `-`,
  `*`, `//`, `%`, unary `-`, `&`, `|`, `~^`, `~`, `<<`, `>>`. Floats
  untouched. Pre-existing partial wrapping in `lua_shift_left`/
  `lua_shift_right` (masked unsigned, leaving high-bit results as
  positive bignums) now produces signed values.
- `test/lua/vm/arithmetic_test.exs` — 11 new tests covering the
  required cases plus `negation of minint`, `float arithmetic
  unaffected`, and `modulo wraps`.

Suite delta: `mix test` 1273 → 1284 (11 new tests, no regressions).
`mix test --only lua53` unchanged at 29/0/25. `bitwise.lua` not flipped
green — additional stdlib work is required and is the scope of A5.

Discovery: `lua_shift_left/2` was already half-Lua-flavored (masked to
unsigned 64-bit) but had not been updated to return signed values. The
plan called this out only obliquely via the `1 << 63 == minint` success
criterion; the fix is included here since it is in scope and required
for that test.

Follow-up: documenting the Luerl divergence in CHANGELOG / release
notes belongs with A12 (readme/changelog) before 0.5.0 ships.
