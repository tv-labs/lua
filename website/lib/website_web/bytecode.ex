defmodule DemoWeb.Bytecode do
  @moduledoc """
  Shared helpers for rendering register-based bytecode in HEEx templates.

  Centralises opcode colouring (`op_class/1`) and per-opcode argument
  formatting (`format_args/2`) so the home-page teaser, playground,
  tour, and opcode reference page all stay in sync.
  """

  @doc """
  Returns the Tailwind/DaisyUI class string for an opcode, used to
  colour-code the mnemonic in disassembly listings.
  """
  def op_class(:source_line), do: "text-base-content/40"

  def op_class(op) when op in [:return, :return_vararg, :tail_call],
    do: "text-accent font-semibold"

  def op_class(op) when op in [:call, :closure, :self, :vararg],
    do: "text-primary font-semibold"

  def op_class(op)
      when op in [
             :test,
             :test_true,
             :test_and,
             :test_or,
             :while_loop,
             :repeat_loop,
             :numeric_for,
             :generic_for,
             :break,
             :scope
           ],
      do: "text-warning font-semibold"

  def op_class(op)
      when op in [
             :add,
             :subtract,
             :multiply,
             :divide,
             :floor_divide,
             :modulo,
             :power,
             :concatenate,
             :negate,
             :equal,
             :less_than,
             :less_equal,
             :length,
             :not,
             :bitwise_and,
             :bitwise_or,
             :bitwise_xor,
             :shift_left,
             :shift_right,
             :bitwise_not
           ],
      do: "text-secondary font-semibold"

  def op_class(op)
      when op in [:new_table, :set_list, :get_table, :set_table, :get_field, :set_field],
      do: "text-info font-semibold"

  def op_class(_), do: "text-success font-semibold"

  @doc """
  Renders the argument list for an opcode as a human-readable string.

  Mirrors the formatting used by `Website.LuaSandbox.disassemble/1`'s
  `:pretty` field, but exposed separately so callers can colour the
  op mnemonic independently.
  """
  def format_args(op, args), do: do_format(op, args)

  defp do_format(op, [a, b, c])
       when op in [
              :add,
              :subtract,
              :multiply,
              :divide,
              :floor_divide,
              :modulo,
              :power,
              :concatenate,
              :bitwise_and,
              :bitwise_or,
              :bitwise_xor,
              :shift_left,
              :shift_right,
              :equal,
              :less_than,
              :less_equal
            ],
       do: "r#{a}, r#{b}, r#{c}"

  defp do_format(op, [a, b])
       when op in [:negate, :not, :length, :bitwise_not, :move],
       do: "r#{a}, r#{b}"

  defp do_format(:load_constant, [d, val]), do: "r#{d}, #{format_lit(val)}"
  defp do_format(:load_nil, [d, count]), do: "r#{d}, #{count}"
  defp do_format(:load_boolean, [d, v]), do: "r#{d}, #{v}"
  defp do_format(:load_env, [d]), do: "r#{d}"
  defp do_format(:get_upvalue, [d, idx]), do: "r#{d}, up[#{idx}]"
  defp do_format(:set_upvalue, [idx, s]), do: "up[#{idx}], r#{s}"
  defp do_format(:get_open_upvalue, [d, r]), do: "r#{d}, r#{r}"
  defp do_format(:set_open_upvalue, [r, s]), do: "r#{r}, r#{s}"
  defp do_format(:get_global, [d, name]), do: ~s|r#{d}, _G["#{name}"]|
  defp do_format(:set_global, [name, s]), do: ~s|_G["#{name}"], r#{s}|
  defp do_format(:new_table, [d, a, h]), do: "r#{d}, array=#{a}, hash=#{h}"
  defp do_format(:get_table, [d, t, k | _]), do: "r#{d}, r#{t}[#{format_arg(k)}]"
  defp do_format(:set_table, [t, k, v | _]), do: "r#{t}[#{format_arg(k)}], r#{v}"
  defp do_format(:get_field, [d, t, name | _]), do: ~s|r#{d}, r#{t}.#{name}|
  defp do_format(:set_field, [t, name, v | _]), do: ~s|r#{t}.#{name}, r#{v}|

  defp do_format(:set_list, [t, s, c, o]),
    do: "r#{t}, start=#{s}, count=#{c}, off=#{o}"

  defp do_format(:call, [b, ac, rc | _]),
    do: "r#{b}, args=#{count_fmt(ac)}, results=#{count_fmt(rc)}"

  defp do_format(:tail_call, [b, ac | _]), do: "r#{b}, args=#{count_fmt(ac)}"
  defp do_format(:return, [b, c]), do: "r#{b}, count=#{count_fmt(c)}"
  defp do_format(:return_vararg, _), do: "(varargs)"
  defp do_format(:vararg, [b, c]), do: "r#{b}, count=#{count_fmt(c)}"
  defp do_format(:self, [b, o, name | _]), do: "r#{b}, r#{o}, .#{name}"
  defp do_format(:closure, [d, idx]), do: "r#{d}, proto[#{idx}]"
  defp do_format(:test, [r | _]), do: "r#{r}"
  defp do_format(:test_true, [r | _]), do: "r#{r}"
  defp do_format(:test_and, [d, s | _]), do: "r#{d}, r#{s}"
  defp do_format(:test_or, [d, s | _]), do: "r#{d}, r#{s}"
  defp do_format(:numeric_for, [b | _]), do: "r#{b}"
  defp do_format(:generic_for, [b, vc | _]), do: "r#{b}, vars=#{vc}"
  defp do_format(:scope, [n | _]), do: "registers=#{n}"
  defp do_format(:source_line, [ln]), do: "line #{ln}"
  defp do_format(_, args), do: args |> Enum.map(&format_arg/1) |> Enum.join(", ")

  defp format_arg({:constant, val}), do: format_lit(val)
  defp format_arg({:global, name}), do: ~s|<#{name}>|
  defp format_arg(atom) when is_atom(atom), do: inspect(atom)
  defp format_arg(n) when is_integer(n), do: Integer.to_string(n)
  defp format_arg(other), do: inspect(other, limit: 20)

  defp format_lit(val) when is_binary(val), do: inspect(val)
  defp format_lit(val), do: inspect(val, limit: 20)

  defp count_fmt({:multi, n}), do: "multi(#{n})"
  defp count_fmt(:varargs), do: "..."
  defp count_fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp count_fmt(other), do: inspect(other)

  @doc """
  Returns a curated map of opcode → short human-readable description.

  Used by the opcode reference page and as tooltip text in the
  playground. Not exhaustive; covers the ops users will actually see
  in the playground examples.
  """
  def opcode_doc(op) do
    Map.get(opcode_docs(), op)
  end

  def opcode_docs do
    %{
      load_env: "Load the global environment table (`_ENV`) into a register.",
      load_constant: "Load a literal value (number, string, nil, bool) into a register.",
      load_nil: "Set N consecutive registers to nil.",
      load_boolean: "Load a boolean literal into a register.",
      move: "Copy one register to another.",
      get_global: "Read a global variable by name.",
      set_global: "Write a global variable by name.",
      get_upvalue: "Read a captured outer-scope binding (upvalue).",
      set_upvalue: "Write a captured outer-scope binding (upvalue).",
      get_open_upvalue:
        "Read a still-on-the-stack upvalue (set before the parent function returned).",
      set_open_upvalue: "Write an open upvalue while the parent is still live.",
      new_table: "Allocate a new table with the given array/hash pre-sizing.",
      get_table: "Read t[k] into a register.",
      set_table: "Write t[k] from a register.",
      get_field: "Read t.name (string-keyed field). Faster path than get_table.",
      set_field: "Write t.name from a register.",
      set_list: "Bulk-write a slice of registers into the array part of a table.",
      self: "Method-call shim: load t and t.name into adjacent registers for `obj:method(...)`.",
      closure: "Build a closure from a nested prototype, capturing its upvalues.",
      call: "Call a function. Args/results encoded as fixed counts, multi, or varargs.",
      tail_call: "Tail-position call. Replaces the current frame instead of pushing.",
      return: "Return zero or more values from the current function.",
      return_vararg: "Return whatever varargs the current function received.",
      vararg: "Materialise `...` into consecutive registers.",
      add: "Numeric addition.",
      subtract: "Numeric subtraction.",
      multiply: "Numeric multiplication.",
      divide: "Float division (`/`).",
      floor_divide: "Integer floor division (`//`).",
      modulo: "Modulo (`%`).",
      power: "Exponentiation (`^`).",
      negate: "Numeric negation.",
      concatenate: "String concatenation (`..`).",
      length: "`#x`: string length, array length, or `__len` metamethod.",
      not: "Logical not.",
      equal: "Equality comparison (`==`).",
      less_than: "Less-than comparison (`<`).",
      less_equal: "Less-or-equal comparison (`<=`).",
      bitwise_and: "Bitwise AND (`&`).",
      bitwise_or: "Bitwise OR (`|`).",
      bitwise_xor: "Bitwise XOR (`~` binary).",
      bitwise_not: "Bitwise NOT (`~` unary).",
      shift_left: "Bit shift left (`<<`).",
      shift_right: "Bit shift right (`>>`).",
      test: "If register is truthy, run the next continuation; else fall through.",
      test_true: "If register is truthy, fall through; else skip.",
      test_and: "Short-circuit AND: if src is falsy, copy to dest and skip; else continue.",
      test_or: "Short-circuit OR: if src is truthy, copy to dest and skip; else continue.",
      while_loop: "While-loop control: test, body, jump back.",
      repeat_loop: "Repeat-until control: body, test, jump back.",
      numeric_for: "Numeric for-loop: increments the loop variable and continues until done.",
      generic_for: "Generic for-loop over an iterator (`pairs`, `ipairs`, custom).",
      break: "Jump out of the nearest enclosing loop.",
      scope: "Allocate a new register-window for the enclosing block.",
      source_line: "Source-line marker (used for error traces and stepping)."
    }
  end
end
