---
id: B5
title: Compile Lua prototypes to Erlang functions (executor JIT)
issue: null
pr: null
branch: perf/compile-to-erlang
base: main
status: blocked
direction: B
unlocks:
  - sub-Luerl latency on tight numeric/call workloads
  - "perf parity with Luerl, ±10%" 1.0 commitment headroom
---

## Blocked on

- B4 — the flat instruction stream is the natural intermediate
  representation to translate into Erlang. Trying to JIT directly from
  the list-of-tuples shape would mix two structural changes in one PR.

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

(populated during implementation)
