defmodule Lua.VM.BitwiseTest do
  use ExUnit.Case, async: true

  # Reduced repros of failing assertions from test/lua53_tests/bitwise.lua.
  # Per Lua 5.3 §3.1: "Hexadecimal numerals with neither a radix point nor
  # an exponent always denote an integer value; if the value overflows, it
  # wraps around to fit into a valid integer."

  defp run(code) do
    {results, _lua} = Lua.eval!(Lua.new(), code)
    results
  end

  describe "hex integer literal overflow wrapping" do
    # bitwise.lua:16
    test "0xFFFFFFFFFFFFFFFF == -1" do
      assert [true] = run("return 0xFFFFFFFFFFFFFFFF == -1")
    end

    test "0xFFFFFFFFFFFFFFFF & -1 == 0xFFFFFFFFFFFFFFFF" do
      assert [true] = run("local a = 0xFFFFFFFFFFFFFFFF; return a & -1 == a")
    end

    # bitwise.lua:19
    test "0xF0F0F0F0F0F0F0F0 ~ 0 == 0xF0F0F0F0F0F0F0F0" do
      assert [true] = run("local a = 0xF0F0F0F0F0F0F0F0; return a ~ 0 == a")
    end

    test "0xF0F0F0F0F0F0F0F0 ~ ~a == -1" do
      assert [true] = run("local a = 0xF0F0F0F0F0F0F0F0; return a ~ ~a == -1")
    end

    test "0x8000000000000000 == math.mininteger" do
      assert [true] = run("return 0x8000000000000000 == math.mininteger")
    end

    test "0xFFFFFFFFFFFFFFFF prints as -1" do
      assert [-1] = run("return 0xFFFFFFFFFFFFFFFF")
    end
  end

  describe "string-to-number coercion for bitwise operators" do
    # bitwise.lua:25 — hex floats in strings should coerce
    test "'0xAA.0' bor 0 == 0xAA" do
      assert [170] = run(~S{return "0xAA.0" | 0})
    end

    test "'0xFD.0' band 0xFF == 0xFD" do
      assert [253] = run(~S{return "0xFD.0" & 0xFF})
    end

    # tonumber should also handle hex floats in strings
    test "tonumber('0xAA.0') == 170.0" do
      assert [170.0] = run(~S{return tonumber("0xAA.0")})
    end

    test "tonumber('0xff.8') == 255.5" do
      assert [255.5] = run(~S{return tonumber("0xff.8")})
    end

    # bitwise.lua:59 — out-of-range hex float string still errors via pcall
    test "string with hex float that doesn't fit in int raises" do
      assert [false] =
               run(~S{local ok = pcall(function() return "0xffffffffffffffff.0" | 0 end); return ok})
    end
  end

  describe "Lua 5.3 mininteger boundary" do
    test "1 << (numbits - 1) == math.mininteger" do
      assert [true] =
               run("""
               local numbits = string.packsize('j') * 8
               return (1 << (numbits - 1)) == math.mininteger
               """)
    end
  end
end
