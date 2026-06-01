defmodule Lua.VM.ErrorToMapTest do
  use ExUnit.Case, async: true

  alias Lua.VM.AssertionError, as: VMAssertionError
  alias Lua.VM.ErrorFormatter
  alias Lua.VM.RuntimeError, as: VMRuntimeError
  alias Lua.VM.TypeError, as: VMTypeError

  @ansi_escape "\e["

  describe "Lua.VM.RuntimeError.to_map/2" do
    test "returns the full structured shape" do
      error =
        VMRuntimeError.exception(
          value: "boom",
          source: "t.lua",
          line: 3,
          call_stack: [%{source: "t.lua", line: 3, name: "fn1"}]
        )

      map = VMRuntimeError.to_map(error)

      assert map.type == :runtime_error
      assert map.message == "runtime error: boom"
      assert map.source == "t.lua"
      assert map.line == 3
      assert map.call_stack == [%{source: "t.lua", line: 3, name: "fn1"}]
      assert map.source_context == nil
      assert map.suggestion == nil
      assert map.error_kind == nil
    end

    test "source_context is populated when source_code is passed" do
      error = VMRuntimeError.exception(value: "boom", source: "t.lua", line: 2)

      map = VMRuntimeError.to_map(error, source_code: "a\nb\nc")

      assert %{lines: lines, pointer_column: 1} = map.source_context
      assert length(lines) == 3
      assert Enum.at(lines, 0) == %{number: 1, text: "a", highlight?: false}
      assert Enum.at(lines, 1) == %{number: 2, text: "b", highlight?: true}
      assert Enum.at(lines, 2) == %{number: 3, text: "c", highlight?: false}
    end

    test "no ANSI escape sequences appear in any string field" do
      error =
        VMRuntimeError.exception(
          value: "boom",
          source: "t.lua",
          line: 2,
          call_stack: [%{source: "t.lua", line: 2, name: "fn1"}]
        )

      map = VMRuntimeError.to_map(error, source_code: "a\nb\nc")

      refute String.contains?(map.message, @ansi_escape)

      for line <- map.source_context.lines do
        refute String.contains?(line.text, @ansi_escape)
      end
    end
  end

  describe "Lua.VM.TypeError.to_map/2" do
    test "carries through :error_kind and :value_type, and emits a plain suggestion" do
      error =
        VMTypeError.exception(
          value: "attempt to call a nil value",
          source: "t.lua",
          line: 4,
          error_kind: :call_nil
        )

      map = VMTypeError.to_map(error)

      assert map.type == :type_error
      assert map.error_kind == :call_nil
      assert is_binary(map.suggestion)
      refute String.contains?(map.suggestion, @ansi_escape)
      assert map.message == "attempt to call a nil value"
    end

    test "value_type informs suggestion text" do
      error =
        VMTypeError.exception(
          value: "attempt to index a number value",
          source: "t.lua",
          line: 1,
          error_kind: :index_non_table,
          value_type: :number
        )

      map = VMTypeError.to_map(error)

      assert map.suggestion =~ "number"
      refute String.contains?(map.suggestion, @ansi_escape)
    end

    test ":length_not_integer suggestion addresses the non-integer result" do
      error =
        VMTypeError.exception(
          value: "object length is not an integer",
          source: "t.lua",
          line: 1,
          error_kind: :length_not_integer,
          value_type: :number
        )

      map = VMTypeError.to_map(error)

      assert map.suggestion =~ "non-integer"
      assert map.suggestion =~ "__len"
    end
  end

  describe "Lua.VM.AssertionError.to_map/2" do
    test "carries the message and no filler suggestion" do
      error = VMAssertionError.exception(value: "expected true", source: "t.lua", line: 1)

      map = VMAssertionError.to_map(error)

      assert map.type == :assertion_error
      assert map.message == "assertion failed: expected true"
      # Assertions no longer carry a generic "check your logic" suggestion;
      # the message body already says what failed.
      assert map.suggestion == nil
      assert map.error_kind == nil
    end
  end

  describe "Lua.VM.ErrorFormatter.format/3 stability" do
    # Golden snapshots locking the rendered output. The test suite runs with
    # ANSI disabled, so these pin the plain-text render: location first, no
    # redundant header, category-specific suggestion. If a refactor changes
    # what callers see, these fail loudly.

    test "ANSI is gated on IO.ANSI.enabled?" do
      refute IO.ANSI.enabled?(), "test env should have ANSI disabled"
      output = ErrorFormatter.format(:type_error, "attempt to call a nil value", source: "t.lua", line: 2)
      refute String.contains?(output, @ansi_escape)
    end

    test "type_error leads with location and emits a category suggestion" do
      output =
        ErrorFormatter.format(:type_error, "attempt to call a nil value",
          source: "t.lua",
          line: 2,
          source_code: "local x\nx()\nreturn 0",
          call_stack: [%{source: "t.lua", line: 2, name: nil}],
          error_kind: :call_nil
        )

      expected =
        "at t.lua:2:\n\n  attempt to call a nil value\n\n   1 │ local x\n   2 │ x()       ^\n   3 │ return 0\n\nStack trace:\n  t.lua:2: in main chunk\n\nSuggestion:\n  The value you're trying to call as a function is nil. Check that the function exists and is defined before this point."

      assert output == expected
    end

    test "runtime_error with no source_code or suggestion" do
      output =
        ErrorFormatter.format(:runtime_error, "runtime error: boom",
          source: "t.lua",
          line: 1,
          call_stack: [%{source: "t.lua", line: 1, name: "f"}]
        )

      expected =
        "at t.lua:1:\n\n  runtime error: boom\n\nStack trace:\n  t.lua:1: in function 'f'"

      assert output == expected
    end

    test "assertion_error carries the body and no filler suggestion" do
      output = ErrorFormatter.format(:assertion_error, "assertion failed: nope")

      assert output == "assertion failed: nope"
    end
  end
end
