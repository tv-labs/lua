defmodule Lua.VM.State do
  @moduledoc """
  Runtime state for the Lua VM.
  """

  alias Lua.VM.Table

  defstruct call_stack: [],
            # Call depth tracked as an O(1) counter that moves in lockstep
            # with `call_stack` — `length(call_stack)` would be O(depth) per
            # call. `max_call_depth` bounds it; `:infinity` (the default)
            # means no limit. See `check_call_depth!/1`.
            call_depth: 0,
            max_call_depth: :infinity,
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
            # The sandbox's virtual filesystem. Filesystem-touching stdlib
            # functions (os.remove/rename/tmpname, the require searcher)
            # operate against this in-memory `VFS` value instead of the host
            # disk, so the VM never reaches real files. Seeded by `new/0` and
            # threaded forward by the `vfs_*` helpers.
            vfs: nil,
            # Whether the `require` searcher may fall back to the host disk
            # (`File.read/1`) when a module is not found in the VFS. Defaults to
            # `false` so a VFS-only VM never reaches real files; an embedding
            # host opts in explicitly via `Lua.set_lua_paths/2`, which targets
            # real on-disk module trees.
            vfs_host_fallback?: false

  @type t :: %__MODULE__{
          call_stack: list(),
          call_depth: non_neg_integer(),
          max_call_depth: pos_integer() | :infinity,
          metatables: map(),
          upvalue_cells: map(),
          tables: %{optional(non_neg_integer()) => Table.t()},
          table_next_id: non_neg_integer(),
          userdata: %{optional(non_neg_integer()) => term()},
          userdata_next_id: non_neg_integer(),
          private: map(),
          multi_return_count: non_neg_integer(),
          g_ref: nil | {:tref, non_neg_integer()},
          vfs: nil | VFS.t(),
          vfs_host_fallback?: boolean()
        }

  @doc """
  Creates a new VM state.

  Allocates an empty `_G` table to hold globals.
  """
  @spec new() :: t()
  def new do
    state = %__MODULE__{vfs: new_vfs()}
    {g_ref, state} = alloc_table(state)
    %{state | g_ref: g_ref}
  end

  # An empty in-memory virtual filesystem with a single `/` mount backed by
  # `VFS.Memory`. This is the default backing store for all filesystem-touching
  # stdlib functions; embedding hosts can seed files or mount other backends.
  defp new_vfs do
    VFS.mount(VFS.new(), "/", VFS.Memory.new(%{}))
  end

  @doc """
  Reads a file from the VM's virtual filesystem.

  Returns `{:ok, contents, state}` with the (possibly updated) VFS threaded
  back onto `state`, or `{:error, %VFS.Error{}, state}` on failure.
  """
  @spec vfs_read(t(), binary()) :: {:ok, binary(), t()} | {:error, VFS.Error.t(), t()}
  def vfs_read(%__MODULE__{vfs: vfs} = state, path) when is_binary(path) do
    case VFS.read_file(vfs, path) do
      {:ok, contents, vfs} -> {:ok, contents, %{state | vfs: vfs}}
      {:error, %VFS.Error{} = error} -> {:error, error, state}
    end
  end

  @doc """
  Writes a file into the VM's virtual filesystem.

  Returns `{:ok, state}` with the updated VFS threaded back, or
  `{:error, %VFS.Error{}, state}` on failure.
  """
  @spec vfs_write(t(), binary(), binary()) :: {:ok, t()} | {:error, VFS.Error.t(), t()}
  def vfs_write(%__MODULE__{vfs: vfs} = state, path, contents) when is_binary(path) and is_binary(contents) do
    case VFS.write_file(vfs, path, contents) do
      {:ok, vfs} -> {:ok, %{state | vfs: vfs}}
      {:error, %VFS.Error{} = error} -> {:error, error, state}
    end
  end

  @doc """
  Removes a file from the VM's virtual filesystem.

  Returns `{:ok, state}` with the updated VFS threaded back, or
  `{:error, %VFS.Error{}, state}` on failure.
  """
  @spec vfs_rm(t(), binary()) :: {:ok, t()} | {:error, VFS.Error.t(), t()}
  def vfs_rm(%__MODULE__{vfs: vfs} = state, path) when is_binary(path) do
    case VFS.rm(vfs, path) do
      {:ok, vfs} -> {:ok, %{state | vfs: vfs}}
      {:error, %VFS.Error{} = error} -> {:error, error, state}
    end
  end

  @doc """
  Reports whether a path exists in the VM's virtual filesystem.

  Returns `{boolean, state}` with the (possibly updated) VFS threaded back.
  """
  @spec vfs_exists?(t(), binary()) :: {boolean(), t()}
  def vfs_exists?(%__MODULE__{vfs: vfs} = state, path) when is_binary(path) do
    {exists?, vfs} = VFS.exists?(vfs, path)
    {exists?, %{state | vfs: vfs}}
  end

  @doc """
  Mounts a `VFS.Mountable` backend at `mountpoint`, returning the updated state.
  """
  @spec vfs_mount(t(), binary(), struct()) :: t()
  def vfs_mount(%__MODULE__{vfs: vfs} = state, mountpoint, backend) when is_binary(mountpoint) do
    %{state | vfs: VFS.mount(vfs, mountpoint, backend)}
  end

  @doc """
  Allows the `require` searcher to fall back to the host disk when a module is
  not found in the virtual filesystem.

  Off by default so a VFS-only VM never reaches real files; enabled by
  `Lua.set_lua_paths/2` when an embedding host points the search path at a real
  on-disk module tree.
  """
  @spec allow_vfs_host_fallback(t()) :: t()
  def allow_vfs_host_fallback(%__MODULE__{} = state) do
    %{state | vfs_host_fallback?: true}
  end

  @doc """
  Reports whether host-disk fallback is enabled for the `require` searcher.
  """
  @spec vfs_host_fallback?(t()) :: boolean()
  def vfs_host_fallback?(%__MODULE__{vfs_host_fallback?: enabled?}), do: enabled?

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
    raise Lua.VM.RuntimeError, value: "stack overflow", call_stack: call_stack
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
