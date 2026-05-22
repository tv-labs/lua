# Run with: mix run benchmarks/table_ops.exs
#
# Benchmarks table (array) operations with n=500:
#   - build:       create array of squared values
#   - sort:        sort a reverse-ordered array (worst case for naive sort)
#   - iterate:     sum all values via ipairs
#   - map_reduce:  build → square each element → sum (two passes)
#
# Compares:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua 5.4 development headers and a small in-tree
# patch (its 1.6.3 release defaults to LuaJIT and uses LUA_GLOBALSINDEX which
# was removed in Lua 5.2). On macOS:
#   brew install lua@5.4
#   ./benchmarks/setup_luaport.sh           # idempotent; patches + builds
#   MIX_ENV=benchmark mix run benchmarks/table_ops.exs
# If luaport fails to start, the benchmark prints a notice and skips it.

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

table_def = """
function run_table_build(n)
  local t = {}
  for i = 1, n do
    t[i] = i * i
  end
  return #t
end

function run_table_sort(n)
  local t = {}
  for i = 1, n do
    t[i] = n - i + 1
  end
  table.sort(t)
  return t[1]
end

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

function run_table_map_reduce(n)
  local t = {}
  for i = 1, n do
    t[i] = i
  end
  local mapped = {}
  for j = 1, n do
    mapped[j] = t[j] * t[j]
  end
  local sum = 0
  for k = 1, n do
    sum = sum + mapped[k]
  end
  return sum
end
"""

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, table_def)

# Pre-compile chunks per (operation, n) pair so the chunk path doesn't
# pay the compile cost during measurement. Inputs ship through Benchee's
# `inputs:` mechanism so all sizes share warmup/measurement state.
sizes = Bench.table_inputs()

build_chunks =
  Map.new(sizes, fn {label, n} ->
    {chunk, _} = Lua.load_chunk!(lua, "return run_table_build(#{n})")
    {label, {chunk, "return run_table_build(#{n})", n}}
  end)

sort_chunks =
  Map.new(sizes, fn {label, n} ->
    {chunk, _} = Lua.load_chunk!(lua, "return run_table_sort(#{n})")
    {label, {chunk, "return run_table_sort(#{n})", n}}
  end)

sum_chunks =
  Map.new(sizes, fn {label, n} ->
    {chunk, _} = Lua.load_chunk!(lua, "return run_table_sum(#{n})")
    {label, {chunk, "return run_table_sum(#{n})", n}}
  end)

map_reduce_chunks =
  Map.new(sizes, fn {label, n} ->
    {chunk, _} = Lua.load_chunk!(lua, "return run_table_map_reduce(#{n})")
    {label, {chunk, "return run_table_map_reduce(#{n})", n}}
  end)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(table_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_call, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:table_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, table_def)

      {
        fn func, n -> :luaport.call(port_pid, func, [n]) end,
        fn -> :luaport.despawn(:table_bench) end
      }

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {nil, fn -> :ok end}
  end

bench = fn name, chunks_map, lua_func ->
  Bench.banner(name)

  jobs = %{
    "lua (eval)" => fn {_chunk, call_str, _n} -> Lua.eval!(lua, call_str) end,
    "lua (chunk)" => fn {chunk, _call_str, _n} -> Lua.eval!(lua, chunk) end,
    "luerl" => fn {_chunk, call_str, _n} -> :luerl.do(call_str, luerl_state) end
  }

  jobs =
    if c_lua_call do
      Map.put(jobs, "C Lua (luaport)", fn {_chunk, _call_str, n} -> c_lua_call.(lua_func, n) end)
    else
      jobs
    end

  Benchee.run(jobs, [{:inputs, chunks_map} | Bench.opts()])
end

bench.("Table Build", build_chunks, :run_table_build)
bench.("Table Sort", sort_chunks, :run_table_sort)
bench.("Table Iterate/Sum", sum_chunks, :run_table_sum)
bench.("Table Map + Reduce", map_reduce_chunks, :run_table_map_reduce)

c_lua_cleanup.()
