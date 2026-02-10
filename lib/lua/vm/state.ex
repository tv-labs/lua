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
            table_next_id: 0,
            userdata: %{},
            userdata_next_id: 0,
            private: %{},
            current_line: 0,
            current_source: nil

  @type t :: %__MODULE__{
          globals: map(),
          call_stack: list(),
          metatables: map(),
          upvalue_cells: map(),
          tables: %{optional(non_neg_integer()) => Table.t()},
          table_next_id: non_neg_integer(),
          userdata: %{optional(non_neg_integer()) => term()},
          userdata_next_id: non_neg_integer(),
          private: map(),
          current_line: non_neg_integer(),
          current_source: binary() | nil
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

  @doc """
  Allocates userdata and returns a reference.

  Userdata stores arbitrary Elixir terms that can be passed through Lua
  but not directly manipulated by Lua code.
  """
  @spec alloc_userdata(t(), term()) :: {{:udref, non_neg_integer()}, t()}
  def alloc_userdata(state, value) do
    id = state.userdata_next_id

    state = %{
      state
      | userdata: Map.put(state.userdata, id, value),
        userdata_next_id: id + 1
    }

    {{:udref, id}, state}
  end

  @doc """
  Gets userdata by reference.
  """
  @spec get_userdata(t(), {:udref, non_neg_integer()}) :: term()
  def get_userdata(state, {:udref, id}) do
    Map.fetch!(state.userdata, id)
  end

  @doc """
  Stores a private value not exposed to Lua.
  """
  @spec put_private(t(), term(), term()) :: t()
  def put_private(%__MODULE__{} = state, key, value) do
    %{state | private: Map.put(state.private, key, value)}
  end

  @doc """
  Retrieves a private value. Raises `KeyError` if the key doesn't exist.
  """
  @spec get_private(t(), term()) :: term()
  def get_private(%__MODULE__{} = state, key) do
    Map.fetch!(state.private, key)
  end

  @doc """
  Deletes a private value.
  """
  @spec delete_private(t(), term()) :: t()
  def delete_private(%__MODULE__{} = state, key) do
    %{state | private: Map.delete(state.private, key)}
  end
end
