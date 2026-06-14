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
  alias Lua.VM.Numeric
  alias Lua.VM.State
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError

  defp run!(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    {proto, results}
  end

  # Like `run!/1` but seeds host-supplied globals before executing. Lets a
  # test inject a raw value (e.g. an integer outside int64) the way
  # `Lua.set!` / `Value.encode/2` would, since neither narrows.
  defp run_with_globals!(code, globals) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")

    state =
      Enum.reduce(globals, Stdlib.install(State.new()), fn {name, value}, acc ->
        State.set_global(acc, to_string(name), value)
      end)

    {:ok, results, _state} = VM.execute(proto, state)
    {proto, results}
  end

  # Pulls out the first sub-prototype — the one wrapping a `function`
  # body the dispatcher is expected to run.
  defp first_sub(%Prototype{prototypes: [fp | _]}), do: fp

  # True if `op` is encoded anywhere in the prototype tree rooted at
  # `proto`. Used to confirm a specific opcode reached bytecode without
  # assuming which (sub-)prototype owns it.
  defp encodes_op?(%Prototype{} = proto, op) do
    own =
      case proto.bytecode do
        nil -> false
        bc -> bc |> Tuple.to_list() |> Enum.any?(&(:erlang.element(1, &1) == op))
      end

    own or Enum.any?(proto.prototypes, &encodes_op?(&1, op))
  end

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

  describe "bitwise opcodes (dispatcher-compiled body)" do
    test ":bitwise_and — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a & b end
        return f(6, 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [2]
    end

    test ":bitwise_or — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a | b end
        return f(6, 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [7]
    end

    test ":bitwise_xor — integer fast path" do
      {proto, results} =
        run!("""
        function f(a, b) return a ~ b end
        return f(6, 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [5]
    end

    test ":bitwise_not" do
      {proto, results} =
        run!("""
        function f(a) return ~a end
        return f(0)
        """)

      assert first_sub(proto).bytecode
      assert results == [-1]
    end

    test ":shift_left" do
      {proto, results} =
        run!("""
        function f(a, b) return a << b end
        return f(1, 4)
        """)

      assert first_sub(proto).bytecode
      assert results == [16]
    end

    test ":shift_right" do
      {proto, results} =
        run!("""
        function f(a, b) return a >> b end
        return f(256, 4)
        """)

      assert first_sub(proto).bytecode
      assert results == [16]
    end

    test "negative shift count flips direction (a << -n == a >> n)" do
      {proto, results} =
        run!("""
        function f(a, b) return a << b end
        return f(256, -4)
        """)

      assert first_sub(proto).bytecode
      assert results == [16]
    end

    test "shift by >= 64 yields 0" do
      {proto, results} =
        run!("""
        function f(a, b) return a << b end
        return f(1, 64)
        """)

      assert first_sub(proto).bytecode
      assert results == [0]
    end

    test ">> is a logical (unsigned) shift on a negative operand" do
      {proto, results} =
        run!("""
        function f(a, b) return a >> b end
        return f(-1, 1)
        """)

      assert first_sub(proto).bytecode
      assert results == [9_223_372_036_854_775_807]
    end

    test "float with integer value coerces (slow path)" do
      {proto, results} =
        run!("""
        function f(a, b) return a & b end
        return f(6.0, 3.0)
        """)

      assert first_sub(proto).bytecode
      assert results == [2]
    end

    test "__band metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t, n) return t & n end
        local mt = {__band = function(_, n) return n + 100 end}
        local t = setmetatable({}, mt)
        return f(t, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [105]
    end

    test "__bor metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t, n) return t | n end
        local mt = {__bor = function(_, n) return n + 200 end}
        local t = setmetatable({}, mt)
        return f(t, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [205]
    end

    test "__bxor metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t, n) return t ~ n end
        local mt = {__bxor = function(_, n) return n + 300 end}
        local t = setmetatable({}, mt)
        return f(t, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [305]
    end

    test "__shr metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t, n) return t >> n end
        local mt = {__shr = function(_, n) return n + 7 end}
        local t = setmetatable({}, mt)
        return f(t, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [12]
    end

    test "matches the interpreter for an int64-boundary AND" do
      code = """
      function f(a, b) return a & b end
      return f(-1, 9223372036854775807)
      """

      {proto, results} = run!(code)
      assert first_sub(proto).bytecode
      assert results == [9_223_372_036_854_775_807]
    end

    test "narrows an out-of-int64 integer operand to match the interpreter" do
      # A host can inject an integer outside [-2^63, 2^63-1] via `Lua.set!`
      # (Value.encode/2 passes host ints through unnarrowed). The integer
      # fast path must still narrow its result, matching the interpreter's
      # `Numeric.to_signed_int64` wrap — otherwise it both diverges and
      # leaks an out-of-range integer back into Lua state.
      big = Bitwise.bsl(1, 64)

      for {op, mask} <- [{"&", 1}, {"|", 1}, {"~", 1}] do
        code = """
        function f(a, b) return a #{op} b end
        return f(big, #{mask})
        """

        {proto, [result]} = run_with_globals!(code, big: big)
        assert first_sub(proto).bytecode

        expected =
          case op do
            "&" -> Numeric.to_signed_int64(Bitwise.band(big, mask))
            "|" -> Numeric.to_signed_int64(Bitwise.bor(big, mask))
            "~" -> Numeric.to_signed_int64(Bitwise.bxor(big, mask))
          end

        assert result == expected
        assert result >= -Bitwise.bsl(1, 63) and result <= Bitwise.bsl(1, 63) - 1
      end
    end

    test "numeric string operand coerces (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(a, b) return a & b end
        return f("6", 3)
        """)

      assert first_sub(proto).bytecode
      assert results == [2]
    end

    test "float with a fractional part raises (no integer representation)" do
      assert_raise TypeError, ~r/no integer representation/, fn ->
        run!("""
        function f(a, b) return a & b end
        return f(3.5, 1)
        """)
      end
    end

    test "non-numeric string operand raises (bitwise on a string value)" do
      assert_raise TypeError, ~r/bitwise operation on a string/, fn ->
        run!("""
        function f(a, b) return a & b end
        return f("x", 1)
        """)
      end
    end

    test "__shl metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t, n) return t << n end
        local mt = {__shl = function(_, n) return n + 1 end}
        local t = setmetatable({}, mt)
        return f(t, 5)
        """)

      assert first_sub(proto).bytecode
      assert results == [6]
    end

    test "__bnot metamethod (slow-path bridge)" do
      {proto, results} =
        run!("""
        function f(t) return ~t end
        local mt = {__bnot = function(_) return 42 end}
        local t = setmetatable({}, mt)
        return f(t)
        """)

      assert first_sub(proto).bytecode
      assert results == [42]
    end
  end

  describe "set_list multi-return tail (dispatcher-compiled body)" do
    test "constructor absorbing a multi-return call matches the interpreter" do
      {proto, results} =
        run!("""
        function pair() return 10, 20 end
        function build()
          local t = {1, pair()}
          return t[1], t[2], t[3]
        end
        return build()
        """)

      assert encodes_op?(proto, Bytecode.op_set_list_multi())
      assert results == [1, 10, 20]
    end

    test "constructor absorbing a vararg tail matches the interpreter" do
      {proto, results} =
        run!("""
        function build(...)
          local t = {1, ...}
          return t[1], t[2], t[3]
        end
        return build(10, 20)
        """)

      assert encodes_op?(proto, Bytecode.op_set_list_multi())
      assert results == [1, 10, 20]
    end

    test "constructor with a bare vararg tail (init_count==0) matches the interpreter" do
      {proto, results} =
        run!("""
        function build(...)
          local t = {...}
          return t[1], t[2], t[3]
        end
        return build(10, 20, 30)
        """)

      assert encodes_op?(proto, Bytecode.op_set_list_multi())
      assert results == [10, 20, 30]
    end

    test "constructor with a tail call returning zero values matches the interpreter" do
      {proto, results} =
        run!("""
        function none() end
        function build()
          local t = {1, none()}
          return #t, t[1]
        end
        return build()
        """)

      assert encodes_op?(proto, Bytecode.op_set_list_multi())
      assert results == [1, 1]
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
    test "compiled callee + compiled outer chunk round-trip" do
      # After B5c-v2 the chunk's `:closure` + multi-return `:call` + tail
      # `:return_collect` all compile, so the whole program is dispatcher-
      # routed. This still exercises the dispatcher → dispatcher call
      # path; pinning correctness here guards against frame plumbing
      # regressions.
      {proto, results} =
        run!("""
        function add(a, b) return a + b end
        return add(2, 3)
        """)

      assert proto.bytecode != nil, "outer chunk should compile after B5c-v2"
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

      _ = proto
      assert results == [30]
    end
  end

  # ── B5c-v2 opcodes ────────────────────────────────────────────────────

  describe "closures + upvalues" do
    test ":closure with upvalue capture (parent_local)" do
      {proto, results} =
        run!("""
        function make_adder(x)
          return function(y) return x + y end
        end
        local f = make_adder(10)
        return f(5)
        """)

      [make_adder | _] = proto.prototypes
      [inner | _] = make_adder.prototypes
      assert is_tuple(inner.bytecode)
      assert results == [15]
    end

    test ":set_upvalue mutates a captured local" do
      # The counter pattern from the closures benchmark.
      {_proto, results} =
        run!("""
        function make_counter()
          local count = 0
          return function() count = count + 1 return count end
        end
        local c = make_counter()
        c()
        c()
        c()
        return c()
        """)

      assert results == [4]
    end

    test "deeply-nested closure cascade" do
      {_proto, results} =
        run!("""
        function outer(a)
          return function(b)
            return function(c) return a + b + c end
          end
        end
        return outer(1)(2)(3)
        """)

      assert results == [6]
    end

    test "multiple closures sharing one open upvalue" do
      {_proto, results} =
        run!("""
        function make_pair()
          local x = 0
          local function get() return x end
          local function set(v) x = v end
          set(42)
          return get()
        end
        return make_pair()
        """)

      assert results == [42]
    end
  end

  describe "vararg + multi-return" do
    test ":vararg expansion" do
      {_proto, results} =
        run!("""
        function f(...)
          return select('#', ...)
        end
        return f(1, 2, 3, 4)
        """)

      assert results == [4]
    end

    test ":return_collect (return ... )" do
      {_proto, results} =
        run!("""
        function f(...)
          return ...
        end
        return f(10, 20, 30)
        """)

      assert results == [10, 20, 30]
    end

    test "multi-return :call with -2 (table-construction-like expansion)" do
      {_proto, results} =
        run!("""
        function pair() return 1, 2 end
        function trio() local a, b = pair() return a, b, 3 end
        return trio()
        """)

      assert results == [1, 2, 3]
    end

    test "fixed-count assignment from multi-return takes first N" do
      {_proto, results} =
        run!("""
        function three() return 1, 2, 3 end
        local a, b = three()
        return a + b
        """)

      assert results == [3]
    end
  end

  describe "self + concatenate (OOP)" do
    test ":self method call via __index metatable" do
      {_proto, results} =
        run!("""
        local Greeter = {}
        Greeter.__index = Greeter
        function Greeter.new(name)
          local self = setmetatable({}, Greeter)
          self.name = name
          return self
        end
        function Greeter:hello() return "hi " .. self.name end
        local g = Greeter.new("world")
        return g:hello()
        """)

      assert results == ["hi world"]
    end

    test ":concatenate chains binaries and numbers" do
      {_proto, results} =
        run!("""
        function f(a, b) return a .. " " .. b end
        return f("hello", 42)
        """)

      assert results == ["hello 42"]
    end

    test "zero-arg method call where base+1 is the register peak" do
      # `:self` writes the receiver into register base+1. With no arguments
      # and a receiver living at a low register, base+1 is the prototype's
      # high-water mark — which the register-file sizing must account for.
      # Sized one short, `:erlang.setelement(base + 2, ...)` raised :badarg
      # once the dispatcher dropped its register-slack buffer (issue #324).
      {_proto, results} =
        run!("""
        local obj = { m = function(self) return 42 end }
        local function f(o) return o:m() end
        return f(obj)
        """)

      assert results == [42]
    end
  end

  describe "loops + break" do
    test ":while_loop with break" do
      {_proto, results} =
        run!("""
        function f(n)
          local i = 0
          while true do
            i = i + 1
            if i >= n then break end
          end
          return i
        end
        return f(7)
        """)

      assert results == [7]
    end

    test ":repeat_loop terminates on truthy condition" do
      {_proto, results} =
        run!("""
        function f(n)
          local i = 0
          repeat i = i + 1 until i >= n
          return i
        end
        return f(5)
        """)

      assert results == [5]
    end

    test ":generic_for with pairs" do
      {_proto, results} =
        run!("""
        function f(t)
          local sum = 0
          for _, v in pairs(t) do sum = sum + v end
          return sum
        end
        return f({1, 2, 3, 4})
        """)

      assert results == [10]
    end

    test ":break inside :numeric_for now compiles and runs" do
      {_proto, results} =
        run!("""
        function f(n)
          local last = 0
          for i = 1, n do
            if i > 5 then break end
            last = i
          end
          return last
        end
        return f(100)
        """)

      assert results == [5]
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
        # Hand-forged bytecode bypasses Bytecode.compile/1, so set the
        # register-file size the dispatcher allocates from (one slot for
        # register 0) explicitly.
        reg_file_size: 1,
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

  describe "table opcodes (dispatcher-compiled body)" do
    test ":new_table — empty constructor returns a fresh tref" do
      {proto, results} =
        run!("""
        function f() return {} end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert [{:tref, _id}] = results
    end

    test ":set_list — table constructor with literals" do
      {proto, results} =
        run!("""
        function f() local t = {10, 20, 30} return t[2] end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [20]
    end

    test ":length — sequence after :set_list" do
      {proto, results} =
        run!("""
        function f()
          local t = {1, 2, 3, 4}
          return \#t
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [4]
    end

    test ":length — string source" do
      {proto, results} =
        run!("""
        function f(s) return #s end
        return f("hello")
        """)

      assert first_sub(proto).bytecode
      assert results == [5]
    end

    test ":set_field then :get_field via dot notation" do
      {proto, results} =
        run!("""
        function f()
          local t = {}
          t.x = 7
          t.y = 11
          return t.x + t.y
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [18]
    end

    test ":get_table — integer-key fast path" do
      {proto, results} =
        run!("""
        function f()
          local t = {100, 200, 300}
          return t[1] + t[2] + t[3]
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [600]
    end

    test ":set_table with computed integer key" do
      {proto, results} =
        run!("""
        function f(n)
          local t = {}
          t[n] = 42
          t[n + 1] = 99
          return t[n] + t[n + 1]
        end
        return f(5)
        """)

      assert first_sub(proto).bytecode
      assert results == [141]
    end
  end

  describe "numeric_for (dispatcher-compiled body)" do
    test "sum 1..n" do
      {proto, results} =
        run!("""
        function f(n)
          local s = 0
          for i = 1, n do s = s + i end
          return s
        end
        return f(10)
        """)

      assert first_sub(proto).bytecode
      assert results == [55]
    end

    test "non-unit step" do
      {proto, results} =
        run!("""
        function f()
          local s = 0
          for i = 0, 10, 2 do s = s + i end
          return s
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      # 0+2+4+6+8+10 = 30
      assert results == [30]
    end

    test "negative step" do
      {proto, results} =
        run!("""
        function f()
          local s = 0
          for i = 10, 1, -1 do s = s + i end
          return s
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [55]
    end

    test "loop runs zero times when initial value already past limit" do
      {proto, results} =
        run!("""
        function f()
          local s = 0
          for i = 10, 1 do s = s + i end
          return s
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [0]
    end

    test "nested numeric_for" do
      {proto, results} =
        run!("""
        function f(n)
          local s = 0
          for i = 1, n do
            for j = 1, n do
              s = s + 1
            end
          end
          return s
        end
        return f(4)
        """)

      assert first_sub(proto).bytecode
      assert results == [16]
    end

    test "float-coerced controls (limit promoted to float)" do
      {proto, results} =
        run!("""
        function f()
          local s = 0
          for i = 1, 5.0 do s = s + i end
          return s
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [15.0]
    end
  end

  describe "table_ops benchmark shapes (dispatcher-compiled)" do
    # The benchmarks in `benchmarks/table_ops.exs` are the public
    # motivation for B5b-v2: they should all run on the dispatcher
    # end-to-end. Asserting that here pins the goal so a future
    # refactor can't silently regress coverage.

    setup do
      lua = Lua.new()

      {_, lua} =
        Lua.eval!(lua, """
        function run_table_build(n)
          local t = {}
          for i = 1, n do
            t[i] = i * i
          end
          return #t
        end

        function run_table_sort(n)
          local t = {}
          for i = 1, n do
            t[i] = n - i + 1
          end
          table.sort(t)
          return t[1]
        end

        function run_table_sum(n)
          local t = {}
          for i = 1, n do
            t[i] = i
          end
          local sum = 0
          for j = 1, n do
            sum = sum + t[j]
          end
          return sum
        end

        function run_table_map_reduce(n)
          local t = {}
          for i = 1, n do
            t[i] = i
          end
          local mapped = {}
          for j = 1, n do
            mapped[j] = t[j] * t[j]
          end
          local sum = 0
          for k = 1, n do
            sum = sum + mapped[k]
          end
          return sum
        end
        """)

      %{lua: lua}
    end

    test "every table_ops function is compiled (not interpreted)", %{lua: lua} do
      names = ~w(run_table_build run_table_sort run_table_sum run_table_map_reduce)

      for name <- names do
        case State.get_global(lua.state, name) do
          {:compiled_closure, _proto, _ups} ->
            :ok

          {:lua_closure, _proto, _ups} ->
            flunk("expected #{name} to be :compiled_closure, got :lua_closure")
        end
      end
    end

    test "run_table_build(10) → 10", %{lua: lua} do
      {[result], _} = Lua.eval!(lua, "return run_table_build(10)")
      assert result == 10
    end

    test "run_table_sort(10) → 1", %{lua: lua} do
      {[result], _} = Lua.eval!(lua, "return run_table_sort(10)")
      assert result == 1
    end

    test "run_table_sum(10) → 55", %{lua: lua} do
      {[result], _} = Lua.eval!(lua, "return run_table_sum(10)")
      assert result == 55
    end

    test "run_table_map_reduce(10) → 385", %{lua: lua} do
      {[result], _} = Lua.eval!(lua, "return run_table_map_reduce(10)")
      assert result == 385
    end
  end

  describe ":call_zero — statement call form" do
    test "discards results from a native function" do
      # `print` is the canonical statement-call target. Routing through
      # the dispatcher must not propagate its return values.
      {proto, results} =
        run!("""
        function f()
          local t = {3, 1, 2}
          table.sort(t)
          return t[1]
        end
        return f()
        """)

      assert first_sub(proto).bytecode
      assert results == [1]
    end
  end
end
