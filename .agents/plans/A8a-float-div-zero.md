---
id: A8a
title: Float division by zero must yield ±inf, not raise
issue: null
pr: null
branch: fix/float-div-zero
base: main
status: ready
direction: A
unlocks:
  - events.lua (line 156: `assert(a // (1/0) == a)`)
  - any code path that relies on Lua 5.3 §3.4.1 float semantics
---

## Goal

Make `1/0`, `-1/0`, and `0/0` evaluate to `+inf`, `-inf`, and `nan`
respectively, per Lua 5.3 §3.4.1, instead of raising
`"attempt to divide by zero"`. Only `//` (floor div) and `%` (modulo)
should raise on integer-zero divisors; plain `/` is always float
division and never raises.

## Out of scope

- Changing the `//` or `%` behavior (those correctly raise on integer
  zero in Lua 5.3 — confirm the integer/float branches separately).
- Implementing a full IEEE 754 float type. We only need values that
  compare correctly with `math.huge` and propagate through subsequent
  arithmetic the way the suite expects.

## Success criteria

- [ ] `1/0 == math.huge` (currently `math.huge` is `1.0e308`)
- [ ] `-1/0 == -math.huge`
- [ ] `0/0 ~= 0/0` (NaN inequality, the canonical NaN test)
- [ ] `math.huge + 1 == math.huge` survives (no overflow surprise)
- [ ] events.lua advances past line 156 (no regression at the metamethod fix)
- [ ] No regressions in `mix test`

## Implementation notes

Erlang's BIF `Float / 0.0` raises `:badarith`. We need to intercept
that in `safe_divide/2` (and likely `safe_floor_divide`'s float branch
plus modulo's float branch) and synthesize the right value.

Two viable representations:

1. **BEAM-native float infinity.** OTP 27 supports `:erlang.float/1`
   producing infinity in some contexts but does NOT support `inf`
   literals or `1.0/0.0` returning inf — `:badarith` is unconditional.
   This rules it out without an NIF.
2. **Stay with finite stand-ins.** `math.huge = 1.0e308` already.
   Have `1/0 -> 1.0e308`, `-1/0 -> -1.0e308`, `0/0 -> :nan` (a Lua
   sentinel atom we'd need to plumb through comparison). The downside
   is `1.0e308 + 1.0e308 == :infinity` won't hold without further
   work, but the suite tests don't hit that.

Recommended: option 2 (finite stand-in), since it matches the existing
`math.huge` decision. Document the divergence from real IEEE 754.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

Plus: re-run events.lua (currently skipped) and confirm it advances
past line 156. If events.lua passes end-to-end after this fix, move it
from `@skipped_tests` to `@ready_tests` in `test/lua53_suite_test.exs`.

## Risks

- NaN comparison rules are subtle. `nan != nan` is the IEEE rule but
  Erlang's `==` doesn't honor that. May need a custom equality path.
- `math.huge + math.huge` overflows to `:infinity` atom in Erlang;
  arithmetic on that raises. Could surface in suite code that does
  inf arithmetic.

## Background

Discovered while shipping A8 (events.lua metamethod fix). With the
metamethod calling convention fixed, events.lua advances from line 15
to line 156. Line 156 is `assert(a // (1/0) == a)`, which fails because
`1/0` raises rather than producing `inf`. This is a stdlib-level Lua
semantics gap, distinct from metamethod dispatch.
