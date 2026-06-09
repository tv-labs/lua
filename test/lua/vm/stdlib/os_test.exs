defmodule Lua.VM.Stdlib.OsTest do
  use ExUnit.Case, async: true

  # Regression coverage for Lua 5.3 suite: all.lua line 57
  # (`local initclock = os.clock()`), which raised
  # "attempt to call a nil value (field 'clock' on global 'os')"
  # before the os library existed.

  describe "os library" do
    test "os.clock returns a non-negative number" do
      {[c], _} = Lua.eval!("return os.clock()")
      assert is_number(c)
      assert c >= 0
    end

    test "os.time with no args returns current epoch seconds" do
      {[t], _} = Lua.eval!("return os.time()")
      assert is_integer(t)
      assert t > 1_500_000_000
    end

    test "os.time builds an epoch from a date table (UTC)" do
      code = "return os.time({year=2000, month=1, day=1, hour=0, min=0, sec=0})"
      {[t], _} = Lua.eval!(code)
      assert t == 946_684_800
    end

    test "os.time_ms returns the current epoch in milliseconds" do
      {[t], _} = Lua.eval!("return os.time_ms()")
      assert is_integer(t)
      assert t > 1_500_000_000_000
    end

    test "os.time_us returns the current epoch in microseconds" do
      {[t], _} = Lua.eval!("return os.time_us()")
      assert is_integer(t)
      assert t > 1_500_000_000_000_000
    end

    test "os.time_ms and os.time_us share the same magnitude as os.time" do
      {[secs, ms, us], _} = Lua.eval!("return os.time(), os.time_ms(), os.time_us()")
      assert div(ms, 1000) in (secs - 2)..(secs + 2)
      assert div(us, 1_000_000) in (secs - 2)..(secs + 2)
    end

    test "os.difftime returns the difference in seconds" do
      {[d], _} = Lua.eval!("return os.difftime(10, 3)")
      assert d == 7.0
    end

    test "os.date formats with strftime directives" do
      code = ~S[return os.date("!%Y-%m-%d", 946684800)]
      {[s], _} = Lua.eval!(code)
      assert s == "2000-01-01"
    end

    test "os.date with *t returns a broken-down time table" do
      code = """
      local t = os.date("!*t", 946684800)
      return t.year, t.month, t.day, t.hour, t.min, t.sec
      """

      {[year, month, day, hour, min, sec], _} = Lua.eval!(code)
      assert {year, month, day, hour, min, sec} == {2000, 1, 1, 0, 0, 0}
    end

    test "os.setlocale reports the C locale" do
      {[locale], _} = Lua.eval!(~S[return os.setlocale("C")])
      assert locale == "C"
    end

    test "os.getenv returns nil for an undefined variable when not sandboxed" do
      lua = Lua.new(sandboxed: [])
      {[v], _} = Lua.eval!(lua, ~S[return os.getenv("LUA_NONEXISTENT_VAR_XYZ")])
      assert v == nil
    end

    test "os.getenv is sandboxed by default" do
      assert_raise Lua.RuntimeException, ~r/os\.getenv.*sandboxed/, fn ->
        Lua.eval!(~S[return os.getenv("PATH")])
      end
    end
  end
end
