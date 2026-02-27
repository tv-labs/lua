defmodule Lua.VM.Executor do
  @moduledoc """
  Instruction executor for the Lua VM.

  Fully tail-recursive CPS dispatch loop. The do_execute/8 function never
  grows the Erlang call stack for Lua-to-Lua function calls or control flow.

  Signature: do_execute(instructions, registers, upvalues, proto, state, cont, frames, line)

    cont   — continuation stack: list of instruction lists or loop/CPS markers
    frames — call frame stack: saved caller context for each active Lua call
    line   — current source line (threaded to avoid State struct allocation)
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
    do_execute(instructions, registers, upvalues, proto, state, [], [], 0)
  end

  @doc """
  Calls a Lua function value with the given arguments.

  Used by pcall/xpcall to invoke functions in protected mode.
  Returns {results, final_state}.
  """
  @spec call_function(term(), list(), State.t()) :: {list(), State.t()}
  def call_function({:lua_closure, callee_proto, callee_upvalues}, args, state) do
    callee_regs =
      Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 16)

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
      do_execute(callee_proto.instructions, callee_regs, callee_upvalues, callee_proto, state, [], [], 0)

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

  # ── Break ──────────────────────────────────────────────────────────────────

  defp do_execute([:break | _rest], regs, upvalues, proto, state, cont, frames, line) do
    {exit_is, rest_cont} = find_loop_exit(cont)
    do_execute(exit_is, regs, upvalues, proto, state, rest_cont, frames, line)
  end

  # ── Goto ───────────────────────────────────────────────────────────────────

  defp do_execute([{:goto, label} | rest], regs, upvalues, proto, state, cont, frames, line) do
    case find_label(rest, label) do
      {:found, after_label} ->
        do_execute(after_label, regs, upvalues, proto, state, cont, frames, line)

      :not_found ->
        raise InternalError, value: "goto target '#{label}' not found"
    end
  end

  # ── Label ──────────────────────────────────────────────────────────────────

  defp do_execute([{:label, _name} | rest], regs, upvalues, proto, state, cont, frames, line) do
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── Instructions exhausted — handle continuations and frames ───────────────

  defp do_execute([], regs, upvalues, proto, state, cont, frames, line) do
    case cont do
      # Normal instruction continuation
      [next_is | rest_cont] when is_list(next_is) ->
        do_execute(next_is, regs, upvalues, proto, state, rest_cont, frames, line)

      # Fell off end of a loop body normally — consume the loop_exit marker
      [{:loop_exit, _} | rest_cont] ->
        do_execute([], regs, upvalues, proto, state, rest_cont, frames, line)

      # After while condition body — check test_reg; enter body or exit loop
      [{:cps_while_test, test_reg, loop_body, cond_body, rest, outer_cont} | _] ->
        loop_exit_cont = [{:loop_exit, rest} | outer_cont]

        if Value.truthy?(elem(regs, test_reg)) do
          body_done = {:cps_while_body, test_reg, loop_body, cond_body, rest, outer_cont}
          do_execute(loop_body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
        else
          do_execute(rest, regs, upvalues, proto, state, outer_cont, frames, line)
        end

      # After while loop body — restart condition
      [{:cps_while_body, test_reg, loop_body, cond_body, rest, outer_cont} | _] ->
        loop_exit_cont = [{:loop_exit, rest} | outer_cont]
        cond_check = {:cps_while_test, test_reg, loop_body, cond_body, rest, outer_cont}
        do_execute(cond_body, regs, upvalues, proto, state, [cond_check | loop_exit_cont], frames, line)

      # After repeat body — execute condition
      [{:cps_repeat_body, loop_body, cond_body, test_reg, rest, outer_cont} | _] ->
        loop_exit_cont = [{:loop_exit, rest} | outer_cont]
        cond_check = {:cps_repeat_cond, loop_body, cond_body, test_reg, rest, outer_cont}
        do_execute(cond_body, regs, upvalues, proto, state, [cond_check | loop_exit_cont], frames, line)

      # After repeat condition — check test_reg; exit or repeat
      [{:cps_repeat_cond, loop_body, cond_body, test_reg, rest, outer_cont} | _] ->
        if Value.truthy?(elem(regs, test_reg)) do
          # Condition true = exit loop (repeat UNTIL)
          do_execute(rest, regs, upvalues, proto, state, outer_cont, frames, line)
        else
          # Condition false = repeat body
          loop_exit_cont = [{:loop_exit, rest} | outer_cont]
          body_done = {:cps_repeat_body, loop_body, cond_body, test_reg, rest, outer_cont}
          do_execute(loop_body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
        end

      # After numeric_for body — increment counter and re-check
      [{:cps_numeric_for, base, loop_var, body, rest, outer_cont} | _] ->
        counter = elem(regs, base)
        step = elem(regs, base + 2)
        new_counter = counter + step
        regs = put_elem(regs, base, new_counter)
        limit = elem(regs, base + 1)
        should_continue = if step > 0, do: new_counter <= limit, else: new_counter >= limit

        if should_continue do
          regs = put_elem(regs, loop_var, new_counter)

          state = %{
            state
            | open_upvalues: Map.reject(state.open_upvalues, fn {reg, _} -> reg >= loop_var end)
          }

          loop_exit_cont = [{:loop_exit, rest} | outer_cont]
          body_done = {:cps_numeric_for, base, loop_var, body, rest, outer_cont}
          do_execute(body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
        else
          do_execute(rest, regs, upvalues, proto, state, outer_cont, frames, line)
        end

      # After generic_for body — call iterator and re-check
      [{:cps_generic_for, base, var_regs, body, rest, outer_cont} | _] ->
        iter_func = elem(regs, base)
        invariant_state = elem(regs, base + 1)
        control = elem(regs, base + 2)

        {results, state} = call_value(iter_func, [invariant_state, control], proto, state, line)
        first_result = List.first(results)

        if first_result == nil do
          do_execute(rest, regs, upvalues, proto, state, outer_cont, frames, line)
        else
          regs = put_elem(regs, base + 2, first_result)

          regs =
            var_regs
            |> Enum.with_index()
            |> Enum.reduce(regs, fn {var_reg, i}, r -> put_elem(r, var_reg, Enum.at(results, i)) end)

          first_var_reg = List.first(var_regs)

          state = %{
            state
            | open_upvalues: Map.reject(state.open_upvalues, fn {reg, _} -> reg >= first_var_reg end)
          }

          loop_exit_cont = [{:loop_exit, rest} | outer_cont]
          body_done = {:cps_generic_for, base, var_regs, body, rest, outer_cont}
          do_execute(body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
        end

      # Continuation stack exhausted — check frames for pending function return
      [] ->
        case frames do
          [] ->
            {[], regs, state}

          [frame | rest_frames] ->
            do_frame_return([], regs, state, frame, rest_frames, line)
        end
    end
  end

  # ── load_constant ──────────────────────────────────────────────────────────

  defp do_execute([{:load_constant, dest, value} | rest], regs, upvalues, proto, state, cont, frames, line) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── load_boolean ───────────────────────────────────────────────────────────

  defp do_execute([{:load_boolean, dest, value} | rest], regs, upvalues, proto, state, cont, frames, line) do
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── get_global ─────────────────────────────────────────────────────────────

  defp do_execute([{:get_global, dest, name} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = Map.get(state.globals, name, nil)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_global ─────────────────────────────────────────────────────────────

  defp do_execute([{:set_global, name, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = elem(regs, source)
    state = %{state | globals: Map.put(state.globals, name, value)}
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── get_upvalue ────────────────────────────────────────────────────────────

  defp do_execute([{:get_upvalue, dest, index} | rest], regs, upvalues, proto, state, cont, frames, line) do
    cell_ref = elem(upvalues, index)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_upvalue ────────────────────────────────────────────────────────────

  defp do_execute([{:set_upvalue, index, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    cell_ref = elem(upvalues, index)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── get_open_upvalue ───────────────────────────────────────────────────────

  defp do_execute([{:get_open_upvalue, dest, reg} | rest], regs, upvalues, proto, state, cont, frames, line) do
    cell_ref = Map.fetch!(state.open_upvalues, reg)
    value = Map.get(state.upvalue_cells, cell_ref)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_open_upvalue ───────────────────────────────────────────────────────

  defp do_execute([{:set_open_upvalue, reg, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    cell_ref = Map.fetch!(state.open_upvalues, reg)
    value = elem(regs, source)
    state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── source_line — Target A: update line param only, no State struct copy ───

  defp do_execute([{:source_line, new_line, _file} | rest], regs, upvalues, proto, state, cont, frames, _line) do
    do_execute(rest, regs, upvalues, proto, state, cont, frames, new_line)
  end

  # ── move ───────────────────────────────────────────────────────────────────

  defp do_execute([{:move, dest, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = elem(regs, source)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── test — push rest as continuation, tail-call body ──────────────────────

  defp do_execute([{:test, reg, then_body, else_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
    body = if Value.truthy?(elem(regs, reg)), do: then_body, else: else_body
    do_execute(body, regs, upvalues, proto, state, [rest | cont], frames, line)
  end

  # ── test_and — short-circuit AND, push rest as continuation ───────────────

  defp do_execute([{:test_and, dest, source, rest_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = elem(regs, source)

    if Value.truthy?(value) do
      do_execute(rest_body, regs, upvalues, proto, state, [rest | cont], frames, line)
    else
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── test_or — short-circuit OR, push rest as continuation ─────────────────

  defp do_execute([{:test_or, dest, source, rest_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = elem(regs, source)

    if Value.truthy?(value) do
      regs = put_elem(regs, dest, value)
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    else
      do_execute(rest_body, regs, upvalues, proto, state, [rest | cont], frames, line)
    end
  end

  # ── while_loop — CPS: condition → check → body → restart ─────────────────

  defp do_execute(
         [{:while_loop, cond_body, test_reg, loop_body} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    loop_exit_cont = [{:loop_exit, rest} | cont]
    cond_check = {:cps_while_test, test_reg, loop_body, cond_body, rest, cont}
    do_execute(cond_body, regs, upvalues, proto, state, [cond_check | loop_exit_cont], frames, line)
  end

  # ── repeat_loop — CPS: body → condition → check → restart ────────────────

  defp do_execute(
         [{:repeat_loop, loop_body, cond_body, test_reg} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    loop_exit_cont = [{:loop_exit, rest} | cont]
    body_done = {:cps_repeat_body, loop_body, cond_body, test_reg, rest, cont}
    do_execute(loop_body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
  end

  # ── numeric_for — CPS ─────────────────────────────────────────────────────

  defp do_execute([{:numeric_for, base, loop_var, body} | rest], regs, upvalues, proto, state, cont, frames, line) do
    counter = elem(regs, base)
    limit = elem(regs, base + 1)
    step = elem(regs, base + 2)

    should_continue =
      if step > 0 do
        counter <= limit
      else
        counter >= limit
      end

    if should_continue do
      regs = put_elem(regs, loop_var, counter)

      state = %{
        state
        | open_upvalues: Map.reject(state.open_upvalues, fn {reg, _} -> reg >= loop_var end)
      }

      loop_exit_cont = [{:loop_exit, rest} | cont]
      body_done = {:cps_numeric_for, base, loop_var, body, rest, cont}
      do_execute(body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
    else
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── generic_for — CPS ─────────────────────────────────────────────────────

  defp do_execute([{:generic_for, base, var_regs, body} | rest], regs, upvalues, proto, state, cont, frames, line) do
    iter_func = elem(regs, base)
    invariant_state = elem(regs, base + 1)
    control = elem(regs, base + 2)

    {results, state} = call_value(iter_func, [invariant_state, control], proto, state, line)
    first_result = List.first(results)

    if first_result == nil do
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    else
      regs = put_elem(regs, base + 2, first_result)

      regs =
        var_regs
        |> Enum.with_index()
        |> Enum.reduce(regs, fn {var_reg, i}, r ->
          put_elem(r, var_reg, Enum.at(results, i))
        end)

      first_var_reg = List.first(var_regs)

      state = %{
        state
        | open_upvalues: Map.reject(state.open_upvalues, fn {reg, _} -> reg >= first_var_reg end)
      }

      loop_exit_cont = [{:loop_exit, rest} | cont]
      body_done = {:cps_generic_for, base, var_regs, body, rest, cont}
      do_execute(body, regs, upvalues, proto, state, [body_done | loop_exit_cont], frames, line)
    end
  end

  # ── closure ────────────────────────────────────────────────────────────────

  defp do_execute([{:closure, dest, proto_index} | rest], regs, upvalues, proto, state, cont, frames, line) do
    nested_proto = Enum.at(proto.prototypes, proto_index)

    {captured_upvalues_reversed, state} =
      Enum.reduce(nested_proto.upvalue_descriptors, {[], state}, fn
        {:parent_local, reg, _name}, {cells, state} ->
          case Map.get(state.open_upvalues, reg) do
            nil ->
              cell_ref = make_ref()
              value = elem(regs, reg)

              state = %{
                state
                | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value),
                  open_upvalues: Map.put(state.open_upvalues, reg, cell_ref)
              }

              {[cell_ref | cells], state}

            existing_cell ->
              {[existing_cell | cells], state}
          end

        {:parent_upvalue, index, _name}, {cells, state} ->
          {[elem(upvalues, index) | cells], state}
      end)

    captured_upvalues = Enum.reverse(captured_upvalues_reversed)
    closure = {:lua_closure, nested_proto, List.to_tuple(captured_upvalues)}
    regs = put_elem(regs, dest, closure)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── call — Lua closures via CPS frames; native functions inline ────────────

  defp do_execute([{:call, base, arg_count, result_count} | rest], regs, upvalues, proto, state, cont, frames, line) do
    func_value = elem(regs, base)

    args =
      case arg_count do
        {:multi, fixed_count} ->
          multi_count = state.multi_return_count
          total = fixed_count + multi_count
          if total > 0, do: for(i <- 1..total, do: elem(regs, base + i)), else: []

        n when is_integer(n) and n > 0 ->
          for i <- 1..n, do: elem(regs, base + i)

        n when is_integer(n) and n < 0 ->
          fixed_arg_count = -(n + 1)
          total_args = fixed_arg_count + state.multi_return_count
          if total_args > 0, do: for(i <- 1..total_args, do: elem(regs, base + i)), else: []

        0 ->
          []
      end

    case func_value do
      {:lua_closure, callee_proto, callee_upvalues} ->
        callee_regs =
          Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 16)

        callee_regs =
          args
          |> Enum.with_index()
          |> Enum.reduce(callee_regs, fn {arg, i}, r ->
            if i < callee_proto.param_count, do: put_elem(r, i, arg), else: r
          end)

        callee_proto =
          if callee_proto.is_vararg,
            do: %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)},
            else: callee_proto

        frame = %{
          rest: rest,
          cont: cont,
          regs: regs,
          upvalues: upvalues,
          proto: proto,
          base: base,
          result_count: result_count,
          open_upvalues: state.open_upvalues
        }

        call_info = %{source: proto.source, line: line, name: nil}

        state = %{state | call_stack: [call_info | state.call_stack], open_upvalues: %{}}

        # Tail call — Erlang stack does not grow
        do_execute(
          callee_proto.instructions,
          callee_regs,
          callee_upvalues,
          callee_proto,
          state,
          [],
          [frame | frames],
          line
        )

      {:native_func, fun} ->
        {results, state} =
          case fun.(args, state) do
            {r, %State{} = s} when is_list(r) ->
              {r, s}

            {r, %State{} = s} ->
              {List.wrap(r), s}

            other ->
              raise InternalError,
                value: "native function returned invalid result: #{inspect(other)}, expected {results, state}"
          end

        continue_after_call(results, regs, rest, upvalues, proto, state, cont, frames, line, base, result_count)

      nil ->
        raise TypeError,
          value: "attempt to call a nil value",
          source: proto.source,
          call_stack: state.call_stack,
          line: line,
          error_kind: :call_nil,
          value_type: nil

      other ->
        case get_metatable(other, state) do
          nil ->
            raise TypeError,
              value: "attempt to call a #{Value.type_name(other)} value",
              source: proto.source,
              call_stack: state.call_stack,
              line: line,
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
                  line: line,
                  error_kind: :call_non_function,
                  value_type: value_type(other)

              call_mm ->
                {results, state} = call_function(call_mm, [other | args], state)
                continue_after_call(results, regs, rest, upvalues, proto, state, cont, frames, line, base, result_count)
            end
        end
    end
  end

  # ── vararg ─────────────────────────────────────────────────────────────────

  defp do_execute([{:vararg, base, count} | rest], regs, upvalues, proto, state, cont, frames, line) do
    varargs = Map.get(proto, :varargs, [])

    {regs, state} =
      if count == 0 do
        regs =
          Enum.reduce(Enum.with_index(varargs), regs, fn {val, i}, r ->
            put_elem(r, base + i, val)
          end)

        {regs, %{state | multi_return_count: length(varargs)}}
      else
        regs =
          Enum.reduce(0..(count - 1), regs, fn i, r ->
            put_elem(r, base + i, Enum.at(varargs, i))
          end)

        {regs, state}
      end

    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── return_vararg ──────────────────────────────────────────────────────────

  defp do_execute([{:return_vararg} | _rest], regs, _upvalues, proto, state, _cont, frames, line) do
    varargs = Map.get(proto, :varargs, [])

    case frames do
      [] -> {varargs, regs, state}
      [frame | rest_frames] -> do_frame_return(varargs, regs, state, frame, rest_frames, line)
    end
  end

  # ── return (multi_return variant) ──────────────────────────────────────────

  defp do_execute(
         [{:return, base, {:multi_return, fixed_count}} | _rest],
         regs,
         _upvalues,
         _proto,
         state,
         _cont,
         frames,
         line
       ) do
    total = fixed_count + state.multi_return_count
    results = if total > 0, do: for(i <- 0..(total - 1), do: elem(regs, base + i)), else: []

    case frames do
      [] -> {results, regs, state}
      [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
    end
  end

  # ── return ─────────────────────────────────────────────────────────────────

  defp do_execute([{:return, base, count} | _rest], regs, _upvalues, _proto, state, _cont, frames, line) do
    results =
      cond do
        count == 0 ->
          [nil]

        count < 0 ->
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

    case frames do
      [] -> {results, regs, state}
      [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
    end
  end

  # ── Arithmetic operations ──────────────────────────────────────────────────

  defp do_execute([{:add, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__add", val_a, val_b, state, fn -> safe_add(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:subtract, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__sub", val_a, val_b, state, fn -> safe_subtract(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:multiply, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__mul", val_a, val_b, state, fn -> safe_multiply(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:divide, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__div", val_a, val_b, state, fn -> safe_divide(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:floor_divide, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__idiv", val_a, val_b, state, fn ->
        safe_floor_divide(val_a, val_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:modulo, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__mod", val_a, val_b, state, fn -> safe_modulo(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:power, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__pow", val_a, val_b, state, fn -> safe_power(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── String concatenation ───────────────────────────────────────────────────

  defp do_execute([{:concatenate, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    left = elem(regs, a)
    right = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__concat", left, right, state, fn ->
        concat_coerce(left) <> concat_coerce(right)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── Bitwise operations ─────────────────────────────────────────────────────

  defp do_execute([{:bitwise_and, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__band", val_a, val_b, state, fn ->
        Bitwise.band(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_or, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__bor", val_a, val_b, state, fn ->
        Bitwise.bor(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_xor, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__bxor", val_a, val_b, state, fn ->
        Bitwise.bxor(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:shift_left, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__shl", val_a, val_b, state, fn ->
        lua_shift_left(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:shift_right, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__shr", val_a, val_b, state, fn ->
        lua_shift_right(to_integer!(val_a), to_integer!(val_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_not, dest, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val = elem(regs, source)

    {result, new_state} =
      try_unary_metamethod("__bnot", val, state, fn ->
        Bitwise.bnot(to_integer!(val))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── Comparison operations ──────────────────────────────────────────────────

  defp do_execute([{:equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_equality_metamethod(val_a, val_b, state, fn -> val_a == val_b end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:less_than, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__lt", val_a, val_b, state, fn -> safe_compare_lt(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:less_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    {result, new_state} =
      try_binary_metamethod("__le", val_a, val_b, state, fn -> safe_compare_le(val_a, val_b) end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:greater_than, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    result = safe_compare_gt(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:greater_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    result = safe_compare_ge(elem(regs, a), elem(regs, b))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:not_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    result = elem(regs, a) != elem(regs, b)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── Unary operations ───────────────────────────────────────────────────────

  defp do_execute([{:negate, dest, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val = elem(regs, source)
    {result, new_state} = try_unary_metamethod("__unm", val, state, fn -> safe_negate(val) end)
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:not, dest, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    result = not Value.truthy?(elem(regs, source))
    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:length, dest, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
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
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── new_table ──────────────────────────────────────────────────────────────

  defp do_execute([{:new_table, dest, _array_hint, _hash_hint} | rest], regs, upvalues, proto, state, cont, frames, line) do
    {tref, state} = State.alloc_table(state)
    regs = put_elem(regs, dest, tref)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── get_table ──────────────────────────────────────────────────────────────

  defp do_execute([{:get_table, dest, table_reg, key_reg} | rest], regs, upvalues, proto, state, cont, frames, line) do
    table_val = elem(regs, table_reg)
    key = elem(regs, key_reg)

    {value, state} = index_value(table_val, key, state)

    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_table ──────────────────────────────────────────────────────────────

  defp do_execute([{:set_table, table_reg, key_reg, value_reg} | rest], regs, upvalues, proto, state, cont, frames, line) do
    {:tref, _} = elem(regs, table_reg)
    key = elem(regs, key_reg)
    value = elem(regs, value_reg)

    state = table_newindex(elem(regs, table_reg), key, value, state)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── get_field ──────────────────────────────────────────────────────────────

  defp do_execute([{:get_field, dest, table_reg, name} | rest], regs, upvalues, proto, state, cont, frames, line) do
    table_val = elem(regs, table_reg)

    {value, state} = index_value(table_val, name, state)

    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_field ──────────────────────────────────────────────────────────────

  defp do_execute([{:set_field, table_reg, name, value_reg} | rest], regs, upvalues, proto, state, cont, frames, line) do
    {:tref, _} = elem(regs, table_reg)
    value = elem(regs, value_reg)

    state = table_newindex(elem(regs, table_reg), name, value, state)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_list (multi-return variant) ───────────────────────────────────────

  defp do_execute(
         [{:set_list, table_reg, start, {:multi, init_count}, offset} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
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

    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_list ───────────────────────────────────────────────────────────────

  defp do_execute([{:set_list, table_reg, start, count, offset} | rest], regs, upvalues, proto, state, cont, frames, line) do
    {:tref, id} = elem(regs, table_reg)

    state =
      State.update_table(state, {:tref, id}, fn table ->
        new_data =
          if count == 0 do
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
            Enum.reduce(1..count, table.data, fn i, data ->
              value = elem(regs, start + i - 1)
              Map.put(data, offset + i, value)
            end)
          end

        %{table | data: new_data}
      end)

    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── self ───────────────────────────────────────────────────────────────────

  defp do_execute([{:self, base, obj_reg, method_name} | rest], regs, upvalues, proto, state, cont, frames, line) do
    obj = elem(regs, obj_reg)
    {func, state} = index_value(obj, method_name, state)

    regs = put_elem(regs, base + 1, obj)
    regs = put_elem(regs, base, func)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── Catch-all for unimplemented instructions ───────────────────────────────

  defp do_execute([instr | _rest], _regs, _upvalues, _proto, _state, _cont, _frames, _line) do
    raise InternalError, value: "unimplemented instruction: #{inspect(instr)}"
  end

  # ── do_frame_return — restore caller context after a Lua function returns ──

  defp do_frame_return(results, _callee_regs, state, frame, rest_frames, line) do
    %{
      rest: rest,
      cont: caller_cont,
      regs: caller_regs,
      upvalues: caller_upvalues,
      proto: caller_proto,
      base: base,
      result_count: result_count,
      open_upvalues: saved_open_upvalues
    } = frame

    state = %{state | call_stack: tl(state.call_stack), open_upvalues: saved_open_upvalues}

    case result_count do
      -1 ->
        # Return-position call (return f()): pass results to the caller's caller
        case rest_frames do
          [] ->
            {results, caller_regs, state}

          [outer_frame | outer_rest_frames] ->
            do_frame_return(results, caller_regs, state, outer_frame, outer_rest_frames, line)
        end

      -2 ->
        # Multi-return expansion: place all results into caller regs from base
        results_list = List.wrap(results)

        caller_regs =
          results_list
          |> Enum.with_index()
          |> Enum.reduce(caller_regs, fn {val, i}, r -> put_elem(r, base + i, val) end)

        state = %{state | multi_return_count: length(results_list)}
        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

      0 ->
        # No results captured
        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

      n when n > 0 ->
        # Fixed count: place first n results into caller regs from base
        results_list = List.wrap(results)

        caller_regs =
          Enum.reduce(0..(n - 1), caller_regs, fn i, r ->
            put_elem(r, base + i, Enum.at(results_list, i))
          end)

        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)
    end
  end

  # ── continue_after_call — place results for native/metamethod calls ─────────

  defp continue_after_call(results, regs, rest, upvalues, proto, state, cont, frames, line, base, result_count) do
    case result_count do
      -1 ->
        # Results from this native call become the return from the current function
        case frames do
          [] -> {results, regs, state}
          [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
        end

      -2 ->
        results_list = List.wrap(results)

        regs =
          results_list
          |> Enum.with_index()
          |> Enum.reduce(regs, fn {val, i}, r -> put_elem(r, base + i, val) end)

        state = %{state | multi_return_count: length(results_list)}
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      0 ->
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      n when n > 0 ->
        results_list = List.wrap(results)

        regs =
          Enum.reduce(0..(n - 1), regs, fn i, r ->
            put_elem(r, base + i, Enum.at(results_list, i))
          end)

        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── find_loop_exit — scan cont for the nearest {:loop_exit, _} marker ──────

  defp find_loop_exit([{:loop_exit, exit_is} | rest_cont]), do: {exit_is, rest_cont}
  defp find_loop_exit([_ | rest_cont]), do: find_loop_exit(rest_cont)
  defp find_loop_exit([]), do: raise(InternalError, value: "break outside loop")

  # ── find_label — scan instruction list for a :label marker ────────────────

  defp find_label([], _label), do: :not_found

  defp find_label([{:label, name} | rest], label) when name == label do
    {:found, rest}
  end

  defp find_label([{:test, _reg, then_body, else_body} | rest], label) do
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

  # ── call_value — invoke a function for generic_for iterator ───────────────

  defp call_value({:lua_closure, callee_proto, callee_upvalues}, args, _proto, state, _line) do
    callee_regs =
      Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 16)

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
      do_execute(callee_proto.instructions, callee_regs, callee_upvalues, callee_proto, state, [], [], 0)

    state = %{state | open_upvalues: saved_open_upvalues}
    {results, state}
  end

  defp call_value({:native_func, fun}, args, _proto, state, _line) do
    case fun.(args, state) do
      {results, %State{} = new_state} when is_list(results) ->
        {results, new_state}

      {results, %State{} = new_state} ->
        {List.wrap(results), new_state}
    end
  end

  defp call_value(nil, _args, proto, state, line) do
    raise TypeError,
      value: "attempt to call a nil value",
      source: proto.source,
      call_stack: state.call_stack,
      line: line,
      error_kind: :call_nil,
      value_type: nil
  end

  defp call_value(other, args, proto, state, line) do
    case get_metatable(other, state) do
      nil ->
        raise TypeError,
          value: "attempt to call a #{Value.type_name(other)} value",
          source: proto.source,
          call_stack: state.call_stack,
          line: line,
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
              line: line,
              error_kind: :call_non_function,
              value_type: value_type(other)

          call_mm ->
            call_value(call_mm, [other | args], proto, state, line)
        end
    end
  end

  # ── Coerce a value to string for concatenation ─────────────────────────────

  defp concat_coerce(value) when is_binary(value), do: value
  defp concat_coerce(value) when is_integer(value), do: Integer.to_string(value)
  defp concat_coerce(value) when is_float(value), do: Value.to_string(value)

  defp concat_coerce(value) do
    raise TypeError,
      value: "attempt to concatenate a #{Value.type_name(value)} value",
      error_kind: :concatenate_type_error,
      value_type: value_type(value)
  end

  # ── Metamethod support ─────────────────────────────────────────────────────

  @metamethod_chain_limit 200

  defp get_metatable({:tref, id}, state) do
    table = Map.fetch!(state.tables, id)
    table.metatable
  end

  defp get_metatable(value, state) when is_binary(value) do
    Map.get(state.metatables, "string")
  end

  defp get_metatable(_value, _state), do: nil

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

  defp table_index({:tref, id}, key, state, depth \\ 0) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__index' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    case Map.get(table.data, key) do
      nil ->
        case table.metatable do
          nil ->
            {nil, state}

          {:tref, mt_id} ->
            mt = Map.fetch!(state.tables, mt_id)

            case Map.get(mt.data, "__index") do
              nil ->
                {nil, state}

              {:tref, _} = index_table ->
                table_index(index_table, key, state, depth + 1)

              func when is_tuple(func) ->
                {results, state} = call_function(func, [{:tref, id}, key], state)
                {List.first(results), state}
            end
        end

      v ->
        {v, state}
    end
  end

  defp table_newindex({:tref, id}, key, value, state, depth \\ 0) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__newindex' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    if Map.has_key?(table.data, key) do
      State.update_table(state, {:tref, id}, fn t ->
        %{t | data: Map.put(t.data, key, value)}
      end)
    else
      case table.metatable do
        nil ->
          State.update_table(state, {:tref, id}, fn t ->
            %{t | data: Map.put(t.data, key, value)}
          end)

        {:tref, mt_id} ->
          mt = Map.fetch!(state.tables, mt_id)

          case Map.get(mt.data, "__newindex") do
            nil ->
              State.update_table(state, {:tref, id}, fn t ->
                %{t | data: Map.put(t.data, key, value)}
              end)

            {:tref, _} = newindex_table ->
              table_newindex(newindex_table, key, value, state, depth + 1)

            func when is_tuple(func) ->
              {_results, state} = call_function(func, [{:tref, id}, key, value], state)
              state
          end
      end
    end
  end

  defp try_binary_metamethod(metamethod_name, a, b, state, default_fn) do
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
        args = [a, b]
        initial_regs = List.to_tuple(args ++ List.duplicate(nil, 248))
        saved_open_upvalues = state.open_upvalues
        state = %{state | open_upvalues: %{}}

        {results, _final_regs, new_state} =
          do_execute(callee_proto.instructions, initial_regs, callee_upvalues, callee_proto, state, [], [], 0)

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
        args = [a]
        initial_regs = List.to_tuple(args ++ List.duplicate(nil, 249))
        saved_open_upvalues = state.open_upvalues
        state = %{state | open_upvalues: %{}}

        {results, _final_regs, new_state} =
          do_execute(callee_proto.instructions, initial_regs, callee_upvalues, callee_proto, state, [], [], 0)

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

  defp try_equality_metamethod(a, b, state, default_fn) do
    mt_a = get_metatable(a, state)
    mt_b = get_metatable(b, state)

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
            do_execute(callee_proto.instructions, initial_regs, callee_upvalues, callee_proto, state, [], [], 0)

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
      {default_fn.(), state}
    end
  end

  # ── Type-safe arithmetic ───────────────────────────────────────────────────

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
          lua_idiv(na, nb)

        true ->
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
          na - lua_idiv(na, nb) * nb

        true ->
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

  defp lua_idiv(a, b) do
    q = div(a, b)
    r = rem(a, b)
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

  # ── Type-safe comparison ───────────────────────────────────────────────────

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

  # ── Number coercion ────────────────────────────────────────────────────────

  defp to_number(v) when is_number(v), do: {:ok, v}

  defp to_number(v) when is_binary(v) do
    case Value.parse_number(v) do
      nil -> {:error, v}
      n -> {:ok, n}
    end
  end

  defp to_number(v), do: {:error, v}

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

  # ── Lua 5.3 shift semantics ────────────────────────────────────────────────

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
    unsigned_val = Bitwise.band(val, 0xFFFFFFFFFFFFFFFF)
    Bitwise.bsr(unsigned_val, shift)
  end

  # ── Value type helper ──────────────────────────────────────────────────────

  defp value_type(nil), do: nil
  defp value_type(v) when is_boolean(v), do: :boolean
  defp value_type(v) when is_number(v), do: :number
  defp value_type(v) when is_binary(v), do: :string
  defp value_type({:tref, _}), do: :table
  defp value_type({:lua_closure, _, _}), do: :function
  defp value_type({:native_func, _}), do: :function
  defp value_type(_), do: :unknown
end
