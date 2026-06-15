defmodule Lua.Parser.ErrorPositionTest do
  @moduledoc """
  Pins the *position* of syntax errors — line and column — not just their
  detection.

  A recursive-descent parser can detect a syntax error correctly yet report
  it at the wrong place: when a deeply-nested sub-parse fails, a shallower
  recovery point may swallow the real error and substitute a generic
  "expected <terminator>" pinned to the list boundary. These tests lock the
  reported line and column to the place our convention says they belong.

  The convention these tests encode (our bar, not any reference compiler's):

    * A *concrete offending token* mid-stream is blamed at that token — never
      at a shallower recovery boundary. A deep error inside the Nth argument
      of a call wins over the outer call's terminator.
    * A construct that *runs off the end of input* (`(`, `[`, `{`, a string,
      a long string/comment) is blamed at its *opening* delimiter, with an
      "add a closing X" suggestion — not at a bare <eof> pinned to the end of
      the file.
    * A block keyword body (`function`/`if`/`while`/`for`/`do`) that reaches
      <eof> without `end` is reported where `end` was expected.

  Every entry asserts both APIs: `parse_structured/1` for the exact
  `{line, column}`, and `parse/1` for the rendered `at line L, column C`
  banner plus a substring of the message it pins.
  """
  use ExUnit.Case, async: true

  alias Lua.Parser
  alias Lua.Parser.Error

  # {name, source, line, column, message_substring}
  #
  # Grouped by the shape of the failure. Columns are 1-indexed and point at
  # the exact token described above.

  @opener_errors [
    # Bracket delimiters that run off the end of input are blamed at the
    # opener, uniformly across (), [] and {}.
    {"unclosed call across lines", "print(1, 2, 3\n", 1, 6, "Unclosed opening parenthesis"},
    {"unclosed index across lines", "y = t[\n  1\n", 1, 6, "Unclosed opening bracket"},
    {"unclosed paren across lines", "z = (\n  1 + 2\n", 1, 5, "Unclosed opening parenthesis"},
    {"unclosed table across lines", "t = {\n  a = 1\n", 1, 5, "Unclosed opening brace"},

    # A delimiter opened immediately before <eof> still blames the opener,
    # not a bare "Expected expression" at the end of the file.
    {"empty call hits end of input", "g(\n", 1, 2, "Unclosed opening parenthesis"},

    # The innermost unclosed delimiter wins: table -> function -> call, the
    # call's '(' on line 3 is the deepest opener.
    {"nested table/function/call all unclosed", "t = {\n  f = function()\n    g(\n", 3, 6, "Unclosed opening parenthesis"}
  ]

  @lexer_errors [
    {"unterminated string", "x = \"abc\n", 1, 9, "Unclosed string literal"},
    {"unterminated long string", "x = [[abc\n", 2, 1, "Unclosed long string"},
    {"unterminated long comment", "--[[ comment\nx = 1\n", 3, 1, "Unclosed multi-line comment"}
  ]

  @missing_end_errors [
    # Block bodies that reach <eof> without `end` are reported where `end`
    # was expected (the line past the body), not at the opening keyword.
    {"function body missing end", "function f()\n  return 1\n", 3, 1, "Expected :keyword::end"},
    {"if-then body missing end", "if x then\n  y = 1\n", 3, 1, "Expected :keyword::end"},
    {"while-do body missing end", "while c do\n  y = 1\n", 3, 1, "Expected :keyword::end"},
    {"do block missing end", "do\n  y = 1\n", 3, 1, "Expected :keyword::end"},
    {"for-do body missing end", "for i = 1, 2 do\n  y = 1\n", 3, 1, "Expected :keyword::end"}
  ]

  @offending_token_errors [
    # A concrete bad token is blamed exactly where it sits.
    {"stray token after complete arg list", "print(1, 2 3)\n", 1, 12, "Expected :delimiter::rparen"},
    {"empty argument before comma", "f(,)\n", 1, 3, "Expected expression"},
    {"empty return expression", "function f()\n  return ,\nend\n", 2, 10, "Expected expression"},
    {"assignment with no right-hand side", "x = \n", 2, 1, "Expected expression"},
    {"binary operator with no right operand", "y = 1 + \n", 2, 1, "Expected expression"},
    {"unary minus with no operand", "y = -\n", 2, 1, "Expected expression"},
    {"'not' with no operand", "y = not\n", 2, 1, "Expected expression"},
    # The motivating report: `function` as a statement needs a name, so the
    # '(' is the genuine first error — line 1, not the call on line 2.
    {"function statement missing name", "function() do\n  foo.bar(\nend\n", 1, 9, "Expected :identifier, got :delimiter"},
    {"dangling property access", "y = foo.\n", 2, 1, "Expected :identifier, got :eof"},
    {"dangling method access", "y = foo:\n", 2, 1, "Expected :identifier, got :eof"},
    {"table field with no key", "t = { = 1 }\n", 1, 7, "Expected expression"},
    {"method call missing name", "a:()\n", 1, 3, "Expected :identifier, got :delimiter"},
    {"if missing then", "if x y then end\n", 1, 6, "Expected :keyword::then"},
    {"while missing do", "while c x end\n", 1, 9, "Expected :keyword::do"},
    {"local missing name", "local = 1\n", 1, 7, "Expected identifier or 'function' after 'local'"}
  ]

  @deep_propagation_errors [
    # The highest-value cases: a bad token deep inside nested functions/calls
    # must point at the innermost offending token, never the outer call line
    # or the `function` keyword.
    {"deep error in 5th call argument", ~s|w:step("a", "b", "c", {x = 1}, function()\n  bar(\nend)\n|, 3, 1,
     "Expected expression"},
    {"deep error in a table field value", "t = {\n  a = 1,\n  b = foo(,\n}\n", 3, 11, "Expected expression"},
    {"bad token in function inside function inside call",
     "outer(function()\n  inner(function()\n    x = +\n  end)\nend)\n", 3, 9, "Expected expression"},
    {"deep error in a return list", "function f()\n  return 1, 2, g(\nend\n", 3, 1, "Expected expression"},
    {"stray statement after nested calls", "outer(mid(inner(\n)))\n.. bad\n", 3, 1, "bare"},
    # A bare-expression error deep inside a function argument must blame the
    # inner statement, not the `function` keyword at the enclosing call's
    # opener. Regression for a stray `)` reported against the wrong line.
    {"bare expression in nested function argument", ~s|w:step("a", "b", function(output)\n  device.doesntExist)\nend)\n|,
     2, 3, "bare table-access expression"},
    # An invalid assignment target deep inside a function argument must blame
    # the inner statement even though the offending node (`f()`, an Expr.Call)
    # carries no position — the error is structurally committed.
    {"invalid assign target in nested function argument", ~s|outer("ok", function()\n  f() = 1\nend)\n|, 2, 7,
     "syntax error near '='"},
    # An unclosed delimiter opened inside a non-first argument propagates as
    # the genuine deep error rather than being swallowed at the outer boundary.
    {"unclosed delimiter in non-first call argument", "outer(1, inner(\n", 1, 15, "Unclosed opening parenthesis"}
  ]

  @statement_errors [
    {"bare arithmetic expression", "2 + 2\n", 1, 3, "bare arithmetic"},
    {"stray end keyword", "x = 1\nend\n", 2, 1, "Expected end of input"},
    {"stray closing paren", "x = 1\n)\n", 2, 1, "Expected expression"},
    {"double assignment operator", "a = = b\n", 1, 5, "Expected expression"},
    {"invalid assignment target", "1 = 2\n", 1, 1, "syntax error near '='"}
  ]

  describe "opener positions (unclosed brackets)" do
    for {name, source, line, column, substring} <- @opener_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  describe "lexer-origin positions" do
    for {name, source, line, column, substring} <- @lexer_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  describe "missing-end positions" do
    for {name, source, line, column, substring} <- @missing_end_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  describe "concrete offending-token positions" do
    for {name, source, line, column, substring} <- @offending_token_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  describe "deep-propagation positions" do
    for {name, source, line, column, substring} <- @deep_propagation_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  describe "statement-level positions" do
    for {name, source, line, column, substring} <- @statement_errors do
      test name do
        assert_error_at(unquote(source), unquote(line), unquote(column), unquote(substring))
      end
    end
  end

  # Asserts the structured position (exact line + column) and the rendered
  # banner + message together, so a drift in either the position or the
  # human-facing string is caught.
  defp assert_error_at(source, line, column, substring) do
    assert {:error, [%Error{position: position} = error]} = Parser.parse_structured(source),
           "expected exactly one structured error for:\n#{source}"

    assert position != nil, "expected a positioned error, got: #{inspect(error)}"

    assert {position.line, position.column} == {line, column},
           "expected position {#{line}, #{column}}, got {#{position.line}, #{position.column}} for:\n#{source}"

    assert {:error, msg} = Parser.parse(source)
    clean = strip_ansi(msg)

    assert clean =~ "at line #{line}, column #{column}",
           "expected rendered banner 'at line #{line}, column #{column}', got:\n#{clean}"

    assert clean =~ substring,
           "expected message to contain #{inspect(substring)}, got:\n#{clean}"
  end

  defp strip_ansi(string), do: String.replace(string, ~r/\e\[[0-9;]*m/, "")
end
