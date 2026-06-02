defmodule Lua.VM.LimitsTest do
  @moduledoc """
  Pins the resource ceilings that turn allocation-bomb DoS attempts into
  catchable Lua errors instead of host out-of-memory crashes.

  Each oversized operation must (a) fail rather than allocate, and (b) be
  catchable with `pcall`, so embedding code can recover. The companion
  checks assert that ordinary, in-bounds calls are untouched.
  """
  use ExUnit.Case, async: true

  setup do
    %{lua: Lua.new(sandboxed: [])}
  end

  defp pcall_error(lua, expr) do
    {[false, message], _} = Lua.eval!(lua, "return pcall(function() #{expr} end)")
    message
  end

  describe "string.rep" do
    test "refuses an oversized single allocation", %{lua: lua} do
      assert pcall_error(lua, ~s|return string.rep("x", 1e15)|) =~ "resulting string too large"
    end

    test "still repeats in-bounds strings", %{lua: lua} do
      assert {["ababab"], _} = Lua.eval!(lua, ~s|return string.rep("ab", 3)|)
      assert {["a-a-a"], _} = Lua.eval!(lua, ~s|return string.rep("a", 3, "-")|)
    end
  end

  describe "string concatenation (..)" do
    test "refuses a doubling bomb before it exhausts memory", %{lua: lua} do
      code = "local s = 'x' for _ = 1, 80 do s = s .. s end return s"
      assert pcall_error(lua, code) =~ "resulting string too large"
    end

    test "still concatenates ordinary strings", %{lua: lua} do
      assert {["foobar42"], _} = Lua.eval!(lua, ~s|return "foo" .. "bar" .. 42|)
    end
  end

  describe "string.format" do
    test "refuses an oversized precision field", %{lua: lua} do
      assert pcall_error(lua, ~s|return string.format("%.2000000000f", 1.0)|) =~
               "invalid conversion"
    end

    test "still formats ordinary specs", %{lua: lua} do
      assert {["3.142"], _} = Lua.eval!(lua, ~s|return string.format("%.3f", 3.14159)|)
    end
  end

  describe "table.concat" do
    test "refuses an oversized range", %{lua: lua} do
      assert pcall_error(lua, ~s|return table.concat({1, 2}, ",", 1, 20000000)|) =~
               "range too large"
    end

    test "still concatenates ordinary tables", %{lua: lua} do
      assert {["1,2,3"], _} = Lua.eval!(lua, ~s|return table.concat({1, 2, 3}, ",")|)
    end
  end

  describe "table.move" do
    test "refuses an oversized range", %{lua: lua} do
      assert pcall_error(lua, ~s|local t = {} return table.move(t, 1, 20000000, 1)|) =~
               "range too large"
    end

    test "still moves ordinary ranges", %{lua: lua} do
      code = "local t = {1, 2, 3} table.move(t, 1, 3, 2) return t[2], t[3], t[4]"
      assert {[1, 2, 3], _} = Lua.eval!(lua, code)
    end
  end

  describe "load reader" do
    test "refuses a reader that never signals end-of-input", %{lua: lua} do
      # A reader returning a 1 MiB chunk forever would accumulate without
      # bound; the byte cap stops it with the string ceiling's message.
      # The reader's error propagates out of `load`, so it surfaces via pcall.
      code = ~s|
        local chunk = string.rep("a", 1024 * 1024)
        load(function() return chunk end)
      |

      assert pcall_error(lua, code) =~ "resulting string too large"
    end
  end
end
