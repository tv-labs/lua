defmodule Lua.VM.GC do
  @moduledoc """
  Generational mark-and-sweep over the VM heap.

  The heap is the three id-keyed stores on `Lua.VM.State`: `tables`,
  `upvalue_cells` and `userdata`. Nothing else ever removes entries from
  them, so without a sweep every temporary table and every closure cell a
  script creates is retained for the life of the state.

  ## Generations

  Table ids are allocated in increasing order, so the tables created since
  the last collection are exactly those with `id >= state.gc_young_from`.
  A minor collection traces only those young tables, and the upvalue cells
  created since the last collection, and frees the unreachable ones. Its
  roots are:

    * the usual roots (below), traced only as far as young objects;
    * every older table written since the last collection, which
      `Lua.VM.State.put_table/3` records in `gc_remembered`;
    * the value of every older upvalue cell. Cells are scanned rather than
      barriered: their ids are unordered and their values are shallow.

  Anything older is assumed live. An old table, cell or userdata that has
  become garbage is only reclaimed by a major collection, which traces the
  whole heap. A minor collection's cost is proportional to the young
  objects, the remembered tables' entries and the number of upvalue cells.

  ## Pacing

  `:auto` does nothing until 1,000 tables, cells and userdata have been
  allocated since the last collection, then runs a minor collection, then
  a major one once the heap has doubled since the last major — the same
  200% pause Lua uses by default. The first `:auto` collection on a state
  is always major.

  ## Safe points

  Live registers are threaded through the executor and dispatcher as loop
  parameters, not stored in `%State{}`. A sweep while Lua frames are active
  would not see them and would free live tables. `collect/3` therefore only
  runs when no host entry point is in progress (`entry_depth` is zero) —
  i.e. between top-level evaluations — and raises otherwise, including from
  an Elixir callback that Lua is running. This is also why in-Lua
  `collectgarbage("collect")` stays a no-op.

  ## Roots

  `_G`, the type metatables, every private value, any open upvalue cells,
  and the `keep` values the caller passes. A userdata payload is traced
  when its userdata is reached. Elixir functions are traced through their
  captured environment, so a native function or `Lua.set!/3` callback keeps
  the tables it captured alive. A captured `%Lua{}` or `%Lua.VM.State{}` is
  a stale snapshot and is not traced. References held only in Elixir terms
  outside the state are not roots: after a sweep they may dangle.
  """

  alias Lua.VM.State
  alias Lua.VM.Table

  @minor_after 1_000

  @type mode :: :auto | :minor | :major

  @doc """
  Frees the heap objects unreachable from the roots and `keep`.
  """
  @spec collect(State.t(), [term()], mode()) :: State.t()
  def collect(%State{entry_depth: depth}, _keep, _mode) when depth > 0 do
    raise ArgumentError, "Lua.gc/2 must not be called while Lua code is running"
  end

  def collect(%State{gc: %{major_at: 0}} = state, keep, :auto), do: major(state, keep)

  def collect(%State{} = state, keep, :auto) do
    if young_count(state) < @minor_after do
      state
    else
      state |> minor(keep) |> maybe_major(keep)
    end
  end

  def collect(%State{} = state, keep, :minor), do: minor(state, keep)
  def collect(%State{} = state, keep, :major), do: major(state, keep)

  defp young_count(%State{gc: gc} = state) do
    state.table_next_id - state.gc_young_from +
      (map_size(state.upvalue_cells) - map_size(gc.old_cells)) +
      (state.userdata_next_id - gc.userdata_from)
  end

  defp heap_size(state), do: map_size(state.tables) + map_size(state.upvalue_cells) + map_size(state.userdata)

  defp maybe_major(state, keep) do
    if heap_size(state) >= state.gc.major_at, do: major(state, keep), else: state
  end

  defp minor(%State{gc: gc} = state, keep) do
    ctx = context(state, state.gc_young_from, gc.old_cells)

    remembered =
      Enum.reduce(state.gc_remembered, [], fn {id, true}, acc ->
        table_children(Map.fetch!(state.tables, id), acc)
      end)

    old_cell_values = for {ref, _} <- gc.old_cells, do: Map.fetch!(state.upvalue_cells, ref)

    {tables, cells, _userdata} =
      drain([roots(state, keep), remembered, old_cell_values], ctx, {%{}, %{}, %{}})

    dead_tables =
      for id <- state.gc_young_from..(state.table_next_id - 1)//1, not is_map_key(tables, id), do: id

    dead_cells =
      for {ref, _} <- state.upvalue_cells,
          not is_map_key(gc.old_cells, ref),
          not is_map_key(cells, ref),
          do: ref

    %{
      state
      | tables: Map.drop(state.tables, dead_tables),
        upvalue_cells: Map.drop(state.upvalue_cells, dead_cells),
        gc_young_from: state.table_next_id,
        gc_remembered: %{},
        gc: %{gc | old_cells: Map.merge(gc.old_cells, cells), userdata_from: state.userdata_next_id}
    }
  end

  defp major(state, keep) do
    {tables, cells, userdata} = drain([roots(state, keep)], context(state, 0, %{}), {%{}, %{}, %{}})
    live = map_size(tables) + map_size(cells) + map_size(userdata)

    %{
      state
      | tables: tables,
        upvalue_cells: cells,
        userdata: userdata,
        gc_young_from: state.table_next_id,
        gc_remembered: %{},
        gc: %{
          old_cells: cells,
          userdata_from: state.userdata_next_id,
          major_at: max(2 * live, live + @minor_after)
        }
    }
  end

  defp context(state, young_from, old_cells) do
    %{
      tables: state.tables,
      cells: state.upvalue_cells,
      userdata: state.userdata,
      young_from: young_from,
      old_cells: old_cells
    }
  end

  defp roots(state, keep) do
    [
      state.g_ref,
      Map.values(state.metatables),
      Map.values(state.private),
      Map.values(state.open_upvalues),
      keep
    ]
  end

  # Drain does not enter old objects (`id < young_from` or in `old_cells`).
  # The remembered set and the old-cell scan supply their young references.
  defp drain([], _ctx, marks), do: marks

  defp drain([{:tref, id} | rest], ctx, {tables, cells, userdata} = marks) do
    cond do
      id < ctx.young_from or is_map_key(tables, id) ->
        drain(rest, ctx, marks)

      is_map_key(ctx.tables, id) ->
        table = Map.fetch!(ctx.tables, id)
        drain(table_children(table, rest), ctx, {Map.put(tables, id, table), cells, userdata})

      true ->
        drain(rest, ctx, marks)
    end
  end

  defp drain([{:udref, id} | rest], ctx, {tables, cells, userdata} = marks) do
    if is_map_key(userdata, id) or not is_map_key(ctx.userdata, id) do
      drain(rest, ctx, marks)
    else
      payload = Map.fetch!(ctx.userdata, id)
      drain([payload | rest], ctx, {tables, cells, Map.put(userdata, id, payload)})
    end
  end

  defp drain([{tag, _proto, upvalues} | rest], ctx, marks) when tag in [:lua_closure, :compiled_closure] do
    drain([upvalues | rest], ctx, marks)
  end

  defp drain([ref | rest], ctx, {tables, cells, userdata} = marks) when is_reference(ref) do
    cond do
      is_map_key(cells, ref) or is_map_key(ctx.old_cells, ref) ->
        drain(rest, ctx, marks)

      is_map_key(ctx.cells, ref) ->
        value = Map.fetch!(ctx.cells, ref)
        drain([value | rest], ctx, {tables, Map.put(cells, ref, value), userdata})

      true ->
        drain(rest, ctx, marks)
    end
  end

  defp drain([fun | rest], ctx, marks) when is_function(fun) do
    {:env, env} = Function.info(fun, :env)
    drain([env | rest], ctx, marks)
  end

  defp drain([%{__struct__: struct} | rest], ctx, marks) when struct in [Lua, State] do
    drain(rest, ctx, marks)
  end

  defp drain([%{__struct__: _} = struct | rest], ctx, marks) do
    drain([Map.from_struct(struct) | rest], ctx, marks)
  end

  defp drain([map | rest], ctx, marks) when is_map(map) do
    drain(:maps.fold(fn k, v, acc -> [k, v | acc] end, rest, map), ctx, marks)
  end

  defp drain([[] | rest], ctx, marks), do: drain(rest, ctx, marks)
  defp drain([[head | tail] | rest], ctx, marks), do: drain([head, tail | rest], ctx, marks)

  defp drain([tuple | rest], ctx, marks) when is_tuple(tuple) do
    drain([Tuple.to_list(tuple) | rest], ctx, marks)
  end

  defp drain([_leaf | rest], ctx, marks), do: drain(rest, ctx, marks)

  defp table_children(%Table{arr: :undefined} = table, rest), do: [table.metatable, table.data | rest]

  defp table_children(%Table{arr: arr} = table, rest) do
    [table.metatable, table.data | :array.sparse_foldl(fn _i, v, acc -> [v | acc] end, rest, arr)]
  end
end
