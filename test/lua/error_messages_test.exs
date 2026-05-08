defmodule Lua.ErrorMessagesTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.TypeError

  describe "beautiful error messages" do
    test "calling nil value shows helpful error" do
      code = """
      local x = nil
      x()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()

      assert_raise TypeError, fn ->
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
        assert_raise TypeError, fn ->
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
        assert_raise TypeError, fn ->
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
        assert_raise TypeError, fn ->
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

      assert_raise TypeError, ~r/concatenate/, fn ->
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
        assert_raise TypeError, fn ->
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
        assert_raise TypeError, fn ->
          VM.execute(proto, state)
        end

      # Should have line information
      assert error.line
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
        assert_raise TypeError, fn ->
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
          call_stack: [],
          error_kind: :call_nil,
          value_type: nil
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

  describe "Lua.eval! preserves line/source on the public exception" do
    test "arithmetic on string carries line and source" do
      script = """
      local x = 1
      local s = "hello"
      print(s * x)
      """

      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      # The structured fields survive the wrapper. Without these, agents
      # and IDE integrations can only string-scrape the formatted message.
      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "attempt to perform arithmetic on a string value"
    end

    test "indexing a nil value carries line and source" do
      script = """
      local x = nil
      print(x.field)
      """

      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
    end

    test "calling a nil value carries line and source" do
      script = """
      local f = nil
      f()
      """

      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "attempt to call a nil value"
    end

    test "assert(false) from Lua carries line and source" do
      script = """
      local x = -5
      assert(x > 0, "must be positive")
      """

      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "check.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "check.lua"
      assert e.message =~ "check.lua:#{e.line}"
      assert e.message =~ "must be positive"
    end

    test "default source name is <eval> when no source: given" do
      script = "local x = nil\nx()"

      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), script)
        end

      assert e.source == "<eval>"
      assert e.message =~ "<eval>:"
    end

    test "source: option threads through to the compiled chunk" do
      e =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(Lua.new(), "local z = nil\nz()", source: "user_input.lua")
        end

      assert e.source == "user_input.lua"
      assert e.message =~ "user_input.lua:"
    end

    test "successful eval doesn't pay any line-tracking cost on the public path" do
      # Sanity check that wrapping the hot path in try/rescue didn't break
      # successful execution. If this regresses we'll likely see fallout
      # in the rest of the suite, but having the assertion here pins the
      # contract: line tracking is invisible on success.
      assert {[6], _} = Lua.eval!(Lua.new(), "return 1 + 2 + 3")
      assert {[true], _} = Lua.eval!(Lua.new(), "return 'a' == 'a'")
      assert {["hi"], _} = Lua.eval!(Lua.new(), ~s|return "h" .. "i"|)
    end
  end
end
