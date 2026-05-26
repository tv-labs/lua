defmodule Lua.Parser.ErrorTest do
  @moduledoc """
  Tests for parser error messages, including formatting and suggestions.
  """
  use ExUnit.Case, async: true

  alias Lua.Parser

  describe "syntax errors" do
    test "missing 'end' keyword" do
      code = """
      function foo()
        return 1
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Parse Error"
      assert msg =~ "line 3"
      assert msg =~ "Expected"
      assert msg =~ "'end'"
    end

    test "missing 'then' keyword" do
      code = """
      if x > 0
        return x
      end
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Expected"
      assert msg =~ ":then"
    end

    test "missing 'do' keyword in while loop" do
      code = """
      while x > 0
        x = x - 1
      end
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Expected"
      assert msg =~ ":do"
    end

    test "missing closing parenthesis" do
      code = "print(1, 2, 3"
      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Parse Error"
    end

    test "missing closing bracket" do
      code = "local t = {1, 2, 3"
      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Parse Error"
    end

    test "unexpected token in expression" do
      code = "local x = 1 + + 2"
      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Parse Error"
    end

    test "complex nested function with missing end" do
      code = """
      function factorial(n)
        if n <= 1 then
          return 1
        else
          return n * factorial(n - 1)
        -- Missing 'end' here!
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ ~r/Parse Error/i
      assert msg =~ "line"
      assert msg =~ "Expected"
      assert msg =~ "end"
    end
  end

  describe "lexer errors" do
    test "unclosed string" do
      code = ~s(local x = "hello)
      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Unclosed string"
      assert msg =~ "line 1"
    end

    test "unexpected character" do
      code = """
      local x = 42
      local y = @invalid
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Unexpected character"
      assert msg =~ "line 2"
      assert msg =~ "@"
    end
  end

  describe "error message formatting" do
    test "includes visual formatting elements" do
      code = "if x > 0"

      assert {:error, msg} = Parser.parse(code)
      # Line separator
      assert msg =~ "│"
      # Error pointer
      assert msg =~ "^"
      # ANSI color codes
      assert msg =~ "\e["
    end

    test "includes line and column information" do
      code = """
      local x = 1
      if x > 0 then
        print(x
      end
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "line"
      assert msg =~ "column"
    end

    test "shows context lines around error" do
      code = """
      local x = 1
      local y = 2
      if x > y
        print(x)
      end
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "│"
    end

    test "provides helpful suggestions" do
      code = """
      function test()
        print("hello")
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "Suggestion"
    end

    test "uses ANSI colors for better readability" do
      code = "if x then"

      assert {:error, msg} = Parser.parse(code)
      # Red for errors
      assert msg =~ "\e[31m"
      # Bold
      assert msg =~ "\e[1m"
      # Reset
      assert msg =~ "\e[0m"
      # Cyan for suggestions
      assert msg =~ "\e[36m"
    end
  end

  describe "parse_raw API" do
    test "returns structured error tuple" do
      code = "if x then"
      assert {:error, error_tuple} = Parser.parse_raw(code)
      assert is_tuple(error_tuple)
    end

    test "returns AST on success" do
      code = "local x = 42"
      assert {:ok, chunk} = Parser.parse_raw(code)
      assert chunk.__struct__ == Lua.AST.Chunk
    end
  end

  describe "bare-expression statements" do
    # A bare expression at statement level (e.g. `2 + 2` with no
    # `return`, no assignment, and no function call) is invalid Lua.
    # Every shape must produce a positioned error with a suggestion
    # specific to the expression shape.

    test "bare arithmetic expression carries position and arithmetic suggestion" do
      assert {:error, msg} = Parser.parse("2 + 2")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "bare arithmetic"
      assert msg =~ "return"
    end

    test "bare unary expression carries position and unary suggestion" do
      assert {:error, msg} = Parser.parse("-x")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "bare unary"
      assert msg =~ "return"
    end

    test "bare variable carries position and call/assign suggestion" do
      assert {:error, msg} = Parser.parse("foo")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1, column 1"
      assert msg =~ "bare variable"
      assert msg =~ "name(...)"
      assert msg =~ "name = value"
    end

    test "bare property access carries position and table-access suggestion" do
      assert {:error, msg} = Parser.parse("t.field")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1, column 1"
      assert msg =~ "bare table-access"
      assert msg =~ "t.field = value"
    end

    test "bare index access carries position and table-access suggestion" do
      assert {:error, msg} = Parser.parse("t[1]")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1, column 1"
      assert msg =~ "bare table-access"
    end

    test "bare literal carries position and literal-specific suggestion" do
      assert {:error, msg} = Parser.parse("42")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1, column 1"
      assert msg =~ "bare literal"
    end

    test "bare string literal also classifies as a bare literal" do
      assert {:error, msg} = Parser.parse(~S("hello"))
      assert msg =~ "Parse Error"
      assert msg =~ "bare literal"
    end

    test "bare boolean classifies as a bare literal" do
      assert {:error, msg} = Parser.parse("true")
      assert msg =~ "Parse Error"
      assert msg =~ "bare literal"
    end

    test "bare expression on a later line reports the right line number" do
      code = """
      local x = 1
      local y = 2
      x + y
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "line 3"
      assert msg =~ "bare arithmetic"
    end

    test "the source line is echoed below the error" do
      assert {:error, msg} = Parser.parse("2 + 2")
      # The renderer strips ANSI in plain inspection but keeps the
      # source text. Look for the echo of the offending input.
      assert msg =~ "2 + 2"
    end
  end

  describe "unexpected end of input" do
    test "lone 'local' keyword carries position, not '(no position information)'" do
      assert {:error, msg} = Parser.parse("local")
      assert msg =~ "Parse Error"
      refute msg =~ "(no position information)"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "after 'local'"
    end
  end

  describe "unexpected-token sites carry position" do
    # These sites previously built a malformed 3-tuple
    # `{:unexpected_token, peek(tokens), msg}` instead of the canonical
    # 4-tuple `{:unexpected_token, type, pos, msg}`, falling through to
    # the catch-all converter and rendering as raw Elixir terms with no
    # position. Every site below now produces a positioned error.

    test "table field followed by unexpected operator (the `{ \"ok\" = 5 }` case)" do
      assert {:error, msg} = Parser.parse(~S|return { "ok" = 5 }|)
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected ',' or '}' in table"
      refute msg =~ "(no position information)"
      # The catch-all renders the tuple via inspect/1 — make sure no
      # Elixir term sneaks into the user-facing message.
      refute msg =~ ":unexpected_token"
      refute msg =~ ":operator"
    end

    test "string-keyed table field includes the bracketed-key suggestion" do
      assert {:error, msg} = Parser.parse(~S|return { "ok" = 5 }|)
      assert msg =~ "Suggestion"
      assert msg =~ ~S(["key"] = value)
      assert msg =~ "bracket"
    end

    test "the bracketed-key suggestion only fires for the table-field case" do
      # `if 1 + then ... end` triggers `Expected expression`, which is
      # a different message path. Make sure we don't leak the
      # table-specific suggestion into unrelated errors.
      assert {:error, msg} = Parser.parse("if 1 + then end")
      refute msg =~ "bracketed"
      refute msg =~ ~S(["key"] = value)
    end

    test "numeric-for with no `=` or `in` after the variable" do
      assert {:error, msg} = Parser.parse("for i 1, 10 do end")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected '=' or 'in' after for variable"
      refute msg =~ "(no position information)"
      refute msg =~ ":unexpected_token"
    end

    test "generic-for variable list not terminated by `in`" do
      assert {:error, msg} = Parser.parse("for i, j 1, 10 do end")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected ',' or 'in' in for loop"
      refute msg =~ "(no position information)"
      refute msg =~ ":unexpected_token"
    end

    test "multi-target assignment with a bad continuation token" do
      assert {:error, msg} = Parser.parse("a, b c = 1, 2")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected '=' or ',' in assignment"
      refute msg =~ "(no position information)"
      refute msg =~ ":unexpected_token"
    end

    test "parameter list with a non-identifier token" do
      assert {:error, msg} = Parser.parse("function f(1) end")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected parameter name or ')'"
      refute msg =~ "(no position information)"
      refute msg =~ ":unexpected_token"
    end

    test "parameter list with a leading comma" do
      assert {:error, msg} = Parser.parse("function f(,) end")
      assert msg =~ "Parse Error"
      assert msg =~ "line 1"
      assert msg =~ "column"
      assert msg =~ "Expected parameter name or ')'"
      refute msg =~ "(no position information)"
    end

    test "table-field error on a later line reports the right line" do
      code = """
      local x = 1
      local y = 2
      return { "ok" = 5 }
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "line 3"
      assert msg =~ "Expected ',' or '}' in table"
    end
  end
end
