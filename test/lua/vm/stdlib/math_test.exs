defmodule Lua.VM.Stdlib.MathTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.ArgumentError, as: LuaArgumentError
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  describe "math library" do
    test "math.abs returns absolute value" do
      code = "return math.abs(-5), math.abs(3.5), math.abs(0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [5, 3.5, 0], _state} = VM.execute(proto, state)
    end

    test "math.ceil rounds up" do
      code = "return math.ceil(3.2), math.ceil(-3.8), math.ceil(5)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [4, -3, 5], _state} = VM.execute(proto, state)
    end

    test "math.floor rounds down" do
      code = "return math.floor(3.8), math.floor(-3.2), math.floor(5)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [3, -4, 5], _state} = VM.execute(proto, state)
    end

    test "math.max returns maximum" do
      code = "return math.max(1, 5, 3), math.max(-2, -8)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [5, -2], _state} = VM.execute(proto, state)
    end

    test "math.min returns minimum" do
      code = "return math.min(1, 5, 3), math.min(-2, -8)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, -8], _state} = VM.execute(proto, state)
    end

    test "math.sqrt computes square root" do
      code = "return math.sqrt(16), math.sqrt(2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [result1, result2], _state} = VM.execute(proto, state)
      assert result1 == 4.0
      assert_in_delta result2, 1.414, 0.01
    end

    test "math.pi is correct" do
      code = "return math.pi"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [pi], _state} = VM.execute(proto, state)
      assert_in_delta pi, 3.14159265, 0.00001
    end

    test "math.sin computes sine" do
      code = "return math.sin(0), math.sin(math.pi / 2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [sin0, sin_pi_2], _state} = VM.execute(proto, state)
      assert_in_delta sin0, 0.0, 0.00001
      assert_in_delta sin_pi_2, 1.0, 0.00001
    end

    test "math.cos computes cosine" do
      code = "return math.cos(0), math.cos(math.pi)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [cos0, cos_pi], _state} = VM.execute(proto, state)
      assert_in_delta cos0, 1.0, 0.00001
      assert_in_delta cos_pi, -1.0, 0.00001
    end

    test "math.tan computes tangent" do
      code = "return math.tan(0), math.tan(math.pi / 4)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [tan0, tan_pi_4], _state} = VM.execute(proto, state)
      assert_in_delta tan0, 0.0, 0.00001
      assert_in_delta tan_pi_4, 1.0, 0.00001
    end

    test "math.exp computes e^x" do
      code = "return math.exp(0), math.exp(1)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [exp0, exp1], _state} = VM.execute(proto, state)
      assert_in_delta exp0, 1.0, 0.00001
      assert_in_delta exp1, 2.718, 0.01
    end

    test "math.log computes logarithm" do
      code = "return math.log(1), math.log(10, 10), math.log(8, 2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [log1, log10, log8], _state} = VM.execute(proto, state)
      assert_in_delta log1, 0.0, 0.00001
      assert_in_delta log10, 1.0, 0.00001
      assert_in_delta log8, 3.0, 0.00001
    end

    test "math.tointeger converts to integer" do
      code =
        "return math.tointeger(5), math.tointeger(5.0), math.tointeger(5.5), math.tointeger('str')"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [5, 5, nil, nil], _state} = VM.execute(proto, state)
    end

    test "math.type returns number type" do
      code = "return math.type(5), math.type(5.5), math.type('str')"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, ["integer", "float", nil], _state} = VM.execute(proto, state)
    end

    test "math.huge is very large" do
      code = "return math.huge > 1e100"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true], _state} = VM.execute(proto, state)
    end

    test "math.maxinteger and mininteger are correct" do
      code = "return math.maxinteger, math.mininteger"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [9_223_372_036_854_775_807, -9_223_372_036_854_775_808], _state} =
               VM.execute(proto, state)
    end

    test "math.fmod with two integers returns integer remainder (sign of dividend)" do
      code = "return math.fmod(7, 3), math.fmod(-7, 3), math.fmod(7, -3), math.fmod(0, 5)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [r1, r2, r3, r4], _state} = VM.execute(proto, state)
      assert r1 === 1
      assert r2 === -1
      assert r3 === 1
      assert r4 === 0
    end

    test "math.fmod with mixed int/float returns a float" do
      code = "return math.fmod(7, 2.5), math.fmod(7.5, 2)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [r1, r2], _state} = VM.execute(proto, state)
      assert is_float(r1)
      assert is_float(r2)
      assert_in_delta r1, 2.0, 1.0e-9
      assert_in_delta r2, 1.5, 1.0e-9
    end

    test "math.fmod with two floats returns a float matching :math.fmod/2" do
      code = "return math.fmod(5.5, 2.0), math.fmod(-5.5, 2.0), math.fmod(5.5, -2.0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [r1, r2, r3], _state} = VM.execute(proto, state)
      assert_in_delta r1, 1.5, 1.0e-9
      assert_in_delta r2, -1.5, 1.0e-9
      assert_in_delta r3, 1.5, 1.0e-9
    end

    test "math.fmod handles mininteger / -1 without overflow" do
      code = "return math.fmod(math.mininteger, -1)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [0], _state} = VM.execute(proto, state)
    end

    test "math.fmod with integer divisor of zero raises bad argument" do
      code = "return math.fmod(5, 0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise LuaArgumentError, ~r/bad argument #2 to 'math\.fmod' \(zero\)/, fn ->
        VM.execute(proto, state)
      end
    end

    test "math.fmod with float divisor of zero raises bad argument" do
      # Lua 5.3 returns NaN here for floats, but BEAM has no NaN value, so we
      # raise — consistent with other zero-divisor paths in this VM.
      code = "return math.fmod(5.0, 0.0)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise LuaArgumentError, ~r/bad argument #2 to 'math\.fmod' \(zero\)/, fn ->
        VM.execute(proto, state)
      end
    end

    test "math.fmod rejects non-number arguments" do
      assert {:ok, ast1} = Parser.parse("return math.fmod('x', 1)")
      assert {:ok, proto1} = Compiler.compile(ast1, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise LuaArgumentError, ~r/bad argument #1 to 'math\.fmod'/, fn ->
        VM.execute(proto1, state)
      end

      assert {:ok, ast2} = Parser.parse("return math.fmod(1, 'x')")
      assert {:ok, proto2} = Compiler.compile(ast2, source: "test.lua")

      assert_raise LuaArgumentError, ~r/bad argument #2 to 'math\.fmod'/, fn ->
        VM.execute(proto2, state)
      end
    end

    test "math.fmod with too few arguments raises value expected" do
      assert {:ok, ast0} = Parser.parse("return math.fmod()")
      assert {:ok, proto0} = Compiler.compile(ast0, source: "test.lua")
      state = Stdlib.install(State.new())

      assert_raise LuaArgumentError, ~r/bad argument #1 to 'math\.fmod' \(value expected\)/, fn ->
        VM.execute(proto0, state)
      end

      assert {:ok, ast1} = Parser.parse("return math.fmod(5)")
      assert {:ok, proto1} = Compiler.compile(ast1, source: "test.lua")

      assert_raise LuaArgumentError, ~r/bad argument #2 to 'math\.fmod' \(value expected\)/, fn ->
        VM.execute(proto1, state)
      end
    end

    test "math.random generates random numbers" do
      code = """
      math.randomseed(42)
      local r1 = math.random()
      local r2 = math.random(10)
      local r3 = math.random(5, 15)
      return r1, r2, r3
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [r1, r2, r3], _state} = VM.execute(proto, state)
      # r1 should be in [0, 1)
      assert is_float(r1)
      assert r1 >= 0 and r1 < 1
      # r2 should be in [1, 10]
      assert is_integer(r2)
      assert r2 >= 1 and r2 <= 10
      # r3 should be in [5, 15]
      assert is_integer(r3)
      assert r3 >= 5 and r3 <= 15
    end
  end

  # Regression tests for Lua 5.3 suite: math.lua. Each pins a numeric-tower
  # conformance fix uncovered while triaging that file.
  describe "math.lua suite conformance" do
    defp run!(code) do
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      assert {:ok, results, _state} = VM.execute(proto, Stdlib.install(State.new()))
      results
    end

    test "math.abs(mininteger) wraps to mininteger (math.lua:579)" do
      assert run!("return math.abs(math.mininteger) == math.mininteger") == [true]
      assert run!("return math.type(math.abs(math.mininteger))") == ["integer"]
    end

    test "math.floor/ceil return integer args unchanged near the 64-bit limit (math.lua:608)" do
      assert run!("return math.floor(math.maxinteger) == math.maxinteger") == [true]
      assert run!("return math.ceil(math.maxinteger) == math.maxinteger") == [true]
      assert run!("return math.floor(math.mininteger) == math.mininteger") == [true]
    end

    test "math.floor of a float beyond the 64-bit range stays a float (math.lua:614)" do
      assert run!("return math.floor(1e50) == 1e50") == [true]
      assert run!("return math.type(math.floor(1e50))") == ["float"]
    end

    test "math.tointeger coerces numeric strings and rejects out-of-range floats (math.lua:627)" do
      assert run!(~s|return math.tointeger("34.0")|) == [34]
      assert run!(~s|return math.tointeger(math.mininteger .. "") == math.mininteger|) == [true]
      assert run!(~s|return math.tointeger("34.3")|) == [nil]
      assert run!("return math.tointeger(math.huge)") == [nil]
    end

    test "math.deg and math.rad convert between degrees and radians (math.lua:577)" do
      assert run!("return math.deg(math.pi)") == [180.0]
      assert run!("return math.rad(180) == math.pi") == [true]
    end

    test "math.random raises on an interval that overflows the 64-bit range (math.lua:819)" do
      assert run!("return not pcall(math.random, math.mininteger, 0)") == [true]
      assert run!("return not pcall(math.random, -1, math.maxinteger)") == [true]
    end

    test "bitwise op on NaN reports no integer representation (math.lua:289)" do
      code = "local ok, err = pcall(function() return (0/0) | 0 end) return ok, err"
      assert [false, err] = run!(code)
      assert err =~ "number has no integer representation"
    end

    test "decimal integer literal overflow becomes a float (math.lua:356)" do
      assert run!("return math.type(10000000000000000000000)") == ["float"]
      assert run!("return 10000000000000000000000.0 == 10000000000000000000000") == [true]
      # -9223372036854775808 is unary minus on an overflowing literal, so float
      assert run!("return math.type(-10000000000000000000000)") == ["float"]
    end

    test "tonumber overflow, sign, and dotted forms match Lua (math.lua:342, 376)" do
      assert run!(~s|return math.type(tonumber("9223372036854775808"))|) == ["float"]
      assert run!(~s|return tonumber("-9223372036854775808") == math.mininteger|) == [true]
      assert run!(~s|return math.type(tonumber("-9223372036854775808"))|) == ["integer"]
      assert run!(~s|return tonumber(".01")|) == [0.01]
      assert run!(~s|return tonumber("-1.")|) == [-1.0]
      assert run!(~s|return tonumber("+ 0.01")|) == [nil]
      assert run!(~s|return tonumber(".e1")|) == [nil]
    end

    test "tonumber with a base handles whitespace and signs (math.lua:390)" do
      assert run!(~s|return tonumber("  001010  ", 2)|) == [10]
      assert run!(~s|return tonumber("  -1010  ", 2)|) == [-10]
      assert run!(~s|return tonumber("  +1Z  ", 36)|) == [71]
    end

    test "hex float strings with leading or trailing dots parse (math.lua:491, 498)" do
      assert run!(~s|return tonumber("0x1.")|) == [1.0]
      assert run!(~s|return tonumber("0x.1")|) == [0.0625]
      assert run!(~s|return tonumber("0x.")|) == [nil]
    end
  end
end
