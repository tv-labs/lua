defmodule Lua.VM.TypeError do
  @moduledoc """
  Raised when a Lua operation is applied to a value of the wrong type.

  Examples: calling a nil value, calling a number, indexing a boolean.
  """

  defexception [:value, :source, :message, :call_stack, :line, :error_kind, :value_type]

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source)
    call_stack = Keyword.get(opts, :call_stack, [])
    line = Keyword.get(opts, :line)
    error_kind = Keyword.get(opts, :error_kind)
    value_type = Keyword.get(opts, :value_type)

    message =
      Keyword.get(opts, :message) ||
        format_message(value, source, line, call_stack, error_kind, value_type)

    %__MODULE__{
      value: value,
      source: source,
      message: message,
      call_stack: call_stack,
      line: line,
      error_kind: error_kind,
      value_type: value_type
    }
  end

  defp format_message(value, source, line, call_stack, error_kind, value_type) do
    error_msg = stringify(value)

    Lua.VM.ErrorFormatter.format(:type_error, error_msg,
      source: source,
      line: line,
      call_stack: call_stack,
      error_kind: error_kind,
      value_type: value_type
    )
  end

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
