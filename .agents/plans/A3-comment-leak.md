---
id: A3
title: Comment tokens leak past lexer in calls.lua path
issue: 164
pr: 182
branch: fix/lexer-comment-leak
base: main
status: review
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

- The lexer is correct: it deliberately emits `{:comment, type, text, pos}`
  tokens so AST consumers can attach them via `Lua.Parser.Comments`. The
  parser already skips comments at *some* boundaries (statement,
  expression prefix, end-of-block), but missed comments at **list/sequence
  separator boundaries**: function-argument lists and table constructors.
  After parsing one expression and before peeking for the next `,` (or
  the closing `)`/`}`), a trailing line-comment plus optional standalone
  comments would flow straight into `expect/3` and crash the executor with
  `no case clause matching: {:comment, :single, ...}`.
- Fix is local: a `skip_comments/1` helper applied at three sites in
  `Lua.Parser` — `parse_expr_list_acc/2` (between expr and comma),
  `parse_expr_list_until/2` (between last expr and terminator), and
  `parse_table_fields/2` (between field and `,`/`;`/`}`). The helper is
  scoped: in `parse_expr_list_acc`, comments are only consumed when the
  next significant token is a comma, so trailing line-comments belonging
  to a parent statement can still be attached by `parse_stmt`.
- `calls.lua` no longer crashes on the comment leak. It now fails earlier
  on line 6 (`local debug = require "debug"`) because `require` is
  sandboxed — a separate, pre-existing concern out of scope here.
- `string.pack` is also unimplemented; the original repro pattern from
  `calls.lua:374` would hit that next. Both are tracked elsewhere.

## What changed

- `lib/lua/parser.ex`: added a `skip_comments/1` helper near the
  `peek`/`consume` token utilities. Applied it at three boundaries:
  `parse_expr_list_acc/2` (gated on comma lookahead so trailing
  comments still reach `parse_stmt`), `parse_expr_list_until/2`
  (before terminator peek), and `parse_table_fields/2` (before and
  after each field).
- `test/lua/parser/comment_test.exs`: new `describe` block "comments
  inside expression lists (regression for A3)" with 7 regression
  tests covering function-arg lists and table constructors, plus a
  test that walks the full parsed AST asserting no `{:comment, ...}`
  tuple survives into the structure passed to codegen.
- Suite: 1301 → 1309 tests passing, 0 failures, 0 regressions.
- PR: #182. No follow-up issues opened — `require` sandboxing and
  `string.pack` were pre-existing.
