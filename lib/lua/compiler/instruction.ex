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
  def get_global(dest, name), do: {:get_global, dest, name}
  def set_global(name, source), do: {:set_global, name, source}

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
  def scope(register_count, body), do: {:scope, register_count, body}

  # Functions
  def closure(dest, proto_index), do: {:closure, dest, proto_index}
  def call(base, arg_count, result_count, name_hint \\ nil), do: {:call, base, arg_count, result_count, name_hint}

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
