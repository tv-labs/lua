---
id: A8
title: Fix events.lua metamethod assertion
issue: null
pr: null
branch: fix/events-suite
base: main
status: ready
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

(populated during implementation)
