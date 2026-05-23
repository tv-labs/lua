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
  @op_test_true 25
  @op_call_one 26
  @op_return_one 27
  @op_return_zero 28
  @op_source_line 29

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

    case encode_list(proto.instructions, []) do
      {:ok, encoded} ->
        %{proto_with_children | bytecode: List.to_tuple(encoded)}

      :fallback ->
        proto_with_children
    end
  end

  # ── Encoding ────────────────────────────────────────────────────────────
  #
  # Walks an instruction list, accumulating opcode tuples in reverse. On
  # the first uncovered opcode, the whole list bails out as `:fallback`.

  defp encode_list([], acc), do: {:ok, Enum.reverse(acc)}

  # `:source_line` opcodes are stripped from the bytecode entirely. They
  # only feed error attribution, which is deferred to B5d-v2 for compiled
  # prototypes. Keeping them in the bytecode would cost one no-op
  # dispatch each — for fib(25), that's ~228k extra dispatch cycles
  # against zero observable benefit at this stage.
  defp encode_list([{:source_line, _, _} | rest], acc) do
    encode_list(rest, acc)
  end

  defp encode_list([instr | rest], acc) do
    case encode(instr) do
      {:ok, encoded} -> encode_list(rest, [encoded | acc])
      :fallback -> :fallback
    end
  end

  # ── Per-opcode encoding ─────────────────────────────────────────────────

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

  defp encode({:add, dest, a, b}), do: {:ok, {@op_add, dest, a, b}}
  defp encode({:subtract, dest, a, b}), do: {:ok, {@op_subtract, dest, a, b}}
  defp encode({:multiply, dest, a, b}), do: {:ok, {@op_multiply, dest, a, b}}
  defp encode({:divide, dest, a, b}), do: {:ok, {@op_divide, dest, a, b}}
  defp encode({:floor_divide, dest, a, b}), do: {:ok, {@op_floor_divide, dest, a, b}}
  defp encode({:modulo, dest, a, b}), do: {:ok, {@op_modulo, dest, a, b}}
  defp encode({:power, dest, a, b}), do: {:ok, {@op_power, dest, a, b}}
  defp encode({:negate, dest, src}), do: {:ok, {@op_negate, dest, src}}

  defp encode({:less_than, dest, a, b}), do: {:ok, {@op_less_than, dest, a, b}}
  defp encode({:less_equal, dest, a, b}), do: {:ok, {@op_less_equal, dest, a, b}}
  defp encode({:greater_than, dest, a, b}), do: {:ok, {@op_greater_than, dest, a, b}}
  defp encode({:greater_equal, dest, a, b}), do: {:ok, {@op_greater_equal, dest, a, b}}
  defp encode({:equal, dest, a, b}), do: {:ok, {@op_equal, dest, a, b}}
  defp encode({:not_equal, dest, a, b}), do: {:ok, {@op_not_equal, dest, a, b}}

  defp encode({:not, dest, src}), do: {:ok, {@op_not, dest, src}}

  # `:test` carries nested instruction lists for the then/else branches.
  # Both branches encode independently; either falling back collapses the
  # whole test (and the enclosing prototype) to interpretation. Empty
  # branches encode to an empty tuple so the dispatcher can distinguish
  # "no branch" from "fell off the end of a branch".
  defp encode({:test, reg, then_body, else_body}) do
    with {:ok, then_enc} <- encode_list(then_body, []),
         {:ok, else_enc} <- encode_list(else_body, []) do
      {:ok, {@op_test, reg, List.to_tuple(then_enc), List.to_tuple(else_enc)}}
    end
  end

  defp encode({:test_true, reg, then_body}) do
    case encode_list(then_body, []) do
      {:ok, then_enc} ->
        {:ok, {@op_test_true, reg, List.to_tuple(then_enc)}}

      :fallback ->
        :fallback
    end
  end

  # `:call` with `result_count == 1` is the dispatcher's only call form.
  # Anything else (multi-return, return-position tail calls, zero-result
  # statement calls) bails out so the interpreter's full machinery handles
  # it. The `name_hint` operand survives for error attribution.
  defp encode({:call, base, arg_count, 1, name_hint}) when is_integer(arg_count) and arg_count >= 0 do
    {:ok, {@op_call_one, base, arg_count, name_hint}}
  end

  # `:return` shapes: single-value is the hot path (every recursive return
  # in fib/factorial), zero-value falls through to the interpreter's "no
  # explicit return = nil" handling.
  defp encode({:return, base, 1}), do: {:ok, {@op_return_one, base}}
  defp encode({:return, _base, 0}), do: {:ok, {@op_return_zero}}

  # `:source_line` is preserved in the bytecode tuple but ignored at
  # execution time (line tracking for compiled prototypes is deferred to
  # B5d-v2). Stripping it would corrupt anyone reading the original
  # instructions list for debugging; keeping it in bytecode at near-zero
  # cost preserves the structural correspondence.
  defp encode({:source_line, line, file}), do: {:ok, {@op_source_line, line, file}}

  # Anything else — `:closure`, `:get_table`, `:concatenate`, loops,
  # multi-return calls, vararg, etc. — is out of scope for v2.
  defp encode(_other), do: :fallback

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
  def op_test_true, do: @op_test_true
  def op_call_one, do: @op_call_one
  def op_return_one, do: @op_return_one
  def op_return_zero, do: @op_return_zero
  def op_source_line, do: @op_source_line
end
