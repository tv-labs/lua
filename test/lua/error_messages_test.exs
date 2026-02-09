defmodule Lua.ErrorMessagesTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler, VM}
  alias Lua.VM.State

  describe "beautiful error messages" do
    test "calling nil value shows helpful error" do
      code = """
      local x = nil
      x()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "calling non-function value shows type" do
      code = """
      local x = 5
      x()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      assert error.message =~ "number"
    end

    test "error message includes source location" do
      code = """
      local f = nil
      f()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "my_script.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      assert error.source == "my_script.lua"
    end

    test "error with nested function calls shows stack trace" do
      code = """
      local inner = function()
        local x = nil
        return x()
      end

      local outer = function()
        return inner()
      end

      return outer()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      # Should have call stack
      assert is_list(error.call_stack)
      assert length(error.call_stack) > 0
    end

    test "concatenation type error" do
      code = """
      local t = {}
      return "hello" .. t
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      assert_raise Lua.VM.TypeError, ~r/concatenate/, fn ->
        VM.execute(proto, state)
      end
    end

    test "error formatter produces readable output" do
      code = """
      local function bad()
        local x = nil
        return x()
      end

      return bad()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "error_test.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      # Error message should be a formatted string
      assert is_binary(error.message)
      # Should contain error type
      assert error.message =~ ~r/Error/i
    end
  end

  describe "error context" do
    test "tracks line numbers" do
      code = """
      local x = 1
      local y = 2
      local z = nil
      z()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      # Should have line information
      assert error.line != nil
      assert error.line > 0
    end

    test "includes call stack in nested calls" do
      code = """
      local a = function()
        local nilval = nil
        return nilval()
      end

      local b = function()
        return a()
      end

      local c = function()
        return b()
      end

      return c()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "nested.lua")

      state = State.new()

      error =
        assert_raise Lua.VM.TypeError, fn ->
          VM.execute(proto, state)
        end

      # Should track multiple stack frames
      assert length(error.call_stack) >= 2
    end
  end

  describe "error formatter" do
    test "formats type errors nicely" do
      alias Lua.VM.ErrorFormatter

      message = "attempt to call a nil value"
      formatted = ErrorFormatter.format(:type_error, message, source: "test.lua", line: 5)

      assert formatted =~ "Runtime Type Error"
      assert formatted =~ "test.lua"
      assert formatted =~ "5"
    end

    test "includes suggestions for common errors" do
      alias Lua.VM.ErrorFormatter

      message = "attempt to call a nil value"

      formatted =
        ErrorFormatter.format(:type_error, message,
          source: "test.lua",
          line: 3,
          call_stack: []
        )

      assert formatted =~ "Suggestion"
    end

    test "formats stack traces" do
      alias Lua.VM.ErrorFormatter

      call_stack = [
        %{source: "test.lua", line: 10, name: nil},
        %{source: "test.lua", line: 5, name: "helper"}
      ]

      formatted =
        ErrorFormatter.format(:type_error, "some error",
          source: "test.lua",
          line: 3,
          call_stack: call_stack
        )

      assert formatted =~ "Stack trace"
      assert formatted =~ "test.lua:10"
      assert formatted =~ "test.lua:5"
      assert formatted =~ "helper"
    end
  end
end
