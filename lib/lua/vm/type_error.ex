defmodule Lua.VM.TypeError do
  @moduledoc """
  Raised when a Lua operation is applied to a value of the wrong type.

  Examples: calling a nil value, calling a number, indexing a boolean.
  """

  defexception [:value, :source, :message]

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    source = Keyword.get(opts, :source)
    message = Keyword.get(opts, :message) || format_message(value, source)

    %__MODULE__{value: value, source: source, message: message}
  end

  defp format_message(value, nil), do: stringify(value)
  defp format_message(value, source), do: "#{source}: #{stringify(value)}"

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
