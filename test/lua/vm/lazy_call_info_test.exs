defmodule Lua.VM.LazyCallInfoTest do
  @moduledoc """
  Guards the lazily-rebuilt `call_stack` on the executor's Lua->Lua call path.

  The executor tracks in-flight Lua frames in its `frames` argument and only
  materializes `state.call_stack` at the boundaries that read it: native-call
  dispatch (where `debug.getinfo`/`debug.traceback` read the stack LIVE during
  successful execution), the dispatcher hand-off, the `generic_for` iterator
  call, the `__call` metamethod dispatch, and error raise sites. These golden
  values were captured from the previous eager-`call_info` executor and must
  remain byte-identical.
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.RuntimeError, as: LuaRuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib
  alias Lua.VM.TypeError, as: LuaTypeError

  defp run(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    state = Stdlib.install(State.new())
    VM.execute(proto, state)
  end

  defp run!(code) do
    {:ok, results, _state} = run(code)
    results
  end

  describe "debug.getinfo reads the live executor stack" do
    test "name/namewhat/currentline for a nested Lua->Lua call chain" do
      code = """
      function outer()
        return inner()
      end
      function inner()
        local info = debug.getinfo(2, "nSl")
        return info.name, info.namewhat, info.currentline, info.source, info.what
      end
      return outer()
      """

      assert run!(code) == ["outer", "global", 0, "test.lua", "Lua"]
    end

    test "level 1 currentline" do
      code = """
      function f()
        return debug.getinfo(1, "Sl").currentline
      end
      return f()
      """

      assert run!(code) == [-1]
    end

    test "three-deep chain resolves distinct levels" do
      code = """
      function a() return b() end
      function b() return c() end
      function c()
        local l2 = debug.getinfo(2, "n").name
        local l3 = debug.getinfo(3, "n").name
        return l2, l3
      end
      return a()
      """

      assert run!(code) == ["b", "a"]
    end
  end

  describe "debug.traceback reads the live executor stack" do
    test "renders one line per active Lua frame" do
      code = """
      function outer() return inner() end
      function inner() return debug.traceback() end
      return outer()
      """

      assert run!(code) == ["stack traceback:\n\ttest.lua:0: in ?\n\ttest.lua:3: in ?"]
    end
  end

  describe "__call metamethod dispatch materializes the executor stack" do
    # The `:call` opcode's `__call` branch dispatches through `call_function/3`.
    # The enclosing executor frames are tracked lazily, so they must be
    # materialized into `state.call_stack` for the duration of the metamethod
    # call exactly like the native-dispatch and dispatcher hand-off boundaries.
    # Without it, a callback reading the stack sees a truncated traceback and a
    # `currentline` of -1 instead of the live call-site line.

    test "debug.traceback inside a __call callback sees the calling frame" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        return debug.traceback("cm")
      end})
      function p()
        return t()
      end
      return p()
      """

      assert run!(code) == ["cm\nstack traceback:\n\ttest.lua:7: in ?"]
    end

    test "debug.getinfo currentline inside a __call callback is the call site" do
      code = """
      local t = setmetatable({}, {__call = function(self)
        return debug.getinfo(2, "nl").currentline
      end})
      function p()
        return t()
      end
      return p()
      """

      assert run!(code) == [7]
    end

    test "call_stack is restored to empty after a __call dispatch" do
      code = """
      local t = setmetatable({}, {__call = function(self) return 7 end})
      local function outer() return t() end
      return outer()
      """

      assert {:ok, [7], state} = run(code)
      assert state.call_stack == []
      assert state.call_depth == 0
    end
  end

  describe "error tracebacks materialize the executor stack" do
    test "attempt to call a nil value from a nested call" do
      code = """
      function outer()
        return inner()
      end
      function inner()
        return notafunction()
      end
      return outer()
      """

      assert_raise LuaTypeError, ~r/attempt to call a nil value \(global 'notafunction'\)/, fn ->
        run(code)
      end
    end
  end

  describe "call_stack stays balanced" do
    test "is empty after a successful nested-call program" do
      code = """
      local function nested() return 42 end
      local function outer() return nested() end
      return outer()
      """

      assert {:ok, [42], state} = run(code)
      assert state.call_stack == []
    end

    test "is empty after a program that invokes a native callback mid-stack" do
      # The native `debug.getinfo` call materializes the executor frames into
      # call_stack for its duration; it must be restored afterward.
      code = """
      local function deep()
        debug.getinfo(1, "l")
        return true
      end
      local function outer() return deep() end
      return outer()
      """

      assert {:ok, [true], state} = run(code)
      assert state.call_stack == []
    end

    test "call_depth returns to zero after recursion" do
      code = """
      local fact
      fact = function(n)
        if n <= 1 then return 1 else return n * fact(n - 1) end
      end
      return fact(6)
      """

      assert {:ok, [720], state} = run(code)
      assert state.call_depth == 0
      assert state.call_stack == []
    end
  end

  describe "max_call_depth still fires off the O(1) counter" do
    test "recursion past the limit raises stack overflow" do
      code = """
      local function rec(n) return rec(n + 1) end
      return rec(0)
      """

      {:ok, ast} = Parser.parse(code)
      {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = %{Stdlib.install(State.new()) | max_call_depth: 50}

      assert_raise LuaRuntimeError, ~r/stack overflow/, fn ->
        VM.execute(proto, state)
      end
    end
  end
end
