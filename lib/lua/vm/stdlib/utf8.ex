defmodule Lua.VM.Stdlib.Utf8 do
  @moduledoc """
  Lua 5.3 `utf8` standard library (§6.5).

  Operates over byte strings; Lua strings have no Unicode awareness of their
  own — this library treats the bytes as a UTF-8 encoded sequence and
  validates per the BMP+supplementary range `[0, 0x10FFFF]`. Overlong
  encodings (e.g. `\\xC0\\x80` for U+0000), continuation bytes appearing
  in the lead position, and codepoints above `0x10FFFF` all surface as
  `"invalid UTF-8 code"`.

  ## Functions

  - `utf8.char(...)` — codepoints to UTF-8 string
  - `utf8.codepoint(s [, i [, j]])` — UTF-8 string slice to codepoints
  - `utf8.codes(s)` — stateless `(byte_pos, codepoint)` iterator
  - `utf8.len(s [, i [, j]])` — codepoint count, or `nil, byte_pos` on
    the first invalid sequence in the slice
  - `utf8.offset(s, n [, i])` — byte position of the n-th codepoint
  - `utf8.charpattern` — Lua pattern matching one UTF-8 byte sequence
  """

  @behaviour Lua.VM.Stdlib.Library

  import Bitwise

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

  @charpattern "[\0-\x7F\xC2-\xFD][\x80-\xBF]*"
  @max_codepoint 0x10FFFF

  @impl true
  def lib_name, do: "utf8"

  @impl true
  def install(state) do
    utf8_table = %{
      "char" => {:native_func, &utf8_char/2},
      "codepoint" => {:native_func, &utf8_codepoint/2},
      "codes" => {:native_func, &utf8_codes/2},
      "len" => {:native_func, &utf8_len/2},
      "offset" => {:native_func, &utf8_offset/2},
      "charpattern" => @charpattern
    }

    {tref, state} = State.alloc_table(state, utf8_table)
    State.set_global(state, "utf8", tref)
  end

  # ---------------------------------------------------------------------------
  # utf8.char(...)
  # ---------------------------------------------------------------------------

  defp utf8_char(args, state) do
    iolist =
      args
      |> Enum.with_index(1)
      |> Enum.map(fn {cp, idx} -> encode_one(cp, idx) end)

    {[IO.iodata_to_binary(iolist)], state}
  end

  defp encode_one(cp, _idx) when is_integer(cp) and cp >= 0 and cp <= @max_codepoint do
    encode_codepoint(cp)
  end

  defp encode_one(cp, idx) when is_integer(cp) do
    raise ArgumentError,
      function_name: "utf8.char",
      arg_num: idx,
      details: "value out of range"
  end

  defp encode_one(v, idx) do
    raise ArgumentError,
      function_name: "utf8.char",
      arg_num: idx,
      expected: "number",
      got: Util.typeof(v)
  end

  defp encode_codepoint(cp) when cp < 0x80, do: <<cp>>

  defp encode_codepoint(cp) when cp < 0x800 do
    <<0xC0 ||| cp >>> 6, 0x80 ||| (cp &&& 0x3F)>>
  end

  defp encode_codepoint(cp) when cp < 0x10000 do
    <<0xE0 ||| cp >>> 12, 0x80 ||| (cp >>> 6 &&& 0x3F), 0x80 ||| (cp &&& 0x3F)>>
  end

  defp encode_codepoint(cp) do
    <<0xF0 ||| cp >>> 18, 0x80 ||| (cp >>> 12 &&& 0x3F), 0x80 ||| (cp >>> 6 &&& 0x3F), 0x80 ||| (cp &&& 0x3F)>>
  end

  # ---------------------------------------------------------------------------
  # utf8.codepoint(s [, i [, j]])
  # ---------------------------------------------------------------------------

  defp utf8_codepoint([], _state) do
    raise ArgumentError.value_expected("utf8.codepoint", 1)
  end

  defp utf8_codepoint([s | rest], state) do
    if !is_binary(s) do
      raise ArgumentError,
        function_name: "utf8.codepoint",
        arg_num: 1,
        expected: "string",
        got: Util.typeof(s)
    end

    len = byte_size(s)
    i = check_integer(Enum.at(rest, 0, 1), "utf8.codepoint", 2)
    j = check_integer(Enum.at(rest, 1, i), "utf8.codepoint", 3)

    posi = u_posrelat(i, len)
    posj = u_posrelat(j, len)

    if posi < 1 do
      raise ArgumentError,
        function_name: "utf8.codepoint",
        arg_num: 2,
        details: "out of range"
    end

    if posj > len do
      raise ArgumentError,
        function_name: "utf8.codepoint",
        arg_num: 3,
        details: "out of range"
    end

    {collect_codepoints(s, posi, posj, []), state}
  end

  defp collect_codepoints(_s, posi, posj, acc) when posi > posj do
    Enum.reverse(acc)
  end

  defp collect_codepoints(s, posi, posj, acc) do
    case decode_at(s, posi) do
      {cp, len} -> collect_codepoints(s, posi + len, posj, [cp | acc])
      :invalid -> raise RuntimeError, value: "invalid UTF-8 code"
    end
  end

  # ---------------------------------------------------------------------------
  # utf8.len(s [, i [, j]])
  # ---------------------------------------------------------------------------

  defp utf8_len([], _state) do
    raise ArgumentError.value_expected("utf8.len", 1)
  end

  defp utf8_len([s | rest], state) do
    if !is_binary(s) do
      raise ArgumentError,
        function_name: "utf8.len",
        arg_num: 1,
        expected: "string",
        got: Util.typeof(s)
    end

    len = byte_size(s)
    i = check_integer(Enum.at(rest, 0, 1), "utf8.len", 2)
    j = check_integer(Enum.at(rest, 1, -1), "utf8.len", 3)

    posi = u_posrelat(i, len)
    posj = u_posrelat(j, len)

    if posi < 1 or posi > len + 1 do
      raise ArgumentError,
        function_name: "utf8.len",
        arg_num: 2,
        details: "initial position out of string"
    end

    if posj > len do
      raise ArgumentError,
        function_name: "utf8.len",
        arg_num: 3,
        details: "final position out of string"
    end

    {do_utf8_len(s, posi, posj, 0), state}
  end

  defp do_utf8_len(_s, posi, posj, n) when posi > posj, do: [n]

  defp do_utf8_len(s, posi, posj, n) do
    case decode_at(s, posi) do
      {_cp, len} -> do_utf8_len(s, posi + len, posj, n + 1)
      :invalid -> [nil, posi]
    end
  end

  # ---------------------------------------------------------------------------
  # utf8.offset(s, n [, i])
  # ---------------------------------------------------------------------------

  defp utf8_offset([], _state) do
    raise ArgumentError.value_expected("utf8.offset", 1)
  end

  defp utf8_offset([s], _state) do
    if !is_binary(s) do
      raise ArgumentError,
        function_name: "utf8.offset",
        arg_num: 1,
        expected: "string",
        got: Util.typeof(s)
    end

    raise ArgumentError.value_expected("utf8.offset", 2)
  end

  defp utf8_offset([s | rest], state) do
    if !is_binary(s) do
      raise ArgumentError,
        function_name: "utf8.offset",
        arg_num: 1,
        expected: "string",
        got: Util.typeof(s)
    end

    n = check_integer(Enum.at(rest, 0), "utf8.offset", 2)
    len = byte_size(s)
    default_i = if n >= 0, do: 1, else: len + 1
    raw_i = Enum.at(rest, 1, default_i)
    i = check_integer(raw_i, "utf8.offset", 3)
    posi = u_posrelat(i, len)

    if posi < 1 or posi > len + 1 do
      raise ArgumentError,
        function_name: "utf8.offset",
        arg_num: 3,
        details: "position out of range"
    end

    # Operate in 0-based byte index internally (`pos`); convert back at end.
    pos = posi - 1
    result = do_offset(s, n, pos, len)
    {result, state}
  end

  defp do_offset(s, 0, pos, _len) do
    pos = scan_back_to_char_start(s, pos)
    [pos + 1]
  end

  defp do_offset(s, n, pos, len) do
    if pos < len and is_continuation_byte?(:binary.at(s, pos)) do
      raise RuntimeError, value: "initial position is a continuation byte"
    end

    # PUC decrements n by one before entering the advance loop, so
    # `utf8.offset(s, 1, i)` returns position `i` itself (no advance).
    cond do
      n > 0 -> advance_forward(s, n - 1, pos, len)
      n < 0 -> advance_backward(s, n, pos)
    end
  end

  defp advance_forward(_s, 0, pos, _len), do: [pos + 1]
  defp advance_forward(_s, _n, pos, len) when pos >= len, do: [nil]

  defp advance_forward(s, n, pos, len) do
    next_pos = skip_continuations(s, pos + 1, len)
    advance_forward(s, n - 1, next_pos, len)
  end

  defp advance_backward(_s, 0, pos), do: [pos + 1]
  defp advance_backward(_s, _n, pos) when pos <= 0, do: [nil]

  defp advance_backward(s, n, pos) do
    prev_pos = scan_back_to_char_start(s, pos - 1)
    advance_backward(s, n + 1, prev_pos)
  end

  defp scan_back_to_char_start(_s, pos) when pos <= 0, do: 0

  defp scan_back_to_char_start(s, pos) do
    if is_continuation_byte?(:binary.at(s, pos)) do
      scan_back_to_char_start(s, pos - 1)
    else
      pos
    end
  end

  defp skip_continuations(_s, pos, len) when pos >= len, do: pos

  defp skip_continuations(s, pos, len) do
    if is_continuation_byte?(:binary.at(s, pos)) do
      skip_continuations(s, pos + 1, len)
    else
      pos
    end
  end

  # ---------------------------------------------------------------------------
  # utf8.codes(s)
  # ---------------------------------------------------------------------------

  defp utf8_codes([], _state) do
    raise ArgumentError.value_expected("utf8.codes", 1)
  end

  defp utf8_codes([s | _], state) when is_binary(s) do
    iter = {:native_func, &codes_iter/2}
    {[iter, s, 0], state}
  end

  defp utf8_codes([v | _], _state) do
    raise ArgumentError,
      function_name: "utf8.codes",
      arg_num: 1,
      expected: "string",
      got: Util.typeof(v)
  end

  defp codes_iter([s, prev_pos], state) when is_binary(s) and is_integer(prev_pos) do
    len = byte_size(s)

    pos =
      cond do
        prev_pos == 0 ->
          1

        prev_pos >= len ->
          len + 1

        true ->
          # Advance past the codepoint at prev_pos. Always at least +1 byte;
          # skip any trailing continuation bytes.
          p = prev_pos + 1
          skip_continuations_1based(s, p, len)
      end

    if pos > len do
      {[nil], state}
    else
      case decode_at(s, pos) do
        {cp, _len} -> {[pos, cp], state}
        :invalid -> raise RuntimeError, value: "invalid UTF-8 code"
      end
    end
  end

  defp skip_continuations_1based(_s, pos, len) when pos > len, do: pos

  defp skip_continuations_1based(s, pos, len) do
    if is_continuation_byte?(:binary.at(s, pos - 1)) do
      skip_continuations_1based(s, pos + 1, len)
    else
      pos
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp check_integer(v, _fn, _arg) when is_integer(v), do: v

  defp check_integer(v, fn_name, arg) when is_float(v) do
    int = trunc(v)

    if int == v do
      int
    else
      raise ArgumentError,
        function_name: fn_name,
        arg_num: arg,
        details: "number has no integer representation"
    end
  end

  defp check_integer(v, fn_name, arg) do
    raise ArgumentError,
      function_name: fn_name,
      arg_num: arg,
      expected: "number",
      got: Util.typeof(v)
  end

  # Lua 5.3 PUC u_posrelat: normalise a possibly-negative position to a
  # 1-based byte index. Returns 0 when a negative position underflows the
  # start of the string.
  defp u_posrelat(pos, _len) when pos >= 0, do: pos
  defp u_posrelat(pos, len) when -pos > len, do: 0
  defp u_posrelat(pos, len), do: len + pos + 1

  defp is_continuation_byte?(byte), do: (byte &&& 0xC0) == 0x80

  # Decode the UTF-8 sequence starting at 1-based position `pos` in `s`.
  # Returns `{codepoint, byte_length}` or `:invalid` if the bytes at `pos`
  # do not start a well-formed UTF-8 sequence (rejects overlong encodings
  # and codepoints above 0x10FFFF).
  defp decode_at(s, pos) when pos >= 1 and pos <= byte_size(s) do
    slice_len = min(byte_size(s) - (pos - 1), 4)
    decode_codepoint(:binary.part(s, pos - 1, slice_len))
  end

  defp decode_at(_, _), do: :invalid

  defp decode_codepoint(<<b1, _::binary>>) when b1 < 0x80, do: {b1, 1}

  defp decode_codepoint(<<b1, b2, _::binary>>) when b1 >= 0xC2 and b1 <= 0xDF and (b2 &&& 0xC0) == 0x80 do
    {(b1 &&& 0x1F) <<< 6 ||| (b2 &&& 0x3F), 2}
  end

  defp decode_codepoint(<<b1, b2, b3, _::binary>>)
       when b1 >= 0xE0 and b1 <= 0xEF and (b2 &&& 0xC0) == 0x80 and (b3 &&& 0xC0) == 0x80 do
    cp = (b1 &&& 0x0F) <<< 12 ||| (b2 &&& 0x3F) <<< 6 ||| (b3 &&& 0x3F)
    if cp < 0x800, do: :invalid, else: {cp, 3}
  end

  defp decode_codepoint(<<b1, b2, b3, b4, _::binary>>)
       when b1 >= 0xF0 and b1 <= 0xF7 and (b2 &&& 0xC0) == 0x80 and (b3 &&& 0xC0) == 0x80 and (b4 &&& 0xC0) == 0x80 do
    cp =
      (b1 &&& 0x07) <<< 18 ||| (b2 &&& 0x3F) <<< 12 ||| (b3 &&& 0x3F) <<< 6 ||| (b4 &&& 0x3F)

    cond do
      cp < 0x10000 -> :invalid
      cp > @max_codepoint -> :invalid
      true -> {cp, 4}
    end
  end

  defp decode_codepoint(_), do: :invalid
end
