# Run with: mix run benchmarks/patterns.exs
#
# Benchmarks Lua's string-pattern engine — the part of the string library that
# compiles and matches Lua patterns, as opposed to the byte-copying and
# formatting paths covered by string_ops.exs / string_format.exs.
#
#   - scan:   repeated `string.find` + `string.match` over one log line. Drives
#             character classes (%a, %d, %w), quantifiers, escaped magic
#             characters (%[ %]) and single-capture extraction. This is the
#             shape of nearly every "pull fields out of a line" script.
#   - split:  tokenises a comma-separated list with `string.find(s, "[^,]+", pos)`
#             advanced by an explicit init offset. Exercises the anchor-free
#             restart path — the matcher is re-entered once per token with a
#             fresh start position.
#   - gsub:   template substitution in three passes: `%${(%w+)}` with a table
#             replacement, `%s+` whitespace squeezing with a string
#             replacement, and `(%a+)` with a *function* replacement. Covers
#             all three gsub replacement kinds plus capture-driven lookup.
#
# `split` deliberately uses `string.find` with an init offset rather than
# `string.gmatch`: `gmatch` raises `badarg` in Luerl 1.5.x, so a gmatch-based
# tokeniser could not be measured against the Luerl reference on the same Lua
# source. Keeping the source identical across VMs is the fairness contract of
# this suite, so the iterator-free idiom is used instead.
#
# Each workload runs n=200 pattern-heavy iterations per invocation so the
# per-match cost is visible above harness overhead.
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
#   MIX_ENV=benchmark mix run benchmarks/patterns.exs
# If luaport fails to start, the benchmark prints a notice and skips it.
#
# Run modes (see benchmarks/helpers.exs):
#   default                — quick mode (~4 s per Benchee.run)
#   LUA_BENCH_MODE=full    — long windows + memory_time, for publishable numbers

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

pattern_def = """
local LOG = "2024-05-01 12:34:56 [warn] request_id=a1b2c3 latency=42ms status=503 path=/api/v1/items"

-- Field extraction: an escaped-magic-character find plus three captures.
function run_scan(n)
  local hits = 0
  for i = 1, n do
    local s, e = string.find(LOG, "%[%a+%]")
    if s then hits = hits + (e - s) end
    local status = string.match(LOG, "status=(%d+)")
    local id = string.match(LOG, "request_id=(%w+)")
    local lat = string.match(LOG, "latency=(%d+)ms")
    if status and id and lat then hits = hits + #status + #id + #lat end
  end
  return hits
end

local CSV = "alpha,beta,gamma,delta,epsilon,zeta,eta,theta,iota,kappa"

-- Tokenise by re-entering the matcher at an advancing init offset.
function run_split(n)
  local total = 0
  for i = 1, n do
    local pos = 1
    while true do
      local s, e = string.find(CSV, "[^,]+", pos)
      if not s then break end
      total = total + (e - s + 1)
      pos = e + 1
    end
  end
  return total
end

local TEMPLATE = "Hello   ${name}, you have ${count} new ${kind} since ${when}.  Visit ${url} for details."
local VALUES = { name = "Ada", count = "7", kind = "messages", when = "Tuesday", url = "/inbox" }

-- All three gsub replacement kinds: table, string, function.
function run_gsub(n)
  local last = ""
  for i = 1, n do
    local filled = string.gsub(TEMPLATE, "%${(%w+)}", VALUES)
    local squeezed = string.gsub(filled, "%s+", " ")
    last = string.gsub(squeezed, "(%a+)", function(w) return w end)
  end
  return #last
end
"""

call_scan = "return run_scan(200)"
call_split = "return run_split(200)"
call_gsub = "return run_gsub(200)"

# --- This Lua implementation ---
# The state returned by `load_chunk!/2` is threaded through each call rather
# than discarded: a loaded chunk may be a reference *into* the state it was
# loaded against, so dropping that state can invalidate the chunk. Threading it
# is correct on every release and costs nothing.
lua = Lua.new()
{_, lua} = Lua.eval!(lua, pattern_def)
{scan_chunk, lua} = Lua.load_chunk!(lua, call_scan)
{split_chunk, lua} = Lua.load_chunk!(lua, call_split)
{gsub_chunk, lua} = Lua.load_chunk!(lua, call_gsub)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(pattern_def, luerl_state)

# --- C Lua via luaport (optional) ---
{c_lua, c_lua_cleanup} =
  case Application.ensure_all_started(:luaport) do
    {:ok, _} ->
      scripts_dir = Path.join(__DIR__, "scripts")
      {:ok, port_pid, _} = :luaport.spawn(:pattern_bench, to_charlist(scripts_dir))
      :luaport.load(port_pid, pattern_def)

      {
        fn func -> %{"C Lua (luaport)" => fn -> :luaport.call(port_pid, func, [200]) end} end,
        fn -> :luaport.despawn(:pattern_bench) end
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

bench.("patterns: find/match field extraction (n=200)", call_scan, scan_chunk, :run_scan)
bench.("patterns: find-based tokenizer (n=200)", call_split, split_chunk, :run_split)
bench.("patterns: gsub template substitution (n=200)", call_gsub, gsub_chunk, :run_gsub)

c_lua_cleanup.()
