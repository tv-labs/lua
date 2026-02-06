defmodule Lua.AST.Meta do
  @moduledoc """
  Position tracking metadata for AST nodes.

  Every AST node includes a `meta` field containing position information
  for error reporting, source maps, and debugging.

  Comments can be attached to AST nodes via the metadata field:
  - `:leading_comments` - Comments before the node
  - `:trailing_comment` - Inline comment after the node on the same line
  """

  @type position :: %{
          line: pos_integer(),
          column: pos_integer(),
          byte_offset: non_neg_integer()
        }

  @type comment :: %{
          type: :single | :multi,
          text: String.t(),
          position: position()
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

  @doc """
  Adds a leading comment to a Meta struct.

  Leading comments appear before the AST node.
  """
  @spec add_leading_comment(t(), comment()) :: t()
  def add_leading_comment(%__MODULE__{metadata: metadata} = meta, comment) do
    existing = Map.get(metadata, :leading_comments, [])
    %{meta | metadata: Map.put(metadata, :leading_comments, existing ++ [comment])}
  end

  @doc """
  Sets the trailing comment for a Meta struct.

  A trailing comment appears on the same line as the AST node.
  Only one trailing comment is allowed per node.
  """
  @spec set_trailing_comment(t(), comment()) :: t()
  def set_trailing_comment(%__MODULE__{metadata: metadata} = meta, comment) do
    %{meta | metadata: Map.put(metadata, :trailing_comment, comment)}
  end

  @doc """
  Gets leading comments from a Meta struct.
  """
  @spec get_leading_comments(t() | nil) :: [comment()]
  def get_leading_comments(nil), do: []

  def get_leading_comments(%__MODULE__{metadata: metadata}) do
    Map.get(metadata, :leading_comments, [])
  end

  @doc """
  Gets trailing comment from a Meta struct.
  """
  @spec get_trailing_comment(t() | nil) :: comment() | nil
  def get_trailing_comment(nil), do: nil

  def get_trailing_comment(%__MODULE__{metadata: metadata}) do
    Map.get(metadata, :trailing_comment)
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
