defmodule Lua.Compiler.Erlang.Opcodes do
  @moduledoc false
  # Per-opcode lowering for `Lua.Compiler.Erlang.Codegen`.
  #
  # Each `lower/2` clause matches one opcode tuple shape and returns
  # either `{:ok, [erlang_form], updated_ctx}` or `:fallback`.
  #
  # Conventions:
  #   - Erlang forms use the abstract syntax tree shape consumed by
  #     `:compile.forms/2`. See `:erl_parse` for the grammar.
  #   - All forms carry a line number for the BEAM debugger.
  #   - Reads from registers use `element(N+1, Regs_curr)`.
  #   - Writes thread a fresh `Regs_n` via `setelement(N+1, Regs_curr, Value)`.
  #   - Writes to state thread a fresh `State_n` likewise.

  alias Lua.Compiler.Erlang.Codegen.Ctx

  # ── Public entry ──────────────────────────────────────────────────

  def lower({:return, base, 1}, %Ctx{} = ctx) do
    line = current_line(ctx)
    value_form = get_register(base, line, ctx)

    # `throw({:b5_return, Results, State})` — wrapped in a `try/catch`
    # at the function level. This is how we model Lua's "return from
    # anywhere in the body" in Erlang's expression-oriented semantics.
    # The overhead of throw/catch is small (sub-microsecond) and pays
    # only when a return is actually executed.
    return_payload =
      {:tuple, line,
       [
         {:atom, line, :b5_return},
         {:cons, line, value_form, {nil, line}},
         {:var, line, ctx.state_var}
       ]}

    throw_form =
      {:call, line, {:atom, line, :throw}, [return_payload]}

    {:ok, [throw_form], ctx}
  end

  def lower({:load_constant, dest, value}, %Ctx{} = ctx) do
    line = current_line(ctx)
    value_form = literal_to_form(value, line)
    {forms, ctx} = set_register(dest, value_form, line, ctx)
    {:ok, forms, ctx}
  end

  def lower({:move, dest, source}, %Ctx{} = ctx) do
    line = current_line(ctx)
    src_form = get_register(source, line, ctx)
    {forms, ctx} = set_register(dest, src_form, line, ctx)
    {:ok, forms, ctx}
  end

  def lower({:source_line, line, _source}, %Ctx{} = ctx) do
    # No runtime effect — just update the codegen-tracked current line
    # so subsequent opcodes' raise sites get the right position.
    {:ok, [], %{ctx | line: line}}
  end

  def lower({:load_env, dest}, %Ctx{} = ctx) do
    line = current_line(ctx)
    # _ENV is `state.g_ref`. Emit `state.g_ref` via `maps:get(g_ref, State_curr)`.
    g_ref_form =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :g_ref}, {:var, line, ctx.state_var}]}

    {forms, ctx} = set_register(dest, g_ref_form, line, ctx)
    {:ok, forms, ctx}
  end

  def lower({:load_boolean, dest, value}, %Ctx{} = ctx) do
    line = current_line(ctx)
    bool = if value, do: true, else: false
    {forms, ctx} = set_register(dest, {:atom, line, bool}, line, ctx)
    {:ok, forms, ctx}
  end

  def lower({:load_nil, dest, count}, %Ctx{} = ctx) when is_integer(count) and count > 0 do
    Enum.reduce_while(0..(count - 1), {:ok, [], ctx}, fn offset, {:ok, acc, ctx} ->
      line = current_line(ctx)
      {f, ctx} = set_register(dest + offset, {:atom, line, nil}, line, ctx)
      {:cont, {:ok, acc ++ f, ctx}}
    end)
  end

  # ── Arithmetic ────────────────────────────────────────────────────
  #
  # Integer fast path inlined as a guard; non-integer falls through to
  # `Lua.VM.Executor.apply_arith_op/6` which handles all coercion +
  # metamethod dispatch.

  def lower({:add, dest, a, b}, ctx), do: arith_binop(:add, dest, a, b, ctx)
  def lower({:subtract, dest, a, b}, ctx), do: arith_binop(:subtract, dest, a, b, ctx)
  def lower({:multiply, dest, a, b}, ctx), do: arith_binop(:multiply, dest, a, b, ctx)
  def lower({:divide, dest, a, b}, ctx), do: arith_binop_slow(:divide, dest, a, b, ctx)
  def lower({:floor_divide, dest, a, b}, ctx), do: arith_binop_slow(:floor_divide, dest, a, b, ctx)
  def lower({:modulo, dest, a, b}, ctx), do: arith_binop_slow(:modulo, dest, a, b, ctx)
  def lower({:power, dest, a, b}, ctx), do: arith_binop_slow(:power, dest, a, b, ctx)
  def lower({:negate, dest, source}, ctx), do: arith_unop(:negate, dest, source, ctx)

  # ── Comparison ────────────────────────────────────────────────────

  # Comparisons with a fast path for two numeric operands (the common
  # case for `if n < 2` and friends). Numbers can't carry metatables in
  # Lua, so the metamethod path is pure overhead when both sides are
  # numbers.
  def lower({:less_than, dest, a, b}, ctx), do: cmp_binop_with_fastpath(:<, :less_than, dest, a, b, ctx)
  def lower({:less_equal, dest, a, b}, ctx), do: cmp_binop_with_fastpath(:"=<", :less_equal, dest, a, b, ctx)
  def lower({:greater_than, dest, a, b}, ctx), do: cmp_binop_with_fastpath(:>, :greater_than, dest, a, b, ctx)
  def lower({:greater_equal, dest, a, b}, ctx), do: cmp_binop_with_fastpath(:>=, :greater_equal, dest, a, b, ctx)
  def lower({:equal, dest, a, b}, ctx), do: cmp_binop(:equal, dest, a, b, ctx)
  def lower({:not_equal, dest, a, b}, ctx), do: cmp_binop(:not_equal, dest, a, b, ctx)

  # ── Upvalues and globals ──────────────────────────────────────────

  def lower({:get_open_upvalue, dest, reg}, %Ctx{} = ctx) do
    line = current_line(ctx)
    # case maps:get(reg, state.open_upvalues, nil) of
    #   nil -> element(reg+1, Regs);
    #   CellRef -> maps:get(CellRef, state.upvalue_cells)
    # end
    open_upvalues_map =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :open_upvalues}, {:var, line, ctx.state_var}]}

    cell_ref_or_nil =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:integer, line, reg}, open_upvalues_map, {:atom, line, nil}]}

    upvalue_cells_map =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :upvalue_cells}, {:var, line, ctx.state_var}]}

    cell_var = fresh_atom(:OpenCell)
    # Fresh local binder for the non-nil clause; scoped to that clause
    # only, so no `unsafe_var` warning.
    ref_var = fresh_atom(:OpenRef)

    case_form =
      {:case, line, {:var, line, cell_var},
       [
         {:clause, line, [{:atom, line, nil}], [], [get_register(reg, line, ctx)]},
         {:clause, line, [{:var, line, ref_var}], [],
          [
            {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
             [{:var, line, ref_var}, upvalue_cells_map]}
          ]}
       ]}

    cell_match = {:match, line, {:var, line, cell_var}, cell_ref_or_nil}

    value_var = fresh_atom(:OpenValue)
    value_match = {:match, line, {:var, line, value_var}, case_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [cell_match, value_match | set_forms], ctx}
  end

  def lower({:get_upvalue, dest, index}, %Ctx{} = ctx) do
    line = current_line(ctx)
    # CellRef = element(Index+1, Upvalues),
    # Value = maps:get(CellRef, maps:get(upvalue_cells, State_curr)),
    # set_register dest <- Value.
    cell_ref =
      {:call, line, {:atom, line, :element}, [{:integer, line, index + 1}, {:var, line, :__Upvalues}]}

    upvalue_cells =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :upvalue_cells}, {:var, line, ctx.state_var}]}

    value_form =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}}, [cell_ref, upvalue_cells]}

    {forms, ctx} = set_register(dest, value_form, line, ctx)
    {:ok, forms, ctx}
  end

  def lower({:get_global, dest, name}, %Ctx{} = ctx) do
    line = current_line(ctx)
    # globals = state.tables[state.g_ref id].data
    # value = globals[name] or nil
    g_ref =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :g_ref}, {:var, line, ctx.state_var}]}

    g_id = {:call, line, {:atom, line, :element}, [{:integer, line, 2}, g_ref]}

    tables =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [{:atom, line, :tables}, {:var, line, ctx.state_var}]}

    g_table = {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}}, [g_id, tables]}

    g_data =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}}, [{:atom, line, :data}, g_table]}

    value =
      {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
       [literal_to_form(name, line), g_data, {:atom, line, nil}]}

    {forms, ctx} = set_register(dest, value, line, ctx)
    {:ok, forms, ctx}
  end

  # `:set_global` mutates state — falls back. Most globals are written
  # via `:set_field` on `_ENV`; pure `:set_global` opcodes are rare in
  # compiled code. B5c picks this up alongside the table opcodes.

  # `:get_field` with a binary literal name — the bread-and-butter
  # global lookup pattern (`_ENV.print`). Inlines the no-metatable
  # fast path from `executor.ex` and falls through to
  # `Executor.index_value/6` for the metatable or non-tref case.
  def lower({:get_field, dest, table_reg, name, name_hint}, %Ctx{} = ctx) when is_binary(name) do
    line = current_line(ctx)
    table_form = get_register(table_reg, line, ctx)

    # Inline fast path:
    #   case TableForm of
    #     {tref, Id} ->
    #         T = maps:get(Id, maps:get(tables, State)),
    #         case maps:get(metatable, T) of
    #             nil ->
    #                 case maps:find(Name, maps:get(data, T)) of
    #                     {ok, V} -> {V, State};
    #                     error -> {nil, State}
    #                 end;
    #             _ -> Executor:index_value(...)  %% metatable case
    #         end;
    #     _ -> Executor:index_value(...)  %% non-tref
    #   end

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    # Slow path (metatable present or non-tref).
    slow_call =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :index_value}},
       [
         table_form,
         literal_to_form(name, line),
         {:var, line, prev_state},
         {:integer, line, line},
         literal_to_form(ctx.proto.source, line),
         term_to_form(name_hint, line)
       ]}

    id_var = fresh_atom(:GFId)
    table_var = fresh_atom(:GFTable)
    data_var = fresh_atom(:GFData)
    value_var = fresh_atom(:GFValue)

    fast_path_body =
      {:block, line,
       [
         # T = maps:get(Id, maps:get(tables, State))
         {:match, line, {:var, line, table_var},
          {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
           [
             {:var, line, id_var},
             {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
              [{:atom, line, :tables}, {:var, line, prev_state}]}
           ]}},
         # case maps:get(metatable, T) of nil -> data lookup; _ -> slow_call end
         {:case, line,
          {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
           [{:atom, line, :metatable}, {:var, line, table_var}]},
          [
            {:clause, line, [{:atom, line, nil}], [],
             [
               # D = maps:get(data, T)
               {:match, line, {:var, line, data_var},
                {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
                 [{:atom, line, :data}, {:var, line, table_var}]}},
               # {maps:get(Name, D, nil), State}
               {:tuple, line,
                [
                  {:call, line, {:remote, line, {:atom, line, :maps}, {:atom, line, :get}},
                   [literal_to_form(name, line), {:var, line, data_var}, {:atom, line, nil}]},
                  {:var, line, prev_state}
                ]}
             ]},
            {:clause, line, [{:var, line, :_}], [], [slow_call]}
          ]}
       ]}

    tref_clause =
      {:clause, line, [{:tuple, line, [{:atom, line, :tref}, {:var, line, id_var}]}], [], [fast_path_body]}

    other_clause = {:clause, line, [{:var, line, :_}], [], [slow_call]}

    case_form = {:case, line, table_form, [tref_clause, other_clause]}

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, case_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  # ── Calls ─────────────────────────────────────────────────────────

  def lower({:call, base, arg_count, 1, _hint}, %Ctx{} = ctx) when is_integer(arg_count) and arg_count >= 0 do
    line = current_line(ctx)
    callable_form = get_register(base, line, ctx)
    args_list = build_args_list(base + 1, arg_count, line, ctx)

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    # Bridge native callbacks the same way the interpreter does:
    # before calling, push the current (line, source) into the process
    # dict via `Lua.VM.Executor.set_call_position/2`. After (or on
    # raise) restore the previous value. The helper exists for both
    # paths to share.
    invoke_call =
      {:call, line,
       {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :call_function_with_position}},
       [
         callable_form,
         args_list,
         {:var, line, prev_state},
         {:integer, line, line},
         literal_to_form(ctx.proto.source, line)
       ]}

    results_var = fresh_atom(:CallResults)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, results_var}, {:var, line, state_var}]}, invoke_call}

    # First-result extraction: `case Results of [V|_] -> V; [] -> nil end`.
    # Lua single-result calls coerce missing results to nil.
    first_var = fresh_atom(:CallResult0)

    first_extract =
      {:case, line, {:var, line, results_var},
       [
         {:clause, line, [{:cons, line, {:var, line, first_var}, {:var, line, :_}}], [], [{:var, line, first_var}]},
         {:clause, line, [{nil, line}], [], [{:atom, line, nil}]}
       ]}

    extract_var = fresh_atom(:CallFirst)

    extract_match = {:match, line, {:var, line, extract_var}, first_extract}

    {set_forms, ctx} = set_register(base, {:var, line, extract_var}, line, ctx)
    {:ok, [match_form, extract_match | set_forms], ctx}
  end

  # ── Conditional branch ────────────────────────────────────────────
  #
  # `:test` is the workhorse for `if`/`while`/`repeat` conditions. We
  # lower it to an Erlang `case` over `Lua.VM.Value.truthy?/1`.
  #
  # Critical: any registers or state mutated inside either branch
  # become "exported" from the case, which Erlang's linter flags as
  # `unsafe_var` unless every clause writes the same set of variables.
  # To keep this safe, the codegen passes a fresh ctx into each branch
  # (forking) and only commits the new state/regs vars from the branch
  # if it falls through (doesn't return). For B5a the simplification:
  # only one branch may "fall through" to the rest of the function;
  # the other must terminate (via throw from `:return`). The
  # `terminates_with_return?/1` check enforces this.

  def lower({:test, reg, then_body, else_body}, %Ctx{} = ctx) do
    line = current_line(ctx)
    reg_form = get_register(reg, line, ctx)

    truthy_call =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Value"}, {:atom, line, :truthy?}}, [reg_form]}

    then_returns? = terminates_with_return?(then_body)
    else_returns? = terminates_with_return?(else_body)

    if then_returns? and (else_body == [] or else_returns?) do
      # Both branches terminate (or else is empty/falls through).
      # Easy case — emit a case where each branch's forms are
      # self-contained.
      lower_terminating_test(line, truthy_call, then_body, else_body, ctx)
    else
      # Mixed shape (one branch returns, the other writes state and
      # falls through to subsequent opcodes). Handling this needs
      # SSA-merge semantics on case branches, which B5a defers.
      :fallback
    end
  end

  def lower({:test_true, reg, then_body}, %Ctx{} = ctx) do
    # Single-branch variant — desugar to :test with empty else.
    lower({:test, reg, then_body, []}, ctx)
  end

  # ── Logical NOT ───────────────────────────────────────────────────

  def lower({:not, dest, source}, %Ctx{} = ctx) do
    line = current_line(ctx)
    src_form = get_register(source, line, ctx)

    truthy_call =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Value"}, {:atom, line, :truthy?}}, [src_form]}

    not_form = {:op, line, :not, truthy_call}
    {forms, ctx} = set_register(dest, not_form, line, ctx)
    {:ok, forms, ctx}
  end

  # ── Fallback ──────────────────────────────────────────────────────

  def lower(_other, _ctx) do
    :fallback
  end

  defp lower_terminating_test(line, truthy_call, then_body, else_body, ctx) do
    # Fork ctx for each branch — fresh state/regs counters inside the
    # branch don't leak out (the branch terminates via throw).
    case lower_branch_body(then_body, ctx) do
      {:ok, then_forms} ->
        case lower_branch_body(else_body, ctx) do
          {:ok, else_forms} ->
            else_clause_body =
              if else_forms == [] do
                # Empty else: fall through to the rest of the function.
                # Emit `ok` as a placeholder expression. The case
                # yields nothing useful; subsequent opcodes don't read
                # from this case.
                [{:atom, line, :ok}]
              else
                else_forms
              end

            case_form =
              {:case, line, truthy_call,
               [
                 {:clause, line, [{:atom, line, true}], [], then_forms},
                 {:clause, line, [{:atom, line, false}], [], else_clause_body}
               ]}

            {:ok, [case_form], ctx}

          :fallback ->
            :fallback
        end

      :fallback ->
        :fallback
    end
  end

  defp lower_branch_body([], _ctx), do: {:ok, []}

  defp lower_branch_body(body, ctx) do
    case Lua.Compiler.Erlang.Codegen.lower_instructions(body, ctx) do
      {:ok, forms, _ctx_after} -> {:ok, forms}
      :fallback -> :fallback
    end
  end

  defp terminates_with_return?([]), do: false

  defp terminates_with_return?(instructions) do
    case List.last(instructions) do
      {:return, _, _} -> true
      :return -> true
      _ -> false
    end
  end

  # ── Arithmetic lowering helpers ───────────────────────────────────

  # Integer-fast-path opcode (add/subtract/multiply). Inlines a case
  # that checks both operands are integers, does the operation
  # directly with `+`/`-`/`*` plus `Numeric.to_signed_int64/1` for
  # wrap-around, and falls through to `apply_arith_op` on any other
  # operand shape.
  defp arith_binop(op, dest, a, b, %Ctx{} = ctx) do
    line = current_line(ctx)
    a_form = get_register(a, line, ctx)
    b_form = get_register(b, line, ctx)

    erl_op =
      case op do
        :add -> :+
        :subtract -> :-
        :multiply -> :*
      end

    # We need to compute the operation. The integer fast path:
    #   case {A, B} of
    #     {Ai, Bi} when is_integer(Ai), is_integer(Bi) ->
    #         {'Elixir.Lua.VM.Numeric':to_signed_int64(Ai OP Bi), State_curr};
    #     _ ->
    #         'Elixir.Lua.VM.Executor':apply_arith_op(Op, A, B, State_curr, Line, Source)
    #   end
    #
    # The case yields `{Value, NewState}`. Match-bind it to fresh vars.

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    int_ai = fresh_atom(:Ai)
    int_bi = fresh_atom(:Bi)

    fast_clause =
      {:clause, line, [{:tuple, line, [{:var, line, int_ai}, {:var, line, int_bi}]}],
       [
         [
           {:call, line, {:atom, line, :is_integer}, [{:var, line, int_ai}]},
           {:call, line, {:atom, line, :is_integer}, [{:var, line, int_bi}]}
         ]
       ],
       [
         {:tuple, line,
          [
            {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Numeric"}, {:atom, line, :to_signed_int64}},
             [{:op, line, erl_op, {:var, line, int_ai}, {:var, line, int_bi}}]},
            {:var, line, prev_state}
          ]}
       ]}

    slow_clause =
      {:clause, line, [{:var, line, :_}], [],
       [
         {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :apply_arith_op}},
          [
            {:atom, line, op},
            a_form,
            b_form,
            {:var, line, prev_state},
            {:integer, line, line},
            literal_to_form(ctx.proto.source, line)
          ]}
       ]}

    case_form =
      {:case, line, {:tuple, line, [a_form, b_form]}, [fast_clause, slow_clause]}

    value_var = fresh_atom(:ArithValue)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, case_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  # Slow-path-only opcode (divide, floor_divide, modulo, power). No
  # integer fast path because the operation requires Lua-specific
  # handling of edge cases (zero divisor, float coercion, etc.).
  # All cases go through `apply_arith_op`.
  defp arith_binop_slow(op, dest, a, b, %Ctx{} = ctx) do
    line = current_line(ctx)
    a_form = get_register(a, line, ctx)
    b_form = get_register(b, line, ctx)

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    call_form =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :apply_arith_op}},
       [
         {:atom, line, op},
         a_form,
         b_form,
         {:var, line, prev_state},
         {:integer, line, line},
         literal_to_form(ctx.proto.source, line)
       ]}

    value_var = fresh_atom(:ArithValue)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, call_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  defp arith_unop(op, dest, source, %Ctx{} = ctx) do
    line = current_line(ctx)
    src_form = get_register(source, line, ctx)

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    call_form =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :apply_unary_op}},
       [
         {:atom, line, op},
         src_form,
         {:var, line, prev_state},
         {:integer, line, line},
         literal_to_form(ctx.proto.source, line)
       ]}

    value_var = fresh_atom(:UnaryValue)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, call_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  # Two-number fast path for less_than/less_equal/greater_than/
  # greater_equal. Bypasses `apply_compare_op` entirely when both
  # operands are integers or floats — numbers don't carry metatables so
  # there's nothing to dispatch.
  defp cmp_binop_with_fastpath(erl_op, op, dest, a, b, %Ctx{} = ctx) do
    line = current_line(ctx)
    a_form = get_register(a, line, ctx)
    b_form = get_register(b, line, ctx)

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    int_ai = fresh_atom(:CmpAi)
    int_bi = fresh_atom(:CmpBi)

    fast_clause =
      {:clause, line, [{:tuple, line, [{:var, line, int_ai}, {:var, line, int_bi}]}],
       [
         [
           {:call, line, {:atom, line, :is_number}, [{:var, line, int_ai}]},
           {:call, line, {:atom, line, :is_number}, [{:var, line, int_bi}]}
         ]
       ],
       [
         {:tuple, line, [{:op, line, erl_op, {:var, line, int_ai}, {:var, line, int_bi}}, {:var, line, prev_state}]}
       ]}

    slow_clause =
      {:clause, line, [{:var, line, :_}], [],
       [
         {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :apply_compare_op}},
          [
            {:atom, line, op},
            a_form,
            b_form,
            {:var, line, prev_state},
            {:integer, line, line},
            literal_to_form(ctx.proto.source, line)
          ]}
       ]}

    case_form = {:case, line, {:tuple, line, [a_form, b_form]}, [fast_clause, slow_clause]}

    value_var = fresh_atom(:CmpValue)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, case_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  defp cmp_binop(op, dest, a, b, %Ctx{} = ctx) do
    line = current_line(ctx)
    a_form = get_register(a, line, ctx)
    b_form = get_register(b, line, ctx)

    {state_var, ctx} = Ctx.fresh_state_var(ctx)
    prev_state = previous_state_atom(ctx.state_var)

    call_form =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.VM.Executor"}, {:atom, line, :apply_compare_op}},
       [
         {:atom, line, op},
         a_form,
         b_form,
         {:var, line, prev_state},
         {:integer, line, line},
         literal_to_form(ctx.proto.source, line)
       ]}

    value_var = fresh_atom(:CmpValue)

    match_form =
      {:match, line, {:tuple, line, [{:var, line, value_var}, {:var, line, state_var}]}, call_form}

    {set_forms, ctx} = set_register(dest, {:var, line, value_var}, line, ctx)
    {:ok, [match_form | set_forms], ctx}
  end

  # Given the current state_var ctx field (already incremented by
  # fresh_state_var), return the atom of the *previous* state version
  # — that's what the slow-path call reads from.
  defp previous_state_atom(:__State), do: :__State

  defp previous_state_atom(state_var_atom) do
    # state vars are State_0, State_1, …; we want the one before
    # ctx.state_var. Since fresh_state_var sets ctx.state_var to the
    # new name, the previous version is at counter-1. But we've lost
    # the counter here, so parse from the atom.
    case Atom.to_string(state_var_atom) do
      "__State" ->
        :__State

      "State_0" ->
        :__State

      "State_" <> n_str ->
        n = String.to_integer(n_str)
        String.to_atom("State_#{n - 1}")
    end
  end

  defp fresh_atom(prefix) do
    String.to_atom("#{prefix}_#{:erlang.unique_integer([:positive, :monotonic])}")
  end

  # Builds an Erlang cons-cell expression `[R_start, R_{start+1}, ..., R_{start+count-1}]`
  # by reading from the current register tuple.
  defp build_args_list(_start, 0, line, _ctx), do: {nil, line}

  defp build_args_list(start, count, line, ctx) do
    head = get_register(start, line, ctx)
    tail = build_args_list(start + 1, count - 1, line, ctx)
    {:cons, line, head, tail}
  end

  # ── Internal helpers ──────────────────────────────────────────────

  defp set_register(idx, value_form, line, %Ctx{} = ctx) do
    # Capture the current register var BEFORE minting a fresh one — that's
    # the version we read from.
    prev_var = ctx.regs_var
    {new_var, ctx} = Ctx.fresh_regs_var(ctx)

    setel_form =
      {:call, line, {:atom, line, :setelement}, [{:integer, line, idx + 1}, {:var, line, prev_var}, value_form]}

    match_form = {:match, line, {:var, line, new_var}, setel_form}
    {[match_form], ctx}
  end

  defp get_register(idx, line, %Ctx{} = ctx) do
    {:call, line, {:atom, line, :element}, [{:integer, line, idx + 1}, {:var, line, ctx.regs_var}]}
  end

  defp current_line(%Ctx{line: line}), do: line

  # ── Literal → Erlang abstract form ────────────────────────────────

  defp literal_to_form(value, line) when is_integer(value), do: {:integer, line, value}
  defp literal_to_form(value, line) when is_float(value), do: {:float, line, value}

  defp literal_to_form(value, line) when is_binary(value) do
    # Lua strings can contain arbitrary bytes (not just UTF-8). Emit
    # each byte as a separate `bin_element` so binaries with embedded
    # non-UTF-8 bytes round-trip correctly.
    bin_elements =
      for <<byte <- value>> do
        {:bin_element, line, {:integer, line, byte}, :default, :default}
      end

    {:bin, line, bin_elements}
  end

  defp literal_to_form(nil, line), do: {:atom, line, nil}
  defp literal_to_form(true, line), do: {:atom, line, true}
  defp literal_to_form(false, line), do: {:atom, line, false}

  defp literal_to_form(atom, line) when is_atom(atom), do: {:atom, line, atom}

  # Generic term-to-abstract-form for arbitrary Erlang terms.
  # Used for `name_hint` and other opaque tags that need to round-trip
  # through codegen as-is. Falls back to `:erl_parse.abstract/1` for
  # anything not explicitly handled.
  defp term_to_form(value, line) when is_integer(value), do: {:integer, line, value}
  defp term_to_form(value, line) when is_float(value), do: {:float, line, value}
  defp term_to_form(nil, line), do: {:atom, line, nil}
  defp term_to_form(true, line), do: {:atom, line, true}
  defp term_to_form(false, line), do: {:atom, line, false}
  defp term_to_form(atom, line) when is_atom(atom), do: {:atom, line, atom}

  defp term_to_form(value, line) when is_binary(value) do
    bin_elements =
      for <<byte <- value>> do
        {:bin_element, line, {:integer, line, byte}, :default, :default}
      end

    {:bin, line, bin_elements}
  end

  defp term_to_form(tuple, line) when is_tuple(tuple) do
    elements = Enum.map(Tuple.to_list(tuple), &term_to_form(&1, line))
    {:tuple, line, elements}
  end

  defp term_to_form([], line), do: {nil, line}

  defp term_to_form([head | tail], line) do
    {:cons, line, term_to_form(head, line), term_to_form(tail, line)}
  end
end
