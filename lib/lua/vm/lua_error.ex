defmodule Lua.VM.LuaError do
  @moduledoc """
  Exception raised by Lua runtime errors (e.g. `error()`, failed `assert()`).
  """

  defexception [:message]

  @impl true
  def exception(opts) do
    message = Keyword.get(opts, :message)

    msg =
      case message do
        nil -> "nil"
        v when is_binary(v) -> v
        v -> inspect(v)
      end

    %__MODULE__{message: msg}
  end
end
