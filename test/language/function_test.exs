defmodule Lua.Language.FunctionTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandbox: false)}
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

  test "method call expands table.unpack in tail position", %{lua: lua} do
    code = ~S"""
    local t = {}
    function t:m(...) return select('#', ...) end
    local vals = {"a", "b", "c"}
    return t:m(table.unpack(vals))
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end

  test "method call expands vararg in tail position", %{lua: lua} do
    code = ~S"""
    local t = {}
    function t:m(...) return select('#', ...) end
    local function wrap(...) return t:m(...) end
    return wrap("a", "b", "c")
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end

  test "method call expands inner call in tail position", %{lua: lua} do
    code = ~S"""
    local t = {}
    function t:m(...) return select('#', ...) end
    local function three() return 1, 2, 3 end
    return t:m(three())
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end

  test "method call expands table.unpack with leading fixed args", %{lua: lua} do
    code = ~S"""
    local t = {}
    function t:m(x, ...) return x, select('#', ...) end
    return t:m("first", table.unpack({"a","b","c"}))
    """

    assert {["first", 3], _} = Lua.eval!(lua, code)
  end

  test "string:format with table.unpack expands all values", %{lua: lua} do
    code = ~S"""
    local args = {"a", "b", "c"}
    return ("[%s,%s,%s]"):format(table.unpack(args))
    """

    assert {["[a,b,c]"], _} = Lua.eval!(lua, code)
  end
end
