defmodule Lua.Language.AssertTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "assert returns all arguments", %{lua: lua} do
    assert {[1, 2, 3], _} = Lua.eval!(lua, "return assert(1, 2, 3)")
  end
end
