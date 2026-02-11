defmodule Lua.VM.Stdlib.MathTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
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

      assert {:ok, [4.0, -3.0, 5.0], _state} = VM.execute(proto, state)
    end

    test "math.floor rounds down" do
      code = "return math.floor(3.8), math.floor(-3.2), math.floor(5)"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [3.0, -4.0, 5.0], _state} = VM.execute(proto, state)
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
end
