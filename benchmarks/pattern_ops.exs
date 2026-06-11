# Run with: mix run benchmarks/pattern_ops.exs
#
# Benchmarks the compiled-pattern cache in `Lua.VM.Stdlib.Pattern`. This is
# the harness behind the tuning constants documented in that module — it lets
# a reviewer (or CI) re-validate them rather than trusting prose:
#
#   - @cache_min_len (8): the byte length at or below which a pattern skips
#     the cache and compiles inline. The "compile vs lookup crossover" sweep
#     below measures `compile/1` against a warm `compile_cached/1` hit across
#     pattern lengths bracketing 8, so the crossover is observable on this
#     engine instead of asserted.
#   - @cache_max_entries (512): the hard cap. The "miss stream" workload
#     drives an all-distinct flood far past the cap to show the bounded-write
#     path stays flat (clear-and-restart, never unbounded growth).
#
# Three Lua-level workloads named in the cache commit history, exercised
# through `string.gsub` so the cache sits on the hot path:
#
#   - trivial:   a repeated short pattern ("%d+") that BYPASSES the cache.
#                Confirms the bypass guard keeps trivial patterns off the
#                ETS round-trip (the cache must not regress this).
#   - expensive: a repeated long, branch-heavy pattern (a datetime matcher)
#                that the cache compiles once and reads thereafter — the
#                workload the cache is built to win.
#   - miss:      an all-distinct stream of long patterns, one sighting each,
#                stressing the sentinel + bounded-eviction path.
#
# Compares this Lua implementation against Luerl. (C Lua via luaport is not
# wired up here — pattern compilation is an internal-engine concern, and the
# cache's effect is only visible against our own compile path.)

alias Lua.VM.Stdlib.Pattern

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

# --- Direct compile-vs-cached crossover sweep -------------------------------
#
# Each entry is a pattern of a given byte length. We compare a bare
# `compile/1` against a warmed `compile_cached/1` hit. Below the crossover,
# compile wins (the cache bypasses anyway); above it, the cached hit wins.
crossover_inputs = [
  {"len=2", "%d"},
  {"len=4", "%d%a"},
  {"len=6", "abcdef"},
  {"len=8 (= @cache_min_len)", "abcdefgh"},
  {"len=12", "(%a+)=(%d+)x"},
  {"len=24", "(%a+)=(%d+);(%a+)=(%d+)x"},
  {"len=48", String.duplicate("(%a+)=(%d+);", 4)}
]

Bench.banner("Pattern compile/1 vs warm compile_cached/1 hit (length sweep around @cache_min_len=8)")

for {label, pattern} <- crossover_inputs do
  # Warm the cache so compile_cached measures a steady-state hit, not a miss.
  Pattern.compile_cached(pattern)
  Pattern.compile_cached(pattern)

  IO.puts("\n--- #{label} (#{byte_size(pattern)} bytes) ---")

  Benchee.run(
    %{
      "compile/1 (no cache)" => fn -> Pattern.compile(pattern) end,
      "compile_cached/1 (warm hit)" => fn -> Pattern.compile_cached(pattern) end
    },
    Bench.opts()
  )
end

# --- Lua-level gsub workloads -----------------------------------------------

trivial_def = """
function run_trivial(n)
  local total = 0
  for i = 1, n do
    local s, c = string.gsub("a1b2c3d4e5", "%d+", "#")
    total = total + c
  end
  return total
end
"""

expensive_def = """
function run_expensive(n)
  local total = 0
  for i = 1, n do
    local s, c = string.gsub(
      "2024-06-11 13:45:01 and 1999-12-31 23:59:59",
      "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)",
      "%3/%2/%1"
    )
    total = total + c
  end
  return total
end
"""

# All-distinct miss stream: a fresh, cache-eligible (>8 byte) pattern every
# iteration, so the cache only ever records sentinels and (past the cap)
# exercises the bounded clear-and-restart eviction.
miss_def = """
function run_miss(n)
  local total = 0
  for i = 1, n do
    local pat = "(%a+)_" .. i .. "_(%d+)x"
    local s, c = string.gsub("field_" .. i .. "_42x", pat, "%1=%2")
    total = total + c
  end
  return total
end
"""

defs = trivial_def <> expensive_def <> miss_def

# --- This Lua implementation ---
lua = Lua.new()
{_, lua} = Lua.eval!(lua, defs)

# --- Luerl ---
luerl_state = :luerl.init()
{:ok, _, luerl_state} = :luerl.do(defs, luerl_state)

run = fn name, n ->
  call = "return run_#{name}(#{n})"
  {chunk, _} = Lua.load_chunk!(lua, call)

  Bench.banner("string.gsub — #{name} pattern (n=#{n})")

  Benchee.run(
    %{
      "lua (chunk)" => fn -> Lua.eval!(lua, chunk) end,
      "luerl" => fn -> :luerl.do(call, luerl_state) end
    },
    Bench.opts()
  )
end

run.("trivial", 1000)
run.("expensive", 1000)
# Push the miss stream past @cache_max_entries (512) to exercise eviction.
run.("miss", 1000)
