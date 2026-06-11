defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  alias Lua.VM.Limits
  alias Lua.VM.Table

  defstruct call_stack: [],
            # Call depth tracked as an O(1) counter that moves in lockstep
            # with `call_stack` — `length(call_stack)` would be O(depth) per
            # call. `max_call_depth` bounds it; `:infinity` (the default)
            # means no limit. See `check_call_depth!/1`.
            call_depth: 0,
            max_call_depth: :infinity,
            # Ceiling for any single string the VM will build (`..`,
            # `string.rep`, `load` reader chunks). Defaults to the practical
            # bound in `Lua.VM.Limits`. Embedders running the VM under a
            # process heap cap (`:max_heap_size`) should set this below that
            # cap so an allocation bomb is refused deterministically instead
            # of racing the GC-time heap check.
            max_string_bytes: Limits.max_string_bytes(),
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
          max_string_bytes: pos_integer(),
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

  Callers on the executor's lazy `:lua_closure`/`:compiled_closure` paths
  keep their in-flight frames in the `frames` argument rather than in
  `state.call_stack`, so passing `state` alone would render an empty
  overflow traceback. Such callers use `check_call_depth!/2` to supply the
  materialized stack that should be reported when the limit is hit.
  """
  @spec check_call_depth!(t()) :: :ok
  def check_call_depth!(%__MODULE__{} = state), do: check_call_depth!(state, nil)

  @doc """
  Like `check_call_depth!/1`, but reports `overflow_call_stack` (instead of
  `state.call_stack`) in the raised `"stack overflow"` error.

  The executor's hot call paths track in-flight Lua frames lazily in their
  `frames` argument; `overflow_call_stack` lets them materialize that stack
  only when the limit is actually hit, preserving traceback fidelity
  without paying the cost on the success path.
  """
  @spec check_call_depth!(t(), [map()] | nil) :: :ok
  def check_call_depth!(%__MODULE__{max_call_depth: :infinity}, _overflow_call_stack), do: :ok

  def check_call_depth!(%__MODULE__{call_depth: depth, max_call_depth: max}, _overflow_call_stack) when depth < max,
    do: :ok

  def check_call_depth!(%__MODULE__{call_stack: call_stack} = state, overflow_call_stack) do
    raise Lua.VM.RuntimeError,
      value: "stack overflow",
      call_stack: overflow_call_stack || call_stack,
      state: state
  end

  @doc """
  Returns `true` when another call may be pushed without exceeding
  `max_call_depth`.

  A pure, allocation-free counterpart to `check_call_depth!/1` for the
  executor's hot `:lua_closure` path: it lets the caller defer building the
  overflow traceback (`rebuild_call_stack/1`) to the rare failing branch
  instead of paying for it on every call. The clauses mirror
  `check_call_depth!/1` exactly.
  """
  @spec call_depth_ok?(t()) :: boolean()
  def call_depth_ok?(%__MODULE__{max_call_depth: :infinity}), do: true
  def call_depth_ok?(%__MODULE__{call_depth: depth, max_call_depth: max}), do: depth < max

  @doc """
  Recovers the state a protected call should continue with after trapping
  an error.

  Lua 5.3 §2.3: an error aborts the protected call, but heap effects made
  before it — global writes, table mutations, upvalue-cell assignments,
  metatable changes — are kept. Only control state unwinds. Accordingly,
  heap fields come from `raised` (the state captured at the raise site,
  ferried out on the exception's `:state` field) while control fields are
  restored from `entry` (the state at protected-call entry):

  | kept from `raised` (heap)              | restored from `entry` (control) |
  |----------------------------------------|---------------------------------|
  | `tables`, `table_next_id`              | `call_stack`, `call_depth`      |
  | `userdata`, `userdata_next_id`         | `open_upvalues`                 |
  | `metatables`, `upvalue_cells`, `private` | `multi_return_count`          |

  Keeping `upvalue_cells` while restoring `open_upvalues` matches reference
  upvalue semantics: cells captured before the protected call keep their
  mutated values, while cells opened by the unwound frames become
  unreachable garbage.

  When no raise-time state was captured (`raised` is `nil`, e.g. the error
  came from outside Lua execution), falls back to `entry` unchanged.
  """
  @spec unwind_to(t(), t() | nil) :: t()
  def unwind_to(%__MODULE__{} = entry, nil), do: entry

  def unwind_to(%__MODULE__{} = entry, %__MODULE__{} = raised) do
    %{
      entry
      | tables: raised.tables,
        table_next_id: raised.table_next_id,
        userdata: raised.userdata,
        userdata_next_id: raised.userdata_next_id,
        metatables: raised.metatables,
        upvalue_cells: raised.upvalue_cells,
        private: raised.private
    }
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
