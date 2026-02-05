defmodule Lua.Parser.BeautifulErrorsTest do
  use ExUnit.Case, async: true
  alias Lua.Parser

  @moduletag :beautiful_errors

  describe "beautiful error message demonstrations" do
    test "missing 'end' keyword shows context and suggestion" do
      code = """
      function factorial(n)
        if n <= 1 then
          return 1
        else
          return n * factorial(n - 1)
        -- Missing 'end' here!
      """

      assert {:error, msg} = Parser.parse(code)

      # Check for essential components
      assert msg =~ ~r/Parse Error/i
      assert msg =~ "line"
      assert msg =~ "Expected"
      assert msg =~ "end"

      # Check for visual formatting
      assert msg =~ "│"  # Line separator
      assert msg =~ "^"  # Error pointer

      # Should have ANSI color codes
      assert msg =~ "\e["

      # Print for manual inspection during test runs
      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 1: Missing 'end' keyword")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "missing 'then' keyword provides helpful suggestion" do
      code = """
      if x > 0
        print(x)
      end
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"
      assert msg =~ "Expected"
      assert msg =~ ":then"
      assert msg =~ "line 2"

      # Should show the problematic line
      assert msg =~ "print(x)"

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 2: Missing 'then' keyword")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "unclosed string shows line with error pointer" do
      code = """
      local message = "Hello, World!
      print(message)
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"
      assert msg =~ "Unclosed string"
      assert msg =~ "line 1"

      # Should show suggestion
      assert msg =~ "Suggestion"
      assert msg =~ "closing quote"

      # Should show the unclosed string line
      assert msg =~ ~s(local message = "Hello, World!)

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 3: Unclosed string")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "missing closing parenthesis shows context" do
      code = """
      local function test(a, b
        return a + b
      end
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"
      assert msg =~ "Expected"
      assert msg =~ ":rparen"

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 4: Missing closing parenthesis")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "invalid character shows clear message" do
      code = """
      local x = 42
      local y = @invalid
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"
      assert msg =~ "Unexpected character"
      assert msg =~ "line 2"
      assert msg =~ "@"

      # Should have suggestion
      assert msg =~ "Suggestion"

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 5: Invalid character")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "missing 'do' in while loop" do
      code = """
      while x > 0
        x = x - 1
      end
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"
      assert msg =~ "Expected"
      assert msg =~ ":do"

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 6: Missing 'do' in while loop")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "complex error with multiple context lines" do
      code = """
      function complex_function()
        local x = 10
        local y = 20
        if x > y then
          return x
        -- Missing 'end' for if
        return y
      -- Missing 'end' for function
      """

      assert {:error, msg} = Parser.parse(code)

      assert msg =~ "Parse Error"

      # Error is at EOF (line 9), so context shows lines around line 9
      # Should show the lines that are actually in the context window (lines 7-9)
      assert msg =~ "return y"
      assert msg =~ "-- Missing 'end' for function"

      if System.get_env("SHOW_ERRORS") do
        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("Example 7: Complex error with context")
        IO.puts(String.duplicate("=", 70))
        IO.puts(msg)
        IO.puts(String.duplicate("=", 70) <> "\n")
      end
    end

    test "error message formatting has proper structure" do
      code = "if x then"

      assert {:error, msg} = Parser.parse(code)

      # Check structure components
      assert msg =~ "Parse Error"
      assert msg =~ "at line"
      assert msg =~ "column"

      # Check visual elements
      assert msg =~ "│"  # Box drawing character for line separator
      assert msg =~ "^"  # Pointer to error location

      # Check color codes (ANSI escape sequences)
      assert String.contains?(msg, "\e[31m")  # Red color for error
      assert String.contains?(msg, "\e[0m")   # Reset color
    end
  end

  describe "error message quality checks" do
    test "always includes line and column information when available" do
      code = """
      local x = 1
      if x > 0 then
        print(x
      end
      """

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ ~r/line \d+/
      assert msg =~ ~r/column \d+/
    end

    test "always includes visual pointer to error location" do
      code = "local x = +"

      assert {:error, msg} = Parser.parse(code)
      assert msg =~ "^"  # Caret pointer
    end

    test "shows surrounding context lines" do
      code = """
      line1 = 1
      line2 = 2
      if x then
      line4 = 4
      line5 = 5
      """

      # This will fail to parse due to missing 'end'
      {:error, msg} = Parser.parse(code)

      # Should show lines around the error with box drawing
      assert msg =~ "│"  # Line separator
      assert msg =~ "line"  # Should show context lines
    end

    test "uses colors for better readability" do
      code = "if x then"

      assert {:error, msg} = Parser.parse(code)

      # Red for errors
      assert msg =~ "\e[31m"
      # Bright/bold
      assert msg =~ "\e[1m"
      # Reset
      assert msg =~ "\e[0m"
      # Cyan for suggestions
      assert msg =~ "\e[36m"
    end
  end
end
