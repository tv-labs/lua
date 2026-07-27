defmodule Lua.VM.BootstrapTest do
  @moduledoc """
  Pins the contract of the memoized boot templates behind `Lua.new/1`: a VM
  built from a shared template must be indistinguishable from one built from
  scratch, and must stay isolated from every other VM built from it.
  """

  use ExUnit.Case, async: true

  alias Lua.VM.Bootstrap
  alias Lua.VM.Limits
  alias Lua.VM.State

  describe "Lua.new/1" do
    test "the standard library works" do
      lua = Lua.new()

      assert {[2], _} = Lua.eval!(lua, "return 1 + 1")
      assert {["HELLO"], _} = Lua.eval!(lua, ~S[return string.upper("hello")])
      assert {[3], _} = Lua.eval!(lua, "return math.max(1, 3, 2)")
      assert {["a,b"], _} = Lua.eval!(lua, ~S[return table.concat({"a", "b"}, ",")])
      assert {["Lua 5.3"], _} = Lua.eval!(lua, "return _VERSION")
      assert {[true], _} = Lua.eval!(lua, "return _G.print ~= nil")
    end

    test "sequential VMs are identical and evaluate identically" do
      first = Lua.new()
      second = Lua.new()

      assert :erlang.term_to_binary(first) === :erlang.term_to_binary(second)

      script = ~S"""
      local acc = {}
      for k in pairs(_G) do acc[#acc + 1] = k end
      return table.concat(acc, ","), tostring(#acc)
      """

      assert {results, _} = Lua.eval!(first, script)
      assert {^results, _} = Lua.eval!(second, script)
    end

    test "a fresh VM starts with the boot table and global counts" do
      state = Lua.new().state

      assert state.g_ref == {:tref, 0}
      assert state.table_next_id == 12
      assert map_size(state.tables) == 12
    end

    test "mutating one VM does not leak into the next" do
      mutated =
        Lua.new()
        |> Lua.set!([:planted], "leaked")
        |> Lua.set!([:deeply, :nested], "leaked")

      assert {["leaked"], _} = Lua.eval!(mutated, "return planted")

      fresh = Lua.new()

      assert {[nil], _} = Lua.eval!(fresh, "return planted")
      assert {[nil], _} = Lua.eval!(fresh, "return deeply")
      assert fresh.state.table_next_id == 12
    end

    test "globals and stdlib tables written from Lua do not leak into the next VM" do
      {_, mutated} =
        Lua.eval!(Lua.new(), ~S"""
        planted = "leaked"
        string.shout = function(s) return s end
        """)

      assert {["leaked", true], _} = Lua.eval!(mutated, "return planted, string.shout ~= nil")

      assert {[nil, nil], _} = Lua.eval!(Lua.new(), "return planted, string.shout")
    end

    test "limits and :debug are per-VM, not baked into the template" do
      limited = Lua.new(max_call_depth: 10, max_string_bytes: 1024, max_instructions: 5000, debug: true)

      assert limited.debug
      assert limited.state.max_call_depth == 10
      assert limited.state.max_string_bytes == 1024
      assert limited.state.max_instructions == 5000

      default = Lua.new()

      refute default.debug
      assert default.state.max_call_depth == :infinity
      assert default.state.max_string_bytes == Limits.max_string_bytes()
      assert default.state.max_instructions == :infinity
    end
  end

  describe "sandbox options" do
    test "the default deny-list still applies" do
      lua = Lua.new()

      assert_raise Lua.RuntimeException, "Lua runtime error: os.exit(_) is sandboxed", fn ->
        Lua.eval!(lua, "os.exit(1)")
      end

      assert_raise Lua.RuntimeException, "Lua runtime error: require(_) is sandboxed", fn ->
        Lua.eval!(lua, ~S[require("anything")])
      end
    end

    test "sandboxed: [] leaves the library intact" do
      lua = Lua.new(sandboxed: [])

      assert {["required file successfully"], _} =
               Lua.eval!(lua, ~S"""
               package.path = "./test/fixtures/?.lua"
               return require("test_require")
               """)
    end

    test "a custom deny-list sandboxes only what it names" do
      lua = Lua.new(sandboxed: [[:os, :exit]])

      assert_raise Lua.RuntimeException, "Lua runtime error: os.exit(_) is sandboxed", fn ->
        Lua.eval!(lua, "os.exit(1)")
      end

      assert {[true], _} = Lua.eval!(lua, "return load ~= nil")
      assert {[true], _} = Lua.eval!(lua, "return package ~= nil")
    end

    test ":exclude lifts entries out of the default deny-list" do
      lua = Lua.new(exclude: [[:require], [:package]])

      assert {["required file successfully"], _} =
               Lua.eval!(Lua.set_lua_paths(lua, "./test/fixtures/?.lua"), ~S[return require("test_require")])

      assert_raise Lua.RuntimeException, "Lua runtime error: os.exit(_) is sandboxed", fn ->
        Lua.eval!(lua, "os.exit(1)")
      end
    end

    test "custom-sandbox VMs do not disturb the default VM" do
      _custom = Lua.set!(Lua.new(sandboxed: []), [:planted], "leaked")

      assert {[nil], _} = Lua.eval!(Lua.new(), "return planted")

      assert_raise Lua.RuntimeException, "Lua runtime error: os.exit(_) is sandboxed", fn ->
        Lua.eval!(Lua.new(), "os.exit(1)")
      end
    end
  end

  describe "fetch/2" do
    setup do
      key = {__MODULE__, System.unique_integer()}
      on_exit(fn -> :persistent_term.erase(key) end)
      %{key: key}
    end

    test "builds once and returns the same term afterwards", %{key: key} do
      test = self()

      builder = fn ->
        send(test, :built)
        %{value: State.new()}
      end

      first = Bootstrap.fetch(key, builder)
      second = Bootstrap.fetch(key, builder)

      assert first === second
      assert_received :built
      refute_received :built
    end

    test "keys are independent", %{key: key} do
      other = {__MODULE__, System.unique_integer()}
      on_exit(fn -> :persistent_term.erase(other) end)

      assert Bootstrap.fetch(key, fn -> :one end) == :one
      assert Bootstrap.fetch(other, fn -> :two end) == :two
      assert Bootstrap.fetch(key, fn -> :three end) == :one
    end

    test "a stale fingerprint rebuilds the term", %{key: key} do
      :persistent_term.put(key, {[{__MODULE__, <<"not the current md5">>}], :stale})

      assert Bootstrap.fetch(key, fn -> :rebuilt end) == :rebuilt
      assert Bootstrap.fetch(key, fn -> :again end) == :rebuilt
    end

    test "a fingerprinted module that no longer exists rebuilds instead of raising", %{key: key} do
      :persistent_term.put(key, {[{Lua.VM.NoSuchModule, <<"md5 of deleted code">>}], :stale})

      assert Bootstrap.fetch(key, fn -> :rebuilt end) == :rebuilt
      assert Bootstrap.fetch(key, fn -> :again end) == :rebuilt
    end

    test "the fingerprint covers template-shaping modules even without captured funs", %{key: key} do
      # The stored term carries no closures at all, so every module below gets
      # into the fingerprint only via the explicit template-module list: a
      # struct-layout or default-limit change in any of them must invalidate
      # the template even though no fun in it points there.
      assert :code.get_mode() == :interactive

      Bootstrap.fetch(key, fn -> %{value: :no_funs_here} end)

      {fingerprint, _term} = :persistent_term.get(key)
      modules = Enum.map(fingerprint, fn {module, _md5} -> module end)

      for module <- [Lua, Bootstrap, Limits, State, Lua.VM.Stdlib, Lua.VM.Table] do
        assert module in modules, "fingerprint is missing template-shaping module #{inspect(module)}"
      end
    end
  end

  describe "reset/0" do
    setup do
      key = {__MODULE__, System.unique_integer()}
      on_exit(fn -> :persistent_term.erase(key) end)
      %{key: key}
    end

    test "erases the stored template so the next fetch rebuilds", %{key: key} do
      assert Bootstrap.fetch(key, fn -> :first end) == :first

      assert Bootstrap.reset() == :ok
      assert :persistent_term.get(key, nil) == nil

      assert Bootstrap.fetch(key, fn -> :second end) == :second
      assert Bootstrap.fetch(key, fn -> :third end) == :second
    end

    test "Lua.new/1 still works after a reset" do
      _warm = Lua.new()

      assert Bootstrap.reset() == :ok

      assert {[2], _} = Lua.eval!(Lua.new(), "return 1 + 1")
    end
  end
end
