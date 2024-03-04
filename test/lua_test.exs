defmodule LuaTest do
  use ExUnit.Case
  doctest Lua

  test "greets the world" do
    assert Lua.hello() == :world
  end
end
