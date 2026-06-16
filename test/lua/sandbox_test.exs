defmodule Lua.SandboxTest do
  @moduledoc """
  Pins the virtual-by-default capability model: the default VM never touches
  the host, `sandbox: false` opts into the host implementations, and the
  filesystem-touching stdlib resolves against the virtual filesystem.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "os.execute" do
    test "is sandboxed by default" do
      assert {[false, message], _} =
               Lua.eval!(Lua.new(), ~S[return pcall(os.execute, "echo hi")])

      assert message =~ "os.execute(_) is sandboxed"
    end

    test "runs the host shell under sandbox: false" do
      assert {[true, "exit", 0], _} =
               Lua.eval!(Lua.new(sandbox: false), ~S[return os.execute("exit 0")])
    end
  end

  describe "os.getenv" do
    test "reads only injected env in the default sandbox" do
      System.put_env("LUA_SANDBOX_PROBE", "host-visible")
      on_exit(fn -> System.delete_env("LUA_SANDBOX_PROBE") end)

      # The host value is invisible; injected values are not.
      assert {[nil], _} = Lua.eval!(Lua.new(), ~S[return os.getenv("LUA_SANDBOX_PROBE")])

      lua = Lua.new(env: %{"TOKEN" => "abc"})
      assert {["abc"], _} = Lua.eval!(lua, ~S[return os.getenv("TOKEN")])
    end

    test "reads the host environment under sandbox: false" do
      System.put_env("LUA_SANDBOX_PROBE", "host-visible")
      on_exit(fn -> System.delete_env("LUA_SANDBOX_PROBE") end)

      assert {["host-visible"], _} =
               Lua.eval!(Lua.new(sandbox: false), ~S[return os.getenv("LUA_SANDBOX_PROBE")])
    end
  end

  describe "os file operations (virtual)" do
    test "os.remove deletes a seeded virtual file" do
      lua = Lua.write_file(Lua.new(), "/data.txt", "hi")
      assert {[true], lua} = Lua.eval!(lua, ~S[return os.remove("/data.txt")])
      assert Lua.read_file(lua, "/data.txt") == {:error, :enoent}
    end

    test "os.remove reports a POSIX failure tuple for a missing file" do
      assert {[nil, message, 2], _} = Lua.eval!(Lua.new(), ~S[return os.remove("/nope.txt")])
      assert message =~ "/nope.txt"
    end

    test "os.rename moves a virtual file" do
      lua = Lua.write_file(Lua.new(), "/a.txt", "v")
      assert {[true], lua} = Lua.eval!(lua, ~S[return os.rename("/a.txt", "/b.txt")])
      assert Lua.read_file(lua, "/b.txt") == {:ok, "v"}
      assert Lua.read_file(lua, "/a.txt") == {:error, :enoent}
    end

    test "os.tmpname returns a virtual path, never a host one" do
      assert {[name], _} = Lua.eval!(Lua.new(), ~S[return os.tmpname()])
      assert String.starts_with?(name, "/tmp/lua_")
    end
  end

  describe "file loaders resolve from the VFS in the default sandbox" do
    test "loadfile compiles a seeded virtual file" do
      lua = Lua.write_file(Lua.new(), "/main.lua", "return 1 + 2")

      assert {[3], _} =
               Lua.eval!(lua, ~S[local f = loadfile("/main.lua"); return f()])
    end

    test "loadfile returns nil + message for a missing file" do
      assert {[nil, message], _} = Lua.eval!(Lua.new(), ~S[return loadfile("/missing.lua")])
      assert message =~ "/missing.lua"
    end

    test "dofile runs a seeded virtual file" do
      lua = Lua.write_file(Lua.new(), "/run.lua", "return 7 * 6")
      assert {[42], _} = Lua.eval!(lua, ~S[return dofile("/run.lua")])
    end

    test "load compiles a string in the default sandbox" do
      assert {[5], _} = Lua.eval!(Lua.new(), ~S[local f = load("return 2 + 3"); return f()])
    end
  end

  describe "Lua.write_file/3, put_dep/3, read_file/2" do
    test "write_file then read_file round-trips" do
      lua = Lua.write_file(Lua.new(), "/note.txt", "remember")
      assert Lua.read_file(lua, "/note.txt") == {:ok, "remember"}
    end

    test "put_dep makes a module require-able by dotted name" do
      lua = Lua.put_dep(Lua.new(), "a.b", ~S[return "nested"])
      assert {["nested"], _} = Lua.eval!(lua, ~S[return require("a.b")])
    end
  end

  describe "deprecated :sandboxed / :exclude options" do
    test "sandboxed: [] warns and behaves as sandbox: false" do
      {lua, stderr} = with_stderr(fn -> Lua.new(sandboxed: []) end)
      assert stderr =~ "deprecated"

      System.put_env("LUA_SANDBOX_PROBE", "host-visible")
      on_exit(fn -> System.delete_env("LUA_SANDBOX_PROBE") end)

      assert {["host-visible"], _} =
               Lua.eval!(lua, ~S[return os.getenv("LUA_SANDBOX_PROBE")])
    end

    test "default Lua.new() does not warn" do
      {_lua, stderr} = with_stderr(fn -> Lua.new() end)
      refute stderr =~ "deprecated"
    end
  end

  defp with_stderr(fun) do
    parent = self()
    stderr = capture_io(:stderr, fn -> send(parent, {:result, fun.()}) end)
    receive do: ({:result, result} -> {result, stderr})
  end
end
