defmodule Lua.VM.DispatcherTest do
  @moduledoc """
  Per-opcode golden tests for `Lua.VM.Dispatcher`.

  Each test compiles a small Lua source that exercises one opcode the
  dispatcher claims to support, then asserts that:

    * The compiled prototype (or the relevant sub-prototype) actually
      received a `bytecode` encoding — confirming the bytecode compiler
      did not bail out via `:fallback`.

    * The compiled program produces the same result as a freshly
      computed reference value.

  These tests pin the dispatcher's observable contract against the
  interpreter's. Any divergence — wrong arithmetic, wrong comparison,
  missing fallback — surfaces here before it can leak into a higher-
  level test that runs against either executor opaquely.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.Dispatcher
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run!(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    {proto, results}
  end

  # Pulls out the first sub-prototype — the one wrapping a `function`
  # body the dispatcher is expected to run.
  defp first_sub(%Prototype{prototypes: [fp | _]}), do: fp

  describe "arithmetic opcodes (dispatcher-compiled body)" do
    test ":add — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a + b end
        return f(40, 2)
        """)

      assert first_sub(proto).bytecode
      assert results == [42]
    end

    test ":subtract — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a - b end
        return f(50, 8)
        """)

      assert first_sub(proto).bytecode
      assert results == [42]
    end

    test ":multiply — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a * b end
        return f(6, 7)
        """)

      assert first_sub(proto).bytecode
      assert results == [42]
    end

    test ":divide — float result" do
      {proto, results} =
        run!("""
        function f(a, b) return a / b end
        return f(10, 4)
        """)

      assert first_sub(proto).bytecode
      assert results == [2.5]
    end

    test ":floor_divide — integer result" do
      {proto, results} =
        run!("""
        function f(a, b) return a // b end
        return f(10, 4)
        """)

      assert first_sub(proto).bytecode
      assert results == [2]
    end

    test ":modulo" do
      {proto, results} =
        run!("""
        function f(a, b) return a % b end
        return f(10, 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [1]
    end

    test ":power" do
      {proto, results} =
        run!("""
        function f(a, b) return a ^ b end
        return f(2, 10)
        """)

      assert first_sub(proto).bytecode
      assert results == [1024.0]
    end

    test ":negate" do
      {proto, results} =
        run!("""
        function f(a) return -a end
        return f(7)
        """)

      assert first_sub(proto).bytecode
      assert results == [-7]
    end

    test ":add — integer wrap at int64 boundary" do
      # 2^63 - 1 + 1 wraps to -2^63 (Lua 5.3 §3.4.1).
      {proto, results} =
        run!("""
        function f(a) return a + 1 end
        return f(9223372036854775807)
        """)

      assert first_sub(proto).bytecode
      assert results == [-9_223_372_036_854_775_808]
    end
  end

  describe "comparison opcodes" do
    test ":less_than with numbers" do
      {proto, results} =
        run!("""
        function f(a, b) return a < b end
        return f(3, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [true]
    end

    test ":less_equal with numbers" do
      {proto, results} =
        run!("""
        function f(a, b) return a <= b end
        return f(5, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [true]
    end

    test ":greater_than with numbers" do
      {proto, results} =
        run!("""
        function f(a, b) return a > b end
        return f(5, 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [true]
    end

    test ":greater_equal with numbers" do
      {proto, results} =
        run!("""
        function f(a, b) return a >= b end
        return f(5, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [true]
    end

    test ":equal — number-vs-number fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a == b end
        return f(5, 5), f(5, 6)
        """)

      assert first_sub(proto).bytecode
      assert results == [true, false]
    end

    test ":not_equal" do
      {proto, results} =
        run!("""
        function f(a, b) return a ~= b end
        return f(5, 6), f(5, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [true, false]
    end

    test "string ordering uses byte comparison" do
      {proto, results} =
        run!("""
        function f(a, b) return a < b end
        return f("apple", "banana")
        """)

      assert first_sub(proto).bytecode
      assert results == [true]
    end
  end

  describe "logical opcodes" do
    test ":not on falsy and truthy values" do
      {proto, results} =
        run!("""
        function f(a) return not a end
        return f(nil), f(false), f(0), f("")
        """)

      assert first_sub(proto).bytecode
      assert results == [true, true, false, false]
    end
  end

  describe "control flow" do
    test ":test selects the then branch when condition is truthy" do
      {proto, results} =
        run!("""
        function f(n) if n > 0 then return 1 end return -1 end
        return f(5), f(-3)
        """)

      assert first_sub(proto).bytecode
      assert results == [1, -1]
    end

    test ":test with nil and false both fall through to else" do
      {proto, results} =
        run!("""
        function f(x) if x then return "truthy" else return "falsy" end end
        return f(nil), f(false), f(0)
        """)

      assert first_sub(proto).bytecode
      assert results == ["falsy", "falsy", "truthy"]
    end
  end

  describe "register movement / loads" do
    test ":load_constant + :move + :return_one" do
      {proto, results} =
        run!("""
        function f() return 42 end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [42]
    end

    test ":load_boolean" do
      {proto, results} =
        run!("""
        function f() return true, false end
        return f()
        """)

      # `return true, false` is a multi-return — encoder rejects it, so
      # the prototype falls back. Still verifies the load opcodes work
      # through the interpreter path.
      _ = proto
      assert results == [true, false]
    end
  end

  describe "calls" do
    test "single-result recursive call (:call_one + :return_one)" do
      {proto, results} =
        run!("""
        function fib(n)
          if n < 2 then return n end
          return fib(n - 1) + fib(n - 2)
        end
        return fib(10)
        """)

      assert first_sub(proto).bytecode
      assert results == [55]
    end

    test "compiled-to-native call: dispatcher hands off to Executor.call_function/3" do
      # A direct `local y = native(...)` (single-result call, no return-
      # position multi-return) compiles to bytecode and routes the
      # native callee through `Executor.call_function/3`.
      {proto, results} =
        run!("""
        function f(s)
          local upper = string.upper(s)
          return upper
        end
        return f("hi")
        """)

      assert first_sub(proto).bytecode
      assert results == ["HI"]
    end
  end

  describe "field access" do
    test ":get_field reads from _ENV (global lookup)" do
      {proto, results} =
        run!("""
        x = 99
        function f() return x end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [99]
    end

    test ":get_field returns nil for missing key with no metatable" do
      {proto, results} =
        run!("""
        function f() return missing_global end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [nil]
    end
  end

  describe "interop with interpreter" do
    test "compiled callee returns to interpreted caller correctly" do
      # The outer chunk's `:call` (multi-return into `return`) is not
      # bytecode-compilable, so it stays on the interpreter. The inner
      # `add` function compiles. This exercises the interpreter →
      # dispatcher → interpreter round-trip.
      {proto, results} =
        run!("""
        function add(a, b) return a + b end
        return add(2, 3)
        """)

      assert proto.bytecode == nil, "outer chunk should fall back"
      assert first_sub(proto).bytecode != nil, "inner fn should compile"
      assert results == [5]
    end

    test "compiled metamethod invoked through interpreter call_function" do
      {proto, results} =
        run!("""
        local mt = {__add = function(a, b) return a.v + b.v end}
        local x = setmetatable({v = 10}, mt)
        local y = setmetatable({v = 20}, mt)
        return (x + y)
        """)

      # The __add closure compiles; the chunk falls back due to
      # setmetatable/table-construction opcodes outside coverage.
      _ = proto
      assert results == [30]
    end
  end

  describe "upvalues" do
    test ":get_upvalue reads a captured local through a compiled closure" do
      # Exercises the dispatcher's :get_upvalue path end-to-end. The
      # inner `inc` body compiles; the outer closure provides the
      # cell.
      {_proto, results} =
        run!("""
        local function make()
          local x = 41
          return function() return x + 1 end
        end
        local inc = make()
        return inc()
        """)

      assert results == [42]
    end

    test ":get_upvalue returns nil for a dangling cell (parity with interpreter)" do
      # Pins the contract that the dispatcher's :get_upvalue mirrors the
      # interpreter's Map.get/2 semantics for a missing cell: nil, not a
      # :badkey raise. Compiled closures should never carry stale refs
      # in practice, but if one ever does, both executors have to
      # diverge identically.
      #
      # Built by hand because the compiler will not produce a stale ref
      # — this asserts the dispatcher's *shape*, not a reachable bug.
      proto = %Prototype{
        instructions: [
          {:get_upvalue, 0, 0},
          {:return, 0, 1}
        ],
        bytecode: {
          {Bytecode.op_get_upvalue(), 0, 0},
          {Bytecode.op_return_one(), 0}
        },
        param_count: 0,
        max_registers: 1,
        source: "test-synthetic"
      }

      # Forge a cell ref that is *not* present in state.upvalue_cells.
      dangling = make_ref()
      upvalues = {dangling}
      state = State.new()

      {results, _state} = Dispatcher.execute(proto, [], upvalues, state)
      assert results == [nil]
    end
  end
end
