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

  describe "os filesystem functions (virtual filesystem)" do
    test "os.tmpname returns a virtual path and creates no host file" do
      lua = Lua.new(sandboxed: [])
      {[name], _} = Lua.eval!(lua, "return os.tmpname()")
      assert is_binary(name)
      assert String.starts_with?(name, "/tmp/lua_")
      refute File.exists?(name)
    end

    test "os.remove deletes a seeded VFS file and returns true" do
      lua = [sandboxed: []] |> Lua.new() |> Lua.write_file("/scratch.txt", "data")

      {[ok], lua} = Lua.eval!(lua, ~S[return os.remove("/scratch.txt")])
      assert ok == true

      {[exists], _} =
        Lua.eval!(lua, ~S[local f = os.remove("/scratch.txt"); return f])

      assert exists == nil
    end

    test "os.remove on a missing file returns nil and a message" do
      lua = Lua.new(sandboxed: [])
      {[result, message], _} = Lua.eval!(lua, ~S[return os.remove("/nope.txt")])
      assert result == nil
      assert is_binary(message)
      assert message =~ "/nope.txt"
    end

    test "os.rename moves file contents within the VFS" do
      lua = [sandboxed: []] |> Lua.new() |> Lua.write_file("/from.txt", "hello")

      {[ok], lua} = Lua.eval!(lua, ~S[return os.rename("/from.txt", "/to.txt")])
      assert ok == true

      # The source is gone after the move.
      {[from_result | _], lua} = Lua.eval!(lua, ~S[return os.remove("/from.txt")])
      assert from_result == nil

      # The destination holds the moved contents and is then removable.
      {[to_result | _], _} = Lua.eval!(lua, ~S[return os.remove("/to.txt")])
      assert to_result == true
    end
  end
end
