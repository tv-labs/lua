---
id: A2
title: Long-string [[ ... ]] lexer handles embedded ] and level brackets [==[
issue: 163
pr: null
branch: fix/long-string-lexer
base: main
status: ready
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

(populated during implementation)
