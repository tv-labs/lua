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

  ## Pattern Matching (Not Yet Implemented)

  The following functions require Lua's pattern matching engine and are deferred:
  - `string.find/4`, `string.match/3`, `string.gmatch/2`, `string.gsub/4`
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

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
      "format" => {:native_func, &string_format/2}
    }

    # Create the string table in VM state
    {tref, state} = State.alloc_table(state, string_table)

    # Register as global
    State.set_global(state, "string", tref)
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

    unless is_integer(i) do
      raise Lua.VM.RuntimeError, value: "bad argument #2 to 'string.sub' (number expected)"
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

    unless is_binary(sep) do
      raise Lua.VM.RuntimeError,
        value: "bad argument #3 to 'string.rep' (string expected, got #{Util.typeof(sep)})"
    end

    result =
      if n <= 0 do
        ""
      else
        1..n
        |> Enum.map(fn _ -> str end)
        |> Enum.join(sep)
      end

    {[result], state}
  end

  defp string_rep([str, n | _], _state) when is_binary(str) do
    raise Lua.VM.RuntimeError,
      value: "bad argument #2 to 'string.rep' (number expected, got #{Util.typeof(n)})"
  end

  defp string_rep([other, _ | _], _state) do
    raise_string_expected(1, "rep", other)
  end

  defp string_rep([_], _state) do
    raise Lua.VM.RuntimeError, value: "bad argument #2 to 'string.rep' (number expected)"
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

    unless is_integer(i) do
      raise Lua.VM.RuntimeError, value: "bad argument #2 to 'string.byte' (number expected)"
    end

    unless is_integer(j) do
      raise Lua.VM.RuntimeError, value: "bad argument #3 to 'string.byte' (number expected)"
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

        start_byte..end_byte
        |> Enum.map(fn idx -> :binary.at(str, idx) end)
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
      Enum.reduce_while(args, "", fn arg, acc ->
        cond do
          not is_integer(arg) ->
            {:halt, {:error, "number expected"}}

          arg < 0 or arg > 255 ->
            {:halt, {:error, "value out of range"}}

          true ->
            {:cont, acc <> <<arg>>}
        end
      end)

    case result do
      {:error, msg} ->
        raise Lua.VM.RuntimeError, value: "bad argument to 'string.char' (#{msg})"

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

  # Format string parser
  defp format_string("", _args, acc), do: acc

  defp format_string("%" <> rest, args, acc) do
    case rest do
      "%" <> rest ->
        format_string(rest, args, acc <> "%")

      "s" <> rest ->
        [arg | remaining_args] = args
        str = Util.to_lua_string(arg)
        format_string(rest, remaining_args, acc <> str)

      "d" <> rest ->
        [arg | remaining_args] = args
        str = format_integer(arg)
        format_string(rest, remaining_args, acc <> str)

      "i" <> rest ->
        [arg | remaining_args] = args
        str = format_integer(arg)
        format_string(rest, remaining_args, acc <> str)

      "f" <> rest ->
        [arg | remaining_args] = args
        str = format_float(arg)
        format_string(rest, remaining_args, acc <> str)

      "x" <> rest ->
        [arg | remaining_args] = args
        str = format_hex(arg, :lower)
        format_string(rest, remaining_args, acc <> str)

      "X" <> rest ->
        [arg | remaining_args] = args
        str = format_hex(arg, :upper)
        format_string(rest, remaining_args, acc <> str)

      "o" <> rest ->
        [arg | remaining_args] = args
        str = format_octal(arg)
        format_string(rest, remaining_args, acc <> str)

      "c" <> rest ->
        [arg | remaining_args] = args
        str = format_char(arg)
        format_string(rest, remaining_args, acc <> str)

      "q" <> rest ->
        [arg | remaining_args] = args
        str = format_quoted(arg)
        format_string(rest, remaining_args, acc <> str)

      _ ->
        raise Lua.VM.RuntimeError,
          value: "invalid option '%#{String.first(rest)}' to 'string.format'"
    end
  end

  defp format_string(<<char::utf8, rest::binary>>, args, acc) do
    format_string(rest, args, acc <> <<char::utf8>>)
  end

  # Format helpers
  defp format_integer(val) when is_integer(val), do: Integer.to_string(val)
  defp format_integer(val) when is_float(val), do: Integer.to_string(trunc(val))

  defp format_integer(_) do
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (number expected)"
  end

  defp format_float(val) when is_number(val) do
    :io_lib.format("~.6f", [val / 1]) |> IO.iodata_to_binary()
  end

  defp format_float(_) do
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (number expected)"
  end

  defp format_hex(val, case_style) when is_integer(val) do
    str = Integer.to_string(val, 16)
    if case_style == :lower, do: String.downcase(str), else: String.upcase(str)
  end

  defp format_hex(val, case_style) when is_float(val) do
    format_hex(trunc(val), case_style)
  end

  defp format_hex(_, _) do
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (number expected)"
  end

  defp format_octal(val) when is_integer(val), do: Integer.to_string(val, 8)
  defp format_octal(val) when is_float(val), do: Integer.to_string(trunc(val), 8)

  defp format_octal(_) do
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (number expected)"
  end

  defp format_char(val) when is_integer(val) and val >= 0 and val <= 255, do: <<val>>

  defp format_char(_) do
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (invalid value for %%c)"
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
    raise Lua.VM.RuntimeError, value: "bad argument to 'string.format' (string expected for %q)"
  end

  # Helper: convert Lua 1-based index to 0-based, handle negative indices
  defp normalize_index(idx, _len) when idx > 0, do: idx - 1
  defp normalize_index(idx, len) when idx < 0, do: len + idx
  defp normalize_index(0, _len), do: 0

  # Error helpers
  defp raise_string_expected(arg_num, func_name, value) do
    type = Util.typeof(value)

    raise Lua.VM.RuntimeError,
      value: "bad argument ##{arg_num} to 'string.#{func_name}' (string expected, got #{type})"
  end

  defp raise_arg_expected(arg_num, func_name) do
    raise Lua.VM.RuntimeError,
      value: "bad argument ##{arg_num} to 'string.#{func_name}' (value expected)"
  end
end
