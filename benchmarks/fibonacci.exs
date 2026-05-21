# Run with: mix run benchmarks/fibonacci.exs
#
# Benchmarks recursive Fibonacci (fib(30)) across:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua 5.4 development headers and a small in-tree
# patch (its 1.6.3 release defaults to LuaJIT and uses LUA_GLOBALSINDEX which
# was removed in Lua 5.2). On macOS:
#   brew install lua@5.4
#   ./benchmarks/setup_luaport.sh           # idempotent; patches + builds
#   MIX_ENV=benchmark mix run benchmarks/fibonacci.exs
# If luaport fails to start, the benchmark prints a notice and skips it.

Code.require_file("helpers.exs", __DIR__)

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
  Bench.opts()
)

c_lua_cleanup.()
