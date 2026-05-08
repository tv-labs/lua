---
id: A8d
title: "~= opcode dispatches through __eq metamethod"
issue: null
pr: null
branch: fix/not-equal-eq-metamethod
base: main
status: in-progress
direction: A
unlocks:
  - any code that compares two metamethod-wrapped values with ~=
---

## Goal

Make the `:not_equal` opcode go through the `__eq` metamethod the same
way `:equal` does, then negate the result. Today `:not_equal` is
implemented as `not lua_equal(a, b)`, which compares the raw values
directly and bypasses metamethod dispatch entirely.

Per Lua 5.3 §3.4.4, `a ~= b` is *defined* as `not (a == b)`, and `==`
runs the `__eq` metamethod. So `~=` should run `__eq` and negate.

## Out of scope

- Other comparison operators. `__lt` / `__le` are already routed
  through `try_binary_metamethod`. `<=` and `>=`/`>` already work.
- Equality semantics changes (e.g. table identity vs. value equality).
  This plan is purely about routing the existing `__eq` dispatch
  through the negated form.

## Success criteria

- [ ] Two values whose `__eq` returns `true` compare as `~= false`,
      not `~= true`.
- [ ] Two values whose `__eq` returns `false` compare as `~= true`.
- [ ] `__eq` is called once per `~=` evaluation (not zero, not twice).
- [ ] Lua 5.3 §3.4.4 raw-equality short-circuit still applies: for
      values that compare equal as primitives (e.g. two equal numbers,
      `nil == nil`), `__eq` is not consulted and `~=` is `false`.
- [ ] Unit tests in `test/lua/vm/equality_metamethod_test.exs` (or
      whatever file already pins `__eq` for `:equal`) covering the
      `~=` path.
- [ ] `mix test` passes; no regressions.

## Implementation notes

The fix is local to `lib/lua/vm/executor.ex`. Today:

```elixir
defp do_execute([{:not_equal, dest, a, b} | rest], regs, ...) do
  result = not lua_equal(elem(regs, a), elem(regs, b))
  ...
end
```

Should be:

```elixir
defp do_execute([{:not_equal, dest, a, b} | rest], regs, ...) do
  val_a = elem(regs, a)
  val_b = elem(regs, b)
  {result, new_state} =
    try_equality_metamethod(val_a, val_b, state, fn -> lua_equal(val_a, val_b) end)
  result = not result
  ...
end
```

`try_equality_metamethod/4` already exists (used by `:equal` at
line 920) and handles the §3.4.4 short-circuit (only consults `__eq`
when the raw values are not primitively equal and both have the same
type). Reuse it.

Repro confirmed on main on 2026-05-07:

```lua
local mt = { __eq = function() return true end }
local a = setmetatable({}, mt)
local b = setmetatable({}, mt)
assert(a == b)             -- true (correct, calls __eq)
assert((a ~= b) == false)  -- fails: a ~= b is true (bypasses __eq)
```

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- `try_equality_metamethod` may have been written with the assumption
  that it's only called in the `:equal` opcode (e.g. it might not
  thread state correctly if called from a context that doesn't expect
  state changes). Double-check the signature and fall-through behavior
  before reusing.
- The `__eq` metamethod can only be set via `setmetatable`, so this
  fix can't surface in code that doesn't touch metatables. Low blast
  radius outside the suite tests.

## Background

Discovered in A8a's PR Discoveries section as follow-up #3:
"`~=` opcode bypasses `__eq` metamethod dispatch (separate plan)."
Re-verified on main on 2026-05-07: the repro above still fails.
