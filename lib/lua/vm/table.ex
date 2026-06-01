defmodule Lua.VM.Table do
  @moduledoc """
  Lua table data structure.

  A single Elixir map backing both array and hash portions, plus a list of
  keys in insertion order and a key-set of "dead" keys whose values were
  cleared during iteration.

  Keys and values are VM values (numbers, strings, booleans, `{:tref, id}`,
  etc.). Integer keys use 1-based indexing per Lua convention.

  ## Dead-key tracking

  Lua 5.3 §6.1 says iteration with `pairs` is well-defined when the body
  clears existing fields (`t[k] = nil`). The reference implementation
  preserves the iteration sequence by leaving cleared keys reachable in
  the hash chain (marked `TDEADKEY`) so the next call to `next(t, k)` can
  still find the entry that follows `k`.

  We mirror that behavior with two pieces of state:

    * `order` — keys in the order they were first assigned a value. Live
      and dead keys both appear; assigning a fresh value to a previously
      dead key moves it to the end (it counts as a new insertion).
    * `dead` — a `key => true` map of keys that have been assigned `nil`.
      Their slot in `order` is preserved so `next(t, k)` can locate the
      slot, but `data` no longer contains the key, so the key is reported
      as absent to readers. (We use a plain map rather than `MapSet` here
      so dialyzer can treat the empty default opaquely; the API surface
      is the same — `Map.has_key?/2`, `Map.put/3`, `Map.delete/2`.)

  All mutations should flow through `put/3` (or `put_data/3` for code that
  only has access to the underlying data map and doesn't care about the
  iteration ordering).
  """

  defstruct data: %{},
            order: [],
            order_tail: [],
            dead: %{},
            metatable: nil

  @type t :: %__MODULE__{
          data: %{optional(term()) => term()},
          order: list(term()),
          order_tail: list(term()),
          dead: %{optional(term()) => true},
          metatable: {:tref, non_neg_integer()} | nil
        }

  # `order` is the "stable" iteration list (insertion order, oldest first).
  # `order_tail` accumulates **newly inserted** keys in reverse-insertion
  # order (newest first). Writes prepend onto `order_tail` in O(1); reads
  # via `next_entry/2` flush the tail into `order` lazily so the iteration
  # protocol still sees a single ordered list. This avoids the O(n) per
  # write that `order ++ [key]` was costing the table_build microbenchmark
  # (~25% of its runtime according to tprof).

  @doc """
  Builds a table struct from a plain data map.

  `order` is derived from the data map's key list — Erlang maps surface
  their keys in a deterministic order, so callers that pass us a literal
  data map (e.g. stdlib initialization) get a sensible iteration order
  with no extra effort.
  """
  @spec from_data(map()) :: t()
  def from_data(data) when is_map(data) do
    %__MODULE__{data: data, order: Map.keys(data)}
  end

  @doc """
  Replaces the data map wholesale, rebuilding `order` and clearing `dead`.

  Used by stdlib operations that rewrite the entire table contents (e.g.
  `table.sort` shuffles every integer key). After this call, iteration
  order reflects the new map layout.
  """
  @spec replace_data(t(), map()) :: t()
  def replace_data(%__MODULE__{} = table, data) when is_map(data) do
    %{table | data: data, order: Map.keys(data), dead: %{}}
  end

  @doc """
  Writes `value` into the table under `key`, honoring Lua semantics:

    * Assigning `nil` removes the key from `data` and marks it dead in
      `order` if it was previously live (Lua 5.3 §3.4.11 / §6.1).
    * Any other value is stored normally; if the key was previously
      dead, it is revived and re-appended to `order` so the new
      assignment counts as a fresh insertion.

  Used by every code path that mutates table contents (`set_table`,
  `set_field`, `set_list`, `rawset`, `table.insert`, etc.) so the
  insertion-order invariant stays consistent.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = table, key, value) do
    key = normalize_key(key)

    case value do
      nil -> delete(table, key)
      _ -> insert(table, key, value)
    end
  end

  defp insert(%__MODULE__{data: data, order: order, order_tail: order_tail, dead: dead} = table, key, value) do
    cond do
      Map.has_key?(dead, key) ->
        # Reviving a dead key — drop it from the existing order/tail and
        # re-append so the observable insertion order matches a fresh
        # assignment. We have to flush the tail because the dead key could
        # live in either list.
        merged_order = order ++ Enum.reverse(order_tail)
        new_order = Enum.reject(merged_order, &(&1 === key))

        %{
          table
          | data: Map.put(data, key, value),
            order: new_order,
            order_tail: [key],
            dead: Map.delete(dead, key)
        }

      Map.has_key?(data, key) ->
        # Update of an existing live key — value changes, position stable.
        %{table | data: Map.put(data, key, value)}

      true ->
        # Brand-new key. Prepend onto `order_tail` (O(1)) instead of
        # appending to `order` (O(n)). Lazy flush on iteration.
        %{table | data: Map.put(data, key, value), order_tail: [key | order_tail]}
    end
  end

  defp delete(%__MODULE__{data: data, dead: dead} = table, key) do
    if Map.has_key?(data, key) do
      # Live key being cleared — move to dead set, leave `order` slot
      # in place so any in-flight iteration can still walk past it.
      %{table | data: Map.delete(data, key), dead: Map.put(dead, key, true)}
    else
      # Already absent (never present, or already cleared) — no-op.
      # Per Lua 5.3 §3.4.11, fields with nil values are absent from the
      # table, so storing nil over an absent key is a no-op.
      table
    end
  end

  @doc """
  Writes `value` into a raw data map under `key`.

  Lower-level than `put/3`: operates only on the underlying map, with no
  awareness of `order`/`dead`. Use this when you have a data map but no
  surrounding `Table` struct (e.g. while folding through `set_list`
  intermediate state). Prefer `put/3` whenever you have the full struct.
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
  Applies an ordered list of `{key, value}` writes to the table, producing
  the same result as folding `put/3` over the list left-to-right, but
  rebuilding the `%Table{}` struct only once at the end.

  This is the batch entry point for table-constructor backfill
  (`:set_list`), where a run of consecutive integer keys is written in one
  go. The `order`/`order_tail`/`dead` invariants are maintained identically
  to repeated `put/3`: new keys append (via `order_tail`), existing live
  keys keep their position, dead keys revive to the end, and `nil` values
  clear a live key into `dead`. The win is collapsing `count` struct
  rebuilds into one.

  `pairs` are applied in order; keys are normalized per `normalize_key/1`.
  """
  @spec put_many(t(), [{term(), term()}]) :: t()
  def put_many(%__MODULE__{} = table, []), do: table

  def put_many(%__MODULE__{data: data, order: order, order_tail: order_tail, dead: dead} = table, pairs)
      when is_list(pairs) do
    {data, order, order_tail, dead} = put_many_reduce(pairs, data, order, order_tail, dead)
    %{table | data: data, order: order, order_tail: order_tail, dead: dead}
  end

  defp put_many_reduce([], data, order, order_tail, dead), do: {data, order, order_tail, dead}

  defp put_many_reduce([{key, value} | rest], data, order, order_tail, dead) do
    key = normalize_key(key)

    {data, order, order_tail, dead} =
      case value do
        nil -> delete_acc(data, order, order_tail, dead, key)
        _ -> insert_acc(data, order, order_tail, dead, key, value)
      end

    put_many_reduce(rest, data, order, order_tail, dead)
  end

  # Accumulator-threaded mirrors of `insert/3` and `delete/2`. They make the
  # exact same `order`/`order_tail`/`dead` decisions, but operate on bare
  # fields so `put_many/2` can rebuild the struct just once.
  defp insert_acc(data, order, order_tail, dead, key, value) do
    cond do
      Map.has_key?(dead, key) ->
        merged_order = order ++ Enum.reverse(order_tail)
        new_order = Enum.reject(merged_order, &(&1 === key))
        {Map.put(data, key, value), new_order, [key], Map.delete(dead, key)}

      Map.has_key?(data, key) ->
        {Map.put(data, key, value), order, order_tail, dead}

      true ->
        {Map.put(data, key, value), order, [key | order_tail], dead}
    end
  end

  defp delete_acc(data, order, order_tail, dead, key) do
    if Map.has_key?(data, key) do
      {Map.delete(data, key), order, order_tail, Map.put(dead, key, true)}
    else
      {data, order, order_tail, dead}
    end
  end

  @doc """
  Normalizes a table key per Lua 5.3 §3.4.11.

  Float keys that hold an exact integer value are coerced to integers so
  that `t[1.0]` and `t[1]` refer to the same slot. NaN keys are left as
  floats; callers that disallow NaN keys (`set_table`, `rawset`) detect
  the NaN and raise before reaching the data map.
  """
  @spec normalize_key(term()) :: term()
  def normalize_key(key) when is_float(key) do
    cond do
      # NaN is not equal to itself; leave as-is so the caller can detect it.
      key != key ->
        key

      # Integer-valued floats convert to integers.
      key == trunc(key) and key >= -9_223_372_036_854_775_808.0 and key <= 9_223_372_036_854_775_807.0 ->
        trunc(key)

      true ->
        key
    end
  end

  def normalize_key(key), do: key

  @doc """
  Returns true if a key is invalid for use in a table assignment.

  Per Lua 5.3 §3.4.11 / §6.1, table keys cannot be `nil` or `NaN`.
  Callers should `raise` with the appropriate "table index is nil" /
  "table index is NaN" error message before mutating table data.
  """
  @spec invalid_key?(term()) :: boolean()
  def invalid_key?(nil), do: true
  def invalid_key?(key) when is_float(key) and key != key, do: true
  def invalid_key?(_), do: false

  @doc """
  Reads a value from a table data map, applying Lua key normalization
  (integer-valued floats collapse to integers per §3.4.11).
  """
  @spec get_data(map(), term()) :: term()
  def get_data(data, key), do: Map.get(data, normalize_key(key))

  @doc """
  Returns true when the table data map has an entry for the given key
  after normalization.
  """
  @spec has_data?(map(), term()) :: boolean()
  def has_data?(data, key), do: Map.has_key?(data, normalize_key(key))

  @doc """
  Returns the next key/value pair in iteration order after `key`.

  Walks the table's `order` list to find `key`, then advances through any
  dead-key slots until a live entry is found. Returns `{k, v}` for the
  next live entry, or `nil` when iteration is complete.

  When `key` is `nil`, returns the first live entry (or `nil` if the
  table is empty/all-dead).

  When `key` is non-nil and is not present in `order` at all, returns the
  sentinel `:invalid_key` so the caller can raise the user-facing
  "invalid key to 'next'" error per Lua 5.3 §6.1.
  """
  @spec next_entry(t(), term()) :: {term(), term()} | nil | :invalid_key
  def next_entry(%__MODULE__{} = table, nil) do
    first_live(merged_order(table), table.data)
  end

  def next_entry(%__MODULE__{} = table, key) do
    key = normalize_key(key)

    case advance_past(merged_order(table), key) do
      :not_found ->
        # The key was never in this table, even as a dead slot. Lua spec
        # §6.1 requires raising for this — caller does the raising.
        :invalid_key

      remaining ->
        first_live(remaining, table.data)
    end
  end

  @doc """
  Flushes any pending appends in `order_tail` into `order`.

  Idempotent: a table with an empty tail is returned unchanged. Used by
  callers that want to amortize the cost of repeated `next_entry` calls
  (e.g. `lua_next` in the stdlib, which iterates via repeated calls).
  """
  @spec flush_order(t()) :: t()
  def flush_order(%__MODULE__{order_tail: []} = table), do: table

  def flush_order(%__MODULE__{order: order, order_tail: tail} = table) do
    %{table | order: order ++ Enum.reverse(tail), order_tail: []}
  end

  # Internal: produces the conceptual full insertion order without
  # mutating the struct. Used by read paths that don't (or can't) write
  # back a flushed version.
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
