defmodule Lua.Language.RequireTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "require 'string' returns string table", %{lua: lua} do
    code = """
    local s = require("string")
    return type(s), type(s.upper)
    """

    assert {["table", "function"], _} = Lua.eval!(lua, code)
  end

  test "require 'math' returns math table", %{lua: lua} do
    code = """
    local m = require("math")
    return type(m), m.pi > 3
    """

    assert {["table", true], _} = Lua.eval!(lua, code)
  end

  test "require 'debug' returns debug table", %{lua: lua} do
    code = """
    local d = require("debug")
    return type(d), type(d.getinfo)
    """

    assert {["table", "function"], _} = Lua.eval!(lua, code)
  end

  test "constructs.lua checkload pattern", %{lua: lua} do
    # checkload uses select(2, load(s)) to get the error message
    code = ~S"""
    local function checkload (s, msg)
      local err = select(2, load(s))
      string.find(err, msg)
    end
    return checkload("invalid $$", "invalid")
    """

    assert {[], _} = Lua.eval!(lua, code)
  end
end
