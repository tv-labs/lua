defmodule Lua.VM.MaxStepsTest do
  @moduledoc """
  Pins the `:max_steps` instruction budget: a finite budget aborts a
  non-terminating script with a catchable `"instruction budget exceeded"`
  runtime error, the budget is recoverable via `pcall`, it bounds both the
  interpreter and the compiled-dispatcher path, the budget is fresh per
  top-level evaluation (no cross-eval leak), and `:infinity` (the default)
  imposes no bound.
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.RuntimeException
  alias Lua.VM.Dispatcher
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp eval!(lua, code), do: Lua.eval!(lua, code)

  describe ":max_steps enforcement (interpreter path)" do
    test "a finite budget aborts a non-terminating while loop" do
      lua = Lua.new(max_steps: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "while true do end")
      end
    end

    test "a finite budget aborts a tight numeric-for loop" do
      lua = Lua.new(max_steps: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local s = 0 for i = 1, 1000000000 do s = s + i end return s")
      end
    end

    test "unbounded recursion is bounded by step counting at call boundaries" do
      # A finite budget far below the depth a deep recursion would reach. The
      # call-boundary increment trips before the recursion exhausts itself,
      # and the message is the budget error — distinct from the
      # `:max_call_depth` "stack overflow".
      lua = Lua.new(max_steps: 100)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local function f() return f() end f()")
      end
    end
  end

  describe ":max_steps catchability and recovery" do
    test "pcall catches the budget error and the VM keeps working afterward" do
      lua = Lua.new(max_steps: 1000)

      {[false, msg], lua} =
        eval!(lua, "return pcall(function() while true do end end)")

      assert msg =~ "instruction budget exceeded"

      # The VM is healthy after a caught budget error.
      assert {[2], _lua} = eval!(lua, "return 1 + 1")
    end
  end

  describe "budget scoping" do
    test "a loop under the budget returns normally" do
      lua = Lua.new(max_steps: 10_000)

      assert {[5050], _lua} =
               eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")
    end

    test "the budget is fresh per evaluation (no cross-eval leak)" do
      lua = Lua.new(max_steps: 5000)

      # First eval consumes ~100 iterations of budget.
      {[5050], lua} = eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")

      # A second eval on the same state gets a fresh budget — it must not
      # see the first eval's tally carried over.
      assert {[5050], _lua} =
               eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")
    end
  end

  describe "default behavior (:infinity)" do
    test "a long-but-terminating loop completes with no bound" do
      assert {[500_500], _lua} =
               Lua.eval!(Lua.new(), "local s = 0 for i = 1, 1000 do s = s + i end return s")
    end
  end

  describe "compiled-dispatcher path" do
    test "a finite budget bounds an infinite loop inside a compiled function" do
      # A `function` body compiles to a `:compiled_closure`; calling it routes
      # the loop through `Lua.VM.Dispatcher`, exercising the dispatcher's
      # back-edge counting rather than the interpreter's.
      lua = Lua.new(max_steps: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local function spin() while true do end end spin()")
      end
    end

    test "the dispatcher enforces the budget when driven directly" do
      {:ok, ast} = Parser.parse("local function spin() while true do end end return spin")
      {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = %{Stdlib.install(State.new()) | max_steps: 1000}

      # Run the chunk to obtain the compiled closure it returns, then drive
      # the dispatcher with the closure's prototype directly.
      {:ok, [closure], state} = Lua.VM.execute(proto, state)
      {:compiled_closure, callee_proto, upvalues} = closure

      assert_raise Lua.VM.RuntimeError, ~r/instruction budget exceeded/, fn ->
        Dispatcher.execute(callee_proto, [], upvalues, state)
      end
    end
  end

  describe "cross-engine mutual recursion" do
    test "the budget bounds recursion that alternates execution engines" do
      # A function whose body contains a `goto` cannot be bytecode-encoded,
      # so it stays an interpreted `:lua_closure`; a plain arithmetic body
      # compiles to a `:compiled_closure`. Pairing them in unbounded mutual
      # recursion with no loop on either side forces a hand-off between the
      # interpreter and the dispatcher on every call. The budget must span
      # those hand-offs rather than resetting at each boundary, so this
      # raises the budget error rather than recursing until `max_call_depth`
      # (which defaults to `:infinity`) or forever.
      lua = Lua.new(max_steps: 1000)

      code = """
      local pong
      -- `goto` keeps this body off the bytecode path: interpreted closure.
      local function ping(n)
        ::again::
        if n < 0 then goto again end
        return pong(n)
      end
      -- Plain body: compiles to a dispatcher closure.
      pong = function(n) return ping(n) end
      return ping(1)
      """

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, code)
      end
    end

    test "the alternating pair is genuinely split across both engines" do
      # Guards the regression test above: if a compiler change ever tagged
      # both functions into the same engine, the cross-engine assertion
      # would silently degrade into a same-engine one. Assert the split
      # holds by inspecting the closure tags the chunk produces.
      {:ok, ast} =
        Parser.parse("""
        local pong
        local function ping(n) ::again:: if n < 0 then goto again end return pong end
        pong = function(n) return ping end
        return ping, pong
        """)

      {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      {:ok, [ping, pong], _state} = Lua.VM.execute(proto, state)

      assert {:lua_closure, _, _} = ping
      assert {:compiled_closure, _, _} = pong
    end
  end

  describe ":max_steps validation" do
    test "rejects non-positive integers and non-integers" do
      assert_raise ArgumentError, ~r/:max_steps/, fn -> Lua.new(max_steps: 0) end
      assert_raise ArgumentError, ~r/:max_steps/, fn -> Lua.new(max_steps: -1) end
      assert_raise ArgumentError, ~r/:max_steps/, fn -> Lua.new(max_steps: :nope) end
    end

    test "accepts :infinity and positive integers" do
      assert %Lua{} = Lua.new(max_steps: :infinity)
      assert %Lua{} = Lua.new(max_steps: 1)
    end
  end
end
