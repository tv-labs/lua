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

  describe ":max_string_bytes option" do
    # A 1 KB ceiling keeps these tests allocation-free while exercising
    # every guard site at a size far below the default 256 MiB bound —
    # the behavior an embedder relies on when running the VM under a
    # process heap cap.
    setup do
      %{small: Lua.new(sandboxed: [], max_string_bytes: 1024)}
    end

    test "string.rep honors a lowered ceiling", %{small: small} do
      assert pcall_error(small, ~s|return string.rep("x", 2048)|) =~
               "resulting string too large"

      assert {["xxxx"], _} = Lua.eval!(small, ~s|return string.rep("x", 4)|)
    end

    test "concatenation honors a lowered ceiling on both execution paths", %{small: small} do
      # Doubling from inside a function body exercises the compiled
      # dispatcher; the top-level loop exercises the interpreter.
      doubling = "local s = 'x' for _ = 1, 11 do s = s .. s end return s"
      assert pcall_error(small, doubling) =~ "resulting string too large"

      in_function = """
      local function grow()
        local s = "x"
        for _ = 1, 11 do s = s .. s end
        return s
      end
      local ok, err = pcall(grow)
      return ok, tostring(err)
      """

      assert {[false, message], _} = Lua.eval!(small, in_function)
      assert message =~ "resulting string too large"

      assert {["ab"], _} = Lua.eval!(small, ~s|return "a" .. "b"|)
    end

    test "load reader chunks honor a lowered ceiling", %{small: small} do
      code = """
      local piece = string.rep("-", 512)
      local n = 0
      local ok, err = pcall(load, function()
        n = n + 1
        if n > 8 then return "" end
        return piece
      end)
      return ok, tostring(err)
      """

      assert {[false, message], _} = Lua.eval!(small, code)
      assert message =~ "resulting string too large"
    end

    test "the default ceiling is unchanged", %{lua: lua} do
      # 1 MB is far under the 256 MiB default; must build fine.
      assert {[1_048_576], _} = Lua.eval!(lua, ~s|return #string.rep("x", 2^20)|)
    end

    test "rejects non-positive and non-integer values" do
      for bad <- [0, -1, "16m", 1.5] do
        assert_raise ArgumentError, ~r/:max_string_bytes must be a positive integer or :infinity/, fn ->
          Lua.new(max_string_bytes: bad)
        end
      end
    end

    test "accepts :infinity to disable the ceiling, uniform with its siblings" do
      # `:infinity` is a valid value (like `:max_call_depth`/`:max_instructions`)
      # and lifts the string-size guard entirely.
      unbounded = Lua.new(sandboxed: [], max_string_bytes: :infinity)

      # A build that trips the 1 KB ceiling above succeeds with no limit.
      assert {[8192], _} = Lua.eval!(unbounded, ~s|return #string.rep("x", 8192)|)
      assert {[result], _} = Lua.eval!(unbounded, ~s|return string.rep("x", 4) .. "y"|)
      assert result == "xxxxy"
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
