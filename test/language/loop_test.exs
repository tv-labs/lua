defmodule Lua.Language.LoopTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "loops with external variables", %{lua: lua} do
    code = ~S"""
    function run(n)
      for i = 1, n do
        local obj = {}   -- overwrites limit register → infinite loop
      end
      return n
    end
    return run(3)
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end
end
