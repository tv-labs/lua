defmodule Lua.Language.Stdlib.StringTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "string method syntax works", %{lua: lua} do
    assert {["HELLO"], _} = Lua.eval!(lua, ~S[return ("hello"):upper()])
  end

  test "string.method via colon syntax", %{lua: lua} do
    assert {["olleh"], _} = Lua.eval!(lua, ~S[return ("hello"):reverse()])
  end

  test "string indexing for methods", %{lua: lua} do
    code = """
    local s = "hello"
    local f = s.upper
    return f(s)
    """

    assert {["HELLO"], _} = Lua.eval!(lua, code)
  end

  test "string.find empty pattern", %{lua: lua} do
    assert {[1, 0], _} = Lua.eval!(lua, "return string.find('', '')")
    assert {[1, 0], _} = Lua.eval!(lua, "return string.find('alo', '')")
  end

  test "pm.lua early lines", %{lua: lua} do
    code = ~S"""
    local function checkerror (msg, f, ...)
      local s, err = pcall(f, ...)
      assert(not s and string.find(err, msg))
    end

    function f(s, p)
      local i,e = string.find(s, p)
      if i then return string.sub(s, i, e) end
    end

    a,b = string.find('', '')
    assert(a == 1 and b == 0)
    a,b = string.find('alo', '')
    assert(a == 1 and b == 0)
    assert(f("alo", "al") == "al")
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end
end
