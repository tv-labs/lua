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

  # Lua 5.3 §6.9: date-table fields passed to os.time need not be within their
  # valid ranges; they are normalised the way C mktime does.
  describe "os.time field normalization" do
    test "day = 0 is the last day of the previous month" do
      assert normalize("year=2026, month=9, day=0") == {2026, 8, 31, 12, 0, 0}
      assert normalize("year=2026, month=3, day=0") == {2026, 2, 28, 12, 0, 0}
      assert normalize("year=2028, month=3, day=0") == {2028, 2, 29, 12, 0, 0}
    end

    test "day = 0 of month 1 rolls back into December of the previous year" do
      assert normalize("year=2026, month=1, day=0") == {2025, 12, 31, 12, 0, 0}
    end

    test "month past December rolls into the next year" do
      assert normalize("year=2026, month=13, day=1") == {2027, 1, 1, 12, 0, 0}
      assert normalize("year=2026, month=12 + 1, day=0") == {2026, 12, 31, 12, 0, 0}
      assert normalize("year=2026, month=14, day=1") == {2027, 2, 1, 12, 0, 0}
      assert normalize("year=2026, month=24, day=1") == {2027, 12, 1, 12, 0, 0}
      assert normalize("year=2026, month=25, day=0") == {2027, 12, 31, 12, 0, 0}
      assert normalize("year=2026, month=25, day=1") == {2028, 1, 1, 12, 0, 0}
      assert normalize("year=2026, month=100, day=1") == {2034, 4, 1, 12, 0, 0}
    end

    test "month below January rolls into the previous year" do
      assert normalize("year=2026, month=0, day=1") == {2025, 12, 1, 12, 0, 0}
      assert normalize("year=2026, month=-1, day=1") == {2025, 11, 1, 12, 0, 0}
      assert normalize("year=2026, month=-13, day=1") == {2024, 11, 1, 12, 0, 0}
    end

    test "day past the end of the month overflows into the next month" do
      assert normalize("year=2026, month=2, day=30") == {2026, 3, 2, 12, 0, 0}
      assert normalize("year=2028, month=2, day=30") == {2028, 3, 1, 12, 0, 0}
      assert normalize("year=2026, month=1, day=32") == {2026, 2, 1, 12, 0, 0}
      assert normalize("year=2026, month=1, day=400") == {2027, 2, 4, 12, 0, 0}
    end

    test "negative day counts back across months and years" do
      assert normalize("year=2026, month=1, day=-40") == {2025, 11, 21, 12, 0, 0}
    end

    test "time fields overflow and underflow across days" do
      assert normalize("year=2026, month=12, day=31, hour=25") == {2027, 1, 1, 1, 0, 0}
      assert normalize("year=2026, month=1, day=1, hour=0, min=0, sec=-10") == {2025, 12, 31, 23, 59, 50}
      assert normalize("year=2026, month=1, day=1, hour=0, min=90") == {2026, 1, 1, 1, 30, 0}
    end

    test "in-range fields are unchanged" do
      assert normalize("year=2000, month=1, day=1, hour=0, min=0, sec=0") == {2000, 1, 1, 0, 0, 0}
    end
  end

  defp normalize(fields) do
    code = """
    local t = os.date("!*t", os.time({#{fields}}))
    return t.year, t.month, t.day, t.hour, t.min, t.sec
    """

    {[year, month, day, hour, min, sec], _} = Lua.eval!(code)
    {year, month, day, hour, min, sec}
  end
end
