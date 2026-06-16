defmodule Lua.VM.Table do
  @moduledoc """
  Lua table data structure with split array/hash storage.

  Dense positive-integer keys (`1..n`) live in an Erlang `:array` (the
  `arr` field), giving O(1) functional read/write and a free sequence
  length. Every other key — strings, non-positive integers, sparse
  integers beyond the contiguous array border, float/boolean/table keys —
  lives in the `data` hash map alongside the iteration-order bookkeeping.

  Keeping string keys in `data` means the executor's field/global fast
  paths (`%{^name => value}`) and metatable lookups read the hash map
  directly with no change. Integer-keyed reads/writes route through the
  split-aware helpers in this module.

  ## Array border

  `arr_n` is the count of contiguous integer keys `1..arr_n` currently
  stored in `arr`. Writing key `arr_n + 1` extends the border; clearing a
  key inside the border splits it (the tail beyond the hole migrates to
  `data` lazily on read). A write to a sparse integer key beyond the
  border goes to `data` until a later contiguous fill promotes it.

  ## Cached sequence border

  `border` caches a value `length/1` is allowed to return, so the common
  no-hole `#t` is O(1) and `table.insert` (which reads `#t` per call) stays
  linear instead of quadratic. An integer `B` means slots `1..B` are known
  non-nil and `B + 1` is a known hole or the array high-water end, i.e. `B`
  is a valid Lua 5.3 §6.1 border; `length/1` returns it directly. `:dirty`
  means "recompute": `length/1` falls back to the scan-based path.

  The cache is only ever set to an integer the scan would itself return
  (`arr_n` right after a full contiguous absorb). Every mutation that could
  invalidate that — an in-border overwrite, a hole punched at or below the
  cached border, a positive-integer hash insert/delete — flips it to
  `:dirty`. Non-integer key writes never affect `#t` and leave it untouched,
  protecting the executor's string-field fast path from churn.

  ## Dead-key tracking

  Lua 5.3 §6.1 dead-key iteration semantics are preserved for the hash
  portion via `order`/`order_tail`/`dead` exactly as before. Array-portion
  keys iterate first, in index order, then hash keys in insertion order.
  """

  defstruct arr: :undefined,
            arr_n: 0,
            border: 0,
            data: %{},
            order: [],
            order_tail: [],
            order_index: nil,
            order_arr: nil,
            dead: %{},
            metatable: nil

  @type t :: %__MODULE__{
          arr: :array.array() | :undefined,
          arr_n: non_neg_integer(),
          border: non_neg_integer() | :dirty,
          data: %{optional(term()) => term()},
          order: list(term()),
          order_tail: list(term()),
          order_index: %{optional(term()) => non_neg_integer()} | nil,
          order_arr: :array.array() | nil,
          dead: %{optional(term()) => true},
          metatable: {:tref, non_neg_integer()} | nil
        }

  @compile {:inline, positive_int?: 1}

  defp positive_int?(k) when is_integer(k) and k >= 1, do: true
  defp positive_int?(_), do: false

  defp ensure_arr(:undefined), do: :array.new({:default, nil})
  defp ensure_arr(arr), do: arr

  @doc """
  Builds a table struct from a plain data map.

  Splits dense positive-integer keys into the array and leaves the rest in
  `data`, so callers that pass a literal map (stdlib init, `table.pack`,
  encode) get split storage with no extra effort.
  """
  @spec from_data(map()) :: t()
  def from_data(data) when is_map(data) do
    split_from_map(%__MODULE__{}, data)
  end

  @doc """
  Replaces the table contents wholesale from a plain data map, rebuilding
  the array/hash split and clearing `dead`.
  """
  @spec replace_data(t(), map()) :: t()
  def replace_data(%__MODULE__{} = table, data) when is_map(data) do
    split_from_map(
      %{
        table
        | arr: :undefined,
          arr_n: 0,
          border: :dirty,
          data: %{},
          order: [],
          order_tail: [],
          order_index: nil,
          order_arr: nil,
          dead: %{}
      },
      data
    )
  end

  defp split_from_map(table, data) do
    Enum.reduce(data, table, fn {k, v}, acc -> put(acc, k, v) end)
  end

  @doc """
  Writes `value` into the table under `key`, honoring Lua semantics:

    * Assigning `nil` removes the key.
    * Dense positive integers route to the array; other keys to the hash.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = table, key, value) do
    key = normalize_key(key)

    cond do
      value == nil -> delete(table, key)
      positive_int?(key) -> put_array(table, key, value)
      true -> insert_hash(table, key, value)
    end
  end

  # Array write. A contiguous append (key == arr_n + 1) extends the border;
  # an in-border overwrite is a plain :array.set; a write beyond the border
  # goes to the hash until a later contiguous fill could promote it.
  defp put_array(%__MODULE__{arr: arr, arr_n: n} = table, key, value) when key == n + 1 do
    arr = :array.set(key - 1, value, ensure_arr(arr))
    # Pull any contiguous successors that were parked in the hash into arr.
    absorbed = absorb_from_hash(%{table | arr: arr, arr_n: key})
    # Cache the new border, but only if slots 1..arr_n are actually dense.
    # The append proves the top slot is filled; it says nothing about a hole
    # punched lower down (delete keeps arr_n as the high-water mark, so a
    # cleared slot stays a nil inside the region). The load-bearing invariant:
    # a cached integer border always equals arr_n (it is only ever set here, to
    # absorbed.arr_n, and arr_n only grows on this same arm). So an integer
    # incoming border proves 1..arr_n was fully dense, the new top slot extends
    # it, and the run stays dense — cache in O(1), the hot insert-loop path. A
    # :dirty incoming border might hide a lower hole, so scan once to learn the
    # true border; a clean run re-establishes the O(1) cache, a holey one stays
    # :dirty.
    case table.border do
      b when is_integer(b) ->
        %{absorbed | border: absorbed.arr_n}

      :dirty ->
        # array_border == arr_n means no hole inside 1..arr_n: a valid border.
        if array_border(absorbed.arr, absorbed.arr_n) == absorbed.arr_n do
          %{absorbed | border: absorbed.arr_n}
        else
          absorbed
        end
    end
  end

  defp put_array(%__MODULE__{arr_n: n} = table, key, value) when key <= n do
    # In-border overwrite. value is non-nil (put/3 routes nil to delete/2);
    # filling a former hole could raise the reachable border, so recompute.
    %{table | arr: :array.set(key - 1, value, table.arr), border: :dirty}
  end

  defp put_array(%__MODULE__{} = table, key, value) do
    # Sparse integer beyond the border — store in hash for now. insert_hash
    # marks the border :dirty because a positive-int key could later be
    # promoted into the sequence and extend #t.
    insert_hash(table, key, value)
  end

  # After extending the border, migrate any hash-resident keys arr_n+1,
  # arr_n+2, ... into the array so the contiguous run stays in arr.
  defp absorb_from_hash(%__MODULE__{arr_n: n, data: data} = table) do
    next = n + 1

    case data do
      %{^next => v} ->
        arr = :array.set(next - 1, v, table.arr)
        table = drop_hash_key(%{table | arr: arr, arr_n: next}, next)
        absorb_from_hash(table)

      _ ->
        table
    end
  end

  defp insert_hash(%__MODULE__{data: data, order: order, order_tail: order_tail, dead: dead} = table, key, value) do
    # A positive-integer hash key sits adjacent to the probe range and can
    # change #t once a contiguous fill reaches it, so invalidate the cache.
    # Non-integer keys (strings/floats/bools) never affect #t — leave it.
    table = if positive_int?(key), do: %{table | border: :dirty}, else: table

    cond do
      Map.has_key?(dead, key) ->
        merged_order = order ++ Enum.reverse(order_tail)
        new_order = Enum.reject(merged_order, &(&1 === key))

        %{
          table
          | data: Map.put(data, key, value),
            order: new_order,
            order_tail: [key],
            order_index: nil,
            order_arr: nil,
            dead: Map.delete(dead, key)
        }

      Map.has_key?(data, key) ->
        %{table | data: Map.put(data, key, value)}

      true ->
        %{
          table
          | data: Map.put(data, key, value),
            order_tail: [key | order_tail],
            order_index: nil,
            order_arr: nil
        }
    end
  end

  defp delete(%__MODULE__{arr_n: n} = table, key) when is_integer(key) and key >= 1 and key <= n do
    # Clear the slot but keep `arr_n` as the high-water bound of the
    # allocated array region. Leaving the nil hole (rather than shrinking
    # the border) preserves two invariants that iteration relies on:
    #
    #   * `next_entry/2` can still tell a former array key (`key <= arr_n`,
    #     resume in-array) from a key that was never present (`key > arr_n`,
    #     raise "invalid key to next") — even after the tail is cleared
    #     mid-iteration, as Lua 5.3 §6.1 requires.
    #   * Re-inserting the same key (`t[k] = nil; t[k] = v`) lands back in
    #     the same array slot, so the dense ordering is stable.
    #
    # `length/1` derives the Lua border by scanning to the first hole, so a
    # cleared tail still reports the correct `#t`.
    #
    # Cached border: a cached integer border always equals arr_n (see
    # put_array clause 1), and this clause only fires for in-array keys
    # (1 <= key <= arr_n == border). Punching a hole anywhere in that range can
    # only shorten the dense run reachable from 1, so every in-array delete
    # invalidates a cached border. Drop straight to :dirty; length/1 rescans
    # lazily on the next read.
    %{table | arr: :array.set(key - 1, nil, table.arr), border: :dirty}
  end

  defp delete(%__MODULE__{data: data, dead: dead} = table, key) do
    if Map.has_key?(data, key) do
      # Removing a positive-integer hash key can lower #t; recompute. Other
      # keys never affect the sequence border.
      border = if positive_int?(key), do: :dirty, else: table.border
      %{table | data: Map.delete(data, key), dead: Map.put(dead, key, true), border: border}
    else
      table
    end
  end

  defp drop_hash_key(%__MODULE__{data: data, order: order, order_tail: tail} = table, key) do
    %{
      table
      | data: Map.delete(data, key),
        order: Enum.reject(order, &(&1 === key)),
        order_tail: Enum.reject(tail, &(&1 === key)),
        order_index: nil,
        order_arr: nil
    }
  end

  @doc """
  Writes `value` into a raw data map under `key` (hash-only, no array).

  Retained for callers that operate on a bare hash map with no surrounding
  struct. Integer keys still land in the map here.
  """
  @spec put_data(map(), term(), term()) :: map()
  def put_data(data, key, value) do
    key = normalize_key(key)

    case value do
      nil -> Map.delete(data, key)
      _ -> Map.put(data, key, value)
    end
  end

  @doc """
  Applies an ordered list of `{key, value}` writes, equivalent to folding
  `put/3` left-to-right but rebuilding the struct once.
  """
  @spec put_many(t(), [{term(), term()}]) :: t()
  def put_many(%__MODULE__{} = table, []), do: table

  def put_many(%__MODULE__{} = table, pairs) when is_list(pairs) do
    Enum.reduce(pairs, table, fn {k, v}, acc -> put(acc, k, v) end)
  end

  @doc """
  Overwrites the array sequence `1..length(values)` with `values` in a single
  pass, leaving the hash portion untouched.

  When `values` exactly covers the current array border (the table.sort
  write-back case — sort replaces the sequence with a permutation of itself),
  the array is rebuilt with one `:array.from_list/2` instead of N individual
  `:array.set/3` calls, each of which path-copies the functional array. The
  values are a non-nil permutation of an existing sequence, so the border is
  exactly their count. Falls back to `put_many/2` for any other shape.
  """
  @spec replace_sequence(t(), [term()]) :: t()
  def replace_sequence(%__MODULE__{arr_n: n} = table, values) do
    if Kernel.length(values) == n do
      %{table | arr: :array.from_list(values, nil), border: n}
    else
      put_many(table, Enum.with_index(values, fn v, i -> {i + 1, v} end))
    end
  end

  @doc """
  Normalizes a table key per Lua 5.3 §3.4.11.
  """
  @spec normalize_key(term()) :: term()
  def normalize_key(key) when is_float(key) do
    cond do
      key != key ->
        key

      key == trunc(key) and key >= -9_223_372_036_854_775_808.0 and key <= 9_223_372_036_854_775_807.0 ->
        trunc(key)

      true ->
        key
    end
  end

  def normalize_key(key), do: key

  @doc """
  Returns true if a key is invalid for use in a table assignment.
  """
  @spec invalid_key?(term()) :: boolean()
  def invalid_key?(nil), do: true
  def invalid_key?(key) when is_float(key) and key != key, do: true
  def invalid_key?(_), do: false

  @doc """
  Reads a value from a table by key, split-aware (array then hash).

  This is the struct-level read. Prefer it over the bare-map `get_data/2`
  for any code that has the full `%Table{}`.
  """
  @spec get(t(), term()) :: term()
  def get(%__MODULE__{arr: arr, arr_n: n}, key) when is_integer(key) and key >= 1 and key <= n do
    :array.get(key - 1, arr)
  end

  def get(%__MODULE__{arr: arr, arr_n: n, data: data}, key) when is_float(key) do
    # An integer-valued float (`t[1.0]`) collapses to its integer slot and
    # may live in the dense array; everything else stays in the hash.
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 and k <= n -> :array.get(k - 1, arr)
      k -> Map.get(data, k)
    end
  end

  def get(%__MODULE__{data: data}, key) do
    Map.get(data, key)
  end

  @doc """
  Reads a value from a bare hash data map, applying key normalization.

  Hash-only: does not consult the array. Callers with a full struct should
  use `get/2`.
  """
  @spec get_data(map(), term()) :: term()
  def get_data(data, key), do: Map.get(data, normalize_key(key))

  @doc """
  Returns true when the table (array or hash) has a live entry for `key`.
  """
  @spec has_key?(t(), term()) :: boolean()
  def has_key?(%__MODULE__{arr: arr, arr_n: n}, key) when is_integer(key) and key >= 1 and key <= n do
    :array.get(key - 1, arr) != nil
  end

  def has_key?(%__MODULE__{arr: arr, arr_n: n, data: data}, key) when is_float(key) do
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 and k <= n -> :array.get(k - 1, arr) != nil
      k -> Map.has_key?(data, k)
    end
  end

  def has_key?(%__MODULE__{data: data}, key) do
    Map.has_key?(data, key)
  end

  @doc """
  Returns true when the bare hash data map has an entry for `key`.
  """
  @spec has_data?(map(), term()) :: boolean()
  def has_data?(data, key), do: Map.has_key?(data, normalize_key(key))

  @doc """
  Returns the Lua sequence length: the largest `n` with keys `1..n` present.

  The contiguous array border gives this for free; we only fall back to
  probing the hash for sparse integers parked beyond the border.
  """
  @spec length(t()) :: non_neg_integer()
  def length(%__MODULE__{border: border}) when is_integer(border), do: border

  def length(%__MODULE__{arr_n: 0, data: data}), do: probe_hash_length(data, 1, 0)

  def length(%__MODULE__{arr: arr, arr_n: n, data: data}) do
    case array_border(arr, n) do
      # No hole inside the array region — the border may extend into sparse
      # integer keys parked in the hash, so keep probing from arr_n + 1.
      ^n -> probe_hash_length(data, n + 1, n)
      # A nil hole inside the array region caps the border early.
      border -> border
    end
  end

  # Returns the largest `b <= n` such that array slots `1..b` are all
  # non-nil (i.e. the Lua sequence border within the dense region). A
  # full region returns `n`; a leading hole at slot 1 returns 0.
  defp array_border(_arr, 0), do: 0

  defp array_border(arr, n) do
    array_border(arr, 1, n)
  end

  defp array_border(arr, i, n) when i <= n do
    case :array.get(i - 1, arr) do
      nil -> i - 1
      _ -> array_border(arr, i + 1, n)
    end
  end

  defp array_border(_arr, _i, n), do: n

  defp probe_hash_length(data, probe, last) do
    if Map.has_key?(data, probe) do
      probe_hash_length(data, probe + 1, probe)
    else
      last
    end
  end

  @doc """
  Materializes the full table contents (array + hash) as a single flat map.

  Used by code paths that genuinely need the whole table as a map (decode,
  display, `string.gsub` replacement lookups). Walks the array once.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{arr: :undefined, data: data}), do: data

  def to_map(%__MODULE__{arr: arr, arr_n: n, data: data}) do
    Enum.reduce(1..n//1, data, fn i, acc ->
      case :array.get(i - 1, arr) do
        nil -> acc
        v -> Map.put(acc, i, v)
      end
    end)
  end

  @doc """
  Returns the next key/value pair in iteration order after `key`.

  Array keys (`1..arr_n`) iterate first in index order, then hash keys in
  insertion order. Mirrors the old `next_entry/2` contract: returns `{k, v}`,
  `nil` at the end, or `:invalid_key` when `key` is absent everywhere.
  """
  @spec next_entry(t(), term()) :: {term(), term()} | nil | :invalid_key
  def next_entry(%__MODULE__{} = table, nil) do
    case first_array_live(table, 1) do
      nil -> first_hash_live(table)
      pair -> pair
    end
  end

  def next_entry(%__MODULE__{arr_n: n} = table, key) do
    key = normalize_key(key)

    if is_integer(key) and key >= 1 and key <= n do
      case first_array_live(table, key + 1) do
        nil -> first_hash_live(table)
        pair -> pair
      end
    else
      next_hash_after(table, key)
    end
  end

  # First live hash entry at or after the start of iteration order. Uses the
  # memoized order array when present (built once per iteration in
  # `flush_order/1`); otherwise falls back to the structural `order` list.
  defp first_hash_live(%__MODULE__{order_arr: nil} = table) do
    first_live(merged_order(table), table.data)
  end

  defp first_hash_live(%__MODULE__{order_arr: arr, data: data}) do
    first_live_from(arr, 0, data)
  end

  # First live hash entry strictly after `key`. With the memo present this is
  # an O(1) index lookup plus a forward scan to the next live key; the scan
  # only ever advances, so a full `pairs` loop is O(n) total. Without the memo
  # it falls back to the linear `advance_past/2` scan.
  defp next_hash_after(%__MODULE__{order_index: nil} = table, key) do
    case advance_past(merged_order(table), key) do
      :not_found -> :invalid_key
      remaining -> first_live(remaining, table.data)
    end
  end

  defp next_hash_after(%__MODULE__{order_index: index, order_arr: arr, data: data}, key) do
    case Map.get(index, key) do
      nil -> :invalid_key
      idx -> first_live_from(arr, idx + 1, data)
    end
  end

  defp first_live_from(arr, idx, data) do
    if idx >= :array.size(arr) do
      nil
    else
      k = :array.get(idx, arr)

      case Map.fetch(data, k) do
        {:ok, v} -> {k, v}
        :error -> first_live_from(arr, idx + 1, data)
      end
    end
  end

  defp first_array_live(%__MODULE__{arr_n: n}, i) when i > n, do: nil

  defp first_array_live(%__MODULE__{arr: arr} = table, i) do
    case :array.get(i - 1, arr) do
      nil -> first_array_live(table, i + 1)
      v -> {i, v}
    end
  end

  @doc """
  Flushes any pending `order_tail` appends into `order` and (re)builds the
  O(1)-lookup iteration memo (`order_arr`/`order_index`). Idempotent.

  Called once at the start of a `pairs`/`next` iteration so the per-step
  hash advance is an index lookup rather than a linear scan. The memo is
  invalidated (set to `nil`) by any structural mutation of `order`, so a
  flush with an already-empty tail still rebuilds it when missing.
  """
  @spec flush_order(t()) :: t()
  def flush_order(%__MODULE__{order_tail: [], order_index: index} = table) when index != nil do
    table
  end

  def flush_order(%__MODULE__{order: order, order_tail: tail} = table) do
    flushed = order ++ Enum.reverse(tail)
    index = flushed |> Enum.with_index() |> Map.new()
    %{table | order: flushed, order_tail: [], order_arr: :array.from_list(flushed), order_index: index}
  end

  defp merged_order(%__MODULE__{order: order, order_tail: []}), do: order
  defp merged_order(%__MODULE__{order: order, order_tail: tail}), do: order ++ Enum.reverse(tail)

  defp advance_past([], _key), do: :not_found

  defp advance_past([k | rest], key) do
    if k === key do
      rest
    else
      advance_past(rest, key)
    end
  end

  defp first_live([], _data), do: nil

  defp first_live([k | rest], data) do
    case Map.fetch(data, k) do
      {:ok, v} -> {k, v}
      :error -> first_live(rest, data)
    end
  end
end
