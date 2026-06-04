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

  alias Lua.VM.Dispatcher
  alias Lua.VM.InternalError
  alias Lua.VM.Limits
  alias Lua.VM.Numeric
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Table
  alias Lua.VM.TypeError
  alias Lua.VM.Value

  # ── Source position bridge for native callbacks ───────────────────────────
  #
  # In-executor raise sites get `line` / `proto.source` threaded as args
  # through their helpers — see e.g. `safe_add/4`. Native callbacks
  # (`assert`, `error`, stdlib type checks) don't have access to those
  # because they're plain `(args, state)` Elixir functions.
  #
  # To bridge: at the `:native_func` call dispatch, the executor stashes
  # the calling line and source in the process dictionary. Native code
  # reads them via `current_position/0`. After the native call returns
  # (or raises), the previous values are restored so nested invocations
  # don't see each other's positions.
  #
  # The cost on the success path is one `Process.put` and one `Process.delete`
  # per native function invocation — far less than per `:source_line`
  # opcode, which would fire ~5M times in a recursive workload like fib.

  @position_key {__MODULE__, :position}
  @unset :__unset__

  @doc """
  Returns the current Lua source position recorded by the executor.

  Returns `{line, source}` if a native callback is executing inside a
  Lua chunk (or just was), or `{nil, nil}` outside any execution.

  Used by raise sites in `Lua.VM.Stdlib` and other native helpers to
  attach `line` / `source` to runtime exceptions without threading them
  through every helper signature.
  """
  @spec current_position() :: {nil | integer(), nil | binary()}
  def current_position do
    case Process.get(@position_key) do
      nil -> {nil, nil}
      pos -> pos
    end
  end

  @doc """
  Executes instructions with the given register file and state.

  Returns {results, final_registers, final_state}.

  Saves and restores any prior `current_position/0` snapshot so nested
  executions (e.g. an Elixir callback that itself calls `Lua.eval!`)
  don't leak source positions into each other.

  Likewise saves and restores `state.open_upvalues` so that a nested
  execution's upvalue cells — keyed by register index — cannot collide
  with the caller's. Without this, a `require` that runs a module body
  containing closures over its top-level locals would leak those cells
  back to the caller; the caller's later closures would then reuse the
  stale cells by register index, aliasing the caller's locals to
  unrelated inner values.
  """
  @spec execute([tuple()], tuple(), list(), map(), State.t()) ::
          {list(), tuple(), State.t()}
  def execute(instructions, registers, upvalues, proto, state) do
    prev = Process.get(@position_key, @unset)
    saved_open_upvalues = state.open_upvalues

    try do
      state = %{state | open_upvalues: %{}}

      {results, regs, state} =
        do_execute(instructions, registers, upvalues, proto, state, [], [], 0)

      {results, regs, %{state | open_upvalues: saved_open_upvalues}}
    after
      restore_position(prev)
    end
  end

  defp set_position(line, source) do
    # Single tuple in the process dict keeps the position bridge to one
    # `Process.put`/`Process.get` pair per native callback instead of two.
    Process.put(@position_key, {line, source})
  end

  defp restore_position(@unset), do: Process.delete(@position_key)
  defp restore_position(pos), do: Process.put(@position_key, pos)

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

  def call_function({:compiled_closure, callee_proto, callee_upvalues}, args, state) do
    # Compiled callees route through the dispatcher. The dispatcher manages
    # its own register file setup, vararg routing, and open-upvalue save/
    # restore — `Dispatcher.execute/4` mirrors the semantics of this
    # function for the bytecode-encoded path.
    Dispatcher.execute(callee_proto, args, callee_upvalues, state)
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

  # ── Bridges for Lua.VM.Dispatcher ──────────────────────────────────────────
  #
  # The dispatcher reuses these helpers to keep metamethod fidelity in
  # lockstep with the interpreter. Each helper takes operands plus the
  # current `proto` (for source attribution) and returns the same
  # `{value, state}` shape the interpreter clauses produce.
  #
  # Line position for raise sites is passed as `0` because the dispatcher
  # does not yet track per-instruction line numbers — error attribution
  # for compiled prototypes is the subject of B5d-v2. Native callbacks
  # invoked via metamethods still get accurate positions via the
  # process-dictionary bridge installed at the call boundary.

  @doc false
  @spec dispatcher_binop(atom(), term(), term(), State.t(), term(), term(), term()) ::
          {term(), State.t()}
  def dispatcher_binop(:add, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__add", a, b, state, fn ->
      safe_add(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:subtract, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__sub", a, b, state, fn ->
      safe_subtract(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:multiply, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__mul", a, b, state, fn ->
      safe_multiply(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:divide, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__div", a, b, state, fn ->
      safe_divide(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:floor_divide, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__idiv", a, b, state, fn ->
      safe_floor_divide(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:modulo, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__mod", a, b, state, fn ->
      safe_modulo(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  def dispatcher_binop(:power, a, b, state, proto, hint_a, hint_b) do
    try_binary_metamethod("__pow", a, b, state, fn ->
      safe_power(a, b, 0, proto.source, hint_a, hint_b)
    end)
  end

  @doc false
  @spec dispatcher_unop(atom(), term(), State.t(), term(), term()) :: {term(), State.t()}
  def dispatcher_unop(:negate, val, state, proto, hint) do
    try_unary_metamethod("__unm", val, state, fn -> safe_negate(val, 0, proto.source, hint) end)
  end

  @doc false
  @spec dispatcher_cmp(atom(), term(), term(), State.t(), term()) :: {term(), State.t()}
  def dispatcher_cmp(:less_than, a, b, state, proto) do
    try_binary_metamethod("__lt", a, b, state, fn -> safe_compare_lt(a, b, 0, proto.source) end)
  end

  def dispatcher_cmp(:less_equal, a, b, state, proto) do
    compare_le(a, b, state, 0, proto.source)
  end

  def dispatcher_cmp(:greater_than, a, b, state, proto) do
    # Lua 5.3 §3.4.4: a > b dispatches __lt with swapped operands.
    try_binary_metamethod("__lt", b, a, state, fn -> safe_compare_lt(b, a, 0, proto.source) end)
  end

  def dispatcher_cmp(:greater_equal, a, b, state, proto) do
    # Lua 5.3 §3.4.4: a >= b is rewritten to b <= a.
    compare_le(b, a, state, 0, proto.source)
  end

  def dispatcher_cmp(:equal, a, b, state, _proto) do
    try_equality_metamethod(a, b, state, fn -> lua_equal(a, b) end)
  end

  def dispatcher_cmp(:not_equal, a, b, state, _proto) do
    {eq, new_state} = try_equality_metamethod(a, b, state, fn -> lua_equal(a, b) end)
    {not eq, new_state}
  end

  @doc false
  @spec dispatcher_get_field(term(), term(), State.t(), term(), term()) :: {term(), State.t()}
  def dispatcher_get_field({:tref, id} = tref, name, state, proto, name_hint) do
    # Fast path mirrors the interpreter's `:get_field` clause: skip the
    # full `index_value` pipeline when the table has the key and either
    # has no metatable, or the key is present at the data layer.
    table = :erlang.map_get(id, state.tables)

    case :erlang.map_get(:data, table) do
      %{^name => value} ->
        {value, state}

      _ ->
        case :erlang.map_get(:metatable, table) do
          nil -> {nil, state}
          _ -> index_value(tref, name, state, 0, proto.source, name_hint)
        end
    end
  end

  def dispatcher_get_field(value, name, state, proto, name_hint) do
    index_value(value, name, state, 0, proto.source, name_hint)
  end

  # ── Dispatcher bridges: table opcodes ───────────────────────────────────
  #
  # These wrap the same `defp` helpers that the interpreter's `:get_table`
  # / `:set_table` / `:set_field` / `:length` clauses call, so the
  # dispatcher inherits metamethod fidelity for free. Line attribution
  # is uniformly `0` here; threading honest line info into compiled
  # prototypes is B5d-v2. Native callbacks reached via metamethods still
  # see accurate positions via the process-dictionary bridge installed
  # at the call boundary.

  @doc false
  @spec dispatcher_get_table(term(), term(), State.t(), term(), term()) ::
          {term(), State.t()}
  def dispatcher_get_table(value, key, state, proto, name_hint) do
    index_value(value, key, state, 0, proto.source, name_hint)
  end

  @doc false
  @spec dispatcher_set_table(term(), term(), term(), State.t(), term(), term()) ::
          State.t() | no_return()
  def dispatcher_set_table({:tref, _} = tref, key, value, state, _proto, _name_hint) do
    table_newindex(tref, key, value, state)
  end

  def dispatcher_set_table(value, _key, _value, _state, proto, name_hint) do
    raise_index_type_error(value, 0, proto.source, name_hint)
  end

  @doc false
  @spec dispatcher_set_field(term(), binary(), term(), State.t(), term(), term()) ::
          State.t() | no_return()
  def dispatcher_set_field({:tref, _} = tref, name, value, state, _proto, _name_hint) do
    table_newindex(tref, name, value, state)
  end

  def dispatcher_set_field(value, _name, _value, _state, proto, name_hint) do
    raise_index_type_error(value, 0, proto.source, name_hint)
  end

  # The `_proto` parameter is unused today because `try_unary_metamethod`
  # doesn't thread a `source` through; B5d-v2 will route `__len` errors
  # back to `proto.source` (matching the other bridges' attribution),
  # so the parameter stays in the signature for forward-compat.
  @doc false
  @spec dispatcher_length(term(), State.t(), term()) :: {term(), State.t()}
  def dispatcher_length(value, state, _proto) do
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
  end

  @doc false
  @spec dispatcher_coerce_numeric_for_controls(term(), term(), term()) ::
          {number(), number(), number()}
  def dispatcher_coerce_numeric_for_controls(init, limit, step) do
    coerce_numeric_for_controls(init, limit, step)
  end

  @doc false
  @spec dispatcher_close_open_upvalues_at_or_above(State.t(), non_neg_integer()) :: State.t()
  def dispatcher_close_open_upvalues_at_or_above(state, threshold) do
    close_open_upvalues_at_or_above(state, threshold)
  end

  # ── Dispatcher bridges: B5c-v2 ──────────────────────────────────────────
  #
  # `:self` method resolution. Wraps `index_value/6` so __index metamethod
  # dispatch matches the interpreter clause-for-clause. Line attribution is
  # `0` for the same reason as the other bridges — error positions are
  # B5d-v2.
  @doc false
  @spec dispatcher_index_method_target(term(), term(), State.t(), term(), term()) ::
          {term(), State.t()}
  def dispatcher_index_method_target(obj, method_name, state, proto, name_hint) do
    index_value(obj, method_name, state, 0, proto.source, name_hint)
  end

  # `:generic_for` step: invoke the iterator function. The iterator can be
  # any callable value (Lua closure, compiled closure, native function,
  # value with `__call`), so we route through `call_value/5` which handles
  # the whole shape via the interpreter's call machinery.
  @doc false
  @spec dispatcher_call_value(term(), [term()], term(), State.t()) ::
          {[term()], State.t()}
  def dispatcher_call_value(callable, args, proto, state) do
    call_value(callable, args, proto, state, 0)
  end

  # `:concatenate` slow path. Mirrors the interpreter's three-way fallback:
  # both-binary → `<>`, both binary-or-number → `concat_coerce/3 . <>`,
  # otherwise `__concat` metamethod via `try_binary_metamethod/5`.
  # The dispatcher inlines the binary-binary fast path itself, but defers
  # the metatable case and the coerce path here so the type-error wording
  # stays in sync with the interpreter.
  @doc false
  @spec dispatcher_concat(term(), term(), State.t(), term()) ::
          {binary(), State.t()}
  def dispatcher_concat(left, right, state, proto) do
    src = proto.source

    try_binary_metamethod("__concat", left, right, state, fn ->
      concat_checked(concat_coerce(left, 0, src), concat_coerce(right, 0, src))
    end)
  end

  # `:call_*` out-of-mode bridge with name_hint-aware error wording.
  # The plain `call_function/3` path doesn't take a hint, so calling a
  # nil/non-function with `(upvalue 'x')`-style attribution would drop
  # the suffix. This wraps the same dispatch as `call_function/3` for
  # the callable shapes and inlines the type-error paths so the
  # dispatcher's error messages match the interpreter's `:call` opcode.
  @doc false
  @spec dispatcher_call_function(term(), [term()], State.t(), term(), term()) ::
          {[term()], State.t()}
  def dispatcher_call_function(nil, _args, state, proto, name_hint) do
    raise TypeError,
      value: "attempt to call a nil value" <> format_target_hint(name_hint),
      source: proto.source,
      call_stack: state.call_stack,
      line: 0,
      error_kind: :call_nil,
      value_type: nil
  end

  def dispatcher_call_function({:lua_closure, _, _} = closure, args, state, _proto, _name_hint),
    do: call_function(closure, args, state)

  def dispatcher_call_function({:compiled_closure, _, _} = closure, args, state, _proto, _name_hint),
    do: call_function(closure, args, state)

  def dispatcher_call_function({:native_func, _} = nf, args, state, _proto, _name_hint),
    do: call_function(nf, args, state)

  def dispatcher_call_function(other, args, state, proto, name_hint) do
    case get_metatable(other, state) do
      nil ->
        raise TypeError,
          value: "attempt to call a #{Value.type_name(other)} value" <> format_target_hint(name_hint),
          source: proto.source,
          call_stack: state.call_stack,
          line: 0,
          error_kind: :call_non_function,
          value_type: value_type(other)

      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        case Map.get(mt.data, "__call") do
          nil ->
            raise TypeError,
              value: "attempt to call a #{Value.type_name(other)} value" <> format_target_hint(name_hint),
              source: proto.source,
              call_stack: state.call_stack,
              line: 0,
              error_kind: :call_non_function,
              value_type: value_type(other)

          call_mm ->
            call_function(call_mm, [other | args], state)
        end
    end
  end

  @doc false
  @spec dispatcher_call_info(term(), term(), non_neg_integer()) :: map()
  def dispatcher_call_info(proto, name_hint, line) do
    %{source: proto.source, line: line, name: hint_name(name_hint), namewhat: hint_namewhat(name_hint)}
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

          state = close_open_upvalues_at_or_above(state, loop_var)

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
          state = close_open_upvalues_at_or_above(state, first_var_reg)

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
    value = State.get_global(state, name)
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_global ─────────────────────────────────────────────────────────────

  defp do_execute([{:set_global, name, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value = elem(regs, source)
    state = State.set_global(state, name, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── load_env ───────────────────────────────────────────────────────────────
  # Loads the chunk's `_ENV` table reference into `dest`. Plan A16 emits this
  # at the start of every chunk so `_ENV` (a chunk-level local at register 0)
  # is initialised before user code runs. A chunk loaded with a custom
  # environment carries it in upvalue slot 0 (see `Stdlib.compile_loaded_chunk`);
  # otherwise `_ENV` defaults to the global table `_G`.

  defp do_execute([{:load_env, dest} | rest], regs, upvalues, proto, state, cont, frames, line) do
    regs = put_elem(regs, dest, load_env_value(upvalues, state))
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

  # Read a captured-local value, preferring the upvalue cell when one exists.
  # If no cell has been created yet (no closure has captured this register),
  # the register itself is the source of truth -- the next closure that
  # captures the register will create a cell from the current register value.
  defp do_execute([{:get_open_upvalue, dest, reg} | rest], regs, upvalues, proto, state, cont, frames, line) do
    value =
      case Map.get(state.open_upvalues, reg) do
        nil -> elem(regs, reg)
        cell_ref -> Map.get(state.upvalue_cells, cell_ref)
      end

    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── close_upvalues ─────────────────────────────────────────────────────────
  #
  # Emitted at the end of a block scope (e.g. `do…end`) whose locals could
  # have been captured by a closure created inside the block. Per Lua 5.3
  # §3.4.10, those upvalue cells must be detached from the register as the
  # locals go out of scope so the next statement reusing those register
  # slots does not read or overwrite the stale cell. Loop bodies do this on
  # each iteration boundary in the continuation handlers above; this is the
  # same operation for non-loop block exits.
  defp do_execute([{:close_upvalues, threshold} | rest], regs, upvalues, proto, state, cont, frames, line) do
    state = close_open_upvalues_at_or_above(state, threshold)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_open_upvalue ───────────────────────────────────────────────────────

  # Write a captured-local value through the upvalue cell when one exists.
  # If no cell has been created yet, this is a no-op: the register already
  # holds the value (codegen always emits a move into the register before
  # set_open_upvalue), and the next closure that captures the register will
  # create a cell from the current register value.
  defp do_execute([{:set_open_upvalue, reg, source} | rest], regs, upvalues, proto, state, cont, frames, line) do
    state =
      case Map.get(state.open_upvalues, reg) do
        nil ->
          state

        cell_ref ->
          value = elem(regs, source)
          %{state | upvalue_cells: Map.put(state.upvalue_cells, cell_ref, value)}
      end

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
    # Lua 5.3 §3.3.5: the three control values are coerced to numbers using
    # the same rules as arithmetic operators. If both initial value and step
    # are integers (after coercion), the loop is done with integers; if
    # either is a float, all three are promoted to floats. Coerce once at
    # loop start and write the canonical numbers back into the control
    # registers so subsequent iterations work on numbers.
    {counter, limit, step} =
      coerce_numeric_for_controls(elem(regs, base), elem(regs, base + 1), elem(regs, base + 2))

    regs =
      regs
      |> put_elem(base, counter)
      |> put_elem(base + 1, limit)
      |> put_elem(base + 2, step)

    should_continue =
      if step > 0 do
        counter <= limit
      else
        counter >= limit
      end

    if should_continue do
      regs = put_elem(regs, loop_var, counter)

      state = close_open_upvalues_at_or_above(state, loop_var)

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
      state = close_open_upvalues_at_or_above(state, first_var_reg)

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
    upvalues_tuple = List.to_tuple(captured_upvalues)

    # Sub-prototypes are compiled to bytecode independently. The closure
    # value tag reflects which executor path will run the function — the
    # decision flows through the closure tag rather than back through the
    # parent prototype, so a compiled child can be called from an
    # interpreted parent and vice versa.
    closure =
      case nested_proto.bytecode do
        nil -> {:lua_closure, nested_proto, upvalues_tuple}
        _ -> {:compiled_closure, nested_proto, upvalues_tuple}
      end

    regs = put_elem(regs, dest, closure)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── call — Lua closures via CPS frames; native functions inline ────────────

  defp do_execute(
         [{:call, base, arg_count, result_count, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    func_value = elem(regs, base)

    # Resolve the number of args without materializing a list. Negative arg
    # counts and `{:multi, _}` both fold in `state.multi_return_count`. For
    # the Lua-closure path we can copy directly from caller regs into the
    # callee's freshly-built register tuple; building the intermediate args
    # list (which fib calls 100k+ times) was a major source of allocation
    # churn (Range/with_index/reduce/take/slice/at in the profile).
    total_args =
      case arg_count do
        {:multi, fixed_count} -> fixed_count + state.multi_return_count
        n when is_integer(n) and n > 0 -> n
        n when is_integer(n) and n < 0 -> -(n + 1) + state.multi_return_count
        0 -> 0
      end

    case func_value do
      {:compiled_closure, callee_proto, callee_upvalues} ->
        # Shortcut for interpreter → dispatcher hand-off: materialize the
        # args list and route through `Dispatcher.execute/4`, which mirrors
        # the semantics of the `:lua_closure` clause below (param/vararg
        # setup, open-upvalue save/restore). The dispatcher's own
        # `:call_one` clause handles dispatcher → dispatcher chains
        # without going through this branch.
        args = collect_args(regs, base + 1, total_args)
        call_info = %{source: proto.source, line: line, name: hint_name(name_hint), namewhat: hint_namewhat(name_hint)}
        depth = next_call_depth!(state)
        state = %{state | call_stack: [call_info | state.call_stack], call_depth: depth}
        {results, state} = Dispatcher.execute(callee_proto, args, callee_upvalues, state)
        state = %{state | call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}
        continue_after_call(results, regs, rest, upvalues, proto, state, cont, frames, line, base, result_count)

      {:lua_closure, callee_proto, callee_upvalues} ->
        param_count = callee_proto.param_count

        callee_regs =
          Tuple.duplicate(nil, max(callee_proto.max_registers, param_count) + 16)

        # Copy directly from caller regs[base+1..] into callee regs[0..param_count-1].
        # Fast path for the common 0/1/2-arg cases avoids the loop overhead.
        callee_regs = copy_args_to_regs(regs, base + 1, callee_regs, 0, min(total_args, param_count))

        callee_proto =
          if callee_proto.is_vararg do
            vararg_count = max(total_args - param_count, 0)
            varargs = collect_args(regs, base + 1 + param_count, vararg_count)
            %{callee_proto | varargs: varargs}
          else
            callee_proto
          end

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

        call_info = %{source: proto.source, line: line, name: hint_name(name_hint), namewhat: hint_namewhat(name_hint)}

        depth = next_call_depth!(state)

        state = %{
          state
          | call_stack: [call_info | state.call_stack],
            call_depth: depth,
            open_upvalues: %{}
        }

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
        # Native callbacks still consume args as a list — materialize it here.
        args = collect_args(regs, base + 1, total_args)

        # Stash the calling Lua position in the process dict so the native
        # callback can read it via `current_position/0` if it raises (e.g.
        # `assert`, `error`, stdlib type checks). The values are restored
        # after the call so nested native invocations don't leak. Doing
        # this only at the native boundary — instead of on every
        # `:source_line` opcode — keeps the success path fast.
        prev_pos = Process.get(@position_key, @unset)
        set_position(line, proto.source)

        {results, state} =
          try do
            case fun.(args, state) do
              {r, %State{} = s} when is_list(r) ->
                {r, s}

              {r, %State{} = s} ->
                {List.wrap(r), s}

              other ->
                raise InternalError,
                  value: "native function returned invalid result: #{inspect(other)}, expected {results, state}"
            end
          after
            restore_position(prev_pos)
          end

        continue_after_call(results, regs, rest, upvalues, proto, state, cont, frames, line, base, result_count)

      nil ->
        raise TypeError,
          value: "attempt to call a nil value" <> format_target_hint(name_hint),
          source: proto.source,
          call_stack: state.call_stack,
          line: line,
          error_kind: :call_nil,
          value_type: nil

      other ->
        case get_metatable(other, state) do
          nil ->
            raise TypeError,
              value: "attempt to call a #{Value.type_name(other)} value" <> format_target_hint(name_hint),
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
                  value: "attempt to call a #{Value.type_name(other)} value" <> format_target_hint(name_hint),
                  source: proto.source,
                  call_stack: state.call_stack,
                  line: line,
                  error_kind: :call_non_function,
                  value_type: value_type(other)

              call_mm ->
                args = collect_args(regs, base + 1, total_args)
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

  # Fast path: single-value return is by far the most common return shape
  # (every fib/factorial style recursion hits this every call). Avoid the
  # comprehension and Range allocation; just read one element.
  defp do_execute([{:return, base, 1} | _rest], regs, _upvalues, _proto, state, _cont, frames, line) do
    results = [elem(regs, base)]

    case frames do
      [] -> {results, regs, state}
      [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
    end
  end

  defp do_execute([{:return, base, count} | _rest], regs, _upvalues, _proto, state, _cont, frames, line) do
    results =
      cond do
        count == 0 ->
          [nil]

        count < 0 ->
          init_count = -(count + 1)
          total = init_count + state.multi_return_count
          collect_args(regs, base, total)

        count > 0 ->
          collect_args(regs, base, count)
      end

    case frames do
      [] -> {results, regs, state}
      [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
    end
  end

  # ── Arithmetic operations ──────────────────────────────────────────────────
  #
  # Fast paths: when both operands are already numbers, skip the metamethod
  # lookup machinery entirely — numbers cannot carry metatables in Lua, so
  # the `try_binary_metamethod` dispatch is pure overhead. Same idea for
  # comparisons below. Integer-integer add/sub/mul go through `to_signed_int64`
  # for Lua 5.3 §3.4.1 wrap-around; mixed and float-only fall through to
  # native `+`/`-`/`*`.

  defp do_execute([{:add, dest, a, b, _hint_a, _hint_b} | rest], regs, upvalues, proto, state, cont, frames, line)
       when is_integer(:erlang.element(a + 1, regs)) and is_integer(:erlang.element(b + 1, regs)) do
    sum = :erlang.element(a + 1, regs) + :erlang.element(b + 1, regs)
    regs = :erlang.setelement(dest + 1, regs, Numeric.to_signed_int64(sum))
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:add, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    if is_number(val_a) and is_number(val_b) do
      regs = put_elem(regs, dest, val_a + val_b)
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    else
      src = proto.source

      {result, new_state} =
        try_binary_metamethod("__add", val_a, val_b, state, fn ->
          safe_add(val_a, val_b, line, src, hint_a, hint_b)
        end)

      regs = put_elem(regs, dest, result)
      do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:subtract, dest, a, b, _hint_a, _hint_b} | rest], regs, upvalues, proto, state, cont, frames, line)
       when is_integer(:erlang.element(a + 1, regs)) and is_integer(:erlang.element(b + 1, regs)) do
    diff = :erlang.element(a + 1, regs) - :erlang.element(b + 1, regs)
    regs = :erlang.setelement(dest + 1, regs, Numeric.to_signed_int64(diff))
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:subtract, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    if is_number(val_a) and is_number(val_b) do
      regs = put_elem(regs, dest, val_a - val_b)
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    else
      src = proto.source

      {result, new_state} =
        try_binary_metamethod("__sub", val_a, val_b, state, fn ->
          safe_subtract(val_a, val_b, line, src, hint_a, hint_b)
        end)

      regs = put_elem(regs, dest, result)
      do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:multiply, dest, a, b, _hint_a, _hint_b} | rest], regs, upvalues, proto, state, cont, frames, line)
       when is_integer(:erlang.element(a + 1, regs)) and is_integer(:erlang.element(b + 1, regs)) do
    prod = :erlang.element(a + 1, regs) * :erlang.element(b + 1, regs)
    regs = :erlang.setelement(dest + 1, regs, Numeric.to_signed_int64(prod))
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  defp do_execute([{:multiply, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    if is_number(val_a) and is_number(val_b) do
      regs = put_elem(regs, dest, val_a * val_b)
      do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    else
      src = proto.source

      {result, new_state} =
        try_binary_metamethod("__mul", val_a, val_b, state, fn ->
          safe_multiply(val_a, val_b, line, src, hint_a, hint_b)
        end)

      regs = put_elem(regs, dest, result)
      do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:divide, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__div", val_a, val_b, state, fn ->
        safe_divide(val_a, val_b, line, src, hint_a, hint_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:floor_divide, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__idiv", val_a, val_b, state, fn ->
        safe_floor_divide(val_a, val_b, line, src, hint_a, hint_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:modulo, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__mod", val_a, val_b, state, fn ->
        safe_modulo(val_a, val_b, line, src, hint_a, hint_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:power, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__pow", val_a, val_b, state, fn ->
        safe_power(val_a, val_b, line, src, hint_a, hint_b)
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── String concatenation ───────────────────────────────────────────────────

  defp do_execute([{:concatenate, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    left = elem(regs, a)
    right = elem(regs, b)

    # Fast path: when both operands are already binary, the metamethod
    # dispatch is wasted work — the string metatable typically has no
    # `__concat` (its purpose is to expose `string.*` indexing). The OOP
    # benchmark hammered this with `name .. " says " .. sound`. Numbers
    # also concatenate without metamethods.
    cond do
      is_binary(left) and is_binary(right) ->
        regs = put_elem(regs, dest, concat_checked(left, right))
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      (is_binary(left) or is_number(left)) and (is_binary(right) or is_number(right)) ->
        src = proto.source
        result = concat_checked(concat_coerce(left, line, src), concat_coerce(right, line, src))
        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        src = proto.source

        {result, new_state} =
          try_binary_metamethod("__concat", left, right, state, fn ->
            concat_checked(concat_coerce(left, line, src), concat_coerce(right, line, src))
          end)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  # ── Bitwise operations ─────────────────────────────────────────────────────

  defp do_execute([{:bitwise_and, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__band", val_a, val_b, state, fn ->
        Numeric.to_signed_int64(
          Bitwise.band(to_integer!(val_a, line, src, hint_a), to_integer!(val_b, line, src, hint_b))
        )
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_or, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__bor", val_a, val_b, state, fn ->
        Numeric.to_signed_int64(Bitwise.bor(to_integer!(val_a, line, src, hint_a), to_integer!(val_b, line, src, hint_b)))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_xor, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__bxor", val_a, val_b, state, fn ->
        Numeric.to_signed_int64(
          Bitwise.bxor(to_integer!(val_a, line, src, hint_a), to_integer!(val_b, line, src, hint_b))
        )
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:shift_left, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__shl", val_a, val_b, state, fn ->
        lua_shift_left(to_integer!(val_a, line, src, hint_a), to_integer!(val_b, line, src, hint_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:shift_right, dest, a, b, hint_a, hint_b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)
    src = proto.source

    {result, new_state} =
      try_binary_metamethod("__shr", val_a, val_b, state, fn ->
        lua_shift_right(to_integer!(val_a, line, src, hint_a), to_integer!(val_b, line, src, hint_b))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  defp do_execute([{:bitwise_not, dest, source, hint} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val = elem(regs, source)
    src = proto.source

    {result, new_state} =
      try_unary_metamethod("__bnot", val, state, fn ->
        Numeric.to_signed_int64(Bitwise.bnot(to_integer!(val, line, src, hint)))
      end)

    regs = put_elem(regs, dest, result)
    do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
  end

  # ── Comparison operations ──────────────────────────────────────────────────

  # Comparison fast paths: number-vs-number and string-vs-string skip the
  # metamethod machinery — neither primitive type can carry __eq/__lt/__le.

  defp do_execute([{:equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a == val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a == val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        {result, new_state} =
          try_equality_metamethod(val_a, val_b, state, fn -> lua_equal(val_a, val_b) end)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:less_than, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a < val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a < val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        src = proto.source

        {result, new_state} =
          try_binary_metamethod("__lt", val_a, val_b, state, fn -> safe_compare_lt(val_a, val_b, line, src) end)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:less_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a <= val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a <= val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        {result, new_state} = compare_le(val_a, val_b, state, line, proto.source)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:greater_than, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a > val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a > val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        src = proto.source

        # Lua 5.3 §3.4.4: a > b is translated to b < a, which dispatches __lt.
        {result, new_state} =
          try_binary_metamethod("__lt", val_b, val_a, state, fn -> safe_compare_lt(val_b, val_a, line, src) end)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:greater_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a >= val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a >= val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        # Lua 5.3 §3.4.4: a >= b is translated to b <= a.
        {result, new_state} = compare_le(val_b, val_a, state, line, proto.source)

        regs = put_elem(regs, dest, result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  defp do_execute([{:not_equal, dest, a, b} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val_a = elem(regs, a)
    val_b = elem(regs, b)

    cond do
      is_number(val_a) and is_number(val_b) ->
        regs = put_elem(regs, dest, val_a != val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      is_binary(val_a) and is_binary(val_b) ->
        regs = put_elem(regs, dest, val_a != val_b)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      true ->
        {eq_result, new_state} =
          try_equality_metamethod(val_a, val_b, state, fn -> lua_equal(val_a, val_b) end)

        regs = put_elem(regs, dest, not eq_result)
        do_execute(rest, regs, upvalues, proto, new_state, cont, frames, line)
    end
  end

  # ── Unary operations ───────────────────────────────────────────────────────

  defp do_execute([{:negate, dest, source, hint} | rest], regs, upvalues, proto, state, cont, frames, line) do
    val = elem(regs, source)
    src = proto.source
    {result, new_state} = try_unary_metamethod("__unm", val, state, fn -> safe_negate(val, line, src, hint) end)
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

  defp do_execute(
         [{:get_table, dest, table_reg, key_reg, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    table_val = elem(regs, table_reg)
    key = elem(regs, key_reg)

    case table_val do
      {:tref, id} when is_integer(key) or is_binary(key) ->
        # Fast path mirroring get_field: integer/string key on a tref. Skip
        # normalize_key (no-op for these) and the full index_value pipeline
        # when the entry is present or no metatable is set.
        table = :erlang.map_get(id, state.tables)

        case :erlang.map_get(:data, table) do
          %{^key => value} ->
            regs = put_elem(regs, dest, value)
            do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

          _data ->
            case :erlang.map_get(:metatable, table) do
              nil ->
                regs = put_elem(regs, dest, nil)
                do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

              _ ->
                {value, state} = index_value(table_val, key, state, line, proto.source, name_hint)
                regs = put_elem(regs, dest, value)
                do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
            end
        end

      _ ->
        {value, state} = index_value(table_val, key, state, line, proto.source, name_hint)
        regs = put_elem(regs, dest, value)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── set_table ──────────────────────────────────────────────────────────────

  defp do_execute(
         [{:set_table, table_reg, key_reg, value_reg, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    table_val = elem(regs, table_reg)

    case table_val do
      {:tref, _} ->
        key = elem(regs, key_reg)
        value = elem(regs, value_reg)
        state = table_newindex(table_val, key, value, state)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      _ ->
        raise_index_type_error(table_val, line, proto.source, name_hint)
    end
  end

  # ── get_field ──────────────────────────────────────────────────────────────

  defp do_execute(
         [{:get_field, dest, table_reg, name, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    table_val = elem(regs, table_reg)

    case table_val do
      {:tref, id} ->
        table = :erlang.map_get(id, state.tables)

        # Fast path: table value present and (in the metatable check) no
        # metatable, so __index dispatch is irrelevant. `name` is always a
        # binary at codegen time, so normalize_key is a no-op — skip it.
        # Avoids the full table_index/index_value pipeline for the dominant
        # case (global lookups, plain field access).
        case :erlang.map_get(:data, table) do
          %{^name => value} ->
            regs = put_elem(regs, dest, value)
            do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

          _data ->
            case :erlang.map_get(:metatable, table) do
              nil ->
                regs = put_elem(regs, dest, nil)
                do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

              _ ->
                {value, state} = index_value(table_val, name, state, line, proto.source, name_hint)
                regs = put_elem(regs, dest, value)
                do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
            end
        end

      _ ->
        {value, state} = index_value(table_val, name, state, line, proto.source, name_hint)
        regs = put_elem(regs, dest, value)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── set_field ──────────────────────────────────────────────────────────────

  defp do_execute(
         [{:set_field, table_reg, name, value_reg, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    table_val = elem(regs, table_reg)

    case table_val do
      {:tref, _} ->
        value = elem(regs, value_reg)
        state = table_newindex(table_val, name, value, state)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      _ ->
        raise_index_type_error(table_val, line, proto.source, name_hint)
    end
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
        Table.put_many(table, set_list_pairs(regs, start, total, offset))
      end)

    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── set_list ───────────────────────────────────────────────────────────────

  defp do_execute([{:set_list, table_reg, start, count, offset} | rest], regs, upvalues, proto, state, cont, frames, line) do
    {:tref, id} = elem(regs, table_reg)
    total = if count == 0, do: state.multi_return_count, else: count

    state =
      State.update_table(state, {:tref, id}, fn table ->
        Table.put_many(table, set_list_pairs(regs, start, total, offset))
      end)

    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── self ───────────────────────────────────────────────────────────────────

  defp do_execute(
         [{:self, base, obj_reg, method_name, name_hint} | rest],
         regs,
         upvalues,
         proto,
         state,
         cont,
         frames,
         line
       ) do
    obj = elem(regs, obj_reg)
    {func, state} = index_value(obj, method_name, state, line, proto.source, name_hint)

    regs = put_elem(regs, base + 1, obj)
    regs = put_elem(regs, base, func)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end

  # ── Catch-all for unimplemented instructions ───────────────────────────────

  defp do_execute([instr | _rest], _regs, _upvalues, _proto, _state, _cont, _frames, _line) do
    raise InternalError, value: "unimplemented instruction: #{inspect(instr)}"
  end

  # Builds the ordered `{key, value}` list for a `:set_list` run: value `k`
  # (0-based) reads from register `start + k` and lands at key
  # `offset + k + 1`. Walks back-to-front so the list is in ascending-key
  # (insertion) order with O(1) prepends, then `Table.put_many/2` applies it
  # in a single struct rebuild — matching the old per-slot `Table.put/3`
  # fold exactly. A `total` of 0 yields `[]` and leaves the table untouched.
  defp set_list_pairs(regs, start, total, offset) do
    set_list_pairs(regs, start, offset, total - 1, [])
  end

  defp set_list_pairs(_regs, _start, _offset, k, acc) when k < 0, do: acc

  defp set_list_pairs(regs, start, offset, k, acc) do
    set_list_pairs(regs, start, offset, k - 1, [{offset + k + 1, elem(regs, start + k)} | acc])
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

    state = %{
      state
      | call_stack: tl(state.call_stack),
        call_depth: state.call_depth - 1,
        open_upvalues: saved_open_upvalues
    }

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
        count = length(results_list)
        caller_regs = ensure_regs_capacity(caller_regs, base + count)
        caller_regs = write_list_to_regs(caller_regs, base, results_list)

        state = %{state | multi_return_count: count}
        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

      0 ->
        # No results captured
        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

      1 ->
        # Fast path: single-result return (the overwhelmingly common case,
        # e.g. `return fib(n-1) + fib(n-2)` in fib). Skip the loop overhead.
        # `results` may be an empty list (function fell off end with no
        # explicit return) — Lua spec says missing returns yield nil.
        first =
          case results do
            [] -> nil
            [v | _] -> v
            v -> v
          end

        caller_regs = ensure_regs_capacity(caller_regs, base + 1)
        caller_regs = :erlang.setelement(base + 1, caller_regs, first)
        do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

      n when n > 0 ->
        # Fixed count: place first n results into caller regs from base
        results_list = List.wrap(results)
        caller_regs = ensure_regs_capacity(caller_regs, base + n)
        caller_regs = write_list_to_regs_n(caller_regs, base, results_list, n)

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
        count = length(results_list)
        regs = ensure_regs_capacity(regs, base + count)
        regs = write_list_to_regs(regs, base, results_list)

        state = %{state | multi_return_count: count}
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      0 ->
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      1 ->
        first =
          case results do
            [] -> nil
            [v | _] -> v
            v -> v
          end

        regs = ensure_regs_capacity(regs, base + 1)
        regs = :erlang.setelement(base + 1, regs, first)
        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)

      n when n > 0 ->
        results_list = List.wrap(results)
        regs = ensure_regs_capacity(regs, base + n)
        regs = write_list_to_regs_n(regs, base, results_list, n)

        do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
    end
  end

  # ── ensure_regs_capacity — grow a register tuple when multi-return overflows ─
  #
  # The compiler sizes register tuples for the syntactic call site, but a
  # multi-return call can produce more values than the caller statically
  # reserved (e.g. `string.char(range(0, 255))` returns 256 values from a
  # recursive helper). Rather than pre-allocate for the pathological case,
  # grow the tuple lazily here and keep the common case to a single
  # `put_elem`. `needed_size` is the total number of slots we must be able
  # to write to (i.e. base + count), so capacity must be at least that.
  defp ensure_regs_capacity(regs, needed_size) when is_tuple(regs) do
    current_size = tuple_size(regs)

    if needed_size > current_size do
      # Append nil slots with a small headroom so back-to-back expansions
      # don't repeatedly reallocate.
      extra = needed_size - current_size + 16
      grow_tuple(regs, extra)
    else
      regs
    end
  end

  defp grow_tuple(tuple, 0), do: tuple
  defp grow_tuple(tuple, n), do: grow_tuple(Tuple.insert_at(tuple, tuple_size(tuple), nil), n - 1)

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

  defp call_value({:compiled_closure, _, _} = closure, args, _proto, state, _line) do
    # Compiled-closure callees for generic_for iterators reuse the same
    # dispatcher bridge as `call_function/3`.
    call_function(closure, args, state)
  end

  defp call_value({:native_func, fun}, args, proto, state, line) do
    # Same source-position bridge as the `:call` opcode's native dispatch.
    # Used by `for` loop iteration when the iterator is native.
    prev_pos = Process.get(@position_key, @unset)
    set_position(line, proto.source)

    try do
      case fun.(args, state) do
        {results, %State{} = new_state} when is_list(results) ->
          {results, new_state}

        {results, %State{} = new_state} ->
          {List.wrap(results), new_state}
      end
    after
      restore_position(prev_pos)
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

  defp concat_coerce(value, _line, _source) when is_binary(value), do: value
  defp concat_coerce(value, _line, _source) when is_integer(value), do: Integer.to_string(value)
  defp concat_coerce(value, _line, _source) when is_float(value), do: Value.to_string(value)

  defp concat_coerce(value, line, source) do
    raise TypeError,
      value: "attempt to concatenate a #{Value.type_name(value)} value",
      line: line,
      source: source,
      error_kind: :concatenate_type_error,
      value_type: value_type(value)
  end

  # `..` builds a new binary on every step. A doubling loop (`s = s .. s`)
  # reaches sizes where a single concat allocates more than the heap limit
  # in one BIF call — faster than the GC-time `max_heap_size` check can
  # react. Guard the size deterministically here, matching the Layer A
  # stdlib checks, so the loop fails with a catchable error long before it
  # threatens the host. `byte_size/1` is O(1), so this is cheap on the hot
  # path. Compile-time constant; no per-call dispatch into `Limits`.
  @max_string_bytes Limits.max_string_bytes()

  @compile {:inline, concat_checked: 2}
  defp concat_checked(left, right) when byte_size(left) + byte_size(right) <= @max_string_bytes do
    left <> right
  end

  defp concat_checked(_left, _right) do
    raise RuntimeError, value: "resulting string too large"
  end

  # Per-call depth check, inlined to a plain integer comparison so the
  # call-dense recursive path does not pay a cross-module call on every
  # Lua call/return. Returns the bumped depth, or raises a catchable
  # "stack overflow" once the limit is hit. The `:infinity` head (the
  # default) skips the comparison.
  #
  # This is one of three copies of the same logic: the authoritative
  # `Lua.VM.State.next_call_depth!/1` and an identical private copy in
  # `Lua.VM.Dispatcher`. They are not compiler-checked against each other,
  # so any change here must be mirrored in the other two. The shared
  # semantics are pinned by `test/lua/vm/state_test.exs`.
  @compile {:inline, next_call_depth!: 1}
  defp next_call_depth!(%State{call_depth: depth, max_call_depth: :infinity}), do: depth + 1
  defp next_call_depth!(%State{call_depth: depth, max_call_depth: max}) when depth < max, do: depth + 1

  defp next_call_depth!(%State{call_stack: call_stack}) do
    raise RuntimeError, value: "stack overflow", call_stack: call_stack
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

  defp index_value({:tref, _} = tref, key, state, _line, _source, _name_hint) do
    table_index(tref, key, state)
  end

  defp index_value(value, key, state, line, source, name_hint) do
    case get_metatable(value, state) do
      nil ->
        raise_index_type_error(value, line, source, name_hint)

      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        case Map.get(mt.data, "__index") do
          nil ->
            raise_index_type_error(value, line, source, name_hint)

          {:tref, _} = idx_tbl ->
            table_index(idx_tbl, key, state)

          func when is_tuple(func) ->
            {results, state} = call_function(func, [value, key], state)
            {List.first(results), state}
        end
    end
  end

  defp raise_index_type_error(value, line, source, name_hint) do
    raise TypeError,
      value: "attempt to index a #{Value.type_name(value)} value" <> format_target_hint(name_hint),
      line: line,
      source: source,
      error_kind: :index_non_table,
      value_type: value_type(value)
  end

  # Formats a `name_hint` tagged-tuple (or `nil`) as the
  # " (global 'foo')"-style suffix appended to call/index error messages.
  # Mirrors PUC-Lua's per-instruction debug name recovery, but resolved at
  # compile time and threaded through on the relevant bytecode ops.
  defp format_target_hint(nil), do: ""
  defp format_target_hint({:global, name}), do: " (global '#{name}')"
  defp format_target_hint({:local, name}), do: " (local '#{name}')"
  defp format_target_hint({:upvalue, name}), do: " (upvalue '#{name}')"
  defp format_target_hint({:field, name}), do: " (field '#{name}')"
  defp format_target_hint({:method, name}), do: " (method '#{name}')"
  defp format_target_hint({:field, name, nil}), do: " (field '#{name}')"
  defp format_target_hint({:method, name, nil}), do: " (method '#{name}')"
  defp format_target_hint({:field, name, receiver}), do: " (field '#{name}' on #{format_receiver(receiver)})"
  defp format_target_hint({:method, name, receiver}), do: " (method '#{name}' on #{format_receiver(receiver)})"

  defp format_receiver({:global, name}), do: "global '#{name}'"
  defp format_receiver({:local, name}), do: "local '#{name}'"
  defp format_receiver({:upvalue, name}), do: "upvalue '#{name}'"
  defp format_receiver({:field, name}), do: "field '#{name}'"
  defp format_receiver({:field, name, _}), do: "field '#{name}'"
  defp format_receiver({:method, name}), do: "method '#{name}'"
  defp format_receiver({:method, name, _}), do: "method '#{name}'"

  defp hint_name(nil), do: nil
  defp hint_name(hint) when is_tuple(hint), do: elem(hint, 1)

  # Maps a call-site `name_hint` tag to the Lua 5.3 `namewhat` string reported
  # by `debug.getinfo(level, "n")`. The hint is recovered at compile time from
  # the caller's instruction, mirroring PUC-Lua's `getfuncname` classification.
  defp hint_namewhat(nil), do: ""
  defp hint_namewhat({:global, _}), do: "global"
  defp hint_namewhat({:local, _}), do: "local"
  defp hint_namewhat({:upvalue, _}), do: "upvalue"
  defp hint_namewhat({:field, _, _}), do: "field"
  defp hint_namewhat({:method, _, _}), do: "method"
  defp hint_namewhat(_), do: ""

  @doc """
  Reads `t[key]` honoring the `__index` metamethod chain.

  Returns `{value, state}`. Raises `RuntimeError` if the `__index` chain
  exceeds `@metamethod_chain_limit` to guard against cyclic metatables.

  Public so that stdlib functions (e.g. `table.concat`, `table.sort`) can
  perform metamethod-aware reads without duplicating dispatch logic.
  """
  @spec table_index({:tref, non_neg_integer()}, term(), State.t()) :: {term(), State.t()}
  def table_index({:tref, _} = tref, key, state) do
    table_index(tref, key, state, 0)
  end

  defp table_index({:tref, id}, key, state, depth) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__index' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    case Table.get_data(table.data, key) do
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

  @doc """
  Writes `t[key] = value` honoring the `__newindex` metamethod chain.

  Returns the updated state. Raises `RuntimeError` if the `__newindex`
  chain exceeds `@metamethod_chain_limit`.

  Public so that stdlib functions (e.g. `table.insert`, `table.sort`) can
  perform metamethod-aware writes without duplicating dispatch logic.
  """
  @spec table_newindex({:tref, non_neg_integer()}, term(), term(), State.t()) :: State.t()
  def table_newindex({:tref, _} = tref, key, value, state) do
    table_newindex(tref, key, value, state, 0)
  end

  defp table_newindex({:tref, id}, key, value, state, depth) do
    if depth >= @metamethod_chain_limit do
      raise RuntimeError, value: "'__newindex' chain too long; possible loop"
    end

    table = Map.fetch!(state.tables, id)

    # Fast path: no metatable means no `__newindex` to consult and no need
    # to look up the key first to decide whether the metamethod applies.
    # This is the overwhelmingly common case for plain tables and benchmarks
    # like `t[i] = ...` in a tight loop. Skips a `has_data?` lookup and the
    # nested case scrutiny.
    case table.metatable do
      nil ->
        updated = Table.put(table, key, value)
        %{state | tables: Map.put(state.tables, id, updated)}

      {:tref, mt_id} ->
        if Table.has_data?(table.data, key) do
          updated = Table.put(table, key, value)
          %{state | tables: Map.put(state.tables, id, updated)}
        else
          mt = Map.fetch!(state.tables, mt_id)

          case Map.get(mt.data, "__newindex") do
            nil ->
              updated = Table.put(table, key, value)
              %{state | tables: Map.put(state.tables, id, updated)}

            {:tref, _} = newindex_table ->
              table_newindex(newindex_table, key, value, state, depth + 1)

            func when is_tuple(func) ->
              {_results, state} = call_function(func, [{:tref, id}, key, value], state)
              state
          end
        end
    end
  end

  @doc """
  Returns the integer length of `tref`, honoring `__len`.

  When `__len` is defined the metamethod is invoked and its result is
  coerced to an integer. Otherwise falls back to `Value.sequence_length/1`.

  Returns `{integer_length, state}`. Raises `TypeError` when `__len`
  returns a value that cannot be coerced to an integer (matching
  `ltablib.c`'s `aux_getn`/`luaL_len` semantics for the `table` library).
  """
  @spec table_length({:tref, non_neg_integer()}, State.t()) ::
          {integer(), State.t()}
  def table_length({:tref, _} = tref, state) do
    {raw, state} =
      try_unary_metamethod("__len", tref, state, fn ->
        {:tref, id} = tref
        table = Map.fetch!(state.tables, id)
        Value.sequence_length(table.data)
      end)

    case raw do
      n when is_integer(n) ->
        {n, state}

      n when is_float(n) ->
        if Float.floor(n) == n and n >= -9_223_372_036_854_775_808.0 and n <= 9_223_372_036_854_775_807.0 do
          {trunc(n), state}
        else
          raise TypeError,
            value: "object length is not an integer",
            error_kind: :length_not_integer,
            value_type: :number
        end

      _ ->
        raise TypeError,
          value: "object length is not an integer",
          error_kind: :length_not_integer,
          value_type: value_type(raw)
    end
  end

  defp try_binary_metamethod(metamethod_name, a, b, state, default_fn) do
    metamethod =
      lookup_metamethod(a, metamethod_name, state) ||
        lookup_metamethod(b, metamethod_name, state)

    invoke_metamethod(metamethod, [a, b], state, default_fn)
  end

  # Lua 5.3 §3.4.4: a <= b is dispatched to __le when present on either
  # operand. If neither operand has __le, the operation falls back to
  # `not (b < a)` — i.e. it consults __lt with the operands swapped and
  # negates the result. Only when neither metamethod is defined does it
  # fall through to the primitive comparison (which raises on
  # incompatible types).
  defp compare_le(a, b, state, line, source) do
    case lookup_metamethod(a, "__le", state) || lookup_metamethod(b, "__le", state) do
      nil ->
        case lookup_metamethod(b, "__lt", state) || lookup_metamethod(a, "__lt", state) do
          nil ->
            {safe_compare_le(a, b, line, source), state}

          lt ->
            {lt_result, new_state} =
              invoke_metamethod(lt, [b, a], state, fn -> safe_compare_lt(b, a, line, source) end)

            {not Value.truthy?(lt_result), new_state}
        end

      le ->
        invoke_metamethod(le, [a, b], state, fn -> safe_compare_le(a, b, line, source) end)
    end
  end

  defp lookup_metamethod(value, name, state) do
    case get_metatable(value, state) do
      nil -> nil
      {:tref, mt_id} -> Map.get(Map.fetch!(state.tables, mt_id).data, name)
    end
  end

  defp try_unary_metamethod(metamethod_name, a, state, default_fn) do
    metamethod = lookup_metamethod(a, metamethod_name, state)
    invoke_metamethod(metamethod, [a], state, default_fn)
  end

  # Per Lua 5.3 §3.4.4, __eq is only consulted when both operands have the
  # same primitive type and rawequal returns false. Lua looks at the first
  # operand's __eq, falling back to the second operand's. The two metamethods
  # do *not* need to be the same function (that was Lua 5.1 behaviour).
  defp try_equality_metamethod(a, b, state, default_fn) do
    if eq_metamethod_eligible?(a, b) do
      case lookup_metamethod(a, "__eq", state) do
        nil ->
          case lookup_metamethod(b, "__eq", state) do
            nil -> {default_fn.(), state}
            eq -> invoke_metamethod(eq, [a, b], state, default_fn)
          end

        eq ->
          invoke_metamethod(eq, [a, b], state, default_fn)
      end
    else
      {default_fn.(), state}
    end
  end

  defp eq_metamethod_eligible?({:tref, _}, {:tref, _}), do: true
  defp eq_metamethod_eligible?(_, _), do: false

  # Invokes a metamethod (native or Lua closure) with the given args, falling
  # back to default_fn when the metamethod is missing or unsupported. Delegates
  # to call_function/3 so vararg metamethods receive operands through proto
  # varargs rather than being silently dropped.
  defp invoke_metamethod(metamethod, args, state, default_fn) do
    case metamethod do
      nil ->
        {default_fn.(), state}

      {:native_func, _} = func ->
        {results, new_state} = call_function(func, args, state)
        {List.first(results), new_state}

      {:lua_closure, _, _} = func ->
        {results, new_state} = call_function(func, args, state)
        {List.first(results), new_state}

      {:compiled_closure, _, _} = func ->
        {results, new_state} = call_function(func, args, state)
        {List.first(results), new_state}

      _ ->
        {default_fn.(), state}
    end
  end

  # ── Type-safe arithmetic ───────────────────────────────────────────────────

  # Arithmetic helpers take `(line, source)` so the raise site can pin the
  # error to the source position of the offending opcode. The args are
  # passed verbatim from the executor's threaded `line` and `proto.source`,
  # so they cost nothing on the success path beyond two register reads.

  defp safe_add(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)
    narrow_if_integer(na + nb)
  end

  defp safe_subtract(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)
    narrow_if_integer(na - nb)
  end

  defp safe_multiply(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)
    narrow_if_integer(na * nb)
  end

  # Coerce a value to a number, or raise an arithmetic type error pointing
  # at the failing operand. Per-operand hint lets the error suffix point
  # to the originating variable / field (PUC-Lua mirrors this via debug
  # info; we resolve at compile time and thread the hint through the
  # instruction tuple).
  defp number_or_arith_raise!(v, line, source, hint) do
    case to_number(v) do
      {:ok, n} -> n
      {:error, val} -> raise_arith_type_error(val, line, source, hint)
    end
  end

  defp raise_arith_type_error(val, line, source, hint) do
    raise TypeError,
      value:
        "attempt to perform arithmetic on a #{Value.type_name(val)} value" <>
          format_target_hint(hint),
      line: line,
      source: source,
      error_kind: :arithmetic_on_non_number,
      value_type: value_type(val)
  end

  # Lua 5.3 §3.4.1: `/` is always float division and never raises. Division
  # by zero produces ±inf or NaN. The BEAM has no IEEE float infinity or NaN
  # (Erlang raises `:badarith` on `1.0 / 0.0`), so we use finite stand-ins
  # consistent with `math.huge = 1.0e308`:
  #
  #   * `1/0`  → `+1.0e308`
  #   * `-1/0` → `-1.0e308`
  #   * `0/0`  → `:nan` (sentinel atom)
  #
  # Sign of an inf result follows sign of the numerator. Equality on `:nan`
  # is overridden in `lua_equal/2` so the canonical `nan ~= nan` test holds.
  # Arithmetic on `:nan` will surface a TypeError via `to_number/1`; that's
  # an accepted divergence from real IEEE 754, since the suite tests we
  # care about don't propagate NaN through further arithmetic.
  defp safe_divide(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)

    if nb == 0 or nb == 0.0 do
      cond do
        na == 0 or na == 0.0 -> :nan
        na > 0 -> 1.0e308
        true -> -1.0e308
      end
    else
      na / nb
    end
  end

  # Lua 5.3 §3.4.1: floor division of floats is `floor(a/b)`. With a zero
  # divisor where either operand is a float, `a/b` is the inf/nan stand-in
  # produced by `safe_divide`, and the floor of that flows through to the
  # result:
  #
  #   * ` 1.0 // 0` / ` 1.0 // 0.0` → `+math.huge`
  #   * `-1.0 // 0` / `-1.0 // 0.0` → `-math.huge`
  #   * ` 0.0 // 0` / ` 0.0 // 0.0` → `:nan`
  #
  # Only an integer `//` integer with a zero divisor raises — that's correct
  # per spec, since `//` between two integers is integer floor division.
  # PUC-Lua reports this as "attempt to divide by zero".
  defp safe_floor_divide(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)

    cond do
      is_integer(na) and is_integer(nb) and nb == 0 ->
        raise RuntimeError, value: "attempt to divide by zero", line: line, source: source

      is_integer(na) and is_integer(nb) ->
        Numeric.to_signed_int64(lua_idiv(na, nb))

      nb == 0 or nb == 0.0 ->
        cond do
          na == 0 or na == 0.0 -> :nan
          na > 0 -> 1.0e308
          true -> -1.0e308
        end

      true ->
        Float.floor(na / nb) * 1.0
    end
  end

  # Lua 5.3 §3.4.1: `a % b = a - floor(a/b)*b`. With a zero divisor where
  # either operand is a float, `a/0.0` is inf or nan and `inf * 0.0 = nan`,
  # so the result is always `:nan` regardless of `a`. Only an integer `%`
  # integer with a zero divisor raises; PUC-Lua reports it as `'n%0'`.
  defp safe_modulo(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)

    cond do
      is_integer(na) and is_integer(nb) and nb == 0 ->
        raise RuntimeError, value: "attempt to perform 'n%0'", line: line, source: source

      is_integer(na) and is_integer(nb) ->
        Numeric.to_signed_int64(na - lua_idiv(na, nb) * nb)

      nb == 0 or nb == 0.0 ->
        :nan

      true ->
        na - Float.floor(na / nb) * nb
    end
  end

  defp lua_idiv(a, b) do
    q = div(a, b)
    r = rem(a, b)
    if r != 0 and Bitwise.bxor(r, b) < 0, do: q - 1, else: q
  end

  defp safe_power(a, b, line, source, hint_a, hint_b) do
    na = number_or_arith_raise!(a, line, source, hint_a)
    nb = number_or_arith_raise!(b, line, source, hint_b)
    pow_ieee(na, nb)
  end

  # `:math.pow` raises ArithmeticError on 0^(negative), inf ^ 0, etc.
  # Lua 5.3 follows IEEE 754: 0^(-x) is +inf for positive x; we approximate
  # inf with our sentinel float (`1.0e308`) since BEAM has no float inf.
  defp pow_ieee(base, exp) when base == 0 and is_number(exp) and exp < 0, do: 1.0e308

  defp pow_ieee(base, exp) do
    :math.pow(base / 1, exp / 1)
  rescue
    ArithmeticError -> :nan
  end

  defp safe_negate(a, line, source, hint) do
    case to_number(a) do
      {:ok, na} ->
        narrow_if_integer(-na)

      {:error, val} ->
        raise_arith_type_error(val, line, source, hint)
    end
  end

  # Narrow integer results to signed 64-bit per Lua 5.3 §3.4.1. Floats are
  # left untouched: IEEE 754 has its own overflow semantics that the spec
  # leaves alone.
  defp narrow_if_integer(n) when is_integer(n), do: Numeric.to_signed_int64(n)
  defp narrow_if_integer(n), do: n

  # ── Equality ───────────────────────────────────────────────────────────────

  # Lua-level value equality. Mirrors Erlang `==` for ordinary values, but
  # honors the IEEE 754 rule that `nan ~= nan` for the `:nan` sentinel
  # produced by `0/0`. See `safe_divide/2` for the rationale.
  defp lua_equal(:nan, _), do: false
  defp lua_equal(_, :nan), do: false
  defp lua_equal(a, b), do: a == b

  # ── Type-safe comparison ───────────────────────────────────────────────────

  # IEEE 754 §5.11: any ordered comparison involving NaN is false.
  defp safe_compare_lt(:nan, _, _, _), do: false
  defp safe_compare_lt(_, :nan, _, _), do: false

  defp safe_compare_lt(a, b, line, source) do
    cond do
      is_number(a) and is_number(b) ->
        a < b

      is_binary(a) and is_binary(b) ->
        a < b

      true ->
        raise_compare_type_error(a, b, line, source)
    end
  end

  defp safe_compare_le(:nan, _, _, _), do: false
  defp safe_compare_le(_, :nan, _, _), do: false

  defp safe_compare_le(a, b, line, source) do
    cond do
      is_number(a) and is_number(b) ->
        a <= b

      is_binary(a) and is_binary(b) ->
        a <= b

      true ->
        raise_compare_type_error(a, b, line, source)
    end
  end

  defp raise_compare_type_error(a, b, line, source) do
    raise TypeError,
      value: "attempt to compare #{Value.type_name(a)} with #{Value.type_name(b)}",
      line: line,
      source: source,
      error_kind: :compare_incompatible_types,
      value_type: value_type(a)
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

  # ── Numeric-for control coercion ───────────────────────────────────────────

  # Lua 5.3 §3.3.5: a `for` statement converts each of init, limit, step to
  # a number using the same rules as arithmetic operators. Then, if both
  # init and step are integers, the loop runs with integers; otherwise,
  # init is promoted to float (limit stays as whatever number it parsed
  # to — counter/limit comparison works numerically across int/float).
  defp coerce_numeric_for_controls(init, limit, step) do
    init_n = coerce_for_value(init, "'for' initial value must be a number")
    limit_n = coerce_for_value(limit, "'for' limit must be a number")
    step_n = coerce_for_value(step, "'for' step must be a number")

    if is_float(init_n) or is_float(step_n) do
      {init_n * 1.0, limit_n, step_n * 1.0}
    else
      {init_n, limit_n, step_n}
    end
  end

  defp coerce_for_value(v, _msg) when is_number(v), do: v

  defp coerce_for_value(v, msg) when is_binary(v) do
    case Value.parse_number(v) do
      nil ->
        raise TypeError,
          value: msg,
          error_kind: :for_loop_non_number,
          value_type: :string

      n ->
        n
    end
  end

  defp coerce_for_value(v, msg) do
    raise TypeError,
      value: msg,
      error_kind: :for_loop_non_number,
      value_type: value_type(v)
  end

  defp to_integer!(v, _line, _source, _hint) when is_integer(v), do: v
  defp to_integer!(v, line, source, hint) when is_float(v), do: float_to_integer!(v, line, source, hint)

  defp to_integer!(v, line, source, hint) when is_binary(v) do
    case Value.parse_number(v) do
      nil ->
        raise TypeError,
          value:
            "attempt to perform bitwise operation on a string value" <>
              format_target_hint(hint),
          line: line,
          source: source,
          error_kind: :bitwise_on_non_integer,
          value_type: :string

      n when is_integer(n) ->
        n

      n when is_float(n) ->
        float_to_integer!(n, line, source, hint)
    end
  end

  defp to_integer!(v, line, source, hint) do
    raise TypeError,
      value:
        "attempt to perform bitwise operation on a #{Value.type_name(v)} value" <>
          format_target_hint(hint),
      line: line,
      source: source,
      error_kind: :bitwise_on_non_integer,
      value_type: value_type(v)
  end

  # Per Lua 5.3 §3.4.3: a float converts to integer for bitwise ops only if
  # it represents an integer exactly and fits in the signed 64-bit range.
  defp float_to_integer!(f, line, source, hint) when is_float(f) do
    truncated = trunc(f)

    if f == truncated * 1.0 and Numeric.signed?(truncated) do
      truncated
    else
      raise TypeError,
        value: "number has no integer representation" <> format_target_hint(hint),
        line: line,
        source: source,
        error_kind: :bitwise_on_non_integer,
        value_type: :number
    end
  end

  # ── Lua 5.3 shift semantics ────────────────────────────────────────────────

  defp lua_shift_left(_val, shift) when shift >= 64, do: 0
  defp lua_shift_left(_val, shift) when shift <= -64, do: 0
  defp lua_shift_left(val, shift) when shift < 0, do: lua_shift_right(val, -shift)

  defp lua_shift_left(val, shift) do
    Numeric.to_signed_int64(Bitwise.bsl(val, shift))
  end

  defp lua_shift_right(_val, shift) when shift >= 64, do: 0
  defp lua_shift_right(_val, shift) when shift <= -64, do: 0
  defp lua_shift_right(val, shift) when shift < 0, do: lua_shift_left(val, -shift)

  defp lua_shift_right(val, shift) do
    unsigned_val = Bitwise.band(val, 0xFFFFFFFFFFFFFFFF)
    Numeric.to_signed_int64(Bitwise.bsr(unsigned_val, shift))
  end

  # ── Value type helper ──────────────────────────────────────────────────────

  defp value_type(nil), do: nil
  defp value_type(v) when is_boolean(v), do: :boolean
  defp value_type(v) when is_number(v), do: :number
  defp value_type(v) when is_binary(v), do: :string
  defp value_type({:tref, _}), do: :table
  defp value_type({:lua_closure, _, _}), do: :function
  defp value_type({:compiled_closure, _, _}), do: :function
  defp value_type({:native_func, _}), do: :function
  defp value_type(_), do: :unknown

  # ── Close upvalue cells whose source register is at or above `threshold` ──
  #
  # Lua 5.3 §3.4.10: when a local variable goes out of scope, its upvalue
  # cell (if any closure has captured it) must be closed so subsequent
  # accesses see the final value. Each loop iteration nominally re-binds
  # the loop-variable registers and any locals declared inside the body,
  # so we sweep open_upvalues for entries at or above that threshold.
  #
  # Fast path: the overwhelming majority of loops never produce any open
  # upvalues (no nested closures capture a loop-local), so we short-circuit
  # on the empty map. Previously the `Map.reject` was eating ~8.5% of the
  # table_build benchmark's runtime because it built an iterator and
  # walked the empty map per iteration.
  defp close_open_upvalues_at_or_above(%{open_upvalues: ou} = state, _threshold) when map_size(ou) == 0 do
    state
  end

  defp close_open_upvalues_at_or_above(%{open_upvalues: ou} = state, threshold) do
    %{state | open_upvalues: Map.reject(ou, fn {reg, _} -> reg >= threshold end)}
  end

  # Resolve the `_ENV` value for a chunk's `load_env` instruction: a custom
  # environment lives in upvalue slot 0 when present (a chunk loaded via
  # `load(..., env)`), otherwise default to the global table `_G`.
  defp load_env_value(upvalues, state) when tuple_size(upvalues) > 0 do
    Map.get(state.upvalue_cells, elem(upvalues, 0))
  end

  defp load_env_value(_upvalues, state), do: State.g_ref(state)

  # ── Call helpers: copy args without allocating an intermediate list ────────
  #
  # `copy_args_to_regs` moves `count` values from `src_regs[src_off..]` into
  # `dst_regs[dst_off..]`. Used when entering a Lua closure: we know the
  # callee's freshly-allocated register tuple and the contiguous slot in the
  # caller's regs where the args live, so we can splice them across without
  # building an args list.
  #
  # `collect_args` walks the same range but produces a list, for the cases
  # that still need one (native function calls, `__call` dispatch, varargs).

  defp copy_args_to_regs(_src_regs, _src_off, dst_regs, _dst_off, 0), do: dst_regs

  defp copy_args_to_regs(src_regs, src_off, dst_regs, dst_off, count) do
    dst_regs = :erlang.setelement(dst_off + 1, dst_regs, :erlang.element(src_off + 1, src_regs))
    copy_args_to_regs(src_regs, src_off + 1, dst_regs, dst_off + 1, count - 1)
  end

  defp collect_args(_regs, _off, 0), do: []

  defp collect_args(regs, off, count) do
    collect_args_rev(regs, off + count - 1, count, [])
  end

  defp collect_args_rev(_regs, _off, 0, acc), do: acc

  defp collect_args_rev(regs, off, count, acc) do
    collect_args_rev(regs, off - 1, count - 1, [:erlang.element(off + 1, regs) | acc])
  end

  # ── Return helpers: write a list of values into a contiguous register range ─

  defp write_list_to_regs(regs, _off, []), do: regs

  defp write_list_to_regs(regs, off, [v | rest]) do
    write_list_to_regs(:erlang.setelement(off + 1, regs, v), off + 1, rest)
  end

  # Bounded version: writes at most `n` values, padding missing slots with nil.
  defp write_list_to_regs_n(regs, _off, _list, 0), do: regs

  defp write_list_to_regs_n(regs, off, [], n) do
    write_list_to_regs_n(:erlang.setelement(off + 1, regs, nil), off + 1, [], n - 1)
  end

  defp write_list_to_regs_n(regs, off, [v | rest], n) do
    write_list_to_regs_n(:erlang.setelement(off + 1, regs, v), off + 1, rest, n - 1)
  end
end
