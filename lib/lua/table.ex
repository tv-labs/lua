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

  To ensure the list is ordered, you can pass the `:sort` option

      iex> Lua.Table.as_list([{2, "b"}, {1, "a"}, {3, "c"}])
      ["b", "a", "c"]

      iex> Lua.Table.as_list([{2, "b"}, {1, "a"}, {3, "c"}], sort: true)
      ["a", "b", "c"]

  """
  def as_list(values, opts \\ []) do
    opts = Keyword.validate!(opts, sort: false)

    sorter =
      if Keyword.fetch!(opts, :sort) do
        &List.keysort(&1, 0)
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
  Converts a Lua table into a string representing
  a Lua table literal

      iex> Lua.Table.as_string([{"a", 1}, {"b", 2}])
      "{a = 1, b = 2}"

  Lists that "look" like Lua tables are treated as lists

      iex> Lua.Table.as_string([{1, "foo"}, {2, "bar"}])
      ~S[{"foo", "bar"}]

  Lists are treated as lists

      iex> Lua.Table.as_string(["a", "b", "c"])
      ~S[{"a", "b", "c"}]

  Regular maps are always treated as tables

      iex> Lua.Table.as_string(%{1 => "foo", "bar" => "baz"})
      ~S<{[1] = "foo", bar = "baz"}>

  ### Options
  * `:formatter` - A 2-arity function used to format values before serialization. The key and value
  are passed as arguments. If there is no key, it will default to `nil`.
  """
  def as_string(table, opts \\ []) do
    opts = Keyword.validate!(opts, formatter: &default_formatter/2)

    "{" <> print_table(table, opts[:formatter]) <> "}"
  end

  defp default_formatter(_key, value), do: value

  # List
  defp print_table([{1, _} | _] = list, formatter) do
    list
    |> Enum.reduce([], fn {key, value}, acc ->
      [acc, if(acc == [], do: "", else: ", "), format_value(key, value, formatter)]
    end)
    |> IO.iodata_to_binary()
  end

  # List
  defp print_table([value | _] = list, formatter) when not is_tuple(value) do
    list
    |> Enum.reduce([], fn value, acc ->
      [acc, if(acc == [], do: "", else: ", "), format_value(nil, value, formatter)]
    end)
    |> IO.iodata_to_binary()
  end

  # Table
  defp print_table(table, formatter) do
    table
    |> Enum.reduce([], fn {key, value}, acc ->
      key_str = format_key(key)
      value_str = format_value(key, value, formatter)

      entry = "#{key_str} = #{value_str}"

      [acc, if(acc == [], do: "", else: ", "), entry]
    end)
    |> then(fn parts ->
      IO.iodata_to_binary(parts)
    end)
  end

  defp valid_identifier?(identifier) do
    regex = ~r/^[[:alpha:]_][[:alnum:]_]*$/u
    Regex.match?(regex, identifier)
  end

  defp format_key(number) when is_number(number) do
    ["[", to_string(number), "]"]
  end

  defp format_key(key) do
    key = to_string(key)

    if valid_identifier?(key) do
      key
    else
      ["[\"", key, "\"]"]
    end
  end

  defp format_value(key, value, formatter) do
    case formatter.(key, value) do
      list when is_list(list) -> "{#{print_table(list, formatter)}}"
      {:userdata, _value} -> inspect("<userdata>")
      true -> "true"
      false -> "false"
      nil -> nil
      number when is_number(number) -> to_string(number)
      other -> inspect(other)
    end
  end

  @doc """
  Converts a Lua table into more "native" feeling lists and
  maps, deeply traversing any sub-tables.

  It uses the heuristic that maps with integer keys starting
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
