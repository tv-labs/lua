---
id: A22a
title: "Triage gc.lua — narrow skip to the collectgarbage no-op region"
issue: 260
pr: 287
branch: fix/gc-vm-errors
base: main
status: merged
direction: A
unlocks:
  - gc.lua
---

## Goal

Narrow `gc.lua`'s whole-file skip to the region that depends on a real
garbage collector, so the file's early allocation smoke tests run and
report conformance.

## Out of scope

- Implementing a real garbage collector (step/stop/restart pacing,
  `count` shrinkage, weak tables, `__gc` finalizers). That is a large
  feature, deferred well past 1.0.
- `attrib.lua` — permanently deferred (filesystem/package I/O), tracked
  under the parent cluster.

## Success criteria

- [ ] `gc.lua` is no longer a whole-file `:all` skip; it runs with a
      narrowed range and passes.
- [ ] A regression test pins the `collectgarbage` stub behaviour and
      documents the PUC-Lua divergences:
      `test/lua/vm/stdlib/collectgarbage_test.exs`.
- [ ] `mix test` passes.
- [ ] `mix test test/lua53_suite_test.exs --only lua53` passes.

## Implementation notes

Parent cluster: A22 (issue #260). The parent hypothesised a leaked
Elixir `MatchError` in the executor; that no longer reproduces —
intervening VM work resolved it. The current first failure in `gc.lua`
is a Lua-level assertion, not a leaked match.

Root cause: `collectgarbage` is a no-op stub
(`lib/lua/vm/stdlib.ex`). `isrunning` always returns `true`,
`count` returns `0.0`, and every other mode returns `0`. The first
failing assertion is `gc.lua:168` (`assert(not collectgarbage("isrunning"))`)
reached via `dosteps(0)` at `gc.lua:186`, because the stub cannot honour
`collectgarbage("stop")`.

From the `dosteps` helper (line 167) onward the file is pervasively
GC-dependent: step pacing returning a boolean cycle flag, `gcinfo()`
shrinking after a collection, weak tables, `__gc` finalizers, threads,
and emergency collections. Lines 1–165 (basic allocation) and the
trailing `print('OK')` do not depend on a real collector.

Decision: defer (triage skill §6.C). Narrow the `gc.lua` skip from
`:all` to `167..622` with a precise reason and issue #260, and leave a
regression test documenting the stub.

The long string `[[ ... ]]` at lines 125–134 is fully inside the
passing prefix, so the range boundary at 167 does not split it. Nothing
declared inside 167..622 is referenced after line 622.

### Files

- `test/lua53_skips.exs` — narrow `gc.lua` range.
- `test/lua/vm/stdlib/collectgarbage_test.exs` — regression test.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua53_suite_test.exs --only lua53
```

`gc.lua` flips from `(pending initial triage)` (whole-file skip) to
`(456 lines skipped, 1 ranges)` and passes.

## Risks

- The narrowed prefix passes only because the stub is a permissive
  no-op; if a real collector lands it must satisfy the expectations the
  regression test enumerates, and the skip range will shrink.

## Discoveries

- The parent plan's `MatchError` hypothesis for `gc.lua` is stale; the
  current failure mode is a Lua-level assertion driven by the
  `collectgarbage` no-op stub.
