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
