defmodule Lua.VM.ParenAdjustTest do
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Lua 5.3 §3.4: "function calls and vararg expressions, when used
  # inside parentheses, are adjusted to one result". The four positions
  # below are the multi-value-expansion sites the VM has to opt out of
  # when the source wraps a call or vararg in parens.

  defp eval!(code) do
    assert {:ok, ast} = Parser.parse(code)
    assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  describe "parenthesised call adjusts to one value" do
    test "last RHS of multi-assign yields nils for missing slots" do
      assert [1, nil, nil] =
               eval!("""
               local function f() return 1, 2, 3 end
               local a, b, c = (f())
               return a, b, c
               """)
    end

    test "last value of `return` returns only the first result" do
      assert [1] =
               eval!("""
               local function f() return 1, 2, 3 end
               return (f())
               """)
    end

    test "last argument to a call passes only one value" do
      assert [1] =
               eval!("""
               local function f() return 1, 2, 3 end
               local function g(...) return select("#", ...) end
               return g((f()))
               """)
    end

    test "last field of a table constructor contributes one slot" do
      assert [2] =
               eval!("""
               local function f() return 1, 2, 3 end
               local t = {0, (f())}
               return #t
               """)
    end
  end

  describe "parenthesised vararg adjusts to one value" do
    test "last RHS of multi-assign yields nils for missing slots" do
      assert [10, nil, nil] =
               eval!("""
               local function v(...)
                 local a, b, c = (...)
                 return a, b, c
               end
               return v(10, 20, 30)
               """)
    end

    test "last value of `return` returns only the first vararg" do
      assert [10] =
               eval!("""
               local function v(...)
                 return (...)
               end
               return v(10, 20, 30)
               """)
    end

    test "last argument to a call passes one vararg" do
      assert [1] =
               eval!("""
               local function v(...)
                 return select("#", (...))
               end
               return v(10, 20, 30)
               """)
    end

    test "last field of a table constructor contributes one slot" do
      assert [2] =
               eval!("""
               local function v(...)
                 local t = {0, (...)}
                 return #t
               end
               return v(10, 20, 30)
               """)
    end
  end

  describe "parens around non-multi-value expressions stay transparent" do
    test "(1 + 2) * 3 still parses and evaluates to 9" do
      assert [9] = eval!("return (1 + 2) * 3")
    end

    test "((f()))(x) only forwards the first result of the inner call" do
      # The outer call is `paren(paren(f()))(x)`. The Paren wrapper around
      # `f()` forces single-result, so `paren(f())` resolves to `g`, and
      # `g(7)` returns 7 * 2 = 14.
      assert [14] =
               eval!("""
               local function g(x) return x * 2 end
               local function f() return g, "noise", "more noise" end
               return ((f()))(7)
               """)
    end
  end
end
