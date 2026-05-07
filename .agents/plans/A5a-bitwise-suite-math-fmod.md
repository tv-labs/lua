---
id: A5a
title: Add math.fmod for bitwise.lua bit32 verification
issue: null
pr: null
branch: feat/math-fmod
base: main
status: in-progress
direction: A
unlocks:
  - bitwise.lua (final third — bit32.lshift verification block)
---

## Goal

Implement `math.fmod` so `bitwise.lua` can finish its bit32-library
verification block (line 278 onward). This was the last remaining gap
discovered while shipping A5.

## Out of scope

- Other missing math.* functions (math.modf, math.atan2, etc.) unless they
  are also exercised by `bitwise.lua` and we hit them while wiring fmod in.
- A `package.searchers` table (currently we have a narrow `package.preload`
  hook added in A5; full searchers list is a separate concern).

## Success criteria

- [ ] `math.fmod(x, y)` works per Lua 5.3 §6.7:
      "Returns the remainder of the division of x by y that rounds the
      quotient towards zero."
- [ ] `math.fmod` of two integers returns an integer; otherwise returns a
      float.
- [ ] `mix test` passes, no regressions.
- [ ] Unit tests in `test/lua/vm/stdlib/math_test.exs` cover: integer/integer,
      integer/float, float/float, negative dividend, divide-by-zero behavior
      (raises for ints, returns NaN for floats per Lua semantics).
- [ ] `bitwise.lua` passes end-to-end. (This was deferred from A5.)

## Implementation notes

Add `math.fmod` to `lib/lua/vm/stdlib/math.ex` next to `math.floor`. For
two integers, use `Kernel.rem/2` (truncated remainder, sign of dividend),
matching C's `%` and Lua 5.3's `math.fmod` for ints. For floats, use
`:math.fmod/2` if available or compute as `x - trunc(x / y) * y`.

Then re-run `bitwise.lua` to confirm. If new gaps surface (other missing
math functions, etc.), the triage-suite-failure skill applies the same
way: reduce → fix-now-or-defer → ship.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/stdlib/math_test.exs
mix run --no-mix-exs -e 'Code.require_file("test/support/lua_test_case.ex"); Lua.TestCase.run_lua_file("test/lua53_tests/bitwise.lua")'
```

## Risks

- Lua 5.3 specifies `math.fmod(x, 0)` for integers raises "bad argument #2
  ... (zero)" but for floats returns NaN. We need to honor both cases.
- Bit-perfect float fmod is subtle for edge cases (NaN, infinities). Lua
  defers to C's `fmod`; Erlang's `:math.fmod/2` is the same OS-level
  implementation, so we should match.

## Discoveries

(populated during implementation)
