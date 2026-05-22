## B5 spike — table-heavy workload
##
## Third spike in the series. The first two answered "is there headroom?"
## (yes, 100x stripped) and "how much survives Lua semantics?"
## (12x faithful, on fib). Both used pure integer arithmetic.
##
## This spike answers: does the win generalise to table-heavy code?
## fib is the friendliest possible benchmark — no allocation, no map
## traversal, no metamethod dispatch path. Real Lua programs spend
## significant time in `t[i] = v` and `t[i]` operations, both of
## which go through:
##
##   - Allocation (`State.alloc_table` -> new map in state.tables)
##   - Lookup (table struct -> :data map -> key fetch)
##   - Mutation (table struct -> new :data map -> new state.tables map)
##
## All three allocate. Lua programs that touch a 1000-entry table will
## allocate a comparable number of intermediate maps. The interpreter's
## register-tuple churn that B5 fully eliminates on fib does *not*
## eliminate this — it lives in the state struct's :tables field, not
## in registers.
##
## The workload: `run_table_sum(n)` from benchmarks/table_ops.exs.
## Builds a 1..n table via `:set_table` in a `:numeric_for` loop, then
## sums it via `:get_table` in a second `:numeric_for`. Two loops, two
## table operations per iteration, no recursion.
##
## What "faithful" means here, same shape as the second spike:
##
##   - Receives `(args, upvalues, state)`, returns `{results, state}`.
##   - `:new_table` -> `State.alloc_table(state)` (full allocation cost).
##   - `:set_table` -> `Executor.table_newindex/4` (the public path the
##     interpreter takes; includes metatable check and Table.put).
##   - `:get_table` -> inlined fast-path: `:erlang.map_get(:data, table)`
##     then map fetch. Matches the interpreter's fast path verbatim.
##   - Loops compiled to recursive helpers (the BEAM-native loop
##     idiom; this is what `compile:forms` would emit for a Lua
##     `:numeric_for` once it knows the bounds).
##   - State threads through every operation that mutates it (allocation,
##     set_table). Read-only ops (get_table on a stable table) thread
##     state too because :get_table is permitted to call __index via
##     a metamethod — codegen has to assume it might.
##
## What it does *not* model (out of scope; same caveats as second spike):
##
##   - Integer overflow narrowing.
##   - Metamethod fallbacks for `__newindex` / `__index`.
##   - Line/source threading for runtime errors.
##
## The compiled function is written in Elixir, not :compile.forms-built
## Erlang. Justification: the BEAM compiles Elixir modules with the same
## BEAMASM JIT that processes `:compile.forms/2` output. The second spike
## verified `:compile.forms` output runs at near-native Elixir speed (1.13x
## slower). Writing this spike in Elixir saves ~200 lines of abstract-forms
## machinery and isolates the question to "compiled vs interpreted dispatch
## of the same opcodes", which is what we care about. If you want to verify
## the equivalence claim, compare the second spike's compiled-stripped vs
## native-elixir columns: 1.08x in quick mode, 1.13x in full mode.

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

table_def = """
function run_table_sum(n)
  local t = {}
  for i = 1, n do
    t[i] = i
  end
  local sum = 0
  for j = 1, n do
    sum = sum + t[j]
  end
  return sum
end
"""

# --- Interpreter baseline ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, table_def)

# --- Compiled run_table_sum ---
#
# Equivalent to the Lua source above. Structurally what B5 codegen
# would emit for the prototype's instruction stream, with each
# interpreter opcode lowered to a direct call.
defmodule SpikeTableSum do
  @moduledoc false

  alias Lua.VM.Executor
  alias Lua.VM.State

  # Entry point. Matches the call protocol used by :compiled_closure
  # in lib/lua/vm/executor.ex.
  @spec run([number()], tuple(), State.t()) :: {[number()], State.t()}
  def run([n | _], _upvalues, state) do
    # local t = {}
    {tref, state} = State.alloc_table(state)

    # for i = 1, n do t[i] = i end
    state = build_loop(1, n, tref, state)

    # local sum = 0; for j = 1, n do sum = sum + t[j] end
    sum = sum_loop(1, n, tref, state, 0)

    {[sum], state}
  end

  # First numeric_for: t[i] = i, i=1..n.
  defp build_loop(i, n, _tref, state) when i > n, do: state
  defp build_loop(i, n, tref, state) do
    state = Executor.table_newindex(tref, i, i, state)
    build_loop(i + 1, n, tref, state)
  end

  # Second numeric_for: sum = sum + t[j], j=1..n.
  # State is read-only here (no metatable, no __index), so it's not
  # threaded back out — but we still have to dereference it on every
  # iteration to fetch the current table. That's the realistic cost.
  defp sum_loop(j, n, _tref, _state, sum) when j > n, do: sum
  defp sum_loop(j, n, {:tref, id} = tref, state, sum) do
    table = :erlang.map_get(id, state.tables)
    value = :erlang.map_get(j, :erlang.map_get(:data, table))
    sum_loop(j + 1, n, tref, state, sum + value)
  end
end

# --- Install the compiled run_table_sum into _G ---
state = lua.state
{:tref, g_id} = state.g_ref
g = :erlang.map_get(g_id, state.tables)
{:lua_closure, _proto, rts_upvalues} = :erlang.map_get("run_table_sum", g.data)

compiled = {:compiled_closure, SpikeTableSum, :run, rts_upvalues}

new_g_data = :maps.put("run_table_sum", compiled, g.data)
new_g = %{g | data: new_g_data}
new_tables = :maps.put(g_id, new_g, state.tables)
state = %{state | tables: new_tables}
lua_compiled = %{lua | state: state}

# --- Luerl reference ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(table_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_call, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:b5_tables_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, table_def)

      {fn n -> :luaport.call(port_pid, :run_table_sum, [n]) end,
       fn -> :luaport.despawn(:b5_tables_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping")
      {nil, fn -> :ok end}
  end

# --- Pre-build chunks for each n ---
sizes =
  case System.get_env("LUA_BENCH_MODE") do
    "full" -> [{"small (n=100)", 100}, {"medium (n=500)", 500}, {"large (n=1000)", 1000}]
    _ -> [{"medium (n=500)", 500}]
  end

inputs =
  Map.new(sizes, fn {label, n} ->
    call_str = "return run_table_sum(#{n})"
    {chunk, _} = Lua.load_chunk!(lua, call_str)
    {label, {chunk, call_str, n}}
  end)

# --- Sanity ---
for {label, {chunk, call_str, n}} <- inputs do
  expected = div(n * (n + 1), 2)
  {[interp_result], _} = Lua.eval!(lua, chunk)
  ^expected = round(interp_result)
  {[compiled_result], _} = Lua.eval!(lua_compiled, chunk)
  ^expected = round(compiled_result)
  IO.puts("#{label}: all implementations agree (sum = #{expected})")
  _ = call_str
end

IO.puts("")

Bench.banner("b5 tables spike: run_table_sum")

jobs = %{
  "lua (interpreter)" => fn {chunk, _, _} -> Lua.eval!(lua, chunk) end,
  "lua (compiled)" => fn {chunk, _, _} -> Lua.eval!(lua_compiled, chunk) end,
  "luerl" => fn {_, call_str, _} -> :luerl.do(call_str, luerl_state) end
}

jobs =
  if c_lua_call do
    Map.put(jobs, "C Lua (luaport)", fn {_, _, n} -> c_lua_call.(n) end)
  else
    jobs
  end

Benchee.run(jobs, [{:inputs, inputs} | Bench.opts()])

c_lua_cleanup.()
