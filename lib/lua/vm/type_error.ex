defmodule Lua.VM.TypeError do
  @moduledoc """
  Raised when a Lua operation is applied to a value of the wrong type.

  Examples: calling a nil value, calling a number, indexing a boolean.
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
    error_msg = stringify(value)

    Lua.VM.ErrorFormatter.format(:type_error, error_msg,
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
