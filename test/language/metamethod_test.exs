defmodule Lua.Language.MetamethodTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "function __index is called on missing key", %{lua: lua} do
    code = """
    local t = {}
    local mt = {__index = function(tbl, key) return key .. "!" end}
    setmetatable(t, mt)
    return t.hello, t.world
    """

    assert {["hello!", "world!"], _} = Lua.eval!(lua, code)
  end

  test "function __newindex is called on new key", %{lua: lua} do
    code = """
    local log = {}
    local t = {}
    local mt = {__newindex = function(tbl, key, val) log[#log + 1] = key .. "=" .. tostring(val) end}
    setmetatable(t, mt)
    t.x = 10
    t.y = 20
    return log[1], log[2]
    """

    assert {["x=10", "y=20"], _} = Lua.eval!(lua, code)
  end

  test "__index chain follows tables", %{lua: lua} do
    code = """
    local base = {greeting = "hello"}
    local mid = {}
    setmetatable(mid, {__index = base})
    local top = {}
    setmetatable(top, {__index = mid})
    return top.greeting
    """

    assert {["hello"], _} = Lua.eval!(lua, code)
  end

  test "existing keys bypass __index", %{lua: lua} do
    code = """
    local t = {x = 1}
    setmetatable(t, {__index = function() return 999 end})
    return t.x
    """

    assert {[1], _} = Lua.eval!(lua, code)
  end

  test "existing keys bypass __newindex", %{lua: lua} do
    code = """
    local called = false
    local t = {x = 1}
    setmetatable(t, {__newindex = function() called = true end})
    t.x = 2
    return t.x, called
    """

    assert {[2, false], _} = Lua.eval!(lua, code)
  end

  test "table with __call can be called as function", %{lua: lua} do
    code = """
    local t = {}
    setmetatable(t, {__call = function(self, a, b) return a + b end})
    return t(3, 4)
    """

    assert {[7], _} = Lua.eval!(lua, code)
  end

  test "__call receives self as first argument", %{lua: lua} do
    code = """
    local t = {value = 10}
    setmetatable(t, {__call = function(self) return self.value end})
    return t()
    """

    assert {[10], _} = Lua.eval!(lua, code)
  end

  test "tostring uses __tostring metamethod", %{lua: lua} do
    code = """
    local t = {name = "foo"}
    setmetatable(t, {__tostring = function(self) return "MyObj(" .. self.name .. ")" end})
    return tostring(t)
    """

    assert {["MyObj(foo)"], _} = Lua.eval!(lua, code)
  end

  test "print uses __tostring metamethod", %{lua: lua} do
    code = """
    local t = {}
    setmetatable(t, {__tostring = function() return "custom" end})
    return tostring(t)
    """

    assert {["custom"], _} = Lua.eval!(lua, code)
  end

  test "getmetatable returns __metatable sentinel", %{lua: lua} do
    code = """
    local t = {}
    setmetatable(t, {__metatable = "protected"})
    return getmetatable(t)
    """

    assert {["protected"], _} = Lua.eval!(lua, code)
  end

  test "setmetatable errors on protected metatable", %{lua: lua} do
    code = """
    local t = {}
    setmetatable(t, {__metatable = "protected"})
    local ok = pcall(setmetatable, t, {})
    return ok
    """

    assert {[false], _} = Lua.eval!(lua, code)
  end
end
