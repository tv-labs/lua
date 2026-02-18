defmodule Lua.Language.AssignmentTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "vararg.lua early lines", %{lua: lua} do
    code = ~S"""
    function f(a, ...)
      local arg = {n = select('#', ...), ...}
      for i=1,arg.n do assert(a[i]==arg[i]) end
      return arg.n
    end
    assert(f() == 0)
    return f({1,2,3}, 1, 2, 3) == 3
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
