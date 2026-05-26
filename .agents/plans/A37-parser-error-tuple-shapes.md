---
id: A37
title: Parser `:unexpected_token` errors carry position in all sites (A36 follow-up)
issue: null
pr: null
branch: fix/parser-error-tuple-shapes
base: main
status: ready
direction: A
unlocks:
  - Table-field syntax errors render with position and source context
  - Bad for-loop, assignment, and param-list syntax errors render the same
---

## Goal

Every parser `:unexpected_token` error tuple uses the canonical 4-tuple
shape `{:unexpected_token, type, pos, message}` so the existing
`Lua.Parser.Error.format/2` pipeline can render it with line/column,
source echo, and a caret — instead of falling through the catch-all and
printing raw Elixir terms.

A36 (#222) flagged this exact class of bug for the `local` keyword
path. Five sibling sites were missed. This plan normalizes all of them
and adds a private helper so the malformed shape can't sneak back in.

The trigger that surfaced this: a user evaluating

```lua
return { "ok" = 5 }
```

…got

```
Parse error: {:unexpected_token, {:operator, :assign, %{line: 1, column: 14, byte_offset: 13}}, "Expected ',' or '}' in table"}
```

instead of a positioned error.

## Out of scope

- **Multi-error recovery.** `Lua.Parser.Recovery` still isn't wired in
  — same boundary A36 drew.
- **Backfilling `meta` on `Expr.Property`/`Expr.Index` postfix nodes.**
  A36 deferred this; nothing here needs it.
- **Widening `Lua.CompilerException`'s public struct fields.** Same
  boundary as A36; the rendered string is what changes.
- **Lexer error positions.** Already correct.
- **Restructuring the parser to eliminate every place a 3-tuple could
  appear.** Five sites is the audit-complete scope; new sites need to
  go through `unexpected_token_error/2`.

## Success criteria

- [ ] `Lua.eval!(~S|return { "ok" = 5 }|)` renders `Parse Error` with
      `line 1, column 14`, the source line echoed, and a caret.
- [ ] The rendered message also contains a `Suggestion:` block
      mentioning `["ok"] = 5` (the bracketed-key form), because the
      common cause for that exact `string = value` shape in a table
      constructor is the user reaching for JSON / map syntax.
- [ ] The same renders correctly for: `for i 1, 10 do end`,
      `for i, j 1, 10 do end`, `local function f(x y) end`,
      `a, b c = 1, 2`.
- [ ] No rendered parser error contains the literal substring
      `(no position information)` for any of the six inputs above.
- [ ] No rendered parser error contains the literal substring
      `:unexpected_token` (i.e. no `inspect/1` of Elixir terms leaks
      through to users for any of the six inputs).
- [ ] `mix test` passes with at least 1705 + new tests, 0 failures.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] No existing parser-error test breaks.

## Implementation notes

### The bug

`Lua.Parser.convert_error/2` matches the canonical 4-tuple:

```elixir
defp convert_error({:unexpected_token, type, pos, message}, _code) do
  Error.new(:unexpected_token, message, pos, suggestion: ...)
end
```

Five sites in `lib/lua/parser.ex` build a malformed 3-tuple where the
second element is the entire peeked token (itself a 3-tuple):

| Line | Site | Faulty tuple |
| --- | --- | --- |
| 407 | numeric-for var followed by neither `=` nor `in` | `{:unexpected_token, peek(rest2), "Expected '=' or 'in' after for variable"}` |
| 456 | generic-for var list not terminated by `in` | `{:unexpected_token, peek(tokens), "Expected ',' or 'in' in for loop"}` |
| 616 | multi-target assignment with bad continuation | `{:unexpected_token, peek(rest2), "Expected '=' or ',' in assignment"}` |
| 1005 | table field followed by unexpected token (the user's reproducer) | `{:unexpected_token, peek(rest), "Expected ',' or '}' in table"}` |
| 1104 | parameter list with unexpected token | `{:unexpected_token, peek(tokens), "Expected parameter name or ')'"}` |

All five fall through `convert_error(other, _code)` (line 1281) and
`inspect/1` the malformed tuple into the message with `position: nil`.
That's exactly the output the user pasted.

### The fix

Introduce a private helper that destructures the peek result correctly
and produces the canonical tuple shape:

```elixir
defp unexpected_token_error(tokens, message) do
  case peek(tokens) do
    {type, _value, pos} ->
      {:error, {:unexpected_token, type, pos, message}}

    {:eof, pos} ->
      {:error, {:unexpected_token, :eof, pos, message}}

    nil ->
      {:error, {:unexpected_end, message, nil}}
  end
end
```

Then rewrite each of the five sites as:

```elixir
unexpected_token_error(rest, "Expected ',' or '}' in table")
```

The existing `parse_local/1` (lines 288–301) has the same three-branch
case inlined. Migrate it to the helper too — same shape, removes
duplication, and brings the audit boundary up to "all unexpected-token
sites use the helper."

### Suggestion polish: did-you-mean for string-keyed tables

For the user's reported input, the more useful suggestion than the
generic "Check for missing operators or keywords before this
delimiter" is:

> In a table constructor, string keys must be bracketed:
> `{ ["ok"] = 5 }`. The shorthand `name = value` only works with
> identifier keys.

To deliver this, we tag the table-field site with a more specific
shape and route it through a tailored suggestion. The cleanest
mechanism without inventing a new error type is to pass a "context"
hint through the error tuple — but that drifts scope. Instead, we
extend `suggest_for_token_error/2` in `parser.ex` to recognize the
substring `"Expected ',' or '}' in table"` (the existing message)
combined with `type == :operator` (i.e. the unexpected token was
`=`/`assign`, or another operator) and emit the bracketed-key hint.

This keeps the helper generic and pushes the polish into the existing
suggestion router. Tradeoff: it's slightly clever (matches on the
message string), but it's the same pattern already used in
`suggest_for_token_error/2` for the other branches and keeps the diff
narrow. If suggestion routing grows further, a later plan can refactor
to a structured shape.

### Files touched

- `lib/lua/parser.ex` —
  - Add `unexpected_token_error/2` private helper.
  - Rewrite five malformed sites to use it.
  - Rewrite the inline three-branch case in `parse_local/1` to use it.
  - Extend `suggest_for_token_error/2` with the table-string-key hint.
- `test/lua/parser/error_test.exs` — new `describe "unexpected-token sites
  carry position"` block with the five inputs above. Additional test
  for the string-keyed table suggestion.
- `test/lua/compiler_exception_test.exs` — one regression test asserting
  the user's reported input renders correctly at the public API.

### Net diff

Estimate: ~−20 lines in `parser.ex` (helper replaces five copies of an
inline case), +~60 lines in tests, +1 plan file.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test test/lua/parser/error_test.exs
mix test test/lua/compiler_exception_test.exs
mix test
```

Manual smoke:

```elixir
Lua.eval!(~S|return { "ok" = 5 }|)
Lua.eval!("for i 1, 10 do end")
Lua.eval!("for i, j 1, 10 do end")
Lua.eval!("local function f(x y) end")
Lua.eval!("a, b c = 1, 2")
```

Each must render:
- `Parse Error`
- `at line N, column M`
- echoed source line + `^`
- a `Suggestion:` block (the table case mentions `["ok"] = 5`).

Each must NOT render:
- `(no position information)`
- `:unexpected_token` or `:operator` or other raw Elixir terms.

## Risks

- **Helper naming.** Chose `unexpected_token_error/2` for searchability
  with the `:unexpected_token` tuple tag.
- **The `nil` peek branch.** Only fires on a malformed token stream
  (the lexer always emits an `:eof` token). Confirmed no existing tests
  pin the old positionless rendering of these five sites.
- **Suggestion router by message substring.** Matches the pattern
  already in use in `suggest_for_token_error/2`. If the table-field
  message ever changes wording, the suggestion silently degrades to
  the generic one (safe-by-construction). A test pins the suggestion.
- **Wider-than-one-site PR.** Justified by identical root cause and
  identical 1-line fix shape across all five sites; splitting would be
  ceremony.
