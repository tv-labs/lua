---
id: A22
title: Triage cluster — gc.lua and attrib.lua VM-level errors
issue: null
pr: null
branch: triage/vm-runtime-errors
base: main
status: blocked
direction: A
unlocks:
  - gc.lua
  - attrib.lua
---

## Blocked on

- A19 — stdlib raises need line/source for actionable triage.

## Goal

Diagnose `gc.lua` (raises "no match of right hand side value", which
is an Elixir `MatchError` leaking through the executor — almost
certainly a real VM bug) and `attrib.lua` (raises a generic Runtime
Error). Both are likely small bugs in less-traveled VM paths.

These two are split into their own cluster because the failure modes
are unique: one is a leaked Elixir `MatchError` (a defensive-coding
gap, not a Lua-level error), and the other is an `attrib`-specific
edge case probably tied to local variable attributes (`<const>`,
`<close>`).

## Out of scope

- Implementing fixes inline. This plan only triages.
- General VM hardening — only the two specific failure points
  surfaced here.

## Success criteria

- [ ] `gc.lua` has a diagnosis: what value pattern fails to match,
      where, and a repro.
- [ ] `attrib.lua` has a diagnosis: which attribute syntax or
      semantics is broken.
- [ ] Each file has a follow-up fix plan (`A22a`, `A22b`) or a
      `@tag :skip` with a documented reason.
- [ ] If `gc.lua`'s `MatchError` is reproducible from a smaller
      input, a regression test is added under
      `test/lua/vm/executor_test.exs` (skipped/pending if not yet
      fixed).

## Implementation notes

For both files, follow `triage-suite-failure`:

1. Repro standalone in `iex`.
2. Read the stack trace into the VM. Find the `case` or `=` site
   that fails to match; capture the actual value vs the expected
   pattern.
3. Reduce to a 5-20 line repro test.
4. Decide fix-now vs defer.

### Hypotheses

- `gc.lua` — likely a metatable, weak table, or `__gc` semantics path
  the VM doesn't handle, falling through to a `case` clause without a
  catchall. The `MatchError` is the symptom; the cause is probably a
  missing case in pattern dispatch. Note: A10a (closure weak tables)
  is `deferred`, suggesting weak-ref semantics are a known gap.
- `attrib.lua` — Lua 5.4 introduced `local x <const>` and `<close>`
  attributes, but our parser/compiler may have inherited some
  handling that mis-fires. Or, more likely, it's exercising a 5.3
  semantic we haven't pinned down.

### Files

- `lib/lua/vm/executor.ex` — likely site of the `MatchError` for
  `gc.lua`.
- `lib/lua/parser/*.ex` — possibly relevant for `attrib.lua` if it's
  a parse-level issue.
- `.agents/plans/A22<letter>-*.md` — fix follow-ups.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test --include skip
```

## Risks

- `gc.lua` may exercise weak-table / finalizer semantics that aren't
  worth implementing for 1.0. Mitigation: defer with an explicit
  `@tag :skip` and document in CHANGELOG.
- `attrib.lua` may need parser work that's higher-risk than expected.
  Triage should be honest about scope before committing.

## Discoveries

(populated during triage)
