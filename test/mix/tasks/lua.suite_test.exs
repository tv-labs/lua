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

  describe "--status" do
    test "summarises a fixture skip file with totals and categories" do
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{
        "a.lua" => [%{lines: :all, category: :unimplemented, reason: "t", issue: nil}],
        "b.lua" => [
          %{lines: 1..3, category: :stdlib, reason: "t", issue: 42},
          %{lines: 10..10, category: :executor, reason: "t", issue: nil}
        ]
      }
      """)

      output = capture_io(fn -> Suite.run(["--status", "--skip-file", skip_file]) end)

      assert output =~ "a.lua"
      assert output =~ ":all pending triage"
      assert output =~ "b.lua"
      assert output =~ "stdlib×1"
      assert output =~ "executor×1"
      assert output =~ "Total: 4 skipped lines across 2 ranges in 1 files. 1 files pending initial triage."
      assert output =~ "By category: stdlib 1, executor 1"
      assert output =~ "By issue: 1 ranges linked, 1 unassigned."
    end
  end

  describe "--audit" do
    test "reports CANDIDATE when a :all entry's file passes outright" do
      write_lua("passing.lua", "return 1\n")
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{"passing.lua" => [%{lines: :all, category: :unimplemented, reason: "t", issue: nil}]}
      """)

      output =
        capture_io(fn ->
          Suite.run(["--audit", "--dir", @tmpdir, "--skip-file", skip_file, "--timeout", "5000"])
        end)

      assert output =~ "passing.lua"
      assert output =~ "CANDIDATE"
      assert output =~ "1 promotion candidates"
    end

    test "reports STALE when a specific range is no longer needed" do
      write_lua("a.lua", "local x = 1\nreturn x\n")
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{"a.lua" => [%{lines: 1..1, category: :executor, reason: "t", issue: nil}]}
      """)

      output =
        capture_io(fn ->
          Suite.run(["--audit", "--dir", @tmpdir, "--skip-file", skip_file, "--timeout", "5000"])
        end)

      assert output =~ "a.lua:1"
      assert output =~ "STALE"
      assert output =~ "1 stale entries"
    end

    test "reports ACTIVE when a :all entry's file still fails without ranges" do
      write_lua("broken.lua", "assert(false, 'still bad')\n")
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{"broken.lua" => [%{lines: :all, category: :unimplemented, reason: "t", issue: nil}]}
      """)

      output =
        capture_io(fn ->
          Suite.run(["--audit", "--dir", @tmpdir, "--skip-file", skip_file, "--timeout", "5000"])
        end)

      assert output =~ "broken.lua"
      assert output =~ "ACTIVE"
      assert output =~ "first failure at line 1"
    end

    test "labels failures that lack a :line field with the exception name" do
      # Syntax garbage triggers Lua.CompilerException, which carries
      # formatted error messages but no top-level :line field. Audit
      # should fall back to a struct-name label instead of bare "?".
      write_lua("bad_syntax.lua", "@@@ not lua @@@\n")
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{"bad_syntax.lua" => [%{lines: :all, category: :unimplemented, reason: "t", issue: nil}]}
      """)

      output =
        capture_io(fn ->
          Suite.run(["--audit", "--dir", @tmpdir, "--skip-file", skip_file, "--timeout", "5000"])
        end)

      assert output =~ "bad_syntax.lua"
      assert output =~ "ACTIVE"
      assert output =~ "unknown line (CompilerException)"
    end
  end

  describe "skip-file validation" do
    test "raises when a file mixes lines: :all with specific ranges" do
      skip_file = Path.join(@tmpdir, "skips.exs")

      File.write!(skip_file, """
      %{
        "mixed.lua" => [
          %{lines: :all, category: :unimplemented, reason: "t", issue: nil},
          %{lines: 1..3, category: :stdlib, reason: "t", issue: nil}
        ]
      }
      """)

      assert_raise ArgumentError, ~r/mixed\.lua mixes `lines: :all`/, fn ->
        Suite.run(["--status", "--skip-file", skip_file])
      end
    end
  end
end
