defmodule Lua.VM.Dispatcher do
  @moduledoc """
  Hand-written executor over the dense bytecode produced by
  `Lua.Compiler.Bytecode`.

  The dispatcher exists to test the hypothesis that integer-tagged opcode
  dispatch over a tuple-encoded instruction stream measurably outperforms
  the existing list-of-tagged-tuples interpreter. It implements a narrow
  subset of opcodes — arithmetic, comparison, logical ops, conditional
  `:test`, single-result `:call`, single-value `:return`, plus the
  surrounding plumbing (constants, moves, env/upvalue/global lookups).
  Anything the bytecode encoder rejects keeps its prototype on the
  interpreter via the bytecode-compiler's `:fallback` cascade.

  Inter-mode calls grow the Erlang stack by one frame at the boundary.
  Dispatcher → dispatcher chains stay flat through `frames`. Mixed-mode
  programs (compiled prototype calling an interpreted one, or vice versa)
  pay a single recursive call at the transition; the recursion is bounded
  by the number of mode switches, not the call depth within a single
  mode.
  """

  alias Lua.Compiler.Prototype
  alias Lua.VM.Executor
  alias Lua.VM.InternalError
  alias Lua.VM.Numeric
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Table

  # Mirror of the interpreter's concat ceiling, inlined as a compile-time
  # constant so the binary-binary fast path stays a single comparison. See
  # `Lua.VM.Executor.concat_checked/2` for the rationale.

  # Opcode tags. These must stay in lockstep with `Lua.Compiler.Bytecode`.
  # The module-attribute form lets each case branch match a constant
  # integer, which the BEAM collapses to a jump table.

  # Lua 5.3 signed-int64 bounds — duplicated from `Lua.VM.Numeric` to
  # make the in-range check a guard-eligible compile-time constant.
  # `to_signed_int64/1` is still called for the (rare) overflow path;
  # the guard short-circuits the common case where the sum is already
  # in range, saving one function call per integer-arithmetic opcode.
  @max_int 0x7FFFFFFFFFFFFFFF
  @min_int -0x8000000000000000

  @op_load_constant 1
  @op_load_boolean 2
  @op_load_nil 3
  @op_move 4
  @op_load_env 5
  @op_get_upvalue 6
  @op_get_global 7
  @op_get_field 8
  @op_add 9
  @op_subtract 10
  @op_multiply 11
  @op_divide 12
  @op_floor_divide 13
  @op_modulo 14
  @op_power 15
  @op_negate 16
  @op_less_than 17
  @op_less_equal 18
  @op_greater_than 19
  @op_greater_equal 20
  @op_equal 21
  @op_not_equal 22
  @op_not 23
  @op_test 24
  # Tag `25` was `@op_test_true`; codegen never emitted it. Reused by
  # B5b-v2 for `:call` with `result_count == 0` (statement calls).
  @op_call_zero 25
  @op_call_one 26
  @op_return_one 27
  @op_return_zero 28
  # `@op_source_line 29` is reserved but never reaches the dispatcher: the
  # bytecode encoder strips `:source_line` entries in `encode_list/2`.
  # Line tracking for compiled prototypes is B5d-v2.
  @op_new_table 30
  @op_get_table 31
  @op_set_table 32
  @op_set_field 33
  @op_set_list 34
  @op_length 35
  @op_numeric_for 36

  # B5c-v2 additions. The contiguous 37..50 block keeps the BEAM's
  # case-jump table dense across the dispatcher's outer match.
  @op_closure 37
  @op_set_upvalue 38
  @op_get_open_upvalue 39
  @op_set_open_upvalue 40
  @op_vararg 41
  @op_return_proto_varargs 42
  @op_return_collect 43
  @op_return_multi 44
  @op_call_multi 45
  @op_self 46
  @op_concatenate 47
  @op_break 48
  @op_while_loop 49
  @op_repeat_loop 50
  @op_generic_for 51
  @op_close_upvalues 52

  @doc """
  Execute a compiled prototype against `args` and `state`.
  """
  @spec execute(Prototype.t(), [term()], State.t()) :: {[term()], State.t()}
  def execute(%Prototype{} = proto, args, %State{} = state) do
    do_execute_top(proto, args, {}, state)
  end

  @doc """
  Execute a compiled prototype with explicit upvalues.

  Used from the interpreter's `:call` opcode and from
  `Executor.call_function/3` when the callee is a `:compiled_closure`
  carrying upvalue cells.
  """
  @spec execute(Prototype.t(), [term()], tuple(), State.t()) :: {[term()], State.t()}
  def execute(%Prototype{} = proto, args, upvalues, %State{} = state) when is_tuple(upvalues) do
    do_execute_top(proto, args, upvalues, state)
  end

  defp do_execute_top(proto, args, upvalues, state) do
    regs = init_regs(proto, args)

    proto =
      if proto.is_vararg do
        %{proto | varargs: Enum.drop(args, proto.param_count)}
      else
        proto
      end

    saved_open = state.open_upvalues

    try do
      state = %{state | open_upvalues: %{}}

      {results, state} = dispatch(proto.bytecode, 1, regs, upvalues, proto, state, [], [])

      state = %{state | open_upvalues: saved_open}
      {results, state}
    rescue
      # Backstop net: any raise site missed by the per-site state
      # annotations still ferries out at least this frame's entry state,
      # so protected calls keep heap effects from enclosing frames —
      # see `Lua.VM.Executor.annotate_frame_state/2`.
      e -> reraise Executor.annotate_frame_state(e, state), __STACKTRACE__
    end
  end

  defp init_regs(proto, args) do
    # The interpreter sizes register tuples with a +16 buffer for
    # multi-return expansion (`ensure_regs_capacity/2`). The
    # dispatcher's `:call_one` always wants exactly one result and
    # the codegen now honestly reports the peak register, so no
    # buffer is needed at all here.
    size = max(proto.max_registers, proto.param_count)
    regs = Tuple.duplicate(nil, size)
    copy_args(regs, 0, args, proto.param_count)
  end

  defp copy_args(regs, _i, _args, 0), do: regs

  defp copy_args(regs, i, [arg | rest], n) do
    copy_args(:erlang.setelement(i + 1, regs, arg), i + 1, rest, n - 1)
  end

  defp copy_args(regs, _i, [], _n), do: regs

  # ── Dispatch loop ───────────────────────────────────────────────────────
  #
  # Single recursive function. Each opcode's handler lives directly inside
  # the outer `case` so the BEAM can emit a jump table on the integer
  # opcode tag — no per-opcode function call overhead, no intermediate
  # pattern-match frame.
  #
  # `code` is the current bytecode tuple, `pc` is 1-indexed. When `pc`
  # exceeds `tuple_size(code)` the current body has finished — pop a
  # continuation from `cont` or unwind through `frames`.
  #
  # `cont` holds `{code, pc}` resume markers pushed by `:test` when
  # descending into a branch body.
  #
  # `frames` holds dispatcher-side call frames for in-mode calls. Out-of-
  # mode calls (compiled → interpreted) bridge through
  # `Executor.call_function/3` instead, paying one Erlang stack frame
  # at the boundary.

  defp dispatch(code, pc, regs, upvalues, proto, state, cont, frames) when pc > tuple_size(code) do
    finish_body(regs, upvalues, proto, state, cont, frames)
  end

  defp dispatch(code, pc, regs, upvalues, proto, state, cont, frames) do
    case :erlang.element(pc, code) do
      {@op_load_constant, dest, value} ->
        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_load_boolean, dest, value} ->
        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_load_nil, dest, count} ->
        regs = clear_nils(regs, dest, count + 1)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_move, dest, src} ->
        v = :erlang.element(src + 1, regs)
        regs = :erlang.setelement(dest + 1, regs, v)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_load_env, dest} ->
        env =
          if tuple_size(upvalues) > 0 do
            Map.get(state.upvalue_cells, :erlang.element(1, upvalues))
          else
            State.g_ref(state)
          end

        regs = :erlang.setelement(dest + 1, regs, env)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_upvalue, dest, index} ->
        cell_ref = :erlang.element(index + 1, upvalues)
        # Mirror the interpreter's `Map.get/2` (returns nil for a dangling
        # cell) rather than `:erlang.map_get/2` (which raises `:badkey`).
        # Compiled closures should never carry stale cell refs, but the
        # invariant is the interpreter's, not ours, and the error shape
        # has to match where it does fire.
        v = Map.get(state.upvalue_cells, cell_ref)
        regs = :erlang.setelement(dest + 1, regs, v)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_global, dest, name} ->
        v = State.get_global(state, name)
        regs = :erlang.setelement(dest + 1, regs, v)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_field, dest, table_reg, name, name_hint} ->
        table_val = :erlang.element(table_reg + 1, regs)
        # Inline the tref fast path the interpreter uses for `_ENV.name`
        # global lookups (overwhelmingly the dominant `:get_field` shape).
        # Falling through to the helper for non-tref values, missing
        # keys, or metatable cases keeps fidelity.
        case table_val do
          {:tref, id} ->
            table = :erlang.map_get(id, state.tables)
            data = :erlang.map_get(:data, table)

            case data do
              %{^name => value} ->
                regs = :erlang.setelement(dest + 1, regs, value)
                dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

              _ ->
                case :erlang.map_get(:metatable, table) do
                  nil ->
                    regs = :erlang.setelement(dest + 1, regs, nil)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

                  _ ->
                    {value, state} =
                      Executor.dispatcher_get_field(table_val, name, state, proto, name_hint)

                    regs = :erlang.setelement(dest + 1, regs, value)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
                end
            end

          _ ->
            {value, state} =
              Executor.dispatcher_get_field(table_val, name, state, proto, name_hint)

            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      # ── Arithmetic ──────────────────────────────────────────────────
      #
      # Integer fast paths mirror the interpreter's. Numbers can't carry
      # metatables in Lua, so the metamethod dispatch is wasted work
      # when both operands are already numeric. The two `is_number`
      # guards inline directly in the case body.

      {@op_add, dest, a, b, hint_a, hint_b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_integer(va) and is_integer(vb) ->
            sum = va + vb
            wrapped = if sum >= @min_int and sum <= @max_int, do: sum, else: Numeric.to_signed_int64(sum)
            regs = :erlang.setelement(dest + 1, regs, wrapped)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va + vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_binop(:add, va, vb, state, proto, hint_a, hint_b)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_subtract, dest, a, b, hint_a, hint_b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_integer(va) and is_integer(vb) ->
            diff = va - vb
            wrapped = if diff >= @min_int and diff <= @max_int, do: diff, else: Numeric.to_signed_int64(diff)
            regs = :erlang.setelement(dest + 1, regs, wrapped)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va - vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_binop(:subtract, va, vb, state, proto, hint_a, hint_b)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_multiply, dest, a, b, hint_a, hint_b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_integer(va) and is_integer(vb) ->
            prod = va * vb
            wrapped = if prod >= @min_int and prod <= @max_int, do: prod, else: Numeric.to_signed_int64(prod)
            regs = :erlang.setelement(dest + 1, regs, wrapped)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va * vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_binop(:multiply, va, vb, state, proto, hint_a, hint_b)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_divide, dest, a, b, hint_a, hint_b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :divide,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto,
            hint_a,
            hint_b
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_floor_divide, dest, a, b, hint_a, hint_b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :floor_divide,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto,
            hint_a,
            hint_b
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_modulo, dest, a, b, hint_a, hint_b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :modulo,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto,
            hint_a,
            hint_b
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_power, dest, a, b, hint_a, hint_b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :power,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto,
            hint_a,
            hint_b
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_negate, dest, src, hint} ->
        {value, state} =
          Executor.dispatcher_unop(:negate, :erlang.element(src + 1, regs), state, proto, hint)

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Comparisons ─────────────────────────────────────────────────

      {@op_less_than, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va < vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va < vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:less_than, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_less_equal, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va <= vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va <= vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:less_equal, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_greater_than, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va > vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va > vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:greater_than, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_greater_equal, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va >= vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va >= vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:greater_equal, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_equal, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va == vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va == vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:equal, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_not_equal, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)

        cond do
          is_number(va) and is_number(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va != vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          is_binary(va) and is_binary(vb) ->
            regs = :erlang.setelement(dest + 1, regs, va != vb)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          true ->
            {value, state} = Executor.dispatcher_cmp(:not_equal, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_not, dest, src} ->
        v = :erlang.element(src + 1, regs)
        # Inline truthiness — Lua treats nil and false as the only falsy
        # values. Saves a function call per `:not` opcode.
        result = v === nil or v === false
        regs = :erlang.setelement(dest + 1, regs, result)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Conditional branching ───────────────────────────────────────
      #
      # `:test` dispatches into the chosen branch's nested bytecode
      # tuple, pushing the post-test resume `{code, pc + 1}` onto
      # `cont`. The branch-end clause of `dispatch/8` pops it.

      {@op_test, reg, then_bc, else_bc} ->
        # Inline truthiness. The default case (anything other than `nil`
        # or `false`) is the common path for `:test` in arithmetic-heavy
        # workloads — booleans returned from `:less_than` etc.
        branch =
          case :erlang.element(reg + 1, regs) do
            nil -> else_bc
            false -> else_bc
            _ -> then_bc
          end

        dispatch(branch, 1, regs, upvalues, proto, state, [{code, pc + 1} | cont], frames)

      # ── Calls ───────────────────────────────────────────────────────
      #
      # `:call_one` always asks for exactly one result placed at `base`.
      # `:call_zero` is the statement-call form (`table.sort(t)`,
      # `print(x)`): results are discarded. `:compiled_closure` callees
      # stay in the dispatcher via the frame stack — no Erlang stack
      # growth. Everything else bridges to the interpreter through
      # `Executor.call_function/3`, which grows the Erlang stack by one
      # frame at the mode boundary.
      #
      # The `:discard` sentinel in the frame's `base` slot signals
      # "throw the return value away"; `return_one/3` skips its
      # setelement write when it sees it.

      {@op_call_zero, base, arg_count, name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        case func_value do
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, arg_count)
            # B5c-v2: compiled callees may now be vararg functions. The
            # `is_vararg` check in `setup_vararg_proto/4` short-circuits for
            # the common non-vararg case at one tuple-field read.
            callee_proto = setup_vararg_proto(callee_proto, regs, base + 1, arg_count)

            frame =
              {code, pc + 1, regs, upvalues, proto, cont, :discard, state.open_upvalues}

            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)

            state = %{
              state
              | call_stack: [call_info | state.call_stack],
                call_depth: state.call_depth + 1,
                open_upvalues: %{}
            }

            dispatch(
              callee_proto.bytecode,
              1,
              callee_regs,
              callee_upvalues,
              callee_proto,
              state,
              [],
              [frame | frames]
            )

          {:lua_closure, _, _} = closure ->
            args = collect_args(regs, base + 1, arg_count)
            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)
            state = %{state | call_stack: [call_info | state.call_stack], call_depth: state.call_depth + 1}
            {_results, state} = Executor.call_function(closure, args, state)
            state = %{state | call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          _ ->
            args = collect_args(regs, base + 1, arg_count)

            {_results, state} =
              Executor.dispatcher_call_function(func_value, args, state, proto, name_hint)

            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_call_one, base, arg_count, name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        case func_value do
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, arg_count)
            callee_proto = setup_vararg_proto(callee_proto, regs, base + 1, arg_count)

            # Frame is a tuple, not a map: pattern-matching a tuple in
            # `return_one/3` skips Map.fetch! lookups and lets the BEAM
            # bind everything in a single `move` per slot.
            frame =
              {code, pc + 1, regs, upvalues, proto, cont, base, state.open_upvalues}

            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)

            state = %{
              state
              | call_stack: [call_info | state.call_stack],
                call_depth: state.call_depth + 1,
                open_upvalues: %{}
            }

            dispatch(
              callee_proto.bytecode,
              1,
              callee_regs,
              callee_upvalues,
              callee_proto,
              state,
              [],
              [frame | frames]
            )

          {:lua_closure, _, _} = closure ->
            args = collect_args(regs, base + 1, arg_count)
            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)
            state = %{state | call_stack: [call_info | state.call_stack], call_depth: state.call_depth + 1}
            {results, state} = Executor.call_function(closure, args, state)
            state = %{state | call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}

            first =
              case results do
                [v | _] -> v
                [] -> nil
              end

            regs = :erlang.setelement(base + 1, regs, first)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          _ ->
            args = collect_args(regs, base + 1, arg_count)

            {results, state} =
              Executor.dispatcher_call_function(func_value, args, state, proto, name_hint)

            first =
              case results do
                [v | _] -> v
                [] -> nil
              end

            regs = :erlang.setelement(base + 1, regs, first)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      # ── Returns ─────────────────────────────────────────────────────
      #
      # In-mode `:call_one` returns thread the single value through
      # `return_one/3` without boxing it as a list — the hot fib path
      # never sees a list allocation for the result. The interpreter-
      # boundary `[result]` shape is only built when unwinding past
      # the last dispatcher frame, where the caller expects the
      # `call_function/3` contract.

      {@op_return_one, base} ->
        return_one(:erlang.element(base + 1, regs), state, frames)

      {@op_return_zero} ->
        return_one(nil, state, frames)

      # ── Table opcodes ───────────────────────────────────────────────
      #
      # The fast paths mirror the interpreter clauses in `:get_field` /
      # `:set_field` / `:length`: tref + integer-or-binary key + no
      # metatable resolves to a direct map access; anything else bridges
      # to `Executor.dispatcher_*` so metamethod fidelity matches.

      {@op_new_table, dest} ->
        {tref, state} = State.alloc_table(state)
        regs = :erlang.setelement(dest + 1, regs, tref)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_table, dest, table_reg, key_reg, name_hint} ->
        table_val = :erlang.element(table_reg + 1, regs)
        key = :erlang.element(key_reg + 1, regs)

        case table_val do
          {:tref, id} when is_integer(key) and key >= 1 ->
            table = :erlang.map_get(id, state.tables)

            case Table.get(table, key) do
              nil ->
                case :erlang.map_get(:metatable, table) do
                  nil ->
                    regs = :erlang.setelement(dest + 1, regs, nil)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

                  _ ->
                    {value, state} =
                      Executor.dispatcher_get_table(table_val, key, state, proto, name_hint)

                    regs = :erlang.setelement(dest + 1, regs, value)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
                end

              value ->
                regs = :erlang.setelement(dest + 1, regs, value)
                dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
            end

          {:tref, id} when is_integer(key) or is_binary(key) ->
            table = :erlang.map_get(id, state.tables)
            data = :erlang.map_get(:data, table)

            case data do
              %{^key => value} ->
                regs = :erlang.setelement(dest + 1, regs, value)
                dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

              _ ->
                case :erlang.map_get(:metatable, table) do
                  nil ->
                    regs = :erlang.setelement(dest + 1, regs, nil)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

                  _ ->
                    {value, state} =
                      Executor.dispatcher_get_table(table_val, key, state, proto, name_hint)

                    regs = :erlang.setelement(dest + 1, regs, value)
                    dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
                end
            end

          _ ->
            {value, state} =
              Executor.dispatcher_get_table(table_val, key, state, proto, name_hint)

            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_set_table, table_reg, key_reg, value_reg, name_hint} ->
        table_val = :erlang.element(table_reg + 1, regs)
        key = :erlang.element(key_reg + 1, regs)
        value = :erlang.element(value_reg + 1, regs)
        state = Executor.dispatcher_set_table(table_val, key, value, state, proto, name_hint)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_set_field, table_reg, name, value_reg, name_hint} ->
        table_val = :erlang.element(table_reg + 1, regs)
        value = :erlang.element(value_reg + 1, regs)
        state = Executor.dispatcher_set_field(table_val, name, value, state, proto, name_hint)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # `:set_list` runs only the integer-count form (see encoder). The
      # multi-return form (`{:multi, _}`) was filtered upstream and never
      # reaches the dispatcher.
      {@op_set_list, table_reg, start, count, offset} ->
        {:tref, id} = :erlang.element(table_reg + 1, regs)

        state =
          State.update_table(state, {:tref, id}, fn table ->
            set_list_into_table(table, regs, start, count, offset, 0)
          end)

        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_length, dest, source} ->
        value = :erlang.element(source + 1, regs)

        case value do
          {:tref, id} ->
            table = :erlang.map_get(id, state.tables)

            case :erlang.map_get(:metatable, table) do
              nil ->
                # No __len possible — Lua 5.3 §3.4.7: # on a table
                # without __len is the border length of the data map.
                len = Table.length(table)
                regs = :erlang.setelement(dest + 1, regs, len)
                dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

              _ ->
                {len, state} = Executor.dispatcher_length(value, state, proto)
                regs = :erlang.setelement(dest + 1, regs, len)
                dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
            end

          v when is_binary(v) ->
            regs = :erlang.setelement(dest + 1, regs, byte_size(v))
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          _ ->
            {len, state} = Executor.dispatcher_length(value, state, proto)
            regs = :erlang.setelement(dest + 1, regs, len)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      # ── numeric_for ─────────────────────────────────────────────────
      #
      # Coerce the three control registers once, write the canonical
      # numbers back, then test `should_continue`. If the loop runs at
      # least once, push a `:cps_for` marker onto `cont`; the body-end
      # handler in `finish_body/6` increments the counter and either
      # re-enters the body or pops back to `outer_pc`.

      {@op_numeric_for, base, loop_var, body_bc} ->
        {counter, limit, step} =
          Executor.dispatcher_coerce_numeric_for_controls(
            :erlang.element(base + 1, regs),
            :erlang.element(base + 2, regs),
            :erlang.element(base + 3, regs),
            state
          )

        regs = :erlang.setelement(base + 1, regs, counter)
        regs = :erlang.setelement(base + 2, regs, limit)
        regs = :erlang.setelement(base + 3, regs, step)

        should_continue =
          if step > 0, do: counter <= limit, else: counter >= limit

        if should_continue do
          regs = :erlang.setelement(loop_var + 1, regs, counter)
          state = Executor.dispatcher_close_open_upvalues_at_or_above(state, loop_var)
          marker = {:cps_for, base, loop_var, body_bc, code, pc + 1}
          loop_exit = {:loop_exit, code, pc + 1}
          dispatch(body_bc, 1, regs, upvalues, proto, state, [marker, loop_exit | cont], frames)
        else
          dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      # ── while_loop / repeat_loop / generic_for ─────────────────────
      #
      # All three loop forms use a pair of `cont` markers: a CPS marker on
      # top, then a `:loop_exit` underneath. The CPS marker drives normal
      # body / condition handoff in `finish_body/6`; the loop_exit anchors
      # `:break`'s unwind via `find_loop_exit/1`.

      {@op_while_loop, test_reg, cond_bc, body_bc} ->
        cps = {:cps_while_test, test_reg, cond_bc, body_bc, code, pc + 1}
        loop_exit = {:loop_exit, code, pc + 1}
        dispatch(cond_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | cont], frames)

      {@op_repeat_loop, test_reg, body_bc, cond_bc} ->
        cps = {:cps_repeat_body, test_reg, body_bc, cond_bc, code, pc + 1}
        loop_exit = {:loop_exit, code, pc + 1}
        dispatch(body_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | cont], frames)

      {@op_generic_for, base, var_regs, body_bc} ->
        # Iterator call follows the same shape as the executor:
        # results = iter_func(invariant_state, control). If the first
        # result is nil the loop terminates; otherwise control gets the
        # first result, var_regs[i] each get results[i].
        iter_func = :erlang.element(base + 1, regs)
        invariant_state = :erlang.element(base + 2, regs)
        control = :erlang.element(base + 3, regs)

        {results, state} =
          Executor.dispatcher_call_value(iter_func, [invariant_state, control], proto, state)

        case results do
          [nil | _] ->
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          [] ->
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          [first | _] ->
            regs = :erlang.setelement(base + 3, regs, first)
            regs = assign_iter_results(regs, var_regs, results, 0)
            first_var_reg = :erlang.element(1, var_regs)
            state = Executor.dispatcher_close_open_upvalues_at_or_above(state, first_var_reg)
            marker = {:cps_generic_for, base, var_regs, body_bc, code, pc + 1}
            loop_exit = {:loop_exit, code, pc + 1}
            dispatch(body_bc, 1, regs, upvalues, proto, state, [marker, loop_exit | cont], frames)
        end

      # ── break ─────────────────────────────────────────────────────
      #
      # `:break` scans `cont` for the nearest `:loop_exit` marker and
      # dispatches to its post-loop target. Everything above the
      # loop_exit (CPS markers, `:test` resume points) is dropped.

      {@op_break} ->
        {exit_code, exit_pc, rest_cont} = find_loop_exit(cont)
        dispatch(exit_code, exit_pc, regs, upvalues, proto, state, rest_cont, frames)

      # ── Closure construction ──────────────────────────────────────
      #
      # Walks `nested_proto.upvalue_descriptors`, allocating a new cell
      # for any `:parent_local` capture that doesn't already have one
      # open on this register, or reusing the existing cell so multiple
      # closures capturing the same local share a single mutation point.
      # `:parent_upvalue` descriptors just forward our own cell ref.
      # The closure tag flips between `:lua_closure` and `:compiled_closure`
      # based on the child prototype's bytecode availability — the
      # decision flows through the closure value, not back through the
      # parent prototype.

      {@op_closure, dest, proto_index} ->
        nested_proto = Enum.at(proto.prototypes, proto_index)
        {cells, state} = build_upvalues(nested_proto.upvalue_descriptors, regs, upvalues, state, [])
        upvalues_tuple = List.to_tuple(:lists.reverse(cells))

        closure =
          case nested_proto.bytecode do
            nil -> {:lua_closure, nested_proto, upvalues_tuple}
            _ -> {:compiled_closure, nested_proto, upvalues_tuple}
          end

        regs = :erlang.setelement(dest + 1, regs, closure)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Upvalue access ────────────────────────────────────────────
      #
      # `:set_upvalue` writes through a closed cell (the upvalue tuple
      # entry is the ref itself). `:get_open_upvalue` and
      # `:set_open_upvalue` operate on locals captured by some other
      # closure: if a cell exists, it owns the value; if not, the
      # register itself is the source of truth and a `:set_open_upvalue`
      # is a no-op (codegen always emits a `:move` first).

      {@op_set_upvalue, index, source} ->
        cell_ref = :erlang.element(index + 1, upvalues)
        value = :erlang.element(source + 1, regs)
        state = %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_open_upvalue, dest, reg} ->
        value =
          case Map.get(state.open_upvalues, reg) do
            nil -> :erlang.element(reg + 1, regs)
            cell_ref -> Map.get(state.upvalue_cells, cell_ref)
          end

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_set_open_upvalue, reg, source} ->
        state =
          case Map.get(state.open_upvalues, reg) do
            nil ->
              state

            cell_ref ->
              value = :erlang.element(source + 1, regs)
              %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
          end

        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_close_upvalues, threshold} ->
        state = Executor.dispatcher_close_open_upvalues_at_or_above(state, threshold)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Vararg ────────────────────────────────────────────────────
      #
      # `:vararg` writes the prototype's varargs into a contiguous range.
      # `count == 0` is the "consume all" form: every vararg lands in
      # regs[base..] and `state.multi_return_count` is set so the next
      # multi-return-aware opcode sees the right length. `count > 0`
      # writes exactly that many slots, padding with nil — no
      # multi_return_count change.

      {@op_vararg, base, 0} ->
        varargs = proto.varargs
        {regs, n} = write_varargs(regs, base, varargs, 0)
        state = %{state | multi_return_count: n}
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_vararg, base, count} ->
        regs = write_varargs_n(regs, base, proto.varargs, count)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Multi-return returns ──────────────────────────────────────

      {@op_return_proto_varargs} ->
        return_multi(proto.varargs, state, frames)

      {@op_return_collect, base, fixed} ->
        total = fixed + state.multi_return_count
        results = collect_args(regs, base, total)
        return_multi(results, state, frames)

      {@op_return_multi, base, count} ->
        results = collect_args(regs, base, count)
        return_multi(results, state, frames)

      # ── Multi-return calls ────────────────────────────────────────
      #
      # `arg_count` may be a fixed integer, a negative integer (mirror
      # of `:return` count<0), or `{:multi, fixed}`. All three fold in
      # `state.multi_return_count` exactly as the executor does
      # (executor.ex:830). `result_count` discriminates how results
      # come back:
      #
      #   -1 → forward to current function's caller (tail-call return).
      #   -2 → expand into consecutive regs at base, set multi_return_count.
      #    n>1 → place first n results into regs starting at base.

      {@op_call_multi, base, arg_count, result_count, name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        total_args =
          case arg_count do
            {:multi, fixed} -> fixed + state.multi_return_count
            n when is_integer(n) and n > 0 -> n
            n when is_integer(n) and n < 0 -> -(n + 1) + state.multi_return_count
            0 -> 0
          end

        case func_value do
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, total_args)
            callee_proto = setup_vararg_proto(callee_proto, regs, base + 1, total_args)
            # Reuse the fast-path frame shapes when result_count is 0
            # (discard) or 1 (single integer base). Only the genuine
            # multi-return shapes (-1, -2, n > 1) need the tagged
            # `{:multi, _, _}` dest.
            dest =
              case result_count do
                0 -> :discard
                1 -> base
                _ -> {:multi, base, result_count}
              end

            frame = {code, pc + 1, regs, upvalues, proto, cont, dest, state.open_upvalues}
            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)

            state = %{
              state
              | call_stack: [call_info | state.call_stack],
                call_depth: state.call_depth + 1,
                open_upvalues: %{}
            }

            dispatch(
              callee_proto.bytecode,
              1,
              callee_regs,
              callee_upvalues,
              callee_proto,
              state,
              [],
              [frame | frames]
            )

          {:lua_closure, _, _} = closure ->
            args = collect_args(regs, base + 1, total_args)
            call_info = Executor.dispatcher_call_info(proto, name_hint, 0)
            State.check_call_depth!(state)
            state = %{state | call_stack: [call_info | state.call_stack], call_depth: state.call_depth + 1}
            {results, state} = Executor.call_function(closure, args, state)
            state = %{state | call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}
            apply_multi_call_result(result_count, base, results, code, pc + 1, regs, upvalues, proto, state, cont, frames)

          _ ->
            args = collect_args(regs, base + 1, total_args)

            {results, state} =
              Executor.dispatcher_call_function(func_value, args, state, proto, name_hint)

            apply_multi_call_result(result_count, base, results, code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      # ── self ──────────────────────────────────────────────────────
      #
      # `obj:method(args)` lowers to `:self` followed by `:call`. The
      # `:self` opcode writes the resolved method into regs[base] and
      # the object into regs[base+1]; the subsequent `:call` reads them
      # as func+first-arg. Resolution goes through `index_value/6` so
      # `__index` metamethods (the table-OOP idiom) work.

      {@op_self, base, obj_reg, method_name, name_hint} ->
        obj = :erlang.element(obj_reg + 1, regs)
        {func, state} = Executor.dispatcher_index_method_target(obj, method_name, state, proto, name_hint)
        regs = :erlang.setelement(base + 2, regs, obj)
        regs = :erlang.setelement(base + 1, regs, func)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      # ── Concatenation ─────────────────────────────────────────────
      #
      # Fast paths inline binary-binary and number/binary mixed forms;
      # anything else (table with `__concat`, etc.) bridges to the
      # interpreter for metamethod fidelity.

      {@op_concatenate, dest, a, b} ->
        left = :erlang.element(a + 1, regs)
        right = :erlang.element(b + 1, regs)

        if is_binary(left) and is_binary(right) do
          if byte_size(left) + byte_size(right) > state.max_string_bytes do
            raise RuntimeError, value: "resulting string too large", state: state
          end

          regs = :erlang.setelement(dest + 1, regs, left <> right)
          dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        else
          {result, state} = Executor.dispatcher_concat(left, right, state, proto)
          regs = :erlang.setelement(dest + 1, regs, result)
          dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end
    end
  end

  # ── End-of-body handling ────────────────────────────────────────────────

  defp finish_body(regs, upvalues, proto, state, [{next_code, next_pc} | rest_cont], frames) do
    dispatch(next_code, next_pc, regs, upvalues, proto, state, rest_cont, frames)
  end

  # `:numeric_for` body ran to completion. Increment the counter, re-test,
  # and either restart the body (re-pushing both the cps_for marker and
  # the loop_exit anchor) or pop both off and dispatch at the post-loop
  # PC. A `step` of zero infinite-loops here, matching the interpreter's
  # behaviour at `do_execute([{:numeric_for, …}])`; neither path implements
  # PUC-Lua's "for step is zero" runtime check. Fixing that is a separate
  # concern across both executors.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [{:cps_for, base, loop_var, body_bc, outer_code, outer_pc} = marker, {:loop_exit, _, _} = loop_exit | rest_cont],
         frames
       ) do
    counter = :erlang.element(base + 1, regs)
    step = :erlang.element(base + 3, regs)
    new_counter = counter + step
    regs = :erlang.setelement(base + 1, regs, new_counter)
    limit = :erlang.element(base + 2, regs)
    should_continue = if step > 0, do: new_counter <= limit, else: new_counter >= limit

    if should_continue do
      regs = :erlang.setelement(loop_var + 1, regs, new_counter)
      state = Executor.dispatcher_close_open_upvalues_at_or_above(state, loop_var)
      dispatch(body_bc, 1, regs, upvalues, proto, state, [marker, loop_exit | rest_cont], frames)
    else
      dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)
    end
  end

  # `:while_loop`: cond body just finished. Read test_reg; enter body (push
  # `:cps_while_body`) or exit.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [
           {:cps_while_test, test_reg, cond_bc, body_bc, outer_code, outer_pc},
           {:loop_exit, _, _} = loop_exit | rest_cont
         ],
         frames
       ) do
    case :erlang.element(test_reg + 1, regs) do
      v when v === nil or v === false ->
        dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)

      _ ->
        cps = {:cps_while_body, test_reg, cond_bc, body_bc, outer_code, outer_pc}
        dispatch(body_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | rest_cont], frames)
    end
  end

  # `:while_loop`: body just finished. Restart the condition by pushing
  # `:cps_while_test` and dispatching into cond_bc.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [
           {:cps_while_body, test_reg, cond_bc, body_bc, outer_code, outer_pc},
           {:loop_exit, _, _} = loop_exit | rest_cont
         ],
         frames
       ) do
    cps = {:cps_while_test, test_reg, cond_bc, body_bc, outer_code, outer_pc}
    dispatch(cond_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | rest_cont], frames)
  end

  # `:repeat_loop`: body just finished. Run the condition next.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [
           {:cps_repeat_body, test_reg, body_bc, cond_bc, outer_code, outer_pc},
           {:loop_exit, _, _} = loop_exit | rest_cont
         ],
         frames
       ) do
    cps = {:cps_repeat_cond, test_reg, body_bc, cond_bc, outer_code, outer_pc}
    dispatch(cond_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | rest_cont], frames)
  end

  # `:repeat_loop`: condition just finished. test_reg truthy = exit (Lua's
  # `repeat ... until cond` exits when cond is true). Otherwise loop.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [
           {:cps_repeat_cond, test_reg, body_bc, cond_bc, outer_code, outer_pc},
           {:loop_exit, _, _} = loop_exit | rest_cont
         ],
         frames
       ) do
    case :erlang.element(test_reg + 1, regs) do
      v when v === nil or v === false ->
        cps = {:cps_repeat_body, test_reg, body_bc, cond_bc, outer_code, outer_pc}
        dispatch(body_bc, 1, regs, upvalues, proto, state, [cps, loop_exit | rest_cont], frames)

      _ ->
        dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)
    end
  end

  # `:generic_for`: body finished. Call iterator again, re-check nil.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [
           {:cps_generic_for, base, var_regs, body_bc, outer_code, outer_pc} = marker,
           {:loop_exit, _, _} = loop_exit | rest_cont
         ],
         frames
       ) do
    iter_func = :erlang.element(base + 1, regs)
    invariant_state = :erlang.element(base + 2, regs)
    control = :erlang.element(base + 3, regs)

    {results, state} =
      Executor.dispatcher_call_value(iter_func, [invariant_state, control], proto, state)

    case results do
      [nil | _] ->
        dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)

      [] ->
        dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)

      [first | _] ->
        regs = :erlang.setelement(base + 3, regs, first)
        regs = assign_iter_results(regs, var_regs, results, 0)
        first_var_reg = :erlang.element(1, var_regs)
        state = Executor.dispatcher_close_open_upvalues_at_or_above(state, first_var_reg)
        dispatch(body_bc, 1, regs, upvalues, proto, state, [marker, loop_exit | rest_cont], frames)
    end
  end

  # Fell off the end of a loop body normally (no CPS marker fired — the
  # body ran past its last instruction with the loop_exit still on top).
  # Drop the loop_exit and let the next iteration of finish_body see the
  # cont below it.
  defp finish_body(regs, upvalues, proto, state, [{:loop_exit, _, _} | rest_cont], frames) do
    finish_body(regs, upvalues, proto, state, rest_cont, frames)
  end

  # Body exhausted with no continuation: prototype ran off the end. Lua
  # 5.3 §3.3.4 / the interpreter at executor.ex:506 both return *no*
  # values when control falls off the end, not a single `nil` — the
  # caller's `result_count` decides how that's projected (nil for a
  # single-value site, empty slot for a multi-return one).
  defp finish_body(_regs, _upvalues, _proto, state, [], frames) do
    return_multi([], state, frames)
  end

  # ── Return propagation through frames ───────────────────────────────────
  #
  # The bottom-of-stack return shape (`{results_list, state}`) matches
  # the contract `Executor.call_function/3` expects, so the dispatcher's
  # top-level `execute/3,4` callers see exactly what they would from
  # the interpreter. Mid-stack returns from `:return_one` skip the list
  # wrapping entirely so the fib hot path never allocates a cons.
  #
  # The frame's `dest` slot discriminates how the caller wants results:
  #
  #   integer N    → single result lands in regs[N]. `:call_one`.
  #   :discard     → result ignored. `:call_zero`.
  #   {:multi, B, -1} → forward all results to caller's caller.
  #   {:multi, B, -2} → expand all into regs[B..], set multi_return_count.
  #   {:multi, B, n>1} → write n results into regs[B..], pad nil.

  defp return_one(value, state, []) do
    {[value], state}
  end

  defp return_one(value, state, [frame | rest_frames]) do
    {code, pc, regs, upvalues, proto, cont, dest, saved_open} = frame
    # Every dispatcher frame corresponds to a Lua-level call that pushed a
    # call_stack entry. Pop it on the way out — the interpreter's
    # `do_frame_return/6` does the same at executor.ex:1767.
    state = %{state | open_upvalues: saved_open, call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}

    case dest do
      :discard ->
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      n when is_integer(n) ->
        regs = :erlang.setelement(n + 1, regs, value)
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      {:multi, _, -1} ->
        return_one(value, state, rest_frames)

      {:multi, base, -2} ->
        regs = :erlang.setelement(base + 1, regs, value)
        state = %{state | multi_return_count: 1}
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      {:multi, base, n} when is_integer(n) and n > 1 ->
        regs = :erlang.setelement(base + 1, regs, value)
        regs = pad_nils(regs, base + 1, n - 1)
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)
    end
  end

  # List-return path for `:return_multi`, `:return_collect`,
  # `:return_proto_varargs`, and the non-compiled-callee branch of
  # `:call_multi`. Mirrors `return_one/3`'s frame-variant handling.

  defp return_multi(results, state, []) do
    {results, state}
  end

  defp return_multi(results, state, [frame | rest_frames]) do
    {code, pc, regs, upvalues, proto, cont, dest, saved_open} = frame
    state = %{state | open_upvalues: saved_open, call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}

    case dest do
      :discard ->
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      n when is_integer(n) ->
        v =
          case results do
            [head | _] -> head
            [] -> nil
          end

        regs = :erlang.setelement(n + 1, regs, v)
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      {:multi, _, -1} ->
        return_multi(results, state, rest_frames)

      {:multi, base, -2} ->
        regs = write_results(regs, base, results)
        state = %{state | multi_return_count: length(results)}
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)

      {:multi, base, n} when is_integer(n) and n > 1 ->
        regs = write_results_n(regs, base, results, n)
        dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp clear_nils(regs, _dest, 0), do: regs

  defp clear_nils(regs, dest, n) do
    clear_nils(:erlang.setelement(dest + 1, regs, nil), dest + 1, n - 1)
  end

  defp init_callee_regs(callee_proto, src_regs, src_off, arg_count) do
    # Same as `init_regs/2`: no buffer needed because the bytecode
    # encoder rejects multi-return calls (which are the only thing
    # the interpreter's +16 buffer absorbs) and codegen reports the
    # honest peak register.
    size = max(callee_proto.max_registers, callee_proto.param_count)
    regs = Tuple.duplicate(nil, size)
    copy_n = min(arg_count, callee_proto.param_count)
    copy_regs(src_regs, src_off, regs, 0, copy_n)
  end

  defp copy_regs(_src, _src_i, dst, _dst_i, 0), do: dst

  defp copy_regs(src, src_i, dst, dst_i, n) do
    v = :erlang.element(src_i + 1, src)
    copy_regs(src, src_i + 1, :erlang.setelement(dst_i + 1, dst, v), dst_i + 1, n - 1)
  end

  defp collect_args(_regs, _off, 0), do: []

  defp collect_args(regs, off, count) do
    collect_args_rev(regs, off + count - 1, count, [])
  end

  defp collect_args_rev(_regs, _off, 0, acc), do: acc

  defp collect_args_rev(regs, off, count, acc) do
    collect_args_rev(regs, off - 1, count - 1, [:erlang.element(off + 1, regs) | acc])
  end

  # `:set_list` writes `count` consecutive register values into the table
  # at keys `[offset + 1, offset + count]`. We collect the `{key, value}`
  # pairs from the registers in one allocation-light walk and apply them
  # via a single `Table.put_many/2`, so the `%Table{}` struct is rebuilt
  # once instead of once per slot.
  defp set_list_into_table(table, _regs, _start, 0, _offset, _i), do: table

  defp set_list_into_table(table, regs, start, count, offset, i) do
    Table.put_many(table, set_list_pairs(regs, start, count, offset, i, count - 1, []))
  end

  # Builds the ordered `{key, value}` list for a `:set_list` run, walking the
  # registers from the last slot back to the first so the result is in
  # ascending-key (insertion) order with O(1) prepends. `Table.put_many/2`
  # then applies the whole run in a single struct rebuild.
  defp set_list_pairs(_regs, _start, _count, _offset, _i, j, acc) when j < 0, do: acc

  defp set_list_pairs(regs, start, count, offset, i, j, acc) do
    value = :erlang.element(start + i + j + 1, regs)
    set_list_pairs(regs, start, count, offset, i, j - 1, [{offset + i + j + 1, value} | acc])
  end

  # ── B5c-v2 helpers ──────────────────────────────────────────────────────

  # `:break` unwind. Drops everything above the nearest `:loop_exit`
  # marker and returns its post-loop dispatch target plus whatever
  # `cont` was below the marker.
  defp find_loop_exit([{:loop_exit, code, pc} | rest_cont]), do: {code, pc, rest_cont}
  defp find_loop_exit([_other | rest_cont]), do: find_loop_exit(rest_cont)

  defp find_loop_exit([]), do: raise(InternalError, value: "break outside loop")

  # Vararg setup at the call boundary. Mirrors the executor's per-call
  # behaviour: when calling a vararg function, regs[param_count..total_args)
  # become the varargs list carried on `%{proto | varargs: ...}`.
  defp setup_vararg_proto(callee_proto, src_regs, src_off, total_args) do
    if callee_proto.is_vararg do
      param_count = callee_proto.param_count
      vararg_count = max(total_args - param_count, 0)
      varargs = collect_args(src_regs, src_off + param_count, vararg_count)
      %{callee_proto | varargs: varargs}
    else
      callee_proto
    end
  end

  # Closure upvalue capture. `:parent_local` allocates (or reuses) an
  # open-upvalue cell so multiple closures over the same register share
  # mutation. `:parent_upvalue` forwards our own cell ref to the child.
  defp build_upvalues([], _regs, _upvalues, state, acc), do: {acc, state}

  defp build_upvalues([{:parent_local, reg, _name} | rest], regs, upvalues, state, acc) do
    {cell_ref, state} =
      case Map.get(state.open_upvalues, reg) do
        nil ->
          new_ref = make_ref()
          value = :erlang.element(reg + 1, regs)

          new_state = %{
            state
            | upvalue_cells: Map.put(state.upvalue_cells, new_ref, value),
              open_upvalues: Map.put(state.open_upvalues, reg, new_ref)
          }

          {new_ref, new_state}

        existing_cell ->
          {existing_cell, state}
      end

    build_upvalues(rest, regs, upvalues, state, [cell_ref | acc])
  end

  defp build_upvalues([{:parent_upvalue, index, _name} | rest], regs, upvalues, state, acc) do
    cell_ref = :erlang.element(index + 1, upvalues)
    build_upvalues(rest, regs, upvalues, state, [cell_ref | acc])
  end

  # `:vararg` count=0 form: write every vararg into regs[base..]
  # and return the count for `state.multi_return_count` update.
  # Grows the regs tuple if base + length exceeds current size — the
  # codegen sizes `max_registers` for the syntactic call site, but a
  # vararg expansion can outrun that statically reserved range
  # (e.g. `f(...)` where the variadic call site has more args than
  # the caller's other locals require).
  defp write_varargs(regs, base, varargs, _n) do
    n = length(varargs)
    regs = grow_regs(regs, base + n)
    write_varargs_loop(regs, base, varargs, 0)
  end

  defp write_varargs_loop(regs, _base, [], n), do: {regs, n}

  defp write_varargs_loop(regs, base, [v | rest], n) do
    write_varargs_loop(:erlang.setelement(base + n + 1, regs, v), base, rest, n + 1)
  end

  # `:vararg` count>0 form: write the first `n` varargs, pad with nil.
  defp write_varargs_n(regs, base, vs, n) do
    regs = grow_regs(regs, base + n)
    write_varargs_n_loop(regs, base, vs, n)
  end

  defp write_varargs_n_loop(regs, _base, _vs, 0), do: regs

  defp write_varargs_n_loop(regs, base, [], n) do
    write_varargs_n_loop(:erlang.setelement(base + 1, regs, nil), base + 1, [], n - 1)
  end

  defp write_varargs_n_loop(regs, base, [v | rest], n) do
    write_varargs_n_loop(:erlang.setelement(base + 1, regs, v), base + 1, rest, n - 1)
  end

  # `:generic_for` result distribution: each var_reg in the tuple gets
  # the next value from `results`. Walks `var_regs` by tuple index and
  # consumes `results` head-by-head so each step is O(1); slots past the
  # end of `results` receive `nil`.
  defp assign_iter_results(regs, var_regs, _results, i) when i >= tuple_size(var_regs), do: regs

  defp assign_iter_results(regs, var_regs, [], i) do
    reg = :erlang.element(i + 1, var_regs)
    assign_iter_results(:erlang.setelement(reg + 1, regs, nil), var_regs, [], i + 1)
  end

  defp assign_iter_results(regs, var_regs, [v | rest], i) do
    reg = :erlang.element(i + 1, var_regs)
    assign_iter_results(:erlang.setelement(reg + 1, regs, v), var_regs, rest, i + 1)
  end

  # Multi-return result writers used by `:call_multi` and `return_multi/3`.
  # Both grow the caller's regs tuple if the result range exceeds the
  # statically reserved size — mirrors the interpreter's
  # `ensure_regs_capacity/2` at the post-call site (executor.ex:1873).

  defp write_results(regs, base, results) do
    regs = grow_regs(regs, base + length(results))
    write_results_loop(regs, base, results)
  end

  defp write_results_loop(regs, _base, []), do: regs

  defp write_results_loop(regs, base, [v | rest]) do
    write_results_loop(:erlang.setelement(base + 1, regs, v), base + 1, rest)
  end

  # Bounded version: writes at most `n` values, padding missing slots with nil.
  defp write_results_n(regs, base, list, n) do
    regs = grow_regs(regs, base + n)
    write_results_n_loop(regs, base, list, n)
  end

  defp write_results_n_loop(regs, _base, _list, 0), do: regs

  defp write_results_n_loop(regs, base, [], n) do
    write_results_n_loop(:erlang.setelement(base + 1, regs, nil), base + 1, [], n - 1)
  end

  defp write_results_n_loop(regs, base, [v | rest], n) do
    write_results_n_loop(:erlang.setelement(base + 1, regs, v), base + 1, rest, n - 1)
  end

  # Pad `n` register slots starting at `start` with nil. Used when a
  # multi-result frame receives a single value via `return_one/3`.
  defp pad_nils(regs, start, n) do
    regs = grow_regs(regs, start + n)
    pad_nils_loop(regs, start, n)
  end

  defp pad_nils_loop(regs, _start, 0), do: regs

  defp pad_nils_loop(regs, start, n) do
    pad_nils_loop(:erlang.setelement(start + 1, regs, nil), start + 1, n - 1)
  end

  # Place results from a non-compiled-callee multi-call back into the
  # caller's regs. The compiled-callee path goes through the frame stack
  # and unwinds via `return_multi/3`; this helper is for the synchronous
  # post-call shape (native, __call metamethod, lua_closure via
  # call_function). Mirrors `Executor.continue_after_call/11` shape.
  defp apply_multi_call_result(0, _base, _results, code, pc, regs, upvalues, proto, state, cont, frames) do
    dispatch(code, pc, regs, upvalues, proto, state, cont, frames)
  end

  defp apply_multi_call_result(1, base, results, code, pc, regs, upvalues, proto, state, cont, frames) do
    first =
      case results do
        [v | _] -> v
        [] -> nil
      end

    regs = :erlang.setelement(base + 1, regs, first)
    dispatch(code, pc, regs, upvalues, proto, state, cont, frames)
  end

  defp apply_multi_call_result(-1, _base, results, _code, _pc, _regs, _upvalues, _proto, state, _cont, frames) do
    return_multi(results, state, frames)
  end

  defp apply_multi_call_result(-2, base, results, code, pc, regs, upvalues, proto, state, cont, frames) do
    regs = write_results(regs, base, results)
    state = %{state | multi_return_count: length(results)}
    dispatch(code, pc, regs, upvalues, proto, state, cont, frames)
  end

  defp apply_multi_call_result(n, base, results, code, pc, regs, upvalues, proto, state, cont, frames)
       when is_integer(n) and n > 1 do
    regs = write_results_n(regs, base, results, n)
    dispatch(code, pc, regs, upvalues, proto, state, cont, frames)
  end

  # Lazy regs-tuple growth. Used at the points where multi-return
  # expansion or vararg writes can exceed the statically reserved size.
  # `Tuple.insert_at/3` is O(n) per insert; this is fine because growth
  # is rare and bounded by the call's actual result count.
  defp grow_regs(regs, needed) do
    current = tuple_size(regs)

    if needed > current do
      grow_tuple(regs, needed - current)
    else
      regs
    end
  end

  defp grow_tuple(tuple, 0), do: tuple

  defp grow_tuple(tuple, n) do
    grow_tuple(Tuple.insert_at(tuple, tuple_size(tuple), nil), n - 1)
  end
end
