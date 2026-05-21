---
id: A36
title: Parser errors always carry position; rewrite bare-expression message
issue: null
pr: null
branch: fix/parser-error-positions
base: main
status: in-progress
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

- [ ] `Lua.eval!("2 + 2")` produces a `Lua.CompilerException` whose
      message contains `line 1, column 1` and the source line with a
      caret.
- [ ] `Lua.eval!("foo")` (a bare `Expr.Var`) likewise carries position,
      with a suggestion about assignment/calling.
- [ ] `Lua.eval!("t.field")` (bare `Expr.Index` or `Expr.Prop`)
      likewise carries position.
- [ ] `Lua.eval!("if true then")` (unexpected end — body missing
      `end`) carries an EOF position, not `nil`.
- [ ] `Lua.eval!("local")` (unexpected end after local keyword)
      carries position.
- [ ] No existing parser-error test breaks.
- [ ] `mix test` passes; `mix test test/lua/parser/` passes.

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

(populated during implementation)
