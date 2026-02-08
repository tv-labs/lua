defmodule Lua.Compiler.Codegen do
  @moduledoc """
  Code generation - transforms AST into instructions.
  """

  alias Lua.AST.{Chunk, Block, Statement, Expr}
  alias Lua.Compiler.{Prototype, Instruction, Scope}

  @doc """
  Generates instructions from a scope-resolved AST.
  """
  @spec generate(Chunk.t(), Scope.State.t(), keyword()) :: {:ok, Prototype.t()} | {:error, term()}
  def generate(%Chunk{block: block}, scope_state, opts \\ []) do
    source = Keyword.get(opts, :source, <<"-no-source-">>)

    # Generate instructions for the chunk body
    # Start next_reg at the max_register from scope to account for locals
    func_scope = scope_state.functions[:chunk]
    start_reg = func_scope.max_register

    {instructions, ctx} =
      gen_block(block, %{next_reg: start_reg, source: source, scope: scope_state, prototypes: []})

    # Wrap in a prototype
    proto = %Prototype{
      instructions: instructions,
      # Reverse to maintain order
      prototypes: Enum.reverse(ctx.prototypes),
      upvalue_descriptors: [],
      param_count: 0,
      is_vararg: false,
      max_registers: func_scope.max_register,
      source: source,
      lines: {1, 1}
    }

    {:ok, proto}
  end

  defp gen_block(%Block{stmts: stmts}, ctx) do
    Enum.reduce(stmts, {[], ctx}, fn stmt, {instructions, ctx} ->
      {new_instructions, ctx} = gen_statement(stmt, ctx)
      {instructions ++ new_instructions, ctx}
    end)
  end

  defp gen_statement(%Statement.Return{values: [%Expr.Vararg{}]}, ctx) do
    {[Instruction.return_vararg()], ctx}
  end

  defp gen_statement(%Statement.Return{values: [%Expr.Call{} = call]}, ctx) do
    # return f(...) — forward all results from the call
    {call_instructions, _result_reg, ctx} = gen_expr(call, ctx)

    # Patch the call to request all results (sentinel -1)
    call_instructions =
      case List.last(call_instructions) do
        {:call, base, arg_count, _result_count} ->
          List.replace_at(
            call_instructions,
            length(call_instructions) - 1,
            {:call, base, arg_count, -1}
          )

        _ ->
          call_instructions
      end

    {call_instructions, ctx}
  end

  defp gen_statement(%Statement.Return{values: values}, ctx) do
    case values do
      [] ->
        # return with no values
        {[Instruction.return_instr(0, 0)], ctx}

      [value] ->
        # return single value
        {value_instructions, result_reg, ctx} = gen_expr(value, ctx)
        {value_instructions ++ [Instruction.return_instr(result_reg, 1)], ctx}

      multiple ->
        base_reg = ctx.next_reg

        {all_instructions, ctx} =
          multiple
          |> Enum.with_index()
          |> Enum.reduce({[], ctx}, fn {value, i}, {instructions, ctx} ->
            target_reg = base_reg + i
            {value_instructions, value_reg, ctx} = gen_expr(value, ctx)

            move =
              if value_reg == target_reg, do: [], else: [Instruction.move(target_reg, value_reg)]

            {instructions ++ value_instructions ++ move, ctx}
          end)

        {all_instructions ++ [Instruction.return_instr(base_reg, length(multiple))], ctx}
    end
  end

  defp gen_statement(%Statement.Assign{targets: targets, values: values}, ctx) do
    case {targets, values} do
      {[target], [value]} ->
        {value_instructions, value_reg, ctx} = gen_expr(value, ctx)

        {store_instructions, ctx} = gen_assign_target(target, value_reg, ctx)

        {value_instructions ++ store_instructions, ctx}

      _ ->
        # Unsupported pattern for now
        {[], ctx}
    end
  end

  defp gen_statement(%Statement.Local{names: names, values: values}, ctx) do
    # Get register assignments from scope
    scope = ctx.scope
    locals = scope.locals

    # Generate code for all values
    {value_instructions, value_regs, ctx} =
      Enum.reduce(values, {[], [], ctx}, fn value, {instructions, regs, ctx} ->
        {new_instructions, reg, ctx} = gen_expr(value, ctx)
        {instructions ++ new_instructions, regs ++ [reg], ctx}
      end)

    # Generate move instructions to copy values to their assigned registers
    move_instructions =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} ->
        dest_reg = Map.get(locals, name)
        source_reg = Enum.at(value_regs, index)

        cond do
          # No value for this local - it's implicitly nil
          is_nil(source_reg) ->
            [Instruction.load_constant(dest_reg, nil)]

          # Value is already in the right register
          dest_reg == source_reg ->
            []

          # Need to move value to assigned register
          true ->
            [Instruction.move(dest_reg, source_reg)]
        end
      end)

    {value_instructions ++ move_instructions, ctx}
  end

  defp gen_statement(
         %Statement.If{
           condition: condition,
           then_block: then_block,
           elseifs: elseifs,
           else_block: else_block
         },
         ctx
       ) do
    # Generate code for the condition
    {condition_instructions, cond_reg, ctx} = gen_expr(condition, ctx)

    # Generate code for the then block
    {then_instructions, ctx} = gen_block(then_block, ctx)

    # Generate code for elseifs and else by building nested if-else
    {else_instructions, ctx} = gen_elseifs_and_else(elseifs, else_block, ctx)

    # Create the test instruction
    test_instruction = Instruction.test(cond_reg, then_instructions, else_instructions)

    {condition_instructions ++ [test_instruction], ctx}
  end

  defp gen_statement(%Statement.While{condition: condition, body: body}, ctx) do
    # Generate code for the condition
    {condition_instructions, cond_reg, ctx} = gen_expr(condition, ctx)

    # Generate code for the body
    {body_instructions, ctx} = gen_block(body, ctx)

    # Create while loop instruction
    loop_instruction = Instruction.while_loop(condition_instructions, cond_reg, body_instructions)

    {[loop_instruction], ctx}
  end

  defp gen_statement(%Statement.Repeat{body: body, condition: condition}, ctx) do
    # Generate code for the body
    {body_instructions, ctx} = gen_block(body, ctx)

    # Generate code for the condition
    {condition_instructions, cond_reg, ctx} = gen_expr(condition, ctx)

    # Create repeat loop instruction
    loop_instruction =
      Instruction.repeat_loop(body_instructions, condition_instructions, cond_reg)

    {[loop_instruction], ctx}
  end

  defp gen_statement(
         %Statement.ForNum{
           var: var,
           start: start_expr,
           limit: limit_expr,
           step: step_expr,
           body: body
         },
         ctx
       ) do
    # Get the loop variable's register from scope
    loop_var_reg = ctx.scope.locals[var]

    # Allocate 3 internal registers for: counter, limit, step
    base = ctx.next_reg
    ctx = %{ctx | next_reg: ctx.next_reg + 3}

    # Generate code for start, limit, step
    {start_instructions, start_reg, ctx} = gen_expr(start_expr, ctx)
    {limit_instructions, limit_reg, ctx} = gen_expr(limit_expr, ctx)

    {step_instructions, step_reg, ctx} =
      if step_expr do
        gen_expr(step_expr, ctx)
      else
        # Default step is 1
        reg = ctx.next_reg
        ctx = %{ctx | next_reg: reg + 1}
        {[Instruction.load_constant(reg, 1)], reg, ctx}
      end

    # Move start/limit/step to internal registers
    init_instructions = [
      # internal counter = start
      Instruction.move(base, start_reg),
      # limit
      Instruction.move(base + 1, limit_reg),
      # step
      Instruction.move(base + 2, step_reg)
    ]

    # Generate body
    {body_instructions, ctx} = gen_block(body, ctx)

    # Create numeric for instruction
    # The VM will handle: copying base to loop_var_reg, incrementing, checking limit
    loop_instruction = Instruction.numeric_for(base, loop_var_reg, body_instructions)

    {start_instructions ++
       limit_instructions ++
       step_instructions ++
       init_instructions ++
       [loop_instruction], ctx}
  end

  defp gen_statement(
         %Statement.ForIn{vars: vars, iterators: iterators, body: body},
         ctx
       ) do
    # Look up loop variable registers from scope
    var_regs = Enum.map(vars, fn name -> ctx.scope.locals[name] end)

    # Allocate 3 internal registers for: iterator function, invariant state, control variable
    base = ctx.next_reg
    ctx = %{ctx | next_reg: base + 3}

    # Generate iterator expression(s)
    # Typically `pairs(t)` or `ipairs(t)` — a single call that returns 3 values
    {iter_instructions, ctx} =
      case iterators do
        [single_iter] ->
          {iter_instr, _iter_reg, ctx} = gen_expr(single_iter, ctx)

          # Patch the call instruction to request 3 results
          iter_instr =
            case List.last(iter_instr) do
              {:call, call_base, arg_count, _result_count} ->
                List.replace_at(
                  iter_instr,
                  length(iter_instr) - 1,
                  {:call, call_base, arg_count, 3}
                )

              _ ->
                iter_instr
            end

          # Move the 3 results (at call_base, call_base+1, call_base+2) into base, base+1, base+2
          call_base =
            case List.last(iter_instr) do
              {:call, cb, _, _} -> cb
              _ -> base
            end

          move_instructions =
            for i <- 0..2, call_base + i != base + i do
              Instruction.move(base + i, call_base + i)
            end

          {iter_instr ++ move_instructions, ctx}

        _ ->
          # Multiple iterator expressions — evaluate each and move to base+0,1,2
          {instrs, regs, ctx} =
            Enum.reduce(iterators, {[], [], ctx}, fn expr, {instructions, regs, ctx} ->
              {expr_instr, expr_reg, ctx} = gen_expr(expr, ctx)
              {instructions ++ expr_instr, regs ++ [expr_reg], ctx}
            end)

          move_instructions =
            regs
            |> Enum.with_index()
            |> Enum.flat_map(fn {src_reg, i} ->
              if i < 3 and src_reg != base + i do
                [Instruction.move(base + i, src_reg)]
              else
                []
              end
            end)

          {instrs ++ move_instructions, ctx}
      end

    # Generate body
    {body_instructions, ctx} = gen_block(body, ctx)

    # Emit generic_for instruction with var_regs as a list of register indices
    loop_instruction = Instruction.generic_for(base, var_regs, body_instructions)

    {iter_instructions ++ [loop_instruction], ctx}
  end

  defp gen_statement(%Statement.CallStmt{call: call}, ctx) do
    # Compile the call expression, but discard the result (0 result count)
    {call_instructions, _result_reg, ctx} = gen_expr(call, ctx)

    # Patch the last instruction to request 0 results
    call_instructions =
      case List.last(call_instructions) do
        {:call, base, arg_count, _result_count} ->
          List.replace_at(
            call_instructions,
            length(call_instructions) - 1,
            {:call, base, arg_count, 0}
          )

        _ ->
          call_instructions
      end

    {call_instructions, ctx}
  end

  # FuncDecl: function name(params) body end
  defp gen_statement(%Statement.FuncDecl{name: name} = decl, ctx) do
    {closure_instructions, closure_reg, ctx} = gen_closure_from_node(decl, ctx)

    case name do
      [single_name] ->
        {closure_instructions ++ [Instruction.set_global(single_name, closure_reg)], ctx}

      [first | rest] ->
        # Dotted name: get the table chain, then set the final field
        {get_instructions, table_reg, ctx} = gen_expr(%Expr.Var{name: first}, ctx)
        {final_instructions, final_table_reg, ctx} =
          Enum.reduce(Enum.slice(rest, 0..-2//1), {get_instructions, table_reg, ctx}, fn field, {instrs, reg, ctx} ->
            field_reg = ctx.next_reg
            ctx = %{ctx | next_reg: field_reg + 1}
            {instrs ++ [Instruction.get_field(field_reg, reg, field)], field_reg, ctx}
          end)

        last_field = List.last(rest)
        {final_instructions ++ [Instruction.set_field(final_table_reg, last_field, closure_reg)], ctx}
    end
  end

  # Stub for other statements
  defp gen_statement(_stmt, ctx), do: {[], ctx}

  # Helpers for assignment target code generation
  defp gen_assign_target(%Expr.Var{} = target_var, value_reg, ctx) do
    store_instructions =
      case Map.get(ctx.scope.var_map, target_var) do
        {:register, local_reg} ->
          if local_reg == value_reg, do: [], else: [Instruction.move(local_reg, value_reg)]

        {:captured_local, local_reg} ->
          [Instruction.set_open_upvalue(local_reg, value_reg)]

        {:upvalue, index} ->
          [Instruction.set_upvalue(index, value_reg)]

        {:global, name} ->
          [Instruction.set_global(name, value_reg)]

        nil ->
          [Instruction.set_global(target_var.name, value_reg)]
      end

    {store_instructions, ctx}
  end

  defp gen_assign_target(%Expr.Property{table: table_expr, field: field}, value_reg, ctx) do
    {table_instructions, table_reg, ctx} = gen_expr(table_expr, ctx)
    {table_instructions ++ [Instruction.set_field(table_reg, field, value_reg)], ctx}
  end

  defp gen_assign_target(%Expr.Index{table: table_expr, key: key_expr}, value_reg, ctx) do
    {table_instructions, table_reg, ctx} = gen_expr(table_expr, ctx)
    {key_instructions, key_reg, ctx} = gen_expr(key_expr, ctx)

    {table_instructions ++
       key_instructions ++
       [Instruction.set_table(table_reg, key_reg, value_reg)], ctx}
  end

  # Helper functions for if statement code generation
  defp gen_elseifs_and_else([], nil, ctx) do
    # No elseifs, no else - empty else branch
    {[], ctx}
  end

  defp gen_elseifs_and_else([], else_block, ctx) do
    # No elseifs, just else block
    gen_block(else_block, ctx)
  end

  defp gen_elseifs_and_else([{elseif_cond, elseif_block} | rest_elseifs], else_block, ctx) do
    # Generate condition for this elseif
    {condition_instructions, cond_reg, ctx} = gen_expr(elseif_cond, ctx)

    # Generate body for this elseif
    {then_instructions, ctx} = gen_block(elseif_block, ctx)

    # Generate remaining elseifs and else
    {else_instructions, ctx} = gen_elseifs_and_else(rest_elseifs, else_block, ctx)

    # Create nested test instruction
    test_instruction = Instruction.test(cond_reg, then_instructions, else_instructions)

    {condition_instructions ++ [test_instruction], ctx}
  end

  # Generate code for an expression, returning {instructions, result_register, context}
  defp gen_expr(%Expr.Number{value: n}, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_constant(reg, n)], reg, ctx}
  end

  defp gen_expr(%Expr.String{value: s}, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_constant(reg, s)], reg, ctx}
  end

  defp gen_expr(%Expr.Bool{value: b}, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_boolean(reg, b)], reg, ctx}
  end

  defp gen_expr(%Expr.Nil{}, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_constant(reg, nil)], reg, ctx}
  end

  defp gen_expr(%Expr.BinOp{op: :and, left: left, right: right}, ctx) do
    # Short-circuit AND: if left is falsy, return left, else evaluate and return right
    # Generate code for left operand
    {left_instructions, left_reg, ctx} = gen_expr(left, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate code for right operand (to be executed conditionally)
    {right_instructions, right_reg, ctx} = gen_expr(right, ctx)

    # Move right result to destination
    move_instruction =
      if dest_reg == right_reg do
        []
      else
        [Instruction.move(dest_reg, right_reg)]
      end

    # test_and: if falsy(left_reg) then dest=left else execute right_body
    and_instruction =
      Instruction.test_and(dest_reg, left_reg, right_instructions ++ move_instruction)

    {left_instructions ++ [and_instruction], dest_reg, ctx}
  end

  defp gen_expr(%Expr.BinOp{op: :or, left: left, right: right}, ctx) do
    # Short-circuit OR: if left is truthy, return left, else evaluate and return right
    # Generate code for left operand
    {left_instructions, left_reg, ctx} = gen_expr(left, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate code for right operand (to be executed conditionally)
    {right_instructions, right_reg, ctx} = gen_expr(right, ctx)

    # Move right result to destination
    move_instruction =
      if dest_reg == right_reg do
        []
      else
        [Instruction.move(dest_reg, right_reg)]
      end

    # test_or: if truthy(left_reg) then dest=left else execute right_body
    or_instruction =
      Instruction.test_or(dest_reg, left_reg, right_instructions ++ move_instruction)

    {left_instructions ++ [or_instruction], dest_reg, ctx}
  end

  defp gen_expr(%Expr.BinOp{op: op, left: left, right: right}, ctx) do
    # Generate code for left operand
    {left_instructions, left_reg, ctx} = gen_expr(left, ctx)

    # Generate code for right operand
    {right_instructions, right_reg, ctx} = gen_expr(right, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate the operation instruction
    operation_instruction =
      case op do
        :add -> Instruction.add(dest_reg, left_reg, right_reg)
        :sub -> Instruction.subtract(dest_reg, left_reg, right_reg)
        :mul -> Instruction.multiply(dest_reg, left_reg, right_reg)
        :div -> Instruction.divide(dest_reg, left_reg, right_reg)
        :floordiv -> Instruction.floor_divide(dest_reg, left_reg, right_reg)
        :mod -> Instruction.modulo(dest_reg, left_reg, right_reg)
        :pow -> Instruction.power(dest_reg, left_reg, right_reg)
        :band -> Instruction.bitwise_and(dest_reg, left_reg, right_reg)
        :bor -> Instruction.bitwise_or(dest_reg, left_reg, right_reg)
        :bxor -> Instruction.bitwise_xor(dest_reg, left_reg, right_reg)
        :shl -> Instruction.shift_left(dest_reg, left_reg, right_reg)
        :shr -> Instruction.shift_right(dest_reg, left_reg, right_reg)
        :concat -> Instruction.concatenate(dest_reg, left_reg, right_reg)
        :eq -> Instruction.equal(dest_reg, left_reg, right_reg)
        :ne -> {:not_equal, dest_reg, left_reg, right_reg}
        :lt -> Instruction.less_than(dest_reg, left_reg, right_reg)
        :le -> Instruction.less_equal(dest_reg, left_reg, right_reg)
        :gt -> {:greater_than, dest_reg, left_reg, right_reg}
        :ge -> {:greater_equal, dest_reg, left_reg, right_reg}
        _ -> raise "Unsupported binary operator: #{op}"
      end

    {left_instructions ++ right_instructions ++ [operation_instruction], dest_reg, ctx}
  end

  defp gen_expr(%Expr.UnOp{op: op, operand: operand}, ctx) do
    # Generate code for operand
    {operand_instructions, operand_reg, ctx} = gen_expr(operand, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate the operation instruction
    operation_instruction =
      case op do
        :neg -> Instruction.negate(dest_reg, operand_reg)
        :not -> Instruction.logical_not(dest_reg, operand_reg)
        :len -> Instruction.length(dest_reg, operand_reg)
        :bnot -> Instruction.bitwise_not(dest_reg, operand_reg)
      end

    {operand_instructions ++ [operation_instruction], dest_reg, ctx}
  end

  defp gen_expr(%Expr.Var{} = var, ctx) do
    # Look up variable classification from scope
    case Map.get(ctx.scope.var_map, var) do
      {:register, reg} ->
        # Local variable - already in a register, just return it
        {[], reg, ctx}

      {:captured_local, reg} ->
        # Local captured by a closure - read from open upvalue cell
        dest = ctx.next_reg
        ctx = %{ctx | next_reg: dest + 1}
        {[Instruction.get_open_upvalue(dest, reg)], dest, ctx}

      {:upvalue, index} ->
        # Upvalue - load from upvalue list
        reg = ctx.next_reg
        ctx = %{ctx | next_reg: reg + 1}
        {[Instruction.get_upvalue(reg, index)], reg, ctx}

      {:global, name} ->
        # Global variable - need to load it
        reg = ctx.next_reg
        ctx = %{ctx | next_reg: reg + 1}
        {[Instruction.get_global(reg, name)], reg, ctx}

      nil ->
        # Variable not in scope (shouldn't happen after scope resolution)
        reg = ctx.next_reg
        ctx = %{ctx | next_reg: reg + 1}
        {[Instruction.load_constant(reg, nil)], reg, ctx}
    end
  end

  defp gen_expr(%Expr.Function{} = func, ctx) do
    gen_closure_from_node(func, ctx)
  end

  defp gen_expr(%Expr.Call{func: func_expr, args: args}, ctx) do
    # Allocate base register for the call
    base_reg = ctx.next_reg

    # Generate code for the function expression
    {function_instructions, func_reg, ctx} = gen_expr(func_expr, ctx)

    # Move function to base register if needed
    move_function =
      if func_reg == base_reg do
        []
      else
        [Instruction.move(base_reg, func_reg)]
      end

    ctx = %{ctx | next_reg: base_reg + 1}

    # Generate code for arguments into temp registers above the arg window.
    # We skip over the arg slots (base+1..base+arg_count) so temps don't clobber them.
    arg_count = length(args)
    ctx = %{ctx | next_reg: base_reg + 1 + arg_count}

    {arg_instructions, arg_regs, ctx} =
      Enum.reduce(args, {[], [], ctx}, fn arg, {instructions, regs, ctx} ->
        {arg_instructions, arg_reg, ctx} = gen_expr(arg, ctx)
        {instructions ++ arg_instructions, regs ++ [arg_reg], ctx}
      end)

    # Move each arg result to its expected position (base+1+i)
    move_instructions =
      arg_regs
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg_reg, i} ->
        expected_reg = base_reg + 1 + i

        if arg_reg == expected_reg do
          []
        else
          [Instruction.move(expected_reg, arg_reg)]
        end
      end)

    # Generate call instruction (single return value for now)
    call_instruction = Instruction.call(base_reg, arg_count, 1)

    # Result will be in base_reg
    {function_instructions ++
       move_function ++
       arg_instructions ++
       move_instructions ++
       [call_instruction], base_reg, ctx}
  end

  defp gen_expr(%Expr.Table{fields: fields}, ctx) do
    dest = ctx.next_reg
    ctx = %{ctx | next_reg: dest + 1}

    # Separate list and record fields
    list_fields = for {:list, val} <- fields, do: val
    record_fields = for {:record, k, v} <- fields, do: {k, v}

    array_hint = length(list_fields)
    hash_hint = length(record_fields)

    new_table_instruction = Instruction.new_table(dest, array_hint, hash_hint)

    # Compile list fields into consecutive temp registers, then emit set_list
    {list_instructions, ctx} =
      if list_fields == [] do
        {[], ctx}
      else
        # Reserve contiguous slots for the list values
        start_reg = ctx.next_reg
        ctx = %{ctx | next_reg: start_reg + array_hint}

        {value_instructions, ctx} =
          list_fields
          |> Enum.with_index()
          |> Enum.reduce({[], ctx}, fn {val_expr, i}, {instructions, ctx} ->
            target_reg = start_reg + i
            {value_instructions, val_reg, ctx} = gen_expr(val_expr, ctx)

            move =
              if val_reg == target_reg, do: [], else: [Instruction.move(target_reg, val_reg)]

            {instructions ++ value_instructions ++ move, ctx}
          end)

        set_list_instruction = Instruction.set_list(dest, start_reg, array_hint, 0)
        {value_instructions ++ [set_list_instruction], ctx}
      end

    # Compile record fields
    {record_instructions, ctx} =
      Enum.reduce(record_fields, {[], ctx}, fn {key_expr, val_expr}, {instructions, ctx} ->
        {value_instructions, val_reg, ctx} = gen_expr(val_expr, ctx)

        case key_expr do
          %Expr.String{value: name} ->
            {instructions ++ value_instructions ++ [Instruction.set_field(dest, name, val_reg)],
             ctx}

          _ ->
            {key_instructions, key_reg, ctx} = gen_expr(key_expr, ctx)

            {instructions ++
               value_instructions ++
               key_instructions ++
               [Instruction.set_table(dest, key_reg, val_reg)], ctx}
        end
      end)

    {[new_table_instruction] ++ list_instructions ++ record_instructions, dest, ctx}
  end

  defp gen_expr(%Expr.Property{table: table_expr, field: field}, ctx) do
    {table_instructions, table_reg, ctx} = gen_expr(table_expr, ctx)
    dest = ctx.next_reg
    ctx = %{ctx | next_reg: dest + 1}
    {table_instructions ++ [Instruction.get_field(dest, table_reg, field)], dest, ctx}
  end

  defp gen_expr(%Expr.Index{table: table_expr, key: key_expr}, ctx) do
    {table_instructions, table_reg, ctx} = gen_expr(table_expr, ctx)
    {key_instructions, key_reg, ctx} = gen_expr(key_expr, ctx)
    dest = ctx.next_reg
    ctx = %{ctx | next_reg: dest + 1}

    {table_instructions ++ key_instructions ++ [Instruction.get_table(dest, table_reg, key_reg)],
     dest, ctx}
  end

  defp gen_expr(%Expr.MethodCall{object: obj_expr, method: method, args: args}, ctx) do
    # Method call: obj:method(a, b)
    # Layout: R[base] = obj["method"], R[base+1] = obj (self), R[base+2..] = args
    base_reg = ctx.next_reg

    # Compile the object expression
    {object_instructions, obj_reg, ctx} = gen_expr(obj_expr, ctx)

    # self instruction: R[base+1] = obj, R[base] = obj["method"]
    self_instruction = Instruction.self_instr(base_reg, obj_reg, method)

    ctx = %{ctx | next_reg: base_reg + 2}

    # Compile arguments into temp registers above the arg window
    arg_count = length(args)
    ctx = %{ctx | next_reg: base_reg + 2 + arg_count}

    {arg_instructions, arg_regs, ctx} =
      Enum.reduce(args, {[], [], ctx}, fn arg, {instructions, regs, ctx} ->
        {arg_instructions, arg_reg, ctx} = gen_expr(arg, ctx)
        {instructions ++ arg_instructions, regs ++ [arg_reg], ctx}
      end)

    # Move each arg result to its expected position (base+2+i)
    move_instructions =
      arg_regs
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg_reg, i} ->
        expected_reg = base_reg + 2 + i

        if arg_reg == expected_reg do
          []
        else
          [Instruction.move(expected_reg, arg_reg)]
        end
      end)

    # Call with arg_count + 1 for self
    call_instruction = Instruction.call(base_reg, arg_count + 1, 1)

    {object_instructions ++
       [self_instruction] ++
       arg_instructions ++
       move_instructions ++
       [call_instruction], base_reg, ctx}
  end

  defp gen_expr(%Expr.Vararg{}, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.vararg(reg, 1)], reg, ctx}
  end

  # Stub for other expressions
  defp gen_expr(_expr, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_constant(reg, nil)], reg, ctx}
  end

  # Shared helper: generates a closure from a function node (Expr.Function, Statement.FuncDecl, etc.)
  # Returns {instructions, dest_reg, ctx} like gen_expr.
  defp gen_closure_from_node(node, ctx) do
    func_key = Map.get(ctx.scope.var_map, node)
    func_scope = ctx.scope.functions[func_key]

    # Generate the function body in a fresh context with function-scoped locals
    func_locals_scope = %{ctx.scope | locals: func_scope.locals}

    {body_instructions, body_ctx} =
      gen_block(node.body, %{
        next_reg: func_scope.param_count,
        source: ctx.source,
        scope: func_locals_scope,
        prototypes: []
      })

    # Create the nested prototype (include nested prototypes from body)
    nested_proto = %Prototype{
      instructions: body_instructions,
      prototypes: Enum.reverse(body_ctx.prototypes),
      upvalue_descriptors: func_scope.upvalue_descriptors,
      param_count: func_scope.param_count,
      is_vararg: func_scope.is_vararg,
      max_registers: func_scope.max_register,
      source: ctx.source,
      lines: {1, 1}
    }

    # Add to prototypes list and get its index
    proto_index = length(ctx.prototypes)
    ctx = %{ctx | prototypes: [nested_proto | ctx.prototypes]}

    # Generate closure instruction
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    {[Instruction.closure(dest_reg, proto_index)], dest_reg, ctx}
  end
end
