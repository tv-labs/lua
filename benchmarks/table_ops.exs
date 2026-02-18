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
# NOTE: luaport requires C Lua development headers. On macOS with Homebrew:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix deps.compile luaport
# Then run:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix run benchmarks/table_ops.exs

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

n = 500

call_build = "return run_table_build(#{n})"
call_sort = "return run_table_sort(#{n})"
call_sum = "return run_table_sum(#{n})"
call_map_reduce = "return run_table_map_reduce(#{n})"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, table_def)
{build_chunk, _} = Lua.load_chunk!(lua, call_build)
{sort_chunk, _} = Lua.load_chunk!(lua, call_sort)
{sum_chunk, _} = Lua.load_chunk!(lua, call_sum)
{map_reduce_chunk, _} = Lua.load_chunk!(lua, call_map_reduce)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(table_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_build, c_lua_sort, c_lua_sum, c_lua_map_reduce, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:table_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, table_def)

      mk = fn func -> %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, func, [n]) end} end

      {
        mk.(:run_table_build),
        mk.(:run_table_sort),
        mk.(:run_table_sum),
        mk.(:run_table_map_reduce),
        fn -> :luaport.despawn(:table_bench) end
      }

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      empty = %{}
      {empty, empty, empty, empty, fn -> :ok end}
  end

benchee_opts = [time: 10, warmup: 2, memory_time: 1]

IO.puts("\n=== Table Build (n=#{n}) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_build) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, build_chunk) end,
      "luerl" => fn -> :luerl.do(call_build, luerl_state) end
    },
    c_lua_build
  ),
  benchee_opts
)

IO.puts("\n=== Table Sort (n=#{n}) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_sort) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, sort_chunk) end,
      "luerl" => fn -> :luerl.do(call_sort, luerl_state) end
    },
    c_lua_sort
  ),
  benchee_opts
)

IO.puts("\n=== Table Iterate/Sum (n=#{n}) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_sum) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, sum_chunk) end,
      "luerl" => fn -> :luerl.do(call_sum, luerl_state) end
    },
    c_lua_sum
  ),
  benchee_opts
)

IO.puts("\n=== Table Map + Reduce (n=#{n}) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_map_reduce) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, map_reduce_chunk) end,
      "luerl" => fn -> :luerl.do(call_map_reduce, luerl_state) end
    },
    c_lua_map_reduce
  ),
  benchee_opts
)

c_lua_cleanup.()
