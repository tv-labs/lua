defmodule Lua.SuiteRunnerTest do
  use ExUnit.Case, async: true

  alias Lua.SuiteRunner

  @tmpdir Path.join(System.tmp_dir!(), "lua_suite_runner_test")

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

  describe "apply_skip_ranges/2" do
    test "returns source unchanged when no ranges are given" do
      source = "line one\nline two\nline three\n"
      assert SuiteRunner.apply_skip_ranges(source, []) == source
    end

    test "comments out lines in a single range, preserving total line count" do
      source = "a\nb\nc\nd\ne"
      out = SuiteRunner.apply_skip_ranges(source, [2..3])

      lines = String.split(out, "\n")
      assert length(lines) == 5
      assert Enum.at(lines, 0) == "a"
      assert String.starts_with?(Enum.at(lines, 1), "--")
      assert String.starts_with?(Enum.at(lines, 2), "--")
      assert Enum.at(lines, 3) == "d"
      assert Enum.at(lines, 4) == "e"
    end

    test "supports multiple disjoint ranges" do
      source = Enum.map_join(1..10, "\n", &"line#{&1}")
      out = SuiteRunner.apply_skip_ranges(source, [2..3, 7..8])

      lines = String.split(out, "\n")
      assert Enum.at(lines, 0) == "line1"
      assert String.starts_with?(Enum.at(lines, 1), "--")
      assert String.starts_with?(Enum.at(lines, 2), "--")
      assert Enum.at(lines, 3) == "line4"
      assert Enum.at(lines, 5) == "line6"
      assert String.starts_with?(Enum.at(lines, 6), "--")
      assert String.starts_with?(Enum.at(lines, 7), "--")
      assert Enum.at(lines, 8) == "line9"
    end
  end

  describe "run_file/2 — line preservation invariant" do
    # If apply_skip_ranges ever stops preserving line numbers, this test
    # catches it. The whole triage workflow depends on the line in the
    # error message matching the line in the source file.
    test "assertion error reports the original line number, with and without skip ranges" do
      # Eleven lines total; the failing assert is on line 11.
      source = """
      -- line 1 (filler)
      -- line 2
      -- line 3
      -- line 4
      -- line 5
      -- line 6
      -- line 7
      -- line 8
      -- line 9
      -- line 10
      assert(false, "boom")
      """

      path = write_lua("line_check.lua", source)

      {:error, err_no_skip} = SuiteRunner.run_file(path)
      {:error, err_with_skip} = SuiteRunner.run_file(path, skip_ranges: [2..4])

      assert err_no_skip.line == 11,
             "expected failing line to be 11 without skips, got #{inspect(err_no_skip.line)} (#{err_no_skip.__struct__})"

      assert err_with_skip.line == 11,
             "expected failing line to remain 11 after skipping 2..4, got #{inspect(err_with_skip.line)} (#{err_with_skip.__struct__})"
    end

    test "skipping the failing statement makes the file pass" do
      source = """
      local x = 1
      assert(false, "would fail")
      """

      path = write_lua("skipme.lua", source)

      assert {:error, _} = SuiteRunner.run_file(path)
      assert :ok = SuiteRunner.run_file(path, skip_ranges: [2..2])
    end
  end
end
