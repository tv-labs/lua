defmodule Lua.Lua53SuiteTest do
  use ExUnit.Case, async: true

  import Lua.TestCase

  @moduletag :lua53

  @test_dir "test/lua53_tests"

  # Dynamically generate test cases for all .lua files in the test directory.
  # This ensures we don't miss any tests as the suite evolves.
  @lua_files @test_dir
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".lua"))
             |> Enum.sort()

  # Tests that are ready to run (not skipped).
  @ready_tests ["simple_test.lua", "api.lua", "bitwise.lua", "code.lua", "tpack.lua", "vararg.lua"]

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

  # Tests that require features not yet implemented. As we implement
  # features, move tests from here to @ready_tests.
  @skipped_tests (@lua_files -- @ready_tests) -- Map.keys(@deferred_permanent)

  describe "Lua 5.3 Test Suite - Ready Tests" do
    for test_file <- @ready_tests do
      @test_file test_file
      test test_file do
        run_lua_file(Path.join(@test_dir, @test_file))
      end
    end
  end

  describe "Lua 5.3 Test Suite - Skipped Tests (Missing Features)" do
    for test_file <- @skipped_tests do
      @test_file test_file
      @tag :skip
      test test_file do
        run_lua_file(Path.join(@test_dir, @test_file))
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
