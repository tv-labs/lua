defmodule Lua.Compiler.Peephole do
  @moduledoc """
  Peephole optimiser over the instruction stream `Lua.Compiler.Codegen`
  emits, run before `Lua.Compiler.Bytecode.compile/1`.

  Codegen is deliberately naive: it allocates a fresh temporary for every
  intermediate value and copies it into place, it re-reads `_ENV` out of the
  upvalue table before every global access, and it materialises every literal
  into a register before using it. That keeps codegen simple, and leaves a
  small set of purely local rewrites on the table:

    1. **Move elision.** `{op, tmp, …}` immediately followed by
       `{:move, dst, tmp}` retargets the producer at `dst` when `tmp` is
       neither an operand of the producer nor read again.
    2. **Constant folding.** `{:load_constant, k, value}` immediately followed
       by an arithmetic or comparison op using `k` as its right operand folds
       into a `_k` variant carrying the constant inline.
    3. **Upvalue-field fusion.** `{:get_upvalue, t, i}` immediately followed by
       a field read or write through `t` fuses into
       `:get_field_upvalue` / `:set_field_upvalue`. Every global access is
       exactly this shape, so this halves their instruction count.
    4. **Unreachable-code removal** after an unconditional `return` / `break`.
    5. **Upvalue round-trip collapse.** `set_upvalue i, r` immediately
       followed by `get_upvalue d, i` reads the register directly.
    6. **Redundant `close_upvalues` removal** in functions that create no
       closures — nothing in such a function can open an upvalue cell over
       one of its own registers, so there is never anything to close.

  Both engines run the rewritten stream: the interpreter
  (`Lua.VM.Executor`) walks `instructions` directly, the dispatcher
  (`Lua.VM.Dispatcher`) walks the `Lua.Compiler.Bytecode` encoding of the
  same list. Every opcode introduced here therefore has a handler in both.

  ## Safety

  Every rewrite is gated on the rewritten temporary being *dead* — never
  read again on any path that can follow. Liveness is answered by scanning
  the instructions that may execute after the rewrite site: the rest of the
  enclosing block, then the rest of each enclosing block outward, plus the
  enclosing loop instruction itself (which covers the back edge). Registers
  read through an upvalue cell count: `:closure` reads every parent register
  its child prototype captures, and the open-upvalue opcodes read theirs
  syntactically.

  `reads?/3` defaults to "reads everything" for an instruction shape it does
  not recognise, so an opcode added to codegen without a clause here disables
  the optimisation rather than miscompiling it.

  Functions containing `goto` / `::label::` opt out entirely. A backward jump
  makes "the instructions that may follow" a control-flow-graph question
  rather than a lexical one, and `goto` is rare enough that the conservative
  answer costs nothing.
  """

  alias Lua.Compiler.Codegen
  alias Lua.Compiler.Prototype

  # Producers whose destination register is operand 1, that write exactly
  # that one register, and that read every operand before writing it. Only
  # these can have their destination retargeted by move elision.
  @coalescible [
    :load_constant,
    :load_boolean,
    :load_env,
    :move,
    :get_upvalue,
    :get_open_upvalue,
    :get_global,
    :new_table,
    :get_table,
    :get_field,
    :get_field_upvalue,
    :closure,
    :length,
    :not,
    :negate,
    :bitwise_not,
    :concatenate,
    :add,
    :subtract,
    :multiply,
    :divide,
    :floor_divide,
    :modulo,
    :power,
    :bitwise_and,
    :bitwise_or,
    :bitwise_xor,
    :shift_left,
    :shift_right,
    :add_k,
    :subtract_k,
    :multiply_k,
    :equal,
    :not_equal,
    :less_than,
    :less_equal,
    :greater_than,
    :greater_equal,
    :equal_k,
    :less_than_k,
    :less_equal_k
  ]

  # `{op, dest, a, b, hint_a, hint_b}` shapes.
  @binary_ops [
    :add,
    :subtract,
    :multiply,
    :divide,
    :floor_divide,
    :modulo,
    :power,
    :bitwise_and,
    :bitwise_or,
    :bitwise_xor,
    :shift_left,
    :shift_right
  ]

  # `{op, dest, a, b}` shapes.
  @compare_ops [:equal, :not_equal, :less_than, :less_equal, :greater_than, :greater_equal]

  # `{op, dest, a, constant, hint_a}` shapes produced by rule 2.
  @arith_k_ops [:add_k, :subtract_k, :multiply_k]

  # `{op, dest, a, constant}` shapes produced by rule 2.
  @compare_k_ops [:equal_k, :less_than_k, :less_equal_k]

  @doc """
  Optimise a prototype and every prototype nested within it.

  `max_registers` is recomputed from the rewritten stream. It only ever
  shrinks: the result is clamped to the incoming value so a shape this
  module does not model can never widen the register file, and bounded
  below by the highest register index the rewritten stream still touches.
  """
  @spec optimize(Prototype.t()) :: Prototype.t()
  def optimize(%Prototype{} = proto) do
    prototypes = Enum.map(proto.prototypes, &optimize/1)
    instructions = optimize_instructions(proto.instructions, prototypes)

    %{
      proto
      | prototypes: prototypes,
        instructions: instructions,
        max_registers: recompute_max_registers(proto, instructions, prototypes)
    }
  end

  defp optimize_instructions(instructions, prototypes) do
    if contains_goto?(instructions) do
      instructions
    else
      instructions
      |> drop_redundant_closes()
      |> drop_unreachable()
      |> collapse_upvalue_roundtrip()
      |> fuse_block([], prototypes)
    end
  end

  # ── Rule 6: redundant `close_upvalues` ──────────────────────────────────
  #
  # An open upvalue cell over one of this function's registers can only be
  # created by a `:closure` opcode in this function capturing it as a
  # `:parent_local`. A function that builds no closures therefore never has
  # anything to close, and every `close_upvalues` it carries is a pure
  # dispatch cost. The gate is the whole function, not the individual block:
  # `goto` closes at explicit levels and loop bodies close at iteration
  # boundaries, and neither is safe to reason about block by block.

  defp drop_redundant_closes(instructions) do
    if contains_closure?(instructions) do
      instructions
    else
      strip_closes(instructions)
    end
  end

  defp strip_closes(instructions) do
    instructions
    |> Enum.reject(&match?({:close_upvalues, _}, &1))
    |> Enum.map(fn instr -> map_bodies(instr, &strip_closes/1) end)
  end

  # ── Rule 4: unreachable code ────────────────────────────────────────────
  #
  # Nothing after an unconditional `return` / `break` in the same block can
  # run. Codegen appends a block-exit `close_upvalues` unconditionally, so
  # every `if … then return x end` carries one.

  defp drop_unreachable(instructions) do
    instructions
    |> Enum.map(fn instr -> map_bodies(instr, &drop_unreachable/1) end)
    |> truncate_after_terminator([])
  end

  defp truncate_after_terminator([], acc), do: Enum.reverse(acc)

  defp truncate_after_terminator([instr | rest], acc) do
    if terminator?(instr) do
      Enum.reverse([instr | acc])
    else
      truncate_after_terminator(rest, [instr | acc])
    end
  end

  defp terminator?({:return, _base, _count}), do: true
  defp terminator?({:return_vararg}), do: true
  defp terminator?(:break), do: true
  defp terminator?(_instr), do: false

  # ── Rule 5: upvalue round-trip ──────────────────────────────────────────
  #
  # `set_upvalue i, r` followed immediately by `get_upvalue d, i` reads back
  # the value just written. Nothing can run between the two, so the register
  # still holds it — read it directly and skip the cell map entirely. The
  # write stays: the cell is shared state other closures observe.

  defp collapse_upvalue_roundtrip(instructions) do
    instructions
    |> Enum.map(fn instr -> map_bodies(instr, &collapse_upvalue_roundtrip/1) end)
    |> collapse_roundtrip_pairs()
  end

  defp collapse_roundtrip_pairs([]), do: []

  defp collapse_roundtrip_pairs([{:set_upvalue, index, source} = set, {:get_upvalue, dest, index} | rest]) do
    [set, {:move, dest, source} | collapse_roundtrip_pairs(rest)]
  end

  defp collapse_roundtrip_pairs([instr | rest]), do: [instr | collapse_roundtrip_pairs(rest)]

  # ── Rules 1–3: fusion ───────────────────────────────────────────────────
  #
  # A single left-to-right walk. Each rewrite collapses two instructions into
  # one and the result is re-examined against its new successor, so chains
  # (`get_upvalue` → `get_field` → `move`) collapse in one pass without a
  # fixpoint loop.
  #
  # `future` is the list of instruction lists that may execute after the
  # current position, innermost first. Every rewrite only ever removes reads,
  # so scanning a not-yet-optimised tail is conservative in the safe
  # direction.

  defp fuse_block([], _future, _prototypes), do: []

  defp fuse_block([instr], future, prototypes) do
    [fuse_bodies(instr, future, prototypes)]
  end

  defp fuse_block([first, second | rest] = block, future, prototypes) do
    case fuse(first, second, [rest | future], prototypes) do
      {:ok, fused} ->
        fuse_block([fused | rest], future, prototypes)

      :error ->
        case elide_move(block, future, prototypes) do
          {:ok, rewritten} ->
            fuse_block(rewritten, future, prototypes)

          :error ->
            tail = [second | rest]
            [fuse_bodies(first, [tail | future], prototypes) | fuse_block(tail, future, prototypes)]
        end
    end
  end

  defp fuse_bodies(instr, future, prototypes) do
    case bodies(instr) do
      [] ->
        instr

      list ->
        optimised =
          list
          |> Enum.zip(body_futures(instr, future))
          |> Enum.map(fn {body, body_future} -> fuse_block(body, body_future, prototypes) end)

        put_bodies(instr, optimised)
    end
  end

  # The future of each nested body, parallel to `bodies/1`.
  #
  # A branch body simply continues into whatever follows the branch. A loop
  # body continues into one more trip around the loop first, spelled out
  # instruction by instruction so the scan can find a kill on the back edge
  # — a temporary rewritten at the top of every iteration is dead at the
  # bottom of the previous one, which is most of them. The loop instruction
  # with its bodies emptied stands in for the header's own register reads
  # (the `for` control triple, the `while` test register).
  defp body_futures({:test, _reg, _then_body, _else_body}, future), do: [future, future]
  defp body_futures({:test_and, _dest, _source, _body}, future), do: [future]
  defp body_futures({:test_or, _dest, _source, _body}, future), do: [future]

  defp body_futures({:while_loop, cond_body, _reg, body} = instr, future) do
    header = [put_bodies(instr, [[], []])]
    [[header ++ body ++ cond_body | future], [cond_body ++ header ++ body | future]]
  end

  defp body_futures({:repeat_loop, body, cond_body, _reg} = instr, future) do
    header = [put_bodies(instr, [[], []])]
    [[cond_body ++ header ++ body | future], [header ++ body ++ cond_body | future]]
  end

  defp body_futures({:numeric_for, _base, _loop_var, body} = instr, future) do
    [[[put_bodies(instr, [[]])] ++ body | future]]
  end

  defp body_futures({:generic_for, _base, _var_regs, body} = instr, future) do
    [[[put_bodies(instr, [[]])] ++ body | future]]
  end

  # Rule 3: `_ENV` (or any upvalue) field access. `t` holding the table is a
  # scratch register the fused form no longer needs. When the field read
  # writes back into `t` its own write kills the value, so no liveness check
  # is needed.
  defp fuse({:get_upvalue, table_reg, index}, {:get_field, dest, table_reg, name, hint}, future, prototypes) do
    if dest == table_reg or dead?(table_reg, future, prototypes) do
      {:ok, {:get_field_upvalue, dest, index, name, hint}}
    else
      :error
    end
  end

  defp fuse({:get_upvalue, table_reg, index}, {:set_field, table_reg, name, value_reg, hint}, future, prototypes) do
    if value_reg != table_reg and dead?(table_reg, future, prototypes) do
      {:ok, {:set_field_upvalue, index, name, value_reg, hint}}
    else
      :error
    end
  end

  # Rule 2: fold a literal into the operation that consumes it. Only the
  # right operand folds, and only when the constant side carries no error
  # hint — which is the shape codegen emits for a literal, so nothing is
  # lost from `Lua.format_exception/1` output.
  defp fuse({:load_constant, k_reg, value}, {op, dest, a, k_reg, hint_a, nil}, future, prototypes) do
    with {:ok, fused_op} <- fetch_arith_k(op),
         true <- a != k_reg,
         true <- dest == k_reg or dead?(k_reg, future, prototypes) do
      {:ok, {fused_op, dest, a, value, hint_a}}
    else
      _ -> :error
    end
  end

  defp fuse({:load_constant, k_reg, value}, {op, dest, a, k_reg}, future, prototypes) do
    with {:ok, fused_op} <- fetch_compare_k(op),
         true <- a != k_reg,
         true <- dest == k_reg or dead?(k_reg, future, prototypes) do
      {:ok, {fused_op, dest, a, value}}
    else
      _ -> :error
    end
  end

  defp fuse(_first, _second, _future, _prototypes), do: :error

  # ── Rule 1: destination coalescing ──────────────────────────────────────
  #
  # A producer writing a scratch register that is later copied into its real
  # home writes the real home directly, and the copy disappears. Codegen
  # emits the pair for every call argument and every `for` header, usually
  # but not always adjacently — `move base+1, tmp1; move base+2, tmp2`
  # separates each producer from its copy — so the copy is searched for
  # within a bounded window.
  #
  # Instructions in the window must be transparent to both registers: they
  # may not read or write `tmp` (whose write is moving later in the stream)
  # and they may not read or write `dest` (whose write is moving earlier).
  # Only straight-line shapes qualify, so no branch, loop, or `break` can
  # observe the reordering.

  @window 16

  defp elide_move([producer | rest], future, prototypes) do
    with true <- coalescible?(producer),
         tmp = :erlang.element(2, producer),
         false <- reads?(producer, tmp, prototypes),
         {:ok, dest, skipped, after_move} <- find_copy(rest, tmp, prototypes, @window, []),
         true <- tmp != dest,
         false <- reads?(producer, dest, prototypes),
         true <- Enum.all?(skipped, &transparent?(&1, dest, prototypes)),
         true <- dead?(tmp, [after_move | future], prototypes) do
      {:ok, [:erlang.setelement(2, producer, dest) | Enum.reverse(skipped, after_move)]}
    else
      _ -> :error
    end
  end

  defp find_copy([{:move, dest, tmp} | after_move], tmp, _prototypes, _budget, skipped) do
    {:ok, dest, skipped, after_move}
  end

  defp find_copy([instr | rest], tmp, prototypes, budget, skipped) when budget > 0 do
    if transparent?(instr, tmp, prototypes) do
      find_copy(rest, tmp, prototypes, budget - 1, [instr | skipped])
    else
      :error
    end
  end

  defp find_copy(_instructions, _tmp, _prototypes, _budget, _skipped), do: :error

  # Straight-line shapes a coalesced write may cross. Everything omitted —
  # `:test`, the loops, `:return`, `:break`, `:goto`, `:vararg` (whose
  # written range is a run-time value) — ends the window.
  @window_safe [
    :load_constant,
    :load_boolean,
    :load_nil,
    :load_env,
    :move,
    :get_upvalue,
    :set_upvalue,
    :get_open_upvalue,
    :set_open_upvalue,
    :close_upvalues,
    :get_global,
    :new_table,
    :get_table,
    :set_table,
    :get_field,
    :set_field,
    :get_field_upvalue,
    :set_field_upvalue,
    :set_list,
    :length,
    :not,
    :negate,
    :bitwise_not,
    :concatenate,
    :self,
    :call,
    :closure,
    :source_line,
    :add,
    :subtract,
    :multiply,
    :divide,
    :floor_divide,
    :modulo,
    :power,
    :bitwise_and,
    :bitwise_or,
    :bitwise_xor,
    :shift_left,
    :shift_right,
    :add_k,
    :subtract_k,
    :multiply_k,
    :equal,
    :not_equal,
    :less_than,
    :less_equal,
    :greater_than,
    :greater_equal,
    :equal_k,
    :less_than_k,
    :less_equal_k
  ]

  defp transparent?(instr, reg, prototypes) when is_tuple(instr) do
    :erlang.element(1, instr) in @window_safe and
      not reads?(instr, reg, prototypes) and
      not window_writes?(instr, reg)
  end

  defp transparent?(_instr, _reg, _prototypes), do: false

  # A call distributes its results from `base` upward, and how far is a
  # run-time property of the callee.
  defp window_writes?({:call, base, _args, _results, _hint}, reg), do: reg >= base
  defp window_writes?(instr, reg), do: writes?(instr, reg)

  defp fetch_arith_k(:add), do: {:ok, :add_k}
  defp fetch_arith_k(:subtract), do: {:ok, :subtract_k}
  defp fetch_arith_k(:multiply), do: {:ok, :multiply_k}
  defp fetch_arith_k(_op), do: :error

  defp fetch_compare_k(:equal), do: {:ok, :equal_k}
  defp fetch_compare_k(:less_than), do: {:ok, :less_than_k}
  defp fetch_compare_k(:less_equal), do: {:ok, :less_equal_k}
  defp fetch_compare_k(_op), do: :error

  defp coalescible?(instr) when is_tuple(instr) and tuple_size(instr) > 1 do
    :erlang.element(1, instr) in @coalescible and is_integer(:erlang.element(2, instr))
  end

  defp coalescible?(_instr), do: false

  # ── Liveness ────────────────────────────────────────────────────────────

  # True when nothing that can execute after the rewrite site observes the
  # current contents of `reg`.
  #
  # `future` is the enclosing blocks' remaining instructions, innermost
  # first. Each list is scanned in order: a read of `reg` settles the
  # question, an unconditional straight-line write to `reg` kills the value
  # and ends the search, and anything else moves on. Running off the end of
  # the outermost list means the frame is gone, which is the strongest form
  # of dead.
  #
  # Conditional writes (a write nested inside a branch or loop body) do not
  # kill: the scan just keeps going, which can only under-report deadness.
  # A `break` reached before the killing write does suppress it, though —
  # the value would survive the block on that path and reach code the outer
  # lists cover.
  defp dead?(_reg, [], _prototypes), do: true

  defp dead?(reg, [instructions | outer], prototypes) do
    case scan(instructions, reg, prototypes, false) do
      :read -> false
      :killed -> true
      :through -> dead?(reg, outer, prototypes)
    end
  end

  defp scan([], _reg, _prototypes, _escaped), do: :through

  defp scan([instr | rest], reg, prototypes, escaped) do
    cond do
      reads?(instr, reg, prototypes) -> :read
      writes?(instr, reg) and not escaped -> :killed
      writes?(instr, reg) -> :through
      true -> scan(rest, reg, prototypes, escaped or breaks?(instr))
    end
  end

  # A `break` in the block (or in a nested branch of it) can leave before a
  # later write kills `reg`, so the value escapes to the enclosing block.
  # A `break` inside a nested *loop* leaves that loop, not this block.
  defp breaks?(:break), do: true
  defp breaks?({:while_loop, _cond_body, _reg, _body}), do: false
  defp breaks?({:repeat_loop, _body, _cond_body, _reg}), do: false
  defp breaks?({:numeric_for, _base, _loop_var, _body}), do: false
  defp breaks?({:generic_for, _base, _var_regs, _body}), do: false
  defp breaks?(instr), do: Enum.any?(bodies(instr), fn body -> Enum.any?(body, &breaks?/1) end)

  # True when `instr` unconditionally overwrites `reg` on every path through
  # it, discarding whatever was there. Anything with a nested body, and
  # anything whose written range is only known at run time (`:call`,
  # `:vararg`), answers false — the scan then simply continues.
  defp writes?({:load_nil, dest, count}, reg), do: reg >= dest and reg <= dest + count
  defp writes?({:self, base, _object, _name, _hint}, reg), do: reg === base or reg === base + 1
  defp writes?({:load_constant, dest, _value}, reg), do: dest === reg
  defp writes?({:load_boolean, dest, _value}, reg), do: dest === reg
  defp writes?({:load_env, dest}, reg), do: dest === reg
  defp writes?({:move, dest, _source}, reg), do: dest === reg
  defp writes?({:get_upvalue, dest, _index}, reg), do: dest === reg
  defp writes?({:get_open_upvalue, dest, _source}, reg), do: dest === reg
  defp writes?({:get_global, dest, _name}, reg), do: dest === reg
  defp writes?({:new_table, dest, _array, _hash}, reg), do: dest === reg
  defp writes?({:get_table, dest, _table, _key, _hint}, reg), do: dest === reg
  defp writes?({:get_field, dest, _table, _name, _hint}, reg), do: dest === reg
  defp writes?({:get_field_upvalue, dest, _index, _name, _hint}, reg), do: dest === reg
  defp writes?({:closure, dest, _index}, reg), do: dest === reg
  defp writes?({:length, dest, _source}, reg), do: dest === reg
  defp writes?({:not, dest, _source}, reg), do: dest === reg
  defp writes?({:negate, dest, _source, _hint}, reg), do: dest === reg
  defp writes?({:bitwise_not, dest, _source, _hint}, reg), do: dest === reg
  defp writes?({:concatenate, dest, _a, _b}, reg), do: dest === reg
  defp writes?({op, dest, _a, _b, _hint_a, _hint_b}, reg) when op in @binary_ops, do: dest === reg
  defp writes?({op, dest, _a, _constant, _hint_a}, reg) when op in @arith_k_ops, do: dest === reg
  defp writes?({op, dest, _a, _b}, reg) when op in @compare_ops, do: dest === reg
  defp writes?({op, dest, _a, _constant}, reg) when op in @compare_k_ops, do: dest === reg
  defp writes?(_instr, _reg), do: false

  defp any_reads?(instructions, reg, prototypes) do
    Enum.any?(instructions, &reads?(&1, reg, prototypes))
  end

  # True when executing `instr` can observe the current contents of `reg`.
  #
  # The clauses with a literal opcode in position 1 must precede the guarded
  # catch-alls for the arithmetic and comparison families, which match on
  # arity alone.
  defp reads?({:load_constant, _dest, _value}, _reg, _protos), do: false
  defp reads?({:load_boolean, _dest, _value}, _reg, _protos), do: false
  defp reads?({:load_nil, _dest, _count}, _reg, _protos), do: false
  defp reads?({:load_env, _dest}, _reg, _protos), do: false
  defp reads?({:move, _dest, source}, reg, _protos), do: source === reg
  defp reads?({:get_upvalue, _dest, _index}, _reg, _protos), do: false
  defp reads?({:set_upvalue, _index, source}, reg, _protos), do: source === reg
  defp reads?({:get_open_upvalue, _dest, source}, reg, _protos), do: source === reg
  defp reads?({:set_open_upvalue, cell_reg, source}, reg, _protos), do: cell_reg === reg or source === reg
  defp reads?({:get_global, _dest, _name}, _reg, _protos), do: false
  defp reads?({:new_table, _dest, _array, _hash}, _reg, _protos), do: false
  defp reads?({:get_table, _dest, table, key, _hint}, reg, _protos), do: table === reg or key === reg
  defp reads?({:set_table, table, key, value, _hint}, reg, _protos), do: table === reg or key === reg or value === reg

  defp reads?({:get_field, _dest, table, _name, _hint}, reg, _protos), do: table === reg
  defp reads?({:set_field, table, _name, value, _hint}, reg, _protos), do: table === reg or value === reg
  defp reads?({:get_field_upvalue, _dest, _index, _name, _hint}, _reg, _protos), do: false
  defp reads?({:set_field_upvalue, _index, _name, value, _hint}, reg, _protos), do: value === reg

  defp reads?({:set_list, table, start, count, _offset}, reg, _protos) when is_integer(count),
    do: table === reg or (reg >= start and reg < start + count)

  defp reads?({:set_list, table, start, _multi, _offset}, reg, _protos), do: table === reg or reg >= start

  defp reads?({:length, _dest, source}, reg, _protos), do: source === reg
  defp reads?({:not, _dest, source}, reg, _protos), do: source === reg
  defp reads?({:negate, _dest, source, _hint}, reg, _protos), do: source === reg
  defp reads?({:bitwise_not, _dest, source, _hint}, reg, _protos), do: source === reg
  defp reads?({:concatenate, _dest, a, b}, reg, _protos), do: a === reg or b === reg
  defp reads?({:self, _base, object, _name, _hint}, reg, _protos), do: object === reg
  defp reads?({:vararg, _base, _count}, _reg, _protos), do: false
  defp reads?({:source_line, _line, _file}, _reg, _protos), do: false
  defp reads?({:return_vararg}, _reg, _protos), do: false
  defp reads?(:break, _reg, _protos), do: false

  # `close_upvalues` filters the frame's open-cell map by register index; it
  # never touches the register file.
  defp reads?({:close_upvalues, _threshold}, _reg, _protos), do: false

  # A closure reads every parent register its child prototype captures.
  defp reads?({:closure, _dest, index}, reg, prototypes), do: captures?(prototypes, index, reg)

  defp reads?({:call, base, arg_count, _results, _hint}, reg, _protos) when is_integer(arg_count) and arg_count >= 0,
    do: reg >= base and reg <= base + arg_count

  defp reads?({:call, base, _arg_count, _results, _hint}, reg, _protos), do: reg >= base

  defp reads?({:return, base, count}, reg, _protos) when is_integer(count) and count > 0,
    do: reg >= base and reg < base + count

  defp reads?({:return, _base, 0}, _reg, _protos), do: false
  defp reads?({:return, base, _count}, reg, _protos), do: reg >= base

  defp reads?({:test, test_reg, then_body, else_body}, reg, protos),
    do: test_reg === reg or any_reads?(then_body, reg, protos) or any_reads?(else_body, reg, protos)

  defp reads?({:test_and, _dest, source, body}, reg, protos), do: source === reg or any_reads?(body, reg, protos)

  defp reads?({:test_or, _dest, source, body}, reg, protos), do: source === reg or any_reads?(body, reg, protos)

  defp reads?({:while_loop, cond_body, test_reg, body}, reg, protos),
    do: test_reg === reg or any_reads?(cond_body, reg, protos) or any_reads?(body, reg, protos)

  defp reads?({:repeat_loop, body, cond_body, test_reg}, reg, protos),
    do: test_reg === reg or any_reads?(body, reg, protos) or any_reads?(cond_body, reg, protos)

  # The numeric/generic `for` header occupies `base..base + 2` (initial
  # value, limit, step / iterator, state, control).
  defp reads?({:numeric_for, base, _loop_var, body}, reg, protos),
    do: (reg >= base and reg <= base + 2) or any_reads?(body, reg, protos)

  defp reads?({:generic_for, base, _var_regs, body}, reg, protos),
    do: (reg >= base and reg <= base + 2) or any_reads?(body, reg, protos)

  defp reads?({op, _dest, a, b, _hint_a, _hint_b}, reg, _protos) when op in @binary_ops, do: a === reg or b === reg

  defp reads?({op, _dest, a, _constant, _hint_a}, reg, _protos) when op in @arith_k_ops, do: a === reg

  defp reads?({op, _dest, a, b}, reg, _protos) when op in @compare_ops, do: a === reg or b === reg

  defp reads?({op, _dest, a, _constant}, reg, _protos) when op in @compare_k_ops, do: a === reg

  # Unrecognised shape — including `:goto` / `:label`, which only reach here
  # via the register-extent scan. Assume it observes everything.
  defp reads?(_instr, _reg, _protos), do: true

  defp captures?(prototypes, index, reg) do
    case Enum.at(prototypes, index) do
      %Prototype{upvalue_descriptors: descriptors} ->
        Enum.any?(descriptors, fn
          {:parent_local, parent_reg, _name} -> parent_reg === reg
          _descriptor -> false
        end)

      _missing ->
        true
    end
  end

  # ── Register file ───────────────────────────────────────────────────────
  #
  # Move elision removes the highest-numbered temporaries first, so the
  # rewritten stream usually needs a narrower register tuple — and every
  # call frame allocates and every `setelement` copies that tuple, so the
  # narrowing is worth as much as the dropped dispatches.
  #
  # The new bound is `Codegen.instruction_peak/1` (every statically-fixed
  # destination) widened to cover every register still *read*, then clamped
  # to the incoming value. Probing `reads?/3` per register reuses the same
  # table the rewrites are gated on rather than duplicating it, and its
  # "reads everything" default makes an unmodelled opcode pin the bound at
  # the incoming value instead of shrinking it.

  defp recompute_max_registers(proto, instructions, prototypes) do
    peak = Codegen.instruction_peak(instructions)
    reads = highest_read(instructions, prototypes, proto.max_registers)

    min(proto.max_registers, Enum.max([proto.param_count, peak, reads]))
  end

  defp highest_read(instructions, prototypes, limit) do
    Enum.reduce(0..(limit - 1)//1, 0, fn reg, acc ->
      if any_reads?(instructions, reg, prototypes), do: reg + 1, else: acc
    end)
  end

  # ── Nested bodies ───────────────────────────────────────────────────────

  defp bodies({:test, _reg, then_body, else_body}), do: [then_body, else_body]
  defp bodies({:test_and, _dest, _source, body}), do: [body]
  defp bodies({:test_or, _dest, _source, body}), do: [body]
  defp bodies({:while_loop, cond_body, _reg, body}), do: [cond_body, body]
  defp bodies({:repeat_loop, body, cond_body, _reg}), do: [body, cond_body]
  defp bodies({:numeric_for, _base, _loop_var, body}), do: [body]
  defp bodies({:generic_for, _base, _var_regs, body}), do: [body]
  defp bodies(_instr), do: []

  defp put_bodies({:test, reg, _then_body, _else_body}, [then_body, else_body]), do: {:test, reg, then_body, else_body}

  defp put_bodies({:test_and, dest, source, _body}, [body]), do: {:test_and, dest, source, body}
  defp put_bodies({:test_or, dest, source, _body}, [body]), do: {:test_or, dest, source, body}

  defp put_bodies({:while_loop, _cond_body, reg, _body}, [cond_body, body]), do: {:while_loop, cond_body, reg, body}

  defp put_bodies({:repeat_loop, _body, _cond_body, reg}, [body, cond_body]), do: {:repeat_loop, body, cond_body, reg}

  defp put_bodies({:numeric_for, base, loop_var, _body}, [body]), do: {:numeric_for, base, loop_var, body}

  defp put_bodies({:generic_for, base, var_regs, _body}, [body]), do: {:generic_for, base, var_regs, body}

  defp put_bodies(instr, []), do: instr

  defp map_bodies(instr, fun) do
    case bodies(instr) do
      [] -> instr
      list -> put_bodies(instr, Enum.map(list, fun))
    end
  end

  # ── Whole-function predicates ───────────────────────────────────────────

  defp contains_closure?(instructions), do: Enum.any?(instructions, &closure?/1)

  defp closure?({:closure, _dest, _index}), do: true
  defp closure?(instr), do: Enum.any?(bodies(instr), &contains_closure?/1)

  defp contains_goto?(instructions), do: Enum.any?(instructions, &goto?/1)

  defp goto?({:goto, _name, _block_path}), do: true
  defp goto?({:label, _name, _level, _block_path}), do: true
  defp goto?(instr), do: Enum.any?(bodies(instr), &contains_goto?/1)
end
