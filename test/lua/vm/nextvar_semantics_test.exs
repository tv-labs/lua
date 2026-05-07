defmodule Lua.VM.NextvarSemanticsTest do
  @moduledoc """
  Regressions for the table semantics gaps surfaced by `nextvar.lua` (plan A7).

  Each test pins a single Lua 5.3 contract that the suite exercises. The cases
  here are deliberately small so a future regression points at the specific
  semantic that broke, not at the 600-line suite file.

  See `.agents/plans/A7-nextvar-suite.md` for context. The plan covers three
  fixes in this PR:

    1. Assigning `nil` to a key removes the key (Lua 5.3 §3.4.11).
    2. Float keys with an exact integer value collapse to integers
       (Lua 5.3 §3.4.11).
    3. `pairs`/`ipairs` raise "bad argument" for non-table inputs.

  A fourth gap (dead-key tracking so iteration tolerates `t[k] = nil`
  during `pairs`) is deferred to plan A7a.
  """

  use ExUnit.Case, async: true

  defp run!(code) do
    {results, _state} = Lua.eval!(Lua.new(), code)
    results
  end

  describe "nil-value writes delete the key (§3.4.11)" do
    test "table constructor with explicit nil leaves index unset" do
      assert run!("return \#{}") == [0]
      assert run!("return \#{nil}") == [0]
      assert run!("return \#{nil, nil}") == [0]
      assert run!("return \#{nil, nil, nil}") == [0]
    end

    test "leading non-nil followed by nils still reports a small border" do
      assert run!("return \#{1, nil, nil}") == [1]
      assert run!("return \#{1, 2, nil}") == [2]
    end

    test "rawlen ignores trailing nil entries from the constructor" do
      assert run!("return rawlen({nil})") == [0]
      assert run!("return rawlen({1, nil, nil})") == [1]
    end

    test "assignment of nil clears the key from rawget" do
      assert run!("local t = {a = 1}; t.a = nil; return rawget(t, 'a')") == [nil]
      assert run!("local t = {1, 2, 3}; t[2] = nil; return rawget(t, 2)") == [nil]
    end

    test "assignment of nil removes the key from pairs iteration" do
      code = """
      local t = {a = 1, b = 2}
      t.a = nil
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
      """

      assert run!(code) == [1]
    end

    test "rawset(t, k, nil) removes the key" do
      assert run!("local t = {1, 2}; rawset(t, 2, nil); return rawget(t, 2)") == [nil]
    end

    test "next on a table whose only key was cleared returns nil" do
      # `next` returns two values when there is no next entry: a nil key
      # and a nil value. After clearing the sole key, iteration is over.
      assert run!("local t = {x = 1}; t.x = nil; return next(t)") == [nil, nil]
    end
  end

  describe "float keys with exact integer value collapse to integers (§3.4.11)" do
    test "writing t[1.0] = v makes t[1] read v" do
      assert run!("local t = {}; t[1.0] = 'hello'; return t[1]") == ["hello"]
    end

    test "writing t[1] = v makes t[1.0] read v" do
      assert run!("local t = {}; t[1] = 'hello'; return t[1.0]") == ["hello"]
    end

    test "rawset and rawget agree across integer/float forms" do
      code = """
      local t = {}
      rawset(t, 5.0, 42)
      return rawget(t, 5)
      """

      assert run!(code) == [42]
    end

    test "next reports the key in canonical integer form" do
      assert run!("local t = {}; t[2.0] = 'v'; local k = next(t); return k") == [2]
    end

    test "float-keyed integer indices act as integer keys" do
      # Float-power keys must round-trip through normalization so that
      # `t[2.0^i]` is reachable via `t[1]`, `t[2]`, etc. Before A7 these
      # writes landed at *float* keys and the reads found nothing.
      code = """
      local t = {}
      for i = 0, 4 do t[2.0 ^ i] = true end
      return t[1], t[2], t[4], t[8], t[16]
      """

      assert run!(code) == [true, true, true, true, true]
    end

    test "length operator after float-key writes returns a valid border" do
      # `#t` is allowed to return any border `n` (n where t[n]~=nil and
      # t[n+1]==nil). For the dense block {1, 2} starting from key 1, the
      # smallest border is 2 (since t[2] is set and t[3] is nil). Real
      # Lua 5.3 returns 2 here.
      assert run!("local t = {} t[1.0] = 'a'; t[2.0] = 'b'; return \#t") == [2]

      # Pin the symptom that originally broke nextvar.lua line 310:
      # `a[#a]` after dense float-keyed writes must reach a real value.
      assert run!("local t = {} t[1.0] = 'a'; t[2.0] = 'b'; return t[\#t]") == ["b"]
    end

    test "non-integer float keys are preserved as floats" do
      assert run!("local t = {}; t[1.5] = 'half'; return t[1.5], t[1]") == ["half", nil]
    end
  end

  describe "pairs and ipairs validate their argument" do
    test "pairs() with no argument raises 'bad argument'" do
      assert_raise Lua.RuntimeException, ~r/bad argument #1 to 'pairs'/, fn ->
        Lua.eval!(Lua.new(), "pairs()")
      end
    end

    test "ipairs() with no argument raises 'bad argument'" do
      assert_raise Lua.RuntimeException, ~r/bad argument #1 to 'ipairs'/, fn ->
        Lua.eval!(Lua.new(), "ipairs()")
      end
    end

    test "pairs(non_table) raises 'bad argument'" do
      assert_raise Lua.RuntimeException, ~r/bad argument #1 to 'pairs'/, fn ->
        Lua.eval!(Lua.new(), "pairs(42)")
      end
    end

    test "ipairs(non_table) raises 'bad argument'" do
      assert_raise Lua.RuntimeException, ~r/bad argument #1 to 'ipairs'/, fn ->
        Lua.eval!(Lua.new(), "ipairs('hello')")
      end
    end
  end
end
