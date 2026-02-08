defmodule Lua.VM.Executor do
  @moduledoc """
  Instruction executor for the Lua VM.

  Tail-recursive dispatch loop that executes instructions.
  """

  alias Lua.VM.{InternalError, State, TypeError, Value}

  @doc """
  Executes instructions with the given register file and state.

  Returns {results, final_registers, final_state}.
  """
  @spec execute([tuple()], tuple(), list(), map(), State.t()) ::
          {list(), tuple(), State.t()}
  def execute(instructions, registers, upvalues, proto, state) do
    do_execute(instructions, registers, {upvalues, %{}}, proto, state)
  end

  # Empty instruction list - implicit return nil
  defp do_execute([], regs, _upvalues, _proto, state) do
    {[nil], regs, state}
  end

  # load_constant
  defp do_execute([{:load_constant, dest, value} | rest], regs, upvalues, proto, state) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # load_boolean
  defp do_execute([{:load_boolean, dest, value} | rest], regs, upvalues, proto, state) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_global
  defp do_execute([{:get_global, dest, name} | rest], regs, upvalues, proto, state) do
    value = Map.get(state.globals, name, nil)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_global
  defp do_execute([{:set_global, name, source} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)
    state = %{state | globals: Map.put(state.globals, name, value)}
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_upvalue
  defp do_execute(
         [{:get_upvalue, dest, index} | rest],
         regs,
         {upvalues, _} = upvalue_context,
         proto,
         state
       ) do
    cell_ref = Enum.at(upvalues, index)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalue_context, proto, state)
  end

  # set_upvalue
  defp do_execute(
         [{:set_upvalue, index, source} | rest],
         regs,
         {upvalues, _} = upvalue_context,
         proto,
         state
       ) do
    cell_ref = Enum.at(upvalues, index)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalue_context, proto, state)
  end

  # get_open_upvalue - read a captured local through its open upvalue cell
  defp do_execute(
         [{:get_open_upvalue, dest, reg} | rest],
         regs,
         {_upvalues, open_upvalues} = upvalue_context,
         proto,
         state
       ) do
    cell_ref = Map.fetch!(open_upvalues, reg)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalue_context, proto, state)
  end

  # set_open_upvalue - write a captured local through its open upvalue cell
  defp do_execute(
         [{:set_open_upvalue, reg, source} | rest],
         regs,
         {_upvalues, open_upvalues} = upvalue_context,
         proto,
         state
       ) do
    cell_ref = Map.fetch!(open_upvalues, reg)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalue_context, proto, state)
  end

  # move
  defp do_execute([{:move, dest, source} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # test - conditional execution
  defp do_execute([{:test, reg, then_body, else_body} | rest], regs, upvalues, proto, state) do
    body = if Value.truthy?(elem(regs, reg)), do: then_body, else: else_body
    do_execute(body ++ rest, regs, upvalues, proto, state)
  end

  # test_and - short-circuit AND
  defp do_execute([{:test_and, dest, source, rest_body} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)

    if Value.truthy?(value) do
      # Value is truthy, execute rest_body to compute final result
      do_execute(rest_body ++ rest, regs, upvalues, proto, state)
    else
      # Value is falsy, store it in dest and continue
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # test_or - short-circuit OR
  defp do_execute([{:test_or, dest, source, rest_body} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)

    if Value.truthy?(value) do
      # Value is truthy, store it in dest and continue
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvalues, proto, state)
    else
      # Value is falsy, execute rest_body to compute final result
      do_execute(rest_body ++ rest, regs, upvalues, proto, state)
    end
  end

  # while_loop
  defp do_execute(
         [{:while_loop, cond_body, test_reg, loop_body} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    # Execute condition
    {_results, regs, state} = do_execute(cond_body, regs, upvalues, proto, state)

    # Check condition
    if Value.truthy?(elem(regs, test_reg)) do
      # Execute body
      {_results, regs, state} = do_execute(loop_body, regs, upvalues, proto, state)
      # Loop again
      do_execute(
        [{:while_loop, cond_body, test_reg, loop_body} | rest],
        regs,
        upvalues,
        proto,
        state
      )
    else
      # Condition false, continue after loop
      do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # repeat_loop
  defp do_execute(
         [{:repeat_loop, loop_body, cond_body, test_reg} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    # Execute body
    {_results, regs, state} = do_execute(loop_body, regs, upvalues, proto, state)

    # Execute condition
    {_results, regs, state} = do_execute(cond_body, regs, upvalues, proto, state)

    # Check condition (repeat UNTIL condition is true)
    if Value.truthy?(elem(regs, test_reg)) do
      # Condition true, exit loop
      do_execute(rest, regs, upvalues, proto, state)
    else
      # Condition false, loop again
      do_execute(
        [{:repeat_loop, loop_body, cond_body, test_reg} | rest],
        regs,
        upvalues,
        proto,
        state
      )
    end
  end

  # numeric_for
  defp do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvalues, proto, state) do
    # Get internal loop state
    counter = elem(regs, base)
    limit = elem(regs, base + 1)
    step = elem(regs, base + 2)

    # Check if we should enter/continue the loop
    should_continue =
      if step > 0 do
        counter <= limit
      else
        counter >= limit
      end

    if should_continue do
      # Copy counter to loop variable
      regs = put_elem(regs, loop_var, counter)

      # Execute body
      {_results, regs, state} = do_execute(body, regs, upvalues, proto, state)

      # Increment counter
      new_counter = counter + step
      regs = put_elem(regs, base, new_counter)

      # Loop again
      do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvalues, proto, state)
    else
      # Loop finished
      do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # closure - create a closure value from a prototype, capturing upvalues
  defp do_execute(
         [{:closure, dest, proto_index} | rest],
         regs,
         {upvalues, open_upvalues},
         proto,
         state
       ) do
    nested_proto = Enum.at(proto.prototypes, proto_index)

    # Capture upvalues based on descriptors, reusing open upvalue cells when available
    {captured_upvalues, state, open_upvalues} =
      Enum.reduce(nested_proto.upvalue_descriptors, {[], state, open_upvalues}, fn
        {:parent_local, reg, _name}, {cells, state, open_upvalues} ->
          case Map.get(open_upvalues, reg) do
            nil ->
              # Create a new cell for this local variable
              cell_ref = make_ref()
              value = elem(regs, reg)
              state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
              open_upvalues = Map.put(open_upvalues, reg, cell_ref)
              {cells ++ [cell_ref], state, open_upvalues}

            existing_cell ->
              # Reuse existing open upvalue cell
              {cells ++ [existing_cell], state, open_upvalues}
          end

        {:parent_upvalue, index, _name}, {cells, state, open_upvalues} ->
          # Share the parent's upvalue cell
          {cells ++ [Enum.at(upvalues, index)], state, open_upvalues}
      end)

    closure = {:lua_closure, nested_proto, captured_upvalues}
    regs = put_elem(regs, dest, closure)
    do_execute(rest, regs, {upvalues, open_upvalues}, proto, state)
  end

  # call - invoke a function value
  defp do_execute(
         [{:call, base, arg_count, result_count} | rest],
         regs,
         upvalue_context,
         proto,
         state
       ) do
    func_value = elem(regs, base)

    # Collect arguments from registers base+1..base+arg_count
    args =
      if arg_count > 0 do
        for i <- 1..arg_count, do: elem(regs, base + i)
      else
        []
      end

    {results, state} =
      case func_value do
        {:lua_closure, callee_proto, callee_upvalues} ->
          # Create new register file for the callee
          callee_regs =
            Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 64)

          # Copy arguments into callee registers (params are R[0..N-1])
          callee_regs =
            args
            |> Enum.with_index()
            |> Enum.reduce(callee_regs, fn {arg, i}, regs ->
              if i < callee_proto.param_count, do: put_elem(regs, i, arg), else: regs
            end)

          # Execute the callee with fresh open_upvalues
          {results, _callee_regs, state} =
            do_execute(
              callee_proto.instructions,
              callee_regs,
              {callee_upvalues, %{}},
              callee_proto,
              state
            )

          {results, state}

        {:native_func, fun} ->
          case fun.(args, state) do
            {results, %State{} = new_state} when is_list(results) ->
              {results, new_state}

            {results, %State{} = new_state} ->
              {List.wrap(results), new_state}

            other ->
              raise InternalError,
                value:
                  "native function returned invalid result: #{inspect(other)}, expected {results, state}"
          end

        nil ->
          raise TypeError,
            value: "attempt to call a nil value",
            source: proto.source

        other ->
          raise TypeError,
            value: "attempt to call a #{Value.type_name(other)} value",
            source: proto.source
      end

    # Place results into caller registers starting at base
    regs =
      if result_count > 0 do
        results_list = List.wrap(results)

        Enum.reduce(0..(result_count - 1), regs, fn i, regs ->
          value = Enum.at(results_list, i)
          put_elem(regs, base + i, value)
        end)
      else
        regs
      end

    do_execute(rest, regs, upvalue_context, proto, state)
  end

  # return
  defp do_execute([{:return, base, count} | _rest], regs, _upvalues, _proto, state) do
    results =
      if count == 0 do
        [nil]
      else
        for i <- 0..(count - 1), do: elem(regs, base + i)
      end

    {results, regs, state}
  end

  # Arithmetic operations
  defp do_execute([{:add, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) + elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:subtract, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) - elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:multiply, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) * elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:divide, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) / elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:floor_divide, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = div(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:modulo, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = rem(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:power, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = :math.pow(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Bitwise operations
  defp do_execute([{:bitwise_and, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = Bitwise.band(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:bitwise_or, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = Bitwise.bor(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:bitwise_xor, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = Bitwise.bxor(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:shift_left, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = Bitwise.bsl(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:shift_right, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = Bitwise.bsr(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:bitwise_not, dest, source} | rest], regs, upvalues, proto, state) do
    result = Bitwise.bnot(trunc(elem(regs, source)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Comparison operations
  defp do_execute([{:equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) == elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:less_than, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) < elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:less_equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) <= elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:greater_than, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) > elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:greater_equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) >= elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:not_equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = elem(regs, a) != elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Unary operations
  defp do_execute([{:negate, dest, source} | rest], regs, upvalues, proto, state) do
    result = -elem(regs, source)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:not, dest, source} | rest], regs, upvalues, proto, state) do
    result = not Value.truthy?(elem(regs, source))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:length, dest, source} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)

    result =
      case value do
        {:tref, id} ->
          table = Map.fetch!(state.tables, id)
          Value.sequence_length(table.data)

        v when is_binary(v) ->
          byte_size(v)

        v when is_list(v) ->
          length(v)

        _ ->
          0
      end

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # new_table
  defp do_execute(
         [{:new_table, dest, _array_hint, _hash_hint} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    {tref, state} = State.alloc_table(state)
    regs = put_elem(regs, dest, tref)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_table — R[dest] = table[R[key_reg]]
  defp do_execute([{:get_table, dest, table_reg, key_reg} | rest], regs, upvalues, proto, state) do
    {:tref, id} = elem(regs, table_reg)
    key = elem(regs, key_reg)
    table = Map.fetch!(state.tables, id)
    value = Map.get(table.data, key)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_table — table[R[key_reg]] = R[value_reg]
  defp do_execute(
         [{:set_table, table_reg, key_reg, value_reg} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    {:tref, id} = elem(regs, table_reg)
    key = elem(regs, key_reg)
    value = elem(regs, value_reg)

    state =
      State.update_table(state, {:tref, id}, fn table ->
        %{table | data: Map.put(table.data, key, value)}
      end)

    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_field — R[dest] = table[name] (string key literal)
  defp do_execute([{:get_field, dest, table_reg, name} | rest], regs, upvalues, proto, state) do
    {:tref, id} = elem(regs, table_reg)
    table = Map.fetch!(state.tables, id)
    value = Map.get(table.data, name)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_field — table[name] = R[value_reg]
  defp do_execute(
         [{:set_field, table_reg, name, value_reg} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    {:tref, id} = elem(regs, table_reg)
    value = elem(regs, value_reg)

    state =
      State.update_table(state, {:tref, id}, fn table ->
        %{table | data: Map.put(table.data, name, value)}
      end)

    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_list — bulk store: table[offset+i] = R[start+i-1] for i in 1..count
  defp do_execute(
         [{:set_list, table_reg, start, count, offset} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    {:tref, id} = elem(regs, table_reg)

    state =
      State.update_table(state, {:tref, id}, fn table ->
        new_data =
          Enum.reduce(1..count, table.data, fn i, data ->
            value = elem(regs, start + i - 1)
            Map.put(data, offset + i, value)
          end)

        %{table | data: new_data}
      end)

    do_execute(rest, regs, upvalues, proto, state)
  end

  # self — R[base+1] = R[obj_reg], R[base] = R[obj_reg]["method"]
  defp do_execute(
         [{:self, base, obj_reg, method_name} | rest],
         regs,
         upvalues,
         proto,
         state
       ) do
    obj = elem(regs, obj_reg)
    {:tref, id} = obj
    table = Map.fetch!(state.tables, id)
    func = Map.get(table.data, method_name)
    regs = put_elem(regs, base + 1, obj)
    regs = put_elem(regs, base, func)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Catch-all for unimplemented instructions
  defp do_execute([instr | _rest], _regs, _upvalues, _proto, _state) do
    raise InternalError, value: "unimplemented instruction: #{inspect(instr)}"
  end
end
