defmodule Lua.VM.Stdlib.PackageTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp eval(code) do
    state = Stdlib.install(State.new())
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "package_test.lua")
    VM.execute(proto, state)
  end

  describe "package.loaded pre-population" do
    test "require 'string' returns the same table as the string global" do
      assert {:ok, [true], _} = eval(~S[return require("string") == string])
    end

    test "require 'math' returns the same table as the math global" do
      assert {:ok, [true], _} = eval(~S[return require("math") == math])
    end

    test "require 'table' returns the same table as the table global" do
      assert {:ok, [true], _} = eval(~S[return require("table") == table])
    end

    test "require 'debug' returns the same table as the debug global" do
      assert {:ok, [true], _} = eval(~S[return require("debug") == debug])
    end

    test "require 'string' twice returns the cached result without re-evaluating" do
      code = """
      local s1 = require("string")
      local s2 = require("string")
      return s1 == s2
      """

      assert {:ok, [true], _} = eval(code)
    end

    test "package.loaded is a table" do
      assert {:ok, ["table"], _} = eval(~S[return type(package.loaded)])
    end

    test "package.preload is a table" do
      assert {:ok, ["table"], _} = eval(~S[return type(package.preload)])
    end

    test "package itself is in package.loaded" do
      assert {:ok, [true], _} = eval(~s{return package.loaded["package"] == package})
    end

    test "package.loaded['string'] equals the string global" do
      assert {:ok, [true], _} = eval(~s{return package.loaded["string"] == string})
    end
  end

  describe "require recursion guard" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "lua_require_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    defp eval_with_path(code, tmp_dir) do
      lua = Lua.new(exclude: [[:package], [:require]])
      lua = Lua.set_lua_paths(lua, [Path.join(tmp_dir, "?.lua")])
      Lua.eval!(lua, code)
    end

    test "module that self-requires returns the sentinel without re-loading", %{tmp_dir: tmp_dir} do
      # mod.lua requires itself: without a sentinel, this would loop forever.
      File.write!(Path.join(tmp_dir, "mod.lua"), """
      local self_ref = require("mod")
      return { self = self_ref, value = 42 }
      """)

      code = ~S"""
      local m = require("mod")
      return m.value, type(m.self)
      """

      assert {[42, "boolean"], _} = eval_with_path(code, tmp_dir)
    end

    test "two modules that mutually require each other do not loop", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.lua"), """
      local b = require("b")
      return { name = "a", b_seen = type(b) }
      """)

      File.write!(Path.join(tmp_dir, "b.lua"), """
      local a = require("a")
      return { name = "b", a_seen = type(a) }
      """)

      code = ~S"""
      local a = require("a")
      return a.name, a.b_seen
      """

      assert {["a", "table"], _} = eval_with_path(code, tmp_dir)
    end

    test "require returns the cached value on second call", %{tmp_dir: tmp_dir} do
      # The module increments a global counter on each evaluation; with the
      # cache working, the counter should be 1 after two requires.
      File.write!(Path.join(tmp_dir, "counter_mod.lua"), """
      _G.counter_mod_loads = (_G.counter_mod_loads or 0) + 1
      return { id = _G.counter_mod_loads }
      """)

      code = ~S"""
      local m1 = require("counter_mod")
      local m2 = require("counter_mod")
      return m1 == m2, _G.counter_mod_loads
      """

      assert {[true, 1], _} = eval_with_path(code, tmp_dir)
    end
  end
end
