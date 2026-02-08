defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  defstruct globals: %{},
            call_stack: [],
            metatables: %{},
            upvalue_cells: %{}

  @type t :: %__MODULE__{
          globals: map(),
          call_stack: list(),
          metatables: map(),
          upvalue_cells: map()
        }

  @doc """
  Creates a new VM state.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end
end
