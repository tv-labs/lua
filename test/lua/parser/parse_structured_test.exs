defmodule Lua.Parser.ParseStructuredTest do
  use ExUnit.Case, async: true

  alias Lua.AST.Chunk
  alias Lua.Parser
  alias Lua.Parser.Error

  describe "parse_structured/1 success" do
    test "returns the chunk on valid source" do
      assert {:ok, %Chunk{}} = Parser.parse_structured("local x = 42\nreturn x")
    end
  end

  describe "parse_structured/1 errors" do
    test "wraps a single converted error struct in a list" do
      assert {:error, [%Error{} = error]} = Parser.parse_structured("if x then")
      assert error.type == :unexpected_token
      assert error.position.line == 1
    end

    test "reports an unclosed delimiter against the opening position" do
      assert {:error, [error]} = Parser.parse_structured("local x = (1")
      assert error.type == :unclosed_delimiter
      assert error.position == %{line: 1, column: 11, byte_offset: 10}
    end

    test "surfaces lexer errors as structured errors" do
      assert {:error, [error]} = Parser.parse_structured("@")
      assert error.type == :invalid_syntax
      assert error.message =~ "Unexpected character"
    end

    test "reports a bare expression as invalid syntax" do
      assert {:error, [error]} = Parser.parse_structured("1 + 1")
      assert error.type == :invalid_syntax
      assert error.position.column == 3
    end
  end

  describe "parse/1 and parse_structured/1 agree" do
    # The display and structured paths share `parse_to_error/1`, so the
    # formatted string must always reflect the same underlying error.
    test "formatted output matches the structured struct's formatting" do
      code = "if x then"

      {:error, formatted} = Parser.parse(code)
      {:error, [error]} = Parser.parse_structured(code)

      assert formatted == Error.format(error, code)
    end
  end
end
