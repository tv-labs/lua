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
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

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
  defp table_concat([{:tref, _} = tref | rest], state) do
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

    # Read each element via __index. Empty range (i > j) yields "".
    {elements, state} =
      if i > j do
        {[], state}
      else
        i..j//1
        |> Enum.reduce({[], state}, fn idx, {acc, st} ->
          {val, st} = Executor.table_index(tref, idx, st)

          str =
            case val do
              v when is_binary(v) ->
                v

              v when is_number(v) ->
                to_string(v)

              _ ->
                raise ArgumentError,
                  function_name: "table.concat",
                  details: "invalid value (#{Util.typeof(val)}) at index #{idx}"
            end

          {[str | acc], st}
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

  # table.sort(list [, comp])
  defp table_sort([{:tref, _} = tref | rest], state) do
    comp = List.first(rest)

    # Resolve length via __len and materialize the slice via __index. We
    # then sort in Elixir and write back via __newindex. This matches
    # Lua 5.3 ltablib.c, which sorts through lua_geti/lua_seti rather
    # than mutating the raw table mid-sort.
    {len, state} = Executor.table_length(tref, state)

    {values, state} =
      if len <= 1 do
        # Even for len 0/1 we still call __index so callers observe the
        # access pattern matching the reference impl. For len == 1 we
        # skip the sort entirely; the slot is already in order.
        if len == 0 do
          {[], state}
        else
          {v, state} = Executor.table_index(tref, 1, state)
          {[v], state}
        end
      else
        1..len//1
        |> Enum.reduce({[], state}, fn i, {acc, st} ->
          {v, st} = Executor.table_index(tref, i, st)
          {[v | acc], st}
        end)
        |> then(fn {acc, st} -> {Enum.reverse(acc), st} end)
      end

    {sorted, state} = sort_values(values, comp, state)

    state =
      sorted
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {val, idx}, st ->
        Executor.table_newindex(tref, idx, val, st)
      end)

    {[], state}
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
        # Read each src slot via __index on tref1, write to dst via
        # __newindex on tref2. Aliasing (tref1 == tref2 with overlapping
        # ranges) is handled by reading every value first, then writing
        # — matching ltablib.c's tmove which preserves overlap-safety
        # only when src and dst are distinct or t <= f.
        {values, state} =
          Enum.reduce(f..e//1, {[], state}, fn idx, {acc, st} ->
            {v, st} = Executor.table_index(tref1, idx, st)
            {[v | acc], st}
          end)

        values = Enum.reverse(values)

        {final_state, _} =
          Enum.reduce(values, {state, t}, fn v, {st, dst_idx} ->
            {Executor.table_newindex(tref2, dst_idx, v, st), dst_idx + 1}
          end)

        final_state
      end

    {[tref2], state}
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
end
