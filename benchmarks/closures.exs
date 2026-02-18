# Run with: mix run benchmarks/closures.exs
#
# Benchmarks closures and upvalue capture.
# Creates 100 counter closures via a factory function, each starting at a different value,
# then calls each counter 10 times, accumulating the sum.
#
# Compares:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua development headers. On macOS with Homebrew:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix deps.compile luaport
# Then run:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix run benchmarks/closures.exs

Application.ensure_all_started(:luerl)

closure_def = """
function make_counter(start)
  local count = start
  return function()
    count = count + 1
    return count
  end
end

function run_closures(n)
  local counters = {}
  for i = 1, n do
    counters[i] = make_counter(i)
  end
  local sum = 0
  for j = 1, n do
    local counter = counters[j]
    for k = 1, 10 do
      sum = sum + counter()
    end
  end
  return sum
end
"""

call_closures = "return run_closures(100)"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, closure_def)
{closure_chunk, _} = Lua.load_chunk!(lua, call_closures)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(closure_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_benchmarks, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:closure_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, closure_def)

      benchmarks = %{
        "C Lua (luaport)" => fn -> :luaport.call(port_pid, :run_closures, [100]) end
      }

      {benchmarks, fn -> :luaport.despawn(:closure_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {%{}, fn -> :ok end}
  end

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_closures) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, closure_chunk) end,
      "luerl" => fn -> :luerl.do(call_closures, luerl_state) end
    },
    c_lua_benchmarks
  ),
  time: 10,
  warmup: 2,
  memory_time: 1
)

c_lua_cleanup.()
