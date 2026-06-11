defmodule Lua.VM.TableIterationTest do
  @moduledoc """
  Pins the O(1)-per-step hash iteration path and its equivalence with the
  list-based fallback, while preserving Lua 5.3 §6.1 dead-key semantics.

  `Lua.VM.Table.flush_order/1` builds a memoized order array plus a
  `key => index` map so each `next_entry/2` hash step is an index lookup
  and a forward scan to the next live key, rather than a linear `===` scan
  over the whole order list. Both the memoized path (after `flush_order/1`)
  and the unflushed fallback must agree on `{k, v}` / `nil` / `:invalid_key`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.VM.Table

  # Collects the full hash-key walk starting from `nil`, driving the same
  # `Table` instance `next_entry/2` would see during a real `pairs` loop.
  defp walk(table) do
    nil
    |> Stream.unfold(fn key ->
      case Table.next_entry(table, key) do
        nil -> nil
        :invalid_key -> nil
        {k, _v} = pair -> {pair, k}
      end
    end)
    |> Enum.to_list()
  end

  # Mix of array keys, sparse-integer hash keys, and string hash keys, so the
  # array arm, the integer-hash arm, and the string-hash arm of next_entry/2
  # all get exercised in one table.
  defp key_gen do
    frequency([
      {5, integer(1..12)},
      {2, integer(100..110)},
      {5, string(?a..?z, min_length: 1, max_length: 3)}
    ])
  end

  defp entries_gen, do: list_of(tuple({key_gen(), integer(1..1000)}), max_length: 40)

  # Builds the table and an independent key=>value oracle from the same ops
  # (last write wins on both sides; generated values are always non-nil).
  defp build_pair(ops) do
    Enum.reduce(ops, {%Table{}, %{}}, fn {k, v}, {t, m} ->
      {Table.put(t, k, v), Map.put(m, k, v)}
    end)
  end

  # Walks like `walk/1`, but deletes the just-returned key before resuming
  # from it — the canonical Lua "remove the current field during traversal"
  # pattern. §6.1 guarantees the cleared key stays a valid resume point, so
  # this must visit every originally-live key once and never see :invalid_key.
  defp walk_deleting(table), do: walk_deleting(table, nil, [])

  defp walk_deleting(table, key, acc) do
    case Table.next_entry(table, key) do
      nil ->
        Enum.reverse(acc)

      :invalid_key ->
        flunk("next_entry returned :invalid_key resuming from just-cleared key #{inspect(key)}")

      {k, _v} ->
        walk_deleting(Table.put(table, k, nil), k, [k | acc])
    end
  end

  describe "memoized iteration path" do
    test "flush_order builds order_arr and order_index covering every live key" do
      table =
        1..50
        |> Enum.reduce(%Table{}, fn i, acc ->
          Table.put(acc, "k#{i}", i)
        end)
        |> Table.flush_order()

      assert table.order_index
      assert table.order_arr
      assert :array.size(table.order_arr) == 50
      assert map_size(table.order_index) == 50
    end

    test "a full walk over a large string-keyed table visits every key once" do
      keys = Enum.map(1..200, &"k#{&1}")

      table =
        keys
        |> Enum.reduce(%Table{}, fn k, acc -> Table.put(acc, k, k) end)
        |> Table.flush_order()

      walked = walk(table)

      assert Enum.map(walked, &elem(&1, 0)) == keys
      assert length(walked) == 200
    end

    test "next_entry on a key absent everywhere returns :invalid_key via the memo" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      assert Table.next_entry(table, "ghost") == :invalid_key
    end

    test "a cleared key stays a valid resume point (§6.1)" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.put("c", 3)
        |> Table.flush_order()

      # Clear "b" mid-iteration; it must remain in order_arr so next(t, "b")
      # advances to the following live key rather than raising.
      cleared = Table.put(table, "b", nil)

      assert Table.next_entry(cleared, "b") == {"c", 3}
    end
  end

  describe "memoized path equals list-based fallback" do
    test "for every key, the memoized result matches the unflushed result" do
      base =
        %Table{}
        |> Table.put(1, "one")
        |> Table.put("x", "ex")
        |> Table.put(2, "two")
        |> Table.put("y", "why")
        |> Table.put(7, "seven")
        |> Table.put("z", "zee")

      flushed = Table.flush_order(base)

      # The unflushed `base` still has a pending order_tail and a nil memo,
      # so its next_entry takes the merged_order/advance_past fallback.
      assert base.order_index == nil

      keys_to_probe = [nil, 1, 2, 7, "x", "y", "z", "ghost"]

      for key <- keys_to_probe do
        assert Table.next_entry(flushed, key) == Table.next_entry(base, key),
               "memo and fallback disagree on next_entry for key #{inspect(key)}"
      end
    end
  end

  describe "memo invalidation across mutations" do
    test "inserting a new key clears the memo so a fresh walk includes it" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      assert table.order_index

      mutated = Table.put(table, "c", 3)
      assert mutated.order_index == nil
      assert mutated.order_arr == nil

      reflushed = Table.flush_order(mutated)
      assert Enum.map(walk(reflushed), &elem(&1, 0)) == ["a", "b", "c"]
    end

    test "dead-key revival rebuilds the memo with the revived position" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      revived =
        table
        |> Table.put("a", nil)
        |> Table.put("a", 100)

      assert revived.order_index == nil

      reflushed = Table.flush_order(revived)
      walked = walk(reflushed)

      assert {"a", 100} in walked
      assert {"b", 2} in walked
      assert length(walked) == 2
    end

    test "clearing a value does not invalidate the memo (§6.1 resume point)" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      # Plain delete of a hash key only marks it dead; it must NOT touch the
      # order/memo, so the cleared key remains reachable for `next`.
      cleared = Table.put(table, "a", nil)

      assert cleared.order_index
      assert cleared.order_arr == table.order_arr
    end

    test "inserting a new key mid-walk then resuming from a prior key still advances" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      # Begin the walk, then insert a brand-new hash key. The insert nils the
      # memo (order_index/order_arr), so resuming from the already-returned
      # "a" must fall back to advance_past over merged_order — which still
      # contains "a" — and find the next live key rather than raising.
      assert Table.next_entry(table, nil) == {"a", 1}

      mutated = Table.put(table, "zzz", 99)
      assert mutated.order_index == nil
      assert mutated.order_arr == nil

      resumed = Table.next_entry(mutated, "a")
      assert resumed != :invalid_key
      assert resumed == {"b", 2}
    end

    test "absorbing a parked hash key into the array nils the memo" do
      # put(3) lands in the hash (border is at 1, so 3 is sparse). After
      # flush_order the memo is live and 3 is part of order_arr/order_index.
      # put(2) is a contiguous append that extends the border to 2, which
      # then absorbs the parked key 3 into the array via drop_hash_key — a
      # distinct memo-invalidation trigger from insert_hash and plain delete.
      table =
        %Table{}
        |> Table.put(1, "a")
        |> Table.put(3, "c")
        |> Table.put("s", "ess")
        |> Table.flush_order()

      assert table.order_index
      assert table.order_arr

      absorbed = Table.put(table, 2, "b")
      assert absorbed.order_index == nil
      assert absorbed.order_arr == nil

      # The walk is correct both before reflush (list-based fallback) and
      # after reflush (rebuilt memo): array keys 1,2,3 then the hash key "s".
      assert Enum.map(walk(absorbed), &elem(&1, 0)) == [1, 2, 3, "s"]
      assert Enum.map(walk(Table.flush_order(absorbed)), &elem(&1, 0)) == [1, 2, 3, "s"]
    end

    test "replace_data drops the memo and walks the new key set exactly once" do
      table =
        %Table{}
        |> Table.put(1, "a")
        |> Table.put("old", "x")
        |> Table.put("gone", "y")
        |> Table.flush_order()

      assert table.order_index
      assert table.order_arr

      # Wholesale replacement must reset the memo so a stale order_arr built
      # from the previous contents can never leak into the new walk.
      replaced = Table.replace_data(table, %{1 => "one", 2 => "two", "new" => "n"})
      assert replaced.order_index == nil
      assert replaced.order_arr == nil

      walked = walk(Table.flush_order(replaced))
      keys = Enum.map(walked, &elem(&1, 0))

      assert keys == [1, 2, "new"]
      assert length(keys) == length(Enum.uniq(keys))
      refute "old" in keys
      refute "gone" in keys
    end

    test "first_hash_live(nil) skips a value-cleared leading key with the memo live" do
      table =
        %Table{}
        |> Table.put("a", 1)
        |> Table.put("b", 2)
        |> Table.flush_order()

      # Clear the FIRST key in order_arr. The value-clear keeps the memo live
      # (order_index stays set), so first_hash_live must scan past the now-dead
      # leading "a" rather than returning it.
      cleared = Table.put(table, "a", nil)

      assert cleared.order_index
      assert Table.next_entry(cleared, nil) == {"b", 2}
    end
  end

  describe "iteration properties (StreamData)" do
    property "a full walk visits exactly the live key set, once each, with matching values" do
      check all(ops <- entries_gen()) do
        {table, oracle} = build_pair(ops)
        walked = walk(Table.flush_order(table))
        keys = Enum.map(walked, &elem(&1, 0))

        # No duplicates and nothing missing.
        assert length(keys) == map_size(oracle)
        assert MapSet.new(keys) == MapSet.new(Map.keys(oracle))

        for {k, v} <- walked do
          assert v == Map.fetch!(oracle, k), "value for #{inspect(k)} diverged from the oracle"
        end
      end
    end

    property "the memoized walk equals the unflushed list-based fallback walk" do
      check all(ops <- entries_gen()) do
        {table, _oracle} = build_pair(ops)
        assert walk(Table.flush_order(table)) == walk(table)
      end
    end

    property "clearing the current key mid-walk still visits every live key once (§6.1), memo and fallback" do
      check all(ops <- entries_gen()) do
        {table, oracle} = build_pair(ops)
        expected = MapSet.new(Map.keys(oracle))

        for start <- [table, Table.flush_order(table)] do
          visited = walk_deleting(start)

          assert length(visited) == map_size(oracle)
          assert MapSet.new(visited) == expected
        end
      end
    end
  end
end
