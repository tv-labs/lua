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
  alias Lua.VM.Numeric
  alias Lua.VM.State

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
  @op_test_true 25
  @op_call_one 26
  @op_return_one 27
  @op_return_zero 28
  @op_source_line 29

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
    state = %{state | open_upvalues: %{}}

    {results, state} = dispatch(proto.bytecode, 1, regs, upvalues, proto, state, [], [])

    state = %{state | open_upvalues: saved_open}
    {results, state}
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
  # `cont` holds `{code, pc}` resume markers pushed by `:test` /
  # `:test_true` when descending into a branch body.
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
        regs = :erlang.setelement(dest + 1, regs, State.g_ref(state))
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_get_upvalue, dest, index} ->
        cell_ref = :erlang.element(index + 1, upvalues)
        v = :erlang.map_get(cell_ref, state.upvalue_cells)
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

      {@op_add, dest, a, b} ->
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
            {value, state} = Executor.dispatcher_binop(:add, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_subtract, dest, a, b} ->
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
            {value, state} = Executor.dispatcher_binop(:subtract, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_multiply, dest, a, b} ->
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
            {value, state} = Executor.dispatcher_binop(:multiply, va, vb, state, proto)
            regs = :erlang.setelement(dest + 1, regs, value)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_divide, dest, a, b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :divide,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_floor_divide, dest, a, b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :floor_divide,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_modulo, dest, a, b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :modulo,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_power, dest, a, b} ->
        {value, state} =
          Executor.dispatcher_binop(
            :power,
            :erlang.element(a + 1, regs),
            :erlang.element(b + 1, regs),
            state,
            proto
          )

        regs = :erlang.setelement(dest + 1, regs, value)
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

      {@op_negate, dest, src} ->
        {value, state} =
          Executor.dispatcher_unop(:negate, :erlang.element(src + 1, regs), state, proto)

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

      {@op_test_true, reg, then_bc} ->
        case :erlang.element(reg + 1, regs) do
          nil ->
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          false ->
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)

          _ ->
            dispatch(then_bc, 1, regs, upvalues, proto, state, [{code, pc + 1} | cont], frames)
        end

      # ── Calls ───────────────────────────────────────────────────────
      #
      # `:call_one` always asks for exactly one result placed at `base`.
      # `:compiled_closure` callees stay in the dispatcher via the
      # frame stack — no Erlang stack growth. Everything else bridges
      # to the interpreter through `Executor.call_function/3`, which
      # grows the Erlang stack by one frame at the mode boundary.

      {@op_call_one, base, arg_count, _name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        case func_value do
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, arg_count)

            callee_proto =
              if callee_proto.is_vararg do
                varargs = collect_varargs(regs, base + 1, arg_count, callee_proto.param_count)
                %{callee_proto | varargs: varargs}
              else
                callee_proto
              end

            # Frame is a tuple, not a map: pattern-matching a tuple in
            # `return_one/3` skips Map.fetch! lookups and lets the BEAM
            # bind everything in a single `move` per slot.
            frame =
              {code, pc + 1, regs, upvalues, proto, cont, base, state.open_upvalues}

            state = %{state | open_upvalues: %{}}

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

          _ ->
            args = collect_args(regs, base + 1, arg_count)
            {results, state} = Executor.call_function(func_value, args, state)

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

      # ── No-ops in execution path ────────────────────────────────────

      {@op_source_line, _line, _file} ->
        # Line tracking for dispatcher-executed code is deferred; error
        # attribution for compiled prototypes is the subject of B5d-v2.
        dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
    end
  end

  # ── End-of-body handling ────────────────────────────────────────────────

  defp finish_body(regs, upvalues, proto, state, [{next_code, next_pc} | rest_cont], frames) do
    dispatch(next_code, next_pc, regs, upvalues, proto, state, rest_cont, frames)
  end

  # Body exhausted with no continuation: prototype ran off the end.
  # Lua spec: missing return yields nil.
  defp finish_body(_regs, _upvalues, _proto, state, [], frames) do
    return_one(nil, state, frames)
  end

  # ── Return propagation through frames ───────────────────────────────────
  #
  # The bottom-of-stack return shape (`{results_list, state}`) matches
  # the contract `Executor.call_function/3` expects, so the dispatcher's
  # top-level `execute/3,4` callers see exactly what they would from
  # the interpreter. Mid-stack returns skip the list wrapping entirely.

  defp return_one(value, state, []) do
    {[value], state}
  end

  defp return_one(value, state, [frame | rest_frames]) do
    {code, pc, regs, upvalues, proto, cont, base, saved_open} = frame
    regs = :erlang.setelement(base + 1, regs, value)
    state = %{state | open_upvalues: saved_open}
    dispatch(code, pc, regs, upvalues, proto, state, cont, rest_frames)
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

  defp collect_varargs(regs, base, total_args, param_count) do
    extra = max(total_args - param_count, 0)
    collect_args(regs, base + param_count, extra)
  end

  defp collect_args(_regs, _off, 0), do: []

  defp collect_args(regs, off, count) do
    collect_args_rev(regs, off + count - 1, count, [])
  end

  defp collect_args_rev(_regs, _off, 0, acc), do: acc

  defp collect_args_rev(regs, off, count, acc) do
    collect_args_rev(regs, off - 1, count - 1, [:erlang.element(off + 1, regs) | acc])
  end
end
