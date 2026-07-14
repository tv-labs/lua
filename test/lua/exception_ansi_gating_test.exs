defmodule Lua.ExceptionAnsiGatingTest do
  @moduledoc """
  Locks the fix for issue #384: exceptions must render their message when
  `Exception.message/1` is called, gating ANSI on `IO.ANSI.enabled?/0` at that
  point — never freezing a TTY-colored render at construction time.

  Each case builds the exception while ANSI is enabled (as it would be
  constructed inside a TTY-attached VM execution), then renders with ANSI
  disabled and asserts no escape codes survive. The reverse direction proves
  it is a gate, not a blanket strip.

  Toggling `:ansi_enabled` mutates global application env, so this module is
  `async: false` to avoid racing tests that assert on plain-text output.
  """
  use ExUnit.Case, async: false

  alias Lua.VM.ArgumentError
  alias Lua.VM.AssertionError
  alias Lua.VM.RuntimeError
  alias Lua.VM.TypeError

  setup do
    on_exit(fn -> Application.put_env(:elixir, :ansi_enabled, false) end)
  end

  # Build each exception with ANSI enabled to simulate construction inside a
  # TTY-attached VM. `message/1` must still consult the gate at call time.
  defp built_with_ansi_on(build) do
    Application.put_env(:elixir, :ansi_enabled, true)
    exception = build.()
    Application.put_env(:elixir, :ansi_enabled, false)
    exception
  end

  defp build(:runtime_error), do: RuntimeError.exception(value: "kaboom", source: "demo", line: 1)

  defp build(:type_error),
    do: TypeError.exception(value: "attempt to call a nil value", source: "demo", line: 2, error_kind: :call_nil)

  defp build(:assertion_error), do: AssertionError.exception(value: "nope", source: "demo", line: 3)

  defp build(:argument_error),
    do: ArgumentError.exception(function_name: "string.rep", arg_num: 2, expected: "number", source: "demo", line: 2)

  for {name, key} <- [
        {"RuntimeError", :runtime_error},
        {"TypeError", :type_error},
        {"AssertionError", :assertion_error},
        {"ArgumentError", :argument_error}
      ] do
    test "#{name}: message carries no ANSI when disabled at render time" do
      exception = built_with_ansi_on(fn -> build(unquote(key)) end)

      refute Exception.message(exception) =~ "\e[",
             "#{unquote(name)} froze ANSI at construction (issue #384)"
    end

    test "#{name}: message carries ANSI when enabled at render time" do
      exception = built_with_ansi_on(fn -> build(unquote(key)) end)

      Application.put_env(:elixir, :ansi_enabled, true)
      assert Exception.message(exception) =~ "\e[", "#{unquote(name)} should color on a TTY"
    end
  end

  describe "Lua.RuntimeException wrapper" do
    test "does not freeze the wrapped VM exception's ANSI render" do
      exception =
        built_with_ansi_on(fn ->
          Lua.RuntimeException.exception(RuntimeError.exception(value: "kaboom", source: "demo", line: 1))
        end)

      refute Exception.message(exception) =~ "\e["

      Application.put_env(:elixir, :ansi_enabled, true)
      assert Exception.message(exception) =~ "\e["
    end
  end

  describe "Lua.CompilerException (parse errors)" do
    test "message gates ANSI at render time; :errors stays ANSI-free" do
      exception =
        built_with_ansi_on(fn ->
          {:error, exception} = Lua.parse_chunk("asdf")
          exception
        end)

      # The bare messages never carry escapes, in any environment.
      refute Enum.any?(exception.errors, &(&1 =~ "\e["))

      refute Exception.message(exception) =~ "\e["

      Application.put_env(:elixir, :ansi_enabled, true)
      assert Exception.message(exception) =~ "\e["
    end
  end
end
