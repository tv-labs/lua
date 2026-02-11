defmodule Lua.VM.PcallTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  describe "pcall and xpcall" do
    test "pcall success - return entire result table" do
      code = """
      local safe = function()
        return 42
      end

      return pcall(safe)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, results, _state} = VM.execute(proto, state)

      # Should return [true, 42]
      assert [true, 42] = results
    end

    test "pcall error - return error message" do
      code = """
      local failing = function()
        error("test error")
      end

      return pcall(failing)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, results, _state} = VM.execute(proto, state)

      assert [false, err] = results
      assert is_binary(err)
      assert err =~ "test error"
    end

    test "pcall with arguments" do
      code = """
      local add = function(a, b)
        return a + b
      end

      return pcall(add, 10, 20)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, results, _state} = VM.execute(proto, state)

      assert [true, 30] = results
    end

    test "pcall catches TypeError" do
      code = """
      local bad = function()
        local x = nil
        return x()
      end

      return pcall(bad)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, results, _state} = VM.execute(proto, state)

      assert [false, err] = results
      assert is_binary(err)
      assert err =~ "nil"
    end

    test "xpcall with error handler" do
      code = """
      local handler = function(err)
        return "handled: " .. err
      end

      local failing = function()
        error("original")
      end

      return xpcall(failing, handler)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      state = Stdlib.install(State.new())
      assert {:ok, results, _state} = VM.execute(proto, state)

      assert [false, handled] = results
      assert handled =~ "handled"
      assert handled =~ "original"
    end
  end
end
