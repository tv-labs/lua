defmodule Lua.Compiler.BytecodeTest do
  @moduledoc """
  Tests for the bytecode encoder's coverage and fallback cascade.

  The encoder must accept every opcode it claims to support and reject
  every opcode it does not — without ever crashing, regardless of input
  shape. These tests pin the boundary.

  The fallback cascade also has a documented property: a child prototype
  that compiles must keep its bytecode even when the parent falls back,
  and vice versa. That independence is what lets a deeply-nested
  function body run on the dispatcher even when the chunk it lives in
  cannot.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Prototype
  alias Lua.Parser

  defp compile!(src) do
    {:ok, ast} = Parser.parse(src)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    proto
  end

  describe "supported-opcode coverage" do
    test "a pure-arithmetic function compiles to bytecode" do
      proto = compile!("function f(a, b) return a + b - 1 end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
      assert tuple_size(fn_proto.bytecode) > 0
    end

    test "single-result return with comparison compiles" do
      proto = compile!("function f(n) if n < 0 then return -n end return n end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test "recursive function with single-result calls compiles" do
      proto =
        compile!("""
        function fib(n)
          if n < 2 then return n end
          return fib(n - 1) + fib(n - 2)
        end
        """)

      [fib_proto] = proto.prototypes
      assert is_tuple(fib_proto.bytecode)
    end
  end

  describe "supported opcodes (B5c-v2)" do
    test ":closure compiles to bytecode" do
      # B5c-v2: chunks that build closures now compile end-to-end.
      proto = compile!("function f() return 1 end")
      assert is_tuple(proto.bytecode)
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":generic_for compiles" do
      proto =
        compile!("""
        function iter(t)
          local n = 0
          for _ in pairs(t) do n = n + 1 end
          return n
        end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":concatenate compiles" do
      proto = compile!("function f(a, b) return a .. b end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test "multi-return call compiles" do
      # `return f(x)` compiles as a tail-call-style multi-return (-1),
      # which routes through `:call_multi` in B5c-v2.
      proto =
        compile!("""
        function caller()
          return inner(1)
        end
        """)

      [caller_proto] = proto.prototypes
      assert is_tuple(caller_proto.bytecode)
    end

    test "while-loop compiles" do
      proto =
        compile!("""
        function f(n)
          local i = 0
          while i < n do i = i + 1 end
          return i
        end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":break inside numeric_for compiles" do
      proto =
        compile!("""
        function f(n)
          for i = 1, n do
            if i > 5 then break end
          end
          return n
        end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":vararg opcode compiles" do
      proto = compile!("function f(...) local first = ... return first end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":self method-call compiles" do
      proto =
        compile!("""
        function obj_method(obj) return obj:method(1, 2) end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test "repeat loop compiles" do
      proto =
        compile!("""
        function f(n)
          local i = 0
          repeat i = i + 1 until i >= n
          return i
        end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end
  end

  describe "fallback on unsupported opcodes" do
    test ":set_list with count == 0 falls back (interpreter's multi-return sentinel)" do
      # Current codegen never emits `{:set_list, _, _, 0, _}` from a
      # literal constructor — the interpreter treats `count == 0` as
      # "consume `state.multi_return_count` trailing values," a shape
      # only reachable through multi-return splicing. The dispatcher
      # has no `multi_return_count` plumbing, so the encoder forces
      # fallback on the literal shape to keep the divergence explicit
      # if codegen ever changes.
      proto = %Prototype{
        instructions: [{:set_list, 0, 1, 0, 0}, {:return, 0, 0}],
        max_registers: 2,
        source: "test-synthetic"
      }

      result = Bytecode.compile(proto)
      assert result.bytecode == nil
    end

    test "short-circuit and/or falls back (test_and/test_or not covered)" do
      # `:test_and` / `:test_or` carry a nested continuation body the encoder
      # does not lower yet, so a function using short-circuit `and`/`or` keeps
      # its prototype on the interpreter.
      proto = compile!("function f(a, b) return a and b or 0 end")
      [fn_proto] = proto.prototypes
      assert fn_proto.bytecode == nil
    end
  end

  describe "set_list multi-return tail" do
    test ":set_list with {:multi, _} count encodes" do
      # Produced by codegen when a constructor's last element is `f()`
      # (so it absorbs the call's full result list). The dispatcher folds
      # the static prefix with `state.multi_return_count` at run time.
      proto = %Prototype{
        instructions: [{:set_list, 0, 1, {:multi, 2}, 0}, {:return, 0, 0}],
        max_registers: 2,
        source: "test-synthetic"
      }

      result = Bytecode.compile(proto)
      assert is_tuple(result.bytecode)
      assert elem(elem(result.bytecode, 0), 0) == Bytecode.op_set_list_multi()
    end
  end

  describe "cascade independence" do
    test "child prototype compiles even when sibling falls back" do
      # `pure` is pure arithmetic (covered). `impure` uses short-circuit
      # `and`/`or` (`:test_and` / `:test_or`), which the encoder does not yet
      # cover, so it stays on the interpreter.
      proto =
        compile!("""
        function pure(a, b) return a + b end
        function impure(a, b) return a and b or 0 end
        """)

      [pure_proto, impure_proto] = proto.prototypes
      assert is_tuple(pure_proto.bytecode)
      assert impure_proto.bytecode == nil
    end

    test "deeply-nested function compiles even when its parent falls back" do
      # The outer `make` uses short-circuit `and`/`or` (fallback), but the
      # inner adder is a pure-arithmetic single-result function (compiles).
      proto =
        compile!("""
        function make(a, b)
          local guard = a and b or 0
          local function add(x, y) return x + y + guard end
          return add
        end
        """)

      [make_proto] = proto.prototypes
      [add_proto] = make_proto.prototypes

      assert make_proto.bytecode == nil
      assert is_tuple(add_proto.bytecode)
    end
  end

  describe "fully_compiled?/1 coverage guard" do
    # A representative corpus exercising every covered opcode family. Each
    # program must compile end-to-end — root chunk and every nested function —
    # so the dispatcher never silently falls back to the interpreter. The only
    # documented exception is short-circuit `and`/`or` (`:test_and` /
    # `:test_or`), asserted separately below.
    @corpus [
      {"goto forward", "local x = 1 goto skip x = 99 ::skip:: return x"},
      {"goto backward loop", "local i = 0 ::top:: i = i + 1 if i < 5 then goto top end return i"},
      {"goto continue out of if", "local s = 0 for i = 1, 5 do if i == 3 then goto c end s = s + i ::c:: end return s"},
      {"goto break out of loop", "local i = 0 while true do i = i + 1 if i == 3 then goto d end end ::d:: return i"},
      {"arithmetic", "function f(a, b) return a + b * 2 - 1 end return f(3, 4)"},
      {"comparison + branch", "function f(n) if n < 0 then return -n end return n end return f(-5)"},
      {"recursion", "function fib(n) if n < 2 then return n end return fib(n-1)+fib(n-2) end return fib(10)"},
      {"bitwise", "function f(n) return (n & 1) | (n << 2) end return f(7)"},
      {"tables + length", "local t = {1, 2, 3} t[4] = 4 return #t"},
      {"numeric for", "local s = 0 for i = 1, 10 do s = s + i end return s"},
      {"generic for", "local n = 0 for _ in pairs({a=1, b=2}) do n = n + 1 end return n"},
      {"while loop", "local i = 0 while i < 5 do i = i + 1 end return i"},
      {"repeat loop", "local i = 0 repeat i = i + 1 until i >= 5 return i"},
      {"break", "local i = 0 while true do i = i + 1 if i == 3 then break end end return i"},
      {"closures + upvalues",
       "local function counter() local n = 0 return function() n = n + 1 return n end end local c = counter() c() return c()"},
      {"varargs + multi-return", "local function f(...) return ... end return f(1, 2, 3)"},
      {"method call (self)", "local t = {v = 10} function t:get() return self.v end return t:get()"},
      {"string concat", ~s{local function f(a, b) return a .. b end return f("x", "y")}}
    ]

    for {label, src} <- @corpus do
      test "compiles fully: #{label}" do
        assert Bytecode.fully_compiled?(compile!(unquote(src)))
      end
    end

    test "short-circuit and/or is the remaining documented exception" do
      # `:test_and` / `:test_or` (short-circuit `and`/`or`) are the only
      # opcodes current codegen emits that the dispatcher does not yet cover,
      # so a function using them still falls back to the interpreter. (goto /
      # label are now covered — see the corpus above.)
      refute Bytecode.fully_compiled?(compile!("local function f(a, b) return a and b or 0 end return f(1, 2)"))
    end
  end

  describe "bitwise coverage" do
    test "a whole function using `n & 1` compiles end-to-end" do
      proto =
        compile!("""
        function odd(n) return n & 1 end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test "every bitwise op encodes (band/bor/bxor/shl/shr/bnot)" do
      proto =
        compile!("""
        function f(a, b)
          return (a & b) | (a ~ b) | (a << b) | (a >> b) | (~a)
        end
        """)

      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end
  end

  describe "edge cases" do
    test "an empty function body compiles" do
      # Empty body codegen emits `{:return, 0, 0}` which is the
      # zero-result form. Encoded as `@op_return_zero`.
      proto = compile!("function f() end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test "source_line opcodes are stripped from the encoding" do
      proto =
        compile!("""
        function f(a, b)
          return a + b
        end
        """)

      [fn_proto] = proto.prototypes
      # The instruction stream still has source_line entries (kept for
      # the interpreter's error reporting); the bytecode tuple skips
      # them entirely.
      assert Enum.any?(fn_proto.instructions, &match?({:source_line, _, _}, &1))

      bytecode_ops = fn_proto.bytecode |> Tuple.to_list() |> Enum.map(&elem(&1, 0))
      source_line_tag = Bytecode.op_source_line()
      refute source_line_tag in bytecode_ops
    end

    test "fallback returns a Prototype with bytecode: nil, never an error" do
      # The encoder must not crash on any well-formed prototype. Short-circuit
      # `and`/`or` (`:test_and` / `:test_or`) stays on the interpreter, so use
      # it to exercise the fallback path.
      proto =
        compile!("""
        function f(a, b)
          return a and b or 0
        end
        """)

      [fn_proto] = proto.prototypes
      assert %Prototype{} = fn_proto
      assert fn_proto.bytecode == nil
    end
  end

  describe "call opcodes carry the source line" do
    test "@op_call_one bakes the line of the call site into its tuple" do
      # `pairs(x)` is a `:call` with result_count > 0 used as an rvalue,
      # encoding to either @op_call_one (when used for one result) or
      # @op_call_multi (when generic_for asks for 3 results). Both shapes
      # MUST include the line.
      proto =
        compile!("""
        function f()
          local x = pairs({1})
        end
        """)

      [fn_proto] = proto.prototypes

      call_ops =
        fn_proto.bytecode
        |> Tuple.to_list()
        |> Enum.filter(fn op ->
          tag = :erlang.element(1, op)
          tag in [Bytecode.op_call_one(), Bytecode.op_call_zero(), Bytecode.op_call_multi()]
        end)

      # Every call opcode carries a positive source line at its last slot.
      for op <- call_ops do
        last = :erlang.element(tuple_size(op), op)

        assert is_integer(last) and last > 0,
               "call opcode #{inspect(op)} should end with a line number, got #{inspect(last)}"
      end
    end

    test "calls in nested bodies carry their own line, not the outer one" do
      # The `print` call lives inside the `for`-body. Its line must be 3,
      # not the line of the outer `pairs(...)` call (which is line 2).
      proto =
        compile!("""
        function f()
          for i in pairs({1}) do
            print(i)
          end
        end
        """)

      [fn_proto] = proto.prototypes

      # The outer body has the pairs call (call_multi, line 2).
      outer_lines =
        fn_proto.bytecode
        |> Tuple.to_list()
        |> Enum.filter(fn op -> :erlang.element(1, op) == Bytecode.op_call_multi() end)
        |> Enum.map(fn op -> :erlang.element(tuple_size(op), op) end)

      assert outer_lines == [2]

      # The generic_for body has the print call (call_zero, line 3).
      generic_for_op =
        fn_proto.bytecode
        |> Tuple.to_list()
        |> Enum.find(fn op -> :erlang.element(1, op) == 51 end)

      assert generic_for_op
      nested_body = :erlang.element(4, generic_for_op)

      nested_call_lines =
        nested_body
        |> Tuple.to_list()
        |> Enum.filter(fn op -> :erlang.element(1, op) == Bytecode.op_call_zero() end)
        |> Enum.map(fn op -> :erlang.element(tuple_size(op), op) end)

      assert nested_call_lines == [3]
    end
  end
end
