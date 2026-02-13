defmodule Lua.VM.Executor do
  @moduledoc """
  Instruction executor for the Lua VM.

  Tail-recursive dispatch loop that executes instructions.
  """

  alias Lua.VM.InternalError
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.TypeError
  alias Lua.VM.Value

  @doc """
  Executes instructions with the given register file and state.

  Returns {results, final_registers, final_state}.
  """
  @spec execute([tuple()], tuple(), list(), map(), State.t()) ::
          {list(), tuple(), State.t()}
  def execute(instructions, registers, upvalues, proto, state) do
    state = %{state | open_upvalues: %{}}
    do_execute(instructions, registers, upvalues, proto, state)
  end

  @doc """
  Calls a Lua function value with the given arguments.

  Used by pcall/xpcall to invoke functions in protected mode.
  Returns {results, final_state}.
  """
  @spec call_function(term(), list(), State.t()) :: {list(), State.t()}
  def call_function({:lua_closure, callee_proto, callee_upvalues}, args, state) do
    callee_regs =
      Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 64)

    callee_regs =
      args
      |> Enum.with_index()
      |> Enum.reduce(callee_regs, fn {arg, i}, regs ->
        if i < callee_proto.param_count, do: put_elem(regs, i, arg), else: regs
      end)

    callee_proto =
      if callee_proto.is_vararg do
        %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)}
      else
        callee_proto
      end

    saved_open_upvalues = state.open_upvalues
    state = %{state | open_upvalues: %{}}

    {results, _callee_regs, state} =
      do_execute(
        callee_proto.instructions,
        callee_regs,
        callee_upvalues,
        callee_proto,
        state
      )

    state = %{state | open_upvalues: saved_open_upvalues}
    {results, state}
  end

  def call_function({:native_func, fun}, args, state) do
    case fun.(args, state) do
      {results, %State{} = new_state} when is_list(results) ->
        {results, new_state}

      {results, %State{} = new_state} ->
        {List.wrap(results), new_state}
    end
  end

  def call_function(nil, _args, _state) do
    raise TypeError,
      value: "attempt to call a nil value",
      error_kind: :call_nil,
      value_type: nil
  end

  def call_function(other, args, state) do
    # Check for __call metamethod
    case get_metatable(other, state) do
      nil ->
        raise TypeError,
          value: "attempt to call a #{Value.type_name(other)} value",
          error_kind: :call_non_function,
          value_type: value_type(other)

      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        case Map.get(mt.data, "__call") do
          nil ->
            raise TypeError,
              value: "attempt to call a #{Value.type_name(other)} value",
              error_kind: :call_non_function,
              value_type: value_type(other)

          call_mm ->
            call_function(call_mm, [other | args], state)
        end
    end
  end

  # Break instruction - signal to exit loop
  defp do_execute([:break | _rest], regs, _upvalues, _proto, state) do
    {:break, regs, state}
  end

  # Goto instruction - find the label and jump to it
  defp do_execute([{:goto, label} | rest], regs, upvalues, proto, state) do
    # Search in the remaining instructions for the label
    case find_label(rest, label) do
      {:found, after_label} ->
        do_execute(after_label, regs, upvalues, proto, state)

      :not_found ->
        raise InternalError, value: "goto target '#{label}' not found"
    end
  end

  # Label instruction - just a marker, skip it
  defp do_execute([{:label, _name} | rest], regs, upvalues, proto, state) do
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Empty instruction list - implicit return (no values)
  defp do_execute([], regs, _upvalues, _proto, state) do
    {[], regs, state}
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
  defp do_execute([{:get_upvalue, dest, index} | rest], regs, upvalues, proto, state) do
    cell_ref = Enum.at(upvalues, index)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_upvalue
  defp do_execute([{:set_upvalue, index, source} | rest], regs, upvalues, proto, state) do
    cell_ref = Enum.at(upvalues, index)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_open_upvalue - read a captured local through its open upvalue cell
  defp do_execute([{:get_open_upvalue, dest, reg} | rest], regs, upvalues, proto, state) do
    cell_ref = Map.fetch!(state.open_upvalues, reg)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_open_upvalue - write a captured local through its open upvalue cell
  defp do_execute([{:set_open_upvalue, reg, source} | rest], regs, upvalues, proto, state) do
    cell_ref = Map.fetch!(state.open_upvalues, reg)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalues, proto, state)
  end

  # source_line - track current source location
  defp do_execute([{:source_line, line, _file} | rest], regs, upvalues, proto, state) do
    state = %{state | current_line: line}
    do_execute(rest, regs, upvalues, proto, state)
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

    case do_execute(body, regs, upvalues, proto, state) do
      {:break, regs, state} ->
        # Propagate break through conditionals to enclosing loop
        {:break, regs, state}

      {results, regs, state} when results != [] ->
        # Body had a return statement — propagate the return
        {results, regs, state}

      {_results, regs, state} ->
        do_execute(rest, regs, upvalues, proto, state)
    end
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
  defp do_execute([{:while_loop, cond_body, test_reg, loop_body} | rest], regs, upvalues, proto, state) do
    # Execute condition
    {_results, regs, state} = do_execute(cond_body, regs, upvalues, proto, state)

    # Check condition
    if Value.truthy?(elem(regs, test_reg)) do
      # Execute body
      case do_execute(loop_body, regs, upvalues, proto, state) do
        {:break, regs, state} ->
          # Break exits the loop
          do_execute(rest, regs, upvalues, proto, state)

        {_results, regs, state} ->
          # Loop again
          do_execute(
            [{:while_loop, cond_body, test_reg, loop_body} | rest],
            regs,
            upvalues,
            proto,
            state
          )
      end
    else
      # Condition false, continue after loop
      do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # repeat_loop
  defp do_execute([{:repeat_loop, loop_body, cond_body, test_reg} | rest], regs, upvalues, proto, state) do
    # Execute body
    case do_execute(loop_body, regs, upvalues, proto, state) do
      {:break, regs, state} ->
        # Break exits the loop
        do_execute(rest, regs, upvalues, proto, state)

      {_results, regs, state} ->
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

      # Clear open upvalue cells for loop-local registers (loop var + body locals)
      # so each iteration gets fresh upvalue cells for its own variables
      state = %{
        state
        | open_upvalues:
            Map.reject(state.open_upvalues, fn {reg, _} -> reg >= loop_var end)
      }

      # Execute body
      case do_execute(body, regs, upvalues, proto, state) do
        {:break, regs, state} ->
          # Break exits the loop
          do_execute(rest, regs, upvalues, proto, state)

        {_results, regs, state} ->
          # Increment counter
          new_counter = counter + step
          regs = put_elem(regs, base, new_counter)

          # Loop again
          do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvalues, proto, state)
      end
    else
      # Loop finished
      do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # generic_for - generic for loop (for k, v in iterator do ... end)
  defp do_execute([{:generic_for, base, var_regs, body} | rest], regs, upvalues, proto, state) do
    # Read iterator function, invariant state, control from internal registers
    iter_func = elem(regs, base)
    invariant_state = elem(regs, base + 1)
    control = elem(regs, base + 2)

    # Call iterator: f(state, control)
    {results, state} = call_value(iter_func, [invariant_state, control], proto, state)

    # If first result is nil, exit loop
    first_result = List.first(results)

    if first_result == nil do
      do_execute(rest, regs, upvalues, proto, state)
    else
      # Update control variable
      regs = put_elem(regs, base + 2, first_result)

      # Copy results to loop variable registers
      regs =
        var_regs
        |> Enum.with_index()
        |> Enum.reduce(regs, fn {var_reg, i}, regs ->
          put_elem(regs, var_reg, Enum.at(results, i))
        end)

      # Clear open upvalue cells for loop-local registers
      first_var_reg = List.first(var_regs)

      state = %{
        state
        | open_upvalues:
            Map.reject(state.open_upvalues, fn {reg, _} -> reg >= first_var_reg end)
      }

      # Execute body
      case do_execute(body, regs, upvalues, proto, state) do
        {:break, regs, state} ->
          # Break exits the loop
          do_execute(rest, regs, upvalues, proto, state)

        {_results, regs, state} ->
          # Loop again
          do_execute(
            [{:generic_for, base, var_regs, body} | rest],
            regs,
            upvalues,
            proto,
            state
          )
      end
    end
  end

  # closure - create a closure value from a prototype, capturing upvalues
  defp do_execute([{:closure, dest, proto_index} | rest], regs, upvalues, proto, state) do
    nested_proto = Enum.at(proto.prototypes, proto_index)

    # Capture upvalues based on descriptors, reusing open upvalue cells when available
    {captured_upvalues, state} =
      Enum.reduce(nested_proto.upvalue_descriptors, {[], state}, fn
        {:parent_local, reg, _name}, {cells, state} ->
          case Map.get(state.open_upvalues, reg) do
            nil ->
              # Create a new cell for this local variable
              cell_ref = make_ref()
              value = elem(regs, reg)

              state = %{
                state
                | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value),
                  open_upvalues: Map.put(state.open_upvalues, reg, cell_ref)
              }

              {cells ++ [cell_ref], state}

            existing_cell ->
              # Reuse existing open upvalue cell
              {cells ++ [existing_cell], state}
          end

        {:parent_upvalue, index, _name}, {cells, state} ->
          # Share the parent's upvalue cell
          {cells ++ [Enum.at(upvalues, index)], state}
      end)

    closure = {:lua_closure, nested_proto, captured_upvalues}
    regs = put_elem(regs, dest, closure)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # call - invoke a function value
  defp do_execute([{:call, base, arg_count, result_count} | rest], regs, upvalues, proto, state) do
    func_value = elem(regs, base)

    # Collect arguments from registers base+1..base+arg_count
    # arg_count < 0 encodes fixed args + varargs:
    # -1 means 0 fixed + varargs, -2 means 1 fixed + varargs, etc.
    # arg_count = {:multi, fixed} encodes fixed args + multi-return expansion
    args =
      case arg_count do
        {:multi, fixed_count} ->
          # Fixed args + results from a multi-return call
          multi_count = state.multi_return_count
          total = fixed_count + multi_count

          if total > 0 do
            for i <- 1..total, do: elem(regs, base + i)
          else
            []
          end

        n when is_integer(n) and n > 0 ->
          for i <- 1..n, do: elem(regs, base + i)

        n when is_integer(n) and n < 0 ->
          # Collect fixed args + all varargs
          # Decode: -1 => 0 fixed, -2 => 1 fixed, -3 => 2 fixed, etc.
          fixed_arg_count = -(n + 1)
          total_args = fixed_arg_count + state.multi_return_count

          if total_args > 0 do
            for i <- 1..total_args, do: elem(regs, base + i)
          else
            []
          end

        0 ->
          []
      end

    {results, state} =
      case func_value do
        {:lua_closure, callee_proto, callee_upvalues} ->
          # Push call stack frame
          frame = %{
            source: proto.source,
            line: Map.get(state, :current_line, 0),
            name: nil
          }

          state = %{state | call_stack: [frame | state.call_stack]}

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

          # Populate varargs if function is vararg
          callee_proto =
            if callee_proto.is_vararg do
              %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)}
            else
              callee_proto
            end

          # Execute the callee with fresh open_upvalues
          saved_open_upvalues = state.open_upvalues
          state = %{state | open_upvalues: %{}}

          {results, _callee_regs, state} =
            do_execute(
              callee_proto.instructions,
              callee_regs,
              callee_upvalues,
              callee_proto,
              state
            )

          # Pop call stack frame, restore open_upvalues
          state = %{state | call_stack: tl(state.call_stack), open_upvalues: saved_open_upvalues}

          {results, state}

        {:native_func, fun} ->
          case fun.(args, state) do
            {results, %State{} = new_state} when is_list(results) ->
              {results, new_state}

            {results, %State{} = new_state} ->
              {List.wrap(results), new_state}

            other ->
              raise InternalError,
                value: "native function returned invalid result: #{inspect(other)}, expected {results, state}"
          end

        nil ->
          raise TypeError,
            value: "attempt to call a nil value",
            source: proto.source,
            call_stack: state.call_stack,
            line: Map.get(state, :current_line),
            error_kind: :call_nil,
            value_type: nil

        other ->
          # Check for __call metamethod
          case get_metatable(other, state) do
            nil ->
              raise TypeError,
                value: "attempt to call a #{Value.type_name(other)} value",
                source: proto.source,
                call_stack: state.call_stack,
                line: Map.get(state, :current_line),
                error_kind: :call_non_function,
                value_type: value_type(other)

            {:tref, mt_id} ->
              mt = Map.fetch!(state.tables, mt_id)

              case Map.get(mt.data, "__call") do
                nil ->
                  raise TypeError,
                    value: "attempt to call a #{Value.type_name(other)} value",
                    source: proto.source,
                    call_stack: state.call_stack,
                    line: Map.get(state, :current_line),
                    error_kind: :call_non_function,
                    value_type: value_type(other)

                call_mm ->
                  call_function(call_mm, [other | args], state)
              end
          end
      end

    cond do
      # result_count == -1 means "return all results" (used in return f() position)
      result_count == -1 ->
        {results, regs, state}

      # result_count == -2 means "multi-return expansion": place all results into
      # registers starting at base, store count in state, continue execution
      result_count == -2 ->
        results_list = List.wrap(results)

        regs =
          results_list
          |> Enum.with_index()
          |> Enum.reduce(regs, fn {val, i}, regs ->
            put_elem(regs, base + i, val)
          end)

        state = %{state | multi_return_count: length(results_list)}
        do_execute(rest, regs, upvalues, proto, state)

      true ->
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

        do_execute(rest, regs, upvalues, proto, state)
    end
  end

  # vararg - load vararg values into registers
  # count == 0 means load all varargs, count > 0 means load exactly count values
  defp do_execute([{:vararg, base, count} | rest], regs, upvalues, proto, state) do
    varargs = Map.get(proto, :varargs, [])

    {regs, state} =
      if count == 0 do
        # Load all varargs and track the count for set_list/call
        regs =
          Enum.reduce(Enum.with_index(varargs), regs, fn {val, i}, regs ->
            put_elem(regs, base + i, val)
          end)

        {regs, %{state | multi_return_count: length(varargs)}}
      else
        # Load exactly count values
        regs =
          Enum.reduce(0..(count - 1), regs, fn i, regs ->
            put_elem(regs, base + i, Enum.at(varargs, i))
          end)

        {regs, state}
      end

    do_execute(rest, regs, upvalues, proto, state)
  end

  # return_vararg - return all varargs
  defp do_execute([{:return_vararg} | _rest], regs, _upvalues, proto, state) do
    varargs = Map.get(proto, :varargs, [])
    {varargs, regs, state}
  end

  # return
  # count == -1 means return from base including all varargs
  # count == 0 means return nil
  # count > 0 means return exactly count values
  # count == {:multi_return, fixed} means return fixed values + multi-return expanded values
  defp do_execute([{:return, base, {:multi_return, fixed_count}} | _rest], regs, _upvalues, _proto, state) do
    total = fixed_count + state.multi_return_count
    results = if total > 0, do: for(i <- 0..(total - 1), do: elem(regs, base + i)), else: []
    {results, regs, state}
  end

  defp do_execute([{:return, base, count} | _rest], regs, _upvalues, _proto, state) do
    results =
      cond do
        count == 0 ->
          [nil]

        count < 0 ->
          # Negative count encodes fixed values + variable values (vararg or multi-return)
          # -(init_count + 1): e.g. -1 = 0 fixed, -2 = 1 fixed, -3 = 2 fixed
          init_count = -(count + 1)
          total = init_count + state.multi_return_count

          if total > 0 do
            for i <- 0..(total - 1), do: elem(regs, base + i)
          else
            []
          end

        count > 0 ->
          for i <- 0..(count - 1), do: elem(regs, base + i)
      end

    {results, regs, state}
  end

  # Arithmetic operations
  defp do_execute([{:add, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__add", val_a, val_b, state, fn -> safe_add(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:subtract, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__sub", val_a, val_b, state, fn -> safe_subtract(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:multiply, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__mul", val_a, val_b, state, fn -> safe_multiply(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:divide, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__div", val_a, val_b, state, fn -> safe_divide(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:floor_divide, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__idiv", val_a, val_b, state, fn ->
        safe_floor_divide(val_a, val_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:modulo, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__mod", val_a, val_b, state, fn -> safe_modulo(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:power, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__pow", val_a, val_b, state, fn -> safe_power(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  # String concatenation
  defp do_execute([{:concatenate, dest, a, b} | rest], regs, upvalues, proto, state) do
    left = elem(regs, a)
    right = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__concat", left, right, state, fn ->
        concat_coerce(left) <> concat_coerce(right)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  # Bitwise operations
  defp do_execute([{:bitwise_and, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__band", val_a, val_b, state, fn ->
        Bitwise.band(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:bitwise_or, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__bor", val_a, val_b, state, fn ->
        Bitwise.bor(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:bitwise_xor, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__bxor", val_a, val_b, state, fn ->
        Bitwise.bxor(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:shift_left, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__shl", val_a, val_b, state, fn ->
        lua_shift_left(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:shift_right, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__shr", val_a, val_b, state, fn ->
        lua_shift_right(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:bitwise_not, dest, source} | rest], regs, upvalues, proto, state) do
    val = elem(regs, source)

    {result, new_state} =
      try_unary_metamethod("__bnot", val, state, fn ->
        Bitwise.bnot(to_integer!(val))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  # Comparison operations
  defp do_execute([{:equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_equality_metamethod(val_a, val_b, state, fn -> val_a == val_b end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:less_than, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__lt", val_a, val_b, state, fn -> safe_compare_lt(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:less_equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__le", val_a, val_b, state, fn -> safe_compare_le(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:greater_than, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = safe_compare_gt(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:greater_equal, dest, a, b} | rest], regs, upvalues, proto, state) do
    result = safe_compare_ge(elem(regs, a), elem(regs, b))
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
    val = elem(regs, source)
    {result, new_state} = try_unary_metamethod("__unm", val, state, fn -> safe_negate(val) end)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  defp do_execute([{:not, dest, source} | rest], regs, upvalues, proto, state) do
    result = not Value.truthy?(elem(regs, source))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state)
  end

  defp do_execute([{:length, dest, source} | rest], regs, upvalues, proto, state) do
    value = elem(regs, source)

    {result, new_state} =
      try_unary_metamethod("__len", value, state, fn ->
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
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state)
  end

  # new_table
  defp do_execute([{:new_table, dest, _array_hint, _hash_hint} | rest], regs, upvalues, proto, state) do
    {tref, state} = State.alloc_table(state)
    regs = put_elem(regs, dest, tref)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_table — R[dest] = table[R[key_reg]]
  defp do_execute([{:get_table, dest, table_reg, key_reg} | rest], regs, upvalues, proto, state) do
    table_val = elem(regs, table_reg)
    key = elem(regs, key_reg)

    {value, state} = index_value(table_val, key, state)

    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_table — table[R[key_reg]] = R[value_reg]
  defp do_execute([{:set_table, table_reg, key_reg, value_reg} | rest], regs, upvalues, proto, state) do
    {:tref, _} = elem(regs, table_reg)
    key = elem(regs, key_reg)
    value = elem(regs, value_reg)

    state = table_newindex(elem(regs, table_reg), key, value, state)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # get_field — R[dest] = table[name] (string key literal)
  defp do_execute([{:get_field, dest, table_reg, name} | rest], regs, upvalues, proto, state) do
    table_val = elem(regs, table_reg)

    {value, state} = index_value(table_val, name, state)

    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_field — table[name] = R[value_reg]
  defp do_execute([{:set_field, table_reg, name, value_reg} | rest], regs, upvalues, proto, state) do
    {:tref, _} = elem(regs, table_reg)
    value = elem(regs, value_reg)

    state = table_newindex(elem(regs, table_reg), name, value, state)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_list with {:multi, init_count} — multi-return expansion in table constructor
  defp do_execute([{:set_list, table_reg, start, {:multi, init_count}, offset} | rest], regs, upvalues, proto, state) do
    {:tref, id} = elem(regs, table_reg)
    total = init_count + state.multi_return_count

    state =
      State.update_table(state, {:tref, id}, fn table ->
        new_data =
          if total > 0 do
            Enum.reduce(0..(total - 1), table.data, fn i, data ->
              value = elem(regs, start + i)
              Map.put(data, offset + i + 1, value)
            end)
          else
            table.data
          end

        %{table | data: new_data}
      end)

    do_execute(rest, regs, upvalues, proto, state)
  end

  # set_list — bulk store: table[offset+i] = R[start+i-1] for i in 1..count
  # count == 0 means variable number of values (from vararg or multi-return)
  defp do_execute([{:set_list, table_reg, start, count, offset} | rest], regs, upvalues, proto, state) do
    {:tref, id} = elem(regs, table_reg)

    state =
      State.update_table(state, {:tref, id}, fn table ->
        new_data =
          if count == 0 do
            # Variable number of values - use multi_return_count which is set by
            # both vararg (count=0) and call (result_count=-2) instructions
            values_to_collect = state.multi_return_count

            if values_to_collect > 0 do
              Enum.reduce(0..(values_to_collect - 1), table.data, fn i, data ->
                value = elem(regs, start + i)
                Map.put(data, offset + i + 1, value)
              end)
            else
              table.data
            end
          else
            # Fixed number of values
            Enum.reduce(1..count, table.data, fn i, data ->
              value = elem(regs, start + i - 1)
              Map.put(data, offset + i, value)
            end)
          end

        %{table | data: new_data}
      end)

    do_execute(rest, regs, upvalues, proto, state)
  end

  # self — R[base+1] = R[obj_reg], R[base] = R[obj_reg]["method"]
  defp do_execute([{:self, base, obj_reg, method_name} | rest], regs, upvalues, proto, state) do
    obj = elem(regs, obj_reg)
    {func, state} = index_value(obj, method_name, state)

    regs = put_elem(regs, base + 1, obj)
    regs = put_elem(regs, base, func)
    do_execute(rest, regs, upvalues, proto, state)
  end

  # Catch-all for unimplemented instructions
  defp do_execute([instr | _rest], _regs, _upvalues, _proto, _state) do
    raise InternalError, value: "unimplemented instruction: #{inspect(instr)}"
  end

  # Find a label in the instruction list (scanning forward and into nested blocks)
  defp find_label([], _label), do: :not_found

  defp find_label([{:label, name} | rest], label) when name == label do
    {:found, rest}
  end

  defp find_label([{:test, _reg, then_body, else_body} | rest], label) do
    # Search in then_body and else_body, and also after the test
    case find_label(then_body, label) do
      {:found, _} = found ->
        found

      :not_found ->
        case find_label(else_body, label) do
          {:found, _} = found -> found
          :not_found -> find_label(rest, label)
        end
    end
  end

  defp find_label([_ | rest], label), do: find_label(rest, label)

  # Helper: call a function value inline (used by generic_for)
  defp call_value({:lua_closure, callee_proto, callee_upvalues}, args, _proto, state) do
    callee_regs =
      Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 64)

    callee_regs =
      args
      |> Enum.with_index()
      |> Enum.reduce(callee_regs, fn {arg, i}, regs ->
        if i < callee_proto.param_count, do: put_elem(regs, i, arg), else: regs
      end)

    callee_proto =
      if callee_proto.is_vararg do
        %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)}
      else
        callee_proto
      end

    saved_open_upvalues = state.open_upvalues
    state = %{state | open_upvalues: %{}}

    {results, _callee_regs, state} =
      do_execute(
        callee_proto.instructions,
        callee_regs,
        callee_upvalues,
        callee_proto,
        state
      )

    state = %{state | open_upvalues: saved_open_upvalues}
    {results, state}
  end

  defp call_value({:native_func, fun}, args, _proto, state) do
    case fun.(args, state) do
      {results, %State{} = new_state} when is_list(results) ->
        {results, new_state}

      {results, %State{} = new_state} ->
        {List.wrap(results), new_state}
    end
  end

  defp call_value(nil, _args, proto, state) do
    raise TypeError,
      value: "attempt to call a nil value",
      source: proto.source,
      call_stack: state.call_stack,
      line: Map.get(state, :current_line),
      error_kind: :call_nil,
      value_type: nil
  end

  defp call_value(other, args, proto, state) do
    # Check for __call metamethod
    case get_metatable(other, state) do
      nil ->
        raise TypeError,
          value: "attempt to call a #{Value.type_name(other)} value",
          source: proto.source,
          call_stack: state.call_stack,
          line: Map.get(state, :current_line),
          error_kind: :call_non_function,
          value_type: value_type(other)

      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        case Map.get(mt.data, "__call") do
          nil ->
            raise TypeError,
              value: "attempt to call a #{Value.type_name(other)} value",
              source: proto.source,
              call_stack: state.call_stack,
              line: Map.get(state, :current_line),
              error_kind: :call_non_function,
              value_type: value_type(other)

          call_mm ->
            call_value(call_mm, [other | args], proto, state)
        end
    end
  end

  # Coerce a value to a string for concatenation (Lua semantics: numbers become strings)
  defp concat_coerce(value) when is_binary(value), do: value
  defp concat_coerce(value) when is_integer(value), do: Integer.to_string(value)
  defp concat_coerce(value) when is_float(value), do: Value.to_string(value)

  defp concat_coerce(value) do
    raise TypeError,
      value: "attempt to concatenate a #{Value.type_name(value)} value",
      error_kind: :concatenate_type_error,
      value_type: value_type(value)
  end

  # Metamethod support

  # Depth limit for metamethod chains (prevents infinite loops)
  @metamethod_chain_limit 200

  defp get_metatable({:tref, id}, state) do
    table = Map.fetch!(state.tables, id)
    table.metatable
  end

  defp get_metatable(value, state) when is_binary(value) do
    Map.get(state.metatables, "string")
  end

  defp get_metatable(_value, _state), do: nil

  # Index any value — dispatches to table_index or type metatable __index, or raises
  defp index_value({:tref, _} = tref, key, state) do
    table_index(tref, key, state)
  end

  defp index_value(value, key, state) do
    case get_metatable(value, state) do
      nil ->
        raise TypeError,
          value: "attempt to index a #{Value.type_name(value)} value",
          error_kind: :index_non_table,
          value_type: value_type(value)

      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        case Map.get(mt.data, "__index") do
          nil ->
            raise TypeError,
              value: "attempt to index a #{Value.type_name(value)} value",
              error_kind: :index_non_table,
              value_type: value_type(value)

          {:tref, _} = idx_tbl ->
            table_index(idx_tbl, key, state)

          func when is_tuple(func) ->
            {results, state} = call_function(func, [value, key], state)
            {List.first(results), state}
        end
    end
  end

  # Resolve table[key] with __index metamethod chain support
  defp table_index({:tref, id}, key, state, depth \\ 0) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__index' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    case Map.get(table.data, key) do
      nil ->
        # Key not found, check for __index metamethod
        case table.metatable do
          nil ->
            {nil, state}

          {:tref, mt_id} ->
            mt = Map.fetch!(state.tables, mt_id)

            case Map.get(mt.data, "__index") do
              nil ->
                {nil, state}

              {:tref, _} = index_table ->
                # __index is a table, recursively look up in it
                table_index(index_table, key, state, depth + 1)

              func when is_tuple(func) ->
                # __index is a function, call it with (table, key)
                {results, state} = call_function(func, [{:tref, id}, key], state)
                {List.first(results), state}
            end
        end

      v ->
        {v, state}
    end
  end

  # Resolve table[key] = value with __newindex metamethod chain support
  defp table_newindex({:tref, id}, key, value, state, depth \\ 0) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__newindex' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    if Map.has_key?(table.data, key) do
      # Key exists, update directly (rawset)
      State.update_table(state, {:tref, id}, fn t ->
        %{t | data: Map.put(t.data, key, value)}
      end)
    else
      # Key doesn't exist, check for __newindex metamethod
      case table.metatable do
        nil ->
          # No metatable, just set the value
          State.update_table(state, {:tref, id}, fn t ->
            %{t | data: Map.put(t.data, key, value)}
          end)

        {:tref, mt_id} ->
          mt = Map.fetch!(state.tables, mt_id)

          case Map.get(mt.data, "__newindex") do
            nil ->
              # No __newindex, just set the value
              State.update_table(state, {:tref, id}, fn t ->
                %{t | data: Map.put(t.data, key, value)}
              end)

            {:tref, _} = newindex_table ->
              # __newindex is a table, set in that table (with chaining)
              table_newindex(newindex_table, key, value, state, depth + 1)

            func when is_tuple(func) ->
              # __newindex is a function, call it with (table, key, value)
              {_results, state} = call_function(func, [{:tref, id}, key, value], state)
              state
          end
      end
    end
  end

  defp try_binary_metamethod(metamethod_name, a, b, state, default_fn) do
    # Try a's metatable first
    mt_a = get_metatable(a, state)
    mt_b = get_metatable(b, state)

    metamethod =
      cond do
        mt_a != nil ->
          mt = Map.fetch!(state.tables, elem(mt_a, 1))
          Map.get(mt.data, metamethod_name)

        mt_b != nil ->
          mt = Map.fetch!(state.tables, elem(mt_b, 1))
          Map.get(mt.data, metamethod_name)

        true ->
          nil
      end

    case metamethod do
      {:native_func, func} ->
        {[result], new_state} = func.([a, b], state)
        {result, new_state}

      {:lua_closure, callee_proto, callee_upvalues} ->
        # Call the Lua closure metamethod
        args = [a, b]
        initial_regs = List.to_tuple(args ++ List.duplicate(nil, 248))
        saved_open_upvalues = state.open_upvalues
        state = %{state | open_upvalues: %{}}

        {results, _final_regs, new_state} =
          do_execute(
            callee_proto.instructions,
            initial_regs,
            callee_upvalues,
            callee_proto,
            state
          )

        new_state = %{new_state | open_upvalues: saved_open_upvalues}

        result =
          case results do
            [r | _] -> r
            [] -> nil
          end

        {result, new_state}

      nil ->
        {default_fn.(), state}

      _ ->
        {default_fn.(), state}
    end
  end

  defp try_unary_metamethod(metamethod_name, a, state, default_fn) do
    mt = get_metatable(a, state)

    metamethod =
      case mt do
        nil ->
          nil

        {:tref, mt_id} ->
          mt_table = Map.fetch!(state.tables, mt_id)
          Map.get(mt_table.data, metamethod_name)
      end

    case metamethod do
      {:native_func, func} ->
        {[result], new_state} = func.([a], state)
        {result, new_state}

      {:lua_closure, callee_proto, callee_upvalues} ->
        # Call the Lua closure metamethod
        args = [a]
        initial_regs = List.to_tuple(args ++ List.duplicate(nil, 249))
        saved_open_upvalues = state.open_upvalues
        state = %{state | open_upvalues: %{}}

        {results, _final_regs, new_state} =
          do_execute(
            callee_proto.instructions,
            initial_regs,
            callee_upvalues,
            callee_proto,
            state
          )

        new_state = %{new_state | open_upvalues: saved_open_upvalues}

        result =
          case results do
            [r | _] -> r
            [] -> nil
          end

        {result, new_state}

      nil ->
        {default_fn.(), state}

      _ ->
        {default_fn.(), state}
    end
  end

  # Special handling for __eq metamethod
  # In Lua, __eq only triggers if both operands have the exact same __eq metamethod
  defp try_equality_metamethod(a, b, state, default_fn) do
    mt_a = get_metatable(a, state)
    mt_b = get_metatable(b, state)

    # Get __eq from both metatables
    eq_a =
      case mt_a do
        nil -> nil
        {:tref, mt_id} -> Map.get(Map.fetch!(state.tables, mt_id).data, "__eq")
      end

    eq_b =
      case mt_b do
        nil -> nil
        {:tref, mt_id} -> Map.get(Map.fetch!(state.tables, mt_id).data, "__eq")
      end

    # Only use metamethod if both have the SAME __eq metamethod
    if not is_nil(eq_a) and eq_a == eq_b do
      case eq_a do
        {:native_func, func} ->
          {[result], new_state} = func.([a, b], state)
          {result, new_state}

        {:lua_closure, callee_proto, callee_upvalues} ->
          args = [a, b]
          initial_regs = List.to_tuple(args ++ List.duplicate(nil, 248))
          saved_open_upvalues = state.open_upvalues
          state = %{state | open_upvalues: %{}}

          {results, _final_regs, new_state} =
            do_execute(
              callee_proto.instructions,
              initial_regs,
              callee_upvalues,
              callee_proto,
              state
            )

          new_state = %{new_state | open_upvalues: saved_open_upvalues}

          result =
            case results do
              [r | _] -> r
              [] -> nil
            end

          {result, new_state}

        _ ->
          {default_fn.(), state}
      end
    else
      # No metamethod or different metamethods, use default comparison
      {default_fn.(), state}
    end
  end

  # Type-safe arithmetic operations
  defp safe_add(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      na + nb
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_subtract(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      na - nb
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_multiply(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      na * nb
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_divide(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      # Check for division by zero
      # Note: Standard Lua 5.3 returns inf/-inf/nan for float division by zero,
      # but Elixir doesn't support creating these values easily, so we raise an error
      if nb == 0 or nb == 0.0 do
        raise RuntimeError, value: "attempt to divide by zero"
      else
        na / nb
      end
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_floor_divide(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      cond do
        nb == 0 or nb == 0.0 ->
          raise RuntimeError, value: "attempt to divide by zero"

        is_integer(na) and is_integer(nb) ->
          # Lua floor division for integers
          lua_idiv(na, nb)

        true ->
          # Float floor division
          Float.floor(na / nb) * 1.0
      end
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_modulo(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      cond do
        nb == 0 or nb == 0.0 ->
          raise RuntimeError, value: "attempt to perform modulo by zero"

        is_integer(na) and is_integer(nb) ->
          # Lua floor modulo for integers: a - floor_div(a, b) * b
          na - lua_idiv(na, nb) * nb

        true ->
          # Float floor modulo: a - floor(a/b) * b
          na - Float.floor(na / nb) * nb
      end
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  # Lua-style integer floor division (rounds toward negative infinity)
  defp lua_idiv(a, b) do
    q = div(a, b)
    r = rem(a, b)
    # Adjust if remainder has different sign than divisor
    if r != 0 and Bitwise.bxor(r, b) < 0, do: q - 1, else: q
  end

  defp safe_power(a, b) do
    with {:ok, na} <- to_number(a),
         {:ok, nb} <- to_number(b) do
      :math.pow(na, nb)
    else
      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  defp safe_negate(a) do
    case to_number(a) do
      {:ok, na} ->
        -na

      {:error, val} ->
        raise TypeError,
          value: "attempt to perform arithmetic on a #{Value.type_name(val)} value",
          error_kind: :arithmetic_on_non_number,
          value_type: value_type(val)
    end
  end

  # Type-safe comparison operations
  defp safe_compare_lt(a, b) do
    cond do
      is_number(a) and is_number(b) ->
        a < b

      is_binary(a) and is_binary(b) ->
        a < b

      true ->
        raise TypeError,
          value: "attempt to compare #{Value.type_name(a)} with #{Value.type_name(b)}",
          error_kind: :compare_incompatible_types,
          value_type: value_type(a)
    end
  end

  defp safe_compare_le(a, b) do
    cond do
      is_number(a) and is_number(b) ->
        a <= b

      is_binary(a) and is_binary(b) ->
        a <= b

      true ->
        raise TypeError,
          value: "attempt to compare #{Value.type_name(a)} with #{Value.type_name(b)}",
          error_kind: :compare_incompatible_types,
          value_type: value_type(a)
    end
  end

  defp safe_compare_gt(a, b) do
    cond do
      is_number(a) and is_number(b) ->
        a > b

      is_binary(a) and is_binary(b) ->
        a > b

      true ->
        raise TypeError,
          value: "attempt to compare #{Value.type_name(a)} with #{Value.type_name(b)}",
          error_kind: :compare_incompatible_types,
          value_type: value_type(a)
    end
  end

  defp safe_compare_ge(a, b) do
    cond do
      is_number(a) and is_number(b) ->
        a >= b

      is_binary(a) and is_binary(b) ->
        a >= b

      true ->
        raise TypeError,
          value: "attempt to compare #{Value.type_name(a)} with #{Value.type_name(b)}",
          error_kind: :compare_incompatible_types,
          value_type: value_type(a)
    end
  end

  # Convert value to number (coerce strings like Lua does)
  defp to_number(v) when is_number(v), do: {:ok, v}

  defp to_number(v) when is_binary(v) do
    case Value.parse_number(v) do
      nil -> {:error, v}
      n -> {:ok, n}
    end
  end

  defp to_number(v), do: {:error, v}

  # Convert value to integer for bitwise operations (with string coercion)
  defp to_integer!(v) when is_integer(v), do: v
  defp to_integer!(v) when is_float(v), do: trunc(v)

  defp to_integer!(v) when is_binary(v) do
    case Value.parse_number(v) do
      nil ->
        raise TypeError,
          value: "attempt to perform bitwise operation on a string value",
          error_kind: :bitwise_on_non_integer,
          value_type: :string

      n ->
        trunc(n)
    end
  end

  defp to_integer!(v) do
    raise TypeError,
      value: "attempt to perform bitwise operation on a #{Value.type_name(v)} value",
      error_kind: :bitwise_on_non_integer,
      value_type: value_type(v)
  end

  # Lua 5.3 shift semantics: negative shift reverses direction, shift >= 64 yields 0
  defp lua_shift_left(_val, shift) when shift >= 64, do: 0
  defp lua_shift_left(_val, shift) when shift <= -64, do: 0
  defp lua_shift_left(val, shift) when shift < 0, do: lua_shift_right(val, -shift)

  defp lua_shift_left(val, shift) do
    Bitwise.band(Bitwise.bsl(val, shift), 0xFFFFFFFFFFFFFFFF)
  end

  defp lua_shift_right(_val, shift) when shift >= 64, do: 0
  defp lua_shift_right(_val, shift) when shift <= -64, do: 0
  defp lua_shift_right(val, shift) when shift < 0, do: lua_shift_left(val, -shift)

  defp lua_shift_right(val, shift) do
    # Unsigned right shift - mask to 64-bit first
    unsigned_val = Bitwise.band(val, 0xFFFFFFFFFFFFFFFF)
    Bitwise.bsr(unsigned_val, shift)
  end

  # Helper to determine Lua type from Elixir value
  defp value_type(nil), do: nil
  defp value_type(v) when is_boolean(v), do: :boolean
  defp value_type(v) when is_number(v), do: :number
  defp value_type(v) when is_binary(v), do: :string
  defp value_type({:tref, _}), do: :table
  defp value_type({:lua_closure, _, _}), do: :function
  defp value_type({:native_func, _}), do: :function
  defp value_type(_), do: :unknown
end
