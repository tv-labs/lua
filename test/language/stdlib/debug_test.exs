defmodule Lua.Language.Stdlib.DebugTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "debug.getinfo on native function", %{lua: lua} do
    code = """
    local info = debug.getinfo(print)
    return info.what
    """

    assert {["C"], _} = Lua.eval!(lua, code)
  end

  test "debug.getinfo on Lua function", %{lua: lua} do
    code = """
    local function foo() end
    local info = debug.getinfo(foo)
    return info.what
    """

    assert {["Lua"], _} = Lua.eval!(lua, code)
  end

  test "debug.traceback returns a string", %{lua: lua} do
    code = """
    local tb = debug.traceback("error here")
    return type(tb)
    """

    assert {["string"], _} = Lua.eval!(lua, code)
  end

  test "debug.traceback contains message", %{lua: lua} do
    code = """
    local tb = debug.traceback("my error")
    return tb
    """

    assert {[result], _} = Lua.eval!(lua, code)
    assert String.contains?(result, "my error")
  end

  test "debug.getmetatable bypasses __metatable protection", %{lua: lua} do
    code = """
    local t = {}
    local mt = {__metatable = "protected"}
    setmetatable(t, mt)
    local real_mt = debug.getmetatable(t)
    return type(real_mt)
    """

    assert {["table"], _} = Lua.eval!(lua, code)
  end

  test "debug stubs work without error", %{lua: lua} do
    code = """
    debug.sethook()
    local h, m, c = debug.gethook()
    local name, val = debug.getlocal(1, 1)
    return h, name
    """

    assert {[nil, nil], _} = Lua.eval!(lua, code)
  end
end
