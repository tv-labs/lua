defmodule Lua.VM.Stdlib do
  @moduledoc """
  Standard library functions for the Lua VM.

  Provides essential built-in functions that are available in the global
  scope when the standard library is installed.
  """

  alias Lua.VM.State

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
    |> State.register_function("rawget", &lua_rawget/2)
    |> State.register_function("rawset", &lua_rawset/2)
    |> State.register_function("rawlen", &lua_rawlen/2)
    |> State.register_function("rawequal", &lua_rawequal/2)
  end

  # type(v) — returns the type of v as a string
  defp lua_type([value | _], state) do
    type_name =
      case value do
        nil -> "nil"
        v when is_boolean(v) -> "boolean"
        v when is_integer(v) -> "number"
        v when is_float(v) -> "number"
        v when is_binary(v) -> "string"
        {:tref, _} -> "table"
        {:lua_closure, _, _} -> "function"
        {:native_func, _} -> "function"
        _ -> "userdata"
      end

    {[type_name], state}
  end

  defp lua_type([], state), do: {["nil"], state}

  # tostring(v) — converts a value to its string representation
  defp lua_tostring([value | _], state) do
    {[value_to_string(value)], state}
  end

  defp lua_tostring([], state), do: {["nil"], state}

  # tonumber(v [, base]) — converts a string to a number
  defp lua_tonumber([value | rest], state) do
    base = List.first(rest)

    result =
      case {value, base} do
        {v, nil} when is_number(v) ->
          v

        {v, nil} when is_binary(v) ->
          parse_number(v)

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
    output = Enum.map_join(args, "\t", &value_to_string/1)
    IO.puts(output)
    {[], state}
  end

  # error(message) — raises a Lua runtime error
  defp lua_error([message | _], _state) do
    raise Lua.VM.LuaError, message: message
  end

  defp lua_error([], _state) do
    raise Lua.VM.LuaError, message: nil
  end

  # assert(v [, message]) — raises if v is falsy
  defp lua_assert([value | rest], state) do
    if value == nil or value == false do
      message =
        case rest do
          [msg | _] -> msg
          [] -> "assertion failed!"
        end

      raise Lua.VM.LuaError, message: message
    else
      {[value], state}
    end
  end

  defp lua_assert([], _state) do
    raise Lua.VM.LuaError, message: "assertion failed!"
  end

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
    {[compute_sequence_length(table.data, 1)], state}
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

  # Convert a Lua value to its string representation
  defp value_to_string(nil), do: "nil"
  defp value_to_string(true), do: "true"
  defp value_to_string(false), do: "false"
  defp value_to_string(v) when is_integer(v), do: Integer.to_string(v)

  defp value_to_string(v) when is_float(v) do
    # Lua displays floats with at least one decimal place
    if v == Float.floor(v) and abs(v) < 1.0e15 do
      :erlang.float_to_binary(v, decimals: 1)
    else
      Float.to_string(v)
    end
  end

  defp value_to_string(v) when is_binary(v), do: v

  defp value_to_string({:tref, id}),
    do: "table: 0x#{String.pad_leading(Integer.to_string(id, 16), 14, "0")}"

  defp value_to_string({:lua_closure, _, _}), do: "function"
  defp value_to_string({:native_func, _}), do: "function"
  defp value_to_string(other), do: inspect(other)

  defp parse_number(str) do
    str = String.trim(str)

    cond do
      String.starts_with?(str, "0x") or String.starts_with?(str, "0X") ->
        case Integer.parse(String.slice(str, 2..-1//1), 16) do
          {n, ""} -> n
          _ -> nil
        end

      true ->
        case Integer.parse(str) do
          {n, ""} ->
            n

          _ ->
            case Float.parse(str) do
              {f, ""} -> f
              _ -> nil
            end
        end
    end
  end

  defp compute_sequence_length(data, n) do
    if Map.has_key?(data, n), do: compute_sequence_length(data, n + 1), else: n - 1
  end
end
