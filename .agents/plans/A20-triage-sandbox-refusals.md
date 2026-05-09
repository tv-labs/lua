---
id: A20
title: Triage cluster — sandbox-refusal suite files
issue: null
pr: null
branch: triage/sandbox-refusals
base: main
status: in-progress
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

- [ ] Each of `main.lua`, `verybig.lua`, `files.lua`, `attrib.lua` has
      a documented decision.
- [ ] For files marked "skip permanently": `test/lua53_suite_test.exs`
      gains a comment explaining *why* alongside the `@tag :skip`, and
      this is reflected in CHANGELOG / README's "supported coverage"
      section.
- [ ] For files marked "fix-now": a follow-up plan (`A20a`, `A20b`, …)
      is written under `.agents/plans/` describing the suite-runner
      config or stub strategy, with its own success criteria.
- [ ] No regression in other suite files. `mix test --include skip`
      shows the same total pass count or higher.

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

(populated during triage)
