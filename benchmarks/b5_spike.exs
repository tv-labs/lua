## B5 spike — does compiling fib to a BEAM module beat interpreting it?
##
## Compares, on identical fib(N) work:
##
##   1. lua (chunk)         — current interpreter (baseline)
##   2. native elixir       — hand-written Elixir; BEAMASM ceiling, no Lua
##      semantics overhead. Establishes the upper bound for what
##      BEAM-side optimisation can possibly buy.
##   3. compiled erlang     — Erlang module generated at runtime via
##      :compile.forms/2, called from the VM. This is the realistic
##      proxy for what B5's codegen could plausibly emit, modulo Lua
##      semantics that the spike strips out.
##   4. luerl               — Erlang-based Lua 5.3 (reference for the
##      Direction B "perf parity with Luerl ±10%" target).
##   5. C Lua via luaport   — out-of-process; included for context.
##
## The point is to bound the win. If (3) is close to (2) we know the
## BEAM JIT path delivers most of its theoretical headroom and B5 is
## worth its multi-month build. If (3) is closer to (1) than to (2),
## the BEAM doesn't actually optimise this kind of generated code
## meaningfully, and the strategic story changes.

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

n = String.to_integer(System.get_env("FIB_N") || "25")

fib_def = """
function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
"""

call_fib = "return fib(#{n})"

# --- 1. Interpreter ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, fib_def)
{fib_chunk, _} = Lua.load_chunk!(lua, call_fib)

# --- 2. Native Elixir (BEAMASM ceiling) ---
defmodule SpikeFib do
  def fib(n) when n < 2, do: n
  def fib(n), do: fib(n - 1) + fib(n - 2)
end

# --- 3. Compiled Erlang via compile:forms/2 ---
# We hand-write the abstract forms for:
#
#   -module(spike_fib_compiled).
#   -export([fib/1]).
#   fib(N) when N < 2 -> N;
#   fib(N) -> fib(N-1) + fib(N-2).
#
# This is structurally what B5's codegen would produce for the fib
# prototype if it stripped Lua tagging (no register tuple, no upvalue
# lookup, no get_field on _ENV). The interesting question is whether
# the BEAM treats this as well as it treats the same code written
# directly in Elixir.
forms = [
  {:attribute, 1, :module, :spike_fib_compiled},
  {:attribute, 2, :export, [{:fib, 1}]},
  {:function, 3, :fib, 1,
   [
     {:clause, 3, [{:var, 3, :N}], [[{:op, 3, :<, {:var, 3, :N}, {:integer, 3, 2}}]],
      [{:var, 3, :N}]},
     {:clause, 4, [{:var, 4, :N}], [],
      [
        {:op, 4, :+,
         {:call, 4, {:atom, 4, :fib}, [{:op, 4, :-, {:var, 4, :N}, {:integer, 4, 1}}]},
         {:call, 4, {:atom, 4, :fib}, [{:op, 4, :-, {:var, 4, :N}, {:integer, 4, 2}}]}}
      ]}
   ]}
]

{:ok, mod_name, bin, _warnings} = :compile.forms(forms, [:return])
{:module, ^mod_name} = :code.load_binary(mod_name, ~c"spike_fib_compiled.beam", bin)

# Sanity: all three give the same answer.
expected = SpikeFib.fib(n)
{[interp_result], _} = Lua.eval!(lua, call_fib)
^expected = round(interp_result)
^expected = :spike_fib_compiled.fib(n)
IO.puts("All implementations agree: fib(#{n}) = #{expected}\n")

# --- 4. Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(fib_def, luerl_state)

# --- 5. C Lua via luaport (optional) ---
{c_lua_benchmarks, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:b5_spike_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, fib_def)

      benchmarks = %{
        "C Lua (luaport)" => fn -> :luaport.call(port_pid, :fib, [n]) end
      }

      {benchmarks, fn -> :luaport.despawn(:b5_spike_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {%{}, fn -> :ok end}
  end

Bench.banner("b5 spike: fib(#{n})")

Benchee.run(
  Map.merge(
    %{
      "lua (chunk)" => fn -> Lua.eval!(lua, fib_chunk) end,
      "native elixir" => fn -> SpikeFib.fib(n) end,
      "compiled erlang" => fn -> :spike_fib_compiled.fib(n) end,
      "luerl" => fn -> :luerl.do(call_fib, luerl_state) end
    },
    c_lua_benchmarks
  ),
  Bench.opts()
)

c_lua_cleanup.()
