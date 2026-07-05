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
  def type_name({:compiled_closure, _, _}), do: "function"
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

  def to_string({:tref, id}), do: "table: 0x#{address(id)}"

  # PUC-Lua renders functions as `function: 0x<addr>`; the suite and host
  # code that calls `tostring` on a function rely on the `function:` prefix.
  # There is no stable identity to print like a table's tref id, so derive a
  # deterministic pseudo-address from the term itself.
  def to_string({:lua_closure, _, _} = f), do: "function: 0x#{address(:erlang.phash2(f))}"
  def to_string({:compiled_closure, _, _} = f), do: "function: 0x#{address(:erlang.phash2(f))}"
  def to_string({:native_func, _} = f), do: "function: builtin: 0x#{address(:erlang.phash2(f))}"
  def to_string(other), do: inspect(other)

  defp address(id), do: String.pad_leading(Integer.to_string(id, 16), 14, "0")

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

    # A sign must be adjacent to the numeral; Lua's `l_str2d` does not allow
    # whitespace between the sign and the digits (`tonumber("+ 1")` is nil).
    {sign, body} =
      case str do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        _ -> {1, str}
      end

    if String.starts_with?(body, "0x") or String.starts_with?(body, "0X") do
      # Hex literals wrap modulo 2^64 (Lua 5.3 §3.1); the sign is applied after
      # wrapping the magnitude into the signed 64-bit range.
      case parse_hex_number(String.slice(body, 2..-1//1)) do
        nil -> nil
        n when sign == 1 -> n
        n when is_integer(n) -> Numeric.to_signed_int64(-n)
        n when is_float(n) -> -n
      end
    else
      case Integer.parse(body) do
        {n, ""} -> decimal_int(sign * n)
        _ -> parse_float(sign, body)
      end
    end
  end

  # Lua 5.3.3 §3.1: a *decimal* integer literal converts to a float only when
  # its signed value overflows the 64-bit range (unlike hex literals, which
  # wrap). The sign is applied before the range check, so `-2^63` stays the
  # integer `minint` while `2^63` and `-2^63 - 1` become floats.
  defp decimal_int(n) when is_integer(n) do
    if Numeric.signed?(n), do: n, else: n * 1.0
  end

  # Lua's `l_str2d` accepts leading-dot (`.01`) and trailing-dot (`1.`, `1.e2`)
  # forms that Elixir's stricter `Float.parse` rejects. Normalise the numeral
  # to a fully-formed decimal before delegating; a body with no digit at all
  # (`.`, `.e1`) still fails to parse and yields nil.
  defp parse_float(sign, body) do
    # Reject numerals with no digit in the mantissa (`.`, `.e1`); after
    # normalisation these would otherwise parse as 0.0. A digit appearing only
    # in the exponent (`.e1`) does not count.
    mantissa = body |> String.split(~r/[eE]/, parts: 2) |> hd()

    if Regex.match?(~r/[0-9]/, mantissa) do
      normalized =
        body
        # "1." → "1.0", "1.e2" → "1.0e2"
        |> String.replace(~r/\.([eE]|$)/, ".0\\1")
        # ".01" → "0.01"
        |> then(fn b -> if String.starts_with?(b, "."), do: "0" <> b, else: b end)

      case Float.parse(normalized) do
        {f, ""} -> sign * f
        _ -> nil
      end
    end
  end

  # Parse the body of a hex literal (after "0x"). Supports:
  #   * integer:        "FF"        → 255 (wrapped to signed int64)
  #   * fractional:     "FF.8"      → 255.5
  #   * exponent only:  "FFp4"      → 4080.0
  #   * fractional+exp: "1.8p3"     → 12.0
  # `0x.` with no digit at all is not a number.
  defp parse_hex_number("."), do: nil

  # A leading dot (`.FF`, `.ABCDEFp+24`) is a valid hex float with no integer
  # part, e.g. `tonumber("0x.1")`. Treat it as integer part 0.
  defp parse_hex_number("." <> rest), do: parse_hex_frac(0, rest)

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

  # A trailing dot with no fractional digits (`FF.`, `1.p3`) is still a valid
  # hex float; the fractional part contributes 0.
  defp parse_hex_frac(int_val, ""), do: int_val + 0.0

  defp parse_hex_frac(int_val, <<p, exp_rest::binary>>) when p in [?p, ?P] do
    parse_hex_exp(int_val + 0.0, exp_rest)
  end

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
  @spec encode(term(), State.t(), (fun() -> term())) :: {term(), State.t()}
  def encode(value, state, fun_wrapper \\ &default_fun_wrapper/1)
  def encode(nil, state, _fun_wrapper), do: {nil, state}
  def encode(value, state, _fun_wrapper) when is_boolean(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_number(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_binary(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_atom(value), do: {Atom.to_string(value), state}

  def encode(fun, state, fun_wrapper) when is_function(fun, 1) or is_function(fun, 2), do: {fun_wrapper.(fun), state}

  def encode({:userdata, value}, state, _fun_wrapper) do
    State.alloc_userdata(state, value)
  end

  # Structs are maps, so without this clause a bare `%MyStruct{}` would encode
  # to a Lua table carrying a `"__struct__"` key — a silent, lossy conversion.
  # Refuse it explicitly: the caller must decide how the struct maps to a Lua
  # value. Protocol-based struct encoding is planned (see issue #341); raising
  # now keeps that future addition additive rather than a breaking change.
  def encode(%mod{}, _state, _fun_wrapper) do
    raise Lua.RuntimeException,
          "cannot encode #{inspect(mod)} struct into a Lua value. Convert it to a " <>
            "plain map first (e.g. `Map.from_struct/1`), selecting only the fields " <>
            "Lua needs. Protocol-based struct encoding is planned (issue #341)."
  end

  def encode(map, state, fun_wrapper) when is_map(map) do
    {data, state} =
      Enum.reduce(map, {%{}, state}, fn {k, v}, {data, state} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        {encoded_v, state} = encode(v, state, fun_wrapper)
        {Map.put(data, key, encoded_v), state}
      end)

    State.alloc_table(state, data)
  end

  def encode(list, state, fun_wrapper) when is_list(list) do
    if keyword_list?(list) do
      {data, state} =
        Enum.reduce(list, {%{}, state}, fn {k, v}, {data, state} ->
          key = Atom.to_string(k)
          {encoded_v, state} = encode(v, state, fun_wrapper)
          {Map.put(data, key, encoded_v), state}
        end)

      State.alloc_table(state, data)
    else
      {data, state} =
        list
        |> Enum.with_index(1)
        |> Enum.reduce({%{}, state}, fn {v, idx}, {data, state} ->
          {encoded_v, state} = encode(v, state, fun_wrapper)
          {Map.put(data, idx, encoded_v), state}
        end)

      State.alloc_table(state, data)
    end
  end

  # Default function wrapper, preserving the raw-state calling convention for
  # low-level callers. `Lua.set!/3` and `Lua.encode!/2` inject their own
  # wrapper so callbacks receive the public `t:Lua.t/0` instead.
  defp default_fun_wrapper(fun) when is_function(fun, 2), do: {:native_func, fun}

  defp default_fun_wrapper(fun) when is_function(fun, 1) do
    {:native_func, fn args, st -> {List.wrap(fun.(args)), st} end}
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

    Enum.map(Lua.VM.Table.to_map(table), fn {k, v} -> {k, decode(v, state)} end)
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
