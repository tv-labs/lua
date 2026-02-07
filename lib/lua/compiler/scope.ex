defmodule Lua.Compiler.Scope do
  @moduledoc """
  Variable scope resolution for the Lua compiler.

  Assigns registers to local variables and identifies upvalues and globals.
  """

  alias Lua.AST.{Chunk, Block, Statement, Expr}

  @type var_ref ::
          {:register, index :: non_neg_integer()}
          | {:upvalue, index :: non_neg_integer()}
          | {:global, name :: binary()}

  defmodule FunctionScope do
    @moduledoc false
    defstruct max_register: 0,
              param_count: 0,
              is_vararg: false,
              upvalue_descriptors: []
  end

  defmodule State do
    @moduledoc false
    defstruct var_map: %{},
              functions: %{},
              current_function: nil,
              next_register: 0,
              locals: %{}
  end

  @doc """
  Resolves variable scopes in the AST.

  Returns a state containing:
  - var_map: maps each Var node to {:register, n} | {:upvalue, n} | {:global, name}
  - functions: maps each function node to its FunctionScope
  """
  @spec resolve(Chunk.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def resolve(%Chunk{block: block}, _opts \\ []) do
    state = %State{}

    # The chunk itself is an implicit function with no parameters
    func_scope = %FunctionScope{}
    state = %{state | current_function: :chunk, functions: %{chunk: func_scope}}

    # Resolve the chunk body
    state = resolve_block(block, state)

    {:ok, state}
  end

  defp resolve_block(%Block{stmts: stmts}, state) do
    Enum.reduce(stmts, state, &resolve_statement/2)
  end

  defp resolve_statement(%Statement.Return{values: values}, state) do
    Enum.reduce(values, state, &resolve_expr/2)
  end

  # For now, stub out other statement types - we'll implement them incrementally
  defp resolve_statement(_stmt, state), do: state

  defp resolve_expr(%Expr.Number{}, state), do: state
  defp resolve_expr(%Expr.String{}, state), do: state
  defp resolve_expr(%Expr.Bool{}, state), do: state
  defp resolve_expr(%Expr.Nil{}, state), do: state

  # For now, stub out other expression types
  defp resolve_expr(_expr, state), do: state
end
