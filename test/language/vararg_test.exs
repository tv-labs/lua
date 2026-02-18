defmodule Lua.Language.VarargTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "simple varargs function", %{lua: lua} do
    code = """
    function f(...)
      return ...
    end
    return f(1, 2, 3)
    """

    assert {[1, 2, 3], _} = Lua.eval!(lua, code)
  end

  test "varargs with regular parameters", %{lua: lua} do
    code = """
    function f(a, b, ...)
      return a, b, ...
    end
    return f(1, 2, 3, 4, 5)
    """

    assert {[1, 2, 3, 4, 5], _} = Lua.eval!(lua, code)
  end

  test "varargs in table constructor", %{lua: lua} do
    code = """
    function f(...)
      return {...}
    end
    t = f(1, 2, 3)
    return t[1], t[2], t[3]
    """

    assert {[1, 2, 3], _} = Lua.eval!(lua, code)
  end

  test "mixed values and varargs in table", %{lua: lua} do
    code = """
    function f(...)
      local t = {10, 20, ...}
      return t[1], t[2], t[3], t[4]
    end
    return f(30, 40)
    """

    assert {[10, 20, 30, 40], _} = Lua.eval!(lua, code)
  end

  test "varargs with select", %{lua: lua} do
    code = """
    function f(...)
      return select('#', ...), select(2, ...)
    end
    return f(10, 20, 30)
    """

    # In Lua 5.3, the last call in a return list expands all its results.
    # select(2, 10, 20, 30) returns 20, 30
    assert {[3, 20, 30], _} = Lua.eval!(lua, code)
  end

  test "varargs in function call", %{lua: lua} do
    code = """
    function g(a, b, c)
      return a + b + c
    end
    function f(...)
      return g(...)
    end
    return f(1, 2, 3)
    """

    assert {[6], _} = Lua.eval!(lua, code)
  end

  test "empty varargs", %{lua: lua} do
    code = """
    function f(...)
      return select('#', ...)
    end
    return f()
    """

    assert {[0], _} = Lua.eval!(lua, code)
  end

  test "select('#', ...) returns count of arguments", %{lua: lua} do
    assert {[3], _} = Lua.eval!(lua, "return select('#', 1, 2, 3)")
    assert {[0], _} = Lua.eval!(lua, "return select('#')")
    assert {[5], _} = Lua.eval!(lua, "return select('#', nil, nil, 1, nil, 2)")
  end

  test "select(n, ...) returns arguments starting from index n", %{lua: lua} do
    # Direct return works (no local assignment)
    assert {[20, 30], _} = Lua.eval!(lua, "return select(2, 10, 20, 30)")
    assert {[30], _} = Lua.eval!(lua, "return select(3, 10, 20, 30)")
    assert {[10, 20, 30], _} = Lua.eval!(lua, "return select(1, 10, 20, 30)")
  end

  test "select with negative index counts from end", %{lua: lua} do
    assert {[30], _} = Lua.eval!(lua, "return select(-1, 10, 20, 30)")
    assert {[20, 30], _} = Lua.eval!(lua, "return select(-2, 10, 20, 30)")
    assert {[10, 20, 30], _} = Lua.eval!(lua, "return select(-3, 10, 20, 30)")
  end

  test "select works with varargs passed to other functions", %{lua: lua} do
    # This requires proper varargs expansion in function calls (VM limitation)
    code = """
    function get_second_onward(a, ...)
      return select(1, ...)
    end
    return get_second_onward(10, 20, 30, 40)
    """

    assert {[20, 30, 40], _} = Lua.eval!(lua, code)
  end

  test "vararg expansion in local multi-assignment", %{lua: lua} do
    code = ~S"""
    function f(...)
      local a, b, c = ...
      return a, b, c
    end
    return f(10, 20, 30)
    """

    assert {[10, 20, 30], _} = Lua.eval!(lua, code)
  end

  test "vararg expansion in regular multi-assignment", %{lua: lua} do
    code = ~S"""
    function f(a, ...)
      local b, c, d = ...
      return a, b, c, d
    end
    return f(5, 4, 3, 2, 1)
    """

    assert {[5, 4, 3, 2], _} = Lua.eval!(lua, code)
  end

  test "vararg.lua new-style varargs", %{lua: lua} do
    code = ~S"""
    function oneless (a, ...) return ... end

    function f (n, a, ...)
      local b
      if n == 0 then
        local b, c, d = ...
        return a, b, c, d, oneless(oneless(oneless(...)))
      else
        n, b, a = n-1, ..., a
        assert(b == ...)
        return f(n, a, ...)
      end
    end

    a,b,c,d,e = assert(f(10,5,4,3,2,1))
    assert(a==5 and b==4 and c==3 and d==2 and e==1)

    a,b,c,d,e = f(4)
    assert(a==nil and b==nil and c==nil and d==nil and e==nil)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
