---
id: B5b
title: Module lifecycle — content-addressable cache + ref-counted purging
issue: null
pr: null
branch: perf/erlang-codegen-lifecycle
base: main
status: ready
direction: B
unlocks:
  - B5c (tables) and later phases can ship without compounding the leak
  - Production-safe deployment of the codegen path
---

## Blocked on

- B5a — there's nothing to manage the lifecycle of until the codegen
  is producing modules.

## Goal

Make B5a not leak. Every compiled prototype currently allocates a
fresh `lua_proto_<unique_integer>` module that lives forever in the
BEAM code server. After B5a merges this would saturate the atom
table within hours of real use.

This PR introduces `Lua.VM.CodeCache`, a content-addressable
ref-counted registry. Identical prototypes (same instruction stream,
same upvalue descriptors) share a module. When the last reference
to a compiled prototype drops, the module is purged.

## Why now

B5a ships the codegen with leak-by-design as a known limitation.
The leak is bounded for the integration period (no production
deployment between B5a and B5b) but compounds rapidly the moment a
real user hits the codegen. Every PR that adds opcodes (B5c, B5d)
makes the leak worse because more prototypes are eligible for
compilation. Fix it now, before the surface area grows.

## Out of scope

- Adding more opcodes (B5c, B5d).
- Cross-prototype optimization or whole-program compilation.
- Persistent compilation caches (on-disk). Memory cache only.
- Changes to the codegen output. The cache wraps codegen calls;
  it doesn't rewrite the modules themselves.

## Success criteria

- [ ] `Lua.VM.CodeCache` GenServer exists. Started under
      `Lua.Application` supervision tree.
- [ ] Module names become `lua_proto_<short_content_hash>`. Two
      prototypes with byte-identical instruction streams + upvalue
      descriptors share a module.
- [ ] Per-module ref count tracks live closures referencing it.
      Each `{:compiled_closure, mod, fun, upvalues}` value
      increments on creation, decrements on collection.
- [ ] When ref count reaches zero, the cache schedules
      `:code.purge/1` + `:code.delete/1`. Scheduled, not immediate
      — running code may still be executing the module on another
      scheduler.
- [ ] Hard cap on loaded modules (default 4096, configurable via
      `Lua.Compiler.Erlang.cache_size/0`). LRU eviction when the
      cap is hit.
- [ ] Build hash in module names (`lua_proto_<build>_<content>`).
      A code-server module loaded from a previous build is rejected
      on lookup and recompiled. Prevents stale references across
      `mix test` hot-reload.
- [ ] Stress test: 10,000 unique prototypes compiled and dropped in
      sequence. `:code.all_loaded() |> length()` stays within
      cache_size + a small buffer for the duration.
- [ ] Stress test: 10,000 *identical* prototypes compiled. Only one
      module loaded.
- [ ] `mix test` passes. No regression.
- [ ] No measurable performance regression on
      `mix run benchmarks/fibonacci.exs` — the cache hit path adds
      one ETS lookup per call to `compile`, which should be
      ~hundreds of nanoseconds.

## Implementation notes

### Architecture

- `Lua.VM.CodeCache` is a GenServer holding an ETS table
  (`:lua_code_cache`) plus an LRU access list.
- ETS keyed by `{build_hash, content_hash}` → `{module_name,
  function_name, ref_count, last_accessed}`.
- `Lua.Compiler.Erlang.compile/1` consults the cache before
  invoking `:compile.forms/2`. Cache hit returns the existing
  module; miss compiles, loads, inserts, returns.
- Ref-counting:
  - Increment when a `{:compiled_closure, mod, fun, upvalues}`
    value is created (closure construction, prototype top-level
    compile).
  - Decrement when… (see below — this is the hard part).

### Ref-count decrement strategy

Closures in this codebase are plain Elixir values. They get
garbage-collected by the BEAM with no callback. So "decrement when
collected" cannot be implemented with `:erlang.monitor`.

Two viable approaches:

1. **Periodic GC sweep.** Every N seconds, walk every live state's
   tables, collect the set of referenced `(mod, fun)` pairs, mark
   the cache. Anything not referenced for K sweeps is purged. This
   is what Luerl's equivalent layer does.
2. **Resource tracking via NIF resource.** Wrap the module
   reference in a NIF-allocated resource whose destructor
   decrements the count. Requires a NIF, which we currently don't
   ship.

Recommend (1) for this PR. Simpler, no NIF, doesn't bound when
modules are purged (they linger until the next sweep) but that's
acceptable for the cap-and-LRU policy.

Sweep cadence: every 30 seconds. Configurable.

LRU eviction provides a hard upper bound regardless of sweep
correctness — if the cap is hit, the least-recently-accessed
module is purged immediately, ref-count be damned. This prevents
unbounded growth if the sweep logic has a bug.

### Build hash

`@build_hash` is computed at compile time from the app's
`:application.get_key(:lua, :vsn)` plus a hash of the codegen
module's source. Embedded in module names. On lookup, if the
module's name doesn't match the current build hash, treat as a
miss and recompile. The stale module is purged by the LRU as it
ages out.

This handles two cases:

- Production: a host application doing a rolling deploy may keep
  old compiled modules in memory referenced by older state values
  that survived the upgrade. The new compiled prototypes use new
  module names; the old ones age out.
- Dev: `mix test` recompiles `lib/`. Compiled prototypes from a
  previous test run reference old internal helpers; reject them
  and recompile.

### Content hash

`:erlang.phash2/2` over `{instructions, upvalue_descriptors,
param_count, is_vararg}`. Truncated to 12 hex chars. Collision
probability is negligible at the scales we care about, but we
verify by storing the full pre-hash key alongside the hash in ETS
and asserting equality on lookup.

### Files

- `lib/lua/vm/code_cache.ex` (new) — the GenServer + ETS interface.
- `lib/lua/application.ex` — supervise the new GenServer.
- `lib/lua/compiler/erlang.ex` (modified) — replace the
  unique-integer module naming with `CodeCache.module_for/1`.
- `test/lua/vm/code_cache_test.exs` (new) — the unit tests +
  stress tests listed in Success criteria.

### Edge cases

- **Module name collisions with non-Lua code.** Mitigation: the
  `lua_proto_` prefix is reserved. Document in `Lua.VM.CodeCache`'s
  moduledoc.
- **GenServer crash.** If the cache GenServer dies (shouldn't, but
  defense in depth), the supervisor restarts it with an empty ETS
  table. Every prototype recompiles. Performance penalty, not a
  correctness failure.
- **Cache poisoned by a compile error.** If `:compile.forms/2`
  raises mid-load, the ETS entry must roll back. Use a
  `try`-`rescue` in `CodeCache.handle_call`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/code_cache_test.exs

# Stress test: 10k unique prototypes
mix run -e '
for i <- 1..10_000 do
  src = "function f_#{i}(n) return n + #{i} end f_#{i}(42)"
  {_, _} = Lua.eval!(Lua.new(), src)
end
:erlang.garbage_collect()
Process.sleep(35_000)
count = :code.all_loaded() |> Enum.count(fn {m, _} ->
  to_string(m) |> String.starts_with?("lua_proto_")
end)
IO.puts("loaded after sweep: #{count}")
# Should be ≤ cache_size (default 4096).
'

# Stress test: 10k *identical* prototypes
mix run -e '
src = "function f(n) return n + 1 end f(42)"
for _ <- 1..10_000, do: Lua.eval!(Lua.new(), src)
count = :code.all_loaded() |> Enum.count(fn {m, _} ->
  to_string(m) |> String.starts_with?("lua_proto_")
end)
IO.puts("identical compiles → loaded count: #{count}")
# Should be 1.
'
```

## Risks

- **Sweep cadence vs allocation rate.** If a host app compiles
  faster than the sweep can clean up, the LRU evicts. If the LRU
  evicts a module that's still in use by a long-running state,
  next call into that closure raises (module not found).
  Mitigation: defer LRU eviction of modules with ref_count > 0
  until they age past a hard limit (10x cache_size, say).
  Compromise: under extreme pressure, the cache exceeds the soft
  cap; only when ref counts drop does it shrink. Acceptable
  trade-off — we'd rather use 2x memory than crash.
- **The sweep is O(states × refs).** For a deployment with tens of
  thousands of live Lua states this could be measurable. Profile
  during this PR; if it shows up, partition the sweep across
  cycles or push the work into a dedicated scheduler.
- **`:code.purge/1` blocks if any process is currently executing
  the module on another scheduler.** Use `:code.soft_purge/1`
  first; if that fails, defer to next sweep rather than blocking.
  Document the policy.
- **NIF resource alternative might be necessary post-launch.** If
  the sweep approach proves too imprecise (modules sticking around
  too long, memory pressure), the NIF-resource approach can be a
  later plan. Don't pre-commit to it now.

## Discoveries

(populated during implementation)
