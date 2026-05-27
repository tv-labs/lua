defmodule Lua.VM.AssertionError do
  @moduledoc """
  Raised by the Lua `assert()` function when the condition is falsy.

  When raised without explicit `:line` / `:source` opts, `exception/1`
  populates them from the calling Lua source position via
  `Lua.VM.Executor.current_position/0`.
  """

  alias Lua.VM.ErrorFormatter

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
    ErrorFormatter.to_map(:assertion_error, raw_message(error.value),
      source: error.source,
      line: error.line,
      call_stack: error.call_stack,
      source_code: Keyword.get(opts, :source_code)
    )
  end

  defp format_message(value, source, line, call_stack) do
    ErrorFormatter.format(:assertion_error, raw_message(value),
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp raw_message(value), do: "assertion failed: #{stringify(value)}"

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
