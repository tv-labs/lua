defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  alias Lua.VM.Table

  defstruct globals: %{},
            call_stack: [],
            metatables: %{},
            upvalue_cells: %{},
            tables: %{},
            table_next_id: 0

  @type t :: %__MODULE__{
          globals: map(),
          call_stack: list(),
          metatables: map(),
          upvalue_cells: map(),
          tables: %{optional(non_neg_integer()) => Table.t()},
          table_next_id: non_neg_integer()
        }

  @doc """
  Creates a new VM state.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Sets a global variable in the VM state.
  """
  @spec set_global(t(), binary(), term()) :: t()
  def set_global(%__MODULE__{} = state, name, value) when is_binary(name) do
    %{state | globals: Map.put(state.globals, name, value)}
  end

  @doc """
  Registers a native Elixir function as a global in the VM state.

  The function should accept `(args, state)` and return `{results, state}`,
  where `args` is a list of Lua values and `results` is a list of return values.
  """
  @spec register_function(t(), binary(), (list(), t() -> {list(), t()})) :: t()
  def register_function(%__MODULE__{} = state, name, fun)
      when is_binary(name) and is_function(fun) do
    set_global(state, name, {:native_func, fun})
  end

  @doc """
  Allocates a fresh table in the state, returning `{{:tref, id}, new_state}`.
  """
  @spec alloc_table(t(), map()) :: {{:tref, non_neg_integer()}, t()}
  def alloc_table(state, data \\ %{}) do
    id = state.table_next_id
    table = %Table{data: data}
    state = %{state | tables: Map.put(state.tables, id, table), table_next_id: id + 1}
    {{:tref, id}, state}
  end

  @doc """
  Fetches a table by reference.
  """
  @spec get_table(t(), {:tref, non_neg_integer()}) :: Table.t()
  def get_table(state, {:tref, id}) do
    Map.fetch!(state.tables, id)
  end

  @doc """
  Updates a table in-place via a function.
  """
  @spec update_table(t(), {:tref, non_neg_integer()}, (Table.t() -> Table.t())) :: t()
  def update_table(state, {:tref, id}, fun) do
    %{state | tables: Map.update!(state.tables, id, fun)}
  end
end
