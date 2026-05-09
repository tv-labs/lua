defmodule Lua.VM.Stdlib.String.Pack do
  @moduledoc """
  Implementation of `string.pack/2`, `string.unpack/2,3`, and
  `string.packsize/1` per Lua 5.3 §6.4.2.

  The format-string mini-language is parsed once into a list of
  operations, which are then driven by the appropriate evaluator
  (`pack`, `unpack`, or `packsize`). All arithmetic on the platform's
  size_t / lua_Integer / lua_Number widths uses 8 bytes (we run on the
  64-bit BEAM); native endianness is treated as little-endian to match
  the dominant host architecture and PUC-Lua's `tpack.lua` assumptions.

  Errors are raised as `Lua.VM.RuntimeError` so that `pcall`'s
  `string.find(err, msg)` checks in `tpack.lua` work as written.
  """

  import Bitwise, only: [<<<: 2, &&&: 2]

  alias Lua.VM.RuntimeError

  # Platform constants. We run on the 64-bit BEAM, so these match the
  # standard 64-bit C ABI that Lua 5.3 was specced against.
  @sizeof_short 2
  @sizeof_int 4
  @sizeof_long 8
  @sizeof_size_t 8
  @sizeof_lua_integer 8
  @sizeof_lua_number 8
  @sizeof_float 4
  @sizeof_double 8

  # Maximum size for any single integer op (`i<n>`, `I<n>`, `s<n>`, `!n`).
  @max_int_size 16

  # Default alignment for bare `!` is platform max alignment, which on
  # 64-bit systems is 8.
  @default_max_align 8

  # Hard cap on total format size that packsize will admit; matches
  # PUC-Lua's `MAXSIZE` (INT_MAX, 2^31 - 1).
  @max_total_size 0x7FFFFFFF

  # ---- public entry points ------------------------------------------------

  @doc "Implements string.pack(fmt, ...)."
  def pack(fmt, args) when is_binary(fmt) do
    ops = parse(fmt)
    do_pack(ops, args, <<>>)
  end

  @doc "Implements string.unpack(fmt, s [, pos])."
  def unpack(fmt, s, pos) when is_binary(fmt) and is_binary(s) and is_integer(pos) do
    init_pos = normalize_init_pos(pos, byte_size(s))
    ops = parse(fmt)
    do_unpack(ops, s, init_pos, [])
  end

  @doc "Implements string.packsize(fmt)."
  def packsize(fmt) when is_binary(fmt) do
    ops = parse(fmt)
    do_packsize(ops, 0)
  end

  # ---- format-string parser ----------------------------------------------

  # Parses fmt into a flat list of {opcode, ...} tuples. Alignment is
  # NOT folded in at parse time — variable-length ops (`s`, `z`) advance
  # the running byte position by an amount only known at pack/unpack
  # time, so the parser emits explicit `{:align, n}` ops and the
  # evaluators decide on the fly how much padding to insert.
  defp parse(fmt) do
    state = %{endian: :little, max_align: 1, ops: []}
    state = parse_loop(fmt, state)
    Enum.reverse(state.ops)
  end

  defp parse_loop(<<>>, state), do: state

  defp parse_loop(<<c, rest::binary>>, state) when c in [?\s, ?\t, ?\n, ?\r] do
    parse_loop(rest, state)
  end

  defp parse_loop(<<"<", rest::binary>>, state) do
    parse_loop(rest, %{state | endian: :little})
  end

  defp parse_loop(<<">", rest::binary>>, state) do
    parse_loop(rest, %{state | endian: :big})
  end

  defp parse_loop(<<"=", rest::binary>>, state) do
    # Native endianness — we treat the BEAM host as little-endian.
    parse_loop(rest, %{state | endian: :little})
  end

  defp parse_loop(<<"!", rest::binary>>, state) do
    {n, rest} = read_optional_int(rest, @default_max_align)

    if n < 1 or n > @max_int_size do
      raise_runtime("integral size (#{n}) out of limits [1,#{@max_int_size}]")
    end

    if not power_of_two?(n) do
      raise_runtime("format asks for alignment not power of 2")
    end

    parse_loop(rest, %{state | max_align: n})
  end

  defp parse_loop(<<"b", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, true, 1))
  end

  defp parse_loop(<<"B", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, false, 1))
  end

  defp parse_loop(<<"h", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, true, @sizeof_short))
  end

  defp parse_loop(<<"H", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, false, @sizeof_short))
  end

  defp parse_loop(<<"i", rest::binary>>, state) do
    {n, rest} = read_optional_int(rest, @sizeof_int)
    parse_loop(rest, emit_int(state, true, n))
  end

  defp parse_loop(<<"I", rest::binary>>, state) do
    {n, rest} = read_optional_int(rest, @sizeof_int)
    parse_loop(rest, emit_int(state, false, n))
  end

  defp parse_loop(<<"l", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, true, @sizeof_long))
  end

  defp parse_loop(<<"L", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, false, @sizeof_long))
  end

  defp parse_loop(<<"j", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, true, @sizeof_lua_integer))
  end

  defp parse_loop(<<"J", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, false, @sizeof_lua_integer))
  end

  defp parse_loop(<<"T", rest::binary>>, state) do
    parse_loop(rest, emit_int(state, false, @sizeof_size_t))
  end

  defp parse_loop(<<"f", rest::binary>>, state) do
    parse_loop(rest, emit_float(state, @sizeof_float))
  end

  defp parse_loop(<<"d", rest::binary>>, state) do
    parse_loop(rest, emit_float(state, @sizeof_double))
  end

  defp parse_loop(<<"n", rest::binary>>, state) do
    parse_loop(rest, emit_float(state, @sizeof_lua_number))
  end

  defp parse_loop(<<"x", rest::binary>>, state) do
    state = push_op(state, {:padding, 1})
    parse_loop(rest, state)
  end

  defp parse_loop(<<"X", rest::binary>>, state) do
    {natural_align, rest_after_op} = consume_x_target(rest)
    align = effective_alignment(natural_align, state.max_align)
    validate_alignment!(align)
    state = if align == 1, do: state, else: push_op(state, {:align, align})
    parse_loop(rest_after_op, state)
  end

  defp parse_loop(<<"c", rest::binary>>, state) do
    case read_size(rest) do
      :error ->
        raise_runtime("missing size for format option 'c'")

      {n, rest} ->
        # `c<n>` does NOT trigger alignment — PUC-Lua treats it as a
        # raw blob (see `Kchar` in `getdetails`).
        state = push_op(state, {:fixed_string, n})
        parse_loop(rest, state)
    end
  end

  defp parse_loop(<<"s", rest::binary>>, state) do
    {n, rest} = read_optional_int(rest, @sizeof_size_t)

    if n < 1 or n > @max_int_size do
      raise_runtime("integral size (#{n}) out of limits [1,#{@max_int_size}]")
    end

    align = effective_alignment(n, state.max_align)
    validate_alignment!(align)
    state = if align == 1, do: state, else: push_op(state, {:align, align})
    state = push_op(state, {:lstring, n, state.endian})
    parse_loop(rest, state)
  end

  defp parse_loop(<<"z", rest::binary>>, state) do
    state = push_op(state, {:zstring})
    parse_loop(rest, state)
  end

  defp parse_loop(<<c, _rest::binary>>, _state) do
    raise_runtime("invalid format option '#{<<c>>}'")
  end

  # `read_size/1` — read a mandatory non-negative integer. Returns `:error`
  # if the next char isn't a digit (so the caller can complain about the
  # missing size, e.g. for bare `c`).
  defp read_size(<<d, rest::binary>>) when d in ?0..?9 do
    {n, rest} = read_int(rest, d - ?0)
    {n, rest}
  end

  defp read_size(_), do: :error

  # `read_optional_int/2` — read an integer if the next char is a digit,
  # else return `default`. Used by `i<n>`, `I<n>`, `!<n>`, `s<n>`.
  defp read_optional_int(<<d, rest::binary>>, _default) when d in ?0..?9 do
    {n, rest} = read_int(rest, d - ?0)
    {n, rest}
  end

  defp read_optional_int(rest, default), do: {default, rest}

  defp read_int(<<d, rest::binary>>, acc) when d in ?0..?9 do
    new = acc * 10 + (d - ?0)

    if new > @max_total_size do
      raise_runtime("invalid format")
    end

    read_int(rest, new)
  end

  defp read_int(rest, acc), do: {acc, rest}

  # ---- emitters ----------------------------------------------------------

  defp emit_int(_state, _signed?, size) when size < 1 or size > @max_int_size do
    raise_runtime("integral size (#{size}) out of limits [1,#{@max_int_size}]")
  end

  defp emit_int(state, signed?, size) do
    align = effective_alignment(size, state.max_align)
    validate_alignment!(align)
    state = if align == 1, do: state, else: push_op(state, {:align, align})
    push_op(state, {:int, signed?, size, state.endian})
  end

  defp emit_float(state, size) do
    align = effective_alignment(size, state.max_align)
    validate_alignment!(align)
    state = if align == 1, do: state, else: push_op(state, {:align, align})
    push_op(state, {:float, size, state.endian})
  end

  # Validate the effective alignment is a positive power of two; mirrors
  # PUC-Lua's `isalign2` check.
  defp validate_alignment!(1), do: :ok

  defp validate_alignment!(n) when n > 1 do
    if not power_of_two?(n) do
      raise_runtime("format asks for alignment not power of 2")
    end

    :ok
  end

  defp validate_alignment!(_) do
    raise_runtime("format asks for alignment not power of 2")
  end

  defp push_op(state, op), do: %{state | ops: [op | state.ops]}

  defp effective_alignment(natural, max_align), do: min(natural, max_align)

  # `consume_x_target/1` — `X<op>` is an empty directive: it consumes the
  # `op` character (and its size suffix, if any) purely to discover its
  # natural alignment, then inserts padding to align the position. The op
  # itself is NOT emitted as a data op. Returns `{alignment, rest}` where
  # `rest` is the format stream past the op. PUC-Lua restricts the target
  # to ops with intrinsic natural alignment > 1; everything else
  # (whitespace, directives, `c`, `s`, `z`, `x`, another `X`, end-of-fmt)
  # is rejected with "invalid next option".
  defp consume_x_target(<<"b", rest::binary>>), do: {1, rest}
  defp consume_x_target(<<"B", rest::binary>>), do: {1, rest}
  defp consume_x_target(<<"h", rest::binary>>), do: {@sizeof_short, rest}
  defp consume_x_target(<<"H", rest::binary>>), do: {@sizeof_short, rest}
  defp consume_x_target(<<"l", rest::binary>>), do: {@sizeof_long, rest}
  defp consume_x_target(<<"L", rest::binary>>), do: {@sizeof_long, rest}
  defp consume_x_target(<<"j", rest::binary>>), do: {@sizeof_lua_integer, rest}
  defp consume_x_target(<<"J", rest::binary>>), do: {@sizeof_lua_integer, rest}
  defp consume_x_target(<<"T", rest::binary>>), do: {@sizeof_size_t, rest}
  defp consume_x_target(<<"f", rest::binary>>), do: {@sizeof_float, rest}
  defp consume_x_target(<<"d", rest::binary>>), do: {@sizeof_double, rest}
  defp consume_x_target(<<"n", rest::binary>>), do: {@sizeof_lua_number, rest}

  defp consume_x_target(<<"i", rest::binary>>) do
    {n, rest} = read_optional_int(rest, @sizeof_int)
    check_x_size(n)
    {n, rest}
  end

  defp consume_x_target(<<"I", rest::binary>>) do
    {n, rest} = read_optional_int(rest, @sizeof_int)
    check_x_size(n)
    {n, rest}
  end

  defp consume_x_target(_), do: raise_runtime("invalid next option for option 'X'")

  defp check_x_size(n) when n < 1 or n > @max_int_size do
    raise_runtime("integral size (#{n}) out of limits [1,#{@max_int_size}]")
  end

  defp check_x_size(_), do: :ok

  # ---- pack driver -------------------------------------------------------

  defp do_pack(ops, args, acc) do
    do_pack_loop(ops, args, acc, 0)
  end

  defp do_pack_loop([], _args, acc, _pos), do: acc

  defp do_pack_loop([{:align, alignment} | ops], args, acc, pos) do
    fill = rem(alignment - rem(pos, alignment), alignment)
    pad = :binary.copy(<<0>>, fill)
    do_pack_loop(ops, args, acc <> pad, pos + fill)
  end

  defp do_pack_loop([{:padding, n} | ops], args, acc, pos) do
    do_pack_loop(ops, args, acc <> :binary.copy(<<0>>, n), pos + n)
  end

  defp do_pack_loop([{:int, signed?, size, endian} | ops], [val | rest], acc, pos) do
    n = to_integer(val, "string.pack")
    bytes = encode_int(n, size, signed?, endian)
    do_pack_loop(ops, rest, acc <> bytes, pos + size)
  end

  defp do_pack_loop([{:float, size, endian} | ops], [val | rest], acc, pos) do
    f = to_float(val, "string.pack")
    bytes = encode_float(f, size, endian)
    do_pack_loop(ops, rest, acc <> bytes, pos + size)
  end

  defp do_pack_loop([{:fixed_string, n} | ops], [val | rest], acc, pos) do
    s = to_string_arg(val, "string.pack")

    if byte_size(s) > n do
      raise_runtime("string longer than given size")
    end

    padded = s <> :binary.copy(<<0>>, n - byte_size(s))
    do_pack_loop(ops, rest, acc <> padded, pos + n)
  end

  defp do_pack_loop([{:lstring, prefix_size, endian} | ops], [val | rest], acc, pos) do
    s = to_string_arg(val, "string.pack")
    len = byte_size(s)

    # Length prefix must fit in `prefix_size` bytes, unsigned.
    max_len = (1 <<< (prefix_size * 8)) - 1

    if len > max_len do
      raise_runtime("string length does not fit in given size")
    end

    prefix = encode_int(len, prefix_size, false, endian)
    do_pack_loop(ops, rest, acc <> prefix <> s, pos + prefix_size + len)
  end

  defp do_pack_loop([{:zstring} | ops], [val | rest], acc, pos) do
    s = to_string_arg(val, "string.pack")

    if String.contains?(s, <<0>>) do
      raise_runtime("string contains zeros")
    end

    do_pack_loop(ops, rest, acc <> s <> <<0>>, pos + byte_size(s) + 1)
  end

  defp do_pack_loop([_op | _], [], _acc, _pos) do
    raise_runtime("bad argument to 'pack' (no value)")
  end

  # ---- unpack driver -----------------------------------------------------

  defp do_unpack([], _s, pos, results) do
    # Lua returns the values in pack order, then the next-read position.
    # We've prepended results, so reverse first, then append pos.
    Enum.reverse(results, [pos + 1])
  end

  defp do_unpack([{:align, alignment} | ops], s, pos, results) do
    fill = rem(alignment - rem(pos, alignment), alignment)
    ensure_available(s, pos, fill, "data string too short")
    do_unpack(ops, s, pos + fill, results)
  end

  defp do_unpack([{:padding, n} | ops], s, pos, results) do
    ensure_available(s, pos, n, "data string too short")
    do_unpack(ops, s, pos + n, results)
  end

  defp do_unpack([{:int, signed?, size, endian} | ops], s, pos, results) do
    ensure_available(s, pos, size, "data string too short")
    bytes = binary_part(s, pos, size)
    val = decode_int_with_overflow_check(bytes, signed?, endian, size)
    val = wrap_to_lua_integer(val)
    do_unpack(ops, s, pos + size, [val | results])
  end

  defp do_unpack([{:float, size, endian} | ops], s, pos, results) do
    ensure_available(s, pos, size, "data string too short")
    bytes = binary_part(s, pos, size)
    val = decode_float(bytes, size, endian)
    do_unpack(ops, s, pos + size, [val | results])
  end

  defp do_unpack([{:fixed_string, n} | ops], s, pos, results) do
    ensure_available(s, pos, n, "data string too short")
    str = binary_part(s, pos, n)
    do_unpack(ops, s, pos + n, [str | results])
  end

  defp do_unpack([{:lstring, prefix_size, endian} | ops], s, pos, results) do
    ensure_available(s, pos, prefix_size, "data string too short")
    prefix = binary_part(s, pos, prefix_size)
    len = decode_int(prefix, false, endian)
    body_start = pos + prefix_size
    ensure_available(s, body_start, len, "data string too short")
    str = binary_part(s, body_start, len)
    do_unpack(ops, s, body_start + len, [str | results])
  end

  defp do_unpack([{:zstring} | ops], s, pos, results) do
    case :binary.match(s, <<0>>, scope: {pos, byte_size(s) - pos}) do
      {nul_pos, 1} ->
        str = binary_part(s, pos, nul_pos - pos)
        do_unpack(ops, s, nul_pos + 1, [str | results])

      :nomatch ->
        raise_runtime("unfinished string for format 'z'")
    end
  end

  defp ensure_available(s, pos, size, msg) do
    if pos + size > byte_size(s) do
      raise_runtime(msg)
    end
  end

  # ---- packsize driver ---------------------------------------------------

  defp do_packsize([], acc), do: acc

  defp do_packsize([{:align, alignment} | ops], acc) do
    fill = rem(alignment - rem(acc, alignment), alignment)
    new_acc = acc + fill

    if new_acc > @max_total_size do
      raise_runtime("format result too large")
    end

    do_packsize(ops, new_acc)
  end

  defp do_packsize([{:padding, n} | ops], acc), do: bump(ops, acc, n)
  defp do_packsize([{:int, _, size, _} | ops], acc), do: bump(ops, acc, size)
  defp do_packsize([{:float, size, _} | ops], acc), do: bump(ops, acc, size)
  defp do_packsize([{:fixed_string, n} | ops], acc), do: bump(ops, acc, n)

  defp do_packsize([{:lstring, _, _} | _], _acc) do
    raise_runtime("variable-length format in packsize")
  end

  defp do_packsize([{:zstring} | _], _acc) do
    raise_runtime("variable-length format in packsize")
  end

  defp bump(ops, acc, n) do
    new_acc = acc + n

    if new_acc > @max_total_size do
      raise_runtime("format result too large")
    end

    do_packsize(ops, new_acc)
  end

  # ---- integer encoding/decoding -----------------------------------------

  defp encode_int(n, size, signed?, endian) do
    {min_v, max_v} = int_range(size, signed?)

    if n < min_v or n > max_v do
      raise_runtime("integer overflow")
    end

    # Convert to unsigned representation in `size` bytes.
    unsigned = if n < 0, do: n + (1 <<< (size * 8)), else: n
    bits = size * 8

    case endian do
      :little -> <<unsigned::little-unsigned-integer-size(bits)>>
      :big -> <<unsigned::big-unsigned-integer-size(bits)>>
    end
  end

  defp decode_int(bytes, signed?, endian) do
    bits = byte_size(bytes) * 8

    unsigned =
      case endian do
        :little -> :binary.decode_unsigned(bytes, :little)
        :big -> :binary.decode_unsigned(bytes, :big)
      end

    if signed? and unsigned >= 1 <<< (bits - 1) do
      unsigned - (1 <<< bits)
    else
      unsigned
    end
  end

  # PUC-Lua's `unpackint`: when the source size exceeds lua_Integer width,
  # always read the low `SZINT` bytes as a *signed* lua_Integer (mirroring
  # the C `(lua_Integer)res` cast), then validate the high bytes match the
  # sign-extension byte (0x00 for unsigned or non-negative signed; 0xFF
  # only for negative signed). Mismatches raise the
  # "<size>-byte integer does not fit into Lua Integer" error.
  defp decode_int_with_overflow_check(bytes, signed?, endian, size) when size <= @sizeof_lua_integer do
    decode_int(bytes, signed?, endian)
  end

  defp decode_int_with_overflow_check(bytes, signed?, endian, size) do
    {value_bytes, extra_bytes} = split_value_extra(bytes, endian, @sizeof_lua_integer)
    val = decode_int(value_bytes, true, endian)
    expected = if signed? and val < 0, do: 0xFF, else: 0x00

    if Enum.any?(:binary.bin_to_list(extra_bytes), fn b -> b != expected end) do
      raise_runtime("#{size}-byte integer does not fit into Lua Integer")
    end

    val
  end

  # Split `bytes` into the low-order `keep` bytes and the high-order
  # remainder. Layout depends on endianness: little-endian keeps the
  # leading bytes, big-endian keeps the trailing bytes.
  defp split_value_extra(bytes, :little, keep) do
    <<value::binary-size(keep), extra::binary>> = bytes
    {value, extra}
  end

  defp split_value_extra(bytes, :big, keep) do
    skip = byte_size(bytes) - keep
    <<extra::binary-size(skip), value::binary>> = bytes
    {value, extra}
  end

  defp int_range(size, true) do
    half = 1 <<< (size * 8 - 1)
    {-half, half - 1}
  end

  defp int_range(size, false), do: {0, (1 <<< (size * 8)) - 1}

  # PUC-Lua's `(lua_Integer)res` reinterprets the bit pattern: an 8-byte
  # unsigned value above 2^63-1 wraps to its signed-64-bit equivalent.
  # `unpack("<J", "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF") == -1` exercises
  # this. Smaller sizes never hit the threshold (their max is 2^56-1).
  defp wrap_to_lua_integer(val) when val > (1 <<< 63) - 1 and val < 1 <<< 64 do
    val - (1 <<< 64)
  end

  defp wrap_to_lua_integer(val), do: val

  # ---- float encoding/decoding -------------------------------------------
  #
  # BEAM floats can't represent IEEE ±Infinity or NaN. The Lua VM's
  # `safe_divide/4` uses `±1.0e308` and the `:nan` sentinel atom as
  # stand-ins (see `Lua.VM.Executor.safe_divide/4`). For pack/unpack to
  # round-trip these consistently — `unpack("f", pack("f", 1/0)) == 1/0`
  # is asserted in `tpack.lua` — we detect IEEE infinity bit patterns on
  # decode and remap them to the same stand-ins. Encoding side already
  # works because BEAM's binary syntax silently coerces values that
  # overflow the float width to ±Infinity bit patterns.

  # IEEE 754 single-precision +inf / -inf bit patterns.
  @inf_bits_32 0x7F800000
  @neg_inf_bits_32 0xFF800000
  # Double-precision: BEAM doubles can hold values up to ~1.8e308, so
  # `1.0e308` packs to a finite double bit pattern, not infinity. We
  # still guard the round-trip in case future code paths produce true
  # IEEE infinity for 64-bit floats.
  @inf_bits_64 0x7FF0000000000000
  @neg_inf_bits_64 0xFFF0000000000000

  defp encode_float(f, 4, :little), do: <<f::little-float-size(32)>>
  defp encode_float(f, 4, :big), do: <<f::big-float-size(32)>>
  defp encode_float(f, 8, :little), do: <<f::little-float-size(64)>>
  defp encode_float(f, 8, :big), do: <<f::big-float-size(64)>>

  defp decode_float(bytes, 4, endian) do
    case unsigned_bits(bytes, endian) do
      @inf_bits_32 -> 1.0e308
      @neg_inf_bits_32 -> -1.0e308
      _ -> raw_decode_float(bytes, 4, endian)
    end
  end

  defp decode_float(bytes, 8, endian) do
    case unsigned_bits(bytes, endian) do
      @inf_bits_64 -> 1.0e308
      @neg_inf_bits_64 -> -1.0e308
      _ -> raw_decode_float(bytes, 8, endian)
    end
  end

  defp raw_decode_float(<<f::little-float-size(32)>>, 4, :little), do: f
  defp raw_decode_float(<<f::big-float-size(32)>>, 4, :big), do: f
  defp raw_decode_float(<<f::little-float-size(64)>>, 8, :little), do: f
  defp raw_decode_float(<<f::big-float-size(64)>>, 8, :big), do: f

  defp unsigned_bits(bytes, :little), do: :binary.decode_unsigned(bytes, :little)
  defp unsigned_bits(bytes, :big), do: :binary.decode_unsigned(bytes, :big)

  # ---- argument coercion -------------------------------------------------

  defp to_integer(n, _) when is_integer(n), do: n

  defp to_integer(n, _) when is_float(n) do
    if n == Float.floor(n) and n >= -(1 <<< 63) and n <= (1 <<< 63) - 1 do
      trunc(n)
    else
      raise_runtime("number has no integer representation")
    end
  end

  defp to_integer(s, _) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> raise_runtime("bad argument (number expected)")
    end
  end

  defp to_integer(_, fname), do: raise_runtime("bad argument to '#{fname}' (number expected)")

  defp to_float(n, _) when is_number(n), do: n / 1
  defp to_float(_, fname), do: raise_runtime("bad argument to '#{fname}' (number expected)")

  defp to_string_arg(s, _) when is_binary(s), do: s
  defp to_string_arg(n, _) when is_integer(n), do: Integer.to_string(n)
  defp to_string_arg(n, _) when is_float(n), do: Float.to_string(n)
  defp to_string_arg(_, fname), do: raise_runtime("bad argument to '#{fname}' (string expected)")

  # ---- pos normalization for unpack -------------------------------------

  defp normalize_init_pos(pos, len) when pos < 0 do
    p = len + pos + 1
    if p < 1, do: raise_runtime("initial position out of string"), else: p - 1
  end

  defp normalize_init_pos(pos, _len) when pos < 1 do
    raise_runtime("initial position out of string")
  end

  defp normalize_init_pos(pos, len) when pos > len + 1 do
    raise_runtime("initial position out of string")
  end

  defp normalize_init_pos(pos, _len), do: pos - 1

  # ---- helpers -----------------------------------------------------------

  defp power_of_two?(n) when n >= 1, do: (n &&& n - 1) == 0
  defp power_of_two?(_), do: false

  defp raise_runtime(msg), do: raise(RuntimeError, value: msg)
end
