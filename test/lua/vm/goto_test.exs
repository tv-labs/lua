defmodule Lua.VM.GotoTest do
  @moduledoc """
  Conformance tests for Lua 5.3 `goto` / `::label::` across both VM engines.

  Each case runs on the interpreter (bytecode stripped) and on the bytecode
  dispatcher (bytecode kept) and asserts both produce the same, correct
  result. `goto` is non-structured control flow — the interesting cases are
  backward jumps, `continue`-style jumps out of an `if`, break-style jumps
  out of a loop, jumps across reused label names, and jumps that must close
  captured upvalues on the way out of a scope.
  """

  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Run `src` on whichever engine `mode` selects, returning the result list.
  # `:dispatcher` keeps the compiled bytecode; `:interpreter` strips it from
  # the whole prototype tree so execution falls back to the list interpreter.
  defp run(src, mode) do
    {:ok, ast} = Parser.parse(src)
    {:ok, proto} = Compiler.compile(ast, source: "goto_test.lua")
    proto = if mode == :interpreter, do: strip_proto(proto), else: proto
    state = Stdlib.install(State.new())
    {:ok, results, _state} = VM.execute(proto, state)
    results
  end

  defp strip_proto(%Prototype{} = p) do
    %{p | bytecode: nil, prototypes: Enum.map(p.prototypes, &strip_proto/1)}
  end

  # Assert both engines agree and match the expected result.
  defp assert_both(src, expected) do
    assert run(src, :interpreter) == expected, "interpreter mismatch for:\n#{src}"
    assert run(src, :dispatcher) == expected, "dispatcher mismatch for:\n#{src}"
  end

  describe "goto conformance (both engines)" do
    test "forward goto skips statements" do
      assert_both("local x = 1; goto skip; x = 99; ::skip:: return x", [1])
    end

    test "backward goto forms a counted loop" do
      assert_both(
        """
        local i = 0
        ::top::
        i = i + 1
        if i < 5 then goto top end
        return i
        """,
        [5]
      )
    end

    test "continue idiom: goto out of an if to a later label in the loop body" do
      assert_both(
        """
        local sum = 0
        for i = 1, 5 do
          if i % 2 == 0 then goto cont end
          sum = sum + i
          ::cont::
        end
        return sum
        """,
        [9]
      )
    end

    test "break-style: goto out of a loop to a label after it" do
      assert_both(
        """
        local i = 0
        while true do
          i = i + 1
          if i == 3 then goto done end
        end
        ::done::
        return i
        """,
        [3]
      )
    end

    test "goto out of a nested loop to a function-level label" do
      assert_both(
        """
        local found = nil
        for a = 1, 3 do
          for b = 1, 3 do
            if a * b == 6 then found = a * 10 + b; goto out end
          end
        end
        ::out::
        return found
        """,
        [23]
      )
    end

    test "forward goto jumps over a reused label name to the correct one" do
      # Two blocks each define ::l::; the goto must reach the one in scope.
      assert_both(
        """
        local x = 0
        do goto l; x = 1; ::l:: x = x + 10 end
        do goto l; x = x + 100; ::l:: x = x + 1000 end
        return x
        """,
        [1010]
      )
    end

    test "goto to a label at end of block falls through to return" do
      assert_both(
        """
        local function f(n)
          if n > 0 then goto positive end
          do return "nonpos" end
          ::positive::
          return "pos"
        end
        return f(5), f(-1)
        """,
        ["pos", "nonpos"]
      )
    end

    test "goto exiting a loop closes captured upvalues correctly" do
      # The closure captures the loop local `v`; jumping out must close the
      # cell so the captured value is the one from the iteration that jumped.
      assert_both(
        """
        local captured
        for i = 1, 10 do
          local v = i * 2
          captured = function() return v end
          if i == 3 then goto stop end
        end
        ::stop::
        return captured()
        """,
        [6]
      )
    end
  end
end
