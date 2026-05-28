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
  alias Lua.VM.Table
  alias Lua.VM.Value

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
        regs = :erlang.setelement(dest + 1, regs, State.g_ref(state))
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

      {@op_call_zero, base, arg_count, _name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        case func_value do
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, arg_count)

            frame =
              {code, pc + 1, regs, upvalues, proto, cont, :discard, state.open_upvalues}

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
            {_results, state} = Executor.call_function(func_value, args, state)
            dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end

      {@op_call_one, base, arg_count, _name_hint} ->
        func_value = :erlang.element(base + 1, regs)

        case func_value do
          # Vararg bodies are out of scope for the bytecode encoder
          # (`:vararg` / `:return_vararg` fall through to `:fallback`),
          # so a `{:compiled_closure, ...}` is, by construction, never a
          # vararg function. No varargs collection needed here.
          {:compiled_closure, callee_proto, callee_upvalues} ->
            callee_regs = init_callee_regs(callee_proto, regs, base + 1, arg_count)

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
                len = Value.sequence_length(:erlang.map_get(:data, table))
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
            :erlang.element(base + 3, regs)
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
          dispatch(body_bc, 1, regs, upvalues, proto, state, [marker | cont], frames)
        else
          dispatch(code, pc + 1, regs, upvalues, proto, state, cont, frames)
        end
    end
  end

  # ── End-of-body handling ────────────────────────────────────────────────

  defp finish_body(regs, upvalues, proto, state, [{next_code, next_pc} | rest_cont], frames) do
    dispatch(next_code, next_pc, regs, upvalues, proto, state, rest_cont, frames)
  end

  # `:numeric_for` body ran to completion. Increment the counter, re-test,
  # and either restart the body (keeping the marker for the next pass) or
  # pop back to the post-loop PC. A `step` of zero infinite-loops here,
  # matching the interpreter's behaviour at `do_execute([{:numeric_for, …}])`;
  # neither path implements PUC-Lua's "for step is zero" runtime check.
  # Fixing that is a separate concern across both executors.
  defp finish_body(
         regs,
         upvalues,
         proto,
         state,
         [{:cps_for, base, loop_var, body_bc, outer_code, outer_pc} = marker | rest_cont],
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
      dispatch(body_bc, 1, regs, upvalues, proto, state, [marker | rest_cont], frames)
    else
      dispatch(outer_code, outer_pc, regs, upvalues, proto, state, rest_cont, frames)
    end
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

    regs =
      case base do
        :discard -> regs
        b -> :erlang.setelement(b + 1, regs, value)
      end

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

  defp collect_args(_regs, _off, 0), do: []

  defp collect_args(regs, off, count) do
    collect_args_rev(regs, off + count - 1, count, [])
  end

  defp collect_args_rev(_regs, _off, 0, acc), do: acc

  defp collect_args_rev(regs, off, count, acc) do
    collect_args_rev(regs, off - 1, count - 1, [:erlang.element(off + 1, regs) | acc])
  end

  # `:set_list` writes `count` consecutive register values into the table
  # at keys `[offset + 1, offset + count]`. Inline loop so the BEAM keeps
  # the hot path allocation-free apart from the `Table.put/3` updates
  # themselves (which sit in the table-storage churn category the parent
  # plan flagged as the post-B5b ceiling).
  defp set_list_into_table(table, _regs, _start, 0, _offset, _i), do: table

  defp set_list_into_table(table, regs, start, count, offset, i) do
    value = :erlang.element(start + i + 1, regs)
    set_list_into_table(Table.put(table, offset + i + 1, value), regs, start, count - 1, offset, i + 1)
  end
end
