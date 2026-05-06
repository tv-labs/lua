---
id: A9
title: Fix pm.lua pattern-matching assertion
issue: 170
pr: 188
branch: fix/pm-suite
base: main
status: review
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

- [x] `mix test` passes (≥ 1273, no regressions)
- [x] Each fixed assertion has a unit test in
      `test/lua/vm/string_test.exs` or `test/lua/vm/lexer_test.exs`.
- [ ] `pm.lua` passes end-to-end. **Narrowed.** The triage on this plan
      uncovered five distinct, layered bugs blocking pm.lua. The first
      four are fixed in this PR (see Discoveries) and now pm.lua reaches
      line 112. The fifth — an executor crash on `string.char(range(0, 255))`
      caused by multi-return tail-call register expansion — is a separate
      concern far from the pattern engine and is split into a follow-up
      plan A9a (`fix/pm-suite-executor`).

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

Triage walked the file in order, fixing each blocker as it surfaced. Each
fix has a unit test attached; pm.lua acts as the integration regression.

1. **Lexer never decoded numeric escapes.** `"a\0o"` parsed as four bytes
   (`a`, `\`, `0`, `o`) instead of three. Affected pm.lua from line 21
   onward — almost every assertion uses `\0`, `\200`, `\xff`, etc.
   - Added `\ddd`, `\xXX`, `\u{...}` handling to `lib/lua/lexer.ex`,
     including UTF-8 encoding for codepoints up to 0x7FFFFFFF.
   - Updated the existing "invalid escape" test, which incorrectly
     asserted that `\1` and `\x` should pass through verbatim. Per the
     Lua 5.3 reference manual §3.1, `\ddd` is a valid decimal escape
     and a bare `\x` is a malformed escape (parse-time error).

2. **Pattern engine missing `%g`, `%G`, `%x`, `%X` character classes.**
   pm.lua line 51 (`%g%g%g+`) was the first user; many later lines use
   `%x` for hex-digit matching.

3. **`string.gsub` crashed when an end-anchored zero-width pattern
   matched at the end of the subject.** The `pos > len` cleanup branch
   passed a negative length to `:erlang.binary_part/3`. Fixed by
   clamping the remainder length to zero.

4. **`string.sub(s, i, j)` returned the wrong value when `j == 0`.**
   The `normalize_index/2` helper collapsed both `0` and `1` to the
   same 0-based offset, so the empty `[1,0]` range became a one-char
   match. Replaced with PUC-Lua's `posrelat`-then-clamp algorithm.

5. **Position captures `()` were treated as zero-width string captures
   instead of numeric byte positions.** The `f1` helper in pm.lua (and
   anything using `()` for position tracking) returned the wrong types.
   Compiler now emits `:position_capture` for `()` and the matcher
   records `pos + 1` as a number.

6. **Out of scope (split to A9a):** pm.lua line 112's
   `string.char(range(0, 255))` triggers an executor crash —
   `:erlang.setelement/3` is called with an index past the end of the
   register tuple when a tail-recursive multi-return funnels 256 values
   into a fixed-size register file. This is a pure executor bug
   unrelated to patterns; addressing it requires register growth in
   `Lua.VM.Executor.do_frame_return/6` and is tracked in
   `.agents/plans/A9a-pm-suite-executor.md`.

## What changed

PR: #188

Files touched:

- `lib/lua/lexer.ex` — decimal/hex/unicode numeric escapes, plus
  Bitwise import for the UTF-8 encoder.
- `lib/lua/vm/stdlib/pattern.ex` — `%g`/`%G`/`%x`/`%X` classes;
  position-capture compile + match; gsub clamp on end-overflow.
- `lib/lua/vm/stdlib/string.ex` — PUC-Lua `posrelat`-then-clamp
  semantics for `string.sub`.
- `test/lua/lexer_test.exs` — new tests for `\ddd`, `\xXX`,
  `\u{...}`, malformed `\x`, plus relaxed "unknown escape"
  passthrough; the old "invalid escape" test (which contradicted the
  Lua 5.3 reference) was replaced.
- `test/lua/vm/string_test.exs` — regression tests for `string.sub`
  edge cases, `%g`/`%x` classes, position captures, NUL-in-pattern,
  and the gsub end-overflow.

Suite delta: 1327 → 1342 unit tests (+15 regressions). lua53 official
suite: 4/24 ready (unchanged). pm.lua remains in `@skipped_tests` —
moving it to `@ready_tests` is gated on A9a.

Follow-up: [`.agents/plans/A9a-pm-suite-executor.md`](A9a-pm-suite-executor.md).
