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

  describe "fallback on unsupported opcodes" do
    test ":closure causes the enclosing prototype to fall back" do
      # The chunk emits `:closure` to materialize `f`, so the chunk
      # itself falls back. The nested `f` body still compiles.
      proto = compile!("function f() return 1 end")
      assert proto.bytecode == nil
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode)
    end

    test ":generic_for causes fallback" do
      # `for k, v in pairs(t)` emits `:generic_for`, which sits outside
      # the dispatcher's loop coverage (only numeric-for is wired up).
      proto =
        compile!("""
        function iter(t)
          local n = 0
          for _ in pairs(t) do n = n + 1 end
          return n
        end
        """)

      [fn_proto] = proto.prototypes
      assert fn_proto.bytecode == nil
    end

    test ":concatenate causes fallback" do
      proto = compile!("function f(a, b) return a .. b end")
      [fn_proto] = proto.prototypes
      assert fn_proto.bytecode == nil
    end

    test "multi-return call causes fallback" do
      # `return f(x)` compiles as a tail-call-style multi-return (-1),
      # which is outside dispatcher coverage.
      proto =
        compile!("""
        function caller()
          return inner(1)
        end
        """)

      [caller_proto] = proto.prototypes
      assert caller_proto.bytecode == nil
    end

    test "while-loops cause fallback" do
      # While/repeat/generic-for stay on the interpreter; only
      # numeric-for is covered by the dispatcher in B5b-v2.
      proto =
        compile!("""
        function f(n)
          local i = 0
          while i < n do i = i + 1 end
          return i
        end
        """)

      [fn_proto] = proto.prototypes
      assert fn_proto.bytecode == nil
    end

    test ":break inside numeric_for causes fallback" do
      # `:break` requires loop_exit continuation walking which the
      # dispatcher doesn't model. The whole enclosing numeric-for
      # collapses to interpretation when the body contains a break.
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
      assert fn_proto.bytecode == nil
    end

    test ":vararg opcode causes fallback" do
      # Using `...` as an expression emits a `:vararg` opcode, which is
      # out of scope. A vararg signature alone (without using `...`)
      # doesn't emit anything special and is fine.
      proto = compile!("function f(...) local first = ... return first end")
      [fn_proto] = proto.prototypes
      assert fn_proto.bytecode == nil
    end
  end

  describe "cascade independence" do
    test "child prototype compiles even when sibling falls back" do
      # `pure` is pure arithmetic (covered). `impure` returns the
      # result of a function call with all results forwarded — a
      # multi-return shape (`:call` with `result_count = -1` plus
      # `:return_vararg`) that stays outside dispatcher coverage.
      proto =
        compile!("""
        function pure(a, b) return a + b end
        function impure(t) return next(t) end
        """)

      [pure_proto, impure_proto] = proto.prototypes
      assert is_tuple(pure_proto.bytecode)
      assert impure_proto.bytecode == nil
    end

    test "deeply-nested function compiles even when its parent falls back" do
      # The outer `make` builds a table (fallback), but the inner adder
      # is a pure-arithmetic single-result function (compiles).
      proto =
        compile!("""
        function make()
          local fns = {}
          local function add(a, b) return a + b end
          return add
        end
        """)

      [make_proto] = proto.prototypes
      [add_proto] = make_proto.prototypes

      assert make_proto.bytecode == nil
      assert is_tuple(add_proto.bytecode)
    end
  end

  describe "edge cases" do
    test "an empty function body falls back gracefully (return 0 args)" do
      # Empty body codegen emits `{:return, 0, 0}` which is the
      # zero-result form. Currently encoded as `@op_return_zero`.
      proto = compile!("function f() end")
      [fn_proto] = proto.prototypes
      assert is_tuple(fn_proto.bytecode) or fn_proto.bytecode == nil
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
      # The encoder must not crash on any well-formed prototype.
      proto = compile!("function f() return coroutine.yield() end")
      [fn_proto] = proto.prototypes
      assert %Prototype{} = fn_proto
      assert fn_proto.bytecode == nil
    end
  end
end
