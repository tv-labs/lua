defmodule Lua.Lua53SuiteTest do
  use ExUnit.Case, async: true
  import Lua.TestCase

  @moduletag :lua53

  @test_dir "test/lua53_tests"

  # Helper to check if test file exists, skip if not
  defp run_test_file(filename) do
    path = Path.join(@test_dir, filename)

    if File.exists?(path) do
      run_lua_file(path)
    else
      skip_message = """
      Test file not found: #{filename}

      The Lua 5.3 test suite must be downloaded first.
      Run: mix lua.get_tests
      """

      ExUnit.Assertions.flunk(skip_message)
    end
  end

  describe "Lua 5.3 Test Suite - Infrastructure Test" do
    test "simple_test.lua" do
      run_test_file("simple_test.lua")
    end
  end

  describe "Lua 5.3 Test Suite - Basic Tests" do
    @tag :skip
    test "literals.lua" do
      run_test_file("literals.lua")
    end

    @tag :skip
    test "locals.lua" do
      run_test_file("locals.lua")
    end

    @tag :skip
    test "constructs.lua" do
      run_test_file("constructs.lua")
    end

    @tag :skip
    test "bitwise.lua" do
      run_test_file("bitwise.lua")
    end

    @tag :skip
    test "vararg.lua" do
      run_test_file("vararg.lua")
    end
  end

  describe "Lua 5.3 Test Suite - Standard Library Tests" do
    @tag :skip
    test "math.lua" do
      run_test_file("math.lua")
    end

    @tag :skip
    test "strings.lua" do
      run_test_file("strings.lua")
    end

    @tag :skip
    test "sort.lua" do
      run_test_file("sort.lua")
    end

    @tag :skip
    test "tpack.lua" do
      run_test_file("tpack.lua")
    end
  end

  describe "Lua 5.3 Test Suite - Metatable Tests" do
    @tag :skip
    test "events.lua" do
      run_test_file("events.lua")
    end

    @tag :skip
    test "closure.lua" do
      run_test_file("closure.lua")
    end

    @tag :skip
    test "calls.lua" do
      run_test_file("calls.lua")
    end
  end

  describe "Lua 5.3 Test Suite - Advanced Tests (Deferred)" do
    @tag :skip
    test "coroutine.lua - not yet supported" do
      # Coroutines not implemented yet
      run_test_file("coroutine.lua")
    end

    @tag :skip
    test "goto.lua - not yet supported" do
      # goto/labels not implemented yet
      run_test_file("goto.lua")
    end

    @tag :skip
    test "db.lua - not yet supported" do
      # Full debug library not implemented yet
      run_test_file("db.lua")
    end

    @tag :skip
    test "files.lua - not yet supported" do
      # Full io library not implemented yet
      run_test_file("files.lua")
    end

    @tag :skip
    test "gc.lua - not yet supported" do
      # GC metamethods not fully supported yet
      run_test_file("gc.lua")
    end
  end
end
