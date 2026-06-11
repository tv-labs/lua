defmodule Lua.VM.TableBorderTest do
  @moduledoc """
  Pins the cached sequence border on `%Lua.VM.Table{}`: the common no-hole
  `#t` must be O(1) (an integer `border`), while every mutation that could
  invalidate it falls back to a scan that still returns a valid Lua 5.3
  §6.1 border (for a table with holes, `#t` may be any valid border).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.VM.Table

  defp build(pairs), do: Enum.reduce(pairs, %Table{}, fn {k, v}, t -> Table.put(t, k, v) end)
  defp seq(n), do: build(Enum.map(1..n, &{&1, &1}))

  # A single mutation: a key drawn from a small range (so dense runs, holes,
  # and contiguous refills interleave heavily — the shape the stale-border
  # bug lived in) paired with either a value or the :delete sentinel.
  defp op_gen do
    key =
      frequency([
        {8, integer(1..10)},
        {1, integer(-2..0)},
        {1, string(?a..?z, min_length: 1, max_length: 2)}
      ])

    value = frequency([{3, integer(1..1000)}, {1, constant(:delete)}])

    tuple({key, value})
  end

  defp apply_op(t, k, :delete), do: Table.put(t, k, nil)
  defp apply_op(t, k, v), do: Table.put(t, k, v)

  # `present` tracks only positive-integer keys mapped to a non-nil value —
  # the only keys that bear on the sequence border.
  defp track(present, k, :delete) when is_integer(k) and k >= 1, do: MapSet.delete(present, k)
  defp track(present, k, _v) when is_integer(k) and k >= 1, do: MapSet.put(present, k)
  defp track(present, _k, _v), do: present

  # `b` is a legal Lua 5.3 §6.1 border for the live key set `present` iff
  # t[b] is non-nil (or b == 0) and t[b + 1] is nil. A holey table has more
  # than one legal border, so this checks the boundary condition, not a value.
  defp legal_border?(present, b) do
    (b == 0 or MapSet.member?(present, b)) and not MapSet.member?(present, b + 1)
  end

  test "empty table has length 0 and an integer border" do
    t = %Table{}
    assert Table.length(t) == 0
    assert t.border == 0
  end

  test "contiguous appends give length n with an integer border (O(1) arm)" do
    t = seq(5)
    assert Table.length(t) == 5
    assert t.border == 5
  end

  test "appending one past the border extends the cached border" do
    t = seq(3)
    t = Table.put(t, 4, 4)
    assert t.border == 4
    assert Table.length(t) == 4
  end

  test "popping the tail leaves a valid length" do
    t = seq(5)
    t = Table.put(t, 5, nil)
    # Clearing the tail (key == cached border) dirties the cache; the scan
    # recomputes the new border.
    assert t.border == :dirty
    assert Table.length(t) == 4
  end

  test "every in-array delete dirties the cached border and keeps length legal" do
    # An integer border always equals arr_n, and an in-array delete (1..arr_n)
    # can only shorten the dense run reachable from 1, so each such delete must
    # flip the cache to :dirty while length/1 still reports a legal border.
    t = seq(5)
    assert t.border == 5

    # Tail delete (key == arr_n) dirties the cache even though it removes the
    # top of a dense run.
    t = Table.put(t, 5, nil)
    assert t.border == :dirty
    assert Table.length(t) == 4

    # A fresh dense run re-establishes the O(1) integer border; an interior
    # delete (key < arr_n) also dirties it. Legal borders are 1 and 4.
    t = seq(4)
    assert t.border == 4
    t = Table.put(t, 2, nil)
    assert t.border == :dirty
    assert legal_border?(MapSet.new([1, 3, 4]), Table.length(t))
  end

  test "repeated tail pop stays correct down to empty" do
    t = seq(4)

    t = Table.put(t, 4, nil)
    assert Table.length(t) == 3

    t = Table.put(t, 3, nil)
    assert Table.length(t) == 2

    t = Table.put(t, 2, nil)
    assert Table.length(t) == 1

    t = Table.put(t, 1, nil)
    assert Table.length(t) == 0
  end

  test "hole strictly beyond the cached border keeps the border valid" do
    t = seq(3)
    assert t.border == 3

    # t[5] routes to the hash (sparse beyond border) and dirties the cache,
    # because a later contiguous fill could promote it.
    t = Table.put(t, 5, 5)
    assert t.border == :dirty
    assert Table.length(t) == 3

    # Removing the sparse key leaves a valid length.
    t = Table.put(t, 5, nil)
    assert Table.length(t) == 3
    assert Table.get(t, 5) == nil
  end

  test "in-border overwrite dirties the cache but length is unchanged" do
    t = seq(5)
    t = Table.put(t, 2, :two)
    assert t.border == :dirty
    assert Table.length(t) == 5
    assert Table.get(t, 2) == :two
  end

  test "holey table reports a legal border and keeps every live key readable" do
    t = seq(5)
    t = Table.put(t, 3, nil)

    # A table with a hole at 3 has valid borders 2 and 5; #t may be either.
    assert Table.length(t) in [2, 5]

    assert Table.get(t, 1) == 1
    assert Table.get(t, 2) == 2
    assert Table.get(t, 3) == nil
    assert Table.get(t, 4) == 4
    assert Table.get(t, 5) == 5
  end

  test "float keys behave like their integer slots" do
    t = build([{1.0, :a}, {2.0, :b}, {3, :c}])
    assert Table.length(t) == 3
    assert t.border == 3

    t = Table.put(t, 3.0, nil)
    assert Table.length(t) == 2
  end

  test "string-field write does not dirty the border" do
    t = seq(3)
    t = Table.put(t, "x", 1)
    assert t.border == 3
    assert Table.length(t) == 3
  end

  test "deleting a string key does not dirty the border" do
    t = seq(3)
    t = Table.put(t, "x", 1)
    t = Table.put(t, "x", nil)
    assert t.border == 3
    assert Table.length(t) == 3
  end

  test "non-positive integer-key write does not dirty the border" do
    # Keys <= 0 never bear on the sequence border, so they route through the
    # hash without invalidating the cached integer (border stays O(1)).
    t = seq(3)

    t = Table.put(t, 0, :zero)
    assert t.border == 3
    assert Table.length(t) == 3

    t = Table.put(t, -5, :neg)
    assert t.border == 3
    assert Table.length(t) == 3
  end

  test "deleting a non-positive integer key does not dirty the border" do
    t = seq(3)
    t = Table.put(t, 0, :zero)
    t = Table.put(t, 0, nil)
    assert t.border == 3
    assert Table.length(t) == 3
  end

  test "appending after an in-border overwrite re-establishes an integer border" do
    t = seq(3)
    t = Table.put(t, 2, :two)
    assert t.border == :dirty

    t = Table.put(t, 4, 4)
    assert t.border == 4
    assert Table.length(t) == 4
  end

  test "sparse fill promotes parked keys and updates the border" do
    t = seq(2)
    t = Table.put(t, 4, 4)
    assert t.border == :dirty
    assert Table.length(t) == 2

    # Filling the gap at 3 promotes both 3 and the parked 4 into the array.
    t = Table.put(t, 3, 3)
    assert t.border == 4
    assert Table.length(t) == 4
  end

  test "1000-element append loop stays linear and reports the right length" do
    t = Enum.reduce(1..1000, %Table{}, fn i, acc -> Table.put(acc, i, i) end)
    assert t.border == 1000
    assert Table.length(t) == 1000
  end

  test "appending past a leading hole does not resurrect a stale border" do
    # delete leaves a hole inside the array region while keeping arr_n as the
    # high-water mark. A later append at arr_n + 1 must NOT cache arr_n as the
    # border: slot 1 is still a hole, so the only borders are 0 and the new top.
    t = seq(5)
    t = Table.put(t, 1, nil)
    assert Table.length(t) == 0

    t = Table.put(t, 6, 60)
    # 1..5 still has the hole at 1, so the contiguous-from-1 border is 0.
    assert Table.length(t) == 0
    refute t.border == 6
  end

  test "appending past an interior hole keeps length at the hole" do
    t = seq(5)
    t = Table.put(t, 3, nil)
    t = Table.put(t, 6, 60)
    # Hole at 3: contiguous-from-1 border is 2 (1,2 then gap).
    assert Table.length(t) == 2
    refute t.border == 6
  end

  test "from_data over an out-of-order map reports a legal integer border" do
    # A literal map iterates in an arbitrary order; from_data folds put/3 over
    # it starting from border 0. When key 2 lands before key 1, the write at 2
    # cannot take the O(1) contiguous-append arm — it parks in the hash and
    # dirties the border, and the later fill at 1 must absorb-scan to a valid
    # border rather than caching a stale integer.
    t = Table.from_data(%{2 => :b, 1 => :a, 3 => :c})

    assert Table.length(t) == 3
    assert legal_border?(MapSet.new([1, 2, 3]), Table.length(t))
    assert Table.get(t, 1) == :a
    assert Table.get(t, 2) == :b
    assert Table.get(t, 3) == :c
  end

  test "from_data over a holey map reports a legal border, not a stale top" do
    t = Table.from_data(%{1 => :a, 2 => :b, 4 => :d})

    # Hole at 3: legal borders are 2 and 4; #t must be one of them, never a
    # stale value that skips the gap.
    assert Table.length(t) in [2, 4]
    assert legal_border?(MapSet.new([1, 2, 4]), Table.length(t))
    assert Table.get(t, 4) == :d
  end

  test "replace_data over a dense table with an interior hole re-splits to a legal border" do
    # Seed the border integer cache via a dense append run, then replace the
    # contents wholesale with a map that has an interior hole. replace_data
    # seeds border: :dirty before re-splitting, so the result must reflect the
    # new key set, not the prior dense cache.
    t = Table.replace_data(seq(5), %{1 => :a, 2 => :b, 4 => :d})

    assert Table.length(t) in [2, 4]
    assert legal_border?(MapSet.new([1, 2, 4]), Table.length(t))
    assert Table.get(t, 1) == :a
    assert Table.get(t, 4) == :d
    # No resurrected key from the replaced dense table.
    assert Table.get(t, 3) == nil
    assert Table.get(t, 5) == nil
  end

  test "put_many full reorder of a dense table keeps the length" do
    # table.sort's fast path writes the sorted slice back via put_many, folding
    # put/3 through the in-border-overwrite arm (which flips border to :dirty).
    # A full reorder must leave length unchanged at 5.
    t = Table.put_many(seq(5), [{1, 50}, {2, 40}, {3, 30}, {4, 20}, {5, 10}])

    assert Table.length(t) == 5
    assert legal_border?(MapSet.new([1, 2, 3, 4, 5]), Table.length(t))
    assert Table.get(t, 1) == 50
    assert Table.get(t, 5) == 10
  end

  test "a positive-int hash insert dirties the border and drops the order memo together" do
    # arr_n is 3; a sparse insert at 10 routes through insert_hash, which sits
    # one line apart from the order memo invalidation. Both caches must drop:
    # the border because a later contiguous fill could promote 10 into #t, and
    # the memo because order_tail just grew a new hash key.
    t = 3 |> seq() |> Table.put("x", 1) |> Table.flush_order()
    assert is_integer(t.border)
    assert t.order_index

    t = Table.put(t, 10, 10)
    assert t.border == :dirty
    assert t.order_index == nil
    assert t.order_arr == nil
    assert Table.length(t) == 3
  end

  test "an in-array delete dirties the border but leaves the order memo intact" do
    # Array keys never live in `order`, so clearing an in-array slot must dirty
    # the border (the dense run from 1 can only shrink) without touching the
    # hash iteration memo built by flush_order/1.
    t = 3 |> seq() |> Table.put("x", 1) |> Table.flush_order()
    index = t.order_index
    arr = t.order_arr
    assert index

    t = Table.put(t, 2, nil)
    assert t.border == :dirty
    assert t.order_index == index
    assert t.order_arr == arr
    assert legal_border?(MapSet.new([1, 3]), Table.length(t))
  end

  test "a string-key write drops the order memo but keeps the integer border" do
    # A non-positive-integer hash key never bears on #t, so the cached integer
    # border survives untouched while the order memo drops (order_tail grew).
    t = 3 |> seq() |> Table.put("x", 1) |> Table.flush_order()
    assert t.border == 3
    assert t.order_index

    t = Table.put(t, "y", 2)
    assert t.border == 3
    assert t.order_index == nil
    assert t.order_arr == nil
    assert Table.length(t) == 3
  end

  property "length/1 returns a legal border after every mutation" do
    check all(ops <- list_of(op_gen(), max_length: 60)) do
      Enum.reduce(ops, {%Table{}, MapSet.new()}, fn {k, v}, {t, present} ->
        t = apply_op(t, k, v)
        present = track(present, k, v)
        len = Table.length(t)

        assert is_integer(len) and len >= 0

        assert legal_border?(present, len),
               "length=#{len} is not a legal border for live keys " <>
                 "#{inspect(Enum.sort(present))} after op #{inspect({k, v})} " <>
                 "(border field=#{inspect(t.border)})"

        {t, present}
      end)
    end
  end

  property "get/2 stays consistent with an independent key=>value oracle" do
    check all(ops <- list_of(op_gen(), max_length: 60)) do
      {table, oracle} =
        Enum.reduce(ops, {%Table{}, %{}}, fn {k, v}, {t, oracle} ->
          oracle = if v == :delete, do: Map.delete(oracle, k), else: Map.put(oracle, k, v)
          {apply_op(t, k, v), oracle}
        end)

      for k <- ops |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
        assert Table.get(table, k) == Map.get(oracle, k)
      end
    end
  end
end
