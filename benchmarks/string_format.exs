# Run with: mix run benchmarks/string_format.exs
#
# Benchmarks string.format across format strings whose cost is dominated by
# different things, so the formatter is exercised on more than one axis:
#
#   - long_format:  a long, literal-heavy format string (~430 chars of
#                   literal text around three specifiers). Stresses how the
#                   formatter accumulates literal runs — the dominant cost
#                   here is copying literal bytes, not converting arguments.
#   - width_format: many width-flagged specifiers (%-20s, %8d, %12.4f, %6x),
#                   exercising the width/padding path on every conversion.
#   - many_specs:   a dozen specifiers interleaved with short literal runs,
#                   the conversion-heavy counterpart to long_format.
#
# Each workload formats n=1000 strings per invocation so the per-call cost
# is visible above harness overhead.
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
#   MIX_ENV=benchmark mix run benchmarks/string_format.exs
# If luaport fails to start, the benchmark prints a notice and skips it.

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

string_def = """
-- A long, literal-heavy format string: ~430 chars of literal text wrapped
-- around three specifiers. The literal runs dominate the cost.
local LONG = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, " ..
  "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " ..
  "Ut enim ad minim veniam, quis nostrud exercitation [%d] ullamco " ..
  "laboris nisi ut aliquip ex ea commodo consequat [%s]. Duis aute " ..
  "irure dolor in reprehenderit in voluptate velit esse cillum dolore " ..
  "eu fugiat nulla pariatur [%.3f]. Excepteur sint occaecat cupidatat " ..
  "non proident, sunt in culpa qui officia deserunt mollit anim id est."

function run_long_format(n)
  local last = ""
  for i = 1, n do
    last = string.format(LONG, i, "tag", i * 0.5)
  end
  return #last
end

-- Width-flagged specifiers exercise the padding path on every call.
function run_width_format(n)
  local last = ""
  for i = 1, n do
    last = string.format("[%-20s][%8d][%12.4f][%-15s][%6x]",
      "name", i, i * 1.25, "label", i)
  end
  return #last
end

-- Many specifiers interleaved with short literal runs.
function run_many_specs(n)
  local last = ""
  for i = 1, n do
    last = string.format(
      "a=%d b=%d c=%d d=%s e=%s f=%.2f g=%.2f h=%x i=%x j=%d k=%s l=%d",
      i, i + 1, i + 2, "x", "y", i * 1.5, i * 2.5, i, i + 1, i + 3, "z", i + 4)
  end
  return #last
end
"""

call_long = "return run_long_format(1000)"
call_width = "return run_width_format(1000)"
call_many = "return run_many_specs(1000)"

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, string_def)
{long_chunk, _} = Lua.load_chunk!(lua, call_long)
{width_chunk, _} = Lua.load_chunk!(lua, call_width)
{many_chunk, _} = Lua.load_chunk!(lua, call_many)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(string_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:string_format_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, string_def)

      {
        fn func -> %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, func, [1000]) end} end,
        fn -> :luaport.despawn(:string_format_bench) end
      }

    {:error, reason} ->
      IO.puts("luaport not available (#{inspect(reason)}) — skipping C Lua benchmarks")
      {fn _func -> %{} end, fn -> :ok end}
  end

bench = fn name, call_str, chunk, c_lua_func ->
  Bench.banner(name)

  Benchee.run(
    Map.merge(
      %{
        "lua (eval)" => fn -> Lua.eval!(lua, call_str) end,
        "lua (chunk)" => fn -> Lua.eval!(lua, chunk) end,
        "luerl" => fn -> :luerl.do(call_str, luerl_state) end
      },
      c_lua.(c_lua_func)
    ),
    Bench.opts()
  )
end

bench.("string.format: long literal-heavy format string (n=1000)", call_long, long_chunk, :run_long_format)
bench.("string.format: width-flagged specifiers (n=1000)", call_width, width_chunk, :run_width_format)
bench.("string.format: many specifiers (n=1000)", call_many, many_chunk, :run_many_specs)

c_lua_cleanup.()
