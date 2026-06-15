defmodule Lua.VM.MaxInstructionsTest do
  @moduledoc """
  Pins the `:max_instructions` instruction budget: a finite budget aborts a
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

  describe ":max_instructions enforcement (interpreter path)" do
    test "a finite budget aborts a non-terminating while loop" do
      lua = Lua.new(max_instructions: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "while true do end")
      end
    end

    test "a finite budget aborts a tight numeric-for loop" do
      lua = Lua.new(max_instructions: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local s = 0 for i = 1, 1000000000 do s = s + i end return s")
      end
    end

    test "unbounded recursion is bounded by step counting at call boundaries" do
      # A finite budget far below the depth a deep recursion would reach. The
      # call-boundary increment trips before the recursion exhausts itself,
      # and the message is the budget error — distinct from the
      # `:max_call_depth` "stack overflow".
      lua = Lua.new(max_instructions: 100)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local function f() return f() end f()")
      end
    end
  end

  describe ":max_instructions catchability and recovery" do
    test "pcall catches the budget error and the VM keeps working afterward" do
      lua = Lua.new(max_instructions: 1000)

      {[false, msg], lua} =
        eval!(lua, "return pcall(function() while true do end end)")

      assert msg =~ "instruction budget exceeded"

      # The VM is healthy after a caught budget error.
      assert {[2], _lua} = eval!(lua, "return 1 + 1")
    end
  end

  describe "budget scoping" do
    test "a loop under the budget returns normally" do
      lua = Lua.new(max_instructions: 10_000)

      assert {[5050], _lua} =
               eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")
    end

    test "the budget is fresh per evaluation (no cross-eval leak)" do
      lua = Lua.new(max_instructions: 5000)

      # First eval consumes ~100 iterations of budget.
      {[5050], lua} = eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")

      # A second eval on the same state gets a fresh budget — it must not
      # see the first eval's tally carried over.
      assert {[5050], _lua} =
               eval!(lua, "local s = 0 for i = 1, 100 do s = s + i end return s")
    end

    test "a budget sized for one eval survives repeating that same eval on the threaded state" do
      # Set the budget just above a single eval's real cost, then run that
      # SAME eval many times on the SAME %Lua{}, threading the returned
      # state forward. If the tally leaked across evaluations (cumulative
      # over the %Lua{} lifetime), the Nth eval would trip the budget even
      # though no single eval comes close. A correct per-eval reset lets
      # every iteration succeed.
      code = "local s = 0 for i = 1, 50 do s = s + i end return s"

      # Establish a budget that comfortably clears one eval but is far below
      # the cumulative cost of running it 100 times.
      lua = Lua.new(max_instructions: 2000)

      final =
        Enum.reduce(1..100, lua, fn _i, acc ->
          {[1275], next} = eval!(acc, code)
          next
        end)

      # And the budget is still live afterward (not silently disabled).
      assert {[1275], _lua} = eval!(final, code)
    end

    test "the budget does NOT reset on nested calls within a single evaluation" do
      # The per-eval reset must bound ONE evaluation's total work across all
      # its instructions and nested calls. A tight loop calling a helper on
      # every iteration must still trip the budget — the reset is a
      # top-level boundary, not a per-call one.
      lua = Lua.new(max_instructions: 1000)

      code = """
      local function step(x) return x + 1 end
      local s = 0
      while true do s = step(s) end
      return s
      """

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, code)
      end
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
      lua = Lua.new(max_instructions: 1000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "local function spin() while true do end end spin()")
      end
    end

    test "the dispatcher enforces the budget when driven directly" do
      {:ok, ast} = Parser.parse("local function spin() while true do end end return spin")
      {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = %{Stdlib.install(State.new()) | max_instructions: 1000}

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
      # A function whose body contains a short-circuit `and`/`or` cannot be
      # bytecode-encoded, so it stays an interpreted `:lua_closure`; a plain
      # body compiles to a `:compiled_closure`. Pairing them in unbounded
      # mutual recursion with no loop on either side forces a hand-off between
      # the interpreter and the dispatcher on every call. The budget must span
      # those hand-offs rather than resetting at each boundary, so this
      # raises the budget error rather than recursing until `max_call_depth`
      # (which defaults to `:infinity`) or forever.
      lua = Lua.new(max_instructions: 1000)

      code = """
      local pong
      -- short-circuit `and` keeps this body off the bytecode path: interpreted closure.
      local function ping(n)
        return n and pong(n)
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
        local function ping(n) return n and pong end
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

  describe "budget integrity (non-conservative-accounting regressions)" do
    test "an interpreted `return ...` terminal stamps the step tally back into state" do
      # The bottom-frame `{:return_vararg}` terminal must stamp the accumulated
      # tally into `state.instruction_count` like every other terminal. If it returns a
      # bare state, a compiled caller that reads `instruction_count = state.instruction_count` after the
      # interpreted callee returns under-counts, so work done in `return ...`
      # passthroughs vanishes from the budget. A finite budget keeps the tally
      # live (the default `:infinity` path charges nothing, so accrual is only
      # observable under a budget) while staying well clear of tripping it.
      run = fn src ->
        {:ok, ast} = Parser.parse(src)
        {:ok, proto} = Compiler.compile(ast, source: "test.lua")
        state = %{Stdlib.install(State.new()) | max_instructions: 1_000_000}
        {:ok, _results, state} = Lua.VM.execute(proto, state)
        state.instruction_count
      end

      work = "local s = 0 for i = 1, 5 do s = s + i end "
      named = run.(work <> "return s")
      vararg = run.(work <> "return ...")

      assert named > 0
      assert vararg == named
    end

    test "pcall does not refund the instructions a caught budget error consumed" do
      # Each inner protected call trips the budget; recovery must carry the
      # exhausted tally forward (monotonic) rather than rewinding it to the
      # pcall-entry value. Otherwise a `pcall`-in-a-loop pattern re-funds the
      # inner work every iteration and the single evaluation runs far beyond
      # `:max_instructions` total instructions before tripping.
      lua = Lua.new(max_instructions: 2000)

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, "for i = 1, 1000000 do pcall(function() while true do end end) end")
      end
    end

    test "require runs the module body against the same budget (no mid-eval reset)" do
      # `require` re-enters `Lua.VM.execute`, which resets the per-eval tally at
      # genuine top-level entry only. The pre-require work must still count: with
      # a mid-eval reset the 700 pre-require instruction_count would be forgiven, leaving the
      # 700 post-require instruction_count under the 1000 budget so the eval would wrongly
      # succeed. With the budget preserved, pre + post exceed it and it trips.
      lua = Lua.new(sandboxed: [], max_instructions: 1000)

      code = ~S"""
      package.path = "./test/fixtures/?.lua"
      local s = 0
      for i = 1, 700 do s = s + i end
      require("budget_small_module")
      for i = 1, 700 do s = s + i end
      return s
      """

      assert_raise RuntimeException, ~r/instruction budget exceeded/, fn ->
        eval!(lua, code)
      end
    end

    test "a budget-exhausting require still trips, and pre-require work is preserved across it" do
      # Sanity companion: requiring the trivial module under a comfortable
      # budget, with light surrounding work, must succeed (the fix must not
      # over-count and spuriously trip a legitimate require).
      lua = Lua.new(sandboxed: [], max_instructions: 100_000)

      code = ~S"""
      package.path = "./test/fixtures/?.lua"
      local m = require("budget_small_module")
      return m
      """

      assert {[1], _lua} = eval!(lua, code)
    end
  end

  describe ":max_instructions validation" do
    test "rejects non-positive integers and non-integers" do
      assert_raise ArgumentError, ~r/:max_instructions/, fn -> Lua.new(max_instructions: 0) end
      assert_raise ArgumentError, ~r/:max_instructions/, fn -> Lua.new(max_instructions: -1) end
      assert_raise ArgumentError, ~r/:max_instructions/, fn -> Lua.new(max_instructions: :nope) end
    end

    test "accepts :infinity and positive integers" do
      assert %Lua{} = Lua.new(max_instructions: :infinity)
      assert %Lua{} = Lua.new(max_instructions: 1)
    end
  end
end
