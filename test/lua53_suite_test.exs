defmodule Lua.Lua53SuiteTest do
  use ExUnit.Case, async: true

  import Lua.TestCase

  @moduletag :lua53

  @test_dir "test/lua53_tests"
  @skip_file "test/lua53_skips.exs"

  # Dynamically generate test cases for all .lua files in the test directory.
  # This ensures we don't miss any tests as the suite evolves.
  @lua_files @test_dir
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".lua"))
             |> Enum.sort()

  # Per-file skip ranges. See test/lua53_skips.exs for shape and conventions.
  @external_resource @skip_file
  @skip_map Lua.SuiteRunner.load_skip_map!(@skip_file)

  # Suite files that we have deliberately decided not to support.
  #
  # These are *not* "missing features we'd take a PR for" — they exercise
  # capabilities that conflict with this library's role as a sandboxed
  # embedded Lua VM. Each entry pairs the file with a one-line reason.
  # See ROADMAP.md "Deferred (intentional, not in 1.0)" for the full
  # rationale.
  @deferred_permanent %{
    # Tests the standalone Lua interpreter binary: shells out via
    # os.execute(), writes Lua programs to temp files, invokes `lua` as
    # a subprocess. We are an embedded VM with no shell-out and no
    # standalone interpreter.
    "main.lua" => "tests standalone interpreter (os.execute, subprocess invocation)",

    # Tests file I/O end-to-end: io.open/input/output/lines/read/write,
    # io.tmpfile, plus os.getenv("PATH"), os.remove, os.rename. We do
    # not ship filesystem I/O — io.* is a stub by design.
    "files.lua" => "tests filesystem I/O (io.open, os.getenv, os.remove)",

    # Tests `require` semantics that depend on writing files to disk
    # and dynamically loading them (libs/A.lua, libs/B.lua, etc.), plus
    # equality checks like `require"io" == io` that require io/os/
    # coroutine globals we do not stub. See A4 plan Discoveries.
    "attrib.lua" => "tests require semantics that depend on filesystem I/O",

    # Tests RK opcodes and >64K constants by writing a generated Lua
    # program to a temp file via os.tmpname()/io.output() and dofile()-
    # ing it. The compiler/VM behaviour being exercised is interesting,
    # but the test harness requires file I/O. A future plan could stub
    # tmpname/io/dofile for the suite runner only; not in scope here.
    "verybig.lua" => "tests dofile()-of-tmpfile harness for >64K constants"
  }

  @runnable_files @lua_files -- Map.keys(@deferred_permanent)

  describe "Lua 5.3 Test Suite" do
    for file <- @runnable_files do
      entries = Map.get(@skip_map, file, [])
      whole_file? = Enum.any?(entries, &(&1.lines == :all))
      ranges = entries |> Enum.reject(&(&1.lines == :all)) |> Enum.map(& &1.lines)

      @test_file file
      @ranges ranges

      cond do
        whole_file? ->
          @tag :skip
          test "#{file} (pending initial triage)" do
            run_lua_file(Path.join(@test_dir, @test_file))
          end

        ranges == [] ->
          test file do
            run_lua_file(Path.join(@test_dir, @test_file))
          end

        true ->
          skipped =
            Enum.reduce(ranges, 0, fn r, acc -> Enum.count(r) + acc end)

          test "#{file} (#{skipped} lines skipped, #{length(ranges)} ranges)" do
            run_lua_file(Path.join(@test_dir, @test_file), skip_ranges: @ranges)
          end
      end
    end
  end

  describe "Lua 5.3 Test Suite - Deferred (Intentional Non-Goals)" do
    for {test_file, reason} <- @deferred_permanent do
      @test_file test_file
      @tag :skip
      @tag :deferred_permanent
      test "#{test_file} — #{reason}" do
        run_lua_file(Path.join(@test_dir, @test_file))
      end
    end
  end
end
