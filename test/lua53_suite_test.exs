defmodule Lua.Lua53SuiteTest do
  use ExUnit.Case, async: true
  import Lua.TestCase

  @moduletag :lua53

  @test_dir "test/lua53_tests"

  # Dynamically generate test cases for all .lua files in the test directory
  # This ensures we don't miss any tests as the suite evolves
  @lua_files @test_dir
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".lua"))
             |> Enum.sort()

  # Tests that are ready to run (not skipped)
  @ready_tests ["simple_test.lua"]

  # Tests that require features not yet implemented
  # As we implement features, move tests from here to @ready_tests
  @skipped_tests @lua_files -- @ready_tests

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
end
