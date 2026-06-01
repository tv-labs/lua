defmodule Lua.VM.Stdlib.String do
  @moduledoc """
  String standard library functions for Lua 5.3.

  This module implements the Lua string library, providing functions for string
  manipulation. All functions are registered in the global `string` table when
  the standard library is installed.

  ## Implemented Functions

  - `string.lower(s)` - converts string to lowercase
  - `string.upper(s)` - converts string to uppercase
  - `string.len(s)` - returns length of string in bytes
  - `string.sub(s, i [, j])` - extracts substring (1-based indexing)
  - `string.rep(s, n [, sep])` - repeats string with optional separator
  - `string.reverse(s)` - reverses a string
  - `string.byte(s [, i [, j]])` - returns byte values of characters
  - `string.char(...)` - creates string from byte values
  - `string.format(fmt, ...)` - C-style string formatting

  ## Pattern Matching

  - `string.find(s, pattern [, init [, plain]])` - find pattern in string
  - `string.match(s, pattern [, init])` - match pattern and return captures
  - `string.gmatch(s, pattern)` - iterate over all matches
  - `string.gsub(s, pattern, repl [, n])` - global substitution
  """

  @behaviour Lua.VM.Stdlib.Library

  import Bitwise

  alias Lua.VM.ArgumentError
  alias Lua.VM.Executor
  alias Lua.VM.Limits
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Pattern
  alias Lua.VM.Stdlib.String.Pack
  alias Lua.VM.Stdlib.Util

  @impl true
  def lib_name, do: "string"

  @impl true
  def install(%State{} = state) do
    # Create string table with all functions
    string_table = %{
      "lower" => {:native_func, &string_lower/2},
      "upper" => {:native_func, &string_upper/2},
      "len" => {:native_func, &string_len/2},
      "sub" => {:native_func, &string_sub/2},
      "rep" => {:native_func, &string_rep/2},
      "reverse" => {:native_func, &string_reverse/2},
      "byte" => {:native_func, &string_byte/2},
      "char" => {:native_func, &string_char/2},
      "format" => {:native_func, &string_format/2},
      "find" => {:native_func, &string_find/2},
      "match" => {:native_func, &string_match/2},
      "gmatch" => {:native_func, &string_gmatch/2},
      "gsub" => {:native_func, &string_gsub/2},
      "packsize" => {:native_func, &string_packsize/2},
      "pack" => {:native_func, &string_pack/2},
      "unpack" => {:native_func, &string_unpack/2}
    }

    # Create the string table in VM state
    {tref, state} = State.alloc_table(state, string_table)

    # Register as global
    state = State.set_global(state, "string", tref)

    # Create string metatable with __index = string table
    # This enables ("hello"):upper() syntax
    {mt_ref, state} = State.alloc_table(state, %{"__index" => tref})

    # Store as the type metatable for strings
    %{state | metatables: Map.put(state.metatables, "string", mt_ref)}
  end

  # string.lower(s) - converts string to lowercase
  defp string_lower([str | _], state) when is_binary(str) do
    {[String.downcase(str)], state}
  end

  defp string_lower([other | _], _state) do
    raise_string_expected(1, "lower", other)
  end

  defp string_lower([], _state) do
    raise_arg_expected(1, "lower")
  end

  # string.upper(s) - converts string to uppercase
  defp string_upper([str | _], state) when is_binary(str) do
    {[String.upcase(str)], state}
  end

  defp string_upper([other | _], _state) do
    raise_string_expected(1, "upper", other)
  end

  defp string_upper([], _state) do
    raise_arg_expected(1, "upper")
  end

  # string.len(s) - returns length of string
  defp string_len([str | _], state) when is_binary(str) do
    {[byte_size(str)], state}
  end

  defp string_len([other | _], _state) do
    raise_string_expected(1, "len", other)
  end

  defp string_len([], _state) do
    raise_arg_expected(1, "len")
  end

  # string.sub(s, i [, j]) - returns substring from position i to j
  defp string_sub([str | rest], state) when is_binary(str) do
    i = Enum.at(rest, 0)
    j = Enum.at(rest, 1)

    if !is_integer(i) do
      raise ArgumentError,
        function_name: "string.sub",
        arg_num: 2,
        expected: "number"
    end

    # Mirror PUC-Lua's str_sub: keep 1-based positions, then clamp.
    len = byte_size(str)
    start_pos = posrelat(i, len)
    end_pos = if j == nil, do: -1, else: j
    end_pos = posrelat(end_pos, len)

    start_pos = if start_pos < 1, do: 1, else: start_pos
    end_pos = if end_pos > len, do: len, else: end_pos

    result =
      if start_pos <= end_pos do
        binary_part(str, start_pos - 1, end_pos - start_pos + 1)
      else
        ""
      end

    {[result], state}
  end

  defp string_sub([other | _], _state) do
    raise_string_expected(1, "sub", other)
  end

  defp string_sub([], _state) do
    raise_arg_expected(1, "sub")
  end

  # string.rep(s, n [, sep]) - repeats string s n times with optional separator
  defp string_rep([str, n | rest], state) when is_binary(str) and is_integer(n) do
    do_string_rep(str, n, rest, state)
  end

  # Lua 5.3 accepts floats with integer values as integer args. `2^3`
  # always yields the float 8.0 in Lua, so without this coercion
  # `string.rep("x", 2^3)` rejects an obviously-valid count.
  defp string_rep([str, n | rest], state) when is_binary(str) and is_float(n) do
    if n == Float.floor(n) do
      do_string_rep(str, trunc(n), rest, state)
    else
      raise ArgumentError,
        function_name: "string.rep",
        arg_num: 2,
        expected: "number",
        got: "number has no integer representation"
    end
  end

  defp string_rep([str, n | _], _state) when is_binary(str) do
    raise ArgumentError,
      function_name: "string.rep",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(n)
  end

  defp string_rep([other, _ | _], _state) do
    raise_string_expected(1, "rep", other)
  end

  defp string_rep([_], _state) do
    raise ArgumentError,
      function_name: "string.rep",
      arg_num: 2,
      expected: "number"
  end

  defp string_rep([], _state) do
    raise_arg_expected(1, "rep")
  end

  defp do_string_rep(str, n, rest, state) do
    sep = Enum.at(rest, 0, "")

    if !is_binary(sep) do
      raise ArgumentError,
        function_name: "string.rep",
        arg_num: 3,
        expected: "string",
        got: Util.typeof(sep)
    end

    result =
      if n <= 0 do
        ""
      else
        # Compute the result size from the count *before* building it, so an
        # oversized request fails with a catchable error instead of trying to
        # allocate (and OOM the host on) a multi-petabyte binary.
        Limits.check_string_size!(n * byte_size(str) + (n - 1) * byte_size(sep))
        Enum.map_join(1..n, sep, fn _ -> str end)
      end

    {[result], state}
  end

  # string.reverse(s) - reverses a string byte-by-byte (Lua strings are
  # byte arrays, not codepoint sequences — so a NUL or non-UTF-8 byte
  # must come back at the mirror position).
  defp string_reverse([str | _], state) when is_binary(str) do
    reversed = str |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
    {[reversed], state}
  end

  defp string_reverse([other | _], _state) do
    raise_string_expected(1, "reverse", other)
  end

  defp string_reverse([], _state) do
    raise_arg_expected(1, "reverse")
  end

  # string.byte(s [, i [, j]]) - returns byte values of characters at positions i to j
  defp string_byte([str | rest], state) when is_binary(str) do
    i = Enum.at(rest, 0, 1)
    j = Enum.at(rest, 1, i)

    if !is_integer(i) do
      raise ArgumentError,
        function_name: "string.byte",
        arg_num: 2,
        expected: "number"
    end

    if !is_integer(j) do
      raise ArgumentError,
        function_name: "string.byte",
        arg_num: 3,
        expected: "number"
    end

    # Per Lua 5.3 §6.4.2, string.byte semantics: posi = max(i, 1) (after
    # normalising negative indices); posj = min(j, #s). If posj < posi the
    # call returns no bytes.
    len = byte_size(str)
    posi = if i < 0, do: max(len + i + 1, 1), else: max(i, 1)
    posj = if j < 0, do: len + j + 1, else: min(j, len)

    bytes =
      if posj < posi or posi > len or posj < 1 do
        []
      else
        Enum.map(posi..posj//1, fn idx -> :binary.at(str, idx - 1) end)
      end

    {bytes, state}
  end

  defp string_byte([other | _], _state) do
    raise_string_expected(1, "byte", other)
  end

  defp string_byte([], _state) do
    raise_arg_expected(1, "byte")
  end

  # string.char(...) - converts byte values to characters
  defp string_char(args, state) do
    result =
      args
      |> Enum.with_index(1)
      |> Enum.reduce_while("", fn {arg, idx}, acc ->
        cond do
          not is_integer(arg) ->
            {:halt, {:error, idx, "number expected"}}

          arg < 0 or arg > 255 ->
            {:halt, {:error, idx, "value out of range"}}

          true ->
            {:cont, acc <> <<arg>>}
        end
      end)

    case result do
      {:error, arg_num, "number expected"} ->
        raise ArgumentError,
          function_name: "string.char",
          arg_num: arg_num,
          expected: "number"

      {:error, arg_num, "value out of range"} ->
        raise ArgumentError,
          function_name: "string.char",
          arg_num: arg_num,
          details: "value out of range"

      str ->
        {[str], state}
    end
  end

  # string.format(formatstring, ...) - formats strings with C-style format specifiers
  defp string_format([fmt | args], state) when is_binary(fmt) do
    result = format_string(fmt, args, [])
    {[result], state}
  rescue
    e in Lua.VM.RuntimeError ->
      reraise e, __STACKTRACE__
  end

  defp string_format([other | _], _state) do
    raise_string_expected(1, "format", other)
  end

  defp string_format([], _state) do
    raise_arg_expected(1, "format")
  end

  # Format string parser - supports full format specifiers: %[flags][width][.precision]specifier
  #
  # `acc` is an iolist, appended as `[acc, piece]` so each step is O(1) and
  # the result is materialized exactly once via `IO.iodata_to_binary/1` at
  # the base case. Avoids the per-character binary reallocation that made
  # this O(n^2) in the format string length.
  #
  # Each step copies the whole run of literal bytes up to the next `%` as a
  # single chunk via `:binary.split/2`, rather than one iolist cell per
  # character. `%` is ASCII 0x25 and never appears as a UTF-8 continuation
  # byte, so splitting on the raw byte is safe for multibyte literals. A
  # per-character iolist would balloon both the list and its eventual
  # flatten on literal-heavy format strings.
  defp format_string(str, args, acc) do
    case :binary.split(str, "%") do
      [literal] -> IO.iodata_to_binary([acc, literal])
      [literal, rest] -> format_directive(rest, args, [acc, literal])
    end
  end

  # `rest` is the format string immediately after a `%`. A second `%`
  # escapes a literal percent; otherwise it begins a format specifier.
  defp format_directive("%" <> rest, args, acc) do
    format_string(rest, args, [acc, "%"])
  end

  defp format_directive(rest, args, acc) do
    {spec, rest2} = parse_format_spec(rest)
    [arg | remaining_args] = args
    str = apply_format_spec(spec, arg)
    format_string(rest2, remaining_args, [acc, str])
  end

  # PUC-Lua copies at most two width and two precision digits into the
  # conversion spec (`scanformat`), erroring on anything longer. We enforce
  # the same bound so a spec like `%.2000000000f` cannot drive a giant
  # `String.duplicate`/padding allocation.
  @max_format_field 99

  # Parse a format spec: [flags][width][.precision]specifier
  defp parse_format_spec(str) do
    {flags, str} = parse_flags(str, 0)
    {width, str} = parse_width(str)
    {precision, str} = parse_precision(str)
    {specifier, str} = parse_specifier(str)
    check_format_field!(width)
    check_format_field!(precision)
    {{flags, width, precision, specifier}, str}
  end

  defp check_format_field!(n) when is_nil(n) or n <= @max_format_field, do: :ok

  defp check_format_field!(_n) do
    raise ArgumentError, function_name: "string.format", details: "invalid conversion"
  end

  # Flags are parsed once into an integer bitmask so the apply path reads
  # precomputed bits instead of re-scanning a binary per specifier. Only the
  # minus and zero bits affect output today (`+`, space, `#` are accepted by
  # PUC-Lua's parser but ignored when rendering); the mask carries all five so
  # the parse stays a single pass without changing behavior.
  @flag_minus 0b00001
  @flag_zero 0b00010
  @flag_plus 0b00100
  @flag_space 0b01000
  @flag_hash 0b10000

  defp parse_flags(<<?-, rest::binary>>, mask), do: parse_flags(rest, mask ||| @flag_minus)
  defp parse_flags(<<?0, rest::binary>>, mask), do: parse_flags(rest, mask ||| @flag_zero)
  defp parse_flags(<<?+, rest::binary>>, mask), do: parse_flags(rest, mask ||| @flag_plus)
  defp parse_flags(<<?\s, rest::binary>>, mask), do: parse_flags(rest, mask ||| @flag_space)
  defp parse_flags(<<?#, rest::binary>>, mask), do: parse_flags(rest, mask ||| @flag_hash)

  defp parse_flags(str, mask), do: {mask, str}

  defp parse_width(<<c, _::binary>> = str) when c in ?0..?9 do
    parse_number(str, 0)
  end

  defp parse_width(str), do: {nil, str}

  defp parse_precision("." <> rest) do
    case rest do
      <<c, _::binary>> when c in ?0..?9 ->
        parse_number(rest, 0)

      _ ->
        {0, rest}
    end
  end

  defp parse_precision(str), do: {nil, str}

  defp parse_number(<<c, rest::binary>>, acc) when c in ?0..?9 do
    parse_number(rest, acc * 10 + (c - ?0))
  end

  defp parse_number(str, acc), do: {acc, str}

  # Keep the conversion char as a raw integer code point so apply_format_spec/2
  # dispatches on BEAM integer patterns rather than one-byte binaries.
  defp parse_specifier(<<c, rest::binary>>), do: {c, rest}

  defp parse_specifier("") do
    raise ArgumentError,
      function_name: "string.format",
      details: "invalid format string"
  end

  # Apply a format spec to a value
  defp apply_format_spec({flags, width, precision, specifier}, arg) do
    raw =
      case specifier do
        ?d -> format_spec_integer(arg)
        ?i -> format_spec_integer(arg)
        ?u -> format_spec_unsigned(arg)
        ?f -> format_spec_float(arg, precision || 6)
        ?e -> format_spec_scientific(arg, precision || 6, :lower)
        ?E -> format_spec_scientific(arg, precision || 6, :upper)
        ?g -> format_spec_general(arg, precision || 6, :lower)
        ?G -> format_spec_general(arg, precision || 6, :upper)
        ?x -> format_spec_hex(arg, :lower)
        ?X -> format_spec_hex(arg, :upper)
        ?o -> format_spec_octal(arg)
        ?c -> format_char(arg)
        ?s -> format_spec_string(arg, precision)
        ?q -> format_quoted(arg)
        _ -> raise ArgumentError, function_name: "string.format", details: "invalid option '%#{<<specifier>>}'"
      end

    apply_width_flags(raw, flags, width)
  end

  defp format_spec_integer(val) when is_integer(val), do: Integer.to_string(val)
  defp format_spec_integer(val) when is_float(val), do: Integer.to_string(trunc(val))

  defp format_spec_integer(_) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  defp format_spec_unsigned(val) when is_integer(val) and val >= 0, do: Integer.to_string(val)

  # Wrap negative as unsigned 64-bit
  defp format_spec_unsigned(val) when is_integer(val), do: Integer.to_string(val + 0x10000000000000000)

  defp format_spec_unsigned(val) when is_float(val), do: format_spec_unsigned(trunc(val))

  defp format_spec_unsigned(_) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  # 0/0 surfaces as the :nan atom in this VM; C Lua prints "nan".
  defp format_spec_float(:nan, _precision), do: "nan"

  defp format_spec_float(val, precision) when is_number(val) do
    float_val = val / 1
    fixed_float(float_val, precision)
  end

  defp format_spec_float(_, _) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  # Format a finite float to exactly `precision` fixed decimal places,
  # matching C printf/PUC-Lua %f (round-half-to-even, sign preserved).
  defp fixed_float(float_val, 0) do
    float_sign(float_val) <> Integer.to_string(round_half_even(abs(float_val)))
  end

  defp fixed_float(float_val, precision) do
    digits =
      ~c"~.*f"
      |> :io_lib.format([precision, abs(float_val)])
      |> :erlang.iolist_to_binary()

    float_sign(float_val) <> digits
  end

  # Derive the printed sign from the IEEE-754 sign bit, not `< 0.0`. On the
  # BEAM `-0.0 < 0.0` is false, which would drop the sign of negative zero;
  # C printf/PUC-Lua print "-0.000000" for it. Reading the sign bit treats
  # exact -0.0 as negative while leaving +0.0 and positive values unsigned.
  defp float_sign(float_val) do
    <<sign_bit::1, _::63>> = <<float_val::float>>
    if sign_bit == 1, do: "-", else: ""
  end

  # Round a non-negative float to the nearest integer, ties to even,
  # matching C printf %.0f. :erlang.round/1 rounds half away from zero,
  # so resolve the exact-half tie explicitly.
  defp round_half_even(abs_val) when abs_val >= 0.0 do
    floor = :erlang.trunc(abs_val)
    frac = abs_val - floor

    cond do
      frac < 0.5 -> floor
      frac > 0.5 -> floor + 1
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp format_spec_scientific(val, precision, case_style) when is_number(val) do
    str = format_scientific_str(val / 1, precision)
    if case_style == :upper, do: String.upcase(str), else: str
  end

  defp format_spec_scientific(_, _, _) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  # Format a float in scientific notation: mantissa e+/-exp with at least 2 digit exponent
  defp format_scientific_str(float_val, precision) do
    if float_val == 0.0 do
      mantissa = float_sign(float_val) <> "0." <> String.duplicate("0", precision)
      "#{mantissa}e+00"
    else
      exp = float_val |> abs() |> :math.log10() |> floor()
      mantissa = float_val / :math.pow(10, exp)

      # Format the mantissa to the requested precision (round-half-to-even),
      # then carry into the exponent if rounding pushed |mantissa| to 10.
      {mantissa_str, exp} = mantissa_with_carry(mantissa, precision, exp)

      exp_sign = if exp >= 0, do: "+", else: "-"
      exp_str = exp |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
      "#{mantissa_str}e#{exp_sign}#{exp_str}"
    end
  end

  # Format the mantissa to `precision` decimals; if rounding lifted it to
  # |mantissa| >= 10 (e.g. 9.999 -> 10.0), divide by ten and bump the exponent.
  defp mantissa_with_carry(mantissa, precision, exp) do
    str = fixed_float(mantissa, precision)
    {mantissa_val, _} = Float.parse(str)

    if abs(mantissa_val) >= 10.0 do
      {fixed_float(mantissa_val / 10.0, precision), exp + 1}
    else
      {str, exp}
    end
  end

  defp format_spec_general(val, precision, case_style) when is_number(val) do
    float_val = val / 1
    precision = max(1, precision)

    if float_val == 0.0 do
      float_sign(float_val) <> "0"
    else
      abs_val = abs(float_val)
      exp = abs_val |> :math.log10() |> floor()

      if exp < -4 or exp >= precision do
        # Scientific notation with trailing zeros stripped
        p = precision - 1
        str = format_scientific_str(float_val, p)
        str = strip_trailing_zeros_scientific(str)
        if case_style == :upper, do: String.upcase(str), else: str
      else
        # Fixed notation with trailing zeros stripped
        p = precision - exp - 1
        p = max(0, p)
        str = format_spec_float(float_val, p)
        str = strip_trailing_zeros(str)
        if case_style == :upper, do: String.upcase(str), else: str
      end
    end
  end

  defp format_spec_general(_, _, _) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  defp strip_trailing_zeros(str) do
    if String.contains?(str, ".") do
      str |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      str
    end
  end

  defp strip_trailing_zeros_scientific(str) do
    case Regex.run(~r/^(.*?)([eE][+-]\d+)$/, str) do
      [_, mantissa, exp_part] ->
        mantissa = strip_trailing_zeros(mantissa)
        "#{mantissa}#{exp_part}"

      _ ->
        str
    end
  end

  defp format_spec_hex(val, case_style) when is_integer(val) do
    str = Integer.to_string(val, 16)
    if case_style == :lower, do: String.downcase(str), else: String.upcase(str)
  end

  defp format_spec_hex(val, case_style) when is_float(val), do: format_spec_hex(trunc(val), case_style)

  defp format_spec_hex(_, _) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  defp format_spec_octal(val) when is_integer(val), do: Integer.to_string(val, 8)
  defp format_spec_octal(val) when is_float(val), do: Integer.to_string(trunc(val), 8)

  defp format_spec_octal(_) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  defp format_spec_string(arg, precision) do
    str = Util.to_lua_string(arg)

    case precision do
      nil -> str
      n -> String.slice(str, 0, n)
    end
  end

  defp format_char(val) when is_integer(val) and val >= 0 and val <= 255, do: <<val>>

  defp format_char(_) do
    raise ArgumentError,
      function_name: "string.format",
      details: "invalid value for %c"
  end

  defp format_quoted(val) when is_binary(val) do
    escaped =
      val
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp format_quoted(_) do
    raise ArgumentError,
      function_name: "string.format",
      expected: "string",
      details: "for %q"
  end

  # string.find(s, pattern [, init [, plain]])
  defp string_find([s, pattern | rest], state) when is_binary(s) and is_binary(pattern) do
    init = Enum.at(rest, 0, 1)
    plain = Enum.at(rest, 1, false)

    init = if is_number(init), do: trunc(init), else: 1

    if plain != nil and plain != false do
      # Plain substring search
      len = byte_size(s)

      if init > len + 1 do
        {[nil], state}
      else
        search_pos =
          cond do
            init > 0 -> init - 1
            init < 0 -> max(len + init, 0)
            true -> 0
          end

        case :binary.match(s, pattern, scope: {search_pos, len - search_pos}) do
          {start, found_len} ->
            {[start + 1, start + found_len], state}

          :nomatch ->
            {[nil], state}
        end
      end
    else
      case Pattern.find(s, pattern, init) do
        {start, stop, captures} ->
          {[start, stop | captures], state}

        :nomatch ->
          {[nil], state}
      end
    end
  end

  defp string_find([other | _], _state) when not is_binary(other) do
    raise_string_expected(1, "find", other)
  end

  defp string_find([], _state), do: raise_arg_expected(1, "find")

  # string.match(s, pattern [, init])
  defp string_match([s, pattern | rest], state) when is_binary(s) and is_binary(pattern) do
    init = Enum.at(rest, 0, 1)
    init = if is_number(init), do: trunc(init), else: 1

    case Pattern.match(s, pattern, init) do
      {:match, captures} -> {captures, state}
      :nomatch -> {[nil], state}
    end
  end

  defp string_match([other | _], _state) when not is_binary(other) do
    raise_string_expected(1, "match", other)
  end

  defp string_match([], _state), do: raise_arg_expected(1, "match")

  # string.gmatch(s, pattern) - returns iterator function
  defp string_gmatch([s, pattern | _], state) when is_binary(s) and is_binary(pattern) do
    # Pre-compute all matches, return an iterator that yields them one by one
    matches = Pattern.gmatch(s, pattern)
    idx_ref = make_ref()
    state = %{state | private: Map.put(state.private, idx_ref, {matches, 0})}

    iter_func =
      {:native_func,
       fn _args, st ->
         {match_list, current_idx} = Map.get(st.private, idx_ref)

         if current_idx >= length(match_list) do
           {[nil], st}
         else
           result = Enum.at(match_list, current_idx)
           st = %{st | private: Map.put(st.private, idx_ref, {match_list, current_idx + 1})}
           {result, st}
         end
       end}

    {[iter_func], state}
  end

  defp string_gmatch([other | _], _state) when not is_binary(other) do
    raise_string_expected(1, "gmatch", other)
  end

  defp string_gmatch([], _state), do: raise_arg_expected(1, "gmatch")

  # string.gsub(s, pattern, repl [, n])
  defp string_gsub([s, pattern, repl | rest], state) when is_binary(s) and is_binary(pattern) do
    max_n = Enum.at(rest, 0)
    max_n = if is_number(max_n), do: trunc(max_n)

    # Determine stateful replacement: either a binary (literal pattern repl)
    # or a 2-arity fn `(args, state) -> {result, state}` so callback side
    # effects (upvalue mutation, table writes) thread back out of gsub.
    repl_fn =
      cond do
        is_binary(repl) ->
          repl

        match?({:tref, _}, repl) ->
          # Table replacement: look up match in table. Reads only — table
          # reads don't mutate state, so we pass it through unchanged.
          fn [match | _], st ->
            table = State.get_table(st, repl)
            value = Map.get(table.data, match, match)
            {value, st}
          end

        match?({:lua_closure, _, _}, repl) or match?({:compiled_closure, _, _}, repl) or match?({:native_func, _}, repl) ->
          fn args, st ->
            {results, st} = Executor.call_function(repl, args, st)
            result = List.first(results)
            value = if result == nil or result == false, do: false, else: result
            {value, st}
          end

        true ->
          raise ArgumentError,
            function_name: "string.gsub",
            arg_num: 3,
            expected: "string/function/table"
      end

    {result, count, state} = Pattern.gsub_stateful(s, pattern, repl_fn, state, max_n)
    {[result, count], state}
  end

  defp string_gsub([other | _], _state) when not is_binary(other) do
    raise_string_expected(1, "gsub", other)
  end

  defp string_gsub([], _state), do: raise_arg_expected(1, "gsub")

  defp apply_width_flags(str, flags, width) do
    width = width || 0

    # Width and padding are measured in bytes, matching PUC-Lua, which hands
    # the width straight to C's printf. The numeric specifiers (%d/%f/%x/...)
    # emit single-byte ASCII so bytes and codepoints coincide there, but `%s`
    # can carry multibyte text, so both the threshold and the fill must count
    # bytes (e.g. format("%6s", "café") -> " café", one fill byte, not two).
    deficit = width - byte_size(str)

    if deficit <= 0 do
      str
    else
      minus? = (flags &&& @flag_minus) != 0
      zero? = (flags &&& @flag_zero) != 0

      pad_char = if zero? and not minus?, do: "0", else: " "

      pad = String.duplicate(pad_char, deficit)

      if minus? do
        # Left justify
        str <> pad
      else
        # Right justify (default)
        # Handle zero-padding with sign
        if pad_char == "0" and String.starts_with?(str, "-") do
          "-" <> pad <> binary_part(str, 1, byte_size(str) - 1)
        else
          pad <> str
        end
      end
    end
  end

  # Helper: convert Lua 1-based index to 0-based, handle negative indices

  # PUC-Lua's posrelat: keep 1-based positions, translate negatives.
  # Negative indices are relative to len+1 (so -1 = len). If a negative is
  # smaller than -len, it clamps to 0 (which the caller then bumps to 1).
  defp posrelat(pos, _len) when pos >= 0, do: pos
  defp posrelat(pos, len) when -pos > len, do: 0
  defp posrelat(pos, len), do: len + pos + 1

  # Error helpers
  defp raise_string_expected(arg_num, func_name, value) do
    type = Util.typeof(value)

    raise ArgumentError,
      function_name: "string.#{func_name}",
      arg_num: arg_num,
      expected: "string",
      got: type
  end

  defp raise_arg_expected(arg_num, func_name) do
    raise ArgumentError.value_expected("string.#{func_name}", arg_num)
  end

  # string.pack(fmt, v1, v2, ...) — pack values per fmt
  defp string_pack([fmt | args], state) when is_binary(fmt) do
    {[Pack.pack(fmt, args)], state}
  end

  defp string_pack([other | _], _state), do: raise_string_expected(1, "pack", other)
  defp string_pack([], _state), do: raise_arg_expected(1, "pack")

  # string.unpack(fmt, s [, pos]) — unpack values; returns vN..., next_pos
  defp string_unpack([fmt, s | rest], state) when is_binary(fmt) and is_binary(s) do
    pos =
      case rest do
        [] -> 1
        [p | _] when is_integer(p) -> p
        [p | _] when is_float(p) -> trunc(p)
        _ -> raise ArgumentError, function_name: "string.unpack", arg_num: 3, expected: "number"
      end

    results = Pack.unpack(fmt, s, pos)
    {results, state}
  end

  defp string_unpack([fmt, other | _], _state) when is_binary(fmt) do
    raise_string_expected(2, "unpack", other)
  end

  defp string_unpack([other | _], _state), do: raise_string_expected(1, "unpack", other)
  defp string_unpack([], _state), do: raise_arg_expected(1, "unpack")

  # string.packsize(fmt) — return size in bytes for fixed-size formats
  defp string_packsize([fmt | _], state) when is_binary(fmt) do
    {[Pack.packsize(fmt)], state}
  end

  defp string_packsize([other | _], _state), do: raise_string_expected(1, "packsize", other)
  defp string_packsize([], _state), do: raise_arg_expected(1, "packsize")
end
