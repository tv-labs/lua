defmodule Lua.Language.MathTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "priority: power vs multiply", %{lua: lua} do
    code = ~S"""
    return 2^3*4 == (2^3)*4
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "constructs.lua priorities", %{lua: lua} do
    assert {[true], _} = Lua.eval!(lua, "return 2^3^2 == 2^(3^2)")
    assert {[true], _} = Lua.eval!(lua, "return 2^3*4 == (2^3)*4")
    assert {[true], _} = Lua.eval!(lua, "return 2.0^-2 == 1/4")
    assert {[true], _} = Lua.eval!(lua, "return -2^2 == -4 and (-2)^2 == 4")
  end

  test "priority: power is right-associative", %{lua: lua} do
    code = ~S"""
    return 2^3^2 == 2^(3^2)
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "hex float literals", %{lua: lua} do
    assert {[240.0], _} = Lua.eval!(lua, "return 0xF0.0")
    assert {[343.5], _} = Lua.eval!(lua, "return 0xABCp-3")
    assert {[1.0], _} = Lua.eval!(lua, "return 0x1p0")
    assert {[255], _} = Lua.eval!(lua, "return 0xFF")
  end

  test "float literal edge cases", %{lua: lua} do
    code = ~S"""
    assert(.0 == 0)
    assert(0. == 0)
    assert(.2e2 == 20)
    assert(2.E-1 == 0.2)
    assert(0e12 == 0)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "bitwise.lua early pattern - pcall catches bitwise error", %{lua: lua} do
    # Test pcall catches bitwise error and the checkerror pattern works
    code = ~S"""
    local s, err = pcall(function() return 1 | nil end)
    assert(not s)
    assert(type(err) == "string")

    -- Test the checkerror pattern used by many suite tests
    local function checkerror(msg, f, ...)
      local s, err = pcall(f, ...)
      assert(not s and string.find(err, msg))
    end
    checkerror("nil", function() return 1 | nil end)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
