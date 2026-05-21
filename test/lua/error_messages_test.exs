defmodule Lua.ErrorMessagesTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.RuntimeException
  alias Lua.VM
  alias Lua.VM.ArgumentError
  alias Lua.VM.State
  alias Lua.VM.TypeError

  defp error_message(code) do
    Exception.message(assert_raise(RuntimeException, fn -> Lua.eval!(code) end))
  end

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

    test "call-nil error names a global" do
      assert error_message("return foo()") =~ "attempt to call a nil value (global 'foo')"
    end

    test "call-nil error names a local" do
      assert error_message("local x = nil\nx()") =~ "attempt to call a nil value (local 'x')"
    end

    test "call-nil error names an upvalue" do
      code = """
      local x = nil
      local function inner()
        return x()
      end
      return inner()
      """

      assert error_message(code) =~ "attempt to call a nil value (upvalue 'x')"
    end

    test "call-nil error names a field and its receiver" do
      assert error_message("local t = {}\nt.bar()") =~
               "attempt to call a nil value (field 'bar' on local 't')"
    end

    test "call-nil error names a method and its receiver" do
      assert error_message("local t = {}\nt:baz()") =~
               "attempt to call a nil value (method 'baz' on local 't')"
    end

    test "call-nil error names a field on a global receiver" do
      assert error_message("foo = {}\nfoo.bar()") =~
               "attempt to call a nil value (field 'bar' on global 'foo')"
    end

    test "call-nil error names a method on a global receiver" do
      assert error_message("foo = {}\nfoo:baz()") =~
               "attempt to call a nil value (method 'baz' on global 'foo')"
    end

    test "call-nil error on field with anonymous receiver omits receiver clause" do
      msg = error_message("local function f() return {} end\nf().bar()")

      assert msg =~ "attempt to call a nil value (field 'bar')"
      refute msg =~ "on local"
      refute msg =~ "on global"
    end

    test "call non-function error names the callee" do
      assert error_message("x = 5\nx()") =~
               "attempt to call a number value (global 'x')"
    end

    test "index error on undefined global names it" do
      assert error_message("foo.bar()") =~
               "attempt to index a nil value (global 'foo')"
    end

    test "index error on nil local names it (set side)" do
      assert error_message("local t = nil\nt.x = 1") =~
               "attempt to index a nil value (local 't')"
    end

    test "index error on non-table local names it" do
      assert error_message("local n = 5\nreturn n.x") =~
               "attempt to index a number value (local 'n')"
    end

    test "anonymous callee has no name hint" do
      msg = error_message("local t = {}\n;(t.x or t.y)()")

      assert msg =~ "attempt to call a nil value"
      refute msg =~ "(global"
      refute msg =~ "(field"
      refute msg =~ "(local"
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
        assert_raise RuntimeException, fn ->
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
        assert_raise RuntimeException, fn ->
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
        assert_raise RuntimeException, fn ->
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
        assert_raise RuntimeException, fn ->
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
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script)
        end

      assert e.source == "<eval>"
      assert e.message =~ "<eval>:"
    end

    test "source: option threads through to the compiled chunk" do
      e =
        assert_raise RuntimeException, fn ->
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

  describe "stdlib bad-argument raises carry line and source" do
    # A18 wired line/source through every executor raise site and through
    # `assert`/`error` via the native-call boundary process dict. A19
    # extended that pattern to every other stdlib raise — `string.*`,
    # `table.*`, `math.*`, etc. — by having the exception modules
    # themselves auto-populate from `Executor.current_position/0` when
    # `:line`/`:source` aren't passed explicitly. These tests pin the
    # contract: any stdlib bad-arg raise reachable from a Lua execution
    # carries the correct location.

    test "string.upper(nil) carries line and source" do
      script = """
      local x = 1
      local y = 2
      return string.upper(nil)
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      # The wrapped public exception preserves the structured fields.
      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "bad argument #1 to 'string.upper'"
    end

    test "math.floor on string carries line and source" do
      script = """
      local greeting = "hello"
      return math.floor("x")
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "bad argument #1 to 'math.floor'"
    end

    test "table.insert with bad pos carries line and source" do
      script = """
      local t = {1, 2, 3}
      table.insert(t, nil, 99)
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "table.insert"
    end

    test "select with non-numeric index carries line and source" do
      script = """
      local first = 1
      local r = select("bad", 1, 2, 3)
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "select"
    end

    test "setmetatable on non-table carries line and source" do
      script = """
      local n = 5
      setmetatable(n, {})
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line)
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:"
      assert e.message =~ "setmetatable"
    end

    test "ArgumentError raised outside a Lua execution has nil line/source" do
      # Defensive: if anyone calls a stdlib helper directly from Elixir
      # outside of `Lua.eval!`, `current_position/0` returns {nil, nil}
      # and the exception just renders without a location prefix.
      e =
        assert_raise ArgumentError, fn ->
          raise ArgumentError,
            function_name: "outside_lua",
            arg_num: 1,
            expected: "string"
        end

      assert is_nil(e.line)
      assert is_nil(e.source)
      msg = Exception.message(e)
      assert msg =~ "bad argument #1 to 'outside_lua'"
      refute msg =~ ~r/at .+:\d+:/
    end

    test "explicit :line/:source on raise opts override auto-populate" do
      # If a raise site does pass explicit values (because it's outside
      # a Lua execution but knows the right answer somehow), those win.
      e =
        assert_raise ArgumentError, fn ->
          raise ArgumentError,
            function_name: "explicit",
            arg_num: 1,
            expected: "string",
            line: 42,
            source: "explicit.lua"
        end

      assert e.line == 42
      assert e.source == "explicit.lua"
      assert Exception.message(e) =~ "explicit.lua:42"
    end

    test "RuntimeError raised from stdlib (e.g. select out of range) carries line and source" do
      # `select(0, ...)` raises a Lua.VM.RuntimeError with just a value
      # string, no explicit line/source. The exception should still pick
      # them up from the calling Lua position via the auto-populate path.
      script = """
      local x = 1
      return select(0, 1, 2, 3)
      """

      e =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), script, source: "demo.lua")
        end

      assert is_integer(e.line) and e.line > 0
      assert e.source == "demo.lua"
      assert e.message =~ "demo.lua:#{e.line}"
      assert e.message =~ "select"
    end
  end
end
