defmodule Lua.AST.Block do
  @moduledoc """
  Represents a block of statements in Lua.

  A block is a sequence of statements that execute in order.
  Blocks create a new scope for local variables.
  """

  alias Lua.AST.{Meta, Statement}

  @type t :: %__MODULE__{
          stmts: [Statement.t()],
          meta: Meta.t() | nil
        }

  defstruct stmts: [], meta: nil

  @doc """
  Creates a new Block.

  ## Examples

      iex> Lua.AST.Block.new([])
      %Lua.AST.Block{stmts: [], meta: nil}

      iex> Lua.AST.Block.new([], %Lua.AST.Meta{})
      %Lua.AST.Block{stmts: [], meta: %Lua.AST.Meta{start: nil, end: nil, metadata: %{}}}
  """
  @spec new([Statement.t()], Meta.t() | nil) :: t()
  def new(stmts \\ [], meta \\ nil) do
    %__MODULE__{stmts: stmts, meta: meta}
  end
end

defmodule Lua.AST.Chunk do
  @moduledoc """
  Represents the top-level chunk (file or string) in Lua.

  A chunk is essentially a block that represents a complete unit of Lua code.
  """

  alias Lua.AST.{Meta, Block}

  @type t :: %__MODULE__{
          block: Block.t(),
          meta: Meta.t() | nil
        }

  defstruct [:block, :meta]

  @doc """
  Creates a new Chunk.

  ## Examples

      iex> Lua.AST.Chunk.new(%Lua.AST.Block{stmts: []})
      %Lua.AST.Chunk{block: %Lua.AST.Block{stmts: [], meta: nil}, meta: nil}
  """
  @spec new(Block.t(), Meta.t() | nil) :: t()
  def new(block, meta \\ nil) do
    %__MODULE__{block: block, meta: meta}
  end
end
