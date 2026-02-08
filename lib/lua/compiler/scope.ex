defmodule Lua.Compiler.Scope do
  @moduledoc """
  Variable scope resolution for the Lua compiler.

  Assigns registers to local variables and identifies upvalues and globals.
  """

  alias Lua.AST.{Chunk, Block, Statement, Expr}

  @type var_ref ::
          {:register, index :: non_neg_integer()}
          | {:captured_local, index :: non_neg_integer()}
          | {:upvalue, index :: non_neg_integer()}
          | {:global, name :: binary()}

  defmodule FunctionScope do
    @moduledoc false
    defstruct max_register: 0,
              param_count: 0,
              is_vararg: false,
              upvalue_descriptors: [],
              locals: %{}

    @type t :: %__MODULE__{
            max_register: non_neg_integer(),
            param_count: non_neg_integer(),
            is_vararg: boolean(),
            upvalue_descriptors: [term()],
            locals: %{optional(binary()) => non_neg_integer()}
          }
  end

  defmodule State do
    @moduledoc false
    defstruct var_map: %{},
              functions: %{},
              current_function: nil,
              next_register: 0,
              locals: %{},
              parent_scopes: [],
              captured_locals: MapSet.new()

    @type t :: %__MODULE__{
            var_map: %{optional(term()) => Lua.Compiler.Scope.var_ref()},
            functions: %{optional(term()) => Lua.Compiler.Scope.FunctionScope.t()},
            current_function: term(),
            next_register: non_neg_integer(),
            locals: %{optional(binary()) => non_neg_integer()},
            parent_scopes: [%{locals: map(), function: term()}],
            captured_locals: MapSet.t()
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

    # Save chunk locals for codegen
    func_scope = state.functions[:chunk]
    func_scope = %{func_scope | locals: state.locals}
    state = %{state | functions: Map.put(state.functions, :chunk, func_scope)}

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
    # Then resolve all target expressions (variables, table fields, index expressions)
    Enum.reduce(targets, state, fn
      %Expr.Index{table: table, key: key}, state ->
        state = resolve_expr(table, state)
        resolve_expr(key, state)

      %Expr.Property{table: table}, state ->
        resolve_expr(table, state)

      target, state ->
        resolve_expr(target, state)
    end)
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

  defp resolve_statement(
         %Statement.If{
           condition: condition,
           then_block: then_block,
           elseifs: elseifs,
           else_block: else_block
         },
         state
       ) do
    # Resolve the main condition
    state = resolve_expr(condition, state)

    # Resolve the then block
    state = resolve_block(then_block, state)

    # Resolve all elseif clauses
    state =
      Enum.reduce(elseifs, state, fn {elseif_cond, elseif_block}, state ->
        state = resolve_expr(elseif_cond, state)
        resolve_block(elseif_block, state)
      end)

    # Resolve the else block if present
    if else_block do
      resolve_block(else_block, state)
    else
      state
    end
  end

  defp resolve_statement(%Statement.While{condition: condition, body: body}, state) do
    # Resolve the condition
    state = resolve_expr(condition, state)
    # Resolve the body
    resolve_block(body, state)
  end

  defp resolve_statement(%Statement.Repeat{body: body, condition: condition}, state) do
    # Resolve the body first (in Lua, the condition can reference variables declared in the body)
    state = resolve_block(body, state)
    # Resolve the condition
    resolve_expr(condition, state)
  end

  defp resolve_statement(
         %Statement.ForNum{
           var: var,
           start: start_expr,
           limit: limit_expr,
           step: step_expr,
           body: body
         },
         state
       ) do
    # Resolve start, limit, and step expressions with current scope
    state = resolve_expr(start_expr, state)
    state = resolve_expr(limit_expr, state)
    state = if step_expr, do: resolve_expr(step_expr, state), else: state

    # The loop variable is a local within the loop body
    # Assign it a register
    loop_var_reg = state.next_register
    state = %{state | locals: Map.put(state.locals, var, loop_var_reg)}
    state = %{state | next_register: loop_var_reg + 1}

    # Update max_register
    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    # Resolve the body with the loop variable in scope
    state = resolve_block(body, state)

    # Remove the loop variable from scope after the loop
    # (In real implementation, we'd need scope stack management, but for now this is fine)
    state
  end

  defp resolve_statement(%Statement.FuncDecl{params: params, body: body, is_method: is_method} = decl, state) do
    all_params = if is_method, do: ["self" | params], else: params
    resolve_function_scope(decl, all_params, body, state)
  end

  defp resolve_statement(%Statement.CallStmt{call: call}, state) do
    resolve_expr(call, state)
  end

  defp resolve_statement(
         %Statement.ForIn{vars: vars, iterators: iterators, body: body},
         state
       ) do
    # Resolve iterator expressions with current scope
    state = Enum.reduce(iterators, state, &resolve_expr/2)

    # Assign registers for loop variables (same pattern as ForNum)
    {state, _} =
      Enum.reduce(vars, {state, state.next_register}, fn name, {state, reg} ->
        state = %{state | locals: Map.put(state.locals, name, reg)}
        state = %{state | next_register: reg + 1}
        {state, reg + 1}
      end)

    # Update max_register
    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    # Resolve the body with loop variables in scope
    resolve_block(body, state)
  end

  # For now, stub out other statement types - we'll implement them incrementally
  defp resolve_statement(_stmt, state), do: state

  defp resolve_expr(%Expr.Number{}, state), do: state
  defp resolve_expr(%Expr.String{}, state), do: state
  defp resolve_expr(%Expr.Bool{}, state), do: state
  defp resolve_expr(%Expr.Nil{}, state), do: state

  defp resolve_expr(%Expr.Var{name: name} = var, state) do
    # Check if this variable is a local, upvalue, or global
    case Map.get(state.locals, name) do
      nil ->
        # Not a local — check parent scopes for upvalue
        case find_upvalue(name, state.parent_scopes, state) do
          {:ok, upvalue_index, state} ->
            %{state | var_map: Map.put(state.var_map, var, {:upvalue, upvalue_index})}

          :not_found ->
            %{state | var_map: Map.put(state.var_map, var, {:global, name})}
        end

      reg ->
        if MapSet.member?(state.captured_locals, name) do
          %{state | var_map: Map.put(state.var_map, var, {:captured_local, reg})}
        else
          %{state | var_map: Map.put(state.var_map, var, {:register, reg})}
        end
    end
  end

  defp resolve_expr(%Expr.BinOp{left: left, right: right}, state) do
    state = resolve_expr(left, state)
    resolve_expr(right, state)
  end

  defp resolve_expr(%Expr.UnOp{operand: operand}, state) do
    resolve_expr(operand, state)
  end

  defp resolve_expr(%Expr.Function{params: params, body: body} = func, state) do
    resolve_function_scope(func, params, body, state)
  end

  defp resolve_expr(%Expr.Call{func: func, args: args}, state) do
    # Resolve the function expression
    state = resolve_expr(func, state)
    # Resolve all arguments
    Enum.reduce(args, state, &resolve_expr/2)
  end

  defp resolve_expr(%Expr.Table{fields: fields}, state) do
    Enum.reduce(fields, state, fn
      {:list, val_expr}, state ->
        resolve_expr(val_expr, state)

      {:record, key_expr, val_expr}, state ->
        state = resolve_expr(key_expr, state)
        resolve_expr(val_expr, state)
    end)
  end

  defp resolve_expr(%Expr.Index{table: table, key: key}, state) do
    state = resolve_expr(table, state)
    resolve_expr(key, state)
  end

  defp resolve_expr(%Expr.Property{table: table}, state) do
    resolve_expr(table, state)
  end

  defp resolve_expr(%Expr.MethodCall{object: object, args: args}, state) do
    state = resolve_expr(object, state)
    Enum.reduce(args, state, &resolve_expr/2)
  end

  defp resolve_expr(%Expr.Vararg{}, state), do: state

  # For now, stub out other expression types
  defp resolve_expr(_expr, state), do: state

  # Walk up the scope chain to find a variable and create upvalue descriptors
  defp find_upvalue(_name, [], _state), do: :not_found

  defp find_upvalue(name, [parent | rest], state) do
    case Map.get(parent.locals, name) do
      nil ->
        # Not in this parent — check if the parent already has it as an upvalue
        parent_func = state.functions[parent.function]

        case Enum.find_index(parent_func.upvalue_descriptors, fn
               {:parent_local, _, n} -> n == name
               {:parent_upvalue, _, n} -> n == name
             end) do
          nil ->
            # Not in parent's upvalues either — recurse further up
            case find_upvalue(name, rest, state) do
              {:ok, grandparent_upvalue_index, state} ->
                # The variable was found further up. The parent needs an upvalue too.
                parent_func = state.functions[parent.function]
                parent_upvalue_index = length(parent_func.upvalue_descriptors)

                parent_func = %{
                  parent_func
                  | upvalue_descriptors:
                      parent_func.upvalue_descriptors ++
                        [{:parent_upvalue, grandparent_upvalue_index, name}]
                }

                state = %{
                  state
                  | functions: Map.put(state.functions, parent.function, parent_func)
                }

                # Now add upvalue in current function referencing parent's upvalue
                current_func = state.functions[state.current_function]
                cur_upvalue_index = length(current_func.upvalue_descriptors)

                current_func = %{
                  current_func
                  | upvalue_descriptors:
                      current_func.upvalue_descriptors ++
                        [{:parent_upvalue, parent_upvalue_index, name}]
                }

                state = %{
                  state
                  | functions: Map.put(state.functions, state.current_function, current_func)
                }

                {:ok, cur_upvalue_index, state}

              :not_found ->
                :not_found
            end

          parent_upvalue_index ->
            # Parent already has this upvalue — reference it
            current_func = state.functions[state.current_function]
            cur_upvalue_index = length(current_func.upvalue_descriptors)

            current_func = %{
              current_func
              | upvalue_descriptors:
                  current_func.upvalue_descriptors ++
                    [{:parent_upvalue, parent_upvalue_index, name}]
            }

            state = %{
              state
              | functions: Map.put(state.functions, state.current_function, current_func)
            }

            {:ok, cur_upvalue_index, state}
        end

      reg ->
        # Found in parent's locals — create upvalue descriptor
        current_func = state.functions[state.current_function]
        upvalue_index = length(current_func.upvalue_descriptors)

        current_func = %{
          current_func
          | upvalue_descriptors: current_func.upvalue_descriptors ++ [{:parent_local, reg, name}]
        }

        state = %{
          state
          | functions: Map.put(state.functions, state.current_function, current_func)
        }

        {:ok, upvalue_index, state}
    end
  end

  # Shared helper: resolves a function body scope for Expr.Function, Statement.FuncDecl, etc.
  # The `node` is used as the var_map key so codegen can look up the function scope.
  defp resolve_function_scope(node, params, body, state) do
    func_key = make_ref()
    param_count = Enum.count(params, &(&1 != :vararg))
    is_vararg = :vararg in params

    # Save current scope state
    saved_locals = state.locals
    saved_next_register = state.next_register
    saved_function = state.current_function
    saved_parent_scopes = state.parent_scopes
    saved_captured_locals = state.captured_locals

    # Push current scope onto parent_scopes for upvalue resolution
    parent_scope_entry = %{locals: state.locals, function: state.current_function}

    # Start fresh for the function scope
    {param_locals, next_param_reg} =
      params
      |> Enum.reject(&(&1 == :vararg))
      |> Enum.with_index()
      |> Enum.reduce({%{}, 0}, fn {param, index}, {locals, _} ->
        {Map.put(locals, param, index), index + 1}
      end)

    state = %{
      state
      | locals: param_locals,
        next_register: next_param_reg,
        current_function: func_key,
        parent_scopes: [parent_scope_entry | state.parent_scopes],
        captured_locals: MapSet.new()
    }

    func_scope = %FunctionScope{
      max_register: next_param_reg,
      param_count: param_count,
      is_vararg: is_vararg,
      upvalue_descriptors: []
    }

    state = %{state | functions: Map.put(state.functions, func_key, func_scope)}

    # Resolve the function body
    state = resolve_block(body, state)

    # Update max_register and save locals for codegen
    func_scope = state.functions[func_key]

    func_scope = %{
      func_scope
      | max_register: max(func_scope.max_register, state.next_register),
        locals: state.locals
    }

    state = %{state | functions: Map.put(state.functions, func_key, func_scope)}

    # Store the function key in var_map for this node
    state = %{state | var_map: Map.put(state.var_map, node, func_key)}

    # Detect which parent locals this inner function captures
    func_scope_final = state.functions[func_key]

    newly_captured =
      func_scope_final.upvalue_descriptors
      |> Enum.filter(fn {type, _, _} -> type == :parent_local end)
      |> Enum.map(fn {:parent_local, _reg, name} -> name end)
      |> MapSet.new()

    # Restore previous scope, merging newly captured locals
    %{
      state
      | locals: saved_locals,
        next_register: saved_next_register,
        current_function: saved_function,
        parent_scopes: saved_parent_scopes,
        captured_locals: MapSet.union(saved_captured_locals, newly_captured)
    }
  end
end
