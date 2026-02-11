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
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.ArgumentError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

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
    # Insert at end
    table = State.get_table(state, tref)
    len = get_table_length(table)
    new_data = Map.put(table.data, len + 1, value)
    state = State.update_table(state, tref, fn _ -> %{table | data: new_data} end)
    {[], state}
  end

  defp table_insert([{:tref, _} = tref, pos, value], state) when is_integer(pos) do
    # Insert at position, shift elements up
    table = State.get_table(state, tref)
    len = get_table_length(table)

    if pos < 1 or pos > len + 1 do
      raise ArgumentError,
        function_name: "table.insert",
        details: "position out of bounds"
    end

    # Shift elements from pos to len one position up
    new_data =
      len..pos
      |> Enum.reduce(table.data, fn i, acc ->
        case Map.get(acc, i) do
          nil -> acc
          val -> Map.put(acc, i + 1, val)
        end
      end)
      |> Map.put(pos, value)

    state = State.update_table(state, tref, fn _ -> %{table | data: new_data} end)
    {[], state}
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
    # Remove from end
    table = State.get_table(state, tref)
    len = get_table_length(table)

    if len == 0 do
      {[nil], state}
    else
      value = Map.get(table.data, len)
      new_data = Map.delete(table.data, len)
      state = State.update_table(state, tref, fn _ -> %{table | data: new_data} end)
      {[value], state}
    end
  end

  defp table_remove([{:tref, _} = tref, pos], state) when is_integer(pos) do
    # Remove from position, shift elements down
    table = State.get_table(state, tref)
    len = get_table_length(table)

    if pos < 1 or pos > len do
      {[nil], state}
    else
      value = Map.get(table.data, pos)

      # Shift elements from pos+1 to len one position down
      new_data =
        (pos + 1)..len
        |> Enum.reduce(Map.delete(table.data, pos), fn i, acc ->
          case Map.get(acc, i) do
            nil -> Map.delete(acc, i)
            val -> Map.put(Map.delete(acc, i), i - 1, val)
          end
        end)
        |> Map.delete(len)

      state = State.update_table(state, tref, fn _ -> %{table | data: new_data} end)
      {[value], state}
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

  # table.concat(list [, sep [, i [, j]]])
  defp table_concat([{:tref, _} = tref | rest], state) do
    table = State.get_table(state, tref)
    sep = Enum.at(rest, 0, "")
    i = Enum.at(rest, 1, 1)
    j = Enum.at(rest, 2, get_table_length(table))

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

    elements =
      for idx <- i..j do
        case Map.get(table.data, idx) do
          nil -> ""
          val when is_binary(val) -> val
          val when is_number(val) -> to_string(val)
          _ -> raise ArgumentError, function_name: "table.concat", details: "invalid value"
        end
      end

    result = Enum.join(elements, sep)
    {[result], state}
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
    table = State.get_table(state, tref)
    comp = List.first(rest)

    len = get_table_length(table)
    elements = for i <- 1..len, do: {i, Map.get(table.data, i)}

    sorted_elements =
      if comp do
        # Custom comparison function - not fully implemented yet
        # For now, just use default sort
        Enum.sort_by(elements, fn {_idx, val} -> val end)
      else
        # Default sort
        Enum.sort_by(elements, fn {_idx, val} -> val end)
      end

    new_data =
      sorted_elements
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {{_old_idx, val}, new_idx}, acc ->
        Map.put(acc, new_idx, val)
      end)
      |> Map.merge(Map.drop(table.data, Enum.to_list(1..len)))

    state = State.update_table(state, tref, fn _ -> %{table | data: new_data} end)
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
    table = State.get_table(state, tref)
    i = Enum.at(rest, 0, 1)
    j = Enum.at(rest, 1, get_table_length(table))

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

    results =
      for idx <- i..j do
        Map.get(table.data, idx, nil)
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

    table1 = State.get_table(state, tref1)
    table2 = State.get_table(state, tref2)

    # Move elements from a1[f..e] to a2[t..]
    {new_data2, _} =
      Enum.reduce(f..e, {table2.data, t}, fn src_idx, {data, dst_idx} ->
        val = Map.get(table1.data, src_idx)

        new_data =
          if val == nil do
            Map.delete(data, dst_idx)
          else
            Map.put(data, dst_idx, val)
          end

        {new_data, dst_idx + 1}
      end)

    state = State.update_table(state, tref2, fn _ -> %{table2 | data: new_data2} end)
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

  # Helper: Get the length of the array part of a table (consecutive integer keys starting from 1)
  defp get_table_length(table) do
    find_table_length(table.data, 1)
  end

  defp find_table_length(data, i) do
    if Map.has_key?(data, i) do
      find_table_length(data, i + 1)
    else
      i - 1
    end
  end
end
