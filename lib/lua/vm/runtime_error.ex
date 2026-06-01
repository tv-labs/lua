defmodule Lua.VM.RuntimeError do
  @moduledoc """
  Raised by the Lua `error()` function.

  Carries the original Lua error value, which may be any Lua type (string,
  number, table reference, etc.).

  When raised without explicit `:line` / `:source` opts (e.g. from a stdlib
  bad-argument check), `exception/1` populates them from the calling Lua
  source position via `Lua.VM.Executor.current_position/0`. That position
  is stashed in the process dictionary at every native-call boundary, so
  any raise site reachable from a Lua execution inherits the correct
  attribution automatically.
  """

  alias Lua.VM.ErrorFormatter
  alias Lua.VM.Value

  defexception [:value, :source, :message, :call_stack, :line]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source) || auto_source
    call_stack = Keyword.get(opts, :call_stack, [])
    line = Keyword.get(opts, :line) || auto_line
    message = Keyword.get(opts, :message) || format_message(value, source, line, call_stack)

    %__MODULE__{
      value: value,
      source: source,
      message: message,
      call_stack: call_stack,
      line: line
    }
  end

  @doc """
  Returns a wire-safe structured map for this error. See
  `Lua.VM.ErrorFormatter.to_map/3` for the shape.

  Pass `:source_code` to populate `source_context`.
  """
  def to_map(%__MODULE__{} = error, opts \\ []) do
    ErrorFormatter.to_map(:runtime_error, raw_message(error.value),
      source: error.source,
      line: error.line,
      call_stack: error.call_stack,
      source_code: Keyword.get(opts, :source_code)
    )
  end

  defp format_message(value, source, line, call_stack) do
    ErrorFormatter.format(:runtime_error, raw_message(value),
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp raw_message(value), do: "runtime error: #{stringify(value)}"

  # PUC-Lua renders string and number error objects verbatim, but any other
  # Lua value (table, function, boolean, nil, userdata) becomes the message
  # "(error object is a TYPE value)" rather than leaking an internal term.
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_integer(v) or is_float(v), do: Value.to_string(v)

  defp stringify(value) do
    "(error object is a #{Value.type_name(value)} value)"
  end
end
