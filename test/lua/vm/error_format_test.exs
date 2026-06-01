defmodule Lua.VM.ErrorFormatTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.ArgumentError, as: LuaArgumentError
  alias Lua.VM.RuntimeError, as: LuaRuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError, as: LuaTypeError

  defp run(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    VM.execute(proto, state)
  end

  # Pins the PUC-Lua-aligned error templates listed in issue #252.
  # Each test guards one wording the official Lua 5.3 suite greps for via
  # checkerror/checkmessage. Loosening any of these will silently break
  # suite progress.

  describe "wrong number of arguments to 'X'" do
    test "table.insert with too many args" do
      assert_raise LuaRuntimeError, ~r/wrong number of arguments to 'insert'/, fn ->
        run("return table.insert({}, 2, 3, 4)")
      end
    end
  end

  describe "bad argument #N to 'X' (T expected, got T)" do
    test "math.abs with string" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #1 to 'math\.abs' \(number expected, got string\)/,
                   fn -> run("return math.abs('foo')") end
    end

    test "string.sub with non-integer index" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #2 to 'string\.sub' \(number expected\)/,
                   fn -> run("return string.sub('abc', 'x')") end
    end

    test "table.insert with non-table first arg" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #1 to 'table\.insert' \(table expected, got number\)/,
                   fn -> run("return table.insert(1, 2)") end
    end
  end

  describe "value expected" do
    test "math.abs with no args" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #1 to 'math\.abs' \(value expected\)/,
                   fn -> run("return math.abs()") end
    end
  end

  describe "attempt to divide by zero" do
    test "integer floor-divide by zero" do
      assert_raise LuaRuntimeError, ~r/attempt to divide by zero/, fn ->
        run("return 1 // 0")
      end
    end
  end

  describe "attempt to perform 'n%0'" do
    test "integer modulo by zero" do
      assert_raise LuaRuntimeError, ~r/attempt to perform 'n%0'/, fn ->
        run("return 1 % 0")
      end
    end
  end

  describe "number has no integer representation" do
    test "bitwise on a non-representable float" do
      assert_raise LuaTypeError, ~r/has no integer representation/, fn ->
        run("return (2.5) | 0")
      end
    end

    test "bitwise on math.huge surfaces the same template" do
      assert_raise LuaTypeError, ~r/has no integer representation/, fn ->
        run("return math.huge << 1")
      end
    end
  end

  # PUC-Lua appends `(global 'X')` / `(local 'X')` / `(upvalue 'X')` /
  # `(field 'X')` to arithmetic and bitwise type errors when the failing
  # operand's lexical origin is recoverable. We resolve at compile time
  # and bake the hint into the instruction tuple — see codegen
  # `name_hint/2` and `format_target_hint/1` in the executor.
  describe "arithmetic type error carries operand hint" do
    test "global operand surfaces (global 'X')" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform arithmetic on a nil value \(global 'foo'\)/,
                   fn -> run("return foo + 1") end
    end

    test "local operand surfaces (local 'X')" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform arithmetic on a nil value \(local 'x'\)/,
                   fn -> run("local x; return x + 1") end
    end

    test "field operand surfaces (field 'X')" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform arithmetic on a nil value \(field 'x'/,
                   fn -> run("local t = {}; return t.x + 1") end
    end

    test "upvalue operand surfaces (upvalue 'X')" do
      code = """
      local y
      local function f() return y + 1 end
      return f()
      """

      assert_raise LuaTypeError,
                   ~r/attempt to perform arithmetic on a nil value \(upvalue 'y'\)/,
                   fn -> run(code) end
    end

    test "unary minus on a nil local surfaces the hint" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform arithmetic on a nil value \(local 'x'\)/,
                   fn -> run("local x; return -x") end
    end
  end

  describe "bitwise type error carries operand hint" do
    test "shift on a string local surfaces (local 'X')" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform bitwise operation on a string value \(local 's'\)/,
                   fn -> run("local s = 'x'; return s << 1") end
    end

    test "bnot on a nil global surfaces (global 'X')" do
      assert_raise LuaTypeError,
                   ~r/attempt to perform bitwise operation on a nil value \(global 'foo'\)/,
                   fn -> run("return ~foo") end
    end

    test "non-representable float through a field surfaces (field 'X')" do
      assert_raise LuaTypeError,
                   ~r/number has no integer representation \(field 'huge'/,
                   fn -> run("return math.huge << 1") end
    end
  end
end
