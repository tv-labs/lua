# Run with: mix run benchmarks/fibonacci.exs
#
# Benchmarks recursive Fibonacci (fib(30)) across:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua development headers. On macOS with Homebrew:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix deps.compile luaport
# Then run:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix run benchmarks/fibonacci.exs

Application.ensure_all_started(:luerl)

fib_def = """
function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
"""

call_fib = "return fib(30)"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, fib_def)
{fib_chunk, _} = Lua.load_chunk!(lua, call_fib)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(fib_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_benchmarks, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:fib_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, fib_def)

      benchmarks = %{
        "C Lua (luaport)" => fn -> :luaport.call(port_pid, :fib, [30]) end
      }

      {benchmarks, fn -> :luaport.despawn(:fib_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {%{}, fn -> :ok end}
  end

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_fib) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, fib_chunk) end,
      "luerl" => fn -> :luerl.do(call_fib, luerl_state) end
    },
    c_lua_benchmarks
  ),
  time: 10,
  warmup: 2,
  memory_time: 1
)

c_lua_cleanup.()
