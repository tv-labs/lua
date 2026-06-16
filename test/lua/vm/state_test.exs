defmodule Lua.VM.StateTest do
  use ExUnit.Case, async: true

  alias Lua.VFS
  alias Lua.VM.State

  describe "vfs seeding" do
    test "new/0 seeds an empty virtual filesystem" do
      assert %VFS{files: %{}} = State.new().vfs
    end
  end

  describe "vfs_write/3, vfs_read/2, vfs_rm/2, vfs_exists?/2" do
    test "write threads the updated VFS back onto state" do
      {:ok, state} = State.vfs_write(State.new(), "/a.lua", "return 1")
      assert State.vfs_read(state, "/a.lua") == {:ok, "return 1"}
      assert State.vfs_exists?(state, "/a.lua")
    end

    test "write error returns the reason and the unchanged state" do
      state = State.new()
      assert {:error, :einval, ^state} = State.vfs_write(state, "relative", "v")
    end

    test "rm threads the updated VFS back onto state" do
      {:ok, state} = State.vfs_write(State.new(), "/a.lua", "v")
      {:ok, state} = State.vfs_rm(state, "/a.lua")
      assert State.vfs_read(state, "/a.lua") == {:error, :enoent}
      refute State.vfs_exists?(state, "/a.lua")
    end

    test "rm of a missing file returns :enoent and the state" do
      state = State.new()
      assert {:error, :enoent, ^state} = State.vfs_rm(state, "/missing")
    end
  end

  describe "update_userdata/3" do
    test "rewrites the backing term in place" do
      {ref, state} = State.alloc_userdata(State.new(), %{pos: 0})
      state = State.update_userdata(state, ref, fn data -> %{data | pos: 5} end)
      assert State.get_userdata(state, ref) == %{pos: 5}
    end
  end
end
