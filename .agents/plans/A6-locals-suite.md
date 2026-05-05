---
id: A6
title: Fix locals.lua "attempt to call nil" at line 67
issue: 167
pr: 185
branch: fix/locals-suite
base: main
status: review
direction: A
unlocks:
  - locals.lua
---

## Goal

Make `locals.lua` pass. The current failure is at line 67 (`f(2)`) where
`f` is nil — the global `function f(a)` declaration at line 44 didn't
update the local `f` declared at line 37.

This pattern (re-defining a local function via `function name(...)` syntax)
is documented in the historical commit `796e384` (FuncDecl local
assignment). The fix may already be on main via PR #141, or it may have
regressed during the CPS refactor (#156). Investigate.

## Out of scope

- Backward goto (separate plan, deferred).
- `debug.getupvalue` semantics (separate plan if it surfaces).

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit test in `test/lua/vm/local_func_redef_test.exs`:
  ```lua
  local f
  function f(x) return x * 2 end
  return f(5)  -- expect 10
  ```
- [ ] `locals.lua` progresses past line 67 (or passes entirely).

## Implementation notes

Steps (use `triage-suite-failure` workflow):

1. Reproduce the line-67 failure as a 5–10 line standalone test.
2. Check whether `function f(...)` at scope level should update the local
   `f` or shadow it. Per Lua 5.3 spec: `function name(...) end` is sugar
   for `name = function(...) end`, so it assigns to whatever `name` is in
   scope (local if local exists, otherwise global).
3. Find where the codegen handles `Statement.FuncDecl`. Verify it resolves
   the target through scope (local → upvalue → global).
4. Fix if broken; if working, the failure is elsewhere (continue triage).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- May interact with the CPS executor's handling of upvalue cells.
- May be the same root cause as some `nextvar.lua` failure; check after fix.

## What changed

- `lib/lua/compiler/scope.ex` — added a `resolve_statement` clause for single-name `FuncDecl` that walks locals → upvalue chain → global and records the resolution under `{:func_decl_target, decl}` in `var_map`.
- `lib/lua/compiler/codegen.ex` — `gen_statement` for single-name `FuncDecl` now reads the namespaced `var_map` entry and emits `move`, `set_open_upvalue`, `set_upvalue`, or `set_global` accordingly.
- `test/lua/vm/local_func_redef_test.exs` — 4 new unit tests covering the core fix and edge cases.

Suite delta: `locals.lua` now progresses past line 67; fails at line 72 on `debug.getupvalue` (out of scope).
Tests: 1318 → 1322 (4 new tests added), 0 failures.

## Discoveries

The `resolve_function_scope` helper always overwrites `var_map[decl]` with the function-scope reference (`make_ref()`). Using a namespaced key `{:func_decl_target, decl}` sidesteps the collision cleanly without touching `resolve_function_scope`.
