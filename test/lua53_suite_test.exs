defmodule Lua.Lua53SuiteTest do
  use ExUnit.Case, async: true
  import Lua.TestCase

  @moduletag :lua53

  @test_dir "test/lua53_tests"

  describe "Lua 5.3 Test Suite - Infrastructure Test" do
    test "simple_test.lua" do
      run_lua_file(Path.join(@test_dir, "simple_test.lua"))
    end
  end

  describe "Lua 5.3 Test Suite - Basic Tests" do
    @tag :pending
    test "literals.lua" do
      run_lua_file(Path.join(@test_dir, "literals.lua"))
    end

    @tag :pending
    test "locals.lua" do
      run_lua_file(Path.join(@test_dir, "locals.lua"))
    end

    @tag :pending
    test "constructs.lua" do
      run_lua_file(Path.join(@test_dir, "constructs.lua"))
    end

    @tag :pending
    test "bitwise.lua" do
      run_lua_file(Path.join(@test_dir, "bitwise.lua"))
    end

    @tag :pending
    test "vararg.lua" do
      run_lua_file(Path.join(@test_dir, "vararg.lua"))
    end
  end

  describe "Lua 5.3 Test Suite - Standard Library Tests" do
    @tag :pending
    test "math.lua" do
      run_lua_file(Path.join(@test_dir, "math.lua"))
    end

    @tag :pending
    test "strings.lua" do
      run_lua_file(Path.join(@test_dir, "strings.lua"))
    end

    @tag :pending
    test "sort.lua" do
      run_lua_file(Path.join(@test_dir, "sort.lua"))
    end

    @tag :pending
    test "tpack.lua" do
      run_lua_file(Path.join(@test_dir, "tpack.lua"))
    end
  end

  describe "Lua 5.3 Test Suite - Metatable Tests" do
    @tag :pending
    test "events.lua" do
      run_lua_file(Path.join(@test_dir, "events.lua"))
    end

    @tag :pending
    test "closure.lua" do
      run_lua_file(Path.join(@test_dir, "closure.lua"))
    end

    @tag :pending
    test "calls.lua" do
      run_lua_file(Path.join(@test_dir, "calls.lua"))
    end
  end

  describe "Lua 5.3 Test Suite - Advanced Tests (Deferred)" do
    @tag :pending
    test "coroutine.lua - not yet supported" do
      # Coroutines not implemented yet
      :skip
    end

    @tag :pending
    test "goto.lua - not yet supported" do
      # goto/labels not implemented yet
      :skip
    end

    @tag :pending
    test "db.lua - not yet supported" do
      # Full debug library not implemented yet
      :skip
    end

    @tag :pending
    test "files.lua - not yet supported" do
      # Full io library not implemented yet
      :skip
    end

    @tag :pending
    test "gc.lua - not yet supported" do
      # GC metamethods not fully supported yet
      :skip
    end
  end
end
