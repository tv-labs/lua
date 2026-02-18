defmodule Lua.Language.StringTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "string concat with shift operator priority", %{lua: lua} do
    # constructs.lua line 35
    code = ~S"""
    assert("7" .. 3 << 1 == 146)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
