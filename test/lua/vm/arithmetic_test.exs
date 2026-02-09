defmodule Lua.VM.ArithmeticTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler, VM}
  alias Lua.VM.State

  describe "arithmetic type checking" do
    test "addition with numbers works" do
      code = "return 5 + 3"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [8], _state} = VM.execute(proto, state)
    end

    test "addition with string numbers coerces" do
      code = "return \"5\" + \"3\""
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

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "addition with nil raises TypeError" do
      code = "return nil + 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "subtraction with non-number raises TypeError" do
      code = "return true - 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.TypeError, fn ->
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

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "negate with non-number raises TypeError" do
      code = "return -\"hello\""
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.TypeError, fn ->
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

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end
  end

  describe "division by zero" do
    test "float division by zero raises error" do
      code = "return 5 / 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      # Note: Standard Lua 5.3 returns inf for this case, but we raise an error
      # because Elixir doesn't easily support creating inf/nan values
      assert_raise Lua.VM.RuntimeError, ~r/divide by zero/, fn ->
        VM.execute(proto, state)
      end
    end

    test "float division of negative by zero raises error" do
      code = "return -5 / 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.RuntimeError, ~r/divide by zero/, fn ->
        VM.execute(proto, state)
      end
    end

    test "floor division by zero raises error" do
      code = "return 5 // 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.RuntimeError, ~r/divide by zero/, fn ->
        VM.execute(proto, state)
      end
    end

    test "modulo by zero raises error" do
      code = "return 5 % 0"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.RuntimeError, ~r/modulo by zero/, fn ->
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
      code = "return \"abc\" < \"def\", \"abc\" <= \"abc\", \"xyz\" > \"abc\""
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

      assert_raise Lua.VM.TypeError, fn ->
        VM.execute(proto, state)
      end
    end

    test "comparing nil with number raises TypeError" do
      code = "return nil < 5"
      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()

      assert_raise Lua.VM.TypeError, fn ->
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

      assert_raise Lua.VM.TypeError, fn ->
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
      state = State.new() |> Lua.VM.Stdlib.install()
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
      state = State.new() |> Lua.VM.Stdlib.install()
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
      state = State.new() |> Lua.VM.Stdlib.install()
      assert {:ok, [false, err], _state} = VM.execute(proto, state)
      assert is_binary(err)
      assert err =~ "compare"
    end
  end
end
