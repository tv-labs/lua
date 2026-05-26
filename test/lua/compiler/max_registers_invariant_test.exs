defmodule Lua.Compiler.MaxRegistersInvariantTest do
  @moduledoc """
  Pins the load-bearing invariant that `proto.max_registers` is large
  enough to hold every register the encoded bytecode references.

  The dispatcher sizes its register tuple exactly to `max_registers`
  (no `+16` safety buffer like the interpreter), so any register write
  beyond that bound raises `:badarg` from `:erlang.setelement/3`. The
  invariant is enforced by `Lua.Compiler.Codegen.record_peak/1`; this
  test pins it across the existing compilable surface so regressions
  surface in CI rather than as a runtime crash.

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
      op == Bytecode.op_call_one() -> [1]
      op == Bytecode.op_return_one() -> [1]
      op == Bytecode.op_return_zero() -> []
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

          assert max_used < proto.max_registers,
                 """
                 #{proto.source} declares max_registers=#{proto.max_registers}
                 but the encoded bytecode writes/reads index #{max_used}.
                 The dispatcher sizes its register tuple to exactly
                 max_registers, so this would crash with :badarg.
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
