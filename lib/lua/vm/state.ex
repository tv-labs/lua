defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  alias Lua.VM.RuntimeError
  alias Lua.VM.Table

  defstruct call_stack: [],
            # Call depth tracked as an O(1) counter that moves in lockstep
            # with `call_stack` — `length(call_stack)` would be O(depth) per
            # call. `max_call_depth` bounds it; `:infinity` (the default)
            # means no limit. See `check_call_depth!/1`.
            call_depth: 0,
            max_call_depth: :infinity,
            # `max_steps` is the configured instruction ceiling; `:infinity`
            # (the default) means no limit. The running tally is NOT stored
            # here on the per-opcode hot path — it is threaded as a parameter
            # through the executor / dispatcher loops, mirroring the
            # `line`-off-State discipline so the default `:infinity` path
            # carries no per-instruction struct rebuild. See `check_steps!/2`.
            max_steps: :infinity,
            # `steps` carries the running tally ACROSS engine boundaries
            # only. The interpreter and dispatcher each thread their tally as
            # a loop parameter; at an `Executor`↔`Dispatcher` hand-off (where
            # the struct is already rebuilt to push a call frame) the crossing
            # engine writes its tally here and the entered engine seeds from
            # it, so the budget spans a chain that alternates engines instead
            # of resetting at each boundary. Never written per opcode.
            steps: 0,
            metatables: %{},
            upvalue_cells: %{},
            open_upvalues: %{},
            tables: %{},
            table_next_id: 0,
            userdata: %{},
            userdata_next_id: 0,
            private: %{},
            multi_return_count: 0,
            # The `_G` table reference. Globals storage lives in this table's
            # `data` map. Allocated by `new/0`. Plan A16: `_ENV` semantics
            # require globals to be a real Lua table so `_ENV` reassignment
            # can redirect global access.
            g_ref: nil

  @type t :: %__MODULE__{
          call_stack: list(),
          call_depth: non_neg_integer(),
          max_call_depth: pos_integer() | :infinity,
          max_steps: pos_integer() | :infinity,
          steps: non_neg_integer(),
          metatables: map(),
          upvalue_cells: map(),
          tables: %{optional(non_neg_integer()) => Table.t()},
          table_next_id: non_neg_integer(),
          userdata: %{optional(non_neg_integer()) => term()},
          userdata_next_id: non_neg_integer(),
          private: map(),
          multi_return_count: non_neg_integer(),
          g_ref: nil | {:tref, non_neg_integer()}
        }

  @doc """
  Creates a new VM state.

  Allocates an empty `_G` table to hold globals.
  """
  @spec new() :: t()
  def new do
    state = %__MODULE__{}
    {g_ref, state} = alloc_table(state)
    %{state | g_ref: g_ref}
  end

  @doc """
  Guards against unbounded recursion.

  Raises a Lua `"stack overflow"` runtime error when the call depth has
  reached `max_call_depth`. Call it immediately before pushing a frame
  onto `call_stack`.

  No-op when depth is under the limit or when `max_call_depth` is
  `:infinity` (the default). The clauses are ordered so both common cases
  resolve in a single function-head match with no struct rebuild.
  """
  @spec check_call_depth!(t()) :: :ok
  def check_call_depth!(%__MODULE__{max_call_depth: :infinity}), do: :ok
  def check_call_depth!(%__MODULE__{call_depth: depth, max_call_depth: max}) when depth < max, do: :ok

  def check_call_depth!(%__MODULE__{call_stack: call_stack}) do
    raise RuntimeError, value: "stack overflow", call_stack: call_stack
  end

  @doc """
  Guards against unbounded CPU work within a single evaluation.

  Raises a catchable Lua `"instruction budget exceeded"` runtime error when
  the running instruction tally `steps` has reached `max_steps`. Call it at
  loop back-edges and call boundaries — never per opcode — so the default
  `:infinity` path stays free of per-instruction cost.

  The tally is threaded as a parameter, not stored in `%State{}`. No-op when
  the tally is under the limit or when `max_steps` is `:infinity` (the
  default). The clauses are ordered so both common cases resolve in a single
  function-head match with no struct rebuild.

  Raises the same `Lua.VM.RuntimeError` used by `"stack overflow"`, which
  `pcall`/`xpcall` already trap, so the error is recoverable for free.
  """
  @spec check_steps!(t(), non_neg_integer()) :: :ok
  def check_steps!(%__MODULE__{max_steps: :infinity}, _steps), do: :ok
  def check_steps!(%__MODULE__{max_steps: max}, steps) when steps < max, do: :ok

  def check_steps!(%__MODULE__{call_stack: call_stack}, _steps) do
    raise RuntimeError, value: "instruction budget exceeded", call_stack: call_stack
  end

  @doc """
  Returns the `_G` table reference.
  """
  @spec g_ref(t()) :: {:tref, non_neg_integer()}
  def g_ref(%__MODULE__{g_ref: g_ref}), do: g_ref

  @doc """
  Sets a global variable in the VM state.

  Writes into the `_G` table's data map. Globals storage lives entirely
  inside the `_G` table since Plan A16 (Lua 5.3 `_ENV` semantics).
  """
  @spec set_global(t(), binary(), term()) :: t()
  def set_global(%__MODULE__{g_ref: g_ref} = state, name, value) when is_binary(name) and not is_nil(g_ref) do
    update_table(state, g_ref, fn table -> Table.put(table, name, value) end)
  end

  @doc """
  Reads a global variable from the VM state. Returns `nil` if unset.
  """
  @spec get_global(t(), binary()) :: term()
  def get_global(%__MODULE__{g_ref: g_ref} = state, name) when is_binary(name) and not is_nil(g_ref) do
    table = get_table(state, g_ref)
    Map.get(table.data, name)
  end

  @doc """
  Returns the underlying globals data map (read-only convenience).

  Equivalent to `state._G.data`. Avoid using this for state mutation —
  use `set_global/3` instead so that future invariants stay consistent.
  """
  @spec globals(t()) :: map()
  def globals(%__MODULE__{g_ref: g_ref} = state) when not is_nil(g_ref) do
    table = get_table(state, g_ref)
    table.data
  end

  @doc """
  Registers a native Elixir function as a global in the VM state.

  The function should accept `(args, state)` and return `{results, state}`,
  where `args` is a list of Lua values and `results` is a list of return values.
  """
  @spec register_function(t(), binary(), (list(), t() -> {list(), t()})) :: t()
  def register_function(%__MODULE__{} = state, name, fun) when is_binary(name) and is_function(fun) do
    set_global(state, name, {:native_func, fun})
  end

  @doc """
  Allocates a fresh table in the state, returning `{{:tref, id}, new_state}`.
  """
  @spec alloc_table(t(), map()) :: {{:tref, non_neg_integer()}, t()}
  def alloc_table(state, data \\ %{}) do
    id = state.table_next_id
    # Use Table.from_data so the iteration `order` list mirrors the
    # initial map's keys. Stdlib tables (math, string, etc.) are built
    # via this path with non-empty data and need a sane iteration order.
    table = Table.from_data(data)
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
