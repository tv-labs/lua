defmodule Lua.VM.ForLoopRegisterTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State

  # Regression test for issue #146.
  #
  # Two consecutive numeric `for` loops in the same scope corrupted the
  # register file: the second loop saw `nil` where its loop counter should
  # have been, producing:
  #
  #   Lua runtime error: attempt to perform arithmetic on a nil value
  #
  # The original Phase 17 fix (commit e7c50e5) ensured the for-loop's
  # internal counter/limit/step registers did not leak into the surrounding
  # scope. The CPS executor refactor (PR #156) reintroduced the regression.
  #
  # This test locks in correct behaviour for the cases that exercised the bug.

  describe "consecutive numeric for loops" do
    test "two consecutive `for i = 1, n` loops produce correct sum" do
      code = """
      local sum = 0
      for i = 1, 3 do sum = sum + i end
      for i = 1, 3 do sum = sum + i end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [12], _state} = VM.execute(proto, state)
    end

    test "three consecutive `for i = 1, n` loops produce correct sum" do
      code = """
      local sum = 0
      for i = 1, 3 do sum = sum + i end
      for i = 1, 3 do sum = sum + i end
      for i = 1, 3 do sum = sum + i end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [18], _state} = VM.execute(proto, state)
    end

    test "two consecutive loops with different variable names" do
      code = """
      local sum = 0
      for i = 1, 3 do sum = sum + i end
      for j = 1, 5 do sum = sum + j end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      # 1+2+3 + 1+2+3+4+5 = 6 + 15 = 21
      assert {:ok, [21], _state} = VM.execute(proto, state)
    end

    test "two consecutive loops with the same variable name (original #146 case)" do
      code = """
      local sum = 0
      for i = 1, 4 do sum = sum + i end
      for i = 1, 4 do sum = sum + i end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      # (1+2+3+4) * 2 = 20
      assert {:ok, [20], _state} = VM.execute(proto, state)
    end

    test "consecutive loops with explicit step values" do
      code = """
      local sum = 0
      for i = 1, 6, 2 do sum = sum + i end
      for i = 10, 2, -2 do sum = sum + i end
      return sum
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      # 1+3+5 + 10+8+6+4+2 = 9 + 30 = 39
      assert {:ok, [39], _state} = VM.execute(proto, state)
    end

    test "closures over loop variables still work after the fix" do
      # Sanity check that the original Phase 17 closure-over-loop-var
      # behaviour is preserved alongside this regression fix.
      code = """
      local fns = {}
      for i = 1, 3 do fns[i] = function() return i end end
      for i = 1, 3 do fns[i + 3] = function() return i * 10 end end
      return fns[1](), fns[2](), fns[3](), fns[4](), fns[5](), fns[6]()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [1, 2, 3, 10, 20, 30], _state} = VM.execute(proto, state)
    end
  end
end
