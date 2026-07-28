# Run with: mix run benchmarks/pcall_varargs.exs
#
# Benchmarks the call protocol: protected calls and variadic/multiple-return
# argument handling. Both are pervasive in embedded Lua — host integrations
# routinely wrap every script entry point in `pcall`, and `...`/multiple
# returns are how Lua code passes argument lists around — and neither appears
# in the comparative workloads otherwise.
#
#   - pcall_ok:     n protected calls that all succeed. Isolates the cost of
#                   entering and leaving a protected frame from the cost of
#                   actually raising, which is the common case in production.
#   - pcall_raise:  n protected calls that all raise a string error and are
#                   caught. Drives error-value construction, stack unwinding
#                   and the return of `false, err` to the caller.
#   - varargs:      variadic collection (`select("#", ...)`), positional
#                   variadic access (`select(i, ...)`), variadic forwarding
#                   (`f(...)` in tail position), `table.pack`/`table.unpack`
#                   round-tripping, and multiple-return destructuring
#                   (`local a, b, c = triple(i)`).
#
# Each workload runs n=500 iterations per invocation.
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
#   MIX_ENV=benchmark mix run benchmarks/pcall_varargs.exs
# If luaport fails to start, the benchmark prints a notice and skips it.
#
# Run modes (see benchmarks/helpers.exs):
#   default                — quick mode (~4 s per Benchee.run)
#   LUA_BENCH_MODE=full    — long windows + memory_time, for publishable numbers

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

call_def = """
-- Raises for negative input, returns normally otherwise, so the same callee
-- drives both the success and the error path below.
function classify(v)
  if v < 0 then
    error("negative")
  end
  return v * 2
end

function run_pcall_ok(n)
  local acc = 0
  for i = 1, n do
    local ok, v = pcall(classify, i)
    if ok then acc = acc + v end
  end
  return acc
end

function run_pcall_raise(n)
  local caught = 0
  for i = 1, n do
    local ok, err = pcall(classify, -i)
    if not ok and type(err) == "string" then caught = caught + 1 end
  end
  return caught
end

-- Variadic collection and positional access.
function tally(...)
  local count = select("#", ...)
  local acc = 0
  for i = 1, count do
    acc = acc + select(i, ...)
  end
  return acc, count
end

-- Variadic forwarding in tail position.
function forward(...)
  return tally(...)
end

function triple(i)
  return i, i + 1, i + 2
end

function run_varargs(n)
  local acc = 0
  for i = 1, n do
    local a, b, c = triple(i)
    local sum, count = forward(a, b, c, i, i * 2)
    acc = acc + sum
    local packed = table.pack(a, b, c)
    acc = acc + tally(table.unpack(packed, 1, packed.n))
  end
  return acc
end
"""

call_pcall_ok = "return run_pcall_ok(500)"
call_pcall_raise = "return run_pcall_raise(500)"
call_varargs = "return run_varargs(500)"

# --- This Lua implementation ---
# The state returned by `load_chunk!/2` is threaded through each call rather
# than discarded: a loaded chunk may be a reference *into* the state it was
# loaded against, so dropping that state can invalidate the chunk. Threading it
# is correct on every release and costs nothing.
lua = Lua.new()
{_, lua} = Lua.eval!(lua, call_def)
{pcall_ok_chunk, lua} = Lua.load_chunk!(lua, call_pcall_ok)
{pcall_raise_chunk, lua} = Lua.load_chunk!(lua, call_pcall_raise)
{varargs_chunk, lua} = Lua.load_chunk!(lua, call_varargs)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(call_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:call_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, call_def)

      {
        fn func -> %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, func, [500]) end} end,
        fn -> :luaport.despawn(:call_bench) end
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

bench.("call protocol: pcall, success path (n=500)", call_pcall_ok, pcall_ok_chunk, :run_pcall_ok)
bench.("call protocol: pcall, raise + catch (n=500)", call_pcall_raise, pcall_raise_chunk, :run_pcall_raise)
bench.("call protocol: varargs + multiple returns (n=500)", call_varargs, varargs_chunk, :run_varargs)

c_lua_cleanup.()
