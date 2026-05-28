defmodule Lua.VM.MetatableTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.ArgumentError
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  describe "metatable basics" do
    test "setmetatable and getmetatable" do
      code = """
      local t = {x = 10}
      local mt = {y = 20}
      setmetatable(t, mt)
      local result = getmetatable(t)
      return result.y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [20], _state} = VM.execute(proto, state)
    end

    test "getmetatable returns nil for table without metatable" do
      code = """
      local t = {x = 10}
      return getmetatable(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "__index metamethod with table" do
      code = """
      local t = {x = 10}
      local mt = {__index = {y = 20, z = 30}}
      setmetatable(t, mt)
      return t.x, t.y, t.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [10, 20, 30], _state} = VM.execute(proto, state)
    end

    test "__index only triggers when key not found" do
      code = """
      local t = {x = 10, y = 15}
      local mt = {__index = {y = 20, z = 30}}
      setmetatable(t, mt)
      return t.x, t.y, t.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # t.y should be 15 (from t), not 20 (from __index)
      assert {:ok, [10, 15, 30], _state} = VM.execute(proto, state)
    end

    test "setmetatable returns the table" do
      code = """
      local t = {x = 10}
      local mt = {}
      local result = setmetatable(t, mt)
      return result.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [10], _state} = VM.execute(proto, state)
    end

    test "can set metatable to nil" do
      code = """
      local t = {x = 10}
      local mt = {__index = {y = 20}}
      setmetatable(t, mt)
      setmetatable(t, nil)
      return t.x, t.y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # After setting metatable to nil, t.y should be nil
      assert {:ok, [10, nil], _state} = VM.execute(proto, state)
    end

    test "setmetatable raises ArgumentError for non-table first argument" do
      code = """
      setmetatable(42, {})
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end

    test "setmetatable raises ArgumentError for invalid metatable type" do
      code = """
      local t = {}
      setmetatable(t, 42)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end

    test "setmetatable raises ArgumentError when called with no arguments" do
      code = """
      setmetatable()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end

    test "__newindex metamethod with table" do
      code = """
      local t = {x = 10}
      local storage = {}
      local mt = {__newindex = storage}
      setmetatable(t, mt)
      t.y = 20
      t.z = 30
      return t.x, t.y, storage.y, storage.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # t.y and t.z should go to storage, not t
      assert {:ok, [10, nil, 20, 30], _state} = VM.execute(proto, state)
    end

    test "__newindex only triggers when key doesn't exist" do
      code = """
      local t = {x = 10, y = 15}
      local storage = {}
      local mt = {__newindex = storage}
      setmetatable(t, mt)
      t.y = 25
      t.z = 30
      return t.x, t.y, t.z, storage.y, storage.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # t.y already exists, so it gets updated in t (not storage)
      # t.z doesn't exist, so it goes to storage
      assert {:ok, [10, 25, nil, nil, 30], _state} = VM.execute(proto, state)
    end
  end

  describe "arithmetic metamethods" do
    test "__add metamethod" do
      code = """
      local a = {value = 10}
      local b = {value = 20}
      local mt = {
        __add = function(x, y)
          return {value = x.value + y.value}
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      local c = a + b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [30], _state} = VM.execute(proto, state)
    end

    test "__sub metamethod" do
      code = """
      local a = {value = 30}
      local b = {value = 10}
      local mt = {
        __sub = function(x, y)
          return {value = x.value - y.value}
        end
      }
      setmetatable(a, mt)
      local c = a - b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [20], _state} = VM.execute(proto, state)
    end

    test "__mul metamethod" do
      code = """
      local a = {value = 5}
      local b = {value = 6}
      local mt = {
        __mul = function(x, y)
          return {value = x.value * y.value}
        end
      }
      setmetatable(a, mt)
      local c = a * b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [30], _state} = VM.execute(proto, state)
    end

    test "__unm metamethod" do
      code = """
      local a = {value = 42}
      local mt = {
        __unm = function(x)
          return {value = -x.value}
        end
      }
      setmetatable(a, mt)
      local b = -a
      return b.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [-42], _state} = VM.execute(proto, state)
    end
  end

  describe "comparison metamethods" do
    test "__eq metamethod" do
      code = """
      local a = {value = 10}
      local b = {value = 10}
      local c = {value = 20}
      local mt = {
        __eq = function(x, y)
          return x.value == y.value
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      setmetatable(c, mt)
      return a == b, a == c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, false], _state} = VM.execute(proto, state)
    end

    test "__eq is called when only the first operand defines it (§3.4.4)" do
      code = """
      local a = {value = 10}
      local b = {value = 10}
      local mt1 = {
        __eq = function(x, y)
          return x.value == y.value
        end
      }
      local mt2 = {
        __eq = function(x, y)
          return x.value == y.value
        end
      }
      setmetatable(a, mt1)
      setmetatable(b, mt2)
      return a == b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # Lua 5.3 dropped the same-metamethod requirement from Lua 5.1.
      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "__eq is called when only the first operand has a metatable" do
      code = """
      local a = setmetatable({}, {__eq = function() return true end})
      local b = {}
      return a == b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "__eq is not consulted for table-vs-non-table comparisons" do
      code = """
      local a = setmetatable({}, {__eq = function() return true end})
      return a == 5, a == "x", a == nil, a == true
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [false, false, false, false], _state} = VM.execute(proto, state)
    end

    test "~= dispatches through __eq metamethod" do
      code = """
      local a = {value = 10}
      local b = {value = 10}
      local c = {value = 20}
      local mt = {
        __eq = function(x, y)
          return x.value == y.value
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      setmetatable(c, mt)
      return a ~= b, a ~= c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # a ~= b → __eq returns true → ~= is false
      # a ~= c → __eq returns false → ~= is true
      assert {:ok, [false, true], _state} = VM.execute(proto, state)
    end

    test "~= calls __eq exactly once per evaluation" do
      code = """
      local count = 0
      local mt = {
        __eq = function(x, y)
          count = count + 1
          return true
        end
      }
      local a = setmetatable({}, mt)
      local b = setmetatable({}, mt)
      local result = a ~= b
      return result, count
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # __eq returns true once, ~= negates to false
      assert {:ok, [false, 1], _state} = VM.execute(proto, state)
    end

    test "~= short-circuits primitive equality without consulting __eq" do
      # Per Lua 5.3 §3.4.4, raw-equal primitive values skip __eq.
      # 1 ~= 1 is false; nil ~= nil is false; "a" ~= "a" is false.
      # No metamethod can be installed on these primitives, so this
      # mainly verifies the code path doesn't break for non-table operands.
      code = """
      return 1 ~= 1, 1 ~= 2, "a" ~= "a", "a" ~= "b", nil ~= nil, nil ~= false
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [false, true, false, true, false, true], _state} =
               VM.execute(proto, state)
    end

    test "~= dispatches through __eq even when metamethods differ (§3.4.4)" do
      code = """
      local a = {value = 10}
      local b = {value = 10}
      local mt1 = { __eq = function() return true end }
      local mt2 = { __eq = function() return true end }
      setmetatable(a, mt1)
      setmetatable(b, mt2)
      return a ~= b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      # The first operand's __eq returns true, so ~= is false.
      assert {:ok, [false], _state} = VM.execute(proto, state)
    end

    test "__lt metamethod" do
      code = """
      local a = {value = 5}
      local b = {value = 10}
      local mt = {
        __lt = function(x, y)
          return x.value < y.value
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      return a < b, b < a
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, false], _state} = VM.execute(proto, state)
    end

    test "__le metamethod" do
      code = """
      local a = {value = 10}
      local b = {value = 10}
      local c = {value = 5}
      local mt = {
        __le = function(x, y)
          return x.value <= y.value
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      setmetatable(c, mt)
      return a <= b, c <= a, a <= c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, true, false], _state} = VM.execute(proto, state)
    end

    test "<= falls back to `not (b < a)` when only __lt is defined" do
      code = """
      local mt = {
        __lt = function(a, b) return a.x < b.x end,
      }
      local function Op(x) return setmetatable({x = x}, mt) end
      return Op(1) <= Op(2), Op(2) <= Op(1), Op(1) <= Op(1)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, false, true], _state} = VM.execute(proto, state)
    end

    test ">= falls back via __lt when only __lt is defined" do
      # a >= b is translated to b <= a, which then falls back to
      # `not (a < b)` when __le is missing. This exercises the same
      # path as <= via the :greater_equal opcode.
      code = """
      local mt = {
        __lt = function(a, b) return a.x < b.x end,
      }
      local function Op(x) return setmetatable({x = x}, mt) end
      return Op(2) >= Op(1), Op(1) >= Op(2), Op(1) >= Op(1)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, false, true], _state} = VM.execute(proto, state)
    end

    test "__le is preferred over __lt when both are defined" do
      # When __le is set it must fire — the fallback to __lt only kicks
      # in when __le is absent on both operands.
      code = """
      local mt = {
        __lt = function(a, b) error("__lt should not fire") end,
        __le = function(a, b) return true end,
      }
      local function Op(x) return setmetatable({x = x}, mt) end
      return Op(1) <= Op(2)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "__le on either operand wins over __lt fallback" do
      # Only b has __le; a has no metatable. The lookup order in
      # try_binary_metamethod / compare_le checks a then b, so b's
      # __le must fire rather than falling back to __lt.
      code = """
      local mt_le = {
        __le = function(x, y) return true end,
        __lt = function(x, y) error("__lt should not fire") end,
      }
      local a = {x = 1}
      local b = setmetatable({x = 2}, mt_le)
      return a <= b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "> dispatches __lt with operands swapped" do
      # Lua 5.3 §3.4.4 translates `a > b` to `b < a`, so `>` between
      # tables with __lt set must call __lt(b, a).
      code = """
      local mt = {
        __lt = function(a, b) return a.x < b.x end,
      }
      local function Op(x) return setmetatable({x = x}, mt) end
      return Op(2) > Op(1), Op(1) > Op(2), Op(1) > Op(1)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true, false, false], _state} = VM.execute(proto, state)
    end

    test "<= on incompatible primitive types still raises" do
      # The fallback to __lt only fires for table operands. Mismatched
      # primitives must still raise — `1 <= "x"` is an error in Lua.
      code = """
      return 1 <= "x"
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise Lua.VM.TypeError, ~r/attempt to compare/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "other metamethods" do
    test "__concat metamethod" do
      code = """
      local a = {value = "Hello"}
      local b = {value = "World"}
      local mt = {
        __concat = function(x, y)
          return {value = x.value .. " " .. y.value}
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      local c = a .. b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, ["Hello World"], _state} = VM.execute(proto, state)
    end

    test "__len metamethod" do
      code = """
      local a = {x = 1, y = 2, z = 3}
      local mt = {
        __len = function(t)
          return 42
        end
      }
      setmetatable(a, mt)
      return #a
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "setmetatable raises ArgumentError when first argument is not a table" do
      code = "setmetatable(42, {})"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end

    test "setmetatable raises ArgumentError when second argument is not nil or table" do
      code = "setmetatable({}, 42)"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end

    test "setmetatable raises ArgumentError when no arguments provided" do
      code = "setmetatable()"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise ArgumentError, fn ->
        VM.execute(proto, state)
      end
    end
  end
end
