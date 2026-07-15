defmodule Lua.VM.InternalError do
  @moduledoc false

  # Internal VM exception. Never surfaces to the host directly — it is wrapped
  # into the public `Lua.RuntimeException` (kind: `:internal`) at the API
  # boundary.
  #
  # Raised for internal VM errors: bad native function returns, unimplemented
  # instructions, and other invariant violations.

  defexception [:value, :message]

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    message = Keyword.get(opts, :message) || stringify(value)

    %__MODULE__{value: value, message: message}
  end

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
