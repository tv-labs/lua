---
id: A9
title: Fix pm.lua pattern-matching assertion
issue: 170
pr: null
branch: fix/pm-suite
base: main
status: ready
direction: A
unlocks:
  - pm.lua
---

## Goal

Make `pm.lua` (the pattern-matching test file) pass. Current failure is a
generic `assertion failed` — needs triage.

## Out of scope

- Reworking the pattern engine (Phase 13 implemented it).
- Adding new pattern features.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] Each fixed assertion has a unit test in
      `test/lua/vm/string_test.exs` or `test/lua/vm/pattern_test.exs`.
- [ ] `pm.lua` passes end-to-end.

## Implementation notes

Use `triage-suite-failure` workflow:

1. Find the failing assertion line via instrumentation.
2. Reduce to a 5–10 line repro using `string.find`, `string.match`,
   `string.gmatch`, or `string.gsub`.
3. Compare against PUC-Lua: install `lua5.3` locally, run the same
   pattern, verify the expected result.
4. Find the bug in `lib/lua/vm/stdlib/pattern.ex`. Likely areas:
   - `%b()` balanced-match.
   - `%f[set]` frontier pattern.
   - `^` anchoring vs character class.
   - Captures with empty matches.
   - `%0` (whole match) vs `%1`–`%9` (numbered captures).

May produce multiple sub-plans (A9a, A9b) if there are distinct issues.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/string_test.exs
```

## Risks

- Pattern matching has many corner cases; a fix in one path may regress
  another. Keep existing pattern tests as guardrails.
- Lua patterns are NOT regexes. Don't accidentally introduce regex
  semantics (e.g. greedy quantifiers behave differently).

## Discoveries

(populated during implementation)
