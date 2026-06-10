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
  end
end
