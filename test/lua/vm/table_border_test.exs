defmodule Lua.VM.TableBorderTest do
  @moduledoc """
  Pins the cached sequence border on `%Lua.VM.Table{}`: the common no-hole
  `#t` must be O(1) (an integer `border`), while every mutation that could
  invalidate it falls back to a scan that still returns a valid Lua 5.3
  §6.1 border (for a table with holes, `#t` may be any valid border).
  """

  use ExUnit.Case, async: true

  alias Lua.VM.Table

  defp build(pairs), do: Enum.reduce(pairs, %Table{}, fn {k, v}, t -> Table.put(t, k, v) end)
  defp seq(n), do: build(Enum.map(1..n, &{&1, &1}))

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
end
