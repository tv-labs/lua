defmodule Lua.VM.Stdlib.TableTest do
  use ExUnit.Case, async: true

  alias Lua.{Compiler, Parser, VM}
  alias Lua.VM.State

  describe "table library" do
    test "table.insert appends to end" do
      code = """
      local t = {1, 2, 3}
      table.insert(t, 4)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.insert at position" do
      code = """
      local t = {1, 2, 4}
      table.insert(t, 3, 3)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.remove from end" do
      # Note: Avoiding local variable to work around VM bug
      code = """
      local t = {1, 2, 3, 4}
      table.remove(t)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 2, 3, nil], _state} = VM.execute(proto, state)
    end

    test "table.remove from position" do
      code = """
      local t = {1, 2, 3, 4}
      table.remove(t, 2)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 3, 4, nil], _state} = VM.execute(proto, state)
    end

    test "table.concat joins elements" do
      code = """
      local t = {1, 2, 3, 4}
      return table.concat(t, ", ")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, ["1, 2, 3, 4"], _state} = VM.execute(proto, state)
    end

    test "table.concat with range" do
      code = """
      local t = {1, 2, 3, 4, 5}
      return table.concat(t, "-", 2, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, ["2-3-4"], _state} = VM.execute(proto, state)
    end

    test "table.pack creates table with n" do
      code = """
      local t = table.pack(1, 2, 3)
      return t[1], t[2], t[3], t.n
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 2, 3, 3], _state} = VM.execute(proto, state)
    end

    test "table.unpack returns elements" do
      code = """
      local t = {10, 20, 30, 40}
      return table.unpack(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [10, 20, 30, 40], _state} = VM.execute(proto, state)
    end

    test "table.unpack with range" do
      code = """
      local t = {10, 20, 30, 40, 50}
      return table.unpack(t, 2, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [20, 30, 40], _state} = VM.execute(proto, state)
    end

    test "table.sort sorts in place" do
      code = """
      local t = {3, 1, 4, 1, 5, 9, 2, 6}
      table.sort(t)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 1, 2, 3], _state} = VM.execute(proto, state)
    end

    test "table.move copies elements" do
      code = """
      local t1 = {1, 2, 3, 4, 5}
      local t2 = {10, 20, 30}
      table.move(t1, 2, 4, 1, t2)
      return t2[1], t2[2], t2[3]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.move within same table" do
      code = """
      local t = {1, 2, 3, 4, 5}
      table.move(t, 1, 3, 3)
      return t[1], t[2], t[3], t[4], t[5]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [1, 2, 1, 2, 3], _state} = VM.execute(proto, state)
    end
  end
end
