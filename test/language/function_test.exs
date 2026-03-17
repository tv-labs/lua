defmodule Lua.Language.FunctionTest do
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  test "redefine local function with same name", %{lua: lua} do
    code = """
    local function f(x) return x + 1 end
    assert(f(10) == 11)
    local function f(x) return x + 2 end
    assert(f(10) == 12)
    return true
    """

    assert {[true], _} = Lua.eval!(lua, code)
  end

  test "multi-value return register corruption", %{lua: lua} do
    assert {[55, 2], _} =
             Lua.eval!(lua, ~S"""
             function c12(...)
               local x = {...}; x.n = #x
               local res = (x.n==2 and x[1] == 1 and x[2] == 2)
               if res then res = 55 end
               return res, 2
             end
             return c12(1,2)
             """)
  end

  test "select with multi-return function", %{lua: lua} do
    # select(2, load(invalid)) should get the error message from load's two return values
    code = ~S"""
    local function multi() return nil, "error msg" end
    return select(2, multi())
    """

    assert {["error msg"], _} = Lua.eval!(lua, code)
  end

  describe "FuncDecl local assignment" do
    test "function f() updates local f when it exists in scope", %{lua: lua} do
      code = """
      local f = function(x) return "first: " .. x end
      assert(f("test") == "first: test")

      function f(x)
        return "second: " .. x
      end

      return f("test")
      """

      assert {["second: test"], _} = Lua.eval!(lua, code)
    end

    test "function f() creates global when no local exists", %{lua: lua} do
      code = """
      function f(x)
        return "global: " .. x
      end

      return f("test")
      """

      assert {["global: test"], _} = Lua.eval!(lua, code)
    end

    test "function f() in nested do block does not see outer local", %{lua: lua} do
      code = """
      local f = function() return "outer" end

      do
        local f = function() return "inner" end

        function f()
          return "updated inner"
        end

        assert(f() == "updated inner")
      end

      -- outer f should be unchanged
      return f()
      """

      assert {["outer"], _} = Lua.eval!(lua, code)
    end

    test "dotted name always uses table assignment", %{lua: lua} do
      code = """
      local t = {}

      function t.method(x)
        return x + 1
      end

      return t.method(41)
      """

      assert {[42], _} = Lua.eval!(lua, code)
    end

    test "function f() does not see locals declared after the FuncDecl", %{lua: lua} do
      code = """
      function f()
        return "global"
      end

      local f = function() return "local" end

      -- The global f is unaffected by the later local declaration
      return f()
      """

      assert {["local"], _} = Lua.eval!(lua, code)
    end
  end

  describe "local function declarations" do
    test "basic local function", %{lua: lua} do
      code = """
      local function add(a, b)
        return a + b
      end
      return add(1, 2)
      """

      assert {[3], _} = Lua.eval!(lua, code)
    end

    test "recursive local function", %{lua: lua} do
      code = """
      local function fact(n)
        if n <= 1 then return 1 end
        return n * fact(n - 1)
      end
      return fact(5)
      """

      assert {[120], _} = Lua.eval!(lua, code)
    end

    test "local function captures outer locals", %{lua: lua} do
      code = """
      local base = 10
      local function add_base(x)
        return x + base
      end
      return add_base(5)
      """

      assert {[15], _} = Lua.eval!(lua, code)
    end

    test "local function is not visible outside its scope", %{lua: lua} do
      code = """
      do
        local function helper()
          return 42
        end
        assert(helper() == 42)
      end
      return helper == nil
      """

      assert {[true], _} = Lua.eval!(lua, code)
    end
  end
end
