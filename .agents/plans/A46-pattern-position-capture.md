---
id: A46
title: "Position capture () in string pattern matching"
issue: 257
pr: null
branch: feat/pattern-position-capture
base: main
status: in-progress
direction: A
unlocks:
  - pm.lua
---

## Goal

Land position capture `()` in the pattern engine with regression coverage
across `string.find`/`match`/`gmatch`/`gsub`, and advance `pm.lua`'s skip
from `:all` to the next genuine failure point.

## Out of scope

Issue #257 is a multi-feature pattern-engine epic. This PR ships only
position capture. The following stay deferred to their own follow-up plans
(noted in ## Discoveries with the precise next failure points):

- `%f[set]` frontier pattern.
- `%b xy` balanced match (e.g. `%b()`).
- `%1`..`%9` backreferences in pattern *bodies* and the matching
  `string.gsub` "invalid capture index" / "invalid replacement value"
  error validation (pm.lua:233-238).
- The C-stack / "pattern too complex" depth-limit and big-string tests
  (pm.lua:240-262).
- `string.gsub` table/string replacement fall-back-to-whole-match
  semantics when the first capture is a position capture (a pre-existing
  table-replacement bug, surfaced via `().`; see ## Discoveries).

## Success criteria

- [ ] `()` captures the current 1-based byte position as an integer in
      `find`, `match`, `gmatch`, and `gsub`.
- [ ] New regression tests in `test/lua/vm/stdlib/pattern_test.exs` pass.
- [ ] `pm.lua` skip narrows from `lines: :all` to a precise range with an
      issue reference, and the lua53 suite is green.
- [ ] `mix test` passes.
- [ ] `mix test test/lua53_suite_test.exs --only lua53` passes.

## Implementation notes

- `lib/lua/vm/stdlib/pattern.ex` already compiles `()` to
  `:position_capture` and emits `{:done, pos + 1}`; the mechanic is in
  place. This plan verifies it end-to-end across all four entry points
  and pins it with regression tests, then advances the skip.
- The first genuine post-position-capture failure in `pm.lua` is line 233
  (`string.gsub` "invalid replacement value"/"invalid capture index"
  error checks) — out of scope. The remaining deferred features are
  interleaved through lines 233-374, so the smallest contiguous skip that
  lands green is `233..374`.

## Verification

- `mix format`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix test test/lua53_suite_test.exs --only lua53`

## Risks

- Position captures interact with other capture kinds (nested, mixed with
  substring captures). Tests cover mixed `()(%w+)()` ordering to guard the
  opening-order capture model.

## Discoveries

- `string.gsub("alo alo", "().", {'x','yy','zzz'})` returns `"xyyzzz4567"`
  instead of the PUC-Lua `"xyyzzz alo"`. The table-replacement path in
  `lib/lua/vm/stdlib/string.ex` keys the table by the first capture and
  falls back to that same key when the lookup misses; Lua semantics
  require the fall-back to be the **whole match** substring. Surfaced via
  position captures because the first capture there is an integer. This is
  a pre-existing table/string-replacement bug, not a position-capture
  defect — deferred to a follow-up plan.
- pm.lua next failure points after position capture: line 233 (gsub error
  validation), line 250 ("pattern too complex" depth limit), then `%b`,
  `%f`, and backreference assertions through line 374.
