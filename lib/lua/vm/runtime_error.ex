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

  defp format_message(value, source, line, call_stack) do
    error_msg = "runtime error: #{stringify(value)}"

    Lua.VM.ErrorFormatter.format(:runtime_error, error_msg,
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
