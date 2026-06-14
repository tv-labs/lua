defmodule Lua.Compiler.MaxRegistersInvariantTest do
  @moduledoc """
  Pins the load-bearing invariant that `proto.reg_file_size` is large
  enough to hold every register the encoded bytecode references.

  The dispatcher sizes its register tuple to exactly `reg_file_size`, with
  no slack buffer — runtime-dynamic writes (vararg spread, multi-return
  result distribution) grow the tuple on demand instead. `reg_file_size`
  is derived from the emitted bytecode in `Lua.Compiler.Bytecode.compile/1`
  precisely so it stays correct even where codegen's own `max_registers`
  undercounts the peak. Any register index the bytecode reads or writes
  beyond `reg_file_size` would raise `:badarg` from `:erlang.element/2` or
  `:erlang.setelement/3`, so this test re-derives the peak with an
  independent walker and pins that `reg_file_size` bounds it across the
  compilable surface.

  The walker recurses into nested branch bodies (`:test`) and nested
  prototypes so the bound is checked at every level.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Prototype
  alias Lua.Parser

  # Each opcode's register operand positions in its tuple, where the
  # first element (the opcode tag) lives at position 0. Reads and writes
  # are folded together: any out-of-bounds position would crash the
  # dispatcher's `:erlang.element/2` or `:erlang.setelement/3`.
  #
  # `:load_nil` is special: it writes a *range* of registers
  # (`dest..dest + count - 1`), so the bound has to be checked against
  # the highest written index, not just `dest`.
  defp register_positions(op) do
    cond do
      op == Bytecode.op_load_constant() -> [1]
      op == Bytecode.op_load_boolean() -> [1]
      op == Bytecode.op_load_nil() -> :load_nil
      op == Bytecode.op_move() -> [1, 2]
      op == Bytecode.op_load_env() -> [1]
      op == Bytecode.op_get_upvalue() -> [1]
      op == Bytecode.op_get_global() -> [1]
      op == Bytecode.op_get_field() -> [1, 2]
      op == Bytecode.op_add() -> [1, 2, 3]
      op == Bytecode.op_subtract() -> [1, 2, 3]
      op == Bytecode.op_multiply() -> [1, 2, 3]
      op == Bytecode.op_divide() -> [1, 2, 3]
      op == Bytecode.op_floor_divide() -> [1, 2, 3]
      op == Bytecode.op_modulo() -> [1, 2, 3]
      op == Bytecode.op_power() -> [1, 2, 3]
      op == Bytecode.op_negate() -> [1, 2]
      op == Bytecode.op_less_than() -> [1, 2, 3]
      op == Bytecode.op_less_equal() -> [1, 2, 3]
      op == Bytecode.op_greater_than() -> [1, 2, 3]
      op == Bytecode.op_greater_equal() -> [1, 2, 3]
      op == Bytecode.op_equal() -> [1, 2, 3]
      op == Bytecode.op_not_equal() -> [1, 2, 3]
      op == Bytecode.op_not() -> [1, 2]
      op == Bytecode.op_test() -> [1]
      op == Bytecode.op_call_zero() -> [1]
      op == Bytecode.op_call_one() -> [1]
      op == Bytecode.op_return_one() -> [1]
      op == Bytecode.op_return_zero() -> []
      # Table opcodes (B5b-v2).
      op == Bytecode.op_new_table() -> [1]
      op == Bytecode.op_get_table() -> [1, 2, 3]
      op == Bytecode.op_set_table() -> [1, 2, 3]
      op == Bytecode.op_set_field() -> [1, 3]
      op == Bytecode.op_set_list() -> [1, 2]
      op == Bytecode.op_length() -> [1, 2]
      op == Bytecode.op_numeric_for() -> :numeric_for
      # B5c-v2 additions. Bytecode tags for closures, upvalues, varargs,
      # multi-return, loops, self, concat, break.
      op == Bytecode.op_closure() -> [1]
      op == Bytecode.op_set_upvalue() -> [2]
      op == Bytecode.op_get_open_upvalue() -> [1, 2]
      op == Bytecode.op_set_open_upvalue() -> [1, 2]
      op == Bytecode.op_vararg() -> :vararg
      op == Bytecode.op_return_proto_varargs() -> []
      op == Bytecode.op_return_collect() -> [1]
      op == Bytecode.op_return_multi() -> :return_multi
      op == Bytecode.op_call_multi() -> [1]
      op == Bytecode.op_self() -> :self
      op == Bytecode.op_concatenate() -> [1, 2, 3]
      op == Bytecode.op_break() -> []
      op == Bytecode.op_while_loop() -> :while_loop
      op == Bytecode.op_repeat_loop() -> :repeat_loop
      op == Bytecode.op_generic_for() -> :generic_for
      # close_upvalues carries a register *watermark* (the pre-block
      # next_register), not a register operand it reads or writes. The
      # watermark can equal max_registers (one past the last live slot), so
      # it must not count toward the max-register bound.
      op == Bytecode.op_close_upvalues() -> []
      # Bitwise opcodes: {tag, dest, a, b, hint_a, hint_b} read a/b and
      # write dest. `bitwise_not` is unary: {tag, dest, src, hint}.
      op == Bytecode.op_bitwise_and() -> [1, 2, 3]
      op == Bytecode.op_bitwise_or() -> [1, 2, 3]
      op == Bytecode.op_bitwise_xor() -> [1, 2, 3]
      op == Bytecode.op_shift_left() -> [1, 2, 3]
      op == Bytecode.op_shift_right() -> [1, 2, 3]
      op == Bytecode.op_bitwise_not() -> [1, 2]
      # set_list_multi: {tag, table_reg, start, init_count, offset}. The
      # multi-return values occupy start..top at runtime, but the only
      # syntactic register operands are table_reg and the start slot.
      op == Bytecode.op_set_list_multi() -> [1, 2]
      true -> raise "register_positions/1 is missing a case for opcode #{inspect(op)}"
    end
  end

  defp max_register_used(bytecode) when is_tuple(bytecode) do
    bytecode
    |> Tuple.to_list()
    |> Enum.reduce(-1, fn instr, acc -> max(acc, max_in_instr(instr)) end)
  end

  defp max_in_instr(instr) do
    op = :erlang.element(1, instr)

    case register_positions(op) do
      :load_nil ->
        # {tag, dest, count}: writes dest..dest+count-1.
        dest = :erlang.element(2, instr)
        count = :erlang.element(3, instr)
        dest + count - 1

      :numeric_for ->
        # {tag, base, loop_var, body_bc}: reads base..base+2, writes loop_var,
        # recurses into body_bc.
        base = :erlang.element(2, instr)
        loop_var = :erlang.element(3, instr)
        body_bc = :erlang.element(4, instr)
        Enum.max([base + 2, loop_var, max_register_used(body_bc)])

      :vararg ->
        # {tag, base, count}: writes base..base+count-1 when count>0.
        # When count==0 the runtime writes all varargs starting at base,
        # but we can only bound by the syntactic count operand. Codegen
        # is responsible for sizing max_registers correctly here.
        base = :erlang.element(2, instr)
        count = :erlang.element(3, instr)
        if count == 0, do: base, else: base + count - 1

      :return_multi ->
        # {tag, base, count}: reads base..base+count-1.
        base = :erlang.element(2, instr)
        count = :erlang.element(3, instr)
        base + count - 1

      :while_loop ->
        # {tag, test_reg, cond_bc, body_bc}.
        test_reg = :erlang.element(2, instr)
        cond_bc = :erlang.element(3, instr)
        body_bc = :erlang.element(4, instr)
        Enum.max([test_reg, max_register_used(cond_bc), max_register_used(body_bc)])

      :repeat_loop ->
        # {tag, test_reg, body_bc, cond_bc}.
        test_reg = :erlang.element(2, instr)
        body_bc = :erlang.element(3, instr)
        cond_bc = :erlang.element(4, instr)
        Enum.max([test_reg, max_register_used(body_bc), max_register_used(cond_bc)])

      :generic_for ->
        # {tag, base, var_regs_tuple, body_bc}.
        base = :erlang.element(2, instr)
        var_regs_tuple = :erlang.element(3, instr)
        body_bc = :erlang.element(4, instr)
        var_max = Enum.reduce(Tuple.to_list(var_regs_tuple), -1, &max/2)
        Enum.max([base + 2, var_max, max_register_used(body_bc)])

      :self ->
        # {tag, base, obj_reg, method, hint}: reads obj_reg, writes base
        # (method) and base+1 (receiver). The base+1 write is not a syntactic
        # operand, so it must be counted explicitly — a zero-arg `obj:m()`
        # call has no later op to cover it.
        max(:erlang.element(2, instr) + 1, :erlang.element(3, instr))

      positions when is_list(positions) ->
        direct = Enum.reduce(positions, -1, fn pos, acc -> max(acc, :erlang.element(pos + 1, instr)) end)

        # `:test` carries nested bytecode tuples in positions 2 and 3 —
        # recurse so the bound is checked there too.
        if op == Bytecode.op_test() do
          then_bc = :erlang.element(3, instr)
          else_bc = :erlang.element(4, instr)
          max(direct, max(max_register_used(then_bc), max_register_used(else_bc)))
        else
          direct
        end
    end
  end

  defp walk_protos(%Prototype{} = proto) do
    own =
      case proto.bytecode do
        nil ->
          :ok

        bytecode ->
          max_used = max_register_used(bytecode)

          assert max_used < proto.reg_file_size,
                 """
                 #{proto.source} declares reg_file_size=#{proto.reg_file_size}
                 but the encoded bytecode writes/reads index #{max_used}.
                 The dispatcher sizes its register tuple to exactly
                 reg_file_size, so this would crash with :badarg.
                 """

          :ok
      end

    Enum.each(proto.prototypes, &walk_protos/1)
    own
  end

  defp compile!(src) do
    {:ok, ast} = Parser.parse(src)
    {:ok, proto} = Compiler.compile(ast, source: "invariant-test.lua")
    proto
  end

  # Each program below exercises a different shape of register allocation.
  # The set is intentionally small but representative: anything more
  # exotic that compiles should ride on these guards in the existing
  # dispatcher tests.
  @corpus [
    {"plain arithmetic", "function f(a, b) return a + b end"},
    {"comparison + branch (:test)", "function f(n) if n < 0 then return -n end return n end"},
    {"recursive call",
     """
     function fib(n)
       if n < 2 then return n end
       return fib(n - 1) + fib(n - 2)
     end
     """},
    {"deep temp chain (string.upper)",
     """
     function f(s)
       local u = string.upper(s)
       return u
     end
     """},
    {"nested upvalue capture",
     """
     local function make()
       local x = 1
       return function() return x + 1 end
     end
     return make
     """},
    {"global lookup through _ENV",
     """
     x = 99
     function f() return x end
     """},
    {"many locals exercising peak",
     """
     function f(a, b, c, d)
       local x = a + b
       local y = c + d
       local z = x * y
       return z
     end
     """},
    {"bitwise + shift + bnot",
     """
     function f(a, b)
       local x = a & b
       local y = a | b
       local z = a ~ b
       local s = a << b
       local r = a >> b
       return x + y + z + s + r + ~a
     end
     """},
    {"constructor absorbing a call tail (set_list_multi)",
     """
     function pair() return 10, 20 end
     function build()
       local t = {1, pair()}
       return t[1], t[2], t[3]
     end
     """},
    {"constructor absorbing a vararg tail (set_list_multi)",
     """
     function build(...)
       local t = {1, ...}
       return t[1], t[2], t[3]
     end
     """},
    {"constructor with a bare vararg tail (set_list_multi, init_count==0)",
     """
     function build(...)
       local t = {...}
       return t[1], t[2], t[3]
     end
     """},
    # Short-circuit compositions threaded through concat build deep
    # transient-register chains whose peak codegen's `max_registers`
    # undercounts. This shape crashed the dispatcher while it sized from
    # `max_registers` and only escaped CI because the slack buffer hid it;
    # it is the case that drove sizing from `reg_file_size` instead.
    {"short-circuit chain through concat",
     """
     function f(a, b, c)
       return "(" .. tostring(a and b) .. " and " .. tostring(b and c) .. ")"
     end
     """},
    # A zero-arg method call writes the receiver into register base+1 with no
    # later op to raise the counted peak, so `:self` must contribute base+1 to
    # the bound. Sized from the receiver's own register, this undercounts by
    # one unless `:self` is handled structurally — it crashed `obj:m()`.
    {"zero-arg method call (:self base+1)",
     """
     local function f(obj)
       return obj:m()
     end
     return f
     """}
  ]

  describe "max_registers bounds every encoded register index" do
    for {label, src} <- @corpus do
      test "#{label}" do
        proto = compile!(unquote(src))
        walk_protos(proto)
      end
    end
  end
end
