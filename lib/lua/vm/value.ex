defmodule Lua.VM.Value do
  @moduledoc """
  Shared utilities for working with Lua values in the VM.

  Provides type inspection, truthiness, string conversion, number parsing,
  sequence length computation, and value encoding/decoding used by both
  the executor and stdlib.
  """

  alias Lua.VM.Numeric
  alias Lua.VM.State

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
  def type_name({:udref, _}), do: "userdata"
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

  def to_string({:tref, id}), do: "table: 0x#{String.pad_leading(Integer.to_string(id, 16), 14, "0")}"

  def to_string({:lua_closure, _, _}), do: "function"
  def to_string({:native_func, _}), do: "function"
  def to_string(other), do: inspect(other)

  @doc """
  Parses a string to a number (integer or float), supporting hex notation.

  Hex integer literals overflow-wrap into the signed 64-bit range per Lua 5.3
  §3.1 (e.g. `"0xFFFFFFFFFFFFFFFF"` → `-1`). Hex floats with a fractional
  part or binary exponent (e.g. `"0xAA.0"`, `"0x1.8p3"`) are also supported.

  Returns `nil` if the string cannot be parsed.
  """
  @spec parse_number(String.t()) :: number() | nil
  def parse_number(str) do
    str = String.trim(str)

    {sign, body} =
      case str do
        "-" <> rest -> {-1, String.trim_leading(rest)}
        "+" <> rest -> {1, String.trim_leading(rest)}
        _ -> {1, str}
      end

    parsed =
      if String.starts_with?(body, "0x") or String.starts_with?(body, "0X") do
        parse_hex_number(String.slice(body, 2..-1//1))
      else
        case Integer.parse(body) do
          {n, ""} ->
            n

          _ ->
            case Float.parse(body) do
              {f, ""} -> f
              _ -> nil
            end
        end
      end

    case parsed do
      nil -> nil
      n when sign == 1 -> n
      n when is_integer(n) -> Numeric.to_signed_int64(-n)
      n when is_float(n) -> -n
    end
  end

  # Parse the body of a hex literal (after "0x"). Supports:
  #   * integer:        "FF"        → 255 (wrapped to signed int64)
  #   * fractional:     "FF.8"      → 255.5
  #   * exponent only:  "FFp4"      → 4080.0
  #   * fractional+exp: "1.8p3"     → 12.0
  defp parse_hex_number(body) do
    case parse_hex_int(body) do
      {int_val, ""} ->
        Numeric.to_signed_int64(int_val)

      {int_val, "." <> rest} ->
        parse_hex_frac(int_val, rest)

      {int_val, <<p, rest::binary>>} when p in [?p, ?P] ->
        parse_hex_exp(int_val + 0.0, rest)

      _ ->
        nil
    end
  end

  defp parse_hex_int(""), do: :error
  defp parse_hex_int(body), do: Integer.parse(body, 16)

  defp parse_hex_frac(int_val, frac_and_rest) do
    case Integer.parse(frac_and_rest, 16) do
      {frac_int, rest} ->
        # Determine how many hex digits the fractional part used.
        digits = byte_size(frac_and_rest) - byte_size(rest)
        frac = if digits == 0, do: 0.0, else: frac_int / :math.pow(16, digits)
        base = int_val + frac

        case rest do
          "" -> base
          <<p, exp_rest::binary>> when p in [?p, ?P] -> parse_hex_exp(base, exp_rest)
          _ -> nil
        end

      :error ->
        nil
    end
  end

  defp parse_hex_exp(base, exp_str) do
    case Integer.parse(exp_str) do
      {exp, ""} -> base * :math.pow(2, exp)
      _ -> nil
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

  # --- Encoding (Elixir → Lua VM) ---

  @doc """
  Encodes an Elixir value into the Lua VM's internal representation.

  Returns `{encoded_value, state}` since encoding maps and lists allocates tables.
  """
  @spec encode(term(), State.t()) :: {term(), State.t()}
  def encode(nil, state), do: {nil, state}
  def encode(value, state) when is_boolean(value), do: {value, state}
  def encode(value, state) when is_number(value), do: {value, state}
  def encode(value, state) when is_binary(value), do: {value, state}
  def encode(value, state) when is_atom(value), do: {Atom.to_string(value), state}

  def encode(fun, state) when is_function(fun, 2), do: {{:native_func, fun}, state}

  def encode(fun, state) when is_function(fun, 1) do
    wrapper = fn args, st -> {List.wrap(fun.(args)), st} end
    {{:native_func, wrapper}, state}
  end

  def encode({:userdata, value}, state) do
    State.alloc_userdata(state, value)
  end

  def encode(map, state) when is_map(map) do
    {data, state} =
      Enum.reduce(map, {%{}, state}, fn {k, v}, {data, state} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        {encoded_v, state} = encode(v, state)
        {Map.put(data, key, encoded_v), state}
      end)

    State.alloc_table(state, data)
  end

  def encode(list, state) when is_list(list) do
    if keyword_list?(list) do
      {data, state} =
        Enum.reduce(list, {%{}, state}, fn {k, v}, {data, state} ->
          key = Atom.to_string(k)
          {encoded_v, state} = encode(v, state)
          {Map.put(data, key, encoded_v), state}
        end)

      State.alloc_table(state, data)
    else
      {data, state} =
        list
        |> Enum.with_index(1)
        |> Enum.reduce({%{}, state}, fn {v, idx}, {data, state} ->
          {encoded_v, state} = encode(v, state)
          {Map.put(data, idx, encoded_v), state}
        end)

      State.alloc_table(state, data)
    end
  end

  @doc """
  Encodes a list of Elixir values, threading state through each encoding.

  Returns `{encoded_values, state}`.
  """
  @spec encode_list([term()], State.t()) :: {[term()], State.t()}
  def encode_list(values, state) do
    {reversed, state} =
      Enum.reduce(values, {[], state}, fn v, {acc, state} ->
        {encoded, state} = encode(v, state)
        {[encoded | acc], state}
      end)

    {Enum.reverse(reversed), state}
  end

  defp keyword_list?([{k, _v} | rest]) when is_atom(k), do: keyword_list?(rest)
  defp keyword_list?([]), do: true
  defp keyword_list?(_), do: false

  # --- Decoding (Lua VM → Elixir) ---

  @doc """
  Decodes a Lua VM value into an Elixir-friendly representation.

  Tables are returned as lists of `{key, decoded_value}` tuples.
  Functions (closures, native) pass through as-is.
  """
  @spec decode(term(), State.t()) :: term()
  def decode(nil, _state), do: nil
  def decode(value, _state) when is_boolean(value), do: value
  def decode(value, _state) when is_number(value), do: value
  def decode(value, _state) when is_binary(value), do: value

  def decode({:udref, _} = ref, state) do
    value = State.get_userdata(state, ref)
    {:userdata, value}
  end

  def decode({:tref, id}, state) do
    table = Map.fetch!(state.tables, id)

    Enum.map(table.data, fn {k, v} -> {k, decode(v, state)} end)
  end

  def decode(value, _state), do: value

  @doc """
  Decodes a list of Lua VM values.
  """
  @spec decode_list([term()], State.t()) :: [term()]
  def decode_list(values, state) do
    Enum.map(values, &decode(&1, state))
  end
end
