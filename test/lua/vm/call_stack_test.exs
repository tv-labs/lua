defmodule Lua.VM.CallStackTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State

  describe "call stack tracking" do
    test "tracks current line during execution" do
      code = """
      local x = 1
      local y = 2
      return x + y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      # Execute and capture state
      state = State.new()
      assert {:ok, _results, final_state} = VM.execute(proto, state)

      # State should have current_line field
      assert Map.has_key?(final_state, :current_line)
    end

    test "pushes call stack frame on function call" do
      code = """
      local bar = function()
        return 42
      end

      local foo = function()
        return bar()
      end

      return foo()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, results, _final_state} = VM.execute(proto, state)

      # Should execute successfully and return 42
      assert results == [42]
    end

    test "call stack is empty after execution completes" do
      code = """
      local nested = function()
        return "deep"
      end

      local outer = function()
        return nested()
      end

      return outer()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, _results, final_state} = VM.execute(proto, state)

      # Call stack should be empty after execution
      assert final_state.call_stack == []
    end

    test "handles recursive function calls" do
      code = """
      local factorial
      factorial = function(n)
        if n <= 1 then
          return 1
        else
          return n * factorial(n - 1)
        end
      end

      return factorial(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, results, final_state} = VM.execute(proto, state)

      # Should compute 5! = 120
      assert results == [120]

      # Call stack should be empty after completion
      assert final_state.call_stack == []
    end

    test "maintains call stack across multiple function calls" do
      code = """
      local a = function()
        return 1
      end

      local b = function()
        return 2
      end

      local x = a()
      local y = b()
      return x + y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, results, final_state} = VM.execute(proto, state)

      assert results == [3]
      assert final_state.call_stack == []
    end
  end
end
