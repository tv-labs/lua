defmodule Lua.VM.TableIndexTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Reading a missing key from a table must return nil, never raise. This
  # covers the language-level contract from Lua 5.3 §3.4.7: an indexing
  # access `t[k]` for a key that is not present in `t` evaluates to nil
  # (after consulting `__index` if a metatable is set).
  #
  # The cases below pin that contract against silent regression on the
  # most common shapes: empty tables, out-of-bounds array reads, missing
  # string fields, comparisons with nil, metatable `__index` fall-through
  # in both function and table form, the "direct hit must not consult
  # __index" short-circuit, and the stdlib helpers (`rawget`, `next`,
  # `pairs`) that all share the same lookup path.

  describe "missing key reads return nil" do
    test "empty table returns nil for any integer key" do
      code = """
      local t = {}
      return t[5]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "array out-of-bounds read returns nil" do
      code = """
      local t = {1, 2, 3}
      return t[10]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "missing string key on a non-empty table returns nil" do
      code = """
      local t = {a = 1}
      return t.b
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "missing key compares equal to nil" do
      code = """
      local t = {}
      return t[5] == nil
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [true], _state} = VM.execute(proto, state)
    end
  end

  describe "metatable __index still resolves (regression guard)" do
    test "function __index falls through on missing key" do
      code = """
      local t = setmetatable({}, {__index = function(_, k) return "got_" .. k end})
      return t.foo
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, ["got_foo"], _state} = VM.execute(proto, state)
    end

    test "table __index falls through on missing key" do
      code = """
      local t = setmetatable({}, {__index = {x = 42}})
      return t.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [42], _state} = VM.execute(proto, state)
    end

    test "direct hits do not trigger __index" do
      # __index that would explode if invoked. A direct hit on `x` must
      # not consult it.
      code = """
      local mt = {__index = function() error("__index should not be called") end}
      local t = setmetatable({x = 1}, mt)
      return t.x
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1], _state} = VM.execute(proto, state)
    end
  end

  describe "stdlib helpers tolerate missing keys" do
    test "rawget returns nil for missing key" do
      code = """
      local t = {}
      return rawget(t, "x")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil], _state} = VM.execute(proto, state)
    end

    test "next returns nil for empty table" do
      code = """
      local t = {}
      return next(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [nil, nil], _state} = VM.execute(proto, state)
    end

    test "pairs over empty table makes zero iterations" do
      code = """
      local t = {}
      local n = 0
      for _, _ in pairs(t) do
        n = n + 1
      end
      return n
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [0], _state} = VM.execute(proto, state)
    end
  end
end
