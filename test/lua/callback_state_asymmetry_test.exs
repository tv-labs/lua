defmodule Lua.CallbackStateAsymmetryTest do
  @moduledoc """
  A two-arity Elixir callback (`fn args, state -> {results, state} end`)
  must receive the same `state` argument — and accept the same return
  shape — regardless of how it entered the VM:

  | How the callback enters the VM                                  | `state` it receives |
  | --------------------------------------------------------------- | ------------------- |
  | `Lua.set!(lua, [:f], fun)` — function directly at the path       | `t:Lua.t/0`         |
  | `deflua` + `Lua.load_api/3`                                      | `t:Lua.t/0`         |
  | `Lua.set!(lua, [:t], %{"f" => fun})` — function inside a value   | `t:Lua.t/0`         |
  | `Lua.encode!(lua, fun)` — closure handed to Lua at runtime       | `t:Lua.t/0`         |

  Every entry point hands the callback the public `t:Lua.t/0`, so the public
  API (`Lua.decode!/2`, `Lua.encode!/2`, `Lua.get_private!/2`, …) works and a
  single closure written against the documented `Lua.set!/3` convention works
  in every position.
  """
  use ExUnit.Case, async: true

  defmodule DefluaProbe do
    @moduledoc false
    use Lua.API, scope: "probe"

    deflua whoami(), state do
      {[inspect(state.__struct__)], state}
    end
  end

  # Reports the struct name of the state the VM handed the callback.
  defp probe_callback do
    fn _args, state -> {[inspect(state.__struct__)], state} end
  end

  # A callback written exactly the way the `Lua.set!/3` docs teach: treat
  # `state` as a `t:Lua.t/0`, use the public API on it, return it as received.
  defp documented_convention_callback do
    fn _args, state -> {[Lua.get_private!(state, :secret)], state} end
  end

  describe "callbacks that receive the public Lua.t (documented convention)" do
    test "a function set! directly at a path receives Lua.t" do
      lua = Lua.set!(Lua.new(), [:probe], probe_callback())

      assert {["Lua"], _} = Lua.eval!(lua, "return probe()")
    end

    test "a deflua function loaded via load_api receives Lua.t" do
      lua = Lua.load_api(Lua.new(), DefluaProbe)

      assert {["Lua"], _} = Lua.eval!(lua, "return probe.whoami()")
    end

    test "a set!-at-path callback can use the public Lua API on its state" do
      lua =
        Lua.new()
        |> Lua.put_private(:secret, "from-private")
        |> Lua.set!([:fetch], documented_convention_callback())

      assert {["from-private"], _} = Lua.eval!(lua, "return fetch()")
    end
  end

  describe "callbacks that enter the VM as encoded values" do
    test "a closure embedded via encode! receives the same Lua.t" do
      {fun, lua} = Lua.encode!(Lua.new(), probe_callback())
      lua = Lua.set!(lua, [:probe], fun)

      assert {["Lua"], _} = Lua.eval!(lua, "return probe()")
    end

    test "a function nested inside a table passed to set! receives the same Lua.t" do
      lua = Lua.set!(Lua.new(), [:api], %{"probe" => probe_callback()})

      assert {["Lua"], _} = Lua.eval!(lua, "return api.probe()")
    end

    test "the same callback works identically via set! and via encode!" do
      lua = Lua.put_private(Lua.new(), :secret, "from-private")

      lua = Lua.set!(lua, [:registered], documented_convention_callback())
      {encoded, lua} = Lua.encode!(lua, documented_convention_callback())
      lua = Lua.set!(lua, [:embedded], encoded)

      assert {["from-private", "from-private"], _} =
               Lua.eval!(lua, "return registered(), embedded()")
    end
  end
end
