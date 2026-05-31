---
id: A21a
title: "Integer division/modulo by zero: PUC message + float-operand semantics"
issue: 259
pr: null
branch: fix/runtime-type-cluster
base: main
status: in-progress
direction: A
---

## Goal

Fix `//` and `%` zero-divisor handling in the VM so it matches PUC-Lua
5.3: integer `//` zero reports "attempt to divide by zero", and a float
operand follows the float (inf/nan) path instead of raising.

This is a concrete sub-fix carved out of the parent triage cluster
(A21, issue #259), independent of the deferred `math.huge` finite
stand-in limitation that keeps `math.lua` skipped overall.

## Out of scope

- The `math.huge` / `:nan` finite-sentinel design (the reason `math.lua`
  remains skipped). NaN/inf flowing through bitwise ops is unchanged.
- `os.*` (handled in a separate PR).
- Unskipping `math.lua` or `errors.lua` wholesale.

## Success criteria

- [ ] `2 // 0` raises with a message containing "divide by zero"
      (PUC-Lua parity; previously "attempt to perform 'n//0'").
- [ ] `2.0 // 0` and `2.0 % 0` do NOT raise — a float operand makes the
      whole expression float `//`/`%`, yielding inf/nan.
- [ ] `mix test` passes.
- [ ] `mix test test/lua53_suite_test.exs --only lua53` passes.

## Implementation notes

`lib/lua/vm/executor.ex`:

- `safe_floor_divide/6`: only raise when BOTH operands are integers and
  the divisor is zero; change the message to "attempt to divide by
  zero". When either operand is a float, take the inf/nan path.
- `safe_modulo/6`: same both-operands-integer guard; message `'n%0'`
  is already correct.

Verified against PUC-Lua: `2 // 0` -> "attempt to divide by zero";
`2 % 0` -> "attempt to perform 'n%0'"; `2.0 // 0` -> inf; `2.0 % 0`
-> nan.

Tests updated to the corrected contract: `float_div_zero_test.exs`,
`arithmetic_test.exs`, `error_format_test.exs`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua53_suite_test.exs --only lua53
```

## Risks

- Other suite files may assert the old `'n//0'` wording. Mitigated:
  the suite (`errors.lua`, `math.lua`) expects "divide by zero", and
  our own tests were the only ones pinning the old message.
</content>
</invoke>
