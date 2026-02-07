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

    {instructions, _ctx} =
      gen_block(block, %{next_reg: start_reg, source: source, scope: scope_state})

    # Wrap in a prototype
    proto = %Prototype{
      instructions: instructions,
      prototypes: [],
      upvalue_descriptors: [],
      param_count: 0,
      is_vararg: false,
      max_registers: 0,
      source: source,
      lines: {1, 1}
    }

    {:ok, proto}
  end

  defp gen_block(%Block{stmts: stmts}, ctx) do
    Enum.reduce(stmts, {[], ctx}, fn stmt, {instrs, ctx} ->
      {new_instrs, ctx} = gen_statement(stmt, ctx)
      {instrs ++ new_instrs, ctx}
    end)
  end

  defp gen_statement(%Statement.Return{values: values}, ctx) do
    case values do
      [] ->
        # return with no values
        {[Instruction.return_instr(0, 0)], ctx}

      [value] ->
        # return single value
        {value_instrs, result_reg, ctx} = gen_expr(value, ctx)
        {value_instrs ++ [Instruction.return_instr(result_reg, 1)], ctx}

      _multiple ->
        # For now, just handle single return
        # TODO: implement multiple return values
        {[Instruction.return_instr(0, 0)], ctx}
    end
  end

  defp gen_statement(%Statement.Assign{targets: targets, values: values}, ctx) do
    # For now, handle simple case: single target, single value
    # TODO: handle multiple assignment and table indexing
    case {targets, values} do
      {[%Expr.Var{name: name}], [value]} ->
        # Simple global assignment: x = value
        {value_instrs, value_reg, ctx} = gen_expr(value, ctx)
        {value_instrs ++ [Instruction.set_global(name, value_reg)], ctx}

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
    {value_instrs, value_regs, ctx} =
      Enum.reduce(values, {[], [], ctx}, fn value, {instrs, regs, ctx} ->
        {new_instrs, reg, ctx} = gen_expr(value, ctx)
        {instrs ++ new_instrs, regs ++ [reg], ctx}
      end)

    # Generate move instructions to copy values to their assigned registers
    move_instrs =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, idx} ->
        dest_reg = Map.get(locals, name)
        source_reg = Enum.at(value_regs, idx)

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

    {value_instrs ++ move_instrs, ctx}
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
    {cond_instrs, cond_reg, ctx} = gen_expr(condition, ctx)

    # Generate code for the then block
    {then_instrs, ctx} = gen_block(then_block, ctx)

    # Generate code for elseifs and else by building nested if-else
    {else_instrs, ctx} = gen_elseifs_and_else(elseifs, else_block, ctx)

    # Create the test instruction
    test_instr = Instruction.test(cond_reg, then_instrs, else_instrs)

    {cond_instrs ++ [test_instr], ctx}
  end

  # Stub for other statements
  defp gen_statement(_stmt, ctx), do: {[], ctx}

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
    {cond_instrs, cond_reg, ctx} = gen_expr(elseif_cond, ctx)

    # Generate body for this elseif
    {then_instrs, ctx} = gen_block(elseif_block, ctx)

    # Generate remaining elseifs and else
    {else_instrs, ctx} = gen_elseifs_and_else(rest_elseifs, else_block, ctx)

    # Create nested test instruction
    test_instr = Instruction.test(cond_reg, then_instrs, else_instrs)

    {cond_instrs ++ [test_instr], ctx}
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
    {left_instrs, left_reg, ctx} = gen_expr(left, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate code for right operand (to be executed conditionally)
    {right_instrs, right_reg, ctx} = gen_expr(right, ctx)

    # Move right result to destination
    move_instr =
      if dest_reg == right_reg do
        []
      else
        [Instruction.move(dest_reg, right_reg)]
      end

    # test_and: if falsy(left_reg) then dest=left else execute right_body
    and_instr = Instruction.test_and(dest_reg, left_reg, right_instrs ++ move_instr)

    {left_instrs ++ [and_instr], dest_reg, ctx}
  end

  defp gen_expr(%Expr.BinOp{op: :or, left: left, right: right}, ctx) do
    # Short-circuit OR: if left is truthy, return left, else evaluate and return right
    # Generate code for left operand
    {left_instrs, left_reg, ctx} = gen_expr(left, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate code for right operand (to be executed conditionally)
    {right_instrs, right_reg, ctx} = gen_expr(right, ctx)

    # Move right result to destination
    move_instr =
      if dest_reg == right_reg do
        []
      else
        [Instruction.move(dest_reg, right_reg)]
      end

    # test_or: if truthy(left_reg) then dest=left else execute right_body
    or_instr = Instruction.test_or(dest_reg, left_reg, right_instrs ++ move_instr)

    {left_instrs ++ [or_instr], dest_reg, ctx}
  end

  defp gen_expr(%Expr.BinOp{op: op, left: left, right: right}, ctx) do
    # Generate code for left operand
    {left_instrs, left_reg, ctx} = gen_expr(left, ctx)

    # Generate code for right operand
    {right_instrs, right_reg, ctx} = gen_expr(right, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate the operation instruction
    op_instr =
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
        :concat -> Instruction.concatenate(dest_reg, left_reg, 2)
        :eq -> Instruction.equal(dest_reg, left_reg, right_reg)
        :ne -> {:not_equal, dest_reg, left_reg, right_reg}
        :lt -> Instruction.less_than(dest_reg, left_reg, right_reg)
        :le -> Instruction.less_equal(dest_reg, left_reg, right_reg)
        :gt -> {:greater_than, dest_reg, left_reg, right_reg}
        :ge -> {:greater_equal, dest_reg, left_reg, right_reg}
        _ -> raise "Unsupported binary operator: #{op}"
      end

    {left_instrs ++ right_instrs ++ [op_instr], dest_reg, ctx}
  end

  defp gen_expr(%Expr.UnOp{op: op, operand: operand}, ctx) do
    # Generate code for operand
    {operand_instrs, operand_reg, ctx} = gen_expr(operand, ctx)

    # Allocate destination register
    dest_reg = ctx.next_reg
    ctx = %{ctx | next_reg: dest_reg + 1}

    # Generate the operation instruction
    op_instr =
      case op do
        :neg -> Instruction.negate(dest_reg, operand_reg)
        :not -> Instruction.logical_not(dest_reg, operand_reg)
        :len -> Instruction.length(dest_reg, operand_reg)
        :bnot -> Instruction.bitwise_not(dest_reg, operand_reg)
      end

    {operand_instrs ++ [op_instr], dest_reg, ctx}
  end

  defp gen_expr(%Expr.Var{} = var, ctx) do
    # Look up variable classification from scope
    case Map.get(ctx.scope.var_map, var) do
      {:register, reg} ->
        # Local variable - already in a register, just return it
        {[], reg, ctx}

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

  # Stub for other expressions
  defp gen_expr(_expr, ctx) do
    reg = ctx.next_reg
    ctx = %{ctx | next_reg: reg + 1}
    {[Instruction.load_constant(reg, nil)], reg, ctx}
  end
end
