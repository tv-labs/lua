defmodule Lua.VM.LengthOperatorTest do
  @moduledoc """
  Pins Lua 5.3 §3.4.7: `#` applies to strings and tables (or any value with a
  `__len` metamethod); every other operand is a type error, never 0.
  """

  use ExUnit.Case, async: true

  defp run!(code) do
    {results, _lua} = Lua.eval!(Lua.new(), code)
    results
  end

  test "strings and tables have a length" do
    assert run!(~S(return #"abc", #{1, 2, 3}, #{})) == [3, 3, 0]
  end

  test "__len is honoured" do
    assert run!("return #setmetatable({}, {__len = function() return 7 end})") == [7]
  end

  for {literal, type} <- [{"nil", "nil"}, {"true", "boolean"}, {"5", "number"}, {"print", "function"}] do
    test "# on a #{type} value raises" do
      assert_raise Lua.RuntimeException, ~r/attempt to get length of a #{unquote(type)} value/, fn ->
        Lua.eval!(Lua.new(), "return #(#{unquote(literal)})")
      end
    end
  end

  test "the error is catchable with pcall" do
    assert [false, message] = run!("return pcall(function() return #nil end)")
    assert message =~ "attempt to get length of a nil value"
  end
end
