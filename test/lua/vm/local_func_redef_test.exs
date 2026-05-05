defmodule Lua.VM.LocalFuncRedefTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State

  # Per Lua 5.3 §3.4.11:
  #   `function name(...) end` is syntactic sugar for `name = function(...) end`.
  # When `name` is already declared as a local, the assignment must update that
  # local's register, not write to the global environment.

  describe "function declaration assigns to in-scope local" do
    test "local f; function f(x) ... end updates the local" do
      code = """
      local f
      function f(x) return x * 2 end
      return f(5)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [10], _state} = VM.execute(proto, state)
    end

    test "function declaration does not pollute the global when a local is in scope" do
      code = """
      local f
      function f(x) return x + 1 end
      local global_f = _G and _G.f
      return f(3), global_f == nil
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      # f(3) == 4; global_f should be nil (no global leak)
      assert {:ok, [4, true], _state} = VM.execute(proto, state)
    end

    test "global function declaration still writes to global when no local is in scope" do
      code = """
      function g(x) return x * 3 end
      return g(4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [12], _state} = VM.execute(proto, state)
    end

    test "function declaration inside a block assigns to the enclosing local" do
      code = """
      local result
      do
        local f
        function f(n) return n * n end
        result = f(7)
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [49], _state} = VM.execute(proto, state)
    end
  end
end
