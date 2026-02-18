defmodule Lua.Language.FunctionTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "redefine local function with same name", %{lua: lua} do
    code = """
    local function f(x) return x + 1 end
    assert(f(10) == 11)
    local function f(x) return x + 2 end
    assert(f(10) == 12)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "multi-value return register corruption", %{lua: lua} do
    assert {[55, 2], _} =
             Lua.eval!(lua, ~S"""
             function c12(...)
               local x = {...}; x.n = #x
               local res = (x.n==2 and x[1] == 1 and x[2] == 2)
               if res then res = 55 end
               return res, 2
             end
             return c12(1,2)
             """)
  end

  test "select with multi-return function", %{lua: lua} do
    # select(2, load(invalid)) should get the error message from load's two return values
    code = ~S"""
    local function multi() return nil, "error msg" end
    return select(2, multi())
    """

    assert {["error msg"], _} = Lua.eval!(lua, code)
  end
end
