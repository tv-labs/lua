defmodule Mix.Tasks.Lua.SuiteTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lua.Suite

  @tmpdir Path.join(System.tmp_dir!(), "mix_lua_suite_test")

  setup do
    File.rm_rf!(@tmpdir)
    File.mkdir_p!(@tmpdir)
    on_exit(fn -> File.rm_rf!(@tmpdir) end)
    :ok
  end

  defp write_lua(name, body) do
    path = Path.join(@tmpdir, name)
    File.write!(path, body)
    path
  end

  describe "run/1" do
    test "prints a summary with passing and failing counts" do
      write_lua("good.lua", "return 1")
      write_lua("bad.lua", ~s|assert(1 == 2, "nope")\n|)

      output = capture_io(fn -> Suite.run(["--dir", @tmpdir]) end)

      assert output =~ ~r/passing:\s*1/
      assert output =~ ~r/failing:\s*1/
      assert output =~ "passing files: good"
      assert output =~ "bad.lua"
    end

    test "--filter restricts which files run" do
      write_lua("math_ops.lua", "return 1")
      write_lua("string_ops.lua", "return 1")

      output =
        capture_io(fn -> Suite.run(["--dir", @tmpdir, "--filter", "math"]) end)

      assert output =~ "math_ops"
      refute output =~ "string_ops"
    end

    test "--timeout flags slow files as timeout" do
      # An infinite loop. Without a per-file timeout this would hang
      # the test forever.
      write_lua("loop.lua", "while true do end\n")
      write_lua("ok.lua", "return 1")

      output =
        capture_io(fn ->
          Suite.run(["--dir", @tmpdir, "--timeout", "200"])
        end)

      assert output =~ ~r/timeout:\s*1/
      assert output =~ "loop.lua"
      assert output =~ "passing files: ok"
      # Loop must NOT appear in the failing section — brutal_kill returning
      # {:exit, :killed} or nil must be categorised as timeout, not fail.
      refute output =~ "failing files"
    end

    test "exits 1 when --filter matches no files" do
      write_lua("a.lua", "return 1")

      assert_raise Mix.Error, ~r/--filter/, fn ->
        Suite.run(["--dir", @tmpdir, "--filter", "zzz"])
      end
    end

    test "exits 1 when no files pass" do
      write_lua("a.lua", "error('fail')")

      assert catch_exit(capture_io(fn -> Suite.run(["--dir", @tmpdir]) end)) == {:shutdown, 1}
    end

    test "raises when the dir does not exist" do
      assert_raise Mix.Error, ~r/does not exist/, fn ->
        Suite.run(["--dir", "/tmp/nonexistent_suite_dir_42891"])
      end
    end
  end
end
