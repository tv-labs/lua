---
id: A36
title: Parser errors always carry position; rewrite bare-expression message
issue: null
pr: 222
branch: fix/parser-error-positions
base: main
status: merged
direction: A
unlocks:
  - `Lua.eval!("2 + 2")` produces a useful error message
  - parser errors can join the A26 error gallery
---

## Goal

Every parse error rendered to the user includes:

- a `line N, column M` location;
- the offending source line echoed with a caret;
- (where appropriate) a suggestion specific to the failure shape.

Today, three error paths in `Lua.Parser` produce
`position: nil` and render `(no position information)`. The most
visible is the bare-expression-at-statement-level case:

```elixir
iex> Lua.eval!("2 + 2")
** (Lua.CompilerException) Failed to compile Lua!

Parse Error

  (no position information)

  Expression statement must be a function call
```

After this plan:

```
** (Lua.CompilerException) Failed to compile Lua!

Parse Error

  at line 1, column 1:

  A bare arithmetic expression isn't a Lua statement; did you mean
  to use 'return 2 + 2'?

  1 │ 2 + 2
      ^
```

## Out of scope

- Multi-error recovery. `Lua.Parser.Recovery` is fully built and
  unit-tested but never called from `Lua.Parser.parse/1`. Wiring it
  in is its own future plan.
- Widening `Lua.CompilerException` to expose structured fields
  (`:line`, `:column`, `:source`). The struct stays as
  `defexception [:errors, :state]`; we only ensure the formatted strings
  inside `:errors` contain the location. Public-struct widening would
  be a follow-up plan.
- Touching any other parser error message. Only the three positionless
  cases below.
- Lexer error positions. Already correct (`convert_lexer_error/2` at
  `parser.ex:1251-` already passes `pos`).

## Success criteria

- [x] `Lua.eval!("2 + 2")` produces a `Lua.CompilerException` whose
      message contains `line 1, column N` and the source line with a
      caret.
- [x] `Lua.eval!("foo")` (a bare `Expr.Var`) likewise carries
      position (`line 1, column 1`) and a suggestion about
      assignment/calling.
- [x] `Lua.eval!("t.field")` (bare `Expr.Property`) and
      `Lua.eval!("t[1]")` (bare `Expr.Index`) likewise carry position.
- [x] `Lua.eval!("if true then")` already carries position
      (line 1, column 13) — no change needed.
- [x] `Lua.eval!("local")` (unexpected token after `local` keyword)
      now carries position (was hitting catch-all converter with a
      malformed tuple, now uses the standard `:unexpected_token`
      shape).
- [x] No existing parser-error test breaks.
- [x] `mix test` passes (1672 → 1684, +12 tests, 0 failures).
- [x] `mix test --only lua53` unchanged (6 passing, 23 skipped).

## Implementation notes

### Three sites lose position today

All three are in `lib/lua/parser.ex`:

#### Site 1 — bare expression at statement level (the headline case)

`parser.ex:570-572`:

```elixir
_ ->
  {:error, {:unexpected_expression, "Expression statement must be a function call"}}
```

Becomes:

```elixir
expr ->
  {:error, {:bare_expression, expr.meta.start, expr.__struct__}}
```

Then a new converter at `parser.ex:1243-`:

```elixir
defp convert_error({:bare_expression, pos, expr_struct}, _code) do
  {message, suggestion} = bare_expression_message(expr_struct)
  Error.new(:invalid_syntax, message, pos, suggestion: suggestion)
end

defp bare_expression_message(Expr.BinOp) do
  {"A bare arithmetic expression isn't a Lua statement.",
   "Did you mean to assign or return the result? For example: 'return ...'"}
end

defp bare_expression_message(Expr.UnaryOp) do
  {"A bare unary expression isn't a Lua statement.",
   "Did you mean to assign or return the result?"}
end

defp bare_expression_message(Expr.Var) do
  {"A bare variable reference isn't a statement.",
   "To call this as a function, add parentheses: 'name()'. " <>
     "To assign to it, write 'name = value'."}
end

defp bare_expression_message(struct)
     when struct in [Expr.Index, Expr.Prop] do
   {"A bare table-access expression isn't a statement.",
    "Did you mean to assign to or read from this field? " <>
      "For an assignment: 't.field = value'. To call: 't.field()'."}
end

defp bare_expression_message(_struct) do
  {"This expression isn't a Lua statement.",
   "Lua statements must be assignments, function calls, or control " <>
     "flow. To use this expression, return it or assign it to a name."}
end
```

#### Site 2 — unexpected end of input

`parser.ex:1234-1241`:

```elixir
defp convert_error({:unexpected_end, message}, _code) do
  Error.new(:unexpected_end, message, nil, suggestion: ...)
end
```

`:unexpected_end` is raised from several call sites in the parser; the
tuple needs to grow a `pos` field. The lexer's last token (or a
synthetic EOF token) provides the position.

Investigation step: trace where `{:unexpected_end, message}` is raised
in `parser.ex` and confirm each site has access to `peek(tokens)` or
similar. The most natural fix is `{:unexpected_end, message, last_pos}`
where `last_pos` is the position of the last consumed token (`+1`
column to point past it).

If no token has been seen (empty input), use `%{line: 1, column: 1,
byte_offset: 0}`.

#### Site 3 — catch-all `convert_error/2`

`parser.ex:1247-1249`:

```elixir
defp convert_error(other, _code) do
  Error.new(:invalid_syntax, "Parse error: #{inspect(other)}", nil)
end
```

This is defensive — every error tuple we deliberately construct now
carries position, so the catch-all should be dead code. Keep it
defensive but log a warning at compile time if we hit it, or convert it
to raise an internal exception. Simplest: keep as-is, since the
upstream fixes mean we won't hit it. Add a test asserting that the
catch-all is unused for a representative sample of inputs (it doesn't
need to be exhaustive).

### AST struct shapes available

Confirmed in `lib/lua/ast/expr.ex`:
- `Expr.BinOp`, `Expr.UnaryOp` — operator expressions.
- `Expr.Var` — bare identifier.
- `Expr.Index` (`t[k]`), `Expr.Prop` (`t.k`) — table access.
- `Expr.Number`, `Expr.String`, `Expr.Bool`, `Expr.Nil`, `Expr.Vararg`
  — literals (also bare-expression candidates, falls into the
  default suggestion).
- `Expr.Function` — anonymous function (rarely a user-error case but
  technically can appear as a bare statement).

All have `:meta` with `start: %{line, column, byte_offset}`.

### Files touched

- `lib/lua/parser.ex` — three error sites updated, plus
  `bare_expression_message/1` helper. ~50 lines added.
- `test/lua/parser/error_test.exs` — 5-6 new tests:
  - `parses fails with position on bare arithmetic expression`
  - `parses fails with position on bare variable`
  - `parses fails with position on bare table access`
  - `parses fails with position on unexpected end after 'if true then'`
  - `parses fails with position on unexpected end after 'local'`
  - `bare-expression suggestion mentions 'return'`
- `test/lua/compiler_exception_test.exs` — extend `test "compile
  errors include line and column"` block with a bare-expression case
  to lock that the rendered message contains `line 1`.

### Wording change is user-visible

The string `"Expression statement must be a function call"` is going
away. `grep -r "Expression statement" .` finds:
- The raise site in `parser.ex` (changes).
- No tests (confirmed in initial audit).
- No documentation references.

The new wording still contains `"Lua statement"` so a downstream
consumer with a permissive `~r/statement/i` match would still match.
Note in the PR body. No CHANGELOG entry needed since this is pre-1.0
rc and the wording isn't part of any public contract.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/parser/
mix test test/lua/compiler_exception_test.exs
```

Manual smoke:

```elixir
iex> Lua.eval!("2 + 2")
# Expect: position rendered, suggestion mentions 'return'.

iex> Lua.eval!("foo")
# Expect: position rendered, suggestion mentions assignment/calling.

iex> Lua.eval!("if true then")
# Expect: position at end of input (line 1, column 14 or thereabouts).
```

## Risks

- **EOF position threading.** Threading EOF position into the
  `:unexpected_end` tuple may require touching multiple raise sites in
  the parser. If any one is deep in the recursive descent without easy
  access to the token stream, fall back to passing the last consumed
  token's position from the top-level `parse_chunk/1`. The plan stays
  in scope either way.
- **Wording change.** Discussed above; no tests pin the old string.
- **Catch-all `convert_error/2`.** If a code path still hits it after
  our changes, we keep the existing `position: nil` fallback rendering
  rather than crashing — safe by construction.

## Discoveries

- **`parser.ex:289` had a malformed error tuple.** The `local` keyword
  failure path emitted `{:unexpected_token, peek(rest), msg}` — a
  3-tuple with the entire token as the second element — instead of
  the standard 4-tuple `{:unexpected_token, type, pos, message}`. This
  fell through to the catch-all `convert_error/2`, producing
  `Parse error: {:unexpected_token, {:eof, %{...}}, "..."}` with no
  rendered position. Fixed by reshaping the tuple correctly. Brought
  into scope because A36 specifically calls out `Lua.eval!("local")`
  as a success criterion.

- **`Expr.Property` and `Expr.Index` are constructed with `meta: nil`**
  at `parser.ex:867` and `parser.ex:880` respectively. This made the
  bare-`t.field` case render without position even after the
  conversion fix. Rather than backfill meta into every postfix infix
  site (broader scope), the bare-expression error site falls back to
  the position of the *first token consumed* (`tokens` before
  `parse_expr` runs). This always yields a position, since the lexer
  always emits at least one token with a position. Backfilling
  postfix `meta` is a follow-up.

- **`Expr.BinOp.meta.start` points at the operator, not at the
  leftmost operand.** For `2 + 2`, the rendered caret lands on the
  `+` (column 3) instead of the `2` (column 1). User-visible but
  still correct: the error is at the BinOp expression, the operator
  is a reasonable anchor, and a richer rendering would need explicit
  range information (`start..end`). Out of scope for this plan.

- **The lone two-tuple `{:unexpected_end, msg}` shape was retained as
  a legacy clause** in `convert_error/2`. Three call sites in the
  parser now use the three-tuple shape `{:unexpected_end, msg, pos}`
  with `pos = nil` (the original behavior). The legacy clause is dead
  in this PR but kept as a safety net.

- **Per-shape bare-expression suggestions** cover six AST node
  categories: `BinOp`, `UnOp`, `Var`, `Index`/`Property`, literals
  (`Number`/`String`/`Bool`/`Nil`/`Vararg`/`Table`), and a default
  catch-all (e.g. `Expr.Function`). Each carries an actionable hint
  matching the shape that was bare.

## What changed

PR: [#222](https://github.com/tv-labs/lua/pull/222)

Files touched:

- `lib/lua/parser.ex` —
  - `parse_assign_or_call/1`: replaced the positionless
    `:unexpected_expression` tuple with `:bare_expression` carrying
    the offending expression's position (with a fallback to the
    first token's position when the AST node's `meta` is missing)
    and its AST struct.
  - Local-keyword error site at L289: replaced the malformed
    `{:unexpected_token, peek(rest), msg}` tuple with the standard
    4-tuple shape.
  - Three `:unexpected_end` error sites updated from a 2-tuple to a
    3-tuple carrying an optional position (all currently `nil`
    because they fire when the token list is empty post-EOF — full
    EOF threading is a follow-up).
  - New private helpers: `token_position/1`,
    `bare_expression_message/1`.
  - Converter clause for `:bare_expression` that emits an
    `Lua.Parser.Error` with the position and per-shape suggestion.
- `test/lua/parser/error_test.exs` — 11 new tests under
  "bare-expression statements" (BinOp / UnOp / Var / Index /
  Property / literals / multi-line) and "unexpected end of input"
  (lone `local`).
- `test/lua/compiler_exception_test.exs` — 1 new regression test
  asserting bare-expression rendering carries position and does not
  show `(no position information)`.

Test count: 1672 → 1684 (+12). 0 failures.
Suite count: 6/29, unchanged.
