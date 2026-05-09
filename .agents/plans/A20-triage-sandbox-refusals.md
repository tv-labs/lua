---
id: A20
title: Triage cluster — sandbox-refusal suite files
issue: null
pr: 216
branch: triage/sandbox-refusals
base: main
status: review
direction: A
unlocks:
  - main.lua
  - verybig.lua
  - files.lua
  - attrib.lua
---

## Goal

Decide, per file, whether the sandbox-refusal failure is a permanent
non-goal (skip with explanatory tag) or whether the suite runner should
be configured to provide stub `os.execute`, `os.tmpname`, `os.getenv`
behavior so the file completes. Produce per-file follow-up plans or
skip annotations.

These four suite files all fail because they call `os.execute()` /
`os.tmpname()` / `os.getenv(_)`, which our sandbox refuses by raising.
The decision is policy, not engineering: do we *want* a hosted Lua to
pretend to have these, or are they explicit non-goals?

## Out of scope

- Implementing `os.execute` etc. for general consumption (we will not
  ship a Lua that can shell out).
- Changing the public sandbox API.
- Suite files outside this cluster.

## Success criteria

- [x] Each of `main.lua`, `verybig.lua`, `files.lua`, `attrib.lua` has
      a documented decision. All four are skip-permanently; reasons
      live in `test/lua53_suite_test.exs` `@deferred_permanent` map.
- [x] For files marked "skip permanently": `test/lua53_suite_test.exs`
      gains a comment explaining *why* alongside the `@tag :skip`, and
      this is reflected in CHANGELOG and ROADMAP "Deferred" section.
      (README does not have a "supported coverage" section; ROADMAP is
      the canonical place — see Discoveries.)
- [x] For files marked "fix-now": a follow-up plan (`A20a`, `A20b`, …)
      is written under `.agents/plans/` describing the suite-runner
      config or stub strategy, with its own success criteria.
      None needed — all four are skip-permanently.
- [x] No regression in other suite files. `mix test --include skip`
      shows the same total pass count or higher. Suite test still
      reports 29 tests, 0 failures, 24 skipped (5 ready). Full
      `mix test`: 1585 tests, 0 failures, 31 skipped (no change).

## Implementation notes

Use the `triage-suite-failure` skill for each of the four files. For
each:

1. Reproduce against a freshly-constructed `Lua` in `iex`.
2. Confirm the failure is *only* the sandbox refusal (not a deeper
   issue masked by the early raise).
3. Decide:
   - **Skip permanently** (recommended for `main`, `files`,
     `verybig`): we will not ship `os.execute` / `os.tmpname` /
     filesystem `os.*` operations. Write a clear comment.
   - **Stub for the suite** (worth considering for any case where the
     test only checks behavior, not values): the suite runner could
     provide a closed-over `os.getenv("FOO")`-returns-nil etc.
4. If "fix-now", write `A20<letter>-<slug>.md` describing the stub
   strategy.

### Files

- `test/lua53_suite_test.exs` — comment annotations on `@tag :skip`.
- `test/support/lua_test_case.ex` — only if a per-suite-file stub
  helper is needed (probably no, since this would be policy).
- `.agents/plans/A20<letter>-*.md` — fix-now follow-ups.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test --include skip
```

After the cluster: the four files are either passing (if any fix-now
sub-plan shipped) or skipped with documented reason. No regression in
the rest of the suite.

## Risks

- "Skip permanently" looks like quitting on coverage. Mitigation: the
  CHANGELOG and README should frame these as deliberate scope choices
  (this library is for sandboxed embedded Lua; shelling out is not in
  scope).
- "Stub for the suite" risks the suite passing on a fake that wouldn't
  match real behavior. If we go this route, the stub must be limited
  to the suite runner — never leaked into `Lua.new()` defaults.

## Discoveries

- The plan's premise that all four files fail with `os.execute()` /
  `os.tmpname()` / `os.getenv(_)` was correct for `main.lua`,
  `verybig.lua`, `files.lua`. `attrib.lua` is a *different* sandbox
  policy: it dies on `require"io"` because there is no `io` global to
  cache (see A4 plan Discoveries — A4 already noted this). The cluster
  framing still holds — all four exercise capabilities that conflict
  with our sandbox role — but the failure mechanism for `attrib.lua` is
  package/loader-driven, not `os.*`-driven.

- `verybig.lua` is the most interesting of the four. The first ~140
  lines are testing genuinely useful VM behaviour (RK opcodes, >64K
  constants, large-table iteration), but they live inside a generated
  Lua program that gets written to a temp file via `os.tmpname()` /
  `io.output()` and executed with `dofile()`. A future plan could stub
  these three primitives in the suite runner only (in-memory file
  handle + in-memory `dofile`) to unlock that coverage. Not in scope
  here, but worth recording: roughly 30 lines in
  `test/support/lua_test_case.ex`, scoped to suite use only.

- The plan asked for a "supported coverage" section in CHANGELOG /
  README. README has no such section and adding one would duplicate
  what's already in `ROADMAP.md`'s "Deferred (intentional, not in 1.0)"
  list. Updated ROADMAP and CHANGELOG instead; the per-file reasons
  also live inline in `test/lua53_suite_test.exs` so the rationale
  travels with the test.

- The pre-existing test file structure (single `@skipped_tests` list)
  conflated "feature not yet implemented" with "deliberate non-goal".
  Split into `@skipped_tests` (the former, still subject to future
  plans) and `@deferred_permanent` (the latter, with reasons) so future
  triage doesn't re-investigate the same four files.

## What changed

Files touched:
- `test/lua53_suite_test.exs` — split `@skipped_tests` into a two-tier
  structure: `@deferred_permanent` (a `%{file => reason}` map for the
  four sandbox-refusal files plus future deliberate non-goals) and
  `@skipped_tests` (everything else, still addressable). New describe
  block "Deferred (Intentional Non-Goals)" surfaces the per-file reason
  in the test name.
- `ROADMAP.md` — expanded the "Deferred (intentional, not in 1.0)"
  section with per-file rationale for `main.lua`, `files.lua`,
  `attrib.lua`, `verybig.lua`. Renamed the existing items into a
  follow-up "Other deferrals in this milestone" sublist.
- `CHANGELOG.md` — added an Unreleased entry under Changed describing
  the new tier and pointing readers at the suite test file and ROADMAP
  for rationale.

Suite delta: no change (5/29 ready). Coverage classification refined:
24 skipped → 4 deferred-permanent + 20 missing-feature. Same total.

Tests: 1585 passing, 0 failing, 31 skipped (no change).

PR: https://github.com/tv-labs/lua/pull/216
