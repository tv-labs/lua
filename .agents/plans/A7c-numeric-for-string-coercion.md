---
id: A7c
title: "numeric for coerces string control values to numbers (Lua 5.3 §3.3.5)"
issue: null
pr: null
branch: fix/numeric-for-string-coercion
base: main
status: ready
direction: A
unlocks:
  - nextvar.lua (line 510 — `for i="10","1","-2" do ... end`)
---

## Goal

Make `for i = init, limit, step` coerce string control values to
numbers (with the same rules as arithmetic), per Lua 5.3 §3.3.5:

> The for statement must evaluate once the values *e1, e2, e3*; these
> values are then converted to numbers using the same rules of
> arithmetic operators.

Today, the executor's `:numeric_for` opcode reads the control values
straight from registers and compares them with `<=` / `>=`. When the
values are strings, the comparison runs lexicographically (or, if the
step is also a string, raises) instead of triggering numeric coercion.

## Out of scope

- Generic `for-in` loops. They use a different opcode
  (`:generic_for`) and a different protocol; if string coercion is
  needed there it's a separate plan.
- Promoting `nextvar.lua` to `@ready_tests`. That is gated on A7b
  landing as well; promotion follows in a small plan once both are in.

## Success criteria

- [ ] `for i = "10", "1", "-2" do ... end` runs 5 iterations, matching
      the assert at nextvar.lua line 510.
- [ ] Mixed integer/string control values coerce correctly:
      `for i = 1, "10" do ... end` and `for i = "1.0", 5 do ... end`
      both work and follow the float/integer typing rule from §3.3.5
      (loop variable is a float if any of init/limit/step is a float
      or coerces to a float).
- [ ] A non-coercible string raises with a message that matches the
      reference: `'for' initial value must be a number` (or the closest
      existing message in this codebase — match what arithmetic
      produces for `tonumber("abc")` failure).
- [ ] Unit tests in `test/lua/vm/numeric_for_test.exs` (new file or
      add to an existing for-loop test file) pinning each case.
- [ ] `mix test` passes; no regressions.
- [ ] `mix test --only lua53`: 5 ready / 24 skipped (no change; suite
      promotion is gated on A7b too).

## Implementation notes

The opcode lives in `lib/lua/vm/executor.ex` at the `:numeric_for`
clause (currently around line 430). The init/limit/step values come
from `regs[base]`, `regs[base+1]`, `regs[base+2]`.

The fix should happen *once*, at loop start, not on every iteration:
coerce all three values to numbers, raise on failure with the right
message, and write the coerced values back into the same registers
before the first comparison. Subsequent iterations just increment in
place and compare numerically.

Float/integer rule (§3.3.5): if any of init/limit/step is a float (or
a string that coerces to a float, e.g. `"1.5"` or `"1e2"`), the loop
variable must be a float for every iteration. Integer-only control
values keep the loop variable an integer. The codebase has the
`narrow_if_integer/1` and arithmetic coercion helpers already; reuse
them.

Repro confirmed on main on 2026-05-07:

```lua
local a = 0
for i = "10", "1", "-2" do a = a + 1 end
assert(a == 5)  -- fails: a is 0 (loop body never executes)
```

The loop body never executes because `"10" <= "1"` is false (string
comparison treats `"1"` as greater than `"10"`).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

Plus: re-run the standalone `nextvar.lua` survey via the probe used
during plan drafting (or just `mix test --only lua53` once the suite
is promoted). It should advance past line 510. If it stops at a new
line, document that as the next follow-up before merging.

## Risks

- Lua 5.3 distinguishes integer-for from float-for at runtime — the
  reference implementation actually emits *different opcodes* for the
  two cases. We have a single `:numeric_for` opcode. If runtime
  coercion changes the type from int to float partway through, the
  step semantics differ (especially the loop-termination edge case at
  the limit). Worth a unit test that pins the documented behavior at
  the float/int boundary.
- Error messages: the reference says `'for' initial value must be a
  number` etc. We may not match exactly; match the suite's expectations
  from `nextvar.lua`'s checkerror calls if any are nearby. Otherwise,
  document the divergence in a comment.

## Background

Discovered in A7a's Discoveries section
(`A7c — numeric 'for' string-to-number coercion (Lua 5.3 §3.3.5)`).
Re-verified on main on 2026-05-07: loop body silently doesn't execute
when init is a string, and `nextvar.lua` line 510's assert fails.
