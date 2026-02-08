defmodule Lua.VM.Value do
  @moduledoc """
  Shared utilities for working with Lua values in the VM.

  Provides type inspection, truthiness, string conversion, number parsing,
  and sequence length computation used by both the executor and stdlib.
  """

  @doc """
  Returns the Lua type name as a string for the given value.
  """
  @spec type_name(term()) :: String.t()
  def type_name(nil), do: "nil"
  def type_name(v) when is_boolean(v), do: "boolean"
  def type_name(v) when is_integer(v), do: "number"
  def type_name(v) when is_float(v), do: "number"
  def type_name(v) when is_binary(v), do: "string"
  def type_name({:tref, _}), do: "table"
  def type_name({:lua_closure, _, _}), do: "function"
  def type_name({:native_func, _}), do: "function"
  def type_name(_), do: "userdata"

  @doc """
  Returns whether a Lua value is truthy.

  In Lua, only `nil` and `false` are falsy. Everything else is truthy.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(_), do: true

  @doc """
  Converts a Lua value to its string representation.
  """
  @spec to_string(term()) :: String.t()
  def to_string(nil), do: "nil"
  def to_string(true), do: "true"
  def to_string(false), do: "false"
  def to_string(v) when is_integer(v), do: Integer.to_string(v)

  def to_string(v) when is_float(v) do
    # Lua displays floats with at least one decimal place
    if v == Float.floor(v) and abs(v) < 1.0e15 do
      :erlang.float_to_binary(v, decimals: 1)
    else
      Float.to_string(v)
    end
  end

  def to_string(v) when is_binary(v), do: v

  def to_string({:tref, id}),
    do: "table: 0x#{String.pad_leading(Integer.to_string(id, 16), 14, "0")}"

  def to_string({:lua_closure, _, _}), do: "function"
  def to_string({:native_func, _}), do: "function"
  def to_string(other), do: inspect(other)

  @doc """
  Parses a string to a number (integer or float), supporting hex notation.

  Returns `nil` if the string cannot be parsed.
  """
  @spec parse_number(String.t()) :: number() | nil
  def parse_number(str) do
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

  @doc """
  Computes the Lua sequence length of a table's data map.

  Finds the largest N where keys 1..N are all present.
  """
  @spec sequence_length(map()) :: non_neg_integer()
  def sequence_length(data) do
    do_sequence_length(data, 1)
  end

  defp do_sequence_length(data, n) do
    if Map.has_key?(data, n), do: do_sequence_length(data, n + 1), else: n - 1
  end
end
