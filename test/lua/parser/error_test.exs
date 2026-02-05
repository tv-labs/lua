defmodule Lua.Parser.ErrorTest do
  use ExUnit.Case, async: true
  alias Lua.Parser

  describe "beautiful error messages" do
    test "missing 'end' keyword shows helpful message" do
      code = """
      function foo()
        return 1
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Parse Error")
      assert String.contains?(error_msg, "line 3")
      assert String.contains?(error_msg, "Expected")
      assert String.contains?(error_msg, "'end'")
    end

    test "missing 'then' keyword provides suggestion" do
      code = """
      if x > 0
        return x
      end
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Expected")
      assert String.contains?(error_msg, ":then")
    end

    test "missing 'do' keyword in while loop" do
      code = """
      while x > 0
        x = x - 1
      end
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Expected")
      assert String.contains?(error_msg, ":do")
    end

    test "unclosed string shows context" do
      code = """
      local x = "hello
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Unclosed string")
      assert String.contains?(error_msg, "line 1")
    end

    test "unexpected character shows position" do
      code = """
      local x = 42
      local y = @invalid
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Unexpected character")
      assert String.contains?(error_msg, "line 2")
    end

    test "missing closing parenthesis" do
      code = """
      print(1, 2, 3
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Parse Error")
      # Should mention parenthesis or bracket
    end

    test "missing closing bracket" do
      code = """
      local t = {1, 2, 3
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Parse Error")
    end

    test "shows context with line numbers" do
      code = """
      local x = 1
      local y = 2
      if x > y
        print(x)
      end
      """

      assert {:error, error_msg} = Parser.parse(code)
      # Should show context around the error
      assert String.contains?(error_msg, "│")
    end

    test "unexpected token in expression" do
      code = """
      local x = 1 + + 2
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Parse Error")
    end

    test "invalid syntax after valid code" do
      code = """
      function add(a, b)
        return a + b
      end

      function multiply(x, y
        return x * y
      end
      """

      assert {:error, error_msg} = Parser.parse(code)
      # Error is on line 6 (the return statement) because line 5 is missing closing )
      assert String.contains?(error_msg, "line 6")
    end
  end

  describe "error message formatting" do
    test "formats with color codes for terminal" do
      code = "if x then"

      assert {:error, error_msg} = Parser.parse(code)
      # Color codes should be present (ANSI escape codes)
      assert String.contains?(error_msg, "\e[")
    end

    test "shows helpful suggestions" do
      code = """
      function test()
        print("hello")
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "Suggestion")
    end

    test "includes line and column information" do
      code = """
      local x = 1
      if x > 0 then
        print(x
      end
      """

      assert {:error, error_msg} = Parser.parse(code)
      assert String.contains?(error_msg, "line")
      assert String.contains?(error_msg, "column")
    end
  end

  describe "raw error parsing" do
    test "parse_raw returns structured error" do
      code = "if x then"

      assert {:error, error_tuple} = Parser.parse_raw(code)
      # Should be a tuple, not a formatted string
      assert is_tuple(error_tuple)
    end

    test "parse_raw successful parsing" do
      code = "local x = 42"

      assert {:ok, chunk} = Parser.parse_raw(code)
      assert chunk.__struct__ == Lua.AST.Chunk
    end
  end
end
