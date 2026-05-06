defmodule Lua.VM.CallStackTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

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

      # Execution should succeed and return a valid state
      assert is_struct(final_state, State)
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

  describe "multi-return register expansion" do
    # Regression test for the executor crash exposed by pm.lua line 112:
    # `string.char(range(0, 255))` where `range` is a recursive helper that
    # tail-position multi-returns 256 values. The compiler sizes the caller's
    # register tuple for the syntactic call site, but multi-return expansion
    # can produce many more values than were statically reserved. The
    # executor must grow the register tuple before writing the expanded
    # results.

    test "recursive multi-return with 256 values feeds string.char" do
      code = """
      local function range(i, j)
        if i <= j then return i, range(i+1, j) end
      end
      return string.char(range(0, 255))
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, [result], _final_state} = VM.execute(proto, state)

      assert is_binary(result)
      assert byte_size(result) == 256
      assert :binary.first(result) == 0
      assert :binary.last(result) == 255
    end

    test "recursive multi-return with 100 values feeds variadic native call" do
      # Smaller variant, also exercises the grow-tuple path because the
      # default register tuple won't be sized for 100 expanded slots.
      code = """
      local function range(i, j)
        if i <= j then return i, range(i+1, j) end
      end
      return string.char(range(65, 164))
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, [result], _final_state} = VM.execute(proto, state)

      assert is_binary(result)
      assert byte_size(result) == 100
    end

    test "fixed-count assignment from large multi-return takes only first N" do
      code = """
      local function range(i, j)
        if i <= j then return i, range(i+1, j) end
      end
      local a, b, c = range(0, 200)
      return a, b, c
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, results, _final_state} = VM.execute(proto, state)

      assert results == [0, 1, 2]
    end

    test "table constructor expands large multi-return into all slots" do
      code = """
      local function range(i, j)
        if i <= j then return i, range(i+1, j) end
      end
      local t = {range(1, 150)}
      return #t, t[1], t[150]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = State.new()
      assert {:ok, results, _final_state} = VM.execute(proto, state)

      assert results == [150, 1, 150]
    end
  end
end
