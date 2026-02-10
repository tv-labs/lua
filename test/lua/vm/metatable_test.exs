defmodule Lua.VM.MetatableTest do
  use ExUnit.Case, async: true

  alias Lua.{Compiler, Parser, VM}
  alias Lua.VM.State

  describe "metatable basics" do
    test "setmetatable and getmetatable" do
      code = """
      local t = {x = 10}
      local mt = {y = 20}
      setmetatable(t, mt)
      local result = getmetatable(t)
      return result.y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [20], _state} = VM.execute(proto, state)
    end

    test "getmetatable returns nil for table without metatable" do
      code = """
      local t = {x = 10}
      return getmetatable(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "__index metamethod with table" do
      code = """
      local t = {x = 10}
      local mt = {__index = {y = 20, z = 30}}
      setmetatable(t, mt)
      return t.x, t.y, t.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [10, 20, 30], _state} = VM.execute(proto, state)
    end

    test "__index only triggers when key not found" do
      code = """
      local t = {x = 10, y = 15}
      local mt = {__index = {y = 20, z = 30}}
      setmetatable(t, mt)
      return t.x, t.y, t.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      # t.y should be 15 (from t), not 20 (from __index)
      assert {:ok, [10, 15, 30], _state} = VM.execute(proto, state)
    end

    test "setmetatable returns the table" do
      code = """
      local t = {x = 10}
      local mt = {}
      local result = setmetatable(t, mt)
      return result.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [10], _state} = VM.execute(proto, state)
    end

    test "can set metatable to nil" do
      code = """
      local t = {x = 10}
      local mt = {__index = {y = 20}}
      setmetatable(t, mt)
      setmetatable(t, nil)
      return t.x, t.y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      # After setting metatable to nil, t.y should be nil
      assert {:ok, [10, nil], _state} = VM.execute(proto, state)
    end

    test "__newindex metamethod with table" do
      code = """
      local t = {x = 10}
      local storage = {}
      local mt = {__newindex = storage}
      setmetatable(t, mt)
      t.y = 20
      t.z = 30
      return t.x, t.y, storage.y, storage.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      # t.y and t.z should go to storage, not t
      assert {:ok, [10, nil, 20, 30], _state} = VM.execute(proto, state)
    end

    test "__newindex only triggers when key doesn't exist" do
      code = """
      local t = {x = 10, y = 15}
      local storage = {}
      local mt = {__newindex = storage}
      setmetatable(t, mt)
      t.y = 25
      t.z = 30
      return t.x, t.y, t.z, storage.y, storage.z
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      # t.y already exists, so it gets updated in t (not storage)
      # t.z doesn't exist, so it goes to storage
      assert {:ok, [10, 25, nil, nil, 30], _state} = VM.execute(proto, state)
    end
  end

  describe "arithmetic metamethods" do
    test "__add metamethod" do
      code = """
      local a = {value = 10}
      local b = {value = 20}
      local mt = {
        __add = function(x, y)
          return {value = x.value + y.value}
        end
      }
      setmetatable(a, mt)
      setmetatable(b, mt)
      local c = a + b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [30], _state} = VM.execute(proto, state)
    end

    test "__sub metamethod" do
      code = """
      local a = {value = 30}
      local b = {value = 10}
      local mt = {
        __sub = function(x, y)
          return {value = x.value - y.value}
        end
      }
      setmetatable(a, mt)
      local c = a - b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [20], _state} = VM.execute(proto, state)
    end

    test "__mul metamethod" do
      code = """
      local a = {value = 5}
      local b = {value = 6}
      local mt = {
        __mul = function(x, y)
          return {value = x.value * y.value}
        end
      }
      setmetatable(a, mt)
      local c = a * b
      return c.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [30], _state} = VM.execute(proto, state)
    end

    test "__unm metamethod" do
      code = """
      local a = {value = 42}
      local mt = {
        __unm = function(x)
          return {value = -x.value}
        end
      }
      setmetatable(a, mt)
      local b = -a
      return b.value
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = State.new() |> Lua.VM.Stdlib.install()

      assert {:ok, [-42], _state} = VM.execute(proto, state)
    end
  end
end
