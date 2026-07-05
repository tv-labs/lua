---
id: A49
title: "Docs sync for 1.0.0: roadmap, changelog, guides, README true-up"
issue: null
pr: 381
branch: docs/release-docs-sync
base: main
status: review
direction: A
---

## Goal

Bring every user-facing doc and status artifact in line with reality
(20/29 official suite files passing, `rc.3` → `1.0.0` pending) so the
`1.0.0` cut is documentation-clean.

## Out of scope

- Any source behavior change, except the test-warning fix (item 8) and
  the doctest wiring (item 9).
- API changes — a sibling PR handles those. Unreleased CHANGELOG entries
  are kept in clearly-labeled subsections to minimize the merge conflict.
- The `1.0.0` version bump and release CHANGELOG section (release-cut PR).
- Blog post, website.

## Success criteria

- [ ] `ROADMAP.md` Status reflects 20/29, dated 2026-07-05; suite gate marked MET.
- [ ] `CHANGELOG.md` Unreleased documents #376 and #379; suite-exclusion
      doc entry lists the 9 exclusions by category; heading/link-ref
      mismatch fixed; "Upgrading from 0.x" migration section added.
- [ ] `guides/sandboxing.md` CPU section leads with `:max_instructions`.
- [ ] `README.md`: `utf8` in coverage list; host-filesystem claim qualified;
      `import Lua` shown in the Tour.
- [ ] `lib/lua.ex` `load_file!` links the Lua 5.3 manual.
- [ ] `lib/lua/runtime_exception.ex` moduledoc uses `<eval>` for default source.
- [ ] `guides/mix_tasks.md` sample output + skips-file reference updated.
- [ ] `test/lua_test.exs` encode-nil test no longer emits a type warning.
- [ ] `doctest Lua.Parser.Error` wired into a test file and passing.
- [ ] `.agents/plans/B17-*.md` and `A33-*.md` statuses reconciled with reality.
- [ ] `mix format`, `mix compile --warnings-as-errors`, `mix test`,
      `mix docs --warnings-as-errors` all clean.

## Implementation notes

Verify each item still needs fixing before touching it — PR #378 shifted
line numbers and fixed some issues already.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
```

## Risks

- Concurrent API-PR CHANGELOG conflict — kept small via labeled subsections.

## What changed

PR #381. Files touched: `ROADMAP.md`, `CHANGELOG.md`, `README.md`,
`guides/sandboxing.md`, `guides/mix_tasks.md`, `lib/lua.ex`,
`lib/lua/runtime_exception.ex`, `tasks/lua.suite.ex`,
`test/lua_test.exs`, `test/lua/parser/error_unit_test.exs`, and the
`B17` / `A33` plan files.

Discoveries:
- The `mix lua.suite` task moduledoc (`tasks/lua.suite.ex`) carried the
  same stale `@ready_tests` reference and sample output as the guide, so
  it was fixed alongside item 7 — same doc-only class, no behavior change.
- The canonical suite count (20/29, skip ranges applied) differs from the
  raw `mix lua.suite` count (9/17/3, no skips); the guide now distinguishes
  them explicitly.
