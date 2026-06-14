defmodule Lua.Parser.ErrorToMapTest do
  use ExUnit.Case, async: true

  alias Lua.Parser
  alias Lua.Parser.Error

  @ansi_escape "\e["

  describe "to_map/1" do
    test "returns the full structured shape with nil source_context when no code given" do
      position = %{line: 3, column: 7, byte_offset: 20}
      error = Error.new(:unexpected_token, "boom", position, suggestion: "try this")

      map = Error.to_map(error)

      assert map == %{
               type: :unexpected_token,
               message: "boom",
               source: nil,
               line: 3,
               call_stack: [],
               source_context: nil,
               suggestion: "try this",
               error_kind: nil
             }
    end

    test "trims trailing newlines from message and suggestion" do
      error = Error.new(:unexpected_end, "ran out\n", nil, suggestion: "add end\n")

      map = Error.to_map(error)

      assert map.message == "ran out"
      assert map.suggestion == "add end"
    end

    test "line and suggestion are nil when absent" do
      error = Error.new(:invalid_syntax, "bad")

      map = Error.to_map(error)

      assert map.line == nil
      assert map.suggestion == nil
      assert map.source_context == nil
    end
  end

  describe "to_map/2 source_context" do
    test "builds a 2-before/2-after window with the real pointer column" do
      position = %{line: 3, column: 4, byte_offset: 0}
      error = Error.new(:unexpected_token, "boom", position)

      map = Error.to_map(error, "a\nb\nc\nd\ne")

      assert %{lines: lines, pointer_column: 4} = map.source_context

      assert lines == [
               %{number: 1, text: "a", highlight?: false},
               %{number: 2, text: "b", highlight?: false},
               %{number: 3, text: "c", highlight?: true},
               %{number: 4, text: "d", highlight?: false},
               %{number: 5, text: "e", highlight?: false}
             ]
    end

    test "clamps the window at the start of the file" do
      position = %{line: 1, column: 1, byte_offset: 0}
      error = Error.new(:unexpected_token, "boom", position)

      map = Error.to_map(error, "a\nb\nc")

      assert Enum.map(map.source_context.lines, & &1.number) == [1, 2, 3]
      assert hd(map.source_context.lines).highlight?
    end

    test "source_context is nil when the line is out of range" do
      position = %{line: 99, column: 1, byte_offset: 0}
      error = Error.new(:unexpected_token, "boom", position)

      assert Error.to_map(error, "a\nb").source_context == nil
    end

    test "pointer_column tracks the real column of a parser-produced error" do
      code = "local x = 1 +"
      {:error, [error]} = Parser.parse_structured(code)

      assert Error.to_map(error, code).source_context.pointer_column == error.position.column
      assert error.position.column > 1
    end
  end

  describe "wire-shape parity and safety" do
    test "shares the same top-level keys as Lua.VM.ErrorFormatter.to_map/3" do
      parse_keys = "x +" |> error!() |> Error.to_map("x +") |> Map.keys() |> Enum.sort()

      formatter_keys =
        :type_error
        |> Lua.VM.ErrorFormatter.to_map("boom", source_code: "a\nb", line: 1)
        |> Map.keys()
        |> Enum.sort()

      assert parse_keys == formatter_keys
    end

    test "no ANSI escapes appear in any string field" do
      map = "if x then" |> error!() |> Error.to_map("if x then")

      refute String.contains?(map.message, @ansi_escape)
      refute String.contains?(map.suggestion || "", @ansi_escape)

      for line <- map.source_context.lines do
        refute String.contains?(line.text, @ansi_escape)
      end
    end
  end

  defp error!(code) do
    {:error, [error]} = Parser.parse_structured(code)
    error
  end
end
