defmodule Lua.VM.LeakRegressionTest do
  @moduledoc """
  Pins the non-leak guarantee of the bytecode compiler + dispatcher.

  The whole point of moving away from per-prototype BEAM module generation
  was to keep `Lua.eval/2` from minting atoms or loading code modules at
  runtime. These tests assert that property holds: running large batches
  of distinct Lua sources — both via `Lua.eval!` directly and via the
  Lua `load()` stdlib — grows neither the atom table nor the
  loaded-module count by more than a small noise threshold.

  This is the test that should have existed when the prior `:compile.forms`
  experiment was originally explored. Treating leak-freedom as a property
  the test suite enforces keeps future codegen experiments honest.
  """

  use ExUnit.Case, async: false

  test "compiling N distinct prototypes via Lua.eval! does not grow atom table" do
    # Warm-up loop: the parser/lexer/codegen pipeline interns some atoms
    # the first time each AST/op shape is seen. After ~100 distinct
    # sources the table stabilises. The measurement window starts after
    # warm-up so the test only captures genuine per-iteration growth.
    lua = Lua.new()

    for i <- 1..200 do
      {[_v], _state} = Lua.eval!(lua, "return #{i} + 1")
    end

    :erlang.garbage_collect()
    before_atoms = :erlang.system_info(:atom_count)
    before_modules = length(:code.all_loaded())

    for i <- 1..1_000 do
      {[_v], _state} = Lua.eval!(lua, "return #{i + 10_000} + 1")
    end

    :erlang.garbage_collect()

    after_atoms = :erlang.system_info(:atom_count)
    after_modules = length(:code.all_loaded())

    # Per-iteration atom growth must be ~zero. Allow a small headroom
    # for incidental interning during the run (formatter strings, etc).
    assert after_atoms - before_atoms < 50,
           "atom count grew by #{after_atoms - before_atoms} over 1000 evals"

    # The dispatcher must not generate per-prototype modules. The
    # test runner loads ancillary modules lazily during a run
    # (Inspect protocol consolidations, exception formatters,
    # benchmark plumbing if it ran first), so we allow a small fixed
    # headroom and assert sub-linear-in-N growth — if each iteration
    # loaded even one module, the count would grow by 1000.
    growth = after_modules - before_modules
    assert growth < 20, "loaded module count grew by #{growth} (expected < 20)"
  end

  test "load() with unique sources does not grow atom table" do
    # `load` is sandboxed by default; allow it explicitly so we can
    # exercise the runtime-compile path.
    lua = Lua.new(sandbox: false)
    # Warm-up call to settle any first-call atom interning.
    {_, _} = Lua.eval!(lua, "return 0")

    before_atoms = :erlang.system_info(:atom_count)
    before_modules = length(:code.all_loaded())

    {_, _lua} =
      Lua.eval!(lua, """
      for i = 1, 1000 do
        load("return " .. i)()
      end
      """)

    :erlang.garbage_collect()

    after_atoms = :erlang.system_info(:atom_count)
    after_modules = length(:code.all_loaded())

    assert after_atoms - before_atoms < 50,
           "atom count grew by #{after_atoms - before_atoms} over 1000 load() calls"

    growth = after_modules - before_modules
    assert growth < 20, "loaded module count grew by #{growth} (expected < 20)"
  end

  test "bytecode prototypes are plain tuples, not modules" do
    # Direct shape check: a compiled prototype's bytecode is a tuple of
    # tuples — no module reference, no `make_ref/0`, no anything that
    # ties it to a particular code version. Hot-reloading the dispatcher
    # would invalidate nothing but the function pointer in the calling
    # process, which is the same property any normal Elixir module has.
    {:ok, ast} = Lua.Parser.parse("function f(a, b) return a + b end")
    {:ok, proto} = Lua.Compiler.compile(ast)
    [fn_proto] = proto.prototypes

    assert is_tuple(fn_proto.bytecode)
    refute is_atom(fn_proto.bytecode)
    refute is_reference(fn_proto.bytecode)
  end
end
