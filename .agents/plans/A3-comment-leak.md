---
id: A3
title: Comment tokens leak past lexer in calls.lua path
issue: 164
pr: null
branch: fix/lexer-comment-leak
base: main
status: ready
direction: A
unlocks:
  - calls.lua
---

## Goal

Fix the lexer to never leak comment tokens to the parser/executor.
Currently `calls.lua` crashes with:

```
Lua runtime error: no case clause matching:
    {:comment, :single, " LUAC_INT", %{line: 374, column: 30, byte_offset: 8883}}
```

A `{:comment, :single, ...}` tuple should never escape the lexer — comments
are stripped after lexing.

## Out of scope

- Preserving comments for AST consumers (an opt-in feature, separate
  concern).
- Long comment edge cases — they may share state with long strings (A2);
  if both are broken in the same way, ship A2 first and re-evaluate.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] New unit test reproducing the leak: take `calls.lua:374` context
      and shrink to a 5–10 line repro.
- [ ] Lexer/parser pipeline never emits a `:comment` tuple to the executor.
      Add an assertion or pattern in test verifying tokens are filtered.
- [ ] `calls.lua` passes (or at least progresses past line 374).

## Implementation notes

Steps:
1. `grep -n LUAC_INT test/lua53_tests/calls.lua` to find context. Likely
   a `--[[ LUAC_INT ... ]]` long comment somewhere.
2. Reproduce in isolation: copy that comment + surrounding code into a
   unit test in `test/lua/lexer_test.exs`.
3. Trace where the `:comment` tuple comes from. Two options:
   - The lexer emits `:comment` and a downstream pass forgets to strip them.
     Look at `lib/lua/parser/comments.ex`.
   - The lexer should never emit `:comment` for stripped comments at all,
     and is only doing so in some misclassified state.
4. Fix at the right layer. If comments are deliberately preserved for an
   AST-level use, ensure the executor is not ever fed comment tokens.

The error message includes "LUAC_INT" which is from a Lua-source comment
about `LUAC_INT`/`LUAC_NUM` (these are PUC-Lua's internal compiler
constants) — confirms it's a long-comment issue.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/lexer_test.exs
mix test --only lua53
```

## Risks

- If `Lua.Parser.Comments` deliberately keeps comments for tooling, the fix
  goes in the parser-to-codegen boundary, not the lexer.
- Any test that inspects raw tokens may break.

## Discoveries

(populated during implementation)
