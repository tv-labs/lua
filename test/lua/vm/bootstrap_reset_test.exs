defmodule Lua.VM.BootstrapResetTest do
  @moduledoc """
  Pins `Lua.VM.Bootstrap.reset/0`: it erases every memoized boot template,
  including ones populated by concurrent cold starts, and `Lua.new/1` keeps
  working afterwards.

  Not async: these tests assert the global `:persistent_term` memo is empty,
  which a concurrent `Lua.new/1` in any other test would refill.
  """

  use ExUnit.Case, async: false

  alias Lua.VM.Bootstrap

  describe "reset/0" do
    test "erases every memoized key so the next fetch rebuilds" do
      _warm = Lua.new()

      for key <- Bootstrap.memoized_keys() do
        assert :persistent_term.get(key, :missing) != :missing,
               "expected #{inspect(key)} to be memoized by Lua.new/1"
      end

      assert Bootstrap.reset() == :ok

      for key <- Bootstrap.memoized_keys() do
        assert :persistent_term.get(key, :missing) == :missing
      end

      assert {[2], _} = Lua.eval!(Lua.new(), "return 1 + 1")
    end

    test "erases every memoized key populated by racing cold starts" do
      Bootstrap.reset()

      test = self()

      workers =
        for _ <- 1..64 do
          Task.async(fn ->
            send(test, {:ready, self()})
            assert_receive :go
            Lua.new()
          end)
        end

      for %Task{pid: pid} <- workers, do: assert_receive({:ready, ^pid})
      for %Task{pid: pid} <- workers, do: send(pid, :go)

      Task.await_many(workers)

      assert Bootstrap.reset() == :ok

      for key <- Bootstrap.memoized_keys() do
        assert :persistent_term.get(key, :missing) == :missing,
               "reset/0 left #{inspect(key)} behind after a concurrent cold start"
      end
    end

    test "does not consult runtime bookkeeping, and erases the obsolete entry" do
      # An entry left by a build that tracked the stored keys at runtime. Such
      # tracking is a read-modify-write that concurrent cold starts can
      # truncate, so a truncated list must not be able to narrow what `reset/0`
      # erases — and the entry itself must not survive the reset.
      obsolete = {Bootstrap, :keys}
      on_exit(fn -> :persistent_term.erase(obsolete) end)

      _warm = Lua.new()
      :persistent_term.put(obsolete, [])

      assert Bootstrap.reset() == :ok

      for key <- [obsolete | Bootstrap.memoized_keys()] do
        assert :persistent_term.get(key, :missing) == :missing,
               "reset/0 left #{inspect(key)} behind"
      end
    end

    test "Lua.new/1 still works after a reset" do
      _warm = Lua.new()

      assert Bootstrap.reset() == :ok

      assert {[2], _} = Lua.eval!(Lua.new(), "return 1 + 1")
    end
  end
end
