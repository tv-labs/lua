defmodule Lua.VM.Stdlib do
  @moduledoc """
  Standard library functions for the Lua VM.

  Provides essential built-in functions that are available in the global
  scope when the standard library is installed.
  """

  alias Lua.VM.{ArgumentError, AssertionError, State, Value}

  @doc """
  Installs the standard library into the given VM state.
  """
  @spec install(State.t()) :: State.t()
  def install(%State{} = state) do
    state
    |> State.register_function("type", &lua_type/2)
    |> State.register_function("tostring", &lua_tostring/2)
    |> State.register_function("tonumber", &lua_tonumber/2)
    |> State.register_function("print", &lua_print/2)
    |> State.register_function("error", &lua_error/2)
    |> State.register_function("assert", &lua_assert/2)
    |> State.register_function("pcall", &lua_pcall/2)
    |> State.register_function("xpcall", &lua_xpcall/2)
    |> State.register_function("rawget", &lua_rawget/2)
    |> State.register_function("rawset", &lua_rawset/2)
    |> State.register_function("rawlen", &lua_rawlen/2)
    |> State.register_function("rawequal", &lua_rawequal/2)
    |> State.register_function("next", &lua_next/2)
    |> State.register_function("pairs", &lua_pairs/2)
    |> State.register_function("ipairs", &lua_ipairs/2)
    |> State.register_function("setmetatable", &lua_setmetatable/2)
    |> State.register_function("getmetatable", &lua_getmetatable/2)
    |> Lua.VM.Stdlib.String.install()
    |> Lua.VM.Stdlib.Math.install()
    |> Lua.VM.Stdlib.Table.install()
  end

  # type(v) — returns the type of v as a string
  defp lua_type([value | _], state), do: {[Value.type_name(value)], state}
  defp lua_type([], state), do: {["nil"], state}

  # tostring(v) — converts a value to its string representation
  defp lua_tostring([value | _], state), do: {[Value.to_string(value)], state}
  defp lua_tostring([], state), do: {["nil"], state}

  # tonumber(v [, base]) — converts a string to a number
  defp lua_tonumber([value | rest], state) do
    base = List.first(rest)

    result =
      case {value, base} do
        {v, nil} when is_number(v) ->
          v

        {v, nil} when is_binary(v) ->
          Value.parse_number(v)

        {v, b} when is_binary(v) and is_integer(b) and b >= 2 and b <= 36 ->
          case Integer.parse(v, b) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end

    {[result], state}
  end

  defp lua_tonumber([], state), do: {[nil], state}

  # print(...) — prints values separated by tabs, followed by a newline
  defp lua_print(args, state) do
    output = Enum.map_join(args, "\t", &Value.to_string/1)
    IO.puts(output)
    {[], state}
  end

  # error(message) — raises a Lua runtime error
  defp lua_error([message | _], _state) do
    raise Lua.VM.RuntimeError, value: message
  end

  defp lua_error([], _state) do
    raise Lua.VM.RuntimeError, value: nil
  end

  # assert(v [, message]) — raises if v is falsy
  defp lua_assert([value | rest], state) do
    if value == nil or value == false do
      message =
        case rest do
          [msg | _] -> msg
          [] -> "assertion failed!"
        end

      raise AssertionError, value: message
    else
      {[value], state}
    end
  end

  defp lua_assert([], _state) do
    raise AssertionError, value: "assertion failed!"
  end

  # pcall(f [, arg1, ...]) — calls function in protected mode
  # Returns true, result(s) on success or false, error_message on error
  defp lua_pcall([func | args], state) do
    try do
      {results, state} = Lua.VM.Executor.call_function(func, args, state)
      {[true | results], state}
    rescue
      e in [Lua.VM.RuntimeError, AssertionError, Lua.VM.TypeError] ->
        error_msg = extract_error_message(e)
        {[false, error_msg], state}

      e ->
        # Catch any other error
        {[false, Exception.message(e)], state}
    end
  end

  defp lua_pcall([], state), do: {[false, "bad argument #1 to 'pcall' (value expected)"], state}

  # xpcall(f, msgh [, arg1, ...]) — calls function with message handler
  # Returns true, result(s) on success or false, handler_result on error
  defp lua_xpcall([func, handler | args], state) do
    try do
      {results, state} = Lua.VM.Executor.call_function(func, args, state)
      {[true | results], state}
    rescue
      e in [Lua.VM.RuntimeError, AssertionError, Lua.VM.TypeError] ->
        error_msg = extract_error_message(e)

        # Call the error handler
        try do
          {handler_results, state} = Lua.VM.Executor.call_function(handler, [error_msg], state)
          {[false | handler_results], state}
        rescue
          _ ->
            # If handler fails, return original error
            {[false, error_msg], state}
        end

      e ->
        # Catch any other error
        error_msg = Exception.message(e)

        try do
          {handler_results, state} = Lua.VM.Executor.call_function(handler, [error_msg], state)
          {[false | handler_results], state}
        rescue
          _ ->
            {[false, error_msg], state}
        end
    end
  end

  defp lua_xpcall(_, state), do: {[false, "bad argument to 'xpcall'"], state}

  # Extract error message from exception
  defp extract_error_message(%{value: value}) when is_binary(value), do: value
  defp extract_error_message(%{value: value}) when not is_nil(value), do: Value.to_string(value)
  defp extract_error_message(e), do: Exception.message(e)

  # rawget(table, key) — get without metamethods
  defp lua_rawget([{:tref, id}, key | _], state) do
    table = Map.fetch!(state.tables, id)
    {[Map.get(table.data, key)], state}
  end

  # rawset(table, key, value) — set without metamethods
  defp lua_rawset([{:tref, _} = tref, key, value | _], state) do
    state =
      State.update_table(state, tref, fn table ->
        %{table | data: Map.put(table.data, key, value)}
      end)

    {[tref], state}
  end

  # rawlen(v) — length without metamethods
  defp lua_rawlen([{:tref, id} | _], state) do
    table = Map.fetch!(state.tables, id)
    {[Value.sequence_length(table.data)], state}
  end

  defp lua_rawlen([v | _], state) when is_binary(v) do
    {[byte_size(v)], state}
  end

  defp lua_rawlen(_, state), do: {[0], state}

  # rawequal(a, b) — equality without metamethods
  defp lua_rawequal([a, b | _], state) do
    {[a === b], state}
  end

  defp lua_rawequal(_, state), do: {[false], state}

  # next(table [, key]) — returns next key-value pair after key
  defp lua_next([{:tref, id} | rest], state) do
    key = List.first(rest)
    table = Map.fetch!(state.tables, id)

    case find_next_entry(table.data, key) do
      nil -> {[nil, nil], state}
      {k, v} -> {[k, v], state}
    end
  end

  defp lua_next(_, state), do: {[nil, nil], state}

  defp find_next_entry(data, nil) do
    # Return the first entry
    iter = :maps.iterator(data)

    case :maps.next(iter) do
      :none -> nil
      {k, v, _} -> {k, v}
    end
  end

  defp find_next_entry(data, key) do
    # Walk the iterator until we find key, then return the next entry
    iter = :maps.iterator(data)
    find_after_key(iter, key)
  end

  defp find_after_key(iter, key) do
    case :maps.next(iter) do
      :none ->
        nil

      {^key, _, next_iter} ->
        case :maps.next(next_iter) do
          :none -> nil
          {k, v, _} -> {k, v}
        end

      {_, _, next_iter} ->
        find_after_key(next_iter, key)
    end
  end

  # pairs(table) — returns next, table, nil
  defp lua_pairs([{:tref, _} = tref | _], state) do
    next_func = Map.fetch!(state.globals, "next")
    {[next_func, tref, nil], state}
  end

  # ipairs(table) — returns iterator function, table, 0
  defp lua_ipairs([{:tref, _} = tref | _], state) do
    iterator =
      {:native_func,
       fn [table_ref, index], state ->
         i = index + 1
         {:tref, id} = table_ref
         table = Map.fetch!(state.tables, id)

         case Map.get(table.data, i) do
           nil -> {[nil], state}
           v -> {[i, v], state}
         end
       end}

    {[iterator, tref, 0], state}
  end

  # setmetatable(table, metatable) — sets the metatable for a table
  defp lua_setmetatable([{:tref, _} = tref, metatable], state) do
    # Validate metatable is nil or a table
    case metatable do
      nil ->
        state = State.update_table(state, tref, fn table -> %{table | metatable: nil} end)
        {[tref], state}

      {:tref, _} = mt_ref ->
        state = State.update_table(state, tref, fn table -> %{table | metatable: mt_ref} end)
        {[tref], state}

      _ ->
        raise Lua.VM.ArgumentError,
          function_name: "setmetatable",
          arg_num: 2,
          expected: "nil or table"
    end
  end

  defp lua_setmetatable([non_table | _], _state) do
    raise Lua.VM.ArgumentError,
      function_name: "setmetatable",
      arg_num: 1,
      expected: "table",
      got: Value.type_name(non_table)
  end

  defp lua_setmetatable([], _state) do
    raise Lua.VM.ArgumentError.value_expected("setmetatable", 1)
  end

  # getmetatable(object) — returns the metatable of an object
  defp lua_getmetatable([{:tref, _} = tref], state) do
    table = State.get_table(state, tref)

    case table.metatable do
      nil -> {[nil], state}
      mt_ref -> {[mt_ref], state}
    end
  end

  defp lua_getmetatable([_other], state) do
    # For non-tables, Lua returns nil (or the metatable set for that type, but we don't support that yet)
    {[nil], state}
  end

  defp lua_getmetatable([], state) do
    {[nil], state}
  end
end
