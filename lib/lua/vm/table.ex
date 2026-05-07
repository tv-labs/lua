defmodule Lua.VM.Table do
  @moduledoc """
  Lua table data structure.

  A single Elixir map backing both array and hash portions.
  Keys and values are VM values (numbers, strings, booleans, `{:tref, id}`, etc.).
  Integer keys use 1-based indexing per Lua convention.
  """

  defstruct data: %{},
            metatable: nil

  @type t :: %__MODULE__{
          data: %{optional(term()) => term()},
          metatable: {:tref, non_neg_integer()} | nil
        }

  @doc """
  Writes `value` into a table data map under `key`, honoring Lua semantics:

    * Assigning `nil` removes the key (Lua spec §3.4.11 — fields with `nil`
      values are absent from the table).
    * Any other value is stored normally.

  Used by every code path that mutates table contents (`set_table`,
  `set_field`, `set_list`, `rawset`) so the "store-as-delete" rule is
  applied uniformly.
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
  """
  @spec get_data(map(), term()) :: term()
  def get_data(data, key), do: Map.get(data, normalize_key(key))

  @doc """
  Returns true when the table data map has an entry for the given key
  after normalization.
  """
  @spec has_data?(map(), term()) :: boolean()
  def has_data?(data, key), do: Map.has_key?(data, normalize_key(key))
end
