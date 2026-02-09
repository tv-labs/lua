defmodule Lua.RocksIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  @tree "test/tmp/lua_deps"

  setup do
    File.rm_rf!(@tree)
    on_exit(fn -> File.rm_rf!(@tree) end)
    :ok
  end

  describe "install/2" do
    test "installs a pure Lua package" do
      assert :ok = Lua.Rocks.install("inspect", tree: @tree)

      lua_files = Path.wildcard(Path.join([@tree, "**", "*.lua"]))
      assert length(lua_files) > 0
    end

    test "returns error for nonexistent package" do
      assert {:error, _reason} =
               Lua.Rocks.install("this-package-does-not-exist-abc123", tree: @tree)
    end
  end

  describe "end-to-end: install and require" do
    test "can install and require a pure Lua package through Luerl" do
      assert :ok = Lua.Rocks.install("inspect", tree: @tree)

      lua =
        Lua.new(exclude: [[:package], [:require]])
        |> Lua.with_rocks(tree: @tree)

      # Verify the module loads successfully via require
      {[result], _lua} =
        Lua.eval!(lua, """
        local inspect = require("inspect")
        return type(inspect)
        """)

      assert result == "function" or result == "table"
    end
  end

  describe "install_deps/1" do
    test "installs all dependencies from a rockspec" do
      {:ok, results} =
        Lua.Rocks.install_deps(
          rockspec: "test/fixtures/test.rockspec",
          tree: @tree
        )

      successful = for {:ok, name} <- results, do: name
      assert "inspect" in successful
    end
  end

  describe "clean/1" do
    test "removes the tree directory" do
      Lua.Rocks.install("inspect", tree: @tree)
      assert File.dir?(@tree)

      Lua.Rocks.clean(tree: @tree)
      refute File.dir?(@tree)
    end
  end

  describe "validate_tree/1" do
    test "detects C extensions when present" do
      Lua.Rocks.install("luafilesystem", tree: @tree)

      case Lua.Rocks.validate_tree(tree: @tree) do
        {:warning, paths} ->
          assert length(paths) > 0

        :ok ->
          # On some systems it may fail to compile C extensions
          :ok
      end
    end
  end
end
