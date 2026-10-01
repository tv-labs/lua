defmodule Lua.Language.LoadTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "load compiles and returns a function", %{lua: lua} do
    code = """
    f = load("return 1 + 2")
    return f()
    """

    assert {[3], _} = Lua.eval!(lua, code)
  end

  test "load with syntax error returns nil", %{lua: lua} do
    # Note: Multi-assignment and table constructors don't capture multiple return values yet
    # So we just test that load returns nil on error
    code = """
    f = load("return 1 +")
    return f == nil
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "loaded function can access upvalues", %{lua: lua} do
    code = """
    x = 10
    f = load("return x + 5")
    return f()
    """

    assert {[15], _} = Lua.eval!(lua, code)
  end

  test "load can compile complex code", %{lua: lua} do
    code = """
    f = load("function add(a, b) return a + b end; return add(3, 4)")
    return f()
    """

    assert {[7], _} = Lua.eval!(lua, code)
  end

  test "load returns nil and error for bad code", %{lua: lua} do
    code = ~S"""
    local st, msg = load("invalid code $$$$")
    return st, type(msg)
    """

    assert {[nil, "string"], _} = Lua.eval!(lua, code)
  end

  @tag :skip
  test "goto scope validation in load", %{lua: lua} do
    # Known limitation: compiler doesn't validate goto-label scope rules
    code = ~S"""
    local st, msg = load(" goto l1; do ::l1:: end ")
    return st, msg
    """

    {[st, _msg], _} = Lua.eval!(lua, code)
    assert st == nil
  end

  test "constructs.lua checkload pattern", %{lua: lua} do
    # checkload uses select(2, load(s)) to get the error message
    # This version uses assert() inside (differs from the require_test version)
    code = ~S"""
    local function checkload (s, msg)
      local err = select(2, load(s))
      assert(string.find(err, msg))
    end
    checkload("invalid $$", "invalid")
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  describe "load with a reader function" do
    setup do
      %{lua: Lua.new(sandboxed: [])}
    end

    test "concatenates pieces returned by the reader", %{lua: lua} do
      code = ~S"""
      local pieces = {"return 1", " + ", "2 + 3"}
      local i = 0
      local function reader()
        i = i + 1
        return pieces[i]
      end
      local f = load(reader)
      return f()
      """

      assert {[6], _} = Lua.eval!(lua, code)
    end

    test "ends the chunk when the reader returns nil", %{lua: lua} do
      code = ~S"""
      local pieces = {"return ", "42"}
      local i = 0
      local function reader()
        i = i + 1
        return pieces[i]  -- becomes nil after the last piece
      end
      local f = load(reader)
      return f()
      """

      assert {[42], _} = Lua.eval!(lua, code)
    end

    test "ends the chunk when the reader returns an empty string", %{lua: lua} do
      code = ~S"""
      local pieces = {"return ", "7", ""}
      local i = 0
      local function reader()
        i = i + 1
        return pieces[i]
      end
      local f = load(reader)
      return f()
      """

      assert {[7], _} = Lua.eval!(lua, code)
    end

    test "ends the chunk when the reader returns no value", %{lua: lua} do
      code = ~S"""
      local called = false
      local function reader()
        if called then return end
        called = true
        return "return 99"
      end
      local f = load(reader)
      return f()
      """

      assert {[99], _} = Lua.eval!(lua, code)
    end

    test "returns nil and an error message when the reader returns a non-string", %{lua: lua} do
      code = ~S"""
      local function reader()
        return 42
      end
      local f, err = load(reader)
      return f == nil, type(err) == "string"
      """

      assert {[true, true], _} = Lua.eval!(lua, code)
    end

    test "returns nil and an error message when the reader-supplied source has a syntax error", %{lua: lua} do
      code = ~S"""
      local pieces = {"return 1 +", ""}
      local i = 0
      local function reader()
        i = i + 1
        return pieces[i]
      end
      local f, err = load(reader)
      return f == nil, type(err) == "string"
      """

      assert {[true, true], _} = Lua.eval!(lua, code)
    end

    test "rejects non-string non-function arguments", %{lua: lua} do
      code = ~S"""
      local f, err = load(42)
      return f == nil, type(err) == "string"
      """

      assert {[true, true], _} = Lua.eval!(lua, code)
    end
  end

  describe "chunkname" do
    # Lua 5.4 §6.1 / luaO_chunkid: "@name" is a file and "=name" is used as is, so errors raised in the chunk
    # name it; any other chunkname is shown as [string "..."].
    test "an error in a chunk loaded as @file names the file and its line", %{lua: lua} do
      code = """
      local f = load("local x = 1\\nerror('boom')", "@plants.lua")
      return select(2, pcall(f))
      """

      assert {["plants.lua:2: boom"], _} = Lua.eval!(lua, code)
    end

    test "=name is used as it is", %{lua: lua} do
      code = """
      return select(2, pcall(load("error('x')", "=stdin")))
      """

      assert {["stdin:1: x"], _} = Lua.eval!(lua, code)
    end

    test "any other chunkname is shown as a string chunk", %{lua: lua} do
      code = """
      return select(2, pcall(load("error('x')", "return 1")))
      """

      assert {[~s([string "return 1"]:1: x)], _} = Lua.eval!(lua, code)
    end

    test "a syntax error names the chunk too", %{lua: lua} do
      code = """
      return select(2, load("return +", "@bad.lua"))
      """

      assert {[message], _} = Lua.eval!(lua, code)
      assert message =~ "bad.lua"
    end
  end
end
