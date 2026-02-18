defmodule Lua.Language.GlobalTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "_G references the global environment", %{lua: lua} do
    # _G should be a table that contains itself
    assert {[true], _} = Lua.eval!(lua, "return _G ~= nil")
    assert {[true], _} = Lua.eval!(lua, "return type(_G) == 'table'")
  end

  test "_G contains global functions", %{lua: lua} do
    # Standard functions should be accessible via _G
    assert {[true], _} = Lua.eval!(lua, "return _G.print == print")
    assert {[true], _} = Lua.eval!(lua, "return _G.type == type")
    assert {[true], _} = Lua.eval!(lua, "return _G.tostring == tostring")
  end

  test "_G contains itself", %{lua: lua} do
    # _G._G should reference _G
    assert {[true], _} = Lua.eval!(lua, "return _G._G == _G")
  end

  test "can set globals via _G", %{lua: lua} do
    code = """
    _G.myvar = 42
    return myvar
    """

    assert {[42], _} = Lua.eval!(lua, code)
  end

  test "can read globals via _G", %{lua: lua} do
    code = """
    myvar = 123
    return _G.myvar
    """

    assert {[123], _} = Lua.eval!(lua, code)
  end
end
