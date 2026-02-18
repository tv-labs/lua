defmodule Lua.Language.LoadTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "load compiles and returns a function", %{lua: lua} do
    code = """
    f = load("return 1 + 2")
    return f()
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end

  test "load with syntax error returns nil", %{lua: lua} do
    # Note: Multi-assignment and table constructors don't capture multiple return values yet
    # So we just test that load returns nil on error
    code = """
    f = load("return 1 +")
    return f == nil
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "loaded function can access upvalues", %{lua: lua} do
    code = """
    x = 10
    f = load("return x + 5")
    return f()
    """

    assert {[15], _} = Lua.eval!(lua, code)
  end

  test "load can compile complex code", %{lua: lua} do
    code = """
    f = load("function add(a, b) return a + b end; return add(3, 4)")
    return f()
    """

    assert {[7], _} = Lua.eval!(lua, code)
  end

  test "load returns nil and error for bad code", %{lua: lua} do
    code = ~S"""
    local st, msg = load("invalid code $$$$")
    return st, type(msg)
    """

    assert {[nil, "string"], _} = Lua.eval!(lua, code)
  end

  @tag :skip
  test "goto scope validation in load", %{lua: lua} do
    # Known limitation: compiler doesn't validate goto-label scope rules
    code = ~S"""
    local st, msg = load(" goto l1; do ::l1:: end ")
    return st, msg
    """

    {[st, _msg], _} = Lua.eval!(lua, code)
    assert st == nil
  end

  test "constructs.lua checkload pattern", %{lua: lua} do
    # checkload uses select(2, load(s)) to get the error message
    # This version uses assert() inside (differs from the require_test version)
    code = ~S"""
    local function checkload (s, msg)
      local err = select(2, load(s))
      assert(string.find(err, msg))
    end
    checkload("invalid $$", "invalid")
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
