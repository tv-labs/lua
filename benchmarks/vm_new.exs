# Run with: mix run benchmarks/vm_new.exs
#
# Benchmarks VM instantiation — `Lua.new/1` — the cost an embedding host pays
# before a single line of Lua runs. Hosts that build a fresh sandbox per
# request (the recommended isolation model) pay this on every request, so it
# sits directly in the request path and is worth measuring separately from
# script execution.
#
# Three instantiation shapes are measured, chosen because all three are valid
# on every release of this library (`:sandboxed` and `:exclude` are the only
# `new/1` options that exist across the whole history; the limit options
# `:max_call_depth` / `:max_string_bytes` / `:max_instructions` / `:debug` are
# newer and would raise on older releases):
#
#   - new                  — `Lua.new()`. The default deny-list sandbox. This is
#                            what >90% of embedders call.
#   - new, no sandbox      — `Lua.new(sandboxed: [])`. Standard library
#                            installed, zero sandbox passes. This is the closest
#                            like-for-like analogue of a bare `:luerl.init()`,
#                            which also performs no sandboxing — compare the
#                            luerl row against *this* row, not against `new`.
#   - new, custom exclude  — `Lua.new(exclude: [[:require]])`. The default
#                            deny-list minus one entry. Represents "I want the
#                            sandbox but need one thing back", and on releases
#                            that memoize instantiation it is the shape that
#                            still pays a per-call sandbox pass.
#
# ---------------------------------------------------------------------------
# Cold vs steady state
# ---------------------------------------------------------------------------
# Newer releases memoize the boot-time VM template in `:persistent_term`,
# written once per node. That makes the *first* `Lua.new()` on a node more
# expensive than every subsequent one, so a benchmark could mislead in either
# direction: measuring only the first call would report a cost no real
# workload repeats, while reporting only the steady state would hide a
# one-time cost that does exist.
#
# Both are therefore reported. The script prints an explicitly-labelled cold
# and second-call timing for `Lua.new()` before Benchee starts — taken as the
# very first thing that touches the library, so nothing has warmed the cache —
# and then Benchee measures steady state, which is what a host serving its
# second and subsequent request sees. On releases with no memoization the two
# figures converge, which is itself the interesting signal.
#
# The cold figure is an upper bound: under `mix run` it also absorbs first-time
# code loading of the stdlib modules, which a release has already done at boot.
#
# Note also that `mix run` puts the VM in `:interactive` code-loading mode.
# Releases run `:embedded`, where a memoizing implementation can skip the
# module-reload staleness check a cache hit otherwise performs — so the steady
# state measured here is, if anything, pessimistic relative to production.
#
# Compares:
#   - This Lua implementation (three instantiation shapes)
#   - Luerl (`:luerl.init/0`, the Erlang-based Lua 5.3 implementation)
#
# There is no C Lua row: `:luaport` instantiation means spawning an OS process
# and handshaking over a port, which measures process spawn and IPC rather than
# VM construction. The two numbers would not mean the same thing.
#
# Run modes (see benchmarks/helpers.exs):
#   default                — quick mode (~4 s per Benchee.run)
#   LUA_BENCH_MODE=full    — long windows + memory_time, for publishable numbers

Code.require_file("helpers.exs", __DIR__)

Application.ensure_all_started(:luerl)

Bench.banner("VM instantiation: Lua.new/1 vs :luerl.init/0")

# Taken before anything else touches the library, so this really is the cold
# path — on a memoizing release it is the call that populates the template.
{cold_us, _} = :timer.tc(fn -> Lua.new() end)
{second_us, _} = :timer.tc(fn -> Lua.new() end)

IO.puts("""
Lua.new() one-time vs repeat cost (single samples, informational):
  first call on this node : #{:erlang.float_to_binary(cold_us / 1, decimals: 1)} us
  second call             : #{:erlang.float_to_binary(second_us / 1, decimals: 1)} us

The first figure includes any one-time template build and first-time module
loading. Benchee's steady-state numbers below are the per-request cost after
that point.
""")

Benchee.run(
  %{
    "lua (new)" => fn -> Lua.new() end,
    "lua (new, no sandbox)" => fn -> Lua.new(sandboxed: []) end,
    "lua (new, custom exclude)" => fn -> Lua.new(exclude: [[:require]]) end,
    "luerl (init)" => fn -> :luerl.init() end
  },
  Bench.opts()
)
