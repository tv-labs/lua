defmodule Lua.VM.FuncDeclTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State

  # Per Lua 5.3 §3.4.11:
  #   `function a.b.c(...) end` is sugar for `a.b.c = function(...) end`
  #   `function a:m(...) end` is sugar for `a.m = function(self, ...) end`.
  # The head name `a` must resolve against the live scope at the point of
  # declaration, *not* against the post-block function-scope snapshot used
  # by codegen.

  describe "multi-name FuncDecl head resolves against live scope" do
    test "method sugar against block-local shadowing a global" do
      code = """
      a = {i=10}
      local result
      do
        local a = {x=0}
        function a:add(x)
          self.x = self.x + x
          return self
        end
        result = a:add(10).x
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [10], _state} = VM.execute(proto, state)
    end

    test "dotted multi-name against block-local" do
      code = """
      local result
      do
        local a = {}
        function a.b()
          return 42
        end
        result = a.b()
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "three-deep dotted multi-name against block-local" do
      code = """
      local result
      do
        local a = {b = {}}
        function a.b.c()
          return "ok"
        end
        result = a.b.c()
      end
      return result
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, ["ok"], _state} = VM.execute(proto, state)
    end

    test "head name resolves as an upvalue when captured by an inner function" do
      code = """
      local function outer()
        local a = {}
        local function inner()
          function a.b() return 7 end
          return a.b()
        end
        return inner()
      end
      return outer()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [7], _state} = VM.execute(proto, state)
    end

    test "method captures head local via upvalue when body references head name" do
      # Mirrors calls.lua lines 65-69: the method body references `a` itself,
      # so `a` is captured by the function. The FuncDecl head must read the
      # same captured-local cell so the chain operates on the live table.
      code = """
      local result_x, result_y
      do
        local a = {x=0}
        function a:add(n)
          self.x, a.y = self.x + n, 20
          return self
        end
        local chained = a:add(10):add(20):add(30)
        result_x = chained.x
        result_y = a.y
      end
      return result_x, result_y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, [60, 20], _state} = VM.execute(proto, state)
    end

    test "head name with no local in scope still writes through _ENV" do
      code = """
      g = {}
      function g.h()
        return "global"
      end
      return g.h()
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new()
      assert {:ok, ["global"], _state} = VM.execute(proto, state)
    end
  end
end
