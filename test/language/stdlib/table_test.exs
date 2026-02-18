defmodule Lua.Language.Stdlib.TableTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "table.unpack with nil third argument", %{lua: lua} do
    assert {[1, 2], _} = Lua.eval!(lua, "return table.unpack({1,2}, 1, nil)")
  end
end
