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
end
