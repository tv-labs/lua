defmodule Lua.VM.AndOrEnginesTest do
  @moduledoc """
  Pins short-circuit `and` / `or` (Lua 5.3 §3.4.5) under both execution
  engines, and pins that functions using them are dispatcher-compiled.

  `and` returns its first operand if that operand is falsy, otherwise its
  second; `or` returns its first operand if truthy, otherwise its second.
  Only `nil` and `false` are falsy, so `0` and `""` are truthy. The right
  operand is evaluated only when the left one does not decide the result.

  Each case runs under both execution engines: the default compile path
  (closures carry bytecode and run on the dispatcher) and with bytecode
  recursively stripped (closures run on the instruction interpreter).
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp compile!(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    proto
  end

  defp run(code, engine) do
    proto =
      case engine do
        :compiled -> compile!(code)
        :interpreted -> strip_bytecode(compile!(code))
      end

    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  defp strip_bytecode(%Prototype{} = proto) do
    %{proto | bytecode: nil, prototypes: Enum.map(proto.prototypes, &strip_bytecode/1)}
  end

  # {label, source, expected results}
  @cases [
    {"value-returning and/or", "return 1 and 2, nil and 1, false and 1, 1 or 2, nil or 2, false or nil, nil or false",
     [2, nil, false, 1, 2, nil, false]},
    {"0 and empty string are truthy", ~s{return 0 and "x", "" and "y", 0 or "x", "" or "y"}, ["x", "y", 0, ""]},
    {"operands from locals",
     ~s{local a, b, c = nil, false, 3 return (a or b) or c, a and b or c, (a or c) and (b or "z"), a or b and c},
     [3, 3, "z", false]},
    {"deep nesting",
     ~s{local t, f = 1, false return ((t and f) or (f or t)) and ((nil or "a") and (f and "b" or "c")), not (t and f or nil)},
     ["c", true]},
    {"right operand side effects run only when needed",
     """
     local calls = 0
     local function bump() calls = calls + 1 return true end
     local r1 = false and bump()
     local r2 = 1 or bump()
     local r3 = nil and bump() or "fallback"
     local r4 = 0 or bump()
     local r5 = "" and bump()
     local r6 = nil or bump()
     return r1, r2, r3, r4, r5, r6, calls
     """, [false, 1, "fallback", 0, true, true, 2]},
    {"and/or inside if / elseif conditions",
     """
     local function f(x)
       if x and x > 0 or x == -1 then return "pos"
       elseif not x or x == 0 then return "none"
       else return "neg" end
     end
     return f(1), f(-1), f(nil), f(0), f(-5), f(false)
     """, ["pos", "pos", "none", "none", "neg", "none"]},
    {"and/or as a while condition", "local i, n = 0, 0 while i < 10 and n < 3 do i = i + 1 n = n + 1 end return i, n",
     [3, 3]},
    {"and/or in a repeat-until condition", "local i = 0 repeat i = i + 1 until i > 100 or i * i > 30 return i", [6]},
    {"default-argument idiom in assignments",
     """
     local function f(a, b) b = b or 10 return a and a + b end
     local t = {}
     t.x = t.x or 5
     t.x = t.x or 6
     local u
     local function g() u = u or "set" return u end
     return f(1), f(1, 2), f(nil), f(false), t.x, g(), g()
     """, [11, 3, nil, false, 5, "set", "set"]},
    {"fib written with and/or", "local function fib(n) return n < 2 and n or fib(n - 1) + fib(n - 2) end return fib(15)",
     [610]},
    {"multi-return call in an operand is truncated",
     "local function two() return 1, 2 end local t = {nil or two()} return nil or two(), #t", [1, 1]},
    {"and/or inside loops with break",
     """
     local out = {}
     for i = 1, 10 do
       local v = i % 2 == 0 and "e" or "o"
       out[#out + 1] = v
       if i >= 4 and v == "e" then break end
     end
     return table.concat(out)
     """, ["oeoe"]},
    {"closure built in the right operand",
     "local x = 5 local function f(c) return c and function() return x end or nil end return f(true)(), f(false)",
     [5, nil]},
    {"error raised in the right operand",
     """
     local ok, e = pcall(function() local x return true and x + 1 end)
     local ok2 = pcall(function() local x return false and x + 1 end)
     return ok, string.find(e, "arithmetic", 1, true) ~= nil, ok2
     """, [false, true, true]}
  ]

  for engine <- [:compiled, :interpreted] do
    @engine engine

    describe "and/or (#{engine} engine)" do
      for {label, src, expected} <- @cases do
        test label do
          assert run(unquote(src), @engine) == unquote(Macro.escape(expected))
        end
      end
    end
  end

  describe "dispatcher coverage" do
    for {label, src, _expected} <- @cases do
      test "compiles fully: #{label}" do
        assert Bytecode.fully_compiled?(compile!(unquote(src)))
      end
    end

    test "and / or encode to their own opcodes" do
      proto = compile!("local function f(a, b) return a and b or 0 end return f(1, 2)")
      assert encodes_op?(proto, Bytecode.op_test_and())
      assert encodes_op?(proto, Bytecode.op_test_or())
    end
  end

  defp encodes_op?(%Prototype{} = proto, op) do
    deep_has_op?(proto.bytecode, op) or Enum.any?(proto.prototypes, &encodes_op?(&1, op))
  end

  defp deep_has_op?(t, op) when is_tuple(t) do
    (tuple_size(t) > 0 and :erlang.element(1, t) == op) or
      Enum.any?(Tuple.to_list(t), &deep_has_op?(&1, op))
  end

  defp deep_has_op?(_other, _op), do: false
end
