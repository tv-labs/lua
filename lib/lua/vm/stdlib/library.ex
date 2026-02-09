defmodule Lua.VM.Stdlib.Library do
  @moduledoc """
  Behaviour for Lua standard library modules.

  All standard library modules (string, math, table, os, etc.) should implement
  this behaviour to provide a consistent interface for installation into the VM state.

  ## Example

      defmodule Lua.VM.Stdlib.String do
        @behaviour Lua.VM.Stdlib.Library

        @impl true
        def install(state) do
          # Create and register the string library
          string_table = %{...}
          {tref, state} = State.alloc_table(state, string_table)
          State.set_global(state, "string", tref)
        end
      end

  """

  alias Lua.VM.State

  @doc """
  Installs the library into the given VM state.

  This function should register all library functions in the appropriate global
  namespace (e.g., "string", "math", "table") and return the updated state.

  ## Parameters

    - `state` - The VM state to install the library into

  ## Returns

    The updated VM state with the library installed
  """
  @callback install(State.t()) :: State.t()
end
