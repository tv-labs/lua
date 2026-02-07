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

    @type t :: %__MODULE__{
            max_register: non_neg_integer(),
            param_count: non_neg_integer(),
            is_vararg: boolean(),
            upvalue_descriptors: [term()]
          }
  end

  defmodule State do
    @moduledoc false
    defstruct var_map: %{},
              functions: %{},
              current_function: nil,
              next_register: 0,
              locals: %{}

    @type t :: %__MODULE__{
            var_map: %{optional(term()) => Lua.Compiler.Scope.var_ref()},
            functions: %{optional(term()) => Lua.Compiler.Scope.FunctionScope.t()},
            current_function: term(),
            next_register: non_neg_integer(),
            locals: %{optional(binary()) => non_neg_integer()}
          }
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

  defp resolve_statement(%Statement.Assign{targets: targets, values: values}, state) do
    # Resolve all value expressions first
    state = Enum.reduce(values, state, &resolve_expr/2)
    # Then resolve all target expressions (for table assignments, etc.)
    Enum.reduce(targets, state, &resolve_expr/2)
  end

  defp resolve_statement(%Statement.Local{names: names, values: values}, state) do
    # First, resolve all the value expressions with current scope
    state = Enum.reduce(values, state, &resolve_expr/2)

    # Then assign registers to the new local variables
    {state, _} =
      Enum.reduce(names, {state, state.next_register}, fn name, {state, reg} ->
        # Add to locals map
        state = %{state | locals: Map.put(state.locals, name, reg)}
        # Update next_register
        state = %{state | next_register: reg + 1}
        {state, reg + 1}
      end)

    # Update max_register in current function scope
    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    state
  end

  # For now, stub out other statement types - we'll implement them incrementally
  defp resolve_statement(_stmt, state), do: state

  defp resolve_expr(%Expr.Number{}, state), do: state
  defp resolve_expr(%Expr.String{}, state), do: state
  defp resolve_expr(%Expr.Bool{}, state), do: state
  defp resolve_expr(%Expr.Nil{}, state), do: state

  defp resolve_expr(%Expr.Var{name: name} = var, state) do
    # Check if this variable is a local or global
    var_ref =
      case Map.get(state.locals, name) do
        nil -> {:global, name}
        reg -> {:register, reg}
      end

    # Store the classification in var_map using the node itself as key
    %{state | var_map: Map.put(state.var_map, var, var_ref)}
  end

  defp resolve_expr(%Expr.BinOp{left: left, right: right}, state) do
    state = resolve_expr(left, state)
    resolve_expr(right, state)
  end

  defp resolve_expr(%Expr.UnOp{operand: operand}, state) do
    resolve_expr(operand, state)
  end

  # For now, stub out other expression types
  defp resolve_expr(_expr, state), do: state
end
