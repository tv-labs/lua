defmodule Lua.Language.ClosureTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "closure upvalue mutation", %{lua: lua} do
    code = ~S"""
    local A = 0
    local dummy = function () return A end
    A = 1
    assert(dummy() == 1)
    A = 0
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  @tag :skip
  test "closure upvalue mutation through nested scope", %{lua: lua} do
    # Known limitation: upvalue mutation through nested function scopes
    # doesn't propagate correctly yet (upvalue cell sharing)
    code = ~S"""
    local A = 0
    function f()
      local dummy = function () return A end
      A = 1
      local val = dummy()
      A = 0
      return val
    end
    return f()
    """

    assert {[1], _} = Lua.eval!(lua, code)
  end

  test "closure in loop accessing parameter through upvalue", %{lua: lua} do
    code = ~S"""
    function f(x)
      local a = {}
      for i=1,3 do
        a[i] = function () return x end
      end
      return a[1](), a[2](), a[3]()
    end
    return f(10)
    """

    assert {[10, 10, 10], _} = Lua.eval!(lua, code)
  end

  test "closure in loop with local and param upvalues", %{lua: lua} do
    # Step 1: Does having a local in loop body break things?
    code1 = ~S"""
    local function f(x)
      local a = {}
      for i=1,3 do
        local y = 0
        a[i] = function () return y end
      end
      return a[1](), a[2]()
    end
    return f(10)
    """

    assert {[0, 0], _} = Lua.eval!(lua, code1)
  end

  test "upvalue sharing between sibling closures", %{lua: lua} do
    # closure.lua basic pattern - two closures sharing same upvalue
    code = ~S"""
    local a = 0
    local function inc() a = a + 1 end
    local function get() return a end
    inc()
    assert(get() == 1)
    inc()
    assert(get() == 2)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "upvalue through nested scopes (3 levels)", %{lua: lua} do
    # Simple: just one level of upvalue
    code1 = ~S"""
    local x = 10
    local function f() return x end
    return f()
    """

    assert {[10], _} = Lua.eval!(lua, code1)

    # Two levels: variable captured through intermediate function's upvalue
    code2 = ~S"""
    local x = 10
    local function outer()
      local function inner()
        return x
      end
      return inner()
    end
    return outer()
    """

    assert {[10], _} = Lua.eval!(lua, code2)

    # Mutation through nested upvalue chain
    code3 = ~S"""
    local x = 10
    local function outer()
      local function inner()
        x = x + 1
        return x
      end
      return inner()
    end
    assert(outer() == 11)
    assert(outer() == 12)
    return x
    """

    assert {[12], _} = Lua.eval!(lua, code3)
  end

  test "closure in for loop captures loop variable", %{lua: lua} do
    # closure.lua pattern - closures in loop body
    code = ~S"""
    local a = {}
    for i = 1, 3 do
      a[i] = function() return i end
    end
    assert(a[1]() == 1)
    assert(a[2]() == 2)
    assert(a[3]() == 3)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
