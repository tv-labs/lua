defmodule Lua.CallFunctionErrorValueTest do
  @moduledoc """
  Pins the `Lua.call_function/3` protected-call boundary: its `{:error,
  reason, _}` is the programmatic Lua error value — exactly what `pcall`
  hands back (§6.1) — never the terminal-formatted render (ANSI, the
  `at <source>:<line>:` header, the `Suggestion:` block, a stack trace, or a
  doubled `Lua runtime error:` prefix).

  The raising variant `call_function!/3` is the opposite contract: it keeps
  the rich `ErrorFormatter` render on the `Lua.RuntimeException` it raises.
  """
  # async: false — one test toggles the global `:elixir` ANSI flag.
  use ExUnit.Case, async: false

  defp fun!(code) do
    {[ref], lua} = Lua.eval!(Lua.new(), "return #{code}", decode: false)
    {ref, lua}
  end

  describe "call_function/3 returns the terse Lua error value" do
    test "a string error is not terminal-formatted" do
      {ref, lua} = fun!("function() error('boom') end")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, ref, [])

      assert is_binary(reason)
      assert reason =~ "boom"
      refute reason =~ "\e["
      refute reason =~ "Suggestion"
      refute reason =~ "Lua runtime error:"
      refute reason =~ "runtime error:"
      refute reason =~ "\n"
    end

    test "a call-nil TypeError stays a terse one-line string" do
      {ref, lua} = fun!("function() local f = nil; f() end")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, ref, [])

      assert is_binary(reason)
      assert reason =~ "attempt to call a nil value"
      refute reason =~ "\e["
      refute reason =~ "Suggestion"
      refute reason =~ "\n"
    end

    test "an index-nil TypeError stays a terse one-line string" do
      {ref, lua} = fun!("function() local t = nil; return t.x end")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, ref, [])

      assert is_binary(reason)
      assert reason =~ "attempt to index"
      refute reason =~ "\e["
      refute reason =~ "\n"
    end
  end

  describe "call_function/3 passes non-string error objects through (pcall parity)" do
    test "a table error object passes through verbatim" do
      {ref, lua} = fun!("function() error({code = 1}) end")

      assert {:error, reason, %Lua{} = lua} = Lua.call_function(lua, ref, [])
      assert Lua.decode!(lua, reason) == [{"code", 1}]
    end

    test "a number error object passes through verbatim" do
      {ref, lua} = fun!("function() error(42) end")

      assert {:error, 42, %Lua{}} = Lua.call_function(lua, ref, [])
    end

    test "a nil error object passes through verbatim" do
      {ref, lua} = fun!("function() error(nil) end")

      assert {:error, nil, %Lua{}} = Lua.call_function(lua, ref, [])
    end

    test "a false error object passes through verbatim" do
      {ref, lua} = fun!("function() error(false) end")

      assert {:error, false, %Lua{}} = Lua.call_function(lua, ref, [])
    end
  end

  describe "call_function/3 reason carries no ANSI even with a TTY attached" do
    test "string error reason has no escape codes when ANSI is enabled" do
      previous = Application.get_env(:elixir, :ansi_enabled)
      Application.put_env(:elixir, :ansi_enabled, true)
      on_exit(fn -> Application.put_env(:elixir, :ansi_enabled, previous) end)

      assert IO.ANSI.enabled?()

      {ref, lua} = fun!("function() error('boom') end")
      assert {:error, reason, %Lua{}} = Lua.call_function(lua, ref, [])

      refute reason =~ "\e["
    end
  end

  describe "call_function!/3 keeps the rich render" do
    test "raises Lua.RuntimeException whose message carries the formatted render" do
      {ref, lua} = fun!("function() error('boom') end")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, ref, [])
        end

      message = Exception.message(error)
      assert message =~ "Lua runtime error:"
      assert message =~ "boom"
      # The rich render includes the raw-message body that the terse
      # programmatic reason deliberately omits.
      assert message =~ "runtime error:"
    end
  end
end
