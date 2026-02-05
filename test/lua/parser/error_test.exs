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
      assert msg =~ "\e[31m"  # Red for errors
      assert msg =~ "\e[1m"   # Bold
      assert msg =~ "\e[0m"   # Reset
      assert msg =~ "\e[36m"  # Cyan for suggestions
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
end
