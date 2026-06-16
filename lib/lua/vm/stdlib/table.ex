defmodule Lua.VM.Stdlib.Table do
  @moduledoc """
  Lua 5.3 table standard library.

  Provides functions for table manipulation including insertion, removal,
  concatenation, sorting, and array operations.

  ## Functions

  - `table.insert(list, [pos,] value)` - Inserts element into list
  - `table.remove(list [, pos])` - Removes element from list
  - `table.concat(list [, sep [, i [, j]]])` - Concatenates list elements
  - `table.sort(list [, comp])` - Sorts list in-place
  - `table.pack(...)` - Packs arguments into table with 'n' field
  - `table.unpack(list [, i [, j]])` - Returns elements from list
  - `table.move(a1, f, e, t [, a2])` - Moves elements between tables

  ## Metamethod handling

  `table.insert`, `table.remove`, `table.concat`, `table.move`, and
  `table.sort` route every read through `__index`, every write through
  `__newindex`, and every length lookup through `__len`. This matches
  Lua 5.3 §6.6 and the reference implementation in `ltablib.c`, which
  uses `lua_geti`/`lua_seti`/`luaL_len` for these operations rather than
  reaching into the raw table.
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.ArgumentError
  alias Lua.VM.Executor
  alias Lua.VM.Limits
  alias Lua.VM.Numeric
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util
  alias Lua.VM.Table

  # ltablib.c sort rejects arrays whose length reaches INT_MAX (2^31 - 1)
  # with "array too big"; we match that ceiling exactly.
  @max_sort_length 2_147_483_647

  @impl true
  def lib_name, do: "table"

  @impl true
  def install(state) do
    table_table = %{
      "insert" => {:native_func, &table_insert/2},
      "remove" => {:native_func, &table_remove/2},
      "concat" => {:native_func, &table_concat/2},
      "sort" => {:native_func, &table_sort/2},
      "pack" => {:native_func, &table_pack/2},
      "unpack" => {:native_func, &table_unpack/2},
      "move" => {:native_func, &table_move/2}
    }

    {tref, state} = State.alloc_table(state, table_table)
    State.set_global(state, "table", tref)
  end

  # table.insert(list, [pos,] value)
  defp table_insert([{:tref, _} = tref, value], state) do
    # Insert at end (pos = len + 1).
    {len, state} = Executor.table_length(tref, state)
    state = Executor.table_newindex(tref, len + 1, value, state)
    {[], state}
  end

  defp table_insert([{:tref, _} = tref, pos, value], state) when is_integer(pos) do
    # Insert at position, shift elements up.
    {len, state} = Executor.table_length(tref, state)

    if pos < 1 or pos > len + 1 do
      raise ArgumentError,
        function_name: "table.insert",
        details: "position out of bounds"
    end

    # Shift t[pos..len] up by one (top-down so reads stay coherent), then
    # write `value` into t[pos]. Reads route through __index, writes
    # through __newindex.
    state =
      Enum.reduce(len..pos//-1, state, fn i, st ->
        {v, st} = Executor.table_index(tref, i, st)
        Executor.table_newindex(tref, i + 1, v, st)
      end)

    state = Executor.table_newindex(tref, pos, value, state)

    {[], state}
  end

  defp table_insert(args, _state) when length(args) > 3 do
    raise ArgumentError.wrong_number_of_arguments("insert")
  end

  defp table_insert([tref | _], _state) do
    raise ArgumentError,
      function_name: "table.insert",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref)
  end

  defp table_insert([], _state) do
    raise ArgumentError.value_expected("table.insert", 1)
  end

  # table.remove(list [, pos])
  defp table_remove([{:tref, _} = tref], state) do
    # Default pos is #list, so a single-arg call removes the last element.
    # When #list == 0, this still removes (and returns) t[0] per Lua 5.3
    # — `table.remove(t) == t[0]` when t has no sequence part.
    {len, state} = Executor.table_length(tref, state)
    do_table_remove(tref, len, len, state)
  end

  defp table_remove([{:tref, _} = tref, pos], state) when is_integer(pos) do
    {len, state} = Executor.table_length(tref, state)

    # Match Lua 5.3 ltablib.c: validate pos only when pos != size. This
    # lets `table.remove(t, 0)` succeed when `#t == 0` (returns t[0]) but
    # raises when `#t > 0`. pos == size + 1 is a no-op that returns nil.
    cond do
      pos == len ->
        do_table_remove(tref, len, pos, state)

      pos < 1 or pos > len + 1 ->
        raise ArgumentError,
          function_name: "table.remove",
          arg_num: 2,
          details: "position out of bounds"

      true ->
        do_table_remove(tref, len, pos, state)
    end
  end

  defp table_remove([tref | _], _state) do
    raise ArgumentError,
      function_name: "table.remove",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref)
  end

  defp table_remove([], _state) do
    raise ArgumentError.value_expected("table.remove", 1)
  end

  defp do_table_remove(tref, len, pos, state) do
    # Read the value at `pos` first (via __index) so we can return it.
    {value, state} = Executor.table_index(tref, pos, state)

    # Shift t[pos+1..len] down by one, then clear t[max(pos, len)].
    # Mirrors the loop in Lua 5.3 ltablib.c tremove: after the shift,
    # `pos` is incremented to `size`, and the cleared slot is t[pos].
    # When pos == 0 (and len == 0) we clear t[0]. When pos == len we
    # clear t[len]. When pos == len + 1 (a no-op remove) we clear
    # t[len + 1], which was already nil.
    state =
      if pos < len do
        Enum.reduce((pos + 1)..len//1, state, fn i, st ->
          {v, st} = Executor.table_index(tref, i, st)
          Executor.table_newindex(tref, i - 1, v, st)
        end)
      else
        state
      end

    clear_at = max(pos, len)
    state = Executor.table_newindex(tref, clear_at, nil, state)

    {[value], state}
  end

  # table.concat(list [, sep [, i [, j]]])
  defp table_concat([{:tref, id} = tref | rest], state) do
    sep = Enum.at(rest, 0, "")
    i = Enum.at(rest, 1, 1)

    # `j` defaults to #list, which itself routes through __len.
    {j, state} =
      case Enum.at(rest, 2) do
        nil ->
          Executor.table_length(tref, state)

        explicit ->
          {explicit, state}
      end

    if !is_binary(sep) do
      raise ArgumentError,
        function_name: "table.concat",
        arg_num: 2,
        expected: "string",
        got: Util.typeof(sep)
    end

    if !is_integer(i) do
      raise ArgumentError,
        function_name: "table.concat",
        arg_num: 3,
        expected: "number",
        got: Util.typeof(i)
    end

    if !is_integer(j) do
      raise ArgumentError,
        function_name: "table.concat",
        arg_num: 4,
        expected: "number",
        got: Util.typeof(j)
    end

    # Read each element. Empty range (i > j) yields "". Plain tables (no
    # metatable) read directly from `data`, skipping the __index dispatch;
    # tables with a metatable keep the Executor path so __index is observed.
    table = Map.fetch!(state.tables, id)

    # Refuse an oversized range before allocating the result list.
    if i <= j, do: Limits.check_range_count!(j - i + 1, "table.concat")

    {elements, state} =
      cond do
        i > j ->
          {[], state}

        table.metatable == nil ->
          elements =
            Enum.map(i..j//1, fn idx ->
              concat_value(Table.get(table, idx), idx)
            end)

          {elements, state}

        true ->
          i..j//1
          |> Enum.reduce({[], state}, fn idx, {acc, st} ->
            {val, st} = Executor.table_index(tref, idx, st)
            {[concat_value(val, idx) | acc], st}
          end)
          |> then(fn {acc, st} -> {Enum.reverse(acc), st} end)
      end

    {[Enum.join(elements, sep)], state}
  end

  defp table_concat([tref | _], _state) do
    raise ArgumentError,
      function_name: "table.concat",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref)
  end

  defp table_concat([], _state) do
    raise ArgumentError.value_expected("table.concat", 1)
  end

  # Coerce a single element to its concatenated string form. Strings pass
  # through; numbers stringify; anything else is an error naming the index.
  defp concat_value(v, _idx) when is_binary(v), do: v
  defp concat_value(v, _idx) when is_number(v), do: to_string(v)

  defp concat_value(v, idx) do
    raise ArgumentError,
      function_name: "table.concat",
      details: "invalid value (#{Util.typeof(v)}) at index #{idx}"
  end

  # table.sort(list [, comp])
  defp table_sort([{:tref, id} = tref | rest], state) do
    comp = List.first(rest)

    # Resolve length via __len and materialize the slice via __index. We
    # then sort in Elixir and write back via __newindex. This matches
    # Lua 5.3 ltablib.c, which sorts through lua_geti/lua_seti rather
    # than mutating the raw table mid-sort.
    {len, state} = Executor.table_length(tref, state)

    # Mirror ltablib.c sort: reject lengths at/above INT_MAX before
    # touching the table, so a `__len` that returns a huge value raises
    # "array too big" instead of materialising billions of slots.
    if len > 1 and len >= @max_sort_length do
      raise ArgumentError,
        function_name: "table.sort",
        arg_num: 1,
        details: "array too big"
    end

    table = Map.fetch!(state.tables, id)

    if table.metatable == nil do
      sort_plain(id, table, len, comp, state)
    else
      sort_via_metamethods(tref, len, comp, state)
    end
  end

  defp table_sort([tref | _], _state) do
    raise ArgumentError,
      function_name: "table.sort",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref)
  end

  defp table_sort([], _state) do
    raise ArgumentError.value_expected("table.sort", 1)
  end

  # Fast path for a metatable-less table: read each slot directly from
  # `data`, sort, then merge the sorted slice back over `data` in one pass.
  # Skips the __index/__newindex dispatch machinery entirely, which is safe
  # because there are no metamethods to observe.
  defp sort_plain(_id, _table, len, _comp, state) when len <= 1 do
    {[], state}
  end

  defp sort_plain(id, table, len, comp, state) do
    values = Enum.map(1..len//1, fn i -> Table.get(table, i) end)

    {sorted, state} = sort_values(values, comp, state)

    # Re-fetch in case the comparator mutated the table; without a
    # comparator the table is unchanged and this is the same struct.
    table = Map.fetch!(state.tables, id)

    # Sort only reorders the values under keys 1..len; every other key
    # (string fields, sparse integers > len, etc.) must survive untouched,
    # matching Lua 5.3 table.sort. Keys 1..len occupy the dense array
    # border, so writing the sorted slice back through the split-aware
    # `put_many/2` rewrites those array slots in place without disturbing
    # the hash portion or any other key.
    pairs = Enum.with_index(sorted, fn val, idx -> {idx + 1, val} end)

    updated = Table.put_many(table, pairs)

    {[], %{state | tables: Map.put(state.tables, id, updated)}}
  end

  # Metatable-backed path: read via __index and write back via __newindex
  # so the metamethod observation order matches the reference impl.
  defp sort_via_metamethods(_tref, 0, _comp, state), do: {[], state}

  defp sort_via_metamethods(tref, 1, comp, state) do
    # len == 1 is already in order; still read the slot so __index fires.
    {v, state} = Executor.table_index(tref, 1, state)
    {_sorted, state} = sort_values([v], comp, state)
    {[], state}
  end

  defp sort_via_metamethods(tref, len, comp, state) do
    {values, state} =
      1..len//1
      |> Enum.reduce({[], state}, fn i, {acc, st} ->
        {v, st} = Executor.table_index(tref, i, st)
        {[v | acc], st}
      end)
      |> then(fn {acc, st} -> {Enum.reverse(acc), st} end)

    {sorted, state} = sort_values(values, comp, state)

    state =
      sorted
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {val, idx}, st ->
        Executor.table_newindex(tref, idx, val, st)
      end)

    {[], state}
  end

  # Sort values, threading state through the comparator when one is
  # supplied. The comparator may be a Lua closure or a native func; we
  # invoke it through `Executor.call_function/3` so vararg comparators
  # work the same way they do at the call site.
  defp sort_values(values, nil, state) do
    {Enum.sort(values, &default_compare/2), state}
  end

  defp sort_values(values, comp, state) do
    # `Enum.sort/2` cannot thread external state through its comparator,
    # so we use a stable insertion sort that does. Sort sizes here track
    # the table being sorted, so for a 1000-element table this is
    # O(n^2). Acceptable for now — matches the cost ceiling of calling
    # `comp` n*log(n) times in any case (comp is the dominant cost).
    Enum.reduce(values, {[], state}, fn val, {sorted, st} ->
      {inserted, st} = insert_sorted(sorted, val, comp, st)
      {inserted, st}
    end)
  end

  defp insert_sorted([], val, _comp, state), do: {[val], state}

  defp insert_sorted([head | tail] = list, val, comp, state) do
    {less?, state} = invoke_compare(comp, val, head, state)

    if less? do
      {[val | list], state}
    else
      {rest, state} = insert_sorted(tail, val, comp, state)
      {[head | rest], state}
    end
  end

  defp invoke_compare(comp, a, b, state) do
    {results, state} = Executor.call_function(comp, [a, b], state)
    {!!List.first(results), state}
  end

  # Default comparator mirrors Lua's `<`: numbers compare numerically,
  # strings compare lexicographically. Cross-type compares raise.
  defp default_compare(a, b) when is_number(a) and is_number(b), do: a < b
  defp default_compare(a, b) when is_binary(a) and is_binary(b), do: a < b

  defp default_compare(a, b) do
    raise ArgumentError,
      function_name: "table.sort",
      details: "attempt to compare #{Util.typeof(a)} with #{Util.typeof(b)}"
  end

  # table.pack(...)
  defp table_pack(args, state) do
    # Create a table with all arguments and 'n' field
    data =
      args
      |> Enum.with_index(1)
      |> Map.new(fn {val, idx} -> {idx, val} end)
      |> Map.put("n", length(args))

    {tref, state} = State.alloc_table(state, data)
    {[tref], state}
  end

  # table.unpack(list [, i [, j]])
  defp table_unpack([{:tref, _} = tref | rest], state) do
    # Treat nil as "not provided" — fall back to defaults. `i` defaults
    # to 1 and `j` defaults to #list (which routes through __len).
    i = Enum.at(rest, 0) || 1

    {j, state} =
      case Enum.at(rest, 1) do
        nil ->
          Executor.table_length(tref, state)

        explicit ->
          {explicit, state}
      end

    if !is_integer(i) do
      raise ArgumentError,
        function_name: "table.unpack",
        arg_num: 2,
        expected: "number",
        got: Util.typeof(i)
    end

    if !is_integer(j) do
      raise ArgumentError,
        function_name: "table.unpack",
        arg_num: 3,
        expected: "number",
        got: Util.typeof(j)
    end

    # Reject an oversized result count before materialising anything.
    # `ltablib.c` rejects only at INT_MAX (count overflow plus the
    # `lua_checkstack` arm), but on the BEAM even a sub-INT_MAX count like
    # `table.unpack({}, 1, 5e8)` would build hundreds of millions of nils
    # and exhaust the host. We share `Limits.max_element_count` with
    # `concat`/`move` so the deterministic ceiling is uniform, well below
    # INT_MAX yet far above any legitimate unpack. The subtraction stays
    # within Elixir's arbitrary-precision integers, so it cannot overflow.
    if i <= j and j - i >= Limits.max_element_count() do
      raise RuntimeError.exception(value: "too many results to unpack")
    end

    # Read each element via __index. Empty range (i > j) returns no
    # values. Matches `ltablib.c` which uses `lua_geti` per slot.
    {results, state} =
      if i > j do
        {[], state}
      else
        i..j//1
        |> Enum.reduce({[], state}, fn idx, {acc, st} ->
          {v, st} = Executor.table_index(tref, idx, st)
          {[v | acc], st}
        end)
        |> then(fn {acc, st} -> {Enum.reverse(acc), st} end)
      end

    {results, state}
  end

  defp table_unpack([tref | _], _state) do
    raise ArgumentError,
      function_name: "table.unpack",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref)
  end

  defp table_unpack([], _state) do
    raise ArgumentError.value_expected("table.unpack", 1)
  end

  # table.move(a1, f, e, t [, a2])
  defp table_move([{:tref, _} = tref1, f, e, t | rest], state) when is_integer(f) and is_integer(e) and is_integer(t) do
    tref2 = List.first(rest) || tref1

    if !match?({:tref, _}, tref2) do
      raise ArgumentError,
        function_name: "table.move",
        arg_num: 5,
        expected: "table",
        got: Util.typeof(tref2)
    end

    # Empty range (f > e) is a no-op that still returns tref2.
    state =
      if f > e do
        state
      else
        move_range(tref1, tref2, f, e, t, state)
      end

    {[tref2], state}
  end

  # All of f, e, t are valid integers but arg1 is not a table. Mirrors
  # ltablib.c tmove, which checks the indices (args 2-4) before the
  # source table (arg 1): `table.move(1, 2, 3, 4)` blames arg #1.
  defp table_move([tref1, f, e, t | _rest], _state) when is_integer(f) and is_integer(e) and is_integer(t) do
    raise ArgumentError,
      function_name: "table.move",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref1)
  end

  defp table_move([_tref1, f, e, t | _rest], _state) when is_integer(f) and is_integer(e) do
    raise ArgumentError,
      function_name: "table.move",
      arg_num: 4,
      expected: "number",
      got: Util.typeof(t)
  end

  defp table_move([_tref1, f, e | _rest], _state) when is_integer(f) do
    raise ArgumentError,
      function_name: "table.move",
      arg_num: 3,
      expected: "number",
      got: Util.typeof(e)
  end

  defp table_move([_tref1, f | _rest], _state) do
    raise ArgumentError,
      function_name: "table.move",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(f)
  end

  defp table_move([tref1 | _], _state) do
    raise ArgumentError,
      function_name: "table.move",
      arg_num: 1,
      expected: "table",
      got: Util.typeof(tref1)
  end

  defp table_move([], _state) do
    raise ArgumentError.value_expected("table.move", 1)
  end

  # Mirrors ltablib.c tmove for a non-empty range (f <= e). First the two
  # overflow argchecks PUC-Lua applies before touching either table, then
  # an interleaved read-via-__index / write-via-__newindex loop. The
  # interleaving (rather than reading the whole slice up front) is what
  # lets a __newindex error abort after the first element — which the
  # suite verifies for ranges as wide as 1..maxinteger.
  defp move_range(tref1, tref2, f, e, t, state) do
    max_int = Numeric.max_int()

    # "too many elements to move": e - f + 1 must not overflow an int.
    if !(f > 0 or e < max_int + f) do
      raise ArgumentError,
        function_name: "table.move",
        arg_num: 3,
        details: "too many elements to move"
    end

    n = e - f + 1

    # "destination wrap around": t + n - 1 must not overflow an int.
    if !(t <= max_int - n + 1) do
      raise ArgumentError,
        function_name: "table.move",
        arg_num: 4,
        details: "destination wrap around"
    end

    # Host-protection ceiling: when neither table has a metatable, no
    # __index/__newindex can interrupt the loop, so a pathological count
    # would build tens of millions of slots and exhaust the BEAM. Refuse
    # those up front. Metatable-backed moves skip this — the suite drives
    # ranges as wide as 1..maxinteger that abort on the first metamethod.
    if plain_tables?(tref1, tref2, state) do
      Limits.check_range_count!(n, "table.move")
    end

    # PUC chooses copy direction so an in-place overlapping move stays
    # coherent: copy forward when the destination cannot clobber an
    # un-read source slot (t > e || t <= f), otherwise copy backward.
    indices =
      if t > e or t <= f do
        0..(n - 1)//1
      else
        (n - 1)..0//-1
      end

    Enum.reduce(indices, state, fn i, st ->
      {v, st} = Executor.table_index(tref1, f + i, st)
      Executor.table_newindex(tref2, t + i, v, st)
    end)
  end

  defp plain_tables?({:tref, id1}, {:tref, id2}, state) do
    no_metatable?(id1, state) and no_metatable?(id2, state)
  end

  defp no_metatable?(id, state) do
    case Map.fetch(state.tables, id) do
      {:ok, table} -> table.metatable == nil
      :error -> true
    end
  end
end
