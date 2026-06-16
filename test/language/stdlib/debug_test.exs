defmodule Lua.Language.Stdlib.DebugTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandbox: false)}
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

  test "debug.getinfo(1, 'n') matches the issue repro", %{lua: lua} do
    code = """
    function F(a)
      assert(debug.getinfo(1, "n").name == 'F')
      return a
    end
    return F(1)
    """

    assert {[1], _} = Lua.eval!(lua, code)
  end

  test "debug.getinfo(1, 'n') classifies namewhat by call form", %{lua: lua} do
    code = """
    local results = {}

    function GlobalFn() return debug.getinfo(1, "n") end
    local g = GlobalFn()
    results[1] = g.name
    results[2] = g.namewhat

    local function LocalFn() return debug.getinfo(1, "n") end
    local l = LocalFn()
    results[3] = l.name
    results[4] = l.namewhat

    local t = {}
    function t.field() return debug.getinfo(1, "n") end
    local f = t.field()
    results[5] = f.name
    results[6] = f.namewhat

    function t:method() return debug.getinfo(1, "n") end
    local m = t:method()
    results[7] = m.name
    results[8] = m.namewhat

    return results[1], results[2], results[3], results[4],
           results[5], results[6], results[7], results[8]
    """

    assert {["GlobalFn", "global", "LocalFn", "local", "field", "field", "method", "method"], _} =
             Lua.eval!(lua, code)
  end

  test "debug.getinfo(1, 'n') leaves name nil when the call carries no hint", %{lua: lua} do
    code = """
    local fns = { function() return debug.getinfo(1, "n") end }
    local info = fns[1]()
    return info.name, info.namewhat
    """

    assert {[nil, ""], _} = Lua.eval!(lua, code)
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

  test "debug.getupvalue reads the _ENV upvalue of a loaded chunk", %{lua: lua} do
    code = """
    local name, val = debug.getupvalue(load"a=3", 1)
    return name, val == _G
    """

    assert {["_ENV", true], _} = Lua.eval!(lua, code)
  end

  test "load honors a custom environment, exposed as _ENV", %{lua: lua} do
    code = """
    local c = {}
    local f = load("a = 3", nil, nil, c)
    local name, val = debug.getupvalue(f, 1)
    local before = c.a
    f()
    return name, val == c, before, c.a
    """

    assert {["_ENV", true, nil, 3], _} = Lua.eval!(lua, code)
  end

  test "debug.getupvalue names captured upvalues and bounds-checks", %{lua: lua} do
    # Every nested function captures `_ENV` as upvalue 1; explicit captures
    # follow in declaration order. `debug.getupvalue(_, 3)` is out of range.
    code = """
    local x = 10
    local function outer() return function() return x end end
    local inner = outer()
    local env_name = debug.getupvalue(inner, 1)
    local name, val = debug.getupvalue(inner, 2)
    return env_name, name, val, debug.getupvalue(inner, 3)
    """

    assert {["_ENV", "x", 10, nil], _} = Lua.eval!(lua, code)
  end

  test "debug.setupvalue mutates an upvalue and returns its name", %{lua: lua} do
    code = """
    local x = 1
    local function getx() return x end
    local name = debug.setupvalue(getx, 2, 99)
    return name, getx()
    """

    assert {["x", 99], _} = Lua.eval!(lua, code)
  end

  test "debug.getupvalue returns nil for non-closures", %{lua: lua} do
    code = """
    return debug.getupvalue(print, 1), debug.getupvalue(42, 1)
    """

    assert {[nil, nil], _} = Lua.eval!(lua, code)
  end
end
