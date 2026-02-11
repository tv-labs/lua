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

  # Table operations
  def new_table(dest, array_hint \\ 0, hash_hint \\ 0), do: {:new_table, dest, array_hint, hash_hint}

  def get_table(dest, table, key), do: {:get_table, dest, table, key}
  def set_table(table, key, value), do: {:set_table, table, key, value}
  def get_field(dest, table, name), do: {:get_field, dest, table, name}
  def set_field(table, name, value), do: {:set_field, table, name, value}
  def set_list(table, start, count, offset), do: {:set_list, table, start, count, offset}

  # Arithmetic
  def add(dest, a, b), do: {:add, dest, a, b}
  def subtract(dest, a, b), do: {:subtract, dest, a, b}
  def multiply(dest, a, b), do: {:multiply, dest, a, b}
  def divide(dest, a, b), do: {:divide, dest, a, b}
  def floor_divide(dest, a, b), do: {:floor_divide, dest, a, b}
  def modulo(dest, a, b), do: {:modulo, dest, a, b}
  def power(dest, a, b), do: {:power, dest, a, b}
  def negate(dest, source), do: {:negate, dest, source}
  def concatenate(dest, a, b), do: {:concatenate, dest, a, b}

  # Bitwise
  def bitwise_and(dest, a, b), do: {:bitwise_and, dest, a, b}
  def bitwise_or(dest, a, b), do: {:bitwise_or, dest, a, b}
  def bitwise_xor(dest, a, b), do: {:bitwise_xor, dest, a, b}
  def shift_left(dest, a, b), do: {:shift_left, dest, a, b}
  def shift_right(dest, a, b), do: {:shift_right, dest, a, b}
  def bitwise_not(dest, source), do: {:bitwise_not, dest, source}

  # Comparison
  def equal(dest, a, b), do: {:equal, dest, a, b}
  def less_than(dest, a, b), do: {:less_than, dest, a, b}
  def less_equal(dest, a, b), do: {:less_equal, dest, a, b}

  # Unary / logical
  def logical_not(dest, source), do: {:not, dest, source}
  def length(dest, source), do: {:length, dest, source}

  # Control flow
  def test(register, then_body, else_body), do: {:test, register, then_body, else_body}
  def test_true(register, then_body), do: {:test_true, register, then_body}
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
  def call(base, arg_count, result_count), do: {:call, base, arg_count, result_count}
  def tail_call(base, arg_count), do: {:tail_call, base, arg_count}
  def return_instr(base, count), do: {:return, base, count}
  def return_vararg, do: {:return_vararg}
  def self_instr(base, object, method_name), do: {:self, base, object, method_name}
  def vararg(base, count), do: {:vararg, base, count}

  # Debug
  def source_line(line, file), do: {:source_line, line, file}

  @doc """
  Creates a constant operand for use in instructions.
  """
  def constant(value), do: {:constant, value}
end
