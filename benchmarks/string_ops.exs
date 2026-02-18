# Run with: mix run benchmarks/string_ops.exs
#
# Benchmarks string operations:
#   - table.concat: builds 100 string parts in a table then joins them
#   - string.format: formats 100 strings with integer and float values
#
# Compares:
#   - This Lua implementation (eval with string, eval with pre-compiled chunk)
#   - Luerl (Erlang-based Lua 5.3 implementation)
#   - C Lua 5.4 via luaport (port-based; results include IPC overhead)
#
# NOTE: luaport requires C Lua development headers. On macOS with Homebrew:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix deps.compile luaport
# Then run:
#   PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig mix run benchmarks/string_ops.exs

Application.ensure_all_started(:luerl)

string_def = """
function run_concat(n)
  local parts = {}
  for i = 1, n do
    parts[i] = tostring(i)
  end
  return table.concat(parts, ", ")
end

function run_format(n)
  local parts = {}
  for i = 1, n do
    parts[i] = string.format("item_%d=%f", i, i * 1.5)
  end
  return table.concat(parts, "\\n")
end
"""

call_concat = "return run_concat(100)"
call_format = "return run_format(100)"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, string_def)
{concat_chunk, _} = Lua.load_chunk!(lua, call_concat)
{format_chunk, _} = Lua.load_chunk!(lua, call_format)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(string_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua_concat, c_lua_format, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:string_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, string_def)

      concat = %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, :run_concat, [100]) end}
      format = %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, :run_format, [100]) end}

      {concat, format, fn -> :luaport.despawn(:string_bench) end}

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {%{}, %{}, fn -> :ok end}
  end

IO.puts("\n=== String Concatenation via table.concat (n=100) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_concat) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, concat_chunk) end,
      "luerl" => fn -> :luerl.do(call_concat, luerl_state) end
    },
    c_lua_concat
  ),
  time: 10,
  warmup: 2,
  memory_time: 1
)

IO.puts("\n=== String Formatting via string.format (n=100) ===\n")

Benchee.run(
  Map.merge(
    %{
      "lua (eval)" => fn -> Lua.eval!(lua, call_format) end,
      "lua (chunk)" => fn -> Lua.eval!(lua, format_chunk) end,
      "luerl" => fn -> :luerl.do(call_format, luerl_state) end
    },
    c_lua_format
  ),
  time: 10,
  warmup: 2,
  memory_time: 1
)

c_lua_cleanup.()
