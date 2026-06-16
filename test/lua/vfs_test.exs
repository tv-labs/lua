defmodule Lua.VFSTest do
  use ExUnit.Case, async: true

  alias Lua.VFS

  describe "new/0" do
    test "starts empty" do
      assert VFS.new().files == %{}
    end
  end

  describe "write/3 and read/2" do
    test "round-trips a file" do
      {:ok, vfs} = VFS.write(VFS.new(), "/a.lua", "return 1")
      assert VFS.read(vfs, "/a.lua") == {:ok, "return 1"}
    end

    test "overwrites an existing file" do
      {:ok, vfs} = VFS.write(VFS.new(), "/a.lua", "old")
      {:ok, vfs} = VFS.write(vfs, "/a.lua", "new")
      assert VFS.read(vfs, "/a.lua") == {:ok, "new"}
    end

    test "normalizes the key on write and read" do
      {:ok, vfs} = VFS.write(VFS.new(), "/x/./y/../z.lua", "v")
      assert vfs.files == %{"/x/z.lua" => "v"}
      assert VFS.read(vfs, "/x/z.lua") == {:ok, "v"}
    end

    test "reading a missing file is :enoent" do
      assert VFS.read(VFS.new(), "/nope.lua") == {:error, :enoent}
    end

    test "relative paths are rejected as :einval" do
      assert VFS.write(VFS.new(), "rel.lua", "v") == {:error, :einval}
      assert VFS.read(VFS.new(), "rel.lua") == {:error, :einval}
      assert VFS.rm(VFS.new(), "rel.lua") == {:error, :einval}
    end
  end

  describe "directories (implicit)" do
    setup do
      {:ok, vfs} = VFS.write(VFS.new(), "/lua/deps/a/b.lua", "v")
      %{vfs: vfs}
    end

    test "an ancestor path reads as :eisdir", %{vfs: vfs} do
      assert VFS.read(vfs, "/lua/deps/a") == {:error, :eisdir}
      assert VFS.read(vfs, "/lua") == {:error, :eisdir}
    end

    test "cannot write over a directory", %{vfs: vfs} do
      assert VFS.write(vfs, "/lua/deps/a", "x") == {:error, :eisdir}
    end

    test "cannot remove a directory", %{vfs: vfs} do
      assert VFS.rm(vfs, "/lua/deps/a") == {:error, :eisdir}
    end
  end

  describe "rm/2" do
    test "removes a file" do
      {:ok, vfs} = VFS.write(VFS.new(), "/a.lua", "v")
      {:ok, vfs} = VFS.rm(vfs, "/a.lua")
      assert VFS.read(vfs, "/a.lua") == {:error, :enoent}
    end

    test "removing a missing file is :enoent" do
      assert VFS.rm(VFS.new(), "/a.lua") == {:error, :enoent}
    end
  end

  describe "exists?/2" do
    setup do
      {:ok, vfs} = VFS.write(VFS.new(), "/dir/file.lua", "v")
      %{vfs: vfs}
    end

    test "true for files and implicit directories", %{vfs: vfs} do
      assert VFS.exists?(vfs, "/dir/file.lua")
      assert VFS.exists?(vfs, "/dir")
    end

    test "false for missing and relative paths", %{vfs: vfs} do
      refute VFS.exists?(vfs, "/missing")
      refute VFS.exists?(vfs, "relative")
    end
  end

  describe "normalize/1" do
    test "resolves . and .. segments" do
      assert VFS.normalize("/a/./b/../c") == {:ok, "/a/c"}
    end

    test "collapses duplicate slashes and trailing slash" do
      assert VFS.normalize("/a//b/") == {:ok, "/a/b"}
    end

    test ".. at root is a no-op" do
      assert VFS.normalize("/../a") == {:ok, "/a"}
    end

    test "root normalizes to itself" do
      assert VFS.normalize("/") == {:ok, "/"}
    end

    test "rejects relative paths" do
      assert VFS.normalize("a/b") == {:error, :einval}
    end
  end
end
