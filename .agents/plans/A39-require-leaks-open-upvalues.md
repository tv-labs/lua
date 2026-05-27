---
id: A39
title: require() leaks inner module's open_upvalues into outer caller
issue: 244
pr: null
branch: fix/require-leaks-open-upvalues
base: main
status: in-progress
direction: A
unlocks:
  - luassert.assertions
  - luassert.array
  - luassert.spy
---

## Goal

Fix `Lua.VM.Executor.execute/5` so that nested executions (most importantly
`require`) no longer leak the inner module's `state.open_upvalues` map
back to the outer caller. This unblocks loading real-world Lua libraries
that mix nested `require` chains with many top-level `local function`
definitions (luassert, busted, etc.).

## Out of scope

- Refactoring the upvalue / closure model. The bug is one missed
  save/restore, not a design flaw.
- Adding a "close all open upvalues at chunk end" sweep. Not needed once
  save/restore is in place.
- The full `package.searchers` mechanism. Unrelated.
- Bytecode-encoder support for vararg chunks (chunks falling back to the
  interpreter is what surfaces this bug, but the interpreter path should
  be correct on its own).
- Coordinating the `tv-labs/platform/sidecar` Lua bump. Mentioned in the
  issue but a downstream concern.

## Success criteria

- [ ] `mix test` passes with no regressions vs. baseline (1772 tests).
- [ ] New unit regression in `test/lua/vm/require_open_upvalue_test.exs`
      reproduces the bug with a minimal two-file pure-Lua repro and
      asserts the outer's local reads correctly.
- [ ] New integration test under `test/integration/luassert_test.exs`
      vendors a real subset of `luassert` + `say` and asserts that every
      luassert module loads successfully via `require`.
- [ ] `mix test --only lua53` suite count does not regress.

## Implementation notes

### Root cause

`Lua.VM.Executor.execute/5` at `lib/lua/vm/executor.ex:73-82` resets
`state.open_upvalues` to `%{}` at entry but never restores the caller's
`open_upvalues` on return. Every other call site that descends into a
nested execution (`call_function/3` for `:lua_closure`, `call_value/5`,
the dispatcher entry, the dispatcher's frame returns, the interpreter's
`:call` op for Lua closures) carefully saves the caller's map, resets
to `%{}`, runs the callee, and restores on return. `Executor.execute/5`
is the one outlier.

When `require` is called as a `native_func` from a Lua execution, the
inner module's `Lua.VM.execute(proto, state)` populates its own
`open_upvalues` as closures are created over the inner module's
top-level locals. When the inner returns, those entries leak back to the
outer caller. If the outer then creates a closure that captures a
top-level local at a register number that collides with one of the
inner's leftover entries, the outer's closure **reuses the inner's
stale cell**, aliasing the outer's local to whatever value the inner had
at that register.

For `luassert.assertions`, the outer's `assert` (reg 0) ends up aliased
to the inner `luassert.assert` module's `s` (reg 0, the `say` module).
At line 307, `assert:register(...)` reads `assert` through the stale
upvalue cell and sees `say`, not the obj table — hence
"attempt to call a nil value (method 'register' on local 'assert')".

### Fix

In `lib/lua/vm/executor.ex` `execute/5`, snapshot `state.open_upvalues`
before resetting and restore it on the way out:

```elixir
def execute(instructions, registers, upvalues, proto, state) do
  prev = Process.get(@position_key, @unset)
  saved_open_upvalues = state.open_upvalues

  try do
    state = %{state | open_upvalues: %{}}

    {results, regs, state} =
      do_execute(instructions, registers, upvalues, proto, state, [], [], 0)

    {results, regs, %{state | open_upvalues: saved_open_upvalues}}
  after
    restore_position(prev)
  end
end
```

Two callers of `Executor.execute/5`:

- `Lua.VM.execute/2` (`lib/lua/vm.ex:26`) — used by
  `parse_and_execute_module` (the bug path) and by top-level
  `Lua.eval!`. Save/restore is correct in both cases.
- `Lua.do_call_function/3` for `:lua_closure` (`lib/lua.ex:717`) —
  called from the public `Lua.call_function/3`. Save/restore makes the
  public API safer: callers don't lose `open_upvalues` across
  `call_function` invocations.

### Tests

Two layers:

1. **Unit regression** (`test/lua/vm/require_open_upvalue_test.exs`).
   Minimal two-file pure-Lua repro: inner module declares a top-level
   local at reg 0 and creates a closure capturing it; outer module
   requires inner, then declares its own top-level local at reg 0 and
   creates a closure capturing it. Assert the outer's local reads the
   correct value, not the inner's leaked value.

2. **Luassert integration** (`test/integration/luassert/` +
   `test/integration/luassert_test.exs`). Vendor the luassert v1.9.0 +
   say v1.4.1 source files under `test/integration/luassert/lua/`.
   Assert that `require('luassert')` and every interior luassert module
   load without error. Behavioural assertions (e.g.
   `assert.are.equal(1, 1)` returns truthy) are deferred to a follow-up
   plan; this PR proves the *loading* pipeline works.

Vendor with upstream LICENSE files. Document the pin and source in
`test/integration/luassert/README.md`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/require_open_upvalue_test.exs
mix test test/integration/luassert_test.exs
mix test --only lua53
```

Suite count before this plan: 1772 passing, 0 failing, 30 skipped.

## Risks

- **The fix changes observable state after a top-level `Lua.eval!`.**
  Specifically, `state.open_upvalues` after an eval will now be the
  pre-eval value (typically `%{}`) instead of whatever the chunk left
  open. Mitigated by the full test run; `open_upvalues` is internal
  state with no documented public consumers.
- **`Lua.call_function/3` (public API) starts preserving the caller's
  `open_upvalues`.** This is a behavior change, but the previous
  behavior was the bug. Documented in `CHANGELOG.md`.
- **Vendored luassert may shift if upstream changes.** Pinned to a
  specific tag; future updates are explicit PRs.
