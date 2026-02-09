defmodule Lua.RocksTest do
  use ExUnit.Case, async: true

  describe "parse_rockspec/1" do
    test "parses dependencies from a valid rockspec" do
      {:ok, deps} = Lua.Rocks.parse_rockspec("test/fixtures/test.rockspec")

      assert {"inspect", ">= 3.0"} in deps
      assert {"middleclass", ">= 4.0"} in deps
      assert length(deps) == 2
    end

    test "filters out the lua runtime dependency" do
      {:ok, deps} = Lua.Rocks.parse_rockspec("test/fixtures/test.rockspec")

      refute Enum.any?(deps, fn {name, _} -> name == "lua" end)
    end

    test "returns empty list when no dependencies specified" do
      {:ok, deps} = Lua.Rocks.parse_rockspec("test/fixtures/empty.rockspec")

      assert deps == []
    end

    test "returns error for missing file" do
      assert {:error, _reason} = Lua.Rocks.parse_rockspec("nonexistent.rockspec")
    end
  end

  describe "lua_paths/1" do
    test "returns two path patterns" do
      paths = Lua.Rocks.lua_paths(tree: "my_deps", root: "/project")

      assert length(paths) == 2
      assert Enum.any?(paths, &String.ends_with?(&1, "?.lua"))
      assert Enum.any?(paths, &String.contains?(&1, "init.lua"))
    end

    test "includes the tree and root in paths" do
      paths = Lua.Rocks.lua_paths(tree: "vendor/lua", root: "/app")

      assert Enum.all?(paths, &String.starts_with?(&1, "/app/vendor/lua/"))
    end

    test "defaults to 5.3 when tree does not exist" do
      paths = Lua.Rocks.lua_paths(tree: "nonexistent_tree", root: "/app")

      assert Enum.any?(paths, &String.contains?(&1, "/5.3/"))
    end
  end

  describe "detect_c_extensions/1" do
    test "returns empty list when tree does not exist" do
      assert [] == Lua.Rocks.detect_c_extensions(tree: "nonexistent_tree")
    end
  end

  describe "validate_tree/1" do
    test "returns :ok when no C extensions present" do
      assert :ok == Lua.Rocks.validate_tree(tree: "nonexistent_tree")
    end
  end

  describe "find_rockspec/1" do
    test "finds rockspec in fixtures directory" do
      {:ok, path} = Lua.Rocks.find_rockspec("test/fixtures")

      assert String.ends_with?(path, ".rockspec")
    end

    test "returns error when no rockspec found" do
      assert {:error, :not_found} = Lua.Rocks.find_rockspec("test/support")
    end
  end

  describe "check_luarocks/0" do
    test "returns ok or not_found" do
      case Lua.Rocks.check_luarocks() do
        {:ok, version} -> assert is_binary(version)
        {:error, :not_found} -> :ok
      end
    end
  end

  describe "default_tree/0" do
    test "returns the default tree path" do
      assert Lua.Rocks.default_tree() == "priv/lua_deps"
    end
  end
end
