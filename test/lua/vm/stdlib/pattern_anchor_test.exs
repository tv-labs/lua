defmodule Lua.VM.Stdlib.PatternAnchorTest do
  use ExUnit.Case, async: true

  # Pins Lua 5.3 §6.4.1 ^-anchor semantics for string.gsub and
  # string.gmatch: a pattern beginning with `^` matches only at the start
  # of the subject, so gsub performs at most one replacement and reports a
  # count of 0 or 1 (mirrors the `anchor` handling in PUC-Lua lstrlib.c
  # str_gsub). In gmatch a leading `^` does not anchor — PUC-Lua matches
  # it as a literal caret (§6.4, `string.gmatch`). Expected values verified
  # against PUC-Lua.

  alias Lua.VM.Stdlib.Pattern

  describe "anchored string.gsub" do
    test "replaces only the leading occurrence" do
      assert {["Yax", 1], _} = Lua.eval!(~S|return string.gsub("xax", "^x", "Y")|)
    end

    test "replaces nothing when the subject does not start with a match" do
      assert {["aha", 0], _} = Lua.eval!(~S|return string.gsub("aha", "^h", "H")|)
    end

    test "replaces a leading multi-char run at most once" do
      assert {["Xabc", 1], _} = Lua.eval!(~S|return string.gsub("abcabc", "^abc", "X")|)
    end

    test "empty anchored match replaces once at the start" do
      assert {["Xbbb", 1], _} = Lua.eval!(~S|return string.gsub("bbb", "^a*", "X")|)
    end

    test "leading-whitespace trim preserves interior and trailing whitespace" do
      assert {["_a b  ", 1], _} = Lua.eval!(~S|return string.gsub("  a b  ", "^%s+", "_")|)
    end

    test "n = 0 suppresses the anchored replacement" do
      assert {["xax", 0], _} = Lua.eval!(~S|return string.gsub("xax", "^x", "Y", 0)|)
    end

    test "n greater than 1 still allows at most one anchored replacement" do
      assert {["Xaa", 1], _} = Lua.eval!(~S|return string.gsub("aaa", "^a", "X", 3)|)
      assert {["Xaa", 1], _} = Lua.eval!(~S|return string.gsub("aaa", "^a", "X", 2)|)
      assert {["Yax", 1], _} = Lua.eval!(~S|return string.gsub("xax", "^x", "Y", 5)|)
    end

    test "negative n suppresses the anchored replacement" do
      assert {["xax", 0], _} = Lua.eval!(~S|return string.gsub("xax", "^x", "Y", -1)|)
    end

    test "a table replacement is consulted once with the anchored capture" do
      assert {["AAlo alo", 1], _} =
               Lua.eval!(~S|return string.gsub("alo alo", "^(%a)", {a = "AA"})|)
    end

    test "anchored pattern whose $ fails leaves the subject untouched" do
      assert {["abc\n", 0], _} = Lua.eval!(~S|return string.gsub("abc\n", "^%a*$", "X")|)
    end

    test "captures reach a function replacement exactly once" do
      script = ~S"""
      local calls = {}
      local s, n = string.gsub("abcabc", "^(a)(b)", function(a, b)
        calls[#calls + 1] = a .. b
        return "<" .. b .. a .. ">"
      end)
      return s, n, #calls, calls[1]
      """

      assert {["<ba>cabc", 1, 1, "ab"], _} = Lua.eval!(script)
    end

    test "anchored pattern matching the whole subject replaces it" do
      assert {["X", 1], _} = Lua.eval!(~S|return string.gsub("abc", "^abc$", "X")|)
    end
  end

  describe "leading caret in string.gmatch" do
    test "does not anchor and does not match without a literal caret" do
      script = ~S"""
      local n = 0
      for w in ("aaa"):gmatch("^a") do n = n + 1 end
      return n
      """

      assert {[0], _} = Lua.eval!(script)
    end

    test "matches a literal caret like any other character" do
      script = ~S"""
      local t = {}
      for w in ("^a ^a"):gmatch("^a") do t[#t + 1] = w end
      return #t, t[1], t[2]
      """

      assert {[2, "^a", "^a"], _} = Lua.eval!(script)
    end

    test "yields the captures of every literal-caret match" do
      script = ~S"""
      local t = {}
      for w in ("^a^b"):gmatch("^(%a)") do t[#t + 1] = w end
      return #t, t[1], t[2]
      """

      assert {[2, "a", "b"], _} = Lua.eval!(script)
    end

    test "a quantifier binds to the literal caret" do
      script = ~S"""
      local t = {}
      for w in ("^*x"):gmatch("^*") do t[#t + 1] = w end
      return #t, t[1], t[2], t[3]
      """

      assert {[3, "^", "", ""], _} = Lua.eval!(script)
    end

    test "a trailing $ still anchors to the end after a literal caret" do
      script = ~S"""
      local t = {}
      for w in ("a^"):gmatch("^$") do t[#t + 1] = w end
      return #t, t[1]
      """

      assert {[1, "^"], _} = Lua.eval!(script)
    end
  end

  describe "anchored Pattern.gsub/4" do
    test "replaces at most once at the start" do
      assert {"Yax", 1} = Pattern.gsub("xax", "^x", "Y")
      assert {"aha", 0} = Pattern.gsub("aha", "^h", "H")
    end

    test "honours an explicit max_n of 0" do
      assert {"xax", 0} = Pattern.gsub("xax", "^x", "Y", 0)
    end

    test "caps the count at 1 for a max_n above 1" do
      assert {"Xaa", 1} = Pattern.gsub("aaa", "^a", "X", 3)
    end

    test "treats a negative max_n as no replacement" do
      assert {"xax", 0} = Pattern.gsub("xax", "^x", "Y", -1)
    end
  end
end
