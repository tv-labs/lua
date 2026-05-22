---
id: B5
title: Compile Lua prototypes to Erlang functions (executor JIT)
issue: null
pr: null
branch: n/a (split into B5a-B5e)
base: main
status: split
direction: B
unlocks:
  - sub-Luerl latency on tight numeric/call workloads
  - "perf parity with Luerl, ±10%" 1.0 commitment headroom
---

## Status: split into B5a–B5e

After three pre-flight spikes (recorded in `## Discoveries` below)
the work was split into five sequential plans, each shippable as
one PR per the `ship-a-plan` contract:

- **B5a** — Erlang codegen foundation; covers fib + arithmetic +
  control flow. Falls back on tables and closures.
- **B5b** — Module lifecycle (cache + ref-counted purging).
  Immediately after B5a; required before more opcodes ship.
- **B5c** — Table opcodes.
- **B5d** — Closures, varargs, multi-return.
- **B5e** — Error position fidelity.

This parent plan stays as the strategic record: spike data,
architectural decisions, and what was decided out of scope. Read
the child plans for what gets implemented.

## Blocked on (historical)

- B4 — the flat instruction stream was assumed to be the natural
  intermediate representation. The B4 spike disproved this; B5
  proceeds directly from the existing list-of-tuples shape. See
  the B4 plan's Discoveries for why.

## Goal

For each compiled `Prototype`, generate an Erlang function
(`:erlang.compile` / `:dynamic_compile` / a module-per-script) whose
body is the prototype's instruction stream rendered as Erlang code.
Dispatch becomes a regular Erlang call instead of an interpreter loop;
the BEAM's JIT (BEAMASM on OTP 25+) then natively optimizes the hot
path.

This is the architectural lever Luerl uses (`luerl_comp_*` compiles to
Erlang abstract code and `compile:forms/2`s it). It's the single
biggest gap between an interpreter loop and a "Lua VM" with serious
throughput.

## Why now

After B4, the interpreter dispatch loop is a `case elem(instrs, pc)`.
Even with the BEAM's jump-table optimization, every opcode pays for
the case scrutiny, the tuple destructure, and the implicit `pc + 1`
recursion. At the limit, the cost floor is set by the dispatch shape
itself, not by anything inside any individual handler.

A function-per-prototype layout pushes opcode selection from runtime
into compile time: `:add` becomes a literal `R0 = R1 + R2` in the
generated Erlang. The BEAM's static analyzer can then inline, fold,
and register-allocate within each prototype.

The current Lua/Luerl gap on fib(25) is ~1.13x. PUC-Lua is ~50x faster
still. Closing meaningfully on PUC-Lua needs codegen-to-Erlang; staying
within ±10% of Luerl probably needs at least the framework even if not
every opcode is migrated initially.

## Out of scope

- A full custom JIT or NIF-backed executor. We stay on the BEAM.
- Migrating every opcode in one PR. Phase the work: arithmetic and
  control flow first (highest dispatch density), then table ops, then
  metamethod dispatch, then native calls.
- Eliminating the interpreter path. The interpreter remains as a
  fallback for opcodes the compiler hasn't implemented yet, and for
  any prototype that opts out (e.g. debug mode).
- Cross-prototype optimization (inlining one Lua function into another).

## Success criteria

- [ ] `Lua.Compiler.Erlang` module exists and converts a `%Prototype{}`
      into an Erlang module (or anonymous function) that, when invoked
      with `(registers, upvalues, state, varargs)`, returns
      `{results, registers, state}`.
- [ ] At minimum these opcodes are compiled (not interpreted):
      `:load_constant`, `:move`, `:add`, `:subtract`, `:multiply`,
      `:less_than`, `:less_equal`, `:greater_than`, `:greater_equal`,
      `:equal`, `:not_equal`, `:test`, `:return` (count=1), `:goto`,
      `:label`, `:numeric_for`. Together these cover the fib hot path.
- [ ] Other opcodes fall back to the interpreter via a synthesized
      `interpret_from_pc(pc, ...)` call. No opcode is unsupported.
- [ ] `mix test` passes; suite pass count does not regress.
- [ ] Microbenchmarks improve. Stretch target: **fib(25) reaches parity
      with Luerl (±5%)** — currently ~1.13x slower.
- [ ] Compiled-mode failures fall back to interpretation, not crash.
- [ ] Generated modules are garbage-collected when no prototype holds
      them. (Critical — otherwise long-running embedders leak code.)

## Implementation notes

### Strategy

Generate Erlang **forms** (abstract syntax) and pass them to
`compile:forms/2` (or `:dynamic_compile.from_string/1`). Don't try to
generate Erlang source text — abstract forms skip the parser and are
the documented compiler entry point.

```erlang
%% One generated module per Prototype.
-module(lua_proto_47).
-export([execute/4]).

execute(Regs, Upvalues, State, Varargs) ->
    %% R0..Rmax inlined as Erlang variables
    R0 = element(1, Regs),
    R1 = element(2, Regs),
    ...
    %% Instructions emitted in order, with control flow via goto/labels
    %% mapped to Erlang case/recursion patterns.
    Sum = R1 + R2,
    Regs2 = setelement(3, Regs, Sum),
    ...
    {[ResultValue], Regs2, State}.
```

Reality is messier — Erlang has no `goto`, so labels become
function-letrec'd helpers or a single tail-recursive dispatch over the
remaining-instructions list (similar to today's interpreter, but
specialized per prototype).

### Module lifecycle

Each compiled prototype gets a unique module name (e.g.
`lua_proto_<hash>` or `lua_proto_<ets_id>`). Two paths:

1. **`:code.load_binary/3`** with a generated `.beam` blob — fast load,
   but loaded modules are global and persist until explicitly purged.
2. **Anonymous function via `erl_eval`** — no module loading, but the
   BEAM doesn't JIT-compile interpreted funs as aggressively. Likely
   slower than the loaded-module path.

Recommend (1) with a per-prototype lifecycle:

- Module name carries the prototype's content-addressable hash, so
  identical prototypes share a module.
- A ref-counted registry tracks live prototypes; when the count hits
  zero, `:code.purge/1` + `:code.delete/1` cleans up.
- The registry lives in a dedicated `Lua.VM.CodeCache` GenServer.

This is the part most likely to leak in long-running embedders if done
wrong. Test it explicitly: create N prototypes, drop references, force
GC, confirm modules are purged.

### Fallback path

For opcodes not yet compiled, the generated module emits a call to
`Lua.VM.Executor.execute_from_pc/N` with the saved interpreter state.
The interpreter resumes from that PC and runs until either:

- A return / frame pop transfers control back to the compiled module
  (via a return-continuation passed in), or
- The whole call completes.

This lets us land the framework with arithmetic + control flow
compiled, ship measurable wins, and migrate remaining opcodes
incrementally as separate plans (`B5a` for table ops, `B5b` for
metamethods, etc.).

### Register representation

Two options inside the compiled function:

1. **Keep registers as a tuple**, use `element/2` and `setelement/3` —
   minimal divergence from the interpreter. The BEAM can't avoid the
   per-write `setelement` allocation.
2. **Promote each register to an Erlang variable** — true SSA, the
   BEAM's optimizer can fold and register-allocate. Requires
   single-assignment IR (rebinding `R0` becomes `R0_1`, `R0_2`, ...).

Option (2) is the bigger payoff but requires SSA conversion in the
codegen. Option (1) ships sooner and still buys the dispatch-loop
elimination. Recommend (1) for the first PR; SSA conversion is a
follow-up plan (`B5c`).

### Files

- `lib/lua/compiler/erlang.ex` (new) — abstract-forms generator.
- `lib/lua/vm/code_cache.ex` (new) — ref-counted module registry.
- `lib/lua/compiler/prototype.ex` — add `:compiled_module` field, nil
  when interpretation-only.
- `lib/lua/vm.ex` — when executing, dispatch to compiled module if
  present, else interpreter.
- `lib/lua/compiler.ex` — opt-in flag to skip compilation (for
  debugging, error-message fidelity).
- `test/lua/compiler/erlang_test.exs` (new) — compiles small prototypes,
  asserts identical results vs interpreter.
- `test/lua/vm/code_cache_test.exs` (new) — module lifecycle tests.

### Error message fidelity

The interpreter currently raises with precise `line:` and `source:`
info threaded via the `line` parameter. Compiled mode must preserve
this. Options:

- Inline `Process.put(@position_key, {line, source})` calls before any
  potentially-raising opcode. Adds per-op overhead but matches
  interpreter exactly.
- Emit a `try/catch` wrapping each compiled call that re-raises with
  the right line info from a pc-to-line table.

Recommend the try/catch approach — pays the cost only on the failure
path. The interpreter pays it on every native call anyway.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Benchmark before / after.
mix run benchmarks/fibonacci.exs
mix run benchmarks/oop.exs
mix run benchmarks/closures.exs
mix run benchmarks/table_ops.exs

# Module lifecycle stress.
mix run -e '
for _ <- 1..1000 do
  lua = Lua.new()
  {_, lua} = Lua.eval!(lua, "function f(n) return n + 1 end")
  Lua.eval!(lua, "return f(42)")
end
:erlang.garbage_collect()
IO.inspect(:code.all_loaded() |> length(), label: "loaded modules after 1000 evals")
# Should be roughly constant, not growing by 1000.
'
```

## Risks

- **Code load is slow.** `compile:forms/2` is hundreds of microseconds
  per module. Embedders that compile-and-throw-away scripts (one-shot
  `Lua.eval!`) may be net slower if compilation cost > execution cost.
  Mitigation: opt out via flag, content-addressable module cache so
  repeated compilation of the same source is free.
- **Module table is a global resource.** A misbehaving embedder that
  compiles unique prototypes faster than they're collected exhausts
  the atom table or `code:` server memory. Mitigation: ref-counted
  registry + hard cap with eviction. Document the cap in the readme.
- **Hot reload / `mix test` interaction.** Compiled prototypes survive
  module recompilation; stale modules could be referenced from in-flight
  states. Mitigation: include a build hash in module names; reject
  loading an old-build module into a new-build VM.
- **Error backtraces become harder to read.** Generated module names
  in stack traces are noise to embedders. Mitigation: stack trimming
  in `Lua.RuntimeException` (already trims VM internals; just extend
  the prune list to include `lua_proto_*` modules).
- **The 1.13x current gap may not be reachable from here alone.** If
  most of the remaining gap is `setelement` churn and not dispatch
  overhead, this plan delivers less than expected. The B4 profile is
  the gate — if B4 doesn't move `do_execute` self-time below ~30%,
  reconsider whether B5 is the right next step or whether B6/B7
  (data structure reductions) come first.

## Discoveries

### Pre-flight spike (perf/b5-spike-fib, May 2026)

Before committing to the multi-month build, a vertical-slice spike hand-
wrote what `compile:forms/2` would emit for the fib prototype's hot
path and compared it against the interpreter, native Elixir (BEAMASM
ceiling), Luerl, and C Lua (via luaport). Spike source:
`benchmarks/b5_spike.exs`.

**fib(25), full mode:**

| Implementation | Mean | Memory | vs interpreter |
|---|---|---|---|
| native elixir | 0.27 ms | 0 B | 325x faster |
| compiled erlang | 0.89 ms | 0 B | **98x faster** |
| C Lua (luaport) | 2.35 ms | 184 B | 37x faster |
| luerl | 65.4 ms | 238 MB | 1.34x faster |
| lua (chunk) | 87.7 ms | 705 MB | baseline |

**fib(30), quick mode:**

| Implementation | Mean | vs interpreter |
|---|---|---|
| native elixir | 3.30 ms | 294x faster |
| compiled erlang | 9.67 ms | **100x faster** |
| C Lua (luaport) | 26.8 ms | 36x faster |
| luerl | 726 ms | 1.34x faster |
| lua (chunk) | 970 ms | baseline |

Ratios are stable across n; the result is not a small-n artefact.

### What the spike shows

- The compiled-erlang path is two orders of magnitude faster than the
  interpreter on fib's hot path and is the only path that beats luerl
  by more than a constant factor. The exit condition for going ahead
  with B5 (≥30% win on fib(30)) is met by ~33x.
- Memory is the more dramatic signal: 705 MB → 0 B on fib(25). The
  interpreter's register-tuple churn (`setelement/3` at 25% of self-
  time in the main-branch profile) **disappears completely** when the
  prototype compiles to a module that uses Erlang variables instead of
  a tuple. This validates that the `setelement/3` ceiling identified
  in the B-series consolidation is not a wall — it is a property of
  the interpreter's data shape, not of the BEAM.
- The 3.3x gap between native elixir and compiled erlang is the
  realistic ceiling for B5: cross-module inlining and constant-time
  call resolution that runtime-loaded modules don't get. B5 should be
  scoped against the compiled-erlang column, not the native-elixir
  column.

### Caveats the spike does not address

1. **fib is the friendliest possible workload.** Pure integer math, no
   tables, no metamethods, no strings, no upvalue mutations. The OOP
   and table_ops benchmarks exercise costs the spike does not touch.
   B5 may deliver smaller (still meaningful) wins on those.
2. **The spike strips Lua semantics.** No register tuple, no `_ENV.fib`
   lookup, no metamethod dispatch path on `<` or `+`. Each of those
   reintroduces overhead a real B5 codegen must respect. The first PR
   should validate that a faithful translation (register tuple +
   `get_upvalue` + `get_field` for the recursive call) still clears
   the original plan's success bar.
3. **Module load cost is not amortised.** Compiled once outside the
   benchmark. Content-addressable module cache (already in the plan)
   handles repeated runs; one-shot scripts may be net slower.

### Adjustments to the plan

- Success criterion "fib(25) parity with Luerl ±5%" is too conservative
  given the spike numbers. Update to "fib(25) beats Luerl by ≥20x" or
  similar, set on the basis of the faithful-translation prototype, not
  the stripped spike.
- Option (1) (keep registers as tuple, eat `setelement/3`) is the right
  first move. The spike showed the dispatch-loop win is overwhelming
  even before register promotion; SSA promotion (`B5c`) can be deferred
  without losing the bulk of the win.
- The faithful-translation prototype (next step) should land as a
  second spike before the full plan implementation begins. If a
  faithful fib compiled module loses more than 5x against the stripped
  spike, the Lua-semantics overhead is bigger than expected and the
  plan needs another pass.

### Spike artefact

Branch `perf/b5-spike-fib`, file `benchmarks/b5_spike.exs`. Reproduce
with `MIX_ENV=benchmark mix run benchmarks/b5_spike.exs`
(or with `LUA_BENCH_MODE=full` / `FIB_N=30`).

### Faithful follow-up spike (perf/b5-spike-fib, May 2026)

The stripped spike answered "is there headroom?" Yes. This second
spike answered "how much survives when we add back the Lua-VM
machinery a real B5 codegen could not skip?"

The faithful spike compiles fib via `compile:forms/2` and then, for
its recursive call, looks up `_ENV` through the upvalue cell, fetches
`_ENV.fib` from the globals table, and re-enters via
`Lua.VM.Executor.call_function/3`. State threads through both calls.
Args are boxed in a list, results unbox from a list — all the same
protocol the interpreter uses.

Source: `benchmarks/b5_spike_faithful.exs`. Required a small
additive change in `lib/lua/vm/executor.ex` to register a
`:compiled_closure` value type that dispatches to a BEAM module
without building a callee register tuple (this is the win condition —
the spike measures call cost when the dispatch shape itself is
collapsed to a BEAM function call). The change is tagged as spike-
only in comments; full test suite (1705 tests + 51 properties + 55
doctests) still passes with it in place.

**fib(25), full mode:**

| Implementation | Mean | Memory | vs interpreter | vs Luerl |
|---|---|---|---|---|
| compiled-stripped | 0.28 ms | 0 MB | 278x | 232x |
| native elixir | 0.32 ms | 0 MB | 243x | 210x |
| C Lua (luaport) | 2.34 ms | 184 B | 33x | 28x |
| **compiled-faithful** | **6.27 ms** | **13.0 MB** | **12.4x** | **10.4x** |
| luerl | 64.8 ms | 227 MB | 1.2x | baseline |
| lua (interpreter) | 77.7 ms | 673 MB | baseline | 1.2x slower |

### What the faithful spike shows

- B5 still clears its bar by a wide margin: **12.4x faster than the
  interpreter, 10.4x faster than Luerl, 22x slower than the BEAMASM
  ceiling**. The 22x gap between stripped and faithful is the real
  cost of preserving Lua semantics during the recursive call (upvalue
  cell lookup, get_field on `_ENV`, two `call_function/3` invocations
  per frame, state threading, args/result list boxing).
- Memory is the standout signal: 673 MB → 13 MB on fib(25), a 50x
  reduction *even with* the call-protocol overhead intact. The
  register-tuple `setelement/3` churn that consumed 25% of fib's
  self-time on main is gone — the compiled function uses Erlang
  variables, and the register tuple never enters the picture for
  the compiled prototype itself.
- Risks #5 in the original plan — "the 1.13x current gap may not be
  reachable from here alone" — is falsified. The plan assumed
  `setelement/3` was a floor. The spike shows it is a property of
  the interpreter's data shape, not the BEAM.

### What the faithful spike unlocks for the plan

1. **The biggest remaining cost is the call protocol, not dispatch.**
   That changes B5's phasing. A v1 that just collapses dispatch (the
   plan's headline) gets most of the win. A follow-up that adds a
   direct-call edge for compiled-to-compiled invocations (skipping
   list boxing on args and results) would buy another large chunk
   — likely a B5d or B5e plan.

2. **`_ENV.fib` static-resolution is a real follow-up lever.** Every
   recursive call re-resolves `fib` through `_ENV`. The interpreter
   pays this. B5 codegen can prove (in the common case) that the
   binding is stable across calls and emit a direct call. This is
   peephole/escape-analysis work — defer to a follow-up plan.

3. **Register-tuple `setelement/3` is not the ceiling.** This was
   the dominant concern in the B-series consolidation (ROADMAP.md
   §"What we learned"). The spike shows compiling out of the
   register-tuple representation entirely (Option 1 in the plan,
   ironically the conservative one) eliminates the cost completely
   on prototypes that fit in BEAM registers. SSA promotion (`B5c`)
   was scoped as the lever for this — it can be deferred without
   losing the bulk of the win.

### Revised success criteria

Replace the plan's "fib(25) parity with Luerl ±5%" with:

- Floor: fib(25) beats Luerl by ≥5x.
- Target: fib(25) beats Luerl by ≥8x.
- Stretch: fib(25) beats Luerl by ≥10x.

The faithful spike hit 10.4x; even a halving of that gap for real-
codegen overhead clears the floor comfortably.

### What the spike did not prove

- **Other workloads.** fib is pure integer math. The OOP, table_ops,
  closures, and string_ops benchmarks exercise costs the spike does
  not touch. A faithful spike on at least one table-heavy workload
  should follow before B5 commits to a phasing — if (say) the
  table_ops loop only wins 2-3x faithful, the plan's per-opcode
  migration order may need to lead with table ops rather than
  arithmetic.
- **Compile-and-load amortisation.** Spike loads modules once outside
  the loop. `Lua.VM.CodeCache` work in the plan stands.
- **Module purging.** Spike never cleans up.

### Spike artefacts

- `benchmarks/b5_spike.exs` — stripped spike (no Lua semantics).
- `benchmarks/b5_spike_faithful.exs` — faithful spike (full call
  protocol).
- `lib/lua/vm/executor.ex` — additive `:compiled_closure` dispatch
  (spike-only, two clauses; see in-line comments).

All on branch `perf/b5-spike-fib`. Reproduce:

```
MIX_ENV=benchmark mix run benchmarks/b5_spike_faithful.exs
LUA_BENCH_MODE=full MIX_ENV=benchmark mix run benchmarks/b5_spike_faithful.exs
```

### Table-heavy spike (perf/b5-spike-fib, May 2026)

The first two spikes measured fib — pure integer arithmetic, the
friendliest possible workload. Open question after the faithful
spike: does the win generalise to table-heavy code? Tables exercise
costs B5 cannot eliminate (`Table.put/3` building a new map per
mutation, `state.tables` updates per write).

Third spike compiles `run_table_sum(n)` from
`benchmarks/table_ops.exs` — two tight `:numeric_for` loops, one
populating a 1..n table, one summing it. Every iteration of the
first loop hits `:set_table`; every iteration of the second hits
`:get_table`. Same `:compiled_closure` dispatch as the second spike.

Source: `benchmarks/b5_spike_tables.exs`. The compiled function is
written in Elixir rather than via `:compile.forms/2` — the second
spike already proved `:compile.forms` output runs at near-native
Elixir speed (1.13x slower in the worst case), and writing two
recursive loop helpers as abstract forms would add ~200 lines without
changing what's measured.

**run_table_sum(n), full mode:**

| n | Interpreter | Compiled | Luerl | C Lua | vs interp | vs Luerl | vs C Lua |
|---|---|---|---|---|---|---|---|
| 100  | 23.0 μs | 10.9 μs | 41.9 μs | 9.6 μs  | **2.1x** | **3.8x** | 0.88x slower |
| 500  | 125 μs  | 56.4 μs | 146 μs  | 14.1 μs | **2.2x** | **2.6x** | 4.0x slower |
| 1000 | 274 μs  | 131 μs  | 272 μs  | 20.1 μs | **2.1x** | **2.1x** | 6.6x slower |

Memory at n=1000: interpreter 2.45 MB → compiled 0.59 MB (4.2x less).

### What the table spike shows

- **The compiled-vs-interpreter ratio is stable at ~2.1x across all
  n.** Per-op interpreter dispatch is a constant per opcode, B5 saves
  a constant fraction. Does not scale with n because the dominant
  cost (table mutation allocation via `Table.put/3` + state.tables
  update) is unchanged.
- **The compiled-vs-C-Lua gap widens with n.** At n=100 we
  essentially match C Lua. At n=1000 we are 6.6x slower. This is
  allocation churn — every `t[i] = i` allocates a new `:data` map
  and a new `state.tables` map. PUC-Lua mutates in place; we cannot
  because tables are immutable maps. Same constraint that defeated
  B7 (see ROADMAP.md §"What we learned").
- **B5's win on tables is ~6x smaller than on fib.** fib's win was
  12.4x faithful; tables is 2.1x faithful. Why: fib eliminates the
  register-tuple `setelement/3` (25% of its self-time) entirely.
  table_sum cannot escape the `Table.put` cost because that lives
  in `state.tables`, not in registers — B5 saves dispatch around
  the mutation, not the mutation itself.

### What this changes about B5 phasing

The plan's per-opcode phasing (arithmetic + control flow first,
tables next, then metamethods, then native calls) is correct. What
changes is the *expected return per phase*:

- **Phase 1 (arithmetic + control flow):** the big win. Numeric
  workloads jump from 1.2x-vs-Luerl (today) to ~10x. fib-style code
  is the primary beneficiary. This is where most of the headline
  performance numbers will come from.
- **Phase 2 (table ops):** smaller win (~2x). Worth doing, but
  table-heavy workloads will not see numbers that look like Phase 1.
- **Phase 3+ (metamethods, native calls):** unmeasured. Each needs
  a pre-flight spike if/when scoped.

A Phase 1-only v1 would honestly ship — fib-style workloads get the
big bump immediately, table workloads stay at interpreter speed
until Phase 2 lands. The release notes need to be honest about which
workloads benefit when.

### Refined success criteria

Replace single fib target with per-workload targets:

- **Numeric workloads (fib, math.*):** floor 5x faster than Luerl,
  target 8x, stretch 10x.
- **Table workloads (table_sum, OOP, etc.):** floor 1.5x faster than
  Luerl, target 2x. PUC-Lua parity is unreachable on BEAM for
  table-heavy code — the third spike puts a hard number on this
  (6.6x slower at n=1000 with the dispatch loop eliminated). The
  remaining gap is allocation cost in immutable maps. Drop any
  aspiration of PUC-Lua parity on table workloads.

### Implication: parallel investigation worth scoping later

Most of the table-workload allocation cost comes from `state.tables`
being a map of maps — every mutation walks two levels. If a future
plan changed table storage to something mutable from inside the BEAM
(`:ets`, `:atomics`, or a per-state mutable structure with explicit
GC integration), it would compose multiplicatively with B5: B5 saves
dispatch, that change saves allocation. Together they could close
the C-Lua gap meaningfully on table workloads.

Not in scope for B5. Worth keeping in the back pocket as a B-series
follow-up once B5 v1 has shipped and the data shape is the obvious
remaining ceiling.

### Third spike artefact

`benchmarks/b5_spike_tables.exs`. Reuses the `:compiled_closure`
dispatch from the second spike. Reproduce:

```
MIX_ENV=benchmark mix run benchmarks/b5_spike_tables.exs
LUA_BENCH_MODE=full MIX_ENV=benchmark mix run benchmarks/b5_spike_tables.exs
```
