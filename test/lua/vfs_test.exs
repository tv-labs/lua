defmodule Lua.VFSTest do
  use ExUnit.Case, async: true

  # Pins the virtual-filesystem backing for `require` and the populate/mount
  # API: sandbox code reads only from the in-memory VFS, never the host disk.

  describe "Lua.write_file/3 + require" do
    test "a module written under /lua/deps is loadable with require" do
      lua =
        [sandboxed: []]
        |> Lua.new()
        |> Lua.write_file("/lua/deps/mymod.lua", "return { answer = 42 }")

      {[result], _lua} = Lua.eval!(lua, ~S[return require("mymod").answer])
      assert result == 42
    end

    test "Lua.put_dep/3 seeds a requireable module" do
      lua = [sandboxed: []] |> Lua.new() |> Lua.put_dep("greet", "return 'hi'")
      {[result], _lua} = Lua.eval!(lua, ~S[return require("greet")])
      assert result == "hi"
    end

    test "dotted module names resolve to nested VFS paths" do
      lua =
        [sandboxed: []]
        |> Lua.new()
        |> Lua.write_file("/lua/deps/a/b.lua", "return 'nested'")

      {[result], _lua} = Lua.eval!(lua, ~S[return require("a.b")])
      assert result == "nested"
    end
  end

  describe "Lua.mount/3 + require" do
    test "a module from a mounted backend is loadable with require" do
      backend = VFS.Memory.new(%{"/util.lua" => "return 7"})
      lua = [sandboxed: []] |> Lua.new() |> Lua.mount("/lua/deps", backend)

      {[result], _lua} = Lua.eval!(lua, ~S[return require("util")])
      assert result == 7
    end
  end

  describe "default virtual filesystem isolation" do
    test "the default VM has an empty in-memory VFS" do
      lua = Lua.new()
      assert %VFS{} = lua.state.vfs
    end

    test "a real host file is not readable via require" do
      # Create a real file on disk, then confirm require cannot reach it: the
      # searcher is anchored at the virtual /lua/deps, not the host cwd.
      path = Path.join(System.tmp_dir!(), "lua_vfs_host_#{:erlang.unique_integer([:positive])}.lua")
      File.write!(path, "return 'host'")

      on_exit(fn -> File.rm(path) end)

      modname = Path.basename(path, ".lua")
      lua = Lua.new(sandboxed: [])

      assert_raise Lua.RuntimeException, ~r/module '#{modname}' not found/, fn ->
        Lua.eval!(lua, ~s[return require("#{modname}")])
      end
    end
  end
end
