defmodule Lua.Compiler.InstructionSizeTest do
  @moduledoc """
  Pins `Codegen.instruction_peak/1`'s per-instruction classification.

  `instruction_peak/1` makes `max_registers` honest by reporting the highest
  statically-fixed destination register every emitted instruction writes.
  Both VM engines size their register tuple to exactly `max(max_registers,
  param_count)` with no slack buffer, so an opcode the walker fails to
  classify silently undercounts `max_registers` and crashes at runtime —
  the #312 failure class.

  The walker enumerates only the exceptions — opcodes that write a range, a
  fixed offset off a base, recurse into nested bodies, or write no register
  — and defaults everything else to "the destination is operand 1", the rule
  every ordinary value-producing opcode obeys. So a new load / arithmetic /
  comparison opcode is sized correctly with no change to the walker, and the
  default can only ever *over*-count (benign slack), never undercount into
  the #312 crash.

  This test drives a representative instruction for every opcode codegen
  emits through the walker and pins the slot count it must report. A
  destination register of 7 reserves 8 slots (indices 0..7); stores, control
  flow, and debug annotations write no register and report 0.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler.Codegen

  # {instruction, expected slot count}. Covers every tag codegen emits into a
  # prototype's instruction stream.
  #
  # Register-writing opcodes: destination is operand 1, so dest 7 → 8 slots.
  @writers [
    {{:load_constant, 7, {:constant, 1}}, 8},
    {{:load_boolean, 7, true}, 8},
    {{:move, 7, 1}, 8},
    {{:get_upvalue, 7, 0}, 8},
    {{:get_open_upvalue, 7, 1}, 8},
    {{:get_global, 7, "x"}, 8},
    {{:load_env, 7}, 8},
    {{:new_table, 7, 0, 0}, 8},
    {{:get_table, 7, 1, 2, nil}, 8},
    {{:get_field, 7, 1, "x", nil}, 8},
    {{:add, 7, 1, 2, nil, nil}, 8},
    {{:subtract, 7, 1, 2, nil, nil}, 8},
    {{:multiply, 7, 1, 2, nil, nil}, 8},
    {{:divide, 7, 1, 2, nil, nil}, 8},
    {{:floor_divide, 7, 1, 2, nil, nil}, 8},
    {{:modulo, 7, 1, 2, nil, nil}, 8},
    {{:power, 7, 1, 2, nil, nil}, 8},
    {{:negate, 7, 1, nil}, 8},
    {{:concatenate, 7, 1, 2}, 8},
    {{:bitwise_and, 7, 1, 2, nil, nil}, 8},
    {{:bitwise_or, 7, 1, 2, nil, nil}, 8},
    {{:bitwise_xor, 7, 1, 2, nil, nil}, 8},
    {{:shift_left, 7, 1, 2, nil, nil}, 8},
    {{:shift_right, 7, 1, 2, nil, nil}, 8},
    {{:bitwise_not, 7, 1, nil}, 8},
    {{:equal, 7, 1, 2}, 8},
    {{:less_than, 7, 1, 2}, 8},
    {{:less_equal, 7, 1, 2}, 8},
    {{:greater_than, 7, 1, 2}, 8},
    {{:greater_equal, 7, 1, 2}, 8},
    {{:not_equal, 7, 1, 2}, 8},
    {{:not, 7, 1}, 8},
    {{:length, 7, 1}, 8},
    {{:closure, 7, 0}, 8}
  ]

  # Structural opcodes: write a range, a fixed offset off a base, or recurse
  # into nested bodies.
  @structural [
    {{:load_nil, 5, 3}, 8},
    {{:vararg, 5, 3}, 8},
    {{:vararg, 5, 0}, 6},
    {{:self, 5, 1, "m", nil}, 7},
    {{:call, 5, 2, 1, nil}, 6},
    {{:set_list, 1, 5, 3, 0}, 8},
    {{:set_list, 1, 5, {:multi, 2}, 0}, 7},
    {{:numeric_for, 4, 7, []}, 7},
    {{:generic_for, 4, {7, 8}, []}, 7},
    {{:while_loop, [{:less_than, 7, 1, 2}], 5, []}, 8},
    {{:repeat_loop, [{:move, 7, 1}], [], 0}, 8},
    {{:test, 1, [{:move, 7, 1}], []}, 8},
    {{:test_and, 7, 1, []}, 8},
    {{:test_or, 7, 1, []}, 8}
  ]

  # Stores, control flow, and debug annotations write no fresh register.
  @non_writers [
    {:break, 0},
    {{:goto, :l1}, 0},
    {{:return, 5, 1}, 0},
    {{:return_vararg}, 0},
    {{:set_table, 1, 2, 3, nil}, 0},
    {{:set_field, 1, "x", 2, nil}, 0},
    {{:set_upvalue, 0, 3}, 0},
    {{:set_open_upvalue, 2, 3}, 0},
    {{:source_line, 10, "f.lua"}, 0},
    {{:close_upvalues, 3}, 0},
    {{:label, :l1}, 0}
  ]

  describe "instruction_peak classifies every emitted opcode" do
    for {instr, expected} <- @writers ++ @structural ++ @non_writers do
      tag = if is_tuple(instr), do: elem(instr, 0), else: instr

      test "#{inspect(tag)} reserves #{expected} slot(s)" do
        assert Codegen.instruction_peak([unquote(Macro.escape(instr))]) == unquote(expected)
      end
    end
  end

  describe "the default sizes new opcodes without maintenance" do
    test "an unlisted value-producing opcode is sized from its operand-1 destination" do
      # A future opcode of the ordinary `{tag, dest, ...}` shape needs no
      # entry in the walker: the default reserves dest + 1 slots.
      assert Codegen.instruction_peak([{:some_future_opcode, 7, 1}]) == 8
    end

    test "an instruction with no integer operand-1 destination contributes nothing" do
      assert Codegen.instruction_peak([{:some_future_marker, :not_a_register}]) == 0
      assert Codegen.instruction_peak([:some_future_atom]) == 0
    end
  end
end
