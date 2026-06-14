defmodule Lua.Compiler.Bytecode do
  @moduledoc """
  Bytecode encoder for `Lua.Compiler.Prototype`.

  Walks the structured instruction stream of a prototype and emits a dense
  tuple-of-tuples encoding suitable for `Lua.VM.Dispatcher`. Integer opcode
  tags occupy slot 1 of each opcode tuple; operands follow in fixed slots.

  Returns `{:ok, prototype}` with `bytecode` populated when every instruction
  in the prototype falls within the dispatcher's coverage. Returns
  `:fallback` the first time an uncovered opcode is encountered — the caller
  keeps the prototype as-is, and the interpreter handles it.

  Sub-prototypes are compiled independently. A parent that contains an
  uncovered opcode falls back to interpretation even when its sub-prototypes
  successfully compile, and vice versa.
  """

  alias Lua.Compiler.Prototype

  # Integer opcode tags. Kept in lockstep with the corresponding @op_*
  # constants in `Lua.VM.Dispatcher`. Small contiguous integers help the
  # BEAM emit a jump table for the dispatcher's outer case.

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
  # B5b-v2 for `:call` with `result_count == 0` — the statement-call
  # form (e.g. `table.sort(t)`).
  @op_call_zero 25
  @op_call_one 26
  @op_return_one 27
  @op_return_zero 28
  @op_source_line 29

  # Table opcodes plus `:numeric_for`, added by B5b-v2 to unlock the
  # `table_ops` benchmark family. The tags pick up where the foundation
  # left off; keeping the block contiguous helps the BEAM lay out the
  # dispatcher's jump table densely.
  @op_new_table 30
  @op_get_table 31
  @op_set_table 32
  @op_set_field 33
  @op_set_list 34
  @op_length 35
  @op_numeric_for 36

  # B5c-v2: closures, upvalues, varargs, multi-return, loops, self, concat.
  # The bitwise family, the `:set_list` multi-return tail (below), and
  # `:goto` / `:label` (resolved to `@op_goto` / `@op_label` by
  # `resolve_gotos/2`) have all joined the covered set — the encoder no
  # longer rejects any opcode current codegen emits.
  @op_closure 37
  @op_set_upvalue 38
  @op_get_open_upvalue 39
  @op_set_open_upvalue 40
  @op_vararg 41
  # `:return_vararg` (returns `proto.varargs`) and the `:return base count<0` /
  # `{:multi_return, fixed}` form (collects from regs) are different data
  # sources, so they get distinct tags. Both unwind through `return_multi/3`.
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

  # Bitwise family (band/bor/bxor/shl/shr/bnot) plus the `:set_list`
  # multi-return tail. Each compiles a single op that previously deopted
  # the whole enclosing prototype to the interpreter. Tags stay contiguous
  # to keep the dispatcher's jump table dense.
  @op_bitwise_and 53
  @op_bitwise_or 54
  @op_bitwise_xor 55
  @op_shift_left 56
  @op_shift_right 57
  @op_bitwise_not 58
  @op_set_list_multi 59

  # `:label` is a no-op that anchors a `goto` target PC. `:goto` is resolved at
  # encode time to `{@op_goto, depth, target_pc, level}` (see `resolve_gotos/2`):
  # `depth` is the `cont` entries the dispatcher drops to reach the target's
  # block, `target_pc` the label's index there, `level` the upvalue-close
  # threshold. Mirrors `Lua.Compiler.GotoResolution` for the interpreter.
  @op_label 60
  @op_goto 61

  @doc """
  Compile a prototype, populating its `bytecode` field on success.

  Sub-prototypes are compiled recursively; each is independent. A failure
  in one sub-prototype does not block another from being compiled.

  The parent prototype only gains a bytecode encoding if every instruction
  in its own body is supported. If the parent falls back, sub-prototype
  encodings are still preserved on the children.
  """
  @spec compile(Prototype.t()) :: Prototype.t()
  def compile(%Prototype{} = proto) do
    compiled_children =
      Enum.map(proto.prototypes, &compile/1)

    proto_with_children = %{proto | prototypes: compiled_children}

    case encode_list(proto.instructions, [], 0) do
      {:ok, encoded} ->
        bytecode = encoded |> List.to_tuple() |> resolve_gotos([])
        %{proto_with_children | bytecode: bytecode}

      :fallback ->
        proto_with_children
    end
  end

  @doc """
  True when `proto` and every prototype nested within it carry a `bytecode`
  encoding — i.e. nothing in the tree fell back to the interpreter.

  Use this after `compile/1` to assert dispatcher coverage. A `false` result
  means at least one prototype contains an opcode the encoder still rejects
  (today: `:goto` / `:label`).
  """
  @spec fully_compiled?(Prototype.t()) :: boolean()
  def fully_compiled?(%Prototype{bytecode: nil}), do: false

  def fully_compiled?(%Prototype{prototypes: children}) do
    Enum.all?(children, &fully_compiled?/1)
  end

  # ── Encoding ────────────────────────────────────────────────────────────
  #
  # Walks an instruction list, accumulating opcode tuples in reverse. On
  # the first uncovered opcode, the whole list bails out as `:fallback`.
  #
  # `:source_line` opcodes are stripped from the bytecode entirely — keeping
  # them would cost one no-op dispatch each (~228k extra cycles for fib(25))
  # — and instead update the rolling `current_line`. Call opcodes
  # (`:call_one`/`:call_zero`/`:call_multi`) bake that line into their own
  # tuple so the dispatcher can pass it through to the executor at native-
  # call boundaries without any parallel lookup table. Other opcodes ignore
  # the line.

  defp encode_list([], acc, _current_line), do: {:ok, Enum.reverse(acc)}

  defp encode_list([{:source_line, n, _} | rest], acc, _current_line) do
    encode_list(rest, acc, n)
  end

  defp encode_list([instr | rest], acc, current_line) do
    case encode(instr, current_line) do
      {:ok, encoded} ->
        encode_list(rest, [annotate_line(encoded, current_line) | acc], current_line)

      :fallback ->
        :fallback
    end
  end

  # Bakes the current source line into the call opcodes and `:generic_for`
  # so the dispatcher can attribute native-call errors without a parallel
  # lookup table. `:generic_for` carries its own line because the iterator
  # is invoked at the `for` statement before the body's `:source_line`
  # opcodes run, so a native iterator raising mid-step (e.g. `error()`)
  # would otherwise leak `:0:`. Other opcodes pass through unchanged —
  # line attribution for non-call raise sites (binops, indexing, concat)
  # is deferred.
  defp annotate_line({@op_call_one, base, args, hint}, line), do: {@op_call_one, base, args, hint, line}

  defp annotate_line({@op_call_zero, base, args, hint}, line), do: {@op_call_zero, base, args, hint, line}

  defp annotate_line({@op_call_multi, base, args, results, hint}, line),
    do: {@op_call_multi, base, args, results, hint, line}

  defp annotate_line({@op_generic_for, base, var_regs, body}, line), do: {@op_generic_for, base, var_regs, body, line}

  defp annotate_line(other, _line), do: other

  # ── Per-opcode encoding ─────────────────────────────────────────────────
  #
  # Body-carrying opcodes (`:test` / `:numeric_for` / `:while_loop` /
  # `:repeat_loop` / `:generic_for`) match `encode/2` so they can seed their
  # nested-body `encode_list` with the in-scope `current_line`. Without it
  # the nested body would restart at line 0 and a native call raising inside
  # a while/repeat condition (which carries no `:source_line` opcode of its
  # own) would bake `:0:` into the §6.1 error value, diverging from the
  # interpreter, which threads the enclosing line through the body. Every
  # other opcode is line-agnostic and delegates to `encode/1`.

  defp encode({:test, reg, then_body, else_body}, current_line) do
    with {:ok, then_enc} <- encode_list(then_body, [], current_line),
         {:ok, else_enc} <- encode_list(else_body, [], current_line) do
      {:ok, {@op_test, reg, List.to_tuple(then_enc), List.to_tuple(else_enc)}}
    end
  end

  defp encode({:numeric_for, base, loop_var, body}, current_line) do
    case encode_list(body, [], current_line) do
      {:ok, body_enc} ->
        {:ok, {@op_numeric_for, base, loop_var, List.to_tuple(body_enc)}}

      :fallback ->
        :fallback
    end
  end

  defp encode({:while_loop, cond_body, test_reg, loop_body}, current_line) do
    with {:ok, cond_enc} <- encode_list(cond_body, [], current_line),
         {:ok, body_enc} <- encode_list(loop_body, [], current_line) do
      {:ok, {@op_while_loop, test_reg, List.to_tuple(cond_enc), List.to_tuple(body_enc)}}
    end
  end

  defp encode({:repeat_loop, loop_body, cond_body, test_reg}, current_line) do
    with {:ok, body_enc} <- encode_list(loop_body, [], current_line),
         {:ok, cond_enc} <- encode_list(cond_body, [], current_line) do
      {:ok, {@op_repeat_loop, test_reg, List.to_tuple(body_enc), List.to_tuple(cond_enc)}}
    end
  end

  defp encode({:generic_for, base, var_regs, body}, current_line) when is_list(var_regs) do
    case encode_list(body, [], current_line) do
      {:ok, body_enc} ->
        {:ok, {@op_generic_for, base, List.to_tuple(var_regs), List.to_tuple(body_enc)}}

      :fallback ->
        :fallback
    end
  end

  defp encode(instr, _current_line), do: encode(instr)

  defp encode({:load_constant, dest, value}), do: {:ok, {@op_load_constant, dest, value}}

  defp encode({:load_boolean, dest, value}), do: {:ok, {@op_load_boolean, dest, value}}

  # `:load_nil` clears `count + 1` registers starting at `dest`. The
  # dispatcher unrolls the clear at execution time, so the operand is
  # passed through verbatim.
  defp encode({:load_nil, dest, count}), do: {:ok, {@op_load_nil, dest, count}}

  defp encode({:move, dest, source}), do: {:ok, {@op_move, dest, source}}

  defp encode({:load_env, dest}), do: {:ok, {@op_load_env, dest}}

  defp encode({:get_upvalue, dest, index}), do: {:ok, {@op_get_upvalue, dest, index}}

  defp encode({:get_global, dest, name}), do: {:ok, {@op_get_global, dest, name}}

  # `:get_field` covers the `_ENV.name` global-lookup form alongside any
  # other table field read. The dispatcher reuses the interpreter's
  # `index_value` helper for the slow path, so coverage is full-fidelity.
  defp encode({:get_field, dest, table_reg, name, name_hint}),
    do: {:ok, {@op_get_field, dest, table_reg, name, name_hint}}

  # Arithmetic instructions carry per-operand hint tuples for error
  # attribution. The v2 dispatcher threads them into
  # `Executor.dispatcher_binop/7` / `dispatcher_unop/5` so on-disk
  # bytecode preserves the hint suffix (e.g. `(local 'n')`) on
  # arithmetic type errors.
  defp encode({:add, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_add, dest, a, b, hint_a, hint_b}}
  defp encode({:subtract, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_subtract, dest, a, b, hint_a, hint_b}}
  defp encode({:multiply, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_multiply, dest, a, b, hint_a, hint_b}}
  defp encode({:divide, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_divide, dest, a, b, hint_a, hint_b}}
  defp encode({:floor_divide, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_floor_divide, dest, a, b, hint_a, hint_b}}
  defp encode({:modulo, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_modulo, dest, a, b, hint_a, hint_b}}
  defp encode({:power, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_power, dest, a, b, hint_a, hint_b}}
  defp encode({:negate, dest, src, hint}), do: {:ok, {@op_negate, dest, src, hint}}

  # Bitwise instructions carry the same per-operand hint tuples as
  # arithmetic. The dispatcher inlines a two-integer fast path for
  # band/bor/bxor and bridges to `Executor.dispatcher_bitwise/7` /
  # `dispatcher_bnot/5` for non-integer operands, metamethods, and all
  # shifts — so on-disk bytecode preserves both the int64 wrap and the
  # hint suffix on `attempt to perform bitwise operation` errors.
  defp encode({:bitwise_and, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_bitwise_and, dest, a, b, hint_a, hint_b}}
  defp encode({:bitwise_or, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_bitwise_or, dest, a, b, hint_a, hint_b}}
  defp encode({:bitwise_xor, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_bitwise_xor, dest, a, b, hint_a, hint_b}}
  defp encode({:shift_left, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_shift_left, dest, a, b, hint_a, hint_b}}
  defp encode({:shift_right, dest, a, b, hint_a, hint_b}), do: {:ok, {@op_shift_right, dest, a, b, hint_a, hint_b}}
  defp encode({:bitwise_not, dest, src, hint}), do: {:ok, {@op_bitwise_not, dest, src, hint}}

  defp encode({:less_than, dest, a, b}), do: {:ok, {@op_less_than, dest, a, b}}
  defp encode({:less_equal, dest, a, b}), do: {:ok, {@op_less_equal, dest, a, b}}
  defp encode({:greater_than, dest, a, b}), do: {:ok, {@op_greater_than, dest, a, b}}
  defp encode({:greater_equal, dest, a, b}), do: {:ok, {@op_greater_equal, dest, a, b}}
  defp encode({:equal, dest, a, b}), do: {:ok, {@op_equal, dest, a, b}}
  defp encode({:not_equal, dest, a, b}), do: {:ok, {@op_not_equal, dest, a, b}}

  defp encode({:not, dest, src}), do: {:ok, {@op_not, dest, src}}

  # `:test` carries nested instruction lists for the then/else branches.
  # It encodes via `encode/2` (above) so each branch inherits the enclosing
  # `current_line`.

  # `:call` shapes:
  #
  #   - `result_count == 1` with fixed positive arg_count → `:call_one`,
  #     the expression-call hot path (every recursive call in fib /
  #     factorial, every `f(x)` used as an rvalue).
  #   - `result_count == 0` with fixed positive arg_count → `:call_zero`,
  #     the statement-call form (e.g. `table.sort(t)`).
  #   - Anything else (multi-return result, negative result count,
  #     `{:multi, _}` arg shape, negative arg count) → `:call_multi`.
  #     This is the B5c-v2 catch-all for the multi-return machinery.
  #
  # `name_hint` is preserved on every shape for error attribution.
  defp encode({:call, base, arg_count, 1, name_hint}) when is_integer(arg_count) and arg_count >= 0 do
    {:ok, {@op_call_one, base, arg_count, name_hint}}
  end

  defp encode({:call, base, arg_count, 0, name_hint}) when is_integer(arg_count) and arg_count >= 0 do
    {:ok, {@op_call_zero, base, arg_count, name_hint}}
  end

  defp encode({:call, base, arg_count, result_count, name_hint}) do
    {:ok, {@op_call_multi, base, arg_count, result_count, name_hint}}
  end

  # `:return` shapes:
  #
  #   - `count == 1` is the hot path (every recursive return in fib/factorial).
  #     Stays a dedicated opcode so the dispatcher can avoid the result-list
  #     allocation on the bottom of the call stack.
  #   - `count == 0` is the codegen-emitted "no explicit return" form;
  #     handled by `:return_zero`.
  #   - `count > 1` is the explicit multi-return form (`return a, b, c`).
  #   - `count < 0` is `-1` for forwarding all results to caller's caller,
  #     `-2` for expansion. Both share the multi-return collection path.
  #   - `{:multi_return, fixed}` is the codegen sentinel for "fixed plus
  #     `state.multi_return_count` trailing values"; equivalent to the
  #     negative-count form but encoded explicitly.
  defp encode({:return, base, 1}), do: {:ok, {@op_return_one, base}}
  defp encode({:return, _base, 0}), do: {:ok, {@op_return_zero}}

  defp encode({:return, base, count}) when is_integer(count) and count > 1 do
    {:ok, {@op_return_multi, base, count}}
  end

  defp encode({:return, base, count}) when is_integer(count) and count < 0 do
    # Negative counts: `-(count + 1)` is the fixed prefix; the rest comes
    # from `state.multi_return_count` at dispatch time.
    {:ok, {@op_return_collect, base, -(count + 1)}}
  end

  defp encode({:return, base, {:multi_return, fixed_count}}) do
    {:ok, {@op_return_collect, base, fixed_count}}
  end

  # ── Table opcodes ──────────────────────────────────────────────────────
  #
  # The dispatcher inlines the tref + integer/binary-key fast path for
  # `:get_table` / `:set_table` / `:set_field` / `:length` and bridges to
  # `Lua.VM.Executor.dispatcher_*` helpers for the metatable / non-tref
  # slow paths. Array/hash hints on `:new_table` are discarded — the
  # executor handler also ignores them.

  defp encode({:new_table, dest, _array_hint, _hash_hint}), do: {:ok, {@op_new_table, dest}}

  defp encode({:get_table, dest, table_reg, key_reg, name_hint}),
    do: {:ok, {@op_get_table, dest, table_reg, key_reg, name_hint}}

  defp encode({:set_table, table_reg, key_reg, value_reg, name_hint}),
    do: {:ok, {@op_set_table, table_reg, key_reg, value_reg, name_hint}}

  defp encode({:set_field, table_reg, name, value_reg, name_hint}),
    do: {:ok, {@op_set_field, table_reg, name, value_reg, name_hint}}

  # `:set_list` with a positive integer `count` is the table-constructor
  # form (`{1, 2, 3}`).
  #
  # - `{:multi, init_count}` absorbs a multi-return call's results (e.g.
  #   `{f(), 1}`): the dispatcher folds `init_count` with
  #   `state.multi_return_count` and reuses the same `set_list_pairs`
  #   machinery, mirroring the interpreter's `{:multi, _}` clause.
  # - `count == 0` is the interpreter's "consume `multi_return_count`
  #   trailing values" sentinel. Current codegen never emits it from a
  #   literal constructor, but encoding it as a no-op would silently
  #   diverge from the interpreter if codegen ever did. The guard makes
  #   that contract explicit — it stays on the interpreter.
  defp encode({:set_list, table_reg, start, count, offset}) when is_integer(count) and count > 0,
    do: {:ok, {@op_set_list, table_reg, start, count, offset}}

  defp encode({:set_list, table_reg, start, {:multi, init_count}, offset}),
    do: {:ok, {@op_set_list_multi, table_reg, start, init_count, offset}}

  defp encode({:length, dest, source}), do: {:ok, {@op_length, dest, source}}

  # `:numeric_for`, `:while_loop`, `:repeat_loop`, `:generic_for` each carry
  # nested instruction lists for the loop body (and, for while / repeat, the
  # condition). They encode via `encode/2` (above) so the nested bodies
  # inherit the enclosing `current_line` — the while/repeat condition body
  # carries no `:source_line` opcode of its own, so without the inherited
  # line a native call raising inside the condition would bake `:0:`. The
  # B5b-v2 guard against `:break` inside `:numeric_for` is gone — `:break` is
  # a first-class opcode now and the dispatcher's `find_loop_exit/1` handles
  # the unwind. `:generic_for`'s variable-register list is encoded as a tuple
  # for the dispatcher to walk with `:erlang.element/2`.

  # ── Closures, upvalues, varargs, self, concat, break ────────────────────

  defp encode({:closure, dest, proto_index}), do: {:ok, {@op_closure, dest, proto_index}}

  defp encode({:set_upvalue, index, source}), do: {:ok, {@op_set_upvalue, index, source}}

  defp encode({:get_open_upvalue, dest, reg}), do: {:ok, {@op_get_open_upvalue, dest, reg}}

  defp encode({:set_open_upvalue, reg, source}), do: {:ok, {@op_set_open_upvalue, reg, source}}

  defp encode({:close_upvalues, threshold}), do: {:ok, {@op_close_upvalues, threshold}}

  defp encode({:vararg, base, count}), do: {:ok, {@op_vararg, base, count}}

  defp encode({:return_vararg}), do: {:ok, {@op_return_proto_varargs}}

  defp encode({:self, base, obj_reg, method_name, name_hint}),
    do: {:ok, {@op_self, base, obj_reg, method_name, name_hint}}

  defp encode({:concatenate, dest, a, b}), do: {:ok, {@op_concatenate, dest, a, b}}

  defp encode(:break), do: {:ok, {@op_break}}

  # `:label` keeps its name and scope `level` so `resolve_gotos/2` can map
  # goto targets to PCs and close levels; at run time it is a no-op. `:goto`
  # is emitted as a placeholder and rewritten by `resolve_gotos/2` once every
  # block's label PCs are known.
  defp encode({:label, name, level}), do: {:ok, {@op_label, name, level}}

  defp encode({:goto, name}), do: {:ok, {:pending_goto, name}}

  # Anything else stays on the interpreter. `:source_line` is stripped
  # upstream in `encode_list/2`, so it never reaches this clause table.
  defp encode(_other), do: :fallback

  # ── Goto resolution ─────────────────────────────────────────────────────
  #
  # Walk the encoded tuple tree, rewriting each `{:pending_goto, name}` to
  # `{@op_goto, depth, target_pc, level}`. Mirrors `Lua.Compiler.GotoResolution`
  # (interpreter) but over encoded tuples with PCs: `depth` counts the `cont`
  # entries the dispatcher drops (a `:test` branch pushes one, a loop body
  # two), `target_pc` is the `{@op_label, ...}` index in the destination
  # tuple, `level` its scope close threshold. `ancestors` is a stack of
  # `{labels, child_pc, weight}` from the innermost enclosing tuple outward.

  # `cont` entries each construct pushes — must match the dispatcher.
  @test_weight 1
  @loop_weight 2

  defp resolve_gotos(code, ancestors) do
    entries = Tuple.to_list(code)
    labels = collect_labels(entries)

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, pc} -> resolve_entry(entry, pc, labels, ancestors) end)
    |> List.to_tuple()
  end

  defp collect_labels(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {{@op_label, name, level}, pc} -> [{name, pc, level}]
      _ -> []
    end)
  end

  defp resolve_entry({:pending_goto, name}, pc, labels, ancestors) do
    case resolve_goto_target(name, labels, pc, ancestors) do
      {:ok, depth, target_pc, level} ->
        {@op_goto, depth, target_pc, level}

      :error ->
        raise "unresolved goto target #{inspect(name)} — codegen should not emit this"
    end
  end

  defp resolve_entry({@op_test, reg, then_bc, else_bc}, pc, labels, ancestors) do
    anc = [{labels, pc, @test_weight} | ancestors]
    {@op_test, reg, resolve_gotos(then_bc, anc), resolve_gotos(else_bc, anc)}
  end

  defp resolve_entry({@op_numeric_for, base, loop_var, body_bc}, pc, labels, ancestors) do
    {@op_numeric_for, base, loop_var, resolve_gotos(body_bc, [{labels, pc, @loop_weight} | ancestors])}
  end

  defp resolve_entry({@op_while_loop, test_reg, cond_bc, body_bc}, pc, labels, ancestors) do
    {@op_while_loop, test_reg, cond_bc, resolve_gotos(body_bc, [{labels, pc, @loop_weight} | ancestors])}
  end

  defp resolve_entry({@op_repeat_loop, test_reg, body_bc, cond_bc}, pc, labels, ancestors) do
    {@op_repeat_loop, test_reg, resolve_gotos(body_bc, [{labels, pc, @loop_weight} | ancestors]), cond_bc}
  end

  defp resolve_entry({@op_generic_for, base, var_regs, body_bc, line}, pc, labels, ancestors) do
    {@op_generic_for, base, var_regs, resolve_gotos(body_bc, [{labels, pc, @loop_weight} | ancestors]), line}
  end

  defp resolve_entry(other, _pc, _labels, _ancestors), do: other

  defp resolve_goto_target(name, labels, from_pc, ancestors) do
    case find_label(labels, name, from_pc) do
      {:ok, target_pc, level} -> {:ok, 0, target_pc, level}
      :error -> resolve_in_ancestors(name, ancestors, 0)
    end
  end

  defp resolve_in_ancestors(_name, [], _depth), do: :error

  defp resolve_in_ancestors(name, [{labels, from_pc, weight} | rest], depth) do
    depth = depth + weight

    case find_label(labels, name, from_pc) do
      {:ok, target_pc, level} -> {:ok, depth, target_pc, level}
      :error -> resolve_in_ancestors(name, rest, depth)
    end
  end

  # Nearest label after `from_pc`, else nearest before — matching the
  # interpreter's `GotoResolution`. Within a real scope a name is unique;
  # flattened `do` blocks are the only multi-candidate case.
  defp find_label(labels, name, from_pc) do
    matching = Enum.filter(labels, fn {n, _, _} -> n == name end)
    after_label = matching |> Enum.filter(fn {_, pc, _} -> pc > from_pc end) |> Enum.min_by(&elem(&1, 1), fn -> nil end)
    before_label = matching |> Enum.filter(fn {_, pc, _} -> pc < from_pc end) |> Enum.max_by(&elem(&1, 1), fn -> nil end)

    case after_label || before_label do
      {_name, pc, level} -> {:ok, pc, level}
      nil -> :error
    end
  end

  # ── Opcode tag accessors ────────────────────────────────────────────────
  #
  # Exposed for `Lua.VM.Dispatcher` (which mirrors these as its own
  # compile-time constants) and for tests that assert on the encoded
  # shape.

  @spec op_load_constant() :: pos_integer()
  def op_load_constant, do: @op_load_constant
  def op_load_boolean, do: @op_load_boolean
  def op_load_nil, do: @op_load_nil
  def op_move, do: @op_move
  def op_load_env, do: @op_load_env
  def op_get_upvalue, do: @op_get_upvalue
  def op_get_global, do: @op_get_global
  def op_get_field, do: @op_get_field
  def op_add, do: @op_add
  def op_subtract, do: @op_subtract
  def op_multiply, do: @op_multiply
  def op_divide, do: @op_divide
  def op_floor_divide, do: @op_floor_divide
  def op_modulo, do: @op_modulo
  def op_power, do: @op_power
  def op_negate, do: @op_negate
  def op_less_than, do: @op_less_than
  def op_less_equal, do: @op_less_equal
  def op_greater_than, do: @op_greater_than
  def op_greater_equal, do: @op_greater_equal
  def op_equal, do: @op_equal
  def op_not_equal, do: @op_not_equal
  def op_not, do: @op_not
  def op_test, do: @op_test
  def op_call_zero, do: @op_call_zero
  def op_call_one, do: @op_call_one
  def op_return_one, do: @op_return_one
  def op_return_zero, do: @op_return_zero
  def op_source_line, do: @op_source_line
  def op_new_table, do: @op_new_table
  def op_get_table, do: @op_get_table
  def op_set_table, do: @op_set_table
  def op_set_field, do: @op_set_field
  def op_set_list, do: @op_set_list
  def op_length, do: @op_length
  def op_numeric_for, do: @op_numeric_for
  def op_closure, do: @op_closure
  def op_set_upvalue, do: @op_set_upvalue
  def op_get_open_upvalue, do: @op_get_open_upvalue
  def op_set_open_upvalue, do: @op_set_open_upvalue
  def op_vararg, do: @op_vararg
  def op_return_proto_varargs, do: @op_return_proto_varargs
  def op_return_collect, do: @op_return_collect
  def op_return_multi, do: @op_return_multi
  def op_call_multi, do: @op_call_multi
  def op_self, do: @op_self
  def op_concatenate, do: @op_concatenate
  def op_break, do: @op_break
  def op_while_loop, do: @op_while_loop
  def op_repeat_loop, do: @op_repeat_loop
  def op_generic_for, do: @op_generic_for
  def op_close_upvalues, do: @op_close_upvalues
  def op_bitwise_and, do: @op_bitwise_and
  def op_bitwise_or, do: @op_bitwise_or
  def op_bitwise_xor, do: @op_bitwise_xor
  def op_shift_left, do: @op_shift_left
  def op_shift_right, do: @op_shift_right
  def op_bitwise_not, do: @op_bitwise_not
  def op_set_list_multi, do: @op_set_list_multi
  def op_label, do: @op_label
  def op_goto, do: @op_goto
end
