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

  alias Lua.VM.ArgumentError
  alias Lua.VM.Executor
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Pattern
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

    # Convert Lua 1-based indices to 0-based, handle negative indices
    len = byte_size(str)
    start_idx = normalize_index(i, len)
    end_idx = if j == nil, do: len - 1, else: normalize_index(j, len)

    result =
      if start_idx > end_idx or start_idx >= len do
        ""
      else
        start_byte = max(0, start_idx)
        end_byte = min(len - 1, end_idx)
        length = end_byte - start_byte + 1
        binary_part(str, start_byte, length)
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
        Enum.map_join(1..n, sep, fn _ -> str end)
      end

    {[result], state}
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

  # string.reverse(s) - reverses a string
  defp string_reverse([str | _], state) when is_binary(str) do
    {[String.reverse(str)], state}
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

    len = byte_size(str)
    start_idx = normalize_index(i, len)
    end_idx = normalize_index(j, len)

    bytes =
      if start_idx > end_idx or start_idx >= len do
        []
      else
        start_byte = max(0, start_idx)
        end_byte = min(len - 1, end_idx)

        Enum.map(start_byte..end_byte, fn idx -> :binary.at(str, idx) end)
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
    result = format_string(fmt, args, "")
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
  defp format_string("", _args, acc), do: acc

  defp format_string("%" <> rest, args, acc) do
    case rest do
      "%" <> rest2 ->
        format_string(rest2, args, acc <> "%")

      _ ->
        {spec, rest2} = parse_format_spec(rest)
        [arg | remaining_args] = args
        str = apply_format_spec(spec, arg)
        format_string(rest2, remaining_args, acc <> str)
    end
  end

  defp format_string(<<char::utf8, rest::binary>>, args, acc) do
    format_string(rest, args, acc <> <<char::utf8>>)
  end

  # Parse a format spec: [flags][width][.precision]specifier
  defp parse_format_spec(str) do
    {flags, str} = parse_flags(str, "")
    {width, str} = parse_width(str)
    {precision, str} = parse_precision(str)
    {specifier, str} = parse_specifier(str)
    {{flags, width, precision, specifier}, str}
  end

  defp parse_flags(<<c, rest::binary>>, acc) when c in ~c(-+ 0#) do
    parse_flags(rest, acc <> <<c>>)
  end

  defp parse_flags(str, acc), do: {acc, str}

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

  defp parse_specifier(<<c, rest::binary>>), do: {<<c>>, rest}

  defp parse_specifier("") do
    raise ArgumentError,
      function_name: "string.format",
      details: "invalid format string"
  end

  # Apply a format spec to a value
  defp apply_format_spec({flags, width, precision, specifier}, arg) do
    raw =
      case specifier do
        "d" -> format_spec_integer(arg)
        "i" -> format_spec_integer(arg)
        "u" -> format_spec_unsigned(arg)
        "f" -> format_spec_float(arg, precision || 6)
        "e" -> format_spec_scientific(arg, precision || 6, :lower)
        "E" -> format_spec_scientific(arg, precision || 6, :upper)
        "g" -> format_spec_general(arg, precision || 6, :lower)
        "G" -> format_spec_general(arg, precision || 6, :upper)
        "x" -> format_spec_hex(arg, :lower)
        "X" -> format_spec_hex(arg, :upper)
        "o" -> format_spec_octal(arg)
        "c" -> format_char(arg)
        "s" -> format_spec_string(arg, precision)
        "q" -> format_quoted(arg)
        _ -> raise ArgumentError, function_name: "string.format", details: "invalid option '%#{specifier}'"
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

  defp format_spec_float(val, precision) when is_number(val) do
    float_val = val / 1

    float_val
    |> :erlang.float_to_binary([{:decimals, precision}, :compact])
    |> expand_float(precision)
  end

  defp format_spec_float(_, _) do
    raise ArgumentError, function_name: "string.format", expected: "number"
  end

  # Ensure the float string has exactly `precision` decimal places
  defp expand_float(str, precision) do
    if precision == 0 do
      # Remove the decimal point entirely for precision 0
      case String.split(str, ".") do
        [int_part, frac] ->
          # Round: check first decimal digit
          first_frac = String.first(frac)

          if first_frac != nil and String.to_integer(first_frac) >= 5 do
            # Need to round up
            {int_val, _} = Integer.parse(int_part)

            if int_val >= 0 do
              Integer.to_string(int_val + 1)
            else
              Integer.to_string(int_val - 1)
            end
          else
            int_part
          end

        _ ->
          str
      end
    else
      case String.split(str, ".") do
        [int_part, frac] ->
          padded_frac = String.pad_trailing(frac, precision, "0")
          "#{int_part}.#{padded_frac}"

        [int_part] ->
          "#{int_part}.#{String.duplicate("0", precision)}"
      end
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
      mantissa = "0." <> String.duplicate("0", precision)
      "#{mantissa}e+00"
    else
      exp = float_val |> abs() |> :math.log10() |> floor()
      mantissa = float_val / :math.pow(10, exp)

      # Format mantissa with the required precision
      mantissa_str =
        :erlang.float_to_binary(mantissa, [{:decimals, precision + 1}, :compact])

      # Round to the requested precision
      mantissa_str = round_mantissa(mantissa_str, precision)

      # Check if rounding pushed mantissa to 10.0 (e.g., 9.999... -> 10.0)
      {mantissa_str, exp} = normalize_mantissa(mantissa_str, exp)

      exp_sign = if exp >= 0, do: "+", else: "-"
      exp_str = exp |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
      "#{mantissa_str}e#{exp_sign}#{exp_str}"
    end
  end

  defp round_mantissa(str, precision) do
    if precision == 0 do
      case String.split(str, ".") do
        [int_part, frac] ->
          first = String.first(frac)

          if first != nil and String.to_integer(first) >= 5 do
            {n, _} = Integer.parse(int_part)
            # Preserve sign for rounding
            if n >= 0, do: Integer.to_string(n + 1), else: Integer.to_string(n - 1)
          else
            int_part
          end

        _ ->
          str
      end
    else
      expand_float(str, precision)
    end
  end

  defp normalize_mantissa(mantissa_str, exp) do
    # Parse the mantissa value to check if |mantissa| >= 10 after rounding
    {mantissa_val, _} = Float.parse(mantissa_str)

    if abs(mantissa_val) >= 10.0 do
      new_mantissa = mantissa_val / 10.0
      # Re-format the new mantissa - extract precision from the string
      precision =
        case String.split(mantissa_str, ".") do
          [_, frac] -> String.length(frac)
          _ -> 0
        end

      new_str =
        expand_float(
          :erlang.float_to_binary(new_mantissa, [{:decimals, precision + 1}, :compact]),
          precision
        )

      {new_str, exp + 1}
    else
      {mantissa_str, exp}
    end
  end

  defp format_spec_general(val, precision, case_style) when is_number(val) do
    float_val = val / 1
    precision = max(1, precision)

    if float_val == 0.0 do
      "0"
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

    if plain == true do
      # Plain substring search
      search_pos = max(init - 1, 0)

      case :binary.match(s, pattern, scope: {search_pos, byte_size(s) - search_pos}) do
        {start, len} ->
          {[start + 1, start + len], state}

        :nomatch ->
          {[nil], state}
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

    # Determine replacement function
    repl_fn =
      cond do
        is_binary(repl) ->
          repl

        is_function(repl, 1) ->
          repl

        match?({:tref, _}, repl) ->
          # Table replacement: look up match in table
          fn [match | _] ->
            table = State.get_table(state, repl)
            Map.get(table.data, match, match)
          end

        match?({:lua_closure, _, _}, repl) ->
          fn args ->
            {results, _state} = Executor.call_function(repl, args, state)
            result = List.first(results)
            if result == nil or result == false, do: false, else: result
          end

        match?({:native_func, _}, repl) ->
          fn args ->
            {results, _state} = Executor.call_function(repl, args, state)
            result = List.first(results)
            if result == nil or result == false, do: false, else: result
          end

        true ->
          raise ArgumentError,
            function_name: "string.gsub",
            arg_num: 3,
            expected: "string/function/table"
      end

    {result, count} = Pattern.gsub(s, pattern, repl_fn, max_n)
    {[result, count], state}
  end

  defp string_gsub([other | _], _state) when not is_binary(other) do
    raise_string_expected(1, "gsub", other)
  end

  defp string_gsub([], _state), do: raise_arg_expected(1, "gsub")

  defp apply_width_flags(str, flags, width) do
    width = width || 0

    if String.length(str) >= width do
      str
    else
      pad_char =
        if String.contains?(flags, "0") and not String.contains?(flags, "-"), do: "0", else: " "

      if String.contains?(flags, "-") do
        # Left justify
        String.pad_trailing(str, width, pad_char)
      else
        # Right justify (default)
        # Handle zero-padding with sign
        if pad_char == "0" and String.starts_with?(str, "-") do
          "-" <> String.pad_leading(String.slice(str, 1..-1//1), width - 1, "0")
        else
          String.pad_leading(str, width, pad_char)
        end
      end
    end
  end

  # Helper: convert Lua 1-based index to 0-based, handle negative indices
  defp normalize_index(idx, _len) when idx > 0, do: idx - 1
  defp normalize_index(idx, len) when idx < 0, do: len + idx
  defp normalize_index(0, _len), do: 0

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

  # string.packsize(fmt) — returns size in bytes for the given format string
  # Supports basic format codes used in Lua 5.3
  defp string_packsize([fmt | _], state) when is_binary(fmt) do
    size = compute_pack_size(fmt, 0)
    {[size], state}
  end

  defp compute_pack_size("", acc), do: acc
  defp compute_pack_size(<<"b", rest::binary>>, acc), do: compute_pack_size(rest, acc + 1)
  defp compute_pack_size(<<"B", rest::binary>>, acc), do: compute_pack_size(rest, acc + 1)
  defp compute_pack_size(<<"h", rest::binary>>, acc), do: compute_pack_size(rest, acc + 2)
  defp compute_pack_size(<<"H", rest::binary>>, acc), do: compute_pack_size(rest, acc + 2)
  defp compute_pack_size(<<"i", rest::binary>>, acc), do: compute_pack_size(rest, acc + 4)
  defp compute_pack_size(<<"I", rest::binary>>, acc), do: compute_pack_size(rest, acc + 4)
  defp compute_pack_size(<<"l", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"L", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"j", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"J", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"n", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"N", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"f", rest::binary>>, acc), do: compute_pack_size(rest, acc + 4)
  defp compute_pack_size(<<"d", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<"T", rest::binary>>, acc), do: compute_pack_size(rest, acc + 8)
  defp compute_pack_size(<<" ", rest::binary>>, acc), do: compute_pack_size(rest, acc)
  defp compute_pack_size(<<"<", rest::binary>>, acc), do: compute_pack_size(rest, acc)
  defp compute_pack_size(<<">", rest::binary>>, acc), do: compute_pack_size(rest, acc)
  defp compute_pack_size(<<"=", rest::binary>>, acc), do: compute_pack_size(rest, acc)

  # string.pack — stub
  defp string_pack(_args, _state) do
    raise Lua.RuntimeException, "string.pack not yet implemented"
  end

  # string.unpack — stub
  defp string_unpack(_args, _state) do
    raise Lua.RuntimeException, "string.unpack not yet implemented"
  end
end
