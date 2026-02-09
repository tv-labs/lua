defmodule Lua.VM.AssertionError do
  @moduledoc """
  Raised by the Lua `assert()` function when the condition is falsy.
  """

  defexception [:value, :source, :message, :call_stack, :line]

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source)
    call_stack = Keyword.get(opts, :call_stack, [])
    line = Keyword.get(opts, :line)
    message = Keyword.get(opts, :message) || format_message(value, source, line, call_stack)

    %__MODULE__{
      value: value,
      source: source,
      message: message,
      call_stack: call_stack,
      line: line
    }
  end

  defp format_message(value, source, line, call_stack) do
    error_msg = "assertion failed: #{stringify(value)}"

    Lua.VM.ErrorFormatter.format(:assertion_error, error_msg,
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
