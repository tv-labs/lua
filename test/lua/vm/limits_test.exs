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

    test "table.concat honors a lowered ceiling", %{small: small} do
      # 32 references to one 64-byte string: the table holds 64 bytes of
      # string data, the joined result would be 2048.
      repeated = ~s|local s = string.rep("x", 64) local t = {} for i = 1, 32 do t[i] = s end return table.concat(t)|
      assert pcall_error(small, repeated) =~ "resulting string too large"

      # The elements alone fit (600 bytes); the separators push it over.
      separated = ~s|local t = {} for i = 1, 600 do t[i] = "x" end return table.concat(t, "--")|
      assert pcall_error(small, separated) =~ "resulting string too large"
    end

    test "table.concat keeps __index side effects when the ceiling trips", %{small: small} do
      code = """
      local reads = 0
      local s = string.rep("x", 64)
      local t = setmetatable({}, {__index = function()
        reads = reads + 1
        return s
      end})
      local ok, err = pcall(table.concat, t, "", 1, 32)
      return ok, tostring(err), reads
      """

      assert {[false, message, 32], _} = Lua.eval!(small, code)
      assert message =~ "resulting string too large"
    end

    test "table.concat still builds a result exactly at the ceiling", %{small: small} do
      code = ~s|local s = string.rep("x", 64) local t = {} for i = 1, 16 do t[i] = s end return #table.concat(t)|
      assert {[1024], _} = Lua.eval!(small, code)
    end

    test "string.gsub honors a lowered ceiling for string and table replacements", %{small: small} do
      for repl <- [~s|string.rep("y", 32)|, ~s|{x = string.rep("y", 32)}|] do
        code = ~s|return string.gsub(string.rep("x", 64), ".", #{repl})|
        assert pcall_error(small, code) =~ "resulting string too large"
      end
    end

    test "string.gsub counts capture expansions against the ceiling", %{small: small} do
      # One match, one replacement: `%0%0` doubles the 600-byte match.
      assert pcall_error(small, ~s|return string.gsub(string.rep("x", 600), ".+", "%0%0")|) =~
               "resulting string too large"
    end

    test "string.gsub honors a lowered ceiling for an anchored pattern", %{small: small} do
      code = ~s|return string.gsub(string.rep("x", 1024), "^x", string.rep("y", 1024))|
      assert pcall_error(small, code) =~ "resulting string too large"
    end

    test "string.gsub counts the unmatched remainder against the ceiling", %{small: small} do
      # Replacements stop after one (max_n = 1) at 1001 bytes; the 99
      # untouched bytes that follow take the result to 1100.
      code = ~s|return string.gsub(string.rep("x", 100), "x", string.rep("y", 1001), 1)|
      assert pcall_error(small, code) =~ "resulting string too large"
    end

    test "string.gsub still builds a result exactly at the ceiling", %{small: small} do
      assert {[1024, 512], _} =
               Lua.eval!(small, ~s|local s, n = string.gsub(string.rep("x", 512), ".", "yy") return #s, n|)

      # A full-size subject is fine when the replacements shrink it.
      assert {["", 1024], _} = Lua.eval!(small, ~s|return string.gsub(string.rep("x", 1024), "x", "")|)
    end

    test "string.gsub keeps callback side effects when the ceiling trips", %{small: small} do
      code = """
      local calls = 0
      local y = string.rep("y", 32)
      local ok, err = pcall(string.gsub, string.rep("x", 64), ".", function()
        calls = calls + 1
        return y
      end)
      return ok, tostring(err), calls
      """

      # 32 replacements fill the ceiling exactly; the 33rd is refused.
      assert {[false, message, 33], _} = Lua.eval!(small, code)
      assert message =~ "resulting string too large"
    end

    test "string.format honors a lowered ceiling", %{small: small} do
      code = ~s|local s = string.rep("x", 1024) return string.format("%s%s", s, s)|
      assert pcall_error(small, code) =~ "resulting string too large"

      at_ceiling = ~s|local s = string.rep("x", 512) return #string.format("%s%s", s, s)|
      assert {[1024], _} = Lua.eval!(small, at_ceiling)
    end

    test "string.format counts width padding against the ceiling", %{small: small} do
      # Each field pads to 64 bytes: 16 land exactly on the ceiling, 17 go
      # over. `%64s` pads a string; `%064d` zero-fills after a minus sign.
      for spec <- ["%64s", "%064d"] do
        padded = fn fields ->
          ~s|local t = {} for i = 1, #{fields} do t[i] = -i end return #string.format(string.rep("#{spec}", #{fields}), table.unpack(t))|
        end

        assert {[1024], _} = Lua.eval!(small, padded.(16))
        assert pcall_error(small, padded.(17)) =~ "resulting string too large"
      end
    end

    test "string.pack honors a lowered ceiling", %{small: small} do
      # A fixed-size field is padded to its declared width.
      assert pcall_error(small, ~s|return string.pack("c2048", "")|) =~ "resulting string too large"

      # Variable-length fields: the same argument packed twice, and a
      # length prefix that tips an otherwise in-bounds string over.
      assert pcall_error(small, ~s|local s = string.rep("x", 600) return string.pack("zz", s, s)|) =~
               "resulting string too large"

      assert pcall_error(small, ~s|return string.pack("s", string.rep("x", 1020))|) =~
               "resulting string too large"

      # An eight-byte integer after 1020 bytes: 1028.
      assert pcall_error(small, ~s|return string.pack("c1020j", "", 0)|) =~ "resulting string too large"

      assert {[1024], _} = Lua.eval!(small, ~s|return #string.pack("c1024", "")|)
    end

    test "os.date honors a lowered ceiling", %{small: small} do
      # `%c` expands 2 format bytes into 24.
      assert pcall_error(small, ~s|return os.date(string.rep("%c", 100))|) =~ "resulting string too large"

      # `%Y` at the epoch is 4 bytes: 256 of them land exactly on the
      # ceiling, 257 go over.
      assert {[1024], _} = Lua.eval!(small, ~s|return #os.date(string.rep("%Y", 256), 0)|)

      assert pcall_error(small, ~s|return os.date(string.rep("%Y", 257), 0)|) =~
               "resulting string too large"
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

      assert {[2048], _} =
               Lua.eval!(unbounded, ~s|return #(string.gsub(string.rep("x", 64), ".", string.rep("y", 32)))|)
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
