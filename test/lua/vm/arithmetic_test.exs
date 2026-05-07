defmodule Lua.VM.ArithmeticTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError

  describe "arithmetic type checking" do
    test "addition with numbers works" do
      code = "return 5 + 3"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [8], _state} = VM.execute(proto, state)
    end

    test "addition with string numbers coerces" do
      code = ~s(return "5" + "3")
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [8], _state} = VM.execute(proto, state)
    end

    test "addition with non-numeric string raises TypeError" do
      code = "return \"hello\" + 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "addition with nil raises TypeError" do
      code = "return nil + 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "subtraction with non-number raises TypeError" do
      code = "return true - 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "multiplication with non-number raises TypeError" do
      code = """
      local t = {}
      return t * 5
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "negate with non-number raises TypeError" do
      code = "return -\"hello\""
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "power with numbers works" do
      code = "return 2 ^ 8"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [result], _state} = VM.execute(proto, state)
      assert result == 256.0
    end

    test "power with non-number raises TypeError" do
      code = """
      local f = function() end
      return f ^ 2
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "division by zero" do
    test "float division by zero yields +math.huge (Lua 5.3 §3.4.1)" do
      # Lua 5.3 §3.4.1: `/` is always float division and never raises. The
      # BEAM has no IEEE +inf, so we use the same finite stand-in as
      # `math.huge = 1.0e308`.
      code = "return 5 / 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [1.0e308], _state} = VM.execute(proto, state)
    end

    test "float division of negative by zero yields -math.huge" do
      code = "return -5 / 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [-1.0e308], _state} = VM.execute(proto, state)
    end

    test "floor division by zero raises error" do
      code = "return 5 // 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise RuntimeError, ~r/divide by zero/, fn ->
        VM.execute(proto, state)
      end
    end

    test "modulo by zero raises error" do
      code = "return 5 % 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise RuntimeError, ~r/modulo by zero/, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "comparison type checking" do
    test "comparing numbers works" do
      code = "return 5 < 10, 5 <= 5, 10 > 5, 10 >= 10"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [true, true, true, true], _state} = VM.execute(proto, state)
    end

    test "comparing strings works" do
      code = ~s(return "abc" < "def", "abc" <= "abc", "xyz" > "abc")
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [true, true, true], _state} = VM.execute(proto, state)
    end

    test "comparing string with number raises TypeError" do
      code = "return \"5\" < 10"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "comparing nil with number raises TypeError" do
      code = "return nil < 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "comparing table with number raises TypeError" do
      code = """
      local t = {}
      return t > 5
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "equality comparison works between any types" do
      code = """
      return 5 == 5, 5 == \"5\", nil == false, true ~= false
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [true, false, false, true], _state} = VM.execute(proto, state)
    end
  end

  describe "pcall catches arithmetic errors" do
    test "pcall catches arithmetic TypeError" do
      code = """
      local bad = function()
        return \"hello\" + 5
      end

      return pcall(bad)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [false, err], _state} = VM.execute(proto, state)
      assert is_binary(err)
      assert err =~ "arithmetic"
    end

    test "pcall catches division by zero" do
      code = """
      local bad = function()
        return 5 // 0
      end

      return pcall(bad)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [false, err], _state} = VM.execute(proto, state)
      assert is_binary(err)
      assert err =~ "divide by zero"
    end

    test "pcall catches comparison TypeError" do
      code = """
      local bad = function()
        return \"hello\" < 5
      end

      return pcall(bad)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())
      assert {:ok, [false, err], _state} = VM.execute(proto, state)
      assert is_binary(err)
      assert err =~ "compare"
    end
  end

  # See `Lua.VM.Numeric` and Lua 5.3 §3.4.1. Integer operations wrap to
  # signed 64-bit. This is a deliberate divergence from Luerl, which uses
  # Erlang's bignum semantics.
  describe "64-bit integer overflow wrapping (Lua 5.3 §3.4.1)" do
    @maxint 9_223_372_036_854_775_807
    @minint -9_223_372_036_854_775_808

    defp eval_int(code) do
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [result], _state} = VM.execute(proto, state)
      result
    end

    test "maxint + 1 wraps to minint" do
      assert eval_int("return 0x7fffffffffffffff + 1") == @minint
    end

    test "minint - 1 wraps to maxint" do
      assert eval_int("return -0x8000000000000000 - 1") == @maxint
    end

    test "maxint * 2 wraps to -2" do
      assert eval_int("return 0x7fffffffffffffff * 2") == -2
    end

    test "1 << 63 is minint, not a positive bignum" do
      assert eval_int("return 1 << 63") == @minint
    end

    test "~0 is -1" do
      assert eval_int("return ~0") == -1
    end

    test "~0xffffffffffffffff is 0" do
      assert eval_int("return ~0xffffffffffffffff") == 0
    end

    test "0x8000000000000000 // 1 stays at minint (no overflow into bignum)" do
      assert eval_int("return 0x8000000000000000 // 1") == @minint
    end

    test "negation of minint wraps back to minint" do
      # -minint as a true integer would be 2^63 which is one past maxint.
      # In Lua 5.3 that overflows back to minint.
      assert eval_int("local x = -0x8000000000000000; return -x") == @minint
    end

    test "float arithmetic is unaffected by wrapping" do
      # 2^53 is the largest exact integer in IEEE 754 doubles. As a float
      # result it must not get masked through the int64 wrapping path —
      # the result should still be a float, and it should be the IEEE
      # answer, not an integer.
      result = eval_int("return 9007199254740992.0 * 2")
      assert is_float(result)
      assert result == 1.8014398509481984e16
    end

    test "modulo wraps results into signed range" do
      # When both operands are integers, lua_mod result must be signed-64.
      assert eval_int("return -1 % 0x7fffffffffffffff") == @maxint - 1
    end
  end
end
