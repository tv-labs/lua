---
id: A2
title: Long-string [[ ... ]] lexer handles embedded ] and level brackets [==[
issue: 163
pr: 180
branch: fix/long-string-lexer
base: main
status: merged
direction: A
unlocks:
  - literals.lua
  - main.lua
---

## Goal

Make the lexer correctly handle Lua's long-string literal syntax including:

- Embedded `]` characters that don't close the long string.
- Level brackets: `[=[ ... ]=]`, `[==[ ... ]==]`, etc.
- Long strings spanning multiple lines.

Currently both `literals.lua` and `main.lua` fail with a parser error
("Expression statement must be a function call") because the lexer
mis-tokenizes a long string and the parser sees garbage.

## Out of scope

- Long comments (`--[[ ... ]]`). They share lexer logic but have different
  rules; treat as a follow-up if they break.
- String escape sequences inside short strings (already implemented).
- Pattern-matching strings (handled in `Lua.VM.Stdlib.Pattern`).

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit tests in `test/lua/lexer_test.exs` for:
  - `[[ ]] ]]` (long string with embedded `]` — only first `]]` closes)

  Wait — that's actually NOT what Lua does. In Lua 5.3 a `[[` always
  closes at the first `]]`. The example failing in `literals.lua` is:

  ```lua
  assert('\n\"\'\\' == [[

  "'\]])
  ```

  Here the long string body is `\n"'\` (actual chars, not escapes), and
  it terminates at the first `]]`. The trailing `])` is then `]` and `)`
  — both literal text closing the assert call.

  So the lexer bug is different. Investigate: maybe it's a confusion
  between the leading `[[\n` and the `\` inside the body, or maybe the
  empty-line handling in long strings.

- [ ] `[=[ ... ]=]` works
- [ ] `[==[ ... ]==]` works
- [ ] `[=[ contains ]] inside ]=]` works (level mismatch is fine)
- [ ] `literals.lua` and `main.lua` both at least parse (they may then
      fail at runtime — that's a separate plan).

## Implementation notes

The lexer is in `lib/lua/lexer.ex`. Find the long-string state.

Steps:
1. Reproduce minimally as a unit test: take the failing snippet from
   `literals.lua:14-17`, isolate it.
2. Trace what tokens the lexer emits. Use `Lua.Lexer.lex/1` directly and
   inspect output.
3. The bug is probably one of:
   - The lexer doesn't count `=` characters correctly to determine the
     closing bracket level.
   - The lexer treats `\` inside a long string as an escape (it shouldn't
     — long strings have NO escape sequences).
   - The lexer counts the leading newline incorrectly (long strings drop
     a single leading newline if present).
4. Fix the state machine, add tests for each bracket level (0, 1, 2, 3 `=`).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/lexer_test.exs
mix test --only lua53
```

## Risks

- The long-string state may share code with the long-comment state; fixing
  one could break the other. Verify both code paths.
- Existing tests may rely on the current (incorrect) tokenization. If so,
  update them to match Lua 5.3 spec, with a comment.
- The Lua 5.3 reference manual §3.1 has the exact spec — consult it.

## Discoveries

- The plan's leading hypothesis was wrong. `Lua.Lexer.tokenize/1` already
  handles long strings at every bracket level correctly:

  - `[[ ... ]]` (level 0)
  - `[=[ ... ]=]`, `[==[ ... ]==]`, `[===[ ... ]===]` (higher levels)
  - Embedded `]]` inside a higher-level string (level mismatch is fine)
  - The first matching close at the right level wins (`[==[]=]==]` → `]=`)

  The literals.lua line 14–17 snippet that motivated the plan tokenizes
  correctly today. A regression test for that exact snippet is now pinned
  in `test/lua/lexer_test.exs`.

- The actual blocker for `literals.lua` was *long comments*, not long
  strings. The lexer's `--[` branch only recognized level-0 multi-line
  comments (`--[[`); `--[=[`, `--[==[`, `--[===[` all fell through to the
  single-line comment scanner, which then mis-tokenized the body. Fixed by
  routing `--[` through the existing `scan_long_bracket/2` helper so all
  bracket levels share one entry point with long strings. This was listed
  as out of scope, but the success criterion "literals.lua parses" forced
  the fix — the file uses level-3 long comments.

- The actual blocker for `main.lua` was the first line: `# testing
  special comment on first line`. Lua's reference loader skips any first
  line beginning with `#` (manual §3.1, footnote about `lua` CLI). Our
  `strip_shebang/1` only handled `#!`. Tightened the rule to strip when
  the first character is `#` followed by `!` or whitespace, which keeps
  `#` (length operator) and `#table` (length-of) intact. This is also
  pinned by tests.

- Three existing lexer tests pinned the buggy `--[=[ ... ]=]` →
  single-line behaviour with explicit "(known limitation)" comments;
  those have been rewritten to assert the correct multi-line behaviour.

- The dead `scan_multiline_comment/5` helper (which only existed to
  consume the second `[` of a level-0 opener) was removed.

- Suite delta: `mix test --only lua53` count is unchanged (4 ready,
  remainder skipped) because `literals.lua` and `main.lua` are still in
  `@skipped_tests` — they parse cleanly now but they hit unrelated
  runtime gaps. Promoting them is a separate plan.

## What changed

Files touched:

- `lib/lua/lexer.ex` — route `--[` through `scan_long_bracket/2`; widen
  shebang strip to `#!` or `# `+whitespace; remove dead
  `scan_multiline_comment/5`.
- `test/lua/lexer_test.exs` — three tests rewritten to assert correct
  multi-line behaviour for `--[=[`/`--[==[`; +7 new tests covering long
  strings at level 3, level-mismatched embedded `]]`, the
  `literals.lua:14–17` snippet, the `literals.lua:240–245`
  nested-comment snippet, the `main.lua` `# ...` header, and the `#`
  length operator.
- `.agents/plans/A2-long-string-lexer.md` — status, PR number,
  discoveries, this section.

Test deltas:

- `mix test`: 1294 → 1301, 0 failures.
- `mix test --only lua53`: unchanged (4 ready, 25 skipped). literals.lua
  and main.lua still skipped — they parse cleanly now but hit unrelated
  runtime gaps. Promoting them is a separate plan.

No follow-up issues opened.
