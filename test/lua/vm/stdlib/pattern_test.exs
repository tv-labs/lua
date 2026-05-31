defmodule Lua.VM.Stdlib.PatternTest do
  use ExUnit.Case, async: true

  # Pins Lua 5.3 §6.4.1 position-capture semantics: an empty
  # parenthesised group `()` captures the current 1-based position in the
  # subject as an integer, not a substring.

  alias Lua.VM.Stdlib.Pattern

  describe "position capture in Pattern.match/find/gmatch" do
    test "() at the start captures position 1" do
      assert {:match, [1]} = Pattern.match("hello", "()")
    end

    test "() captures the 1-based byte position as an integer" do
      assert {:match, [3, 5]} = Pattern.match("hello", "()ll()")
    end

    test "find returns the captured position alongside the match span" do
      assert {3, 3, [4]} = Pattern.find("hello", "l()")
    end

    test "position capture mixes with a substring capture in opening order" do
      assert {:match, [1, "alo", 4]} = Pattern.match("alo jose", "()(%w+)()")
    end

    test "gmatch yields each match's position captures" do
      assert [[1, "a", 2], [3, "alo", 6], [7, "jose", 11], [13, "joao", 17]] =
               Pattern.gmatch("a alo jose  joao", "()(%w+)()")
    end

    test "gmatch with a bare () walks every position including end+1" do
      positions = "abcde" |> Pattern.gmatch("()") |> List.flatten()
      assert positions == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "position capture through the Lua string library" do
    test "string.match returns integer positions" do
      assert {[3, 5], _} = Lua.eval!(~S|return string.match("hello", "()ll()")|)
    end

    test "string.find appends the captured position" do
      assert {[3, 3, 4], _} = Lua.eval!(~S|return string.find("hello", "l()")|)
    end

    test "string.gsub passes positions to the replacement function" do
      script = ~S"""
      local t = {}
      local s = 'a alo jose  joao'
      local r = string.gsub(s, '()(%w+)()', function (a, w, b)
        assert(string.len(w) == b - a)
        t[a] = b - a
      end)
      return r, t[1], t[3], t[7], t[13]
      """

      assert {["a alo jose  joao", 1, 3, 4, 4], _} = Lua.eval!(script)
    end

    test "string.gmatch iterates positions in a for loop" do
      script = ~S"""
      local a = 0
      for i in string.gmatch('abcde', '()') do
        assert(i == a + 1)
        a = i
      end
      return a
      """

      assert {[6], _} = Lua.eval!(script)
    end
  end
end
