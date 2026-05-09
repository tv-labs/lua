defmodule Lua.VM.Stdlib.StringPackTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Run the given Lua source against a fresh stdlib-installed VM and
  # return whatever the chunk returned.
  defp lua!(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  describe "string.packsize/1" do
    test "fixed-size integer formats" do
      assert lua!("return string.packsize('b')") == [1]
      assert lua!("return string.packsize('B')") == [1]
      assert lua!("return string.packsize('h')") == [2]
      assert lua!("return string.packsize('H')") == [2]
      assert lua!("return string.packsize('i')") == [4]
      assert lua!("return string.packsize('I')") == [4]
      assert lua!("return string.packsize('l')") == [8]
      assert lua!("return string.packsize('L')") == [8]
      assert lua!("return string.packsize('j')") == [8]
      assert lua!("return string.packsize('J')") == [8]
      assert lua!("return string.packsize('T')") == [8]
    end

    test "sized integer formats" do
      assert lua!("return string.packsize('i1')") == [1]
      assert lua!("return string.packsize('i3')") == [3]
      assert lua!("return string.packsize('i16')") == [16]
      assert lua!("return string.packsize('I7')") == [7]
    end

    test "float formats" do
      assert lua!("return string.packsize('f')") == [4]
      assert lua!("return string.packsize('d')") == [8]
      assert lua!("return string.packsize('n')") == [8]
    end

    test "fixed-size string formats" do
      assert lua!("return string.packsize('c0')") == [0]
      assert lua!("return string.packsize('c10')") == [10]
    end

    test "padding and whitespace" do
      assert lua!("return string.packsize('x')") == [1]
      assert lua!("return string.packsize(' b ')") == [1]
    end

    test "alignment with !" do
      # Default alignment is 1, so no padding.
      assert lua!("return string.packsize('bi4')") == [5]
      # !4 forces 4-byte alignment for i4.
      assert lua!("return string.packsize('!4 b i4')") == [8]
      # !8 with x then Xi8 gives 8-byte total (1 + 7 padding).
      assert lua!("return string.packsize('!8 xXi8')") == [8]
      assert lua!("return string.packsize('!2 xXi8')") == [2]
      assert lua!("return string.packsize('!2 xXi2')") == [2]
    end

    test "mixed types" do
      # b(1) + h(2) + b(1) + f(4) + d(8) + f(4) + n(8) + i(4) = 32
      assert lua!("return string.packsize('<b h b f d f n i')") == [32]
    end

    test "raises on variable-length formats" do
      assert_raise RuntimeError, ~r/variable-length format/, fn ->
        lua!("return string.packsize('s')")
      end

      assert_raise RuntimeError, ~r/variable-length format/, fn ->
        lua!("return string.packsize('z')")
      end
    end

    test "raises on out-of-range integer size" do
      assert_raise RuntimeError, ~r/out of limits/, fn ->
        lua!("return string.packsize('i0')")
      end

      assert_raise RuntimeError, ~r/out of limits/, fn ->
        lua!("return string.packsize('i17')")
      end
    end

    test "raises on missing 'c' size" do
      assert_raise RuntimeError, ~r/missing size/, fn ->
        lua!("return string.packsize('c')")
      end
    end

    test "raises on bad alignment" do
      assert_raise RuntimeError, ~r/not power of 2/, fn ->
        lua!("return string.packsize('!4 i3')")
      end
    end

    test "raises on unknown option" do
      assert_raise RuntimeError, ~r/invalid format option/, fn ->
        lua!("return string.packsize('r')")
      end
    end
  end

  describe "string.pack/2 — integer formats" do
    test "round-trips signed and unsigned bytes" do
      assert lua!("return string.unpack('B', string.pack('B', 0xff))") == [0xFF, 2]
      assert lua!("return string.unpack('b', string.pack('b', 0x7f))") == [0x7F, 2]
      assert lua!("return string.unpack('b', string.pack('b', -0x80))") == [-0x80, 2]
    end

    test "round-trips short, int, long" do
      assert lua!("return string.unpack('H', string.pack('H', 0xffff))") == [0xFFFF, 3]
      assert lua!("return string.unpack('L', string.pack('L', 0xffffffff))") == [0xFFFFFFFF, 9]
    end

    test "endianness controls byte order" do
      # >i4 of 1 is 00 00 00 01.
      assert lua!(~S{return string.pack('>i4', 1)}) == [<<0, 0, 0, 1>>]
      # <i4 of 1 is 01 00 00 00.
      assert lua!(~S{return string.pack('<i4', 1)}) == [<<1, 0, 0, 0>>]
      # = is native, which we treat as little.
      assert lua!(~S{return string.pack('=i4', 1)}) == [<<1, 0, 0, 0>>]
    end

    test "sign-extension on small signed sizes" do
      # i3 of -1 = FF FF FF (3 bytes of 0xFF).
      assert lua!(~S{return string.pack('i3', -1)}) == [<<0xFF, 0xFF, 0xFF>>]
    end

    test "raises on integer overflow for signed size" do
      assert_raise RuntimeError, ~r/overflow/, fn ->
        # i1 max = 127.
        lua!("return string.pack('<i1', 128)")
      end
    end

    test "raises on integer overflow for unsigned size" do
      assert_raise RuntimeError, ~r/overflow/, fn ->
        # I1 max = 255; -1 is not representable.
        lua!("return string.pack('<I1', -1)")
      end
    end
  end

  describe "string.pack/2 — float formats" do
    test "round-trips doubles via n/d" do
      assert lua!("return string.unpack('n', string.pack('n', 3.5))") == [3.5, 9]
      assert lua!("return string.unpack('d', string.pack('d', -1.25))") == [-1.25, 9]
    end

    test "round-trips f for round-numbered floats" do
      assert lua!("return string.unpack('<f', string.pack('<f', 24.0))") == [24.0, 5]
      assert lua!("return string.unpack('>f', string.pack('>f', 24.0))") == [24.0, 5]
    end
  end

  describe "string.pack/2 — string formats" do
    test "fixed-size c<n> pads with zeros" do
      assert lua!(~S{return string.pack('c5', 'abc')}) == [<<"abc", 0, 0>>]
    end

    test "fixed-size c<n> errors when string too long" do
      assert_raise RuntimeError, ~r/longer than/, fn ->
        lua!("return string.pack('c3', '1234')")
      end
    end

    test "z is zero-terminated" do
      assert lua!(~S{return string.pack('z', 'abc')}) == [<<"abc", 0>>]
    end

    test "z errors on embedded zero" do
      assert_raise RuntimeError, ~r/contains zeros/, fn ->
        lua!(~S{return string.pack('z', 'a\0b')})
      end
    end

    test "s prefixes with size_t-byte length" do
      # Default s = s8 (size_t). Length prefix is 8 little-endian bytes.
      assert lua!(~S{return string.pack('<s', 'ab')}) ==
               [<<2, 0, 0, 0, 0, 0, 0, 0, "ab">>]
    end

    test "s1 errors when length doesn't fit" do
      assert_raise RuntimeError, ~r/does not fit/, fn ->
        lua!(~S{return string.pack('s1', string.rep('a', 256))})
      end
    end

    test "s100 errors with out-of-limits" do
      assert_raise RuntimeError, ~r/out of limits/, fn ->
        lua!(~S{return string.pack('s100', 'a')})
      end
    end
  end

  describe "string.pack/2 — alignment" do
    test "X pads to natural alignment of next op (X is empty directive)" do
      # !8 b Xi8 = 1 byte (b=1), then 7 padding to reach 8-byte boundary.
      # Xi8 is an empty alignment directive — it does NOT emit i8 data.
      result = lua!(~S{return string.pack('!8 b Xi8', 1)})
      assert result == [<<1, 0, 0, 0, 0, 0, 0, 0>>]
    end

    test "X without valid follow-on errors" do
      assert_raise RuntimeError, ~r/invalid next option/, fn ->
        lua!(~S{return string.pack('X')})
      end

      assert_raise RuntimeError, ~r/invalid next option/, fn ->
        lua!(~S{return string.pack('Xc1')})
      end
    end

    test "no alignment by default" do
      # i1 i2 packs as 3 bytes, no padding.
      assert lua!(~S{return string.pack('<i1 i2', 2, 3)}) == [<<2, 3, 0>>]
    end
  end

  describe "string.unpack/2,3" do
    test "returns next read position as last value" do
      assert lua!(~S{return string.unpack('b', '\5')}) == [5, 2]
    end

    test "supports initial position argument" do
      assert lua!(~S{return string.unpack('b', '\1\2\3', 2)}) == [2, 3]
    end

    test "supports negative initial position" do
      assert lua!(~S{return string.unpack('b', '\1\2\3', -1)}) == [3, 4]
    end

    test "errors on initial position out of range" do
      assert_raise RuntimeError, ~r/out of string/, fn ->
        lua!(~S{return string.unpack('b', 'abc', 0)})
      end

      assert_raise RuntimeError, ~r/out of string/, fn ->
        lua!(~S{return string.unpack('b', 'abc', 5)})
      end
    end

    test "errors when source string is too short" do
      assert_raise RuntimeError, ~r/too short/, fn ->
        lua!(~S{return string.unpack('i4', 'ab')})
      end
    end

    test "c<n> reads exactly n bytes" do
      assert lua!(~S{return string.unpack('c3', 'abcdef')}) == ["abc", 4]
    end

    test "z reads up to NUL" do
      assert lua!(~S{return string.unpack('z', 'hello\0world')}) == ["hello", 7]
    end

    test "errors on unfinished z" do
      assert_raise RuntimeError, ~r/unfinished string|too short/, fn ->
        lua!(~S{return string.unpack('z', 'abc')})
      end
    end

    test "i16 errors when value can't fit in lua_Integer" do
      assert_raise RuntimeError, ~r/16-byte integer/, fn ->
        lua!(~S{return string.unpack('i16', string.rep('\3', 16))})
      end
    end
  end

  describe "string.pack/2 — combined" do
    test "mixed sequence packs and unpacks correctly" do
      code = ~S"""
      local s = string.pack('<b h b f d f n i', 1, 2, 3, 4, 5, 6, 7, 8)
      local a, b, c, d, e, f, g, h = string.unpack('<b h b f d f n i', s)
      return a, b, c, d, e, f, g, h
      """

      assert lua!(code) == [1, 2, 3, 4.0, 5.0, 6.0, 7.0, 8]
    end

    test "mixed endianness in single format" do
      assert lua!(~S{return string.pack('>i2 <i2', 10, 20)}) == [<<0, 10, 20, 0>>]
    end
  end
end
