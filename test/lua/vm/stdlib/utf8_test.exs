defmodule Lua.VM.Stdlib.Utf8Test do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.ArgumentError, as: LuaArgumentError
  alias Lua.VM.RuntimeError, as: LuaRuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    VM.execute(proto, state)
  end

  describe "utf8.char" do
    test "encodes single-byte codepoints" do
      assert {:ok, ["abc"], _} = run("return utf8.char(97, 98, 99)")
    end

    test "encodes empty arg list to empty string" do
      assert {:ok, [""], _} = run("return utf8.char()")
    end

    test "encodes 2/3/4-byte sequences" do
      # 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF — boundaries
      assert {:ok, [bin], _} =
               run("return utf8.char(0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF)")

      assert bin ==
               <<0xC2, 0x80, 0xDF, 0xBF, 0xE0, 0xA0, 0x80, 0xEF, 0xBF, 0xBF, 0xF0, 0x90, 0x80, 0x80, 0xF4, 0x8F, 0xBF,
                 0xBF>>
    end

    test "raises value out of range above 0x10FFFF" do
      assert_raise LuaArgumentError, ~r/bad argument #1 to 'utf8\.char' \(value out of range\)/, fn ->
        run("return utf8.char(0x110000)")
      end
    end

    test "raises on non-integer arg" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #1 to 'utf8\.char' \(number expected, got string\)/,
                   fn ->
                     run("return utf8.char('a')")
                   end
    end

    test "accepts floats with integer representation" do
      assert {:ok, ["a"], _} = run("return utf8.char(97.0)")
    end

    test "raises on float with no integer representation" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #1 to 'utf8\.char' \(number has no integer representation\)/,
                   fn ->
                     run("return utf8.char(97.5)")
                   end
    end
  end

  describe "utf8.codepoint" do
    test "default i,j returns first codepoint" do
      assert {:ok, [97], _} = run("return utf8.codepoint('abc')")
    end

    test "returns range of codepoints" do
      assert {:ok, [97, 98, 99], _} = run("return utf8.codepoint('abc', 1, 3)")
    end

    test "multi-byte sequence" do
      # 汉 = 0x6C49, 字 = 0x5B57
      assert {:ok, [0x6C49, 0x5B57], _} = run("return utf8.codepoint('汉字', 1, -1)")
    end

    test "raises on invalid UTF-8 byte" do
      assert_raise LuaRuntimeError, ~r/invalid UTF-8 code/, fn ->
        run("return utf8.codepoint('\\xff')")
      end
    end

    test "raises on i out of range (below)" do
      assert_raise LuaArgumentError, ~r/bad argument #2 to 'utf8\.codepoint' \(out of range\)/, fn ->
        run("local s = 'abc'; return utf8.codepoint(s, -(#s + 1))")
      end
    end

    test "raises on j out of range (above)" do
      assert_raise LuaArgumentError, ~r/bad argument #3 to 'utf8\.codepoint' \(out of range\)/, fn ->
        run("local s = 'abc'; return utf8.codepoint(s, 1, #s + 1)")
      end
    end
  end

  describe "utf8.len" do
    test "ASCII string length is byte count" do
      assert {:ok, [11], _} = run("return utf8.len('hello World')")
    end

    test "counts multi-byte characters as 1 each" do
      assert {:ok, [2], _} = run("return utf8.len('汉字')")
    end

    test "empty string is length 0" do
      assert {:ok, [0], _} = run("return utf8.len('')")
    end

    test "returns nil + position on invalid sequence" do
      # 'abc' + \xE3 starts an unfinished 3-byte sequence at byte 4
      assert {:ok, [nil, 4], _} = run("return utf8.len('abc\\xE3def')")
    end

    test "range arguments" do
      assert {:ok, [1], _} = run("return utf8.len('abc', 2, 2)")
    end
  end

  describe "utf8.offset" do
    test "returns byte position of n-th character" do
      # 汉字 = 6 bytes (3 + 3). 1st char at byte 1, 2nd at byte 4.
      assert {:ok, [1], _} = run("return utf8.offset('汉字', 1)")
      assert {:ok, [4], _} = run("return utf8.offset('汉字', 2)")
    end

    test "n=0 returns start of character containing byte i" do
      # 4-byte char 𦧺 starts at byte 1. From any byte 1..4, n=0 returns 1.
      assert {:ok, [1], _} = run("return utf8.offset('𦧺', 0, 1)")
      assert {:ok, [1], _} = run("return utf8.offset('𦧺', 0, 4)")
    end

    test "negative n counts backward" do
      # "abc": 3 ASCII chars. n=-1 from end position (4) = last char position (3).
      assert {:ok, [3], _} = run("return utf8.offset('abc', -1)")
    end

    test "returns nil when past end" do
      assert {:ok, [nil], _} = run("return utf8.offset('alo', 5)")
      assert {:ok, [nil], _} = run("return utf8.offset('alo', -4)")
    end

    test "raises position out of range" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #3 to 'utf8\.offset' \(position out of range\)/,
                   fn ->
                     run("return utf8.offset('abc', 1, 5)")
                   end
    end

    test "raises position out of range (negative)" do
      assert_raise LuaArgumentError,
                   ~r/bad argument #3 to 'utf8\.offset' \(position out of range\)/,
                   fn ->
                     run("return utf8.offset('abc', 1, -4)")
                   end
    end

    test "raises on continuation byte at non-zero n" do
      # 𦧺 is 4 bytes; byte 2 is a continuation byte
      assert_raise LuaRuntimeError, ~r/initial position is a continuation byte/, fn ->
        run("return utf8.offset('𦧺', 1, 2)")
      end
    end
  end

  describe "utf8.codes" do
    test "iterates over ASCII codepoints" do
      code = """
      local t = {}
      for p, c in utf8.codes('abc') do
        t[#t + 1] = p
        t[#t + 1] = c
      end
      return t[1], t[2], t[3], t[4], t[5], t[6]
      """

      assert {:ok, [1, 97, 2, 98, 3, 99], _} = run(code)
    end

    test "iterates over multi-byte codepoints" do
      code = """
      local t = {}
      for p, c in utf8.codes('汉字') do
        t[#t + 1] = c
      end
      return t[1], t[2]
      """

      assert {:ok, [0x6C49, 0x5B57], _} = run(code)
    end

    test "raises on invalid sequence mid-iteration" do
      code = """
      for p, c in utf8.codes('ab\\xff') do end
      """

      assert_raise LuaRuntimeError, ~r/invalid UTF-8 code/, fn ->
        run(code)
      end
    end
  end

  describe "utf8.charpattern" do
    test "is the Lua 5.3 canonical pattern string" do
      assert {:ok, [pat], _} = run("return utf8.charpattern")
      assert pat == <<"[\0-\x7F\xC2-\xFD][\x80-\xBF]*">>
    end

    test "matches one UTF-8 sequence at a time via gmatch" do
      code = """
      local t = {}
      for c in string.gmatch('汉a字', utf8.charpattern) do
        t[#t + 1] = c
      end
      return t[1], t[2], t[3]
      """

      assert {:ok, ["汉", "a", "字"], _} = run(code)
    end
  end

  describe "require('utf8')" do
    test "resolves to the utf8 library table" do
      code = """
      local m = require('utf8')
      return m == utf8, m.char(97)
      """

      assert {:ok, [true, "a"], _} = run(code)
    end
  end
end
