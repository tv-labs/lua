defmodule Lua.Compiler.Scope do
  @moduledoc false

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Expr
  alias Lua.AST.Statement

  @type var_ref ::
          {:register, index :: non_neg_integer()}
          | {:captured_local, index :: non_neg_integer()}
          | {:upvalue, index :: non_neg_integer()}
          | {:env_field, env_var_ref :: env_var_ref(), name :: binary()}

  @typedoc """
  How `_ENV` itself is resolved at the use site of a free name. One of
  `{:register, n}` (chunk-level), `{:captured_local, n}` (chunk-level
  `_ENV` captured by a nested function), or `{:upvalue, n}` (most common
  for nested functions).
  """
  @type env_var_ref ::
          {:register, index :: non_neg_integer()}
          | {:captured_local, index :: non_neg_integer()}
          | {:upvalue, index :: non_neg_integer()}

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
  - var_map: maps each Var node to {:register, n} | {:upvalue, n} | {:env_field, env_var_ref, name}
  - functions: maps each function node to its FunctionScope

  Plan A16 (Lua 5.3 `_ENV` semantics): the chunk reserves register 0 for
  an implicit `_ENV` local, holding `_G`. Free names compile to
  `_ENV.name` field access; nested functions capture `_ENV` via the
  standard upvalue chain.
  """
  @spec resolve(Chunk.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def resolve(%Chunk{block: block}, _opts \\ []) do
    state = %State{}

    # The chunk itself is an implicit vararg function (Lua 5.3 spec)
    func_scope = %FunctionScope{is_vararg: true}
    state = %{state | current_function: :chunk, functions: %{chunk: func_scope}}

    # Bind `_ENV` as a chunk-level local at register 0. Codegen emits a
    # `load_env` instruction at the start of the chunk to populate this
    # register; user code (and any free-name reference resolved through
    # `_ENV`) sees it as a normal local. User-level `_ENV = ...` rebinds
    # this register and redirects subsequent free-name access.
    #
    # We mark `_ENV` as captured up-front so all chunk-level `_ENV` access
    # routes through the open-upvalue cell. This keeps reads/writes
    # consistent regardless of whether a nested function actually captures
    # `_ENV` later in the chunk: the executor's open-upvalue mechanism
    # falls back to direct register access until a cell is allocated.
    state = %{
      state
      | locals: %{"_ENV" => 0},
        next_register: 1,
        captured_locals: MapSet.put(state.captured_locals, "_ENV")
    }

    # Track max_register accordingly
    func_scope = %{func_scope | max_register: 1}
    state = %{state | functions: Map.put(state.functions, :chunk, func_scope)}

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

  # Per Lua 5.3 §3.3.4, each control-flow block (then/else, while/repeat
  # body, for body) is its own lexical scope: locals declared inside it
  # must not leak past the block's end.
  # Resolve `fun` in a fresh block scope, restoring the enclosing scope's
  # locals and register watermark afterward, and stash the pre-block register
  # watermark under `key` so codegen can emit a `:close_upvalues` at the
  # block's exit (Lua 5.3 §3.4.10). Any open-upvalue cell over a register the
  # block's locals occupied must be detached when the block ends, so a later
  # sibling block reusing the same slot does not read or write through the
  # stale cell.
  defp with_block_scope(state, key, fun) do
    saved_locals = state.locals
    saved_next_register = state.next_register

    state = %{state | var_map: Map.put(state.var_map, key, saved_next_register)}
    state = fun.(state)

    %{state | locals: saved_locals, next_register: saved_next_register}
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

  defp resolve_statement(%Statement.Local{names: names, values: values} = local_stmt, state) do
    # First, resolve all the value expressions with current scope
    state = Enum.reduce(values, state, &resolve_expr/2)

    # Then assign registers to the new local variables
    {state, reg_list} =
      Enum.reduce(names, {state, []}, fn name, {state, regs} ->
        reg = state.next_register
        # Add to locals map (current scope visibility)
        state = %{state | locals: Map.put(state.locals, name, reg)}
        # Update next_register
        state = %{state | next_register: reg + 1}
        {state, regs ++ [reg]}
      end)

    # Store per-statement register assignments in var_map so codegen can find them
    state = %{state | var_map: Map.put(state.var_map, local_stmt, reg_list)}

    # Update max_register in current function scope
    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    state
  end

  defp resolve_statement(
         %Statement.If{condition: condition, then_block: then_block, elseifs: elseifs, else_block: else_block},
         state
       ) do
    # Per Lua 5.3 §3.3.4, each branch of an `if` is its own block, so locals
    # declared inside it do not leak past `end`.
    state = resolve_expr(condition, state)
    state = with_block_scope(state, {:block_close_threshold, then_block}, &resolve_block(then_block, &1))

    state =
      Enum.reduce(elseifs, state, fn {elseif_cond, elseif_block}, state ->
        state = resolve_expr(elseif_cond, state)
        with_block_scope(state, {:block_close_threshold, elseif_block}, &resolve_block(elseif_block, &1))
      end)

    if else_block do
      with_block_scope(state, {:block_close_threshold, else_block}, &resolve_block(else_block, &1))
    else
      state
    end
  end

  defp resolve_statement(%Statement.While{condition: condition, body: body}, state) do
    state = resolve_expr(condition, state)
    with_block_scope(state, {:block_close_threshold, body}, &resolve_block(body, &1))
  end

  defp resolve_statement(%Statement.Repeat{body: body, condition: condition}, state) do
    # In Lua, repeat-until's condition is part of the body's scope so it can
    # reference locals declared inside the loop. Restore the outer scope only
    # after the condition has been resolved.
    saved_locals = state.locals
    saved_next_register = state.next_register

    state = %{state | var_map: Map.put(state.var_map, {:block_close_threshold, body}, saved_next_register)}
    state = resolve_block(body, state)
    state = resolve_expr(condition, state)

    %{state | locals: saved_locals, next_register: saved_next_register}
  end

  defp resolve_statement(
         %Statement.ForNum{var: var, start: start_expr, limit: limit_expr, step: step_expr, body: body} = for_stmt,
         state
       ) do
    state = resolve_expr(start_expr, state)
    state = resolve_expr(limit_expr, state)
    state = if step_expr, do: resolve_expr(step_expr, state), else: state

    saved_locals = state.locals
    saved_next_register = state.next_register

    loop_var_reg = state.next_register
    state = %{state | locals: Map.put(state.locals, var, loop_var_reg)}
    state = %{state | next_register: loop_var_reg + 3}

    state = %{state | var_map: Map.put(state.var_map, {:for_num_var_reg, for_stmt}, loop_var_reg)}

    # Stash the post-loop-variable watermark so codegen can close body-local
    # cells at the tail of each iteration. The loop variable's own cells are
    # swept by the per-iteration close in the executor's continuation handler
    # (keyed on `loop_var_reg`); the body-tail close handles inner-block
    # locals declared above this watermark.
    state = %{state | var_map: Map.put(state.var_map, {:block_close_threshold, body}, state.next_register)}

    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    state = resolve_block(body, state)

    %{state | locals: saved_locals, next_register: saved_next_register}
  end

  defp resolve_statement(
         %Statement.FuncDecl{name: [single_name], params: params, body: body, is_method: is_method} = decl,
         state
       )
       when is_binary(single_name) do
    # Per Lua 5.3 §3.4.11: `function name(...) end` is sugar for `name = function(...) end`.
    # Resolve the target name through scope (local → captured_local → upvalue → global)
    # and store the result in var_map so codegen can emit the right store instruction.
    all_params = if is_method, do: ["self" | params], else: params

    # Resolve the target name (local/upvalue/global) and store under a namespaced
    # key so resolve_function_scope cannot overwrite it (it always stores the
    # function-scope reference under the bare `decl` key).
    target_key = {:func_decl_target, decl}

    # Process the function body FIRST. The body may capture this scope's
    # locals (including `_ENV`); processing it before tagging the assignment
    # target ensures `state.captured_locals` is fully populated when we
    # decide between `{:register, _}` vs `{:captured_local, _}` for the
    # target (and for `_ENV` when the target is a free name).
    state = resolve_function_scope(decl, all_params, body, state)

    case Map.get(state.locals, single_name) do
      nil ->
        case find_upvalue(single_name, state.parent_scopes, state) do
          {:ok, upvalue_index, state} ->
            %{state | var_map: Map.put(state.var_map, target_key, {:upvalue, upvalue_index})}

          :not_found ->
            # Free name: compile as `_ENV.name = ...`
            {env_ref, state} = resolve_env_ref(state)
            %{state | var_map: Map.put(state.var_map, target_key, {:env_field, env_ref, single_name})}
        end

      reg ->
        if MapSet.member?(state.captured_locals, single_name) do
          %{state | var_map: Map.put(state.var_map, target_key, {:captured_local, reg})}
        else
          %{state | var_map: Map.put(state.var_map, target_key, {:register, reg})}
        end
    end
  end

  defp resolve_statement(
         %Statement.FuncDecl{name: [first | rest], params: params, body: body, is_method: is_method} = decl,
         state
       )
       when rest != [] do
    # Multi-name FuncDecl (`function a.b.c(...)` / `function a:m(...)`).
    # Process the body FIRST so `state.captured_locals` reflects whether
    # the head name is captured by the function body (e.g. `a.y = ...`
    # inside `function a:m`). `resolve_function_scope` restores the outer
    # scope's `locals` and merges newly-captured names into
    # `captured_locals`, so the post-call state matches what the head
    # lookup needs. Mirrors the single-name FuncDecl ordering above.
    all_params = if is_method, do: ["self" | params], else: params
    state = resolve_function_scope(decl, all_params, body, state)

    resolve_func_decl_head(first, decl, state)
  end

  defp resolve_statement(%Statement.FuncDecl{params: params, body: body, is_method: is_method} = decl, state) do
    all_params = if is_method, do: ["self" | params], else: params
    resolve_function_scope(decl, all_params, body, state)
  end

  defp resolve_statement(%Statement.CallStmt{call: call}, state) do
    resolve_expr(call, state)
  end

  defp resolve_statement(%Statement.ForIn{vars: vars, iterators: iterators, body: body} = for_stmt, state) do
    state = Enum.reduce(iterators, state, &resolve_expr/2)

    saved_locals = state.locals
    saved_next_register = state.next_register

    {state, _, var_regs} =
      Enum.reduce(vars, {state, state.next_register, []}, fn name, {state, reg, acc} ->
        state = %{state | locals: Map.put(state.locals, name, reg)}
        state = %{state | next_register: reg + 1}
        {state, reg + 1, [reg | acc]}
      end)

    state = %{state | var_map: Map.put(state.var_map, {:for_in_var_regs, for_stmt}, Enum.reverse(var_regs))}

    # Stash the post-loop-variable watermark so codegen can close body-local
    # cells at the tail of each iteration. The loop variables' own cells are
    # swept by the per-iteration close in the executor's continuation handler.
    state = %{state | var_map: Map.put(state.var_map, {:block_close_threshold, body}, state.next_register)}

    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    state = resolve_block(body, state)

    %{state | locals: saved_locals, next_register: saved_next_register}
  end

  defp resolve_statement(%Statement.LocalFunc{name: name, params: params, body: body} = local_func, state) do
    # First, allocate a register for the local function name
    reg = state.next_register
    state = %{state | locals: Map.put(state.locals, name, reg)}
    state = %{state | next_register: reg + 1}

    # Store the register assignment in var_map so codegen can find the correct
    # register even when the same name is redefined later (e.g., two `local function f`)
    state = %{state | var_map: Map.put(state.var_map, {:local_func_reg, local_func}, reg)}

    # Update max_register in current function scope
    func_scope = state.functions[state.current_function]
    func_scope = %{func_scope | max_register: max(func_scope.max_register, state.next_register)}
    state = %{state | functions: Map.put(state.functions, state.current_function, func_scope)}

    # Then resolve the function body scope (like FuncDecl)
    resolve_function_scope(local_func, params, body, state)
  end

  defp resolve_statement(%Statement.Do{body: body} = do_stmt, state) do
    # Do blocks create a new scope - save and restore locals/next_register
    saved_locals = state.locals
    saved_next_register = state.next_register

    state = resolve_block(body, state)

    # Stash the pre-block register watermark so codegen can emit a
    # `:close_upvalues` at block exit. Per Lua 5.3 §3.4.10 any open-upvalue
    # cell over a register that goes out of scope here must be detached so
    # the next statement that reuses the slot does not read or write through
    # the stale cell — see locals.lua:148-154 for the symptom this prevents.
    state = %{state | var_map: Map.put(state.var_map, {:do_close_threshold, do_stmt}, saved_next_register)}

    # Restore outer scope (inner locals don't leak out)
    %{state | locals: saved_locals, next_register: saved_next_register}
  end

  # For now, stub out other statement types - we'll implement them incrementally
  defp resolve_statement(_stmt, state), do: state

  defp resolve_expr(%Expr.Number{}, state), do: state
  defp resolve_expr(%Expr.String{}, state), do: state
  defp resolve_expr(%Expr.Bool{}, state), do: state
  defp resolve_expr(%Expr.Nil{}, state), do: state

  defp resolve_expr(%Expr.Var{name: name} = var, state) do
    # Check if this variable is a local, upvalue, or free name (=> _ENV.name)
    case Map.get(state.locals, name) do
      nil ->
        # Not a local — check parent scopes for upvalue
        case find_upvalue(name, state.parent_scopes, state) do
          {:ok, upvalue_index, state} ->
            %{state | var_map: Map.put(state.var_map, var, {:upvalue, upvalue_index})}

          :not_found ->
            # Free name: compile as `_ENV.name`
            {env_ref, state} = resolve_env_ref(state)
            %{state | var_map: Map.put(state.var_map, var, {:env_field, env_ref, name})}
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

  defp resolve_expr(%Expr.Paren{inner: inner}, state), do: resolve_expr(inner, state)

  # For now, stub out other expression types
  defp resolve_expr(_expr, state), do: state

  # Resolve the head name of a multi-name FuncDecl the same way an
  # `Expr.Var` read is resolved. The result is stashed under
  # `{:func_decl_head, decl}` so codegen can replay the lookup without
  # re-reading the post-block locals snapshot.
  defp resolve_func_decl_head(name, decl, state) do
    key = {:func_decl_head, decl}

    case Map.get(state.locals, name) do
      nil ->
        case find_upvalue(name, state.parent_scopes, state) do
          {:ok, upvalue_index, state} ->
            %{state | var_map: Map.put(state.var_map, key, {:upvalue, upvalue_index})}

          :not_found ->
            {env_ref, state} = resolve_env_ref(state)
            %{state | var_map: Map.put(state.var_map, key, {:env_field, env_ref, name})}
        end

      reg ->
        if MapSet.member?(state.captured_locals, name) do
          %{state | var_map: Map.put(state.var_map, key, {:captured_local, reg})}
        else
          %{state | var_map: Map.put(state.var_map, key, {:register, reg})}
        end
    end
  end

  # Walk up the scope chain to find a variable and create upvalue descriptors.
  # Delegates to ensure_upvalue which handles multi-level nesting correctly.
  defp find_upvalue(name, parent_scopes, state) do
    ensure_upvalue(name, state.current_function, parent_scopes, state)
  end

  # Resolve `_ENV` as a `var_ref` (`{:register, n}` | `{:captured_local, n}` |
  # `{:upvalue, n}`) usable for env-field access at the current scope.
  #
  # `_ENV` is bound as register 0 of the chunk and inherits to nested
  # functions via the standard upvalue chain. This helper handles all three
  # cases: chunk-level register, chunk-level captured-by-nested-fn, and
  # nested-function upvalue.
  defp resolve_env_ref(state) do
    case Map.get(state.locals, "_ENV") do
      nil ->
        # Not a local in the current function — must be reachable as an
        # upvalue (the chunk binds `_ENV` as a local at register 0; nested
        # functions inherit through `find_upvalue`).
        case find_upvalue("_ENV", state.parent_scopes, state) do
          {:ok, upvalue_index, state} ->
            {{:upvalue, upvalue_index}, state}

          :not_found ->
            # Should never happen: the chunk always defines `_ENV`.
            raise "Internal error: _ENV not found in scope chain (Plan A16)"
        end

      reg ->
        # Local `_ENV` (chunk register 0, or `local _ENV = ...` in an inner
        # function). If a nested closure has captured this register, the
        # current function reads it through the open-upvalue cell so writes
        # remain visible.
        if MapSet.member?(state.captured_locals, "_ENV") do
          {{:captured_local, reg}, state}
        else
          {{:register, reg}, state}
        end
    end
  end

  # ensure_upvalue(name, for_function, parent_scopes, state)
  # Ensures that for_function has an upvalue for the variable `name`.
  # Walks up parent_scopes to find the variable, creating upvalue descriptors
  # in each intermediate function as needed.
  defp ensure_upvalue(_name, _for_function, [], _state), do: :not_found

  defp ensure_upvalue(name, for_function, [parent | rest], state) do
    case Map.get(parent.locals, name) do
      nil ->
        # Not in this parent's locals — check if the parent already has it as an upvalue
        parent_func = state.functions[parent.function]

        case Enum.find_index(parent_func.upvalue_descriptors, fn
               {:parent_local, _, n} -> n == name
               {:parent_upvalue, _, n} -> n == name
             end) do
          nil ->
            # Parent doesn't have it. Recurse to ensure the parent gets it first.
            case ensure_upvalue(name, parent.function, rest, state) do
              {:ok, _parent_uv_index, state} ->
                # Parent now has an upvalue for this variable. Find its index.
                parent_func = state.functions[parent.function]

                parent_uv_index =
                  Enum.find_index(parent_func.upvalue_descriptors, fn
                    {:parent_local, _, n} -> n == name
                    {:parent_upvalue, _, n} -> n == name
                  end)

                # Add to for_function referencing parent's upvalue
                func = state.functions[for_function]
                uv_index = length(func.upvalue_descriptors)

                func = %{
                  func
                  | upvalue_descriptors:
                      func.upvalue_descriptors ++
                        [{:parent_upvalue, parent_uv_index, name}]
                }

                state = %{state | functions: Map.put(state.functions, for_function, func)}
                {:ok, uv_index, state}

              :not_found ->
                :not_found
            end

          parent_uv_index ->
            # Parent already has this upvalue — add reference in for_function
            func = state.functions[for_function]
            uv_index = length(func.upvalue_descriptors)

            func = %{
              func
              | upvalue_descriptors:
                  func.upvalue_descriptors ++
                    [{:parent_upvalue, parent_uv_index, name}]
            }

            state = %{state | functions: Map.put(state.functions, for_function, func)}
            {:ok, uv_index, state}
        end

      reg ->
        # Found in parent's locals — add {:parent_local, reg, name} to for_function
        func = state.functions[for_function]
        uv_index = length(func.upvalue_descriptors)

        func = %{
          func
          | upvalue_descriptors: func.upvalue_descriptors ++ [{:parent_local, reg, name}]
        }

        state = %{state | functions: Map.put(state.functions, for_function, func)}
        {:ok, uv_index, state}
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

    # Every nested function inherits `_ENV` as an upvalue. Resolve it
    # eagerly before the body is processed so codegen paths that read
    # free names through `_ENV` can rely on the upvalue being present
    # with a known index. A parameter or `local _ENV = ...` still takes
    # precedence for free-name resolution, which is the correct Lua 5.3
    # behaviour.
    state =
      if Map.has_key?(state.locals, "_ENV") do
        # `_ENV` is a parameter — no upvalue allocation needed at this entry
        # point. Inner local rebinds will be handled by normal scope rules.
        state
      else
        case find_upvalue("_ENV", state.parent_scopes, state) do
          {:ok, _index, state} -> state
          # Should not happen: chunk always defines `_ENV` as a local.
          :not_found -> state
        end
      end

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
      |> MapSet.new(fn {:parent_local, _reg, name} -> name end)

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
