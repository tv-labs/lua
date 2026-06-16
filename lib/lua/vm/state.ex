defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  alias Lua.VFS
  alias Lua.VM.Limits
  alias Lua.VM.RuntimeError
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
            # `max_instructions` is the configured instruction ceiling; `:infinity`
            # (the default) means no limit. The running tally is NOT stored
            # here on the per-opcode hot path — it is threaded as a parameter
            # through the executor / dispatcher loops, mirroring the
            # `line`-off-State discipline so the default `:infinity` path
            # carries no per-instruction struct rebuild. See `tick!/2`.
            max_instructions: :infinity,
            # `instruction_count` carries the running tally ACROSS engine boundaries
            # only. The interpreter and dispatcher each thread their tally as
            # a loop parameter; at an `Executor`↔`Dispatcher` hand-off (where
            # the struct is already rebuilt to push a call frame) the crossing
            # engine writes its tally here and the entered engine seeds from
            # it, so the budget spans a chain that alternates engines instead
            # of resetting at each boundary. Never written per opcode.
            instruction_count: 0,
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
            g_ref: nil,
            # Memoizes parsed `string.format` templates (format string ->
            # compiled segment list) so a format string reused across calls —
            # the common `for ... string.format(FMT, ...)` loop shape — is
            # scanned and spec-parsed once, not every call. Threaded in the
            # struct (not ETS/process dictionary) to preserve value semantics;
            # bounded in `Lua.VM.Stdlib.String`.
            format_cache: %{},
            # The in-memory virtual filesystem backing the sandboxed VM.
            # Filesystem-touching stdlib (`require`, `loadfile`/`dofile`, `io`,
            # the file-oriented `os` functions) reads/writes here instead of the
            # host disk, so a sandboxed script never reaches the real machine.
            # Seeded by `new/0`; threaded via the `vfs_*` helpers below.
            vfs: nil

  @type t :: %__MODULE__{
          call_stack: list(),
          call_depth: non_neg_integer(),
          max_call_depth: pos_integer() | :infinity,
          max_string_bytes: pos_integer(),
          max_instructions: pos_integer() | :infinity,
          instruction_count: non_neg_integer(),
          metatables: map(),
          upvalue_cells: map(),
          tables: %{optional(non_neg_integer()) => Table.t()},
          table_next_id: non_neg_integer(),
          userdata: %{optional(non_neg_integer()) => term()},
          userdata_next_id: non_neg_integer(),
          private: map(),
          multi_return_count: non_neg_integer(),
          g_ref: nil | {:tref, non_neg_integer()},
          format_cache: %{optional(binary()) => list()},
          vfs: nil | VFS.t()
        }

  @doc """
  Creates a new VM state.

  Allocates an empty `_G` table to hold globals.
  """
  @spec new() :: t()
  def new do
    state = %__MODULE__{}
    {g_ref, state} = alloc_table(state)
    %{state | g_ref: g_ref, vfs: VFS.new()}
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

  def check_call_depth!(%__MODULE__{call_stack: call_stack} = state) do
    raise RuntimeError, value: "stack overflow", call_stack: call_stack, state: state
  end

  @doc """
  Charges one instruction against the budget and returns the new tally.

  Guards against unbounded CPU work within a single evaluation by folding
  the running-tally increment and the budget check into one call. Call it
  at loop back-edges and call boundaries — never per opcode — so the
  default `:infinity` path stays free of per-instruction cost.

  The tally is threaded as a parameter, not stored in `%State{}`. When
  `max_instructions` is `:infinity` (the default) this is a true no-op: it returns
  the tally unchanged in a single function-head match, doing no arithmetic
  and rebuilding no struct, so the default path's only per-boundary cost is
  this one call. When a finite budget is set it increments the tally and,
  once the new tally reaches `max_instructions`, raises a catchable Lua
  `"instruction budget exceeded"` runtime error. The clauses are ordered so
  both the `:infinity` and under-budget cases resolve in a single
  function-head match.

  The raise reuses the same `Lua.VM.RuntimeError` used by `"stack
  overflow"`, carrying the raise-time `state:` so `pcall`/`xpcall` recover
  heap effects for free. The live tally is stamped into that `state:` (the
  threaded `instruction_count` is not otherwise in `%State{}`), so `unwind_to/2` can
  carry it forward and a caught budget error stays spent — a protected call
  cannot refund the work it burned.
  """
  @spec tick!(t(), non_neg_integer()) :: non_neg_integer()
  def tick!(%__MODULE__{max_instructions: :infinity}, instruction_count), do: instruction_count

  def tick!(%__MODULE__{max_instructions: max}, instruction_count) when instruction_count + 1 < max,
    do: instruction_count + 1

  def tick!(%__MODULE__{call_stack: call_stack} = state, instruction_count) do
    instruction_count = instruction_count + 1

    raise RuntimeError,
      value: "instruction budget exceeded",
      call_stack: call_stack,
      state: %{state | instruction_count: instruction_count}
  end

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

  The instruction tally `instruction_count` is also carried forward (monotonic max), not
  reset to the entry value: the work a protected call burned must still count
  against the one per-evaluation `:max_instructions` budget, so wrapping heavy work in
  `pcall` (or looping over `pcall`) cannot escape the cap.

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
        private: raised.private,
        instruction_count: max(entry.instruction_count, raised.instruction_count)
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
  Updates userdata in-place via a function.

  Mutable userdata is how `io` file handles carry their cursor: the handle is a
  `{:udref, _}` whose backing struct is rewritten through this helper as the
  script reads/writes.
  """
  @spec update_userdata(t(), {:udref, non_neg_integer()}, (term() -> term())) :: t()
  def update_userdata(state, {:udref, id}, fun) do
    %{state | userdata: Map.update!(state.userdata, id, fun)}
  end

  @doc """
  Reads a file from the virtual filesystem.

  Returns `{:ok, contents}` or `{:error, reason}` where `reason` is a tagged
  atom (`:enoent`/`:eisdir`/`:einval`). Reads do not mutate state, so no state
  is threaded back.
  """
  @spec vfs_read(t(), VFS.path()) :: {:ok, binary()} | {:error, VFS.error()}
  def vfs_read(%__MODULE__{vfs: vfs}, path), do: VFS.read(vfs, path)

  @doc """
  Writes a file into the virtual filesystem, threading the updated VFS back.

  Returns `{:ok, state}` or `{:error, reason, state}`.
  """
  @spec vfs_write(t(), VFS.path(), binary()) :: {:ok, t()} | {:error, VFS.error(), t()}
  def vfs_write(%__MODULE__{vfs: vfs} = state, path, contents) do
    case VFS.write(vfs, path, contents) do
      {:ok, vfs} -> {:ok, %{state | vfs: vfs}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc """
  Removes a file from the virtual filesystem, threading the updated VFS back.

  Returns `{:ok, state}` or `{:error, reason, state}`.
  """
  @spec vfs_rm(t(), VFS.path()) :: {:ok, t()} | {:error, VFS.error(), t()}
  def vfs_rm(%__MODULE__{vfs: vfs} = state, path) do
    case VFS.rm(vfs, path) do
      {:ok, vfs} -> {:ok, %{state | vfs: vfs}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc """
  Returns `true` when `path` names an existing file or directory in the VFS.
  """
  @spec vfs_exists?(t(), VFS.path()) :: boolean()
  def vfs_exists?(%__MODULE__{vfs: vfs}, path), do: VFS.exists?(vfs, path)

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
