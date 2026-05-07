defmodule Lua.VM.NextvarDeadKeysTest do
  @moduledoc """
  Pins the dead-key iteration semantics required by Lua 5.3 §6.1.

  `next(t, k)` is well-defined while `pairs` is iterating even if the body
  just cleared `t[k]`. The reference VM keeps the cleared key reachable in
  the hash chain (a `TDEADKEY` slot) so iteration can find the next live
  entry. The same paragraph also requires `next(t, k)` to raise
  "invalid key to 'next'" when `k` was *never* a key in `t`.

  Three contracts covered, one per `describe` block:

    1. Strict `next` — phantom keys raise.
    2. Iterate-then-clear — `for k in pairs(t) do t[k] = nil end` visits
       every key once.
    3. Dead-key revival — re-assigning a previously cleared key works
       across a fresh iteration with no leaked state.
  """

  use ExUnit.Case, async: true

  defp run!(code) do
    {results, _state} = Lua.eval!(Lua.new(), code)
    results
  end

  describe "strict next (Lua 5.3 §6.1)" do
    test "next(t, k) raises when k was never a key in t" do
      assert_raise Lua.RuntimeException, ~r/invalid key to 'next'/, fn ->
        Lua.eval!(Lua.new(), "next({10, 20}, 3)")
      end
    end

    test "next(t, k) raises for a non-numeric phantom key too" do
      assert_raise Lua.RuntimeException, ~r/invalid key/, fn ->
        Lua.eval!(Lua.new(), "next({a = 1}, 'b')")
      end
    end

    test "next(t, nil) returns the first entry without raising" do
      # Insertion order is deterministic, so we assert against the literal
      # values the constructor inserted first.
      assert run!("local k, v = next({10, 20, 30}); return k, v") == [1, 10]
    end

    test "next walks past a key whose value was cleared mid-iteration" do
      code = """
      local t = {a = 1, b = 2, c = 3}
      local k1 = next(t)
      t[k1] = nil
      local k2 = next(t, k1)
      return k1 ~= k2 and k2 ~= nil
      """

      assert run!(code) == [true]
    end
  end

  describe "iterate-then-clear (Lua 5.3 §6.1)" do
    test "for k,v in pairs(t) do t[k] = nil end visits every key once" do
      code = """
      local t = {10, 20, 30, 40, 50}
      local n = 0
      for k, v in pairs(t) do
        n = n + 1
        assert(t[k] == v)
        t[k] = nil
      end
      return n
      """

      assert run!(code) == [5]
    end

    test "iterate-then-clear leaves the table empty" do
      code = """
      local t = {a = 1, b = 2, c = 3}
      for k in pairs(t) do t[k] = nil end
      local count = 0
      for _ in pairs(t) do count = count + 1 end
      return count
      """

      assert run!(code) == [0]
    end

    test "mixed-type keys all get visited exactly once" do
      # Mirrors nextvar.lua's "erasing values" loop (line ~315) — drives
      # iteration with a deliberately mixed key set so we know the
      # dead-key bookkeeping doesn't depend on key shape.
      code = """
      local t = {[1] = 'a', [2] = 'b', x = 'c', [3] = 'd', y = 'e'}
      local n = 0
      for k, v in pairs(t) do
        n = n + 1
        assert(t[k] == v)
        t[k] = nil
        assert(t[k] == nil)
      end
      return n
      """

      assert run!(code) == [5]
    end
  end

  describe "dead-key revival (no state leak across iterations)" do
    test "clear, re-assign, iterate — re-assigned key shows up live" do
      code = """
      local t = {a = 1, b = 2}
      t.a = nil
      t.a = 10
      local seen = {}
      for k, v in pairs(t) do seen[k] = v end
      return seen.a, seen.b
      """

      assert run!(code) == [10, 2]
    end

    test "dead-key state from one iteration does not poison the next" do
      code = """
      local t = {a = 1, b = 2, c = 3}
      -- First pass: clear everything via iteration.
      for k in pairs(t) do t[k] = nil end
      -- Second pass: refill, then iterate fresh. Should see all 3.
      t.a = 10; t.b = 20; t.c = 30
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
      """

      assert run!(code) == [3]
    end

    test "after a key is revived, next(t, revived_key) advances normally" do
      code = """
      local t = {a = 1, b = 2}
      t.a = nil      -- a is dead in `order`
      t.a = 100      -- revive — moves to end of `order`
      -- Walk every key starting from nil; we should see exactly 2 entries
      -- and a should map to 100.
      local count, sum = 0, 0
      for _, v in pairs(t) do
        count = count + 1
        sum = sum + v
      end
      return count, sum
      """

      assert run!(code) == [2, 102]
    end
  end
end
