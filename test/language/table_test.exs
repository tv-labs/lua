defmodule Lua.Language.TableTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "table constructors with semicolons", %{lua: lua} do
    # Can retrieve values from tables with explicit fields using semicolons
    code = """
    t = {1, 2; n=2}
    return t[1], t[2], t.n
    """

    assert {[1, 2, 2], _} = Lua.eval!(lua, code)

    # Mixed commas and semicolons
    code = """
    t = {1; 2, 3}
    return t[1], t[2], t[3]
    """

    assert {[1, 2, 3], _} = Lua.eval!(lua, code)
  end

  test "table constructor with vararg expansion", %{lua: lua} do
    code = ~S"""
    function f(a, ...)
      local arg = {n = select('#', ...), ...}
      return arg.n, arg[1], arg[2]
    end
    return f({}, 10, 20)
    """

    assert {[2, 10, 20], _} = Lua.eval!(lua, code)
  end

  test "multi-return in table constructor", %{lua: lua} do
    # Last expression in table constructor should expand
    code = ~S"""
    local function multi() return 10, 20, 30 end
    local t = {multi()}
    return t[1], t[2], t[3]
    """

    assert {[10, 20, 30], _} = Lua.eval!(lua, code)

    # With init values before the call
    code = ~S"""
    local function multi() return 20, 30 end
    local t = {10, multi()}
    return t[1], t[2], t[3]
    """

    assert {[10, 20, 30], _} = Lua.eval!(lua, code)

    # Call NOT in last position should only return first value
    code = ~S"""
    local function multi() return 10, 20, 30 end
    local t = {multi(), 99}
    return t[1], t[2]
    """

    assert {[10, 99], _} = Lua.eval!(lua, code)
  end
end
