defmodule Lua.VM.RuntimeError do
  @moduledoc """
  Raised by the Lua `error()` function.

  Carries the original Lua error value, which may be any Lua type (string,
  number, table reference, etc.).
  """

  defexception [:value, :source, :message]

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source)
    message = Keyword.get(opts, :message) || format_message(value, source)

    %__MODULE__{value: value, source: source, message: message}
  end

  defp format_message(value, nil), do: "runtime error: #{stringify(value)}"
  defp format_message(value, source), do: "#{source}: runtime error: #{stringify(value)}"

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
