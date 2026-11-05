defmodule Lua.VM.DeadlineTest do
  @moduledoc """
  Pins `Lua.set_deadline/2`: once the deadline passes, running Lua raises a
  catchable `"deadline exceeded"` error on both the interpreter and the
  compiled-dispatcher path, a `pcall` that traps it cannot keep the script
  running, and a host can give a nested call a shorter deadline so only that
  call fails.
  """
  use ExUnit.Case, async: true

  alias Lua.RuntimeException

  defp now, do: System.monotonic_time(:millisecond)
  defp passed(lua), do: Lua.set_deadline(lua, now())

  test "no deadline by default" do
    assert Lua.deadline(Lua.new()) == :infinity
    assert {[45], _lua} = Lua.eval!(Lua.new(), "local s = 0 for i = 1, 9 do s = s + i end return s")
  end

  test "set_deadline/2 and deadline/1 round-trip" do
    lua = Lua.set_deadline(Lua.new(), 123)
    assert Lua.deadline(lua) == 123
    assert Lua.deadline(Lua.set_deadline(lua, :infinity)) == :infinity
  end

  test "a passed deadline ends a top-level loop" do
    assert_raise RuntimeException, ~r/deadline exceeded/, fn ->
      Lua.eval!(passed(Lua.new()), "while true do end")
    end
  end

  test "a passed deadline ends a loop in a compiled function" do
    assert_raise RuntimeException, ~r/deadline exceeded/, fn ->
      Lua.eval!(passed(Lua.new()), "local function spin() while true do end end spin()")
    end
  end

  test "a passed deadline ends unbounded recursion" do
    assert_raise RuntimeException, ~r/deadline exceeded/, fn ->
      Lua.eval!(passed(Lua.new()), "local function f() return f() end f()")
    end
  end

  test "the deadline is read from the clock, not fixed when the call starts" do
    lua = Lua.set_deadline(Lua.new(), now() + 50)
    started = now()

    assert_raise RuntimeException, ~r/deadline exceeded/, fn ->
      Lua.eval!(lua, "while true do end")
    end

    assert now() - started >= 50
  end

  test "work that finishes before the deadline is not interrupted" do
    lua = Lua.set_deadline(Lua.new(), now() + 60_000)

    assert {[500_000_500_000], _lua} =
             Lua.eval!(lua, "local s = 0 for i = 1, 1000000 do s = s + i end return s")
  end

  test "pcall traps the error, which comes back on the next ticks" do
    {[false, message], _lua} =
      Lua.eval!(passed(Lua.new()), "return pcall(function() while true do end end)")

    assert message =~ "deadline exceeded"

    assert_raise RuntimeException, ~r/deadline exceeded/, fn ->
      Lua.eval!(passed(Lua.new()), """
      local spin = function() while true do end end
      while true do pcall(spin) end
      """)
    end
  end

  test "heap effects before the error are kept" do
    lua = passed(Lua.new())
    {[false, _message], lua} = Lua.eval!(lua, "return pcall(function() seen = 1 while true do end end)")
    assert {[1], _lua} = lua |> Lua.set_deadline(:infinity) |> Lua.eval!("return seen")
  end

  test "the instruction budget still applies with a deadline set" do
    lua = [max_instructions: 1000] |> Lua.new() |> Lua.set_deadline(now() + 60_000)

    assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
      Lua.eval!(lua, "while true do end")
    end
  end

  test "a host gives a nested call its own deadline, and only that call fails" do
    # The Elixir function stands in for a host that calls back into Lua while an outer
    # call waits on it: the callback runs on the same state with a passed deadline, the
    # error ends it, and the outer call carries on once the old deadline is back.
    lua =
      Lua.set!(Lua.new(), [:host_call], fn [callback], lua ->
        outer = Lua.deadline(lua)
        nested = Lua.set_deadline(lua, now())

        {result, lua} =
          case Lua.call_function(nested, callback, []) do
            {:ok, _values, lua} -> {"finished", lua}
            {:error, %RuntimeException{} = error, lua} -> {Exception.message(error), lua}
          end

        {[result], Lua.set_deadline(lua, outer)}
      end)

    {[message, total], _lua} =
      Lua.eval!(lua, """
      local message = host_call(function() while true do end end)
      local s = 0
      for i = 1, 100000 do s = s + i end
      return message, s
      """)

    assert message =~ "deadline exceeded"
    assert total == 5_000_050_000
  end
end
