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

  describe "attempt to perform 'n//0'" do
    test "integer floor-divide by zero" do
      assert_raise LuaRuntimeError, ~r/attempt to perform 'n\/\/0'/, fn ->
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
end
