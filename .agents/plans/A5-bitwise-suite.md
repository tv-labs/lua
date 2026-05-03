---
id: A5
title: Fix bitwise.lua failing assertion
issue: null
pr: null
branch: fix/bitwise-suite
base: main
status: blocked
direction: A
unlocks:
  - bitwise.lua
---

## Goal

Make `bitwise.lua` pass the official Lua 5.3 suite. Currently fails with
`Assertion Failed: assertion failed!` (no line info, indicating an early
assertion).

## Out of scope

- Architectural bitwise changes (covered in A0).
- Anything not directly tied to a failing assertion in `bitwise.lua`.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] Each fixed assertion has a corresponding unit test in
      `test/lua/vm/bitwise_test.exs`.
- [ ] `bitwise.lua` passes end-to-end.

## Implementation notes

This plan is `blocked` until A0 (integer overflow wrapping) ships. A0 may
fix this entirely; if so, this plan can be closed without doing additional
work.

Triage workflow once A0 is merged:

1. Re-run `bitwise.lua` to confirm what (if any) assertions still fail.
2. If still failing, load the `triage-suite-failure` skill and follow the
   workflow:
   - Find the failing line via line-print.
   - Reduce to a unit test.
   - Classify (likely stdlib edge case in `Bitwise` module wrapping).
   - Fix, verify, ship.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/bitwise_test.exs
```

## Risks

- May reveal multiple distinct issues. If so, split into A5a, A5b, etc.

## Discoveries

(populated during implementation)
