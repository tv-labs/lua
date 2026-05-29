defmodule Lua.VM.RecursionDepthTest do
  @moduledoc """
  Pins the `:max_call_depth` recursion limit: deep recursion raises a
  catchable Lua `"stack overflow"` error, the depth counter unwinds on
  return and after a caught error, and `:infinity` (the default) imposes
  no bound.
  """
  use ExUnit.Case, async: true

  alias Lua.RuntimeException

  defp eval!(lua, code), do: Lua.eval!(lua, code)

  describe ":max_call_depth enforcement" do
    test "recursion deeper than the limit raises stack overflow" do
      lua = Lua.new(max_call_depth: 10)

      assert_raise RuntimeException, ~r/stack overflow/, fn ->
        eval!(lua, "local function f(n) if n > 0 then f(n - 1) end end f(50)")
      end
    end

    test "recursion under the limit returns normally and the VM stays usable" do
      lua = Lua.new(max_call_depth: 100)

      # deep(50) nests 50 frames — comfortably under the cap — and returns n.
      {[50], lua} =
        eval!(lua, "local function deep(n) if n > 0 then deep(n - 1) end return n end return deep(50)")

      # The depth counter must have unwound back to 0: a second deep call works.
      assert {[50], _lua} =
               eval!(lua, "local function deep(n) if n > 0 then deep(n - 1) end return n end return deep(50)")
    end

    test "pcall catches the overflow and the VM keeps working afterward" do
      lua = Lua.new(max_call_depth: 50)

      {[false, err], lua} =
        eval!(lua, "local function f(n) f(n + 1) end return pcall(f, 1)")

      assert err =~ "stack overflow"

      # call_depth was restored on the rescue, so the VM is healthy.
      assert {[2], _lua} = eval!(lua, "return 1 + 1")
    end

    test "tail recursion is bounded too (no tail-call optimization)" do
      # `return f(...)` is in tail position, which PUC-Lua would run
      # unbounded. This VM does not implement TCO, so every call — tail or
      # not — consumes a frame and a finite cap stops the recursion.
      lua = Lua.new(max_call_depth: 10)

      assert_raise RuntimeException, ~r/stack overflow/, fn ->
        eval!(lua, "local function loop(n) return loop(n + 1) end loop(1)")
      end
    end
  end

  describe "default behavior (:infinity)" do
    test "moderately deep recursion runs with no limit" do
      {[200], _lua} =
        Lua.eval!(
          Lua.new(),
          "local function deep(n) if n > 0 then deep(n - 1) end return n end return deep(200)"
        )
    end
  end

  describe ":max_call_depth validation" do
    test "rejects non-positive integers and non-integers" do
      assert_raise ArgumentError, ~r/:max_call_depth/, fn -> Lua.new(max_call_depth: 0) end
      assert_raise ArgumentError, ~r/:max_call_depth/, fn -> Lua.new(max_call_depth: -5) end
      assert_raise ArgumentError, ~r/:max_call_depth/, fn -> Lua.new(max_call_depth: "big") end
    end

    test "accepts :infinity and positive integers" do
      assert %Lua{} = Lua.new(max_call_depth: :infinity)
      assert %Lua{} = Lua.new(max_call_depth: 1)
    end
  end
end
