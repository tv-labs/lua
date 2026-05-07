---
id: A8
title: Fix events.lua metamethod assertion
issue: 169
pr: null
branch: fix/events-suite
base: main
status: in-progress
direction: A
unlocks:
  - events.lua
---

## Goal

Make `events.lua` (the metatable/metamethod test file) pass. Current
failure is a generic `assertion failed` — needs triage.

## Out of scope

- Adding new metamethods (the suite tests existing ones).
- Reworking the metamethod dispatch architecture (Phase 12 settled this).

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] Each fixed assertion has a unit test in
      `test/lua/vm/metatable_test.exs` or a new
      `test/lua/vm/events_*_test.exs`.
- [ ] `events.lua` passes end-to-end.

## Implementation notes

Use `triage-suite-failure` workflow:

1. Find the failing assertion line via instrumentation.
2. Reduce to a 5–20 line repro.
3. Likely areas (in order of probability):
   - `__index` chain when the chain has 3+ levels.
   - `__newindex` invocation rules (only fires on absent keys).
   - Comparison metamethods (`__eq`, `__lt`, `__le`) — `__le` falling
     back to `not __lt(b, a)` is a known subtle area.
   - `__call` with self argument.
4. Fix the specific issue, add unit test, ship.

May produce multiple smaller PRs (A8a, A8b) if multiple distinct issues
surface.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/metatable_test.exs
```

## Risks

- Metamethod regression risk is high — comprehensive existing tests in
  `metatable_test.exs` must still pass.
- Lua 5.3 metamethod rules are intricate; consult §2.4 of the reference
  manual when in doubt.

## Discoveries

### Triage outcome: blocked on `_ENV` semantics, not metamethods

Triage of `events.lua` (per `triage-suite-failure` skill) located the
first failing assertion at line 15:

```lua
assert(X == 30 and _G.X == 20)
```

Reduced to a 5-line repro:

```lua
X = 20
_ENV = setmetatable({}, {__index=_G})
X = X + 10
-- expected: _G.X == 20 (write went to new _ENV); actual: write goes to _G
```

Investigation showed the failure is **not** a metamethod bug. It is a
gap in Lua 5.3 `_ENV` semantics:

- Globals live in a flat `state.globals` Elixir map
  (`lib/lua/vm/state.ex:8`), not in any Lua table.
- The compiler emits dedicated `:get_global` / `:set_global` opcodes
  that hit `state.globals` directly
  (`lib/lua/vm/executor.ex:264-278`), bypassing any user-set `_ENV`.
- `_G` is a metatable proxy whose `__index`/`__newindex` route to
  `state.globals` (`lib/lua/vm/stdlib.ex:67-115`). Its `data` map is
  empty, which is why `rawget(_G, "X")` returns `nil` even after
  `X = 20`.
- `_ENV` is a one-time alias of `_G` set at stdlib install
  (`lib/lua/vm/stdlib.ex:105-106`). Reassigning it has no effect on
  subsequent global access.

Because `events.lua` swaps `_ENV` on line 10 before any metamethod
tests run, the entire file is gated on this. There is no smaller
metamethod-only fix that would let events.lua pass.

### Follow-up

- New plan: `.agents/plans/A16-env-semantics.md` (status: ready) —
  implements proper `_ENV` semantics across `scope.ex`, `codegen.ex`,
  `executor.ex`, and `stdlib.ex`. Unlocks events.lua plus attrib.lua,
  locals.lua, errors.lua (also `_ENV`-dependent).
- Regression tests documenting the gap:
  `test/lua/vm/env_semantics_test.exs` (currently `@tag :skip`,
  un-skipped by A16).

A8 is set to **blocked** on A16. Once A16 lands, A8 can be reopened to
triage any remaining metamethod-specific failures in events.lua (if
any surface beyond the `_ENV` block).
