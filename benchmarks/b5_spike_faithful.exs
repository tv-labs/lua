## B5 spike — *faithful* translation
##
## Companion to benchmarks/b5_spike.exs. That first spike answered "is
## there headroom?" with a stripped-down fib that called itself directly
## as `:spike_fib_compiled.fib/1`. This one answers the follow-up:
## **how much of that headroom survives once we add back the Lua-VM
## machinery a real B5 codegen could not skip?**
##
## What "faithful" means here. The compiled fib module:
##
##   1. Receives `(args :: [number()], upvalues :: tuple(), state)` and
##      returns `{results :: [number()], state}` — the same shape as a
##      :lua_closure interpreted call.
##   2. Performs the recursive call via the actual VM dispatch path:
##      look up `_ENV` through the upvalue cell, fetch `_ENV.fib` from
##      the globals table's `:data` map, then call
##      `Lua.VM.Executor.call_function/3` with the resolved callable.
##      That callable is `{:compiled_closure, ...}` (itself), so it
##      re-enters the same path the `:call` opcode uses on Lua closures.
##   3. Threads `state` through both recursive calls — the same
##      mutable-state ABI Luerl and our interpreter use.
##   4. Returns a result list `[value]`, not a bare number — matching
##      the call protocol used by `continue_after_call/11`.
##
## What it does *not* model (in scope for B5 proper, out of scope for
## the spike):
##
##   - Integer overflow narrowing (`Numeric.narrow_if_integer/1`).
##   - Metamethod fallbacks for `<` and `+`.
##   - Line/source threading for runtime errors.
##   - Open-upvalue close on return.
##
## A real B5 codegen would either inline guards for the common integer
## path (avoiding the fallback cost) or emit conditional dispatch. The
## fib hot path uses the integer fast path on every iteration, so
## omitting these costs reflects the *intended* B5 fast path, not a
## cheat.

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

# --- Interpreter baseline ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, fib_def)
{fib_chunk, _} = Lua.load_chunk!(lua, call_fib)

# --- Native Elixir (BEAMASM ceiling, no Lua semantics) ---
defmodule SpikeFib do
  def fib(n) when n < 2, do: n
  def fib(n), do: fib(n - 1) + fib(n - 2)
end

# --- Stripped compiled erlang (from the first spike, for reference) ---
stripped_forms = [
  {:attribute, 1, :module, :spike_fib_stripped},
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

{:ok, stripped_mod, stripped_bin, _} = :compile.forms(stripped_forms, [:return])
{:module, ^stripped_mod} =
  :code.load_binary(stripped_mod, ~c"spike_fib_stripped.beam", stripped_bin)

# --- Faithful compiled erlang ---
#
# Hand-rolled abstract forms equivalent to this Erlang source:
#
#   -module(spike_fib_faithful).
#   -export([fib/3]).
#
#   fib([N | _], Upvalues, State) when N < 2 ->
#       {[N], State};
#   fib([N | _], Upvalues, State) ->
#       %% _ENV.fib lookup — what {:get_upvalue, ...} + {:get_field, ...}
#       %% do in the interpreter.
#       EnvCellRef = element(1, Upvalues),
#       EnvRef = maps:get(EnvCellRef, element(11, State)), % state.upvalue_cells
#       {tref, EnvId} = EnvRef,
#       EnvTable = maps:get(EnvId, element(5, State)),    % state.tables
#       FibCallable = maps:get(<<"fib">>, maps:get(data, EnvTable)),
#       %% Recursive calls back through the VM call protocol.
#       {R1List, S1} = 'Elixir.Lua.VM.Executor':call_function(
#           FibCallable, [N - 1], State),
#       {R2List, S2} = 'Elixir.Lua.VM.Executor':call_function(
#           FibCallable, [N - 2], S1),
#       [V1 | _] = R1List,
#       [V2 | _] = R2List,
#       {[V1 + V2], S2}.
#
# State field indices come from %Lua.VM.State{}. Maps (state.tables and
# state.upvalue_cells) are looked up via maps:get/2 in this version —
# the interpreter uses the same pattern (`Map.get/2` / `:erlang.map_get/2`).
#
# `element(N, State)` indexes into the struct as a tuple. The state
# struct's field order is reachable at compile time, but for the
# spike's purposes we just match the value out at the Elixir layer
# and pass the two maps through directly. That keeps the abstract
# forms small and isolates the question to "dispatch + call protocol
# cost", not "struct-shape pattern matching cost".
#
# Compromise: instead of indexing the State struct via element/N at
# the abstract-forms level, the module receives the two relevant maps
# as additional positional args. The interpreter does effectively the
# same with `state.upvalue_cells` and `state.tables` reads — those are
# struct field accesses (compile-time-known offsets), so passing them
# in directly does not change the cost story.
#
# Actually — let's keep the spike simple and have the compiled module
# call back into a tiny Elixir helper that reads the two maps from
# the state struct. That helper is one indirect call; it does the
# struct decomposition once. The recursive call path is what we care
# about measuring.

defmodule SpikeFib.Helpers do
  @moduledoc false

  # Returns the resolved `_ENV.fib` callable from current state.
  # In a real B5 codegen this would be inlined as direct struct field
  # reads + a Map.get/2 — same cost as the interpreter's
  # {:get_upvalue, ...} + {:get_field, ...} pair.
  def resolve_env_fib(upvalues, state) do
    cell_ref = elem(upvalues, 0)
    {:tref, env_id} = Map.fetch!(state.upvalue_cells, cell_ref)
    env = :erlang.map_get(env_id, state.tables)
    :erlang.map_get("fib", :erlang.map_get(:data, env))
  end
end

faithful_forms = [
  {:attribute, 1, :module, :spike_fib_faithful},
  {:attribute, 2, :export, [{:fib, 3}]},
  {:function, 3, :fib, 3,
   [
     # Base case: fib([N | _], _, State) when N < 2 -> {[N], State}.
     {:clause, 3,
      [
        {:cons, 3, {:var, 3, :N}, {:var, 3, :_}},
        {:var, 3, :_Upvalues},
        {:var, 3, :State}
      ],
      [[{:op, 3, :<, {:var, 3, :N}, {:integer, 3, 2}}]],
      [
        {:tuple, 3, [{:cons, 3, {:var, 3, :N}, {nil, 3}}, {:var, 3, :State}]}
      ]},
     # Recursive case.
     {:clause, 4,
      [
        {:cons, 4, {:var, 4, :N}, {:var, 4, :_}},
        {:var, 4, :Upvalues},
        {:var, 4, :State}
      ],
      [],
      [
        # Fib = Elixir.SpikeFib.Helpers:resolve_env_fib(Upvalues, State).
        {:match, 4, {:var, 4, :Fib},
         {:call, 4, {:remote, 4, {:atom, 4, :"Elixir.SpikeFib.Helpers"}, {:atom, 4, :resolve_env_fib}},
          [{:var, 4, :Upvalues}, {:var, 4, :State}]}},
        # {R1, S1} = Elixir.Lua.VM.Executor:call_function(Fib, [N-1], State).
        {:match, 5, {:tuple, 5, [{:var, 5, :R1}, {:var, 5, :S1}]},
         {:call, 5, {:remote, 5, {:atom, 5, :"Elixir.Lua.VM.Executor"}, {:atom, 5, :call_function}},
          [
            {:var, 5, :Fib},
            {:cons, 5, {:op, 5, :-, {:var, 5, :N}, {:integer, 5, 1}}, {nil, 5}},
            {:var, 5, :State}
          ]}},
        # {R2, S2} = Elixir.Lua.VM.Executor:call_function(Fib, [N-2], S1).
        {:match, 6, {:tuple, 6, [{:var, 6, :R2}, {:var, 6, :S2}]},
         {:call, 6, {:remote, 6, {:atom, 6, :"Elixir.Lua.VM.Executor"}, {:atom, 6, :call_function}},
          [
            {:var, 6, :Fib},
            {:cons, 6, {:op, 6, :-, {:var, 6, :N}, {:integer, 6, 2}}, {nil, 6}},
            {:var, 6, :S1}
          ]}},
        # [V1 | _] = R1; [V2 | _] = R2.
        {:match, 7, {:cons, 7, {:var, 7, :V1}, {:var, 7, :_}}, {:var, 7, :R1}},
        {:match, 8, {:cons, 8, {:var, 8, :V2}, {:var, 8, :_}}, {:var, 8, :R2}},
        # {[V1 + V2], S2}.
        {:tuple, 9,
         [
           {:cons, 9, {:op, 9, :+, {:var, 9, :V1}, {:var, 9, :V2}}, {nil, 9}},
           {:var, 9, :S2}
         ]}
      ]}
   ]}
]

{:ok, faithful_mod, faithful_bin, _} = :compile.forms(faithful_forms, [:return])
{:module, ^faithful_mod} =
  :code.load_binary(faithful_mod, ~c"spike_fib_faithful.beam", faithful_bin)

# --- Install the compiled fib into the Lua state ---
#
# We grab the existing `:lua_closure` value bound to `fib` in _G,
# extract its upvalues tuple, and rebind `fib` to a `:compiled_closure`
# that uses the same upvalues. From the rest of the VM's perspective
# fib is still a callable function value with the same upvalue
# environment — only the dispatch shape changes.

state = lua.state
{:tref, g_id} = state.g_ref
g_table = :erlang.map_get(g_id, state.tables)
{:lua_closure, _proto, fib_upvalues} = :erlang.map_get("fib", g_table.data)

compiled_fib = {:compiled_closure, :spike_fib_faithful, :fib, fib_upvalues}

new_g_data = :maps.put("fib", compiled_fib, g_table.data)
new_g_table = %{g_table | data: new_g_data}
new_tables = :maps.put(g_id, new_g_table, state.tables)
state = %{state | tables: new_tables}
lua_compiled = %{lua | state: state}

# Sanity: faithful, stripped, native, and luerl all agree on the result.
expected = SpikeFib.fib(n)
{[interp_result], _} = Lua.eval!(lua, call_fib)
^expected = round(interp_result)
^expected = :spike_fib_stripped.fib(n)
{[faithful_result], _} = Lua.eval!(lua_compiled, call_fib)
^expected = round(faithful_result)
IO.puts("All implementations agree: fib(#{n}) = #{expected}\n")

# --- Luerl reference ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(fib_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_benchmarks, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:b5_faithful_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, fib_def)

      {%{"C Lua (luaport)" => fn -> :luaport.call(port_pid, :fib, [n]) end},
       fn -> :luaport.despawn(:b5_faithful_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping")
      {%{}, fn -> :ok end}
  end

Bench.banner("b5 faithful spike: fib(#{n})")

Benchee.run(
  Map.merge(
    %{
      "lua (interpreter)" => fn -> Lua.eval!(lua, fib_chunk) end,
      "lua (compiled-faithful)" => fn -> Lua.eval!(lua_compiled, fib_chunk) end,
      "lua (compiled-stripped)" => fn -> :spike_fib_stripped.fib(n) end,
      "native elixir" => fn -> SpikeFib.fib(n) end,
      "luerl" => fn -> :luerl.do(call_fib, luerl_state) end
    },
    c_lua_benchmarks
  ),
  Bench.opts()
)

c_lua_cleanup.()
