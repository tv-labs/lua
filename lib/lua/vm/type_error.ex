defmodule Lua.VM.TypeError do
  @moduledoc """
  Raised when a Lua operation is applied to a value of the wrong type.

  Examples: calling a nil value, calling a number, indexing a boolean.

  When raised without explicit `:line` / `:source` opts (e.g. from a stdlib
  type check), `exception/1` populates them from the calling Lua source
  position via `Lua.VM.Executor.current_position/0`. That position is
  stashed in the process dictionary at every native-call boundary, so
  any raise site reachable from a Lua execution inherits the correct
  attribution automatically.
  """

  defexception [:value, :source, :message, :call_stack, :line, :error_kind, :value_type]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source) || auto_source
    call_stack = Keyword.get(opts, :call_stack, [])
    line = Keyword.get(opts, :line) || auto_line
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
