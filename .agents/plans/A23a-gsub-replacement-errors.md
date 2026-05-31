---
id: A23a
title: "string.gsub validates replacement string and replacement value"
issue: 261
pr: null
branch: fix/metamethod-control-flow
base: main
status: in-progress
direction: A
unlocks:
  - pm.lua
---

## Goal

Make `string.gsub` raise the Lua 5.3 errors for an invalid replacement
string or replacement value, so the official `pm.lua` suite advances
past its `checkerror` block (lines 233-238).

## Out of scope

- Pattern-engine backreferences `%0` / `%1` to an unclosed or absent
  capture (pm.lua 236-237) — needs capture-level validation in the
  matcher.
- A pattern recursion / complexity limit so huge `.?` patterns raise
  "pattern too complex" (pm.lua 240-263).
- `gsub` with captures replacing only the capture rather than the whole
  match, plus gmatch position captures, `%f` frontier sets,
  malformed-pattern error messages, and embedded-`\0` patterns
  (pm.lua 277-371).
- The other A23 cluster files (events.lua, errors.lua, closure.lua,
  goto.lua).

## Success criteria

- [ ] `string.gsub` raises `invalid capture index %N in replacement string`
      for an out-of-range `%N` in the replacement string.
- [ ] `string.gsub` raises `invalid use of '%' in replacement string`
      for a `%` followed by a non-digit, non-`%` char.
- [ ] `string.gsub` raises `invalid replacement value (a TYPE)` when a
      table/function replacement yields a non-string/number value.
- [ ] `%%` still renders a literal `%`, and the existing no-capture `%1`
      == `%0` quirk is preserved.
- [ ] Regression tests in `test/lua/vm/string_test.exs`.
- [ ] `pm.lua` advances from a whole-file `:all` skip to a narrowed skip;
      `mix test test/lua53_suite_test.exs --only lua53` stays green.
- [ ] `mix test` passes.

## Implementation notes

- `lib/lua/vm/stdlib/pattern.ex`:
  - `apply_replacement/4` function-result branch: raise on a non
    string/number/false/nil result.
  - `replace_captures/3`: error on out-of-range `%N`, only allow `%%`
    as the literal escape, error on any other `%`-escape.
- Errors raised as `Lua.VM.RuntimeError` (value: message) so `pcall`
  surfaces the message string for `string.find`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/string_test.exs
mix test
mix test test/lua53_suite_test.exs --only lua53
```

## Risks

- Tightening replacement-string validation could reject inputs we
  previously silently accepted (e.g. `%x` used to drop the `%`). This
  matches PUC-Lua, but any caller relying on the lax behaviour would now
  see an error. Mitigated by the `%%`-literal regression test.

## Discoveries

Parent A23 grouped pm.lua under "pattern engine work". Triage of the
`:all`-skipped pm.lua found four independent failure clusters, only the
first of which is shipped here:

1. Replacement-string / replacement-value errors (233-238) — FIXED here.
2. Pattern backreferences `%0`/`%1` to an unclosed/absent capture
   (236-237) — needs capture-level bounds checking in the matcher.
3. No pattern recursion/complexity limit (240-263) — huge `.?` patterns
   never raise "pattern too complex".
4. `gsub` with captures replaces only the capture, not the whole match
   (277); gmatch position captures, `%f` frontier sets, malformed-pattern
   error text, and embedded-`\0` patterns also still differ (277-371).

Clusters 2-4 are narrowed in `test/lua53_skips.exs` with precise reasons
and tracked under #261 for follow-up sub-plans.
