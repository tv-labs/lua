defmodule Lua.VM.InternalError do
  @moduledoc false

  # Internal VM exception. Never surfaces to the host directly — it is wrapped
  # into the public `Lua.RuntimeException` (kind: `:internal`) at the API
  # boundary.
  #
  # Raised for internal VM errors: bad native function returns, unimplemented
  # instructions, and other invariant violations.

  defexception [:value]

  @impl true
  def exception(opts) do
    %__MODULE__{value: Keyword.get(opts, :value)}
  end

  @impl true
  def message(%__MODULE__{value: value}), do: stringify(value)

  # No location/stack machinery for internal errors, so the rich render is the
  # same plain string. Present so `Lua.RuntimeException.format/1` can dispatch
  # uniformly across wrapped VM errors.
  @doc false
  def format(%__MODULE__{} = e), do: message(e)

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
