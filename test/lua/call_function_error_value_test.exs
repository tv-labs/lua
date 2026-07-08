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

  alias Lua.VM.TypeError

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

    test "a stdlib bad-argument ArgumentError stays a terse one-line string" do
      {ref, lua} = fun!(~S|function() for i in pairs("asdf") do end end|)

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, ref, [])

      assert is_binary(reason)
      assert reason =~ "bad argument #1 to 'pairs'"
      assert reason =~ "table expected"
      assert reason =~ "got string"
      refute reason =~ "\e["
      refute reason =~ "at -no-source-"
      refute reason =~ "\n"
    end
  end

  describe "call_function/3 on a name that does not resolve to a function" do
    test "an undefined name names what was looked up, not the resolved nil" do
      {_, lua} = Lua.eval!(Lua.new(), "function foo() return 1 end")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, [:bar], [])

      # Regression: previously reported the resolved value ("undefined
      # function 'nil'"). It must name the requested global instead.
      assert reason == "attempt to call a nil value (global 'bar')"
    end

    test "an existing non-function value reports its type, not 'undefined'" do
      {_, lua} = Lua.eval!(Lua.new(), "x = 5")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, [:x], [])

      assert reason == "attempt to call a number value (global 'x')"
    end

    test "a nested path attributes to the final field" do
      {_, lua} = Lua.eval!(Lua.new(), "t = {}")

      assert {:error, reason, %Lua{}} = Lua.call_function(lua, [:t, :missing], [])

      assert reason == "attempt to call a nil value (field 'missing')"
    end
  end

  describe "call_function!/3 on an unresolved name keeps the rich render" do
    test "raises with the location-less rich render and a suggestion" do
      {_, lua} = Lua.eval!(Lua.new(), "function foo() return 1 end")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, [:bar], [])
        end

      message = Exception.message(error)
      assert message =~ "attempt to call a nil value (global 'bar')"
      assert message =~ "Suggestion:"
      # No Lua source position exists for a programmatic call, so no
      # `at <source>:<line>:` header is rendered.
      refute message =~ ~r/at \S+:\d+:/
    end

    test "the original TypeError carries the structured call-nil kind" do
      {_, lua} = Lua.eval!(Lua.new(), "function foo() return 1 end")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, [:bar], [])
        end

      assert %TypeError{error_kind: :call_nil} = error.original
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

    test "ArgumentError reason has no escape codes when ANSI is enabled" do
      previous = Application.get_env(:elixir, :ansi_enabled)
      Application.put_env(:elixir, :ansi_enabled, true)
      on_exit(fn -> Application.put_env(:elixir, :ansi_enabled, previous) end)

      assert IO.ANSI.enabled?()

      {ref, lua} = fun!(~S|function() pairs("asdf") end|)
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

  describe "call_function!/3 preserves the original VM exception via :original" do
    test "ArgumentError passes through with all structured fields" do
      {ref, lua} = fun!(~S|function() pairs("asdf") end|)

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, ref, [])
        end

      assert %Lua.VM.ArgumentError{
               function_name: "pairs",
               arg_num: 1,
               expected: "table",
               got: "string"
             } = error.original
    end

    test "RuntimeError from error() passes through with its Lua value" do
      {ref, lua} = fun!("function() error('boom') end")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, ref, [])
        end

      assert %Lua.VM.RuntimeError{value: "boom"} = error.original
    end

    test "TypeError passes through with error_kind for programmatic dispatch" do
      {ref, lua} = fun!("function() local t = nil; return t.x end")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, ref, [])
        end

      assert %TypeError{error_kind: :index_non_table} = error.original
    end
  end

  describe "call_function!/3 rich render attributes the right source:line" do
    test "ArgumentError raised from a stdlib call inside a compiled chunk" do
      code = """
      function foo()
        pairs("asdf")
      end
      """

      {_, lua} = Lua.eval!(Lua.new(), code, source: "regression.lua")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, [:foo], [])
        end

      message = Exception.message(error)
      assert message =~ "regression.lua:2:"
      assert message =~ "bad argument #1 to 'pairs'"
      assert error.original.line == 2
      assert error.original.source == "regression.lua"
    end

    test "ArgumentError raised inside a generic_for loop body attributes the call line" do
      code = """
      function foo()
        for i in pairs("asdf") do
          print(i)
        end
      end
      """

      {_, lua} = Lua.eval!(Lua.new(), code, source: "regression.lua")

      error =
        assert_raise Lua.RuntimeException, fn ->
          Lua.call_function!(lua, [:foo], [])
        end

      assert error.original.line == 2
      assert Exception.message(error) =~ "regression.lua:2:"
    end
  end
end
