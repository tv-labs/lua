defmodule Lua.Compiler.Instruction do
  @moduledoc """
  Constructor functions for Lua VM instructions.

  Our register-based instruction set. Each instruction is a tagged tuple.
  Operands are either register indices (integers) or `{:constant, value}` for inline literals.
  """

  # Data movement
  def load_constant(dest, value), do: {:load_constant, dest, value}
  def load_nil(dest, count), do: {:load_nil, dest, count}
  def load_boolean(dest, value), do: {:load_boolean, dest, value}
  def move(dest, source), do: {:move, dest, source}

  # Upvalue & global access
  def get_upvalue(dest, index), do: {:get_upvalue, dest, index}
  def set_upvalue(index, source), do: {:set_upvalue, index, source}
  def get_open_upvalue(dest, reg), do: {:get_open_upvalue, dest, reg}
  def set_open_upvalue(reg, source), do: {:set_open_upvalue, reg, source}

  # Close any open-upvalue cells whose source register is at or above
  # `threshold`. Lua 5.3 §3.4.10: locals going out of scope (block exit) must
  # have their captured cells detached from the register so subsequent
  # re-uses of those registers don't read through the stale cell.
  def close_upvalues(threshold), do: {:close_upvalues, threshold}
  def get_global(dest, name), do: {:get_global, dest, name}

  # Loads the runtime `_G` table reference into `dest`. Emitted at the start
  # of every chunk to bind `_ENV` as a chunk-level local. Plan A16 (Lua 5.3
  # `_ENV` semantics): free names compile to `_ENV.name` field access; the
  # chunk's `_ENV` is initialised here and inherited by nested functions
  # via the standard upvalue chain.
  def load_env(dest), do: {:load_env, dest}

  # Table operations
  def new_table(dest, array_hint \\ 0, hash_hint \\ 0), do: {:new_table, dest, array_hint, hash_hint}

  def get_table(dest, table, key, name_hint \\ nil), do: {:get_table, dest, table, key, name_hint}
  def set_table(table, key, value, name_hint \\ nil), do: {:set_table, table, key, value, name_hint}
  def get_field(dest, table, name, name_hint \\ nil), do: {:get_field, dest, table, name, name_hint}
  def set_field(table, name, value, name_hint \\ nil), do: {:set_field, table, name, value, name_hint}

  # Field access through an upvalue-held table, fusing a `get_upvalue` with
  # the `get_field` / `set_field` that consumes it. Every read or write of a
  # global is exactly that pair (`_ENV` is an upvalue in every function but
  # the chunk), so the fused form halves their instruction count.
  # `Lua.Compiler.Peephole` emits these; codegen never does.
  def get_field_upvalue(dest, index, name, name_hint \\ nil), do: {:get_field_upvalue, dest, index, name, name_hint}

  def set_field_upvalue(index, name, value, name_hint \\ nil), do: {:set_field_upvalue, index, name, value, name_hint}

  def set_list(table, start, count, offset), do: {:set_list, table, start, count, offset}

  # Arithmetic.
  #
  # `hint_a` / `hint_b` carry the lexical origin of each operand
  # (`{:global|:local|:upvalue|:field, name}` tuples produced by
  # `Lua.Compiler.Codegen.name_hint/2`) so the executor can render
  # PUC-Lua-style suffixes like `(field 'huge')` on type errors. `nil`
  # means "no useful name" (e.g. expression operand).
  def add(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:add, dest, a, b, hint_a, hint_b}
  def subtract(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:subtract, dest, a, b, hint_a, hint_b}
  def multiply(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:multiply, dest, a, b, hint_a, hint_b}
  def divide(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:divide, dest, a, b, hint_a, hint_b}

  def floor_divide(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:floor_divide, dest, a, b, hint_a, hint_b}

  def modulo(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:modulo, dest, a, b, hint_a, hint_b}
  def power(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:power, dest, a, b, hint_a, hint_b}
  def negate(dest, source, hint \\ nil), do: {:negate, dest, source, hint}
  def concatenate(dest, a, b), do: {:concatenate, dest, a, b}

  # Bitwise. Same hint convention as arithmetic.
  def bitwise_and(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:bitwise_and, dest, a, b, hint_a, hint_b}

  def bitwise_or(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:bitwise_or, dest, a, b, hint_a, hint_b}

  def bitwise_xor(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:bitwise_xor, dest, a, b, hint_a, hint_b}

  def shift_left(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:shift_left, dest, a, b, hint_a, hint_b}

  def shift_right(dest, a, b, hint_a \\ nil, hint_b \\ nil), do: {:shift_right, dest, a, b, hint_a, hint_b}

  def bitwise_not(dest, source, hint \\ nil), do: {:bitwise_not, dest, source, hint}

  # Comparison
  def equal(dest, a, b), do: {:equal, dest, a, b}
  def less_than(dest, a, b), do: {:less_than, dest, a, b}
  def less_equal(dest, a, b), do: {:less_equal, dest, a, b}

  # Constant-folded variants. The right operand is an inline literal rather
  # than a register, so the `load_constant` that materialised it disappears
  # along with the register it occupied. Only `hint_a` survives: the
  # constant side never carried a name hint to begin with, so error
  # rendering is unchanged. `Lua.Compiler.Peephole` emits these; codegen
  # never does.
  def add_k(dest, a, constant, hint_a \\ nil), do: {:add_k, dest, a, constant, hint_a}
  def subtract_k(dest, a, constant, hint_a \\ nil), do: {:subtract_k, dest, a, constant, hint_a}
  def multiply_k(dest, a, constant, hint_a \\ nil), do: {:multiply_k, dest, a, constant, hint_a}
  def equal_k(dest, a, constant), do: {:equal_k, dest, a, constant}
  def less_than_k(dest, a, constant), do: {:less_than_k, dest, a, constant}
  def less_equal_k(dest, a, constant), do: {:less_equal_k, dest, a, constant}

  # Unary / logical
  def logical_not(dest, source), do: {:not, dest, source}
  def length(dest, source), do: {:length, dest, source}

  # Control flow
  def test(register, then_body, else_body), do: {:test, register, then_body, else_body}
  def test_and(dest, source, rest_body), do: {:test_and, dest, source, rest_body}
  def test_or(dest, source, rest_body), do: {:test_or, dest, source, rest_body}

  def while_loop(condition_body, test_reg, loop_body), do: {:while_loop, condition_body, test_reg, loop_body}

  def repeat_loop(loop_body, condition_body, test_reg), do: {:repeat_loop, loop_body, condition_body, test_reg}

  def numeric_for(base, loop_var, body), do: {:numeric_for, base, loop_var, body}
  def generic_for(base, var_count, body), do: {:generic_for, base, var_count, body}

  def break_instr, do: :break

  # Functions
  def closure(dest, proto_index), do: {:closure, dest, proto_index}
  def call(base, arg_count, result_count, name_hint \\ nil), do: {:call, base, arg_count, result_count, name_hint}

  # A call whose callee is the prototype making it, reached through the
  # `local function` self-reference upvalue. Operands mirror `call/4` minus
  # the closure: the engines already hold the prototype and its upvalues, so
  # `base` is only the argument base and the result destination.
  # `Lua.Compiler.Peephole` emits these; codegen never does.
  def call_self(base, arg_count, result_count, name_hint \\ nil),
    do: {:call_self, base, arg_count, result_count, name_hint}

  def tail_call(base, arg_count, name_hint \\ nil), do: {:tail_call, base, arg_count, name_hint}
  def return_instr(base, count), do: {:return, base, count}
  def return_vararg, do: {:return_vararg}
  def self_instr(base, object, method_name, name_hint \\ nil), do: {:self, base, object, method_name, name_hint}
  def vararg(base, count), do: {:vararg, base, count}

  # Debug
  def source_line(line, file), do: {:source_line, line, file}

  @doc """
  Creates a constant operand for use in instructions.
  """
  def constant(value), do: {:constant, value}
end
