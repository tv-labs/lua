defmodule Lua.VM.Executor do
  @moduledoc """
  Instruction executor for the Lua VM.

  Tail-recursive dispatch loop that executes instructions.
  """

  alias Lua.VM.State

  @doc """
  Executes instructions with the given register file and state.

  Returns {results, final_registers, final_state}.
  """
  @spec execute([tuple()], tuple(), list(), State.t()) ::
          {list(), tuple(), State.t()}
  def execute(instructions, registers, upvalues, state) do
    do_execute(instructions, registers, upvalues, state)
  end

  # Empty instruction list - implicit return nil
  defp do_execute([], regs, _upvals, state) do
    {[nil], regs, state}
  end

  # load_constant
  defp do_execute([{:load_constant, dest, value} | rest], regs, upvals, state) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvals, state)
  end

  # load_boolean
  defp do_execute([{:load_boolean, dest, value} | rest], regs, upvals, state) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvals, state)
  end

  # get_global
  defp do_execute([{:get_global, dest, name} | rest], regs, upvals, state) do
    value = Map.get(state.globals, name, nil)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvals, state)
  end

  # set_global
  defp do_execute([{:set_global, name, source} | rest], regs, upvals, state) do
    value = elem(regs, source)
    state = %{state | globals: Map.put(state.globals, name, value)}
    do_execute(rest, regs, upvals, state)
  end

  # move
  defp do_execute([{:move, dest, source} | rest], regs, upvals, state) do
    value = elem(regs, source)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvals, state)
  end

  # test - conditional execution
  defp do_execute([{:test, reg, then_body, else_body} | rest], regs, upvals, state) do
    body = if truthy?(elem(regs, reg)), do: then_body, else: else_body
    do_execute(body ++ rest, regs, upvals, state)
  end

  # test_and - short-circuit AND
  defp do_execute([{:test_and, dest, source, rest_body} | rest], regs, upvals, state) do
    value = elem(regs, source)

    if truthy?(value) do
      # Value is truthy, execute rest_body to compute final result
      do_execute(rest_body ++ rest, regs, upvals, state)
    else
      # Value is falsy, store it in dest and continue
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvals, state)
    end
  end

  # test_or - short-circuit OR
  defp do_execute([{:test_or, dest, source, rest_body} | rest], regs, upvals, state) do
    value = elem(regs, source)

    if truthy?(value) do
      # Value is truthy, store it in dest and continue
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvals, state)
    else
      # Value is falsy, execute rest_body to compute final result
      do_execute(rest_body ++ rest, regs, upvals, state)
    end
  end

  # while_loop
  defp do_execute([{:while_loop, cond_body, test_reg, loop_body} | rest], regs, upvals, state) do
    # Execute condition
    {_results, regs, state} = do_execute(cond_body, regs, upvals, state)

    # Check condition
    if truthy?(elem(regs, test_reg)) do
      # Execute body
      {_results, regs, state} = do_execute(loop_body, regs, upvals, state)
      # Loop again
      do_execute([{:while_loop, cond_body, test_reg, loop_body} | rest], regs, upvals, state)
    else
      # Condition false, continue after loop
      do_execute(rest, regs, upvals, state)
    end
  end

  # repeat_loop
  defp do_execute([{:repeat_loop, loop_body, cond_body, test_reg} | rest], regs, upvals, state) do
    # Execute body
    {_results, regs, state} = do_execute(loop_body, regs, upvals, state)

    # Execute condition
    {_results, regs, state} = do_execute(cond_body, regs, upvals, state)

    # Check condition (repeat UNTIL condition is true)
    if truthy?(elem(regs, test_reg)) do
      # Condition true, exit loop
      do_execute(rest, regs, upvals, state)
    else
      # Condition false, loop again
      do_execute([{:repeat_loop, loop_body, cond_body, test_reg} | rest], regs, upvals, state)
    end
  end

  # numeric_for
  defp do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvals, state) do
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
      {_results, regs, state} = do_execute(body, regs, upvals, state)

      # Increment counter
      new_counter = counter + step
      regs = put_elem(regs, base, new_counter)

      # Loop again
      do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvals, state)
    else
      # Loop finished
      do_execute(rest, regs, upvals, state)
    end
  end

  # return
  defp do_execute([{:return, base, count} | _rest], regs, _upvals, state) do
    results =
      if count == 0 do
        [nil]
      else
        for i <- 0..(count - 1), do: elem(regs, base + i)
      end

    {results, regs, state}
  end

  # Arithmetic operations
  defp do_execute([{:add, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) + elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:subtract, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) - elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:multiply, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) * elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:divide, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) / elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:floor_divide, dest, a, b} | rest], regs, upvals, state) do
    result = div(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:modulo, dest, a, b} | rest], regs, upvals, state) do
    result = rem(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:power, dest, a, b} | rest], regs, upvals, state) do
    result = :math.pow(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  # Bitwise operations
  defp do_execute([{:bitwise_and, dest, a, b} | rest], regs, upvals, state) do
    result = Bitwise.band(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:bitwise_or, dest, a, b} | rest], regs, upvals, state) do
    result = Bitwise.bor(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:bitwise_xor, dest, a, b} | rest], regs, upvals, state) do
    result = Bitwise.bxor(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:shift_left, dest, a, b} | rest], regs, upvals, state) do
    result = Bitwise.bsl(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:shift_right, dest, a, b} | rest], regs, upvals, state) do
    result = Bitwise.bsr(trunc(elem(regs, a)), trunc(elem(regs, b)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:bitwise_not, dest, source} | rest], regs, upvals, state) do
    result = Bitwise.bnot(trunc(elem(regs, source)))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  # Comparison operations
  defp do_execute([{:equal, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) == elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:less_than, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) < elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:less_equal, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) <= elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:greater_than, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) > elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:greater_equal, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) >= elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:not_equal, dest, a, b} | rest], regs, upvals, state) do
    result = elem(regs, a) != elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  # Unary operations
  defp do_execute([{:negate, dest, source} | rest], regs, upvals, state) do
    result = -elem(regs, source)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:not, dest, source} | rest], regs, upvals, state) do
    result = not truthy?(elem(regs, source))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  defp do_execute([{:length, dest, source} | rest], regs, upvals, state) do
    # For now, handle string length. Will add table/list length later
    value = elem(regs, source)

    result =
      cond do
        is_binary(value) -> byte_size(value)
        is_list(value) -> length(value)
        true -> 0
      end

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvals, state)
  end

  # Catch-all for unimplemented instructions
  defp do_execute([instr | _rest], _regs, _upvals, _state) do
    raise "Unimplemented instruction: #{inspect(instr)}"
  end

  # Helper for Lua truthiness
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true
end
