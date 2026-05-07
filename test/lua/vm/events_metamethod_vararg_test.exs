defmodule Lua.VM.EventsMetamethodVarargTest do
  @moduledoc """
  Pins Lua 5.3 §2.4 metamethod calling conventions for vararg metamethods.

  Arithmetic, comparison, and unary metamethods are invoked with the two
  operands (or one, for unary) as ordinary call arguments. A metamethod
  declared `function(...)` must therefore see those operands in its
  varargs, not as registers it never reads.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run!(code) do
    assert {:ok, ast} = Parser.parse(code)
    assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    assert {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  describe "vararg arithmetic metamethods" do
    test "__add receives both operands when declared as function(...)" do
      code = """
      local cap
      local t = {
        __add = function(...) cap = {[0] = "add", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b + 5
      return r == b, cap[0], cap[1] == b, cap[2]
      """

      assert [true, "add", true, 5] = run!(code)
    end

    test "__add receives both operands when right-hand side has metatable" do
      code = """
      local cap
      local t = {
        __add = function(...) cap = {[0] = "add", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = 5 + b
      return r == 5, cap[0], cap[1], cap[2] == b
      """

      assert [true, "add", 5, true] = run!(code)
    end

    test "__sub vararg metamethod" do
      code = """
      local cap
      local t = {
        __sub = function(...) cap = {[0] = "sub", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b - 3
      return r == b, cap[0], cap[1] == b, cap[2]
      """

      assert [true, "sub", true, 3] = run!(code)
    end

    test "__mul vararg metamethod" do
      code = """
      local cap
      local t = {
        __mul = function(...) cap = {[0] = "mul", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b * 4
      return r == b, cap[0], cap[1] == b, cap[2]
      """

      assert [true, "mul", true, 4] = run!(code)
    end

    test "__div vararg metamethod" do
      code = """
      local cap
      local t = {
        __div = function(...) cap = {[0] = "div", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b / 2
      return r == b, cap[0], cap[2]
      """

      assert [true, "div", 2] = run!(code)
    end

    test "__mod vararg metamethod" do
      code = """
      local cap
      local t = {
        __mod = function(...) cap = {[0] = "mod", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b % 7
      return r == b, cap[0], cap[2]
      """

      assert [true, "mod", 7] = run!(code)
    end

    test "__pow vararg metamethod" do
      code = """
      local cap
      local t = {
        __pow = function(...) cap = {[0] = "pow", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b ^ 2
      return r == b, cap[0], cap[2]
      """

      assert [true, "pow", 2] = run!(code)
    end

    test "__idiv vararg metamethod" do
      code = """
      local cap
      local t = {
        __idiv = function(...) cap = {[0] = "idiv", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b // 2
      return r == b, cap[0], cap[2]
      """

      assert [true, "idiv", 2] = run!(code)
    end
  end

  describe "vararg bitwise metamethods" do
    test "__band vararg metamethod" do
      code = """
      local cap
      local t = {
        __band = function(...) cap = {[0] = "band", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b & 7
      return r == b, cap[0], cap[2]
      """

      assert [true, "band", 7] = run!(code)
    end

    test "__bor vararg metamethod" do
      code = """
      local cap
      local t = {
        __bor = function(...) cap = {[0] = "bor", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b | 7
      return r == b, cap[0], cap[2]
      """

      assert [true, "bor", 7] = run!(code)
    end

    test "__bxor vararg metamethod" do
      code = """
      local cap
      local t = {
        __bxor = function(...) cap = {[0] = "bxor", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b ~ 7
      return r == b, cap[0], cap[2]
      """

      assert [true, "bxor", 7] = run!(code)
    end

    test "__shl vararg metamethod" do
      code = """
      local cap
      local t = {
        __shl = function(...) cap = {[0] = "shl", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b << 2
      return r == b, cap[0], cap[2]
      """

      assert [true, "shl", 2] = run!(code)
    end

    test "__shr vararg metamethod" do
      code = """
      local cap
      local t = {
        __shr = function(...) cap = {[0] = "shr", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = b >> 2
      return r == b, cap[0], cap[2]
      """

      assert [true, "shr", 2] = run!(code)
    end
  end

  describe "vararg unary metamethods" do
    test "__unm vararg metamethod receives operand" do
      code = """
      local cap
      local t = {
        __unm = function(...) cap = {[0] = "unm", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = -b
      return r == b, cap[0], cap[1] == b
      """

      assert [true, "unm", true] = run!(code)
    end

    test "__bnot vararg metamethod receives operand" do
      code = """
      local cap
      local t = {
        __bnot = function(...) cap = {[0] = "bnot", ...}; return (...) end
      }
      local b = setmetatable({}, t)
      local r = ~b
      return r == b, cap[0], cap[1] == b
      """

      assert [true, "bnot", true] = run!(code)
    end

    test "__len vararg metamethod receives operand" do
      code = """
      local cap
      local t = {
        __len = function(...) cap = {[0] = "len", ...}; return 42 end
      }
      local b = setmetatable({}, t)
      local r = #b
      return r, cap[0], cap[1] == b
      """

      assert [42, "len", true] = run!(code)
    end
  end

  describe "vararg concat and equality metamethods" do
    test "__concat vararg metamethod" do
      code = """
      local cap
      local t = {
        __concat = function(...) cap = {[0] = "concat", ...}; return "ok" end
      }
      local b = setmetatable({}, t)
      local r = b .. "x"
      return r, cap[0], cap[1] == b, cap[2]
      """

      assert ["ok", "concat", true, "x"] = run!(code)
    end

    test "__eq vararg metamethod" do
      code = """
      local cap
      local mm = function(...) cap = {[0] = "eq", ...}; return true end
      local t = {__eq = mm}
      local a = setmetatable({}, t)
      local b = setmetatable({}, t)
      local r = a == b
      return r, cap[0], cap[1] == a, cap[2] == b
      """

      assert [true, "eq", true, true] = run!(code)
    end

    test "__lt vararg metamethod" do
      code = """
      local cap
      local t = {
        __lt = function(...) cap = {[0] = "lt", ...}; return true end
      }
      local a = setmetatable({}, t)
      local b = setmetatable({}, t)
      local r = a < b
      return r, cap[0], cap[1] == a, cap[2] == b
      """

      assert [true, "lt", true, true] = run!(code)
    end

    test "__le vararg metamethod" do
      code = """
      local cap
      local t = {
        __le = function(...) cap = {[0] = "le", ...}; return true end
      }
      local a = setmetatable({}, t)
      local b = setmetatable({}, t)
      local r = a <= b
      return r, cap[0], cap[1] == a, cap[2] == b
      """

      assert [true, "le", true, true] = run!(code)
    end
  end

  describe "events.lua-style closure capture" do
    test "factory pattern from events.lua passes through varargs" do
      code = """
      local cap
      local function f(op)
        return function (...) cap = {[0] = op, ...}; return (...) end
      end
      local t = {}
      t.__add = f("add")
      t.__sub = f("sub")
      local b = setmetatable({}, t)

      local r1 = b + 5
      local s1 = cap[0]
      local b1 = cap[1] == b
      local v1 = cap[2]

      local r2 = b - 3
      local s2 = cap[0]
      local b2 = cap[1] == b
      local v2 = cap[2]

      return r1 == b, s1, b1, v1, r2 == b, s2, b2, v2
      """

      assert [true, "add", true, 5, true, "sub", true, 3] = run!(code)
    end
  end
end
