---
id: A19
title: Native function raises (assert, error, stdlib type checks) carry line info
issue: null
pr: null
branch: fix/error-line-info-native-funcs
base: main
status: blocked
direction: A
unlocks:
  - line numbers on `assert(false)` and `error("msg")` failures
  - line numbers on bad-argument errors from `table.*`, `string.*`, `math.*`, etc.
---

## Goal

After A18 lands, every error from a Lua **opcode** carries source/line
info, but errors from **native functions** (`assert`, `error`, and the
~100 stdlib functions in `lib/lua/vm/stdlib*.ex`) still raise without
context. This plan threads the calling line through the native-call
boundary so those raises can include it too.

## Out of scope

- Changing the surface of native functions exposed to users via
  `Lua.set!/3`. Custom Elixir callbacks remain `fn args, state -> ... end`.
  We only thread context for the **internal** stdlib path.
- Anything A18 covered (opcode-level raises).

## Success criteria

- [ ] `mix test` still passes.
- [ ] New test: `assert(false, "boom")` from a Lua script raises with
      `:line` populated to the assert call line, not nil.
- [ ] New test: `error("boom")` from Lua raises with `:line` populated.
- [ ] New test: `string.upper(nil)` (or another native bad-arg case)
      raises a TypeError with `:line` populated.
- [ ] No measurable perf regression on the bench harness vs A18 baseline.

## Implementation notes

Two viable mechanisms, pick the one that's least invasive:

### (1) Push line into State around native calls

In `executor.ex`'s native-func dispatch (the `{:native_func, fun}`
clause of `call_value/5`), set `state.current_line` and `state.current_source`
before invoking the closure, restore on return. Stdlib raises read from
state instead of arguments. Changes the public Elixir API of native
funcs minimally (state already has plenty of fields).

### (2) Pass ctx as extra arg

Change the native-func calling convention from `fn args, state -> ... end`
to `fn args, state, ctx -> ... end`. Backward-compat-breaking for any
external Lua-on-Elixir code that registers native funcs. Probably a no-go
for 1.0.

Recommend (1) — internal-only, no public API change.

### Files

- `lib/lua/vm/state.ex` — add `current_line`, `current_source` fields.
- `lib/lua/vm/executor.ex` — set/restore in native-call dispatch
  (`call_value({:native_func, fun}, ...)` and `call_function/3`).
- `lib/lua/vm/{assertion_error,runtime_error,type_error}.ex` — already
  carry the fields, no changes.
- `lib/lua/vm/stdlib*.ex` — every `raise` site reads context from state.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- State allocation churn. Setting two fields per native call is cheap
  but not free; measure on the benchee harness.
- Reentrancy. If a native func calls back into Lua (e.g. `pcall`), the
  inner call must save/restore the outer line. Use a stack discipline
  (push before call, pop on return).

## Blocked on

- A18 lands (this plan reuses A18's wrapper changes and assumes
  `Lua.RuntimeException` already preserves structured fields).
