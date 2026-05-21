defmodule Lua.VM.Table do
  @moduledoc """
  Lua table data structure.

  Hybrid storage matching the layout PUC-Lua uses internally: a tuple-backed
  array part for the contiguous integer prefix `1..array_len`, plus a map for
  every other key (non-integer, negative, sparse, or beyond the prefix). The
  two parts are disjoint — a key lives in exactly one of them.

  Iteration order tracking (the `order`/`order_tail`/`dead` machinery)
  applies only to the hash part. The array part walks `1..array_len` in
  numerical order before the hash part is consulted.

  ## Why split

  For the common case `t = {1, 2, 3, ...}` or `for i = 1, n do t[i] = ...`:

    * Integer-indexed reads in range become `elem/2`. No map hashing, no
      `normalize_key` call.
    * Sequential integer writes promote into the tuple, so the per-key
      `Map.put` + `order_tail` cons + `dead` check pipeline only fires
      for the hash-side keys.
    * `#t` becomes O(1) when the hash part doesn't extend the contiguous
      prefix (the overwhelmingly common case).

  Tables used as records (`{name = "x", id = 1}`) carry no array part and
  pay no extra cost.

  ## Dead-key tracking

  Lua 5.3 §6.1 says iteration with `pairs` is well-defined when the body
  clears existing fields (`t[k] = nil`). The reference implementation
  preserves the iteration sequence by leaving cleared keys reachable in
  the hash chain (marked `TDEADKEY`) so the next call to `next(t, k)` can
  still find the entry that follows `k`.

  We mirror that behavior on the hash part with two pieces of state:

    * `order` — keys in the order they were first assigned a value. Live
      and dead keys both appear; assigning a fresh value to a previously
      dead key moves it to the end (it counts as a new insertion).
    * `dead` — a `key => true` map of keys that have been assigned `nil`.
      Their slot in `order` is preserved so `next(t, k)` can locate the
      slot, but `data` no longer contains the key, so the key is reported
      as absent to readers.

  The array part has no dead-key concept — `t[i] = nil` for `i == array_len`
  shrinks the array. `t[i] = nil` for `1 <= i < array_len` would split the
  array (PUC-Lua handles this by demoting the tail into the hash part); we
  conservatively demote the tail to keep iteration consistent.

  All mutations should flow through `put/3` (or `put_data/3` for code that
  only has access to the underlying data map and doesn't care about the
  iteration ordering).
  """

  defstruct array: {},
            array_len: 0,
            array_has_holes: false,
            data: %{},
            order: [],
            order_tail: [],
            dead: %{},
            metatable: nil

  @type t :: %__MODULE__{
          array: tuple(),
          array_len: non_neg_integer(),
          array_has_holes: boolean(),
          data: %{optional(term()) => term()},
          order: list(term()),
          order_tail: list(term()),
          dead: %{optional(term()) => true},
          metatable: {:tref, non_neg_integer()} | nil
        }

  # `order` is the "stable" iteration list (insertion order, oldest first) for
  # the hash part. `order_tail` accumulates **newly inserted** hash-side keys
  # in reverse-insertion order (newest first). Writes prepend onto `order_tail`
  # in O(1); reads via `next_entry/2` flush the tail into `order` lazily so the
  # iteration protocol still sees a single ordered list. This avoids the O(n)
  # per write that `order ++ [key]` was costing the table_build microbenchmark.

  @doc """
  Builds a table struct from a plain data map.

  Splits the incoming map into the array prefix (`1..N` for the largest N
  where every integer key in that range is present) and a hash part for
  everything else. Stdlib tables with all-string keys (math, string, ...)
  produce an empty array part and route entirely through the hash side.

  `order` is derived from the hash-side keys — Erlang maps surface their
  keys in a deterministic order, so callers that pass us a literal data
  map get a sensible iteration order with no extra effort.
  """
  @spec from_data(map()) :: t()
  def from_data(data) when is_map(data) do
    {array, array_len, hash} = split_from_map(data)
    %__MODULE__{array: array, array_len: array_len, data: hash, order: Map.keys(hash)}
  end

  defp split_from_map(data) do
    case Map.get(data, 1) do
      nil ->
        {{}, 0, data}

      first ->
        # Walk 1..N building the array part. Stop at the first missing key.
        # We mutate `hash` by dropping each promoted key.
        collect_array_prefix([first], 1, Map.delete(data, 1))
    end
  end

  defp collect_array_prefix(acc, n, hash) do
    next_key = n + 1

    case Map.get(hash, next_key) do
      nil ->
        {List.to_tuple(Enum.reverse(acc)), n, hash}

      v ->
        collect_array_prefix([v | acc], next_key, Map.delete(hash, next_key))
    end
  end

  @doc """
  Replaces the data map wholesale, rebuilding the array/hash split and
  clearing `dead`.

  Used by stdlib operations that rewrite the entire table contents (e.g.
  `table.sort` shuffles every integer key). After this call, iteration
  order reflects the new map layout.
  """
  @spec replace_data(t(), map()) :: t()
  def replace_data(%__MODULE__{} = table, data) when is_map(data) do
    {array, array_len, hash} = split_from_map(data)

    %{
      table
      | array: array,
        array_len: array_len,
        array_has_holes: false,
        data: hash,
        order: Map.keys(hash),
        order_tail: [],
        dead: %{}
    }
  end

  @doc """
  Reads `t[key]`, consulting both the array and hash parts.

  Honors Lua key normalization (integer-valued floats collapse to integers
  per §3.4.11). Returns `nil` when the key is absent.

  This is the read-path equivalent of `put/3` — callers that previously
  inspected `table.data` directly should use this helper so the array
  part is consulted.
  """
  @spec get(t(), term()) :: term()
  def get(%__MODULE__{array: array, array_len: array_len, data: data}, key) do
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 and k <= array_len ->
        # Array slot may be nil (a hole left by `t[k] = nil`); nil means
        # the key is absent, matching the hash-side semantics.
        :erlang.element(k, array)

      k ->
        Map.get(data, k)
    end
  end

  @doc """
  Returns `true` when `t[key]` is present (i.e. would return a non-nil value).
  """
  @spec has?(t(), term()) :: boolean()
  def has?(%__MODULE__{array: array, array_len: array_len, data: data}, key) do
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 and k <= array_len ->
        # Nil array slots are holes — treat them as absent for `t[k] ~= nil`
        # purposes (matches Lua semantics: nil-valued keys are not in the
        # table).
        :erlang.element(k, array) != nil

      k ->
        Map.has_key?(data, k)
    end
  end

  @doc """
  Returns the table's `#t` sequence length.

  When the hash part doesn't extend the contiguous prefix, this is O(1) —
  the array part's length is authoritative. Otherwise falls back to a
  walk through the hash side to find the largest contiguous N.
  """
  @spec length(t()) :: non_neg_integer()
  def length(%__MODULE__{array_len: 0, data: data}) when map_size(data) == 0, do: 0

  def length(%__MODULE__{array_has_holes: false, array_len: n, data: data}) do
    # Fast path: no holes have ever been introduced. The array is a solid
    # 1..n run, so the border is at least n. If the hash side extends the
    # contiguous prefix, walk through it.
    if map_size(data) == 0 do
      n
    else
      length_with_hash(n, data)
    end
  end

  def length(%__MODULE__{array: array, array_len: n, data: data}) do
    # `#t` per Lua 5.3 §3.4.7: a "border" — an index where t[i] != nil
    # and t[i + 1] == nil. We scan the array part forward to find the
    # first nil hole, then optionally extend into the hash part if the
    # array runs to completion without a hole.
    case first_array_hole(array, n) do
      ^n when map_size(data) > 0 ->
        # Array runs full to n; check whether n+1, n+2, ... live in hash.
        length_with_hash(n, data)

      border ->
        border
    end
  end

  # Returns the index of the last non-nil cell that forms a contiguous
  # prefix `1..i`. If `array[1]` is nil, returns 0. If every cell is
  # non-nil, returns `n`.
  defp first_array_hole(_array, 0), do: 0

  defp first_array_hole(array, n) do
    scan_array_for_border(array, 1, n)
  end

  defp scan_array_for_border(_array, i, n) when i > n, do: n

  defp scan_array_for_border(array, i, n) do
    case :erlang.element(i, array) do
      nil -> i - 1
      _ -> scan_array_for_border(array, i + 1, n)
    end
  end

  defp length_with_hash(n, data) do
    next = n + 1

    if Map.has_key?(data, next) do
      length_with_hash(next, data)
    else
      n
    end
  end

  @doc """
  Writes `value` into the table under `key`, honoring Lua semantics:

    * Assigning `nil` removes the key. For the array part, this either
      shrinks `array_len` (when `key == array_len`) or demotes the tail
      of the array past `key` into the hash part with dead-key markers.
      For the hash part, the key is marked dead in `order` if previously
      live.
    * Any other value is stored. Integer keys equal to `array_len + 1`
      append to the array part (and absorb any contiguous run that has
      been parked in the hash part). Integer keys in `[1, array_len]`
      update the array in place. Everything else goes through the hash
      part.

  Used by every code path that mutates table contents (`set_table`,
  `set_field`, `set_list`, `rawset`, `table.insert`, etc.) so the
  array/hash invariants stay consistent.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = table, key, value) do
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 ->
        put_integer(table, k, value)

      k ->
        put_hash(table, k, value)
    end
  end

  # ── integer-key write path ─────────────────────────────────────────────────

  # `t[k] = v` for `1 <= k <= array_len`: update the slot in place. We allow
  # `nil` to occupy slots as hole markers — that matches PUC-Lua's `LUA_TNIL`
  # array semantics and is what `#t` was already observing in this VM. The
  # array_len stays as a high-water mark for the contiguous-prefix length;
  # iteration and `#t` both treat nil slots as absent.
  defp put_integer(%__MODULE__{array_len: n, array: array} = table, k, value) when k <= n do
    new_array = :erlang.setelement(k, array, value)

    cond do
      is_nil(value) and k == n ->
        # Tail write of nil — the slot at position n is now nil. We could
        # eagerly shrink array_len here, but Lua's `#t` semantics only
        # require the border be ANY boundary, and keeping the high-water
        # mark stable avoids hysteresis on rapidly-toggling clears.
        # Flag holes so `length/1` falls back to the scan.
        %{table | array: new_array, array_has_holes: true}

      is_nil(value) ->
        # Mid-array nil — definitely a hole now.
        %{table | array: new_array, array_has_holes: true}

      true ->
        # Non-nil overwrite of an existing slot. Holes (if any) elsewhere
        # are unchanged.
        %{table | array: new_array}
    end
  end

  defp put_integer(%__MODULE__{array_len: n, array: array} = table, k, value) when k == n + 1 do
    cond do
      is_nil(value) ->
        # Lua: assigning nil to an absent key is a no-op.
        table

      tuple_size(array) > n ->
        # Capacity available beyond the logical length — bump the high-water
        # mark, no tuple reallocation needed. This is the amortized-O(1)
        # path that makes sequential `t[i] = ...` loops fast.
        appended = %{table | array: :erlang.setelement(n + 1, array, value), array_len: n + 1}

        if map_size(table.data) == 0 do
          appended
        else
          absorb_from_hash(appended)
        end

      true ->
        # Tuple is at logical capacity. Grow exponentially (PUC-Lua doubles
        # the array part on overflow) so amortized cost stays O(1) per
        # append. Pre-fill new slots with nil so subsequent in-range reads
        # return nil cleanly.
        new_array = grow_array(array, n + 1, value)
        appended = %{table | array: new_array, array_len: n + 1}

        if map_size(table.data) == 0 do
          appended
        else
          absorb_from_hash(appended)
        end
    end
  end

  defp put_integer(table, k, value) do
    # Out of array range (either > array_len + 1, or array part is empty
    # and k > 1). Goes to hash side.
    put_hash(table, k, value)
  end

  # Grow `array` so it has enough capacity for slot `k`. New capacity is
  # max(2 * current_size, k, 4) — the 4-floor avoids tiny growths for the
  # very first append, and doubling beyond that keeps amortized append
  # O(1). New cells are nil; the caller assigns `value` to slot `k`.
  defp grow_array(array, k, value) do
    current = tuple_size(array)
    new_size = next_capacity(max(current, 1), k)
    extension = List.duplicate(nil, new_size - current)

    grown =
      array
      |> Tuple.to_list()
      |> Kernel.++(extension)
      |> List.to_tuple()

    :erlang.setelement(k, grown, value)
  end

  defp next_capacity(current, target) when current >= target, do: current
  defp next_capacity(current, target), do: next_capacity(max(current * 2, 4), target)

  defp absorb_from_hash(%__MODULE__{array_len: n, data: data} = table) do
    next_key = n + 1

    case Map.get(data, next_key) do
      nil ->
        table

      v ->
        new_data = Map.delete(data, next_key)
        # Drop the key from order/order_tail too.
        new_order = drop_key_from_lists(table.order, next_key)
        new_tail = drop_key_from_lists(table.order_tail, next_key)
        new_dead = Map.delete(table.dead, next_key)

        appended = %{
          table
          | array: :erlang.append_element(table.array, v),
            array_len: next_key,
            data: new_data,
            order: new_order,
            order_tail: new_tail,
            dead: new_dead
        }

        absorb_from_hash(appended)
    end
  end

  defp drop_key_from_lists([], _key), do: []
  defp drop_key_from_lists([k | rest], key) when k === key, do: rest
  defp drop_key_from_lists([k | rest], key), do: [k | drop_key_from_lists(rest, key)]

  # ── hash-key write path ────────────────────────────────────────────────────

  defp put_hash(table, key, nil), do: hash_delete(table, key)
  defp put_hash(table, key, value), do: hash_insert(table, key, value)

  defp hash_insert(%__MODULE__{data: data, order: order, order_tail: order_tail, dead: dead} = table, key, value) do
    cond do
      Map.has_key?(dead, key) ->
        # Reviving a dead key — drop from order/tail and re-append so the
        # observable insertion order matches a fresh assignment.
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
        # Brand-new key. Prepend onto `order_tail` (O(1)).
        %{table | data: Map.put(data, key, value), order_tail: [key | order_tail]}
    end
  end

  defp hash_delete(%__MODULE__{data: data, dead: dead} = table, key) do
    if Map.has_key?(data, key) do
      %{table | data: Map.delete(data, key), dead: Map.put(dead, key, true)}
    else
      # Already absent (never present, or already cleared) — no-op.
      table
    end
  end

  @doc """
  Writes `value` into a raw data map under `key`.

  Lower-level than `put/3`: operates only on the underlying hash map, with
  no awareness of the array part, `order`, or `dead`. Use this when you
  have a hash data map but no surrounding `Table` struct (e.g. while
  folding through `set_list` intermediate state). Prefer `put/3` whenever
  you have the full struct.
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

  Operates on a bare data map — does NOT consult the array part. Use
  `get/2` when you have the full struct and want both parts checked.
  """
  @spec get_data(map(), term()) :: term()
  def get_data(data, key), do: Map.get(data, normalize_key(key))

  @doc """
  Returns true when the table data map has an entry for the given key
  after normalization.

  Operates on a bare data map — does NOT consult the array part. Use
  `has?/2` when you have the full struct and want both parts checked.
  """
  @spec has_data?(map(), term()) :: boolean()
  def has_data?(data, key), do: Map.has_key?(data, normalize_key(key))

  @doc """
  Returns the next key/value pair in iteration order after `key`.

  Walks the array part first (`1..array_len`), then the hash part's
  `order` list, advancing through any dead-key slots until a live entry
  is found. Returns `{k, v}` for the next live entry, or `nil` when
  iteration is complete.

  When `key` is `nil`, returns the first live entry (or `nil` if the
  table is empty/all-dead).

  When `key` is non-nil and is not present in either part, returns the
  sentinel `:invalid_key` so the caller can raise the user-facing
  "invalid key to 'next'" error per Lua 5.3 §6.1.
  """
  @spec next_entry(t(), term()) :: {term(), term()} | nil | :invalid_key
  def next_entry(%__MODULE__{array_len: n, array: array} = table, nil) do
    case first_live_in_array(array, 1, n) do
      {_k, _v} = entry -> entry
      :none -> first_hash_entry(table)
    end
  end

  def next_entry(%__MODULE__{array_len: n, array: array} = table, key) do
    case normalize_key(key) do
      k when is_integer(k) and k >= 1 and k <= n ->
        # Iteration is mid-array. Lua spec: `next(t, k)` returns the entry
        # after `k` in iteration order, regardless of whether `t[k]` is
        # still set. So even if `t[k] = nil` cleared the slot during
        # iteration, we still advance past `k` to find the next live
        # array slot, then fall through to the hash side.
        case first_live_in_array(array, k + 1, n) do
          {_k, _v} = entry -> entry
          :none -> first_hash_entry(table)
        end

      k when is_integer(k) and k > n ->
        # The caller is iterating past the array boundary. Could be a hash
        # key (integer keys live in hash when they're not contiguous with
        # the array prefix) — try the hash list. If `k` isn't there either,
        # report :invalid_key.
        next_in_hash(table, k)

      k ->
        next_in_hash(table, k)
    end
  end

  defp next_in_hash(%__MODULE__{} = table, k) do
    case advance_past(merged_order(table), k) do
      :not_found ->
        :invalid_key

      remaining ->
        first_live(remaining, table.data)
    end
  end

  defp first_live_in_array(_array, i, n) when i > n, do: :none

  defp first_live_in_array(array, i, n) do
    case :erlang.element(i, array) do
      nil -> first_live_in_array(array, i + 1, n)
      v -> {i, v}
    end
  end

  defp first_hash_entry(%__MODULE__{data: data} = table) do
    first_live(merged_order(table), data)
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

  @doc """
  Returns a plain map containing every live entry in the table.

  Merges the array part (with keys `1..array_len`) into the hash part.
  Used by code paths that need a flat map view of the table (decoding,
  display, stdlib helpers that pre-existing this split).

  Prefer `get/2`, `has?/2`, or `next_entry/2` when possible — those
  avoid materializing the combined map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{array_len: 0, data: data}), do: data

  def to_map(%__MODULE__{array: array, array_len: n, data: data}) do
    Enum.reduce(1..n, data, fn i, acc ->
      case :erlang.element(i, array) do
        nil -> acc
        v -> Map.put(acc, i, v)
      end
    end)
  end

  @doc """
  Returns all live keys currently in the table, array part first then hash.

  Nil-valued slots (holes) in the array part are skipped, matching the
  behavior of `pairs`.
  """
  @spec keys(t()) :: [term()]
  def keys(%__MODULE__{array: array, array_len: n} = table) do
    live_array_keys = collect_live_array_keys(array, 1, n, [])
    hash_keys = merged_order(table) -- Map.keys(table.dead)
    live_array_keys ++ hash_keys
  end

  defp collect_live_array_keys(_array, i, n, acc) when i > n, do: Enum.reverse(acc)

  defp collect_live_array_keys(array, i, n, acc) do
    case :erlang.element(i, array) do
      nil -> collect_live_array_keys(array, i + 1, n, acc)
      _ -> collect_live_array_keys(array, i + 1, n, [i | acc])
    end
  end
end
