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
      load_env:
        "Put the globals table (`_ENV`, where `print`, `math`, etc. live) into a register so later instructions can look things up in it.",
      load_constant:
        "Put a literal value — a number, string, `nil`, or boolean — into a register. Constants are baked into the bytecode at compile time.",
      load_nil: "Set a run of registers to `nil` in one shot (used when declaring locals without values).",
      load_boolean: "Put `true` or `false` into a register.",
      move: "Copy the value in one register into another. Like `local x = y`.",
      get_global: "Read a global variable (e.g. `print`) by name into a register.",
      set_global: "Write a register's value to a global variable.",
      get_upvalue:
        "Read an upvalue — a variable this function captured from the enclosing function — into a register.",
      set_upvalue: "Write a register's value back to a captured upvalue.",
      get_open_upvalue:
        "Read a captured local that's still living on the parent's stack (parent hasn't returned yet).",
      set_open_upvalue:
        "Write to a captured local that's still living on the parent's stack (parent hasn't returned yet).",
      new_table:
        "Create a fresh empty table. The compiler pre-sizes it based on how many array entries and hash keys it expects.",
      get_table: "Read `t[k]` (any key) and put the result in a register.",
      set_table: "Write a register's value to `t[k]` (any key).",
      get_field:
        "Read `t.name` — same as `get_table` but specialised for string keys. The VM uses a faster path here.",
      set_field: "Write `t.name` — fast path for string-keyed assignment.",
      set_list:
        "Bulk-populate the array part of a table. Used for table literals like `{1, 2, 3}` so the VM can write all entries in one instruction.",
      self:
        "Set up an `obj:method(args)` call. Copies `obj` into one register and `obj.method` into the next, so the call instruction can use both.",
      closure:
        "Build a closure from a nested function definition, capturing its upvalues from the surrounding scope. This is what makes `function() ... end` actually produce a callable value.",
      call:
        "Call a function. The function and its arguments must already be in consecutive registers. Returns are written back to those same registers.",
      tail_call:
        "Call a function in tail position — reuses the current function's stack frame instead of growing it. Lets recursive functions run without exhausting the stack.",
      return: "Return zero or more values from this function. Values come from a run of consecutive registers.",
      return_vararg: "Return whatever `...` arguments this function received, unchanged.",
      vararg: "Expand `...` into a run of consecutive registers so following instructions can use them.",
      add: "Compute `a + b` and write the result to a register.",
      subtract: "Compute `a - b` and write the result to a register.",
      multiply: "Compute `a * b` and write the result to a register.",
      divide: "Float division: `a / b`. Always returns a float, even for whole numbers.",
      floor_divide: "Integer floor division: `a // b`. Drops the fractional part.",
      modulo: "Compute `a % b` (remainder after floor division).",
      power: "Compute `a ^ b` (exponentiation). Always returns a float.",
      negate: "Compute `-x`.",
      concatenate: "Join two strings with `..` and write the result to a register.",
      length:
        "Compute `#x` — string length, array length of a table, or the result of the `__len` metamethod.",
      not: "Compute `not x` — flip a truthy value to `false` or a falsy one to `true`.",
      equal: "Compare `a == b` and write `true` or `false` to a register.",
      less_than: "Compare `a < b` and write the boolean result.",
      less_equal: "Compare `a <= b` and write the boolean result.",
      bitwise_and: "Compute `a & b` (bitwise AND).",
      bitwise_or: "Compute `a | b` (bitwise OR).",
      bitwise_xor: "Compute `a ~ b` (bitwise XOR — the binary `~`).",
      bitwise_not: "Compute `~x` (bitwise NOT — the unary `~`).",
      shift_left: "Compute `a << b` (left shift).",
      shift_right: "Compute `a >> b` (right shift).",
      test:
        "Branch on truthiness: if the register is truthy, execute the next continuation; otherwise skip it. Powers `if` / `elseif` / `while` conditions.",
      test_true: "Inverse of `test`: continue if truthy, skip if falsy.",
      test_and:
        "Short-circuit AND. If the source is falsy, copy it to the destination and skip the rest of the expression; otherwise keep going.",
      test_or:
        "Short-circuit OR. If the source is truthy, copy it to the destination and skip the rest; otherwise keep going.",
      while_loop: "Top of a `while` loop: test the condition, run the body, jump back.",
      repeat_loop: "Top of a `repeat … until` loop: run the body, test the condition, jump back.",
      numeric_for:
        "A `for i = start, stop, step do` loop. Steps the loop variable and continues until it passes `stop`.",
      generic_for:
        "A `for k, v in iter do` loop. Calls the iterator function on each iteration and binds its return values.",
      break: "Jump out of the nearest enclosing loop. Implements Lua's `break`.",
      scope:
        "Open a new block scope and reserve registers for its locals. Bytecode-level mirror of a `do … end` block.",
      source_line:
        "Pseudo-instruction. Marks where in your source code the next batch of instructions came from — used for line numbers in error messages and the cross-highlight in this panel."
    }
  end

  @doc """
  Compact mnemonic signature for an opcode (e.g. `"rD, rS"`). Used both
  on the opcode reference cards and inside playground tooltips.
  """
  def op_signature(op) do
    case op do
      :load_constant -> "rD, K"
      :load_nil -> "rD, N"
      :load_boolean -> "rD, bool"
      :load_env -> "rD"
      :move -> "rD, rS"
      :get_global -> "rD, name"
      :set_global -> "name, rS"
      :get_upvalue -> "rD, up[i]"
      :set_upvalue -> "up[i], rS"
      :get_open_upvalue -> "rD, rS"
      :set_open_upvalue -> "rD, rS"
      :new_table -> "rD, array, hash"
      :get_table -> "rD, rT, k"
      :set_table -> "rT, k, rV"
      :get_field -> "rD, rT, name"
      :set_field -> "rT, name, rV"
      :set_list -> "rT, start, count, off"
      :self -> "rD, rO, name"
      :closure -> "rD, proto[i]"
      :call -> "rB, argc, resc"
      :tail_call -> "rB, argc"
      :return -> "rB, count"
      :return_vararg -> "(varargs)"
      :vararg -> "rB, count"
      :test -> "rR"
      :test_true -> "rR"
      :test_and -> "rD, rS"
      :test_or -> "rD, rS"
      :numeric_for -> "rB"
      :generic_for -> "rB, vars"
      :scope -> "registers"
      :source_line -> "line"
      op when op in [:add, :subtract, :multiply, :divide, :floor_divide, :modulo, :power] -> "rD, rA, rB"
      op when op in [:concatenate, :bitwise_and, :bitwise_or, :bitwise_xor] -> "rD, rA, rB"
      op when op in [:shift_left, :shift_right] -> "rD, rA, rB"
      op when op in [:equal, :less_than, :less_equal] -> "rD, rA, rB"
      op when op in [:negate, :not, :length, :bitwise_not] -> "rD, rS"
      _ -> ""
    end
  end

  @doc """
  Map of opcode → `%{doc, signature}` ready to JSON-encode into the page
  for client-side tooltip rendering.
  """
  def opcode_tooltip_map do
    for {op, doc} <- opcode_docs(), into: %{} do
      {op, %{doc: doc, signature: op_signature(op)}}
    end
  end
end
