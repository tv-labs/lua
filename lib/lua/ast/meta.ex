defmodule Lua.AST.Meta do
  @moduledoc """
  Position tracking metadata for AST nodes.

  Every AST node includes a `meta` field containing position information
  for error reporting, source maps, and debugging.
  """

  @type position :: %{
          line: pos_integer(),
          column: pos_integer(),
          byte_offset: non_neg_integer()
        }

  @type t :: %__MODULE__{
          start: position() | nil,
          end: position() | nil,
          metadata: map()
        }

  defstruct start: nil, end: nil, metadata: %{}

  @doc """
  Creates a new Meta struct with start and end positions.

  ## Examples

      iex> Lua.AST.Meta.new(
      ...>   %{line: 1, column: 1, byte_offset: 0},
      ...>   %{line: 1, column: 5, byte_offset: 4}
      ...> )
      %Lua.AST.Meta{
        start: %{line: 1, column: 1, byte_offset: 0},
        end: %{line: 1, column: 5, byte_offset: 4},
        metadata: %{}
      }
  """
  @spec new(position() | nil, position() | nil, map()) :: t()
  def new(start \\ nil, end_pos \\ nil, metadata \\ %{}) do
    %__MODULE__{start: start, end: end_pos, metadata: metadata}
  end

  @doc """
  Merges two Meta structs, taking the earliest start and latest end.

  Useful when combining multiple nodes into a single parent node.

  ## Examples

      iex> meta1 = Lua.AST.Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 5, byte_offset: 4})
      iex> meta2 = Lua.AST.Meta.new(%{line: 1, column: 7, byte_offset: 6}, %{line: 1, column: 10, byte_offset: 9})
      iex> Lua.AST.Meta.merge(meta1, meta2)
      %Lua.AST.Meta{
        start: %{line: 1, column: 1, byte_offset: 0},
        end: %{line: 1, column: 10, byte_offset: 9},
        metadata: %{}
      }
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{start: start1, end: end1}, %__MODULE__{start: start2, end: end2}) do
    new_start = earliest_position(start1, start2)
    new_end = latest_position(end1, end2)
    new(new_start, new_end)
  end

  @doc """
  Adds metadata to an existing Meta struct.
  """
  @spec add_metadata(t(), atom(), term()) :: t()
  def add_metadata(%__MODULE__{metadata: metadata} = meta, key, value) do
    %{meta | metadata: Map.put(metadata, key, value)}
  end

  # Private helpers

  defp earliest_position(nil, pos), do: pos
  defp earliest_position(pos, nil), do: pos

  defp earliest_position(pos1, pos2) do
    if pos1.byte_offset <= pos2.byte_offset, do: pos1, else: pos2
  end

  defp latest_position(nil, pos), do: pos
  defp latest_position(pos, nil), do: pos

  defp latest_position(pos1, pos2) do
    if pos1.byte_offset >= pos2.byte_offset, do: pos1, else: pos2
  end
end
