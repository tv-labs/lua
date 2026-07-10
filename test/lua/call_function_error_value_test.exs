defmodule Lua.CallFunctionErrorValueTest do
  @moduledoc """
  Pins the `Lua.call_function/3` protected-call boundary: its `{:error,
  exception, _}` payload is the VM exception struct itself — a
  `Lua.VM.RuntimeError`, `Lua.VM.TypeError`, or `Lua.VM.ArgumentError` —
  carried out verbatim. The boundary does no rendering: callers own that by
  calling `Exception.message/1`, and can pattern-match on the concrete struct
  and its structured fields. The raw Lua value handed to `error()` (§6.1) is
  preserved on the struct's `:value`, so pcall-parity data survives.

  The raising variant `call_function!/3` re-raises the same exception through
  `Lua.RuntimeException`, keeping the rich `ErrorFormatter` render.
  """
  use ExUnit.Case, async: true

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError
  alias Lua.VM.TypeError

  defp fun!(code) do
    {[ref], lua} = Lua.eval!(Lua.new(), "return #{code}", decode: false)
    {ref, lua}
  end

  describe "call_function/3 returns the VM exception struct" do
    test "error('boom') comes back as a RuntimeError carrying the raised value" do
      {ref, lua} = fun!("function() error('boom') end")

      assert {:error, %RuntimeError{value: "boom"} = error, %Lua{}} =
               Lua.call_function(lua, ref, [])

      assert Exception.message(error) =~ "boom"
    end

    test "a call-nil failure comes back as a TypeError struct" do
      {ref, lua} = fun!("function() local f = nil; f() end")

      assert {:error, %TypeError{error_kind: :call_nil} = error, %Lua{}} =
               Lua.call_function(lua, ref, [])

      assert Exception.message(error) =~ "attempt to call a nil value"
    end

    test "an index-nil failure comes back as a TypeError struct" do
      {ref, lua} = fun!("function() local t = nil; return t.x end")

      assert {:error, %TypeError{error_kind: :index_non_table} = error, %Lua{}} =
               Lua.call_function(lua, ref, [])

      assert Exception.message(error) =~ "attempt to index"
    end

    test "a stdlib bad-argument failure comes back as an ArgumentError struct" do
      {ref, lua} = fun!(~S|function() for i in pairs("asdf") do end end|)

      assert {:error, %ArgumentError{function_name: "pairs", arg_num: 1} = error, %Lua{}} =
               Lua.call_function(lua, ref, [])

      message = Exception.message(error)
      assert message =~ "bad argument #1 to 'pairs'"
      assert message =~ "table expected"
      assert message =~ "got string"
    end
  end

  describe "call_function/3 on a name that does not resolve to a function" do
    test "an undefined name names what was looked up, not the resolved nil" do
      {_, lua} = Lua.eval!(Lua.new(), "function foo() return 1 end")

      assert {:error, %TypeError{error_kind: :call_nil} = error, %Lua{}} =
               Lua.call_function(lua, [:bar], [])

      # Regression: previously reported the resolved value ("undefined
      # function 'nil'"). It must name the requested global instead.
      assert Exception.message(error) =~ "attempt to call a nil value (global 'bar')"
    end

    test "an existing non-function value reports its type, not 'undefined'" do
      {_, lua} = Lua.eval!(Lua.new(), "x = 5")

      assert {:error, %TypeError{} = error, %Lua{}} = Lua.call_function(lua, [:x], [])

      assert Exception.message(error) =~ "attempt to call a number value (global 'x')"
    end

    test "a nested path attributes to the final field" do
      {_, lua} = Lua.eval!(Lua.new(), "t = {}")

      assert {:error, %TypeError{} = error, %Lua{}} = Lua.call_function(lua, [:t, :missing], [])

      assert Exception.message(error) =~ "attempt to call a nil value (field 'missing')"
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

  describe "call_function/3 preserves the raised Lua value on the struct (pcall parity)" do
    test "a table error object is preserved on :value" do
      {ref, lua} = fun!("function() error({code = 1}) end")

      assert {:error, %RuntimeError{value: value}, %Lua{} = lua} = Lua.call_function(lua, ref, [])
      assert Lua.decode!(lua, value) == [{"code", 1}]
    end

    test "a number error object is preserved on :value" do
      {ref, lua} = fun!("function() error(42) end")

      assert {:error, %RuntimeError{value: 42}, %Lua{}} = Lua.call_function(lua, ref, [])
    end

    test "a nil error object is preserved on :value" do
      {ref, lua} = fun!("function() error(nil) end")

      assert {:error, %RuntimeError{value: nil}, %Lua{}} = Lua.call_function(lua, ref, [])
    end

    test "a false error object is preserved on :value" do
      {ref, lua} = fun!("function() error(false) end")

      assert {:error, %RuntimeError{value: false}, %Lua{}} = Lua.call_function(lua, ref, [])
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

      assert %ArgumentError{
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

      assert %RuntimeError{value: "boom"} = error.original
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
