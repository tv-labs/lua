defmodule Lua.ExceptionAnsiGatingTest do
  @moduledoc """
  Locks the ANSI contract for rendered errors:

    * `Exception.message/1` is the plain, log-safe form — it never emits ANSI
      escapes, in any environment.
    * `Lua.format_exception/1` (and each VM error's `format/1`) is the rich
      form — it gates ANSI on `IO.ANSI.enabled?/0` evaluated *at render time*,
      never frozen at construction (issue #384). The reverse direction proves
      it is a gate, not a blanket strip.

  Each case builds the exception while ANSI is enabled (as it would be
  constructed inside a TTY-attached VM execution), then renders under both
  settings.

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
  # TTY-attached VM. The render must still consult the gate at call time.
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

  defp rich(%RuntimeError{} = e), do: RuntimeError.format(e)
  defp rich(%TypeError{} = e), do: TypeError.format(e)
  defp rich(%AssertionError{} = e), do: AssertionError.format(e)
  defp rich(%ArgumentError{} = e), do: ArgumentError.format(e)

  for {name, key} <- [
        {"RuntimeError", :runtime_error},
        {"TypeError", :type_error},
        {"AssertionError", :assertion_error},
        {"ArgumentError", :argument_error}
      ] do
    test "#{name}: Exception.message/1 is ANSI-free regardless of env" do
      exception = built_with_ansi_on(fn -> build(unquote(key)) end)

      refute Exception.message(exception) =~ "\e["

      Application.put_env(:elixir, :ansi_enabled, true)

      refute Exception.message(exception) =~ "\e[",
             "#{unquote(name)}: Exception.message/1 must never emit ANSI"
    end

    test "#{name}: format/1 carries no ANSI when disabled at render time" do
      exception = built_with_ansi_on(fn -> build(unquote(key)) end)

      refute rich(exception) =~ "\e[",
             "#{unquote(name)} froze ANSI at construction (issue #384)"
    end

    test "#{name}: format/1 carries ANSI when enabled at render time" do
      exception = built_with_ansi_on(fn -> build(unquote(key)) end)

      Application.put_env(:elixir, :ansi_enabled, true)
      assert rich(exception) =~ "\e[", "#{unquote(name)} should color on a TTY"
    end
  end

  describe "Lua.RuntimeException wrapper" do
    test "message stays plain; format_exception gates ANSI at render time" do
      exception =
        built_with_ansi_on(fn ->
          Lua.RuntimeException.exception(RuntimeError.exception(value: "kaboom", source: "demo", line: 1))
        end)

      refute Exception.message(exception) =~ "\e["
      refute Lua.format_exception(exception) =~ "\e["

      Application.put_env(:elixir, :ansi_enabled, true)
      refute Exception.message(exception) =~ "\e["
      assert Lua.format_exception(exception) =~ "\e["
    end
  end

  describe "Lua.CompilerException (parse errors)" do
    test "message stays plain; :errors stays ANSI-free; format_exception gates ANSI" do
      exception =
        built_with_ansi_on(fn ->
          {:error, exception} = Lua.parse_chunk("asdf")
          exception
        end)

      # The bare messages never carry escapes, in any environment.
      refute Enum.any?(exception.errors, &(&1 =~ "\e["))

      refute Exception.message(exception) =~ "\e["
      refute Lua.format_exception(exception) =~ "\e["

      Application.put_env(:elixir, :ansi_enabled, true)
      refute Exception.message(exception) =~ "\e["
      assert Lua.format_exception(exception) =~ "\e["
    end
  end
end
