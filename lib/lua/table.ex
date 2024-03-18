defmodule Lua.Table do
  @moduledoc """
  In Lua, [tables](https://www.lua.org/pil/2.5.html) are the fundamental datastructure,
  which are used both as associative arrays (maps), and arrays (lists).

  `Lua.Table` provides some utilities for working with Lua tables when passed back to
  Elixir.
  """

  @doc """
  Converts a Lua table into a list. Assumes that the
  table is correctly ordered.

      iex> Lua.Table.as_list([{1, "a"}, {2, "b"}, {3, "c"}])
      ["a", "b", "c"]

  To ensure the list is ordered, you can pass the `:sort` options

      iex> Lua.Table.as_list([{2, "b"}, {1, "a"}, {3, "c"}])
      ["b", "a", "c"]

      iex> Lua.Table.as_list([{2, "b"}, {1, "a"}, {3, "c"}], sort: true)
      ["a", "b", "c"]

  """
  def as_list(values, opts \\ []) do
    opts = Keyword.validate!(opts, sort: false)

    sorter =
      if Keyword.fetch!(opts, :sort) do
        &Enum.sort/1
      else
        &Function.identity/1
      end

    values
    |> sorter.()
    |> Enum.map(fn {_, v} -> v end)
  end

  @doc """
  Converts a Lua table into a map

      iex> Lua.Table.as_map([{"a", 1}, {"b", 2}])
      %{"a" => 1, "b" => 2}
  """
  def as_map(values) do
    Map.new(values)
  end

  @doc """
  Converts a Lua table into more "native" feeling lists and
  maps, deeply traversing any sub-tables.

  It will use the heuristic that maps with integer keys starting
  as 1 will be auto-cast into lists

      iex> Lua.Table.deep_cast([{"a", 1}, {"b", [{1, 3}, {2, 4}]}])
      %{"a" => 1, "b" => [3, 4]}
  """
  def deep_cast(value) do
    case value do
      [{1, _val} | _rest] = list ->
        Enum.map(list, fn
          {_, v} when is_list(v) -> deep_cast(v)
          {_, v} -> v
        end)

      map ->
        Map.new(map, fn
          {k, v} when is_list(v) -> {k, deep_cast(v)}
          {k, v} -> {k, v}
        end)
    end
  end
end
