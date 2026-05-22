---
id: B5a
title: Erlang codegen foundation — compile arithmetic + control flow prototypes to BEAM modules
issue: null
pr: 235
branch: perf/erlang-codegen-foundation
base: main
status: review
direction: B
unlocks:
  - B5b (lifecycle), B5c (tables), B5d (closures), B5e (errors)
  - ~10x speedup over Luerl on numeric workloads (fib, math.*)
  - ~2x speedup over Luerl on control-flow-heavy code
---

## Goal

Land the foundation for compiling Lua `%Prototype{}` values to BEAM
modules via `:compile.forms/2`. The compiled module gets dispatched
through a new `:compiled_closure` value type that bypasses the
interpreter's register-tuple construction and per-opcode dispatch
loop entirely.

This first PR covers every opcode **except tables and closures**:
arithmetic, comparison, control flow (including loops and goto),
bitwise ops, string concat/length, source-line tracking, calls,
single-value returns, and upvalue reads (read-only, since closures
ship in B5d). If a prototype contains a table or closure opcode the
whole prototype falls back to the interpreter (all-or-nothing per
prototype — mixed-mode interpret-from-pc is explicitly out of scope).

## Why now

Three pre-flight spikes (recorded under `## Discoveries` in
`.agents/plans/B5-compile-prototypes-to-erlang.md`, branch
`perf/b5-spike-fib`) measured the headroom against today's
interpreter:

- **Stripped fib(25):** 278x faster than interpreter (BEAMASM ceiling).
- **Faithful fib(25):** 12.4x faster than interpreter, 10.4x faster
  than Luerl. Memory 673 MB → 13 MB.
- **Faithful run_table_sum(1000):** 2.1x faster than interpreter,
  2.1x faster than Luerl.

The dispatch-loop hypothesis from the parent plan is confirmed. The
spike branch demonstrated the `:compiled_closure` dispatch shape;
this plan productionises it.

The library is pre-release and there is no flag — every prototype
the codegen can handle goes through compilation. That's the bet.

## Out of scope

- Module lifecycle (cache, ref-counting, purging). Every prototype
  gets a fresh module per compile in this PR. **Leaks. B5b fixes
  this immediately after merge.**
- Tables (`:new_table`, `:get_table`, `:set_table`, `:set_list`,
  `:get_field` full path, `:set_field`). Falls back to interpreter.
  B5c.
- Closures (`:closure`, `:set_upvalue`, `:get_open_upvalue`,
  `:set_open_upvalue`, `:vararg`, `:return_vararg`, `:return` count
  > 1). Falls back to interpreter. B5d.
- Error position fidelity for compiled code (line/source in raise
  sites). B5e.
- Mixed-mode (compiled prototype calls interpreter for one missing
  opcode and resumes). All-or-nothing per prototype.
- SSA / register promotion. Registers stay in a tuple in compiled
  code — same shape as the interpreter. This is the conservative
  option from the parent plan; the spike showed the dispatch win
  alone justifies the work.

## Success criteria

- [ ] `Lua.Compiler.Erlang` module exists and converts a covered
      `%Prototype{}` into Erlang abstract forms.
- [ ] `Lua.VM.CompiledModule` value type exists and is dispatched
      by `Executor.call_function/3` and the `:call` opcode.
      Carries `{:compiled_closure, module_name, function_name,
      upvalues_tuple}`.
- [ ] `Lua.Compiler.compile/1,2` returns prototypes that have been
      compiled to BEAM modules where the codegen accepts them.
      Prototypes containing any uncovered opcode are returned as
      plain interpreted prototypes (current behaviour).
- [ ] Opcode coverage in this PR (everything except tables,
      closures, varargs, multi-return, generic_for, tail_call,
      self):
      `:load_constant`, `:load_boolean`, `:load_nil`, `:move`,
      `:source_line`, `:scope`, `:get_upvalue`, `:get_global`,
      `:set_global`, `:load_env`, `:get_field` (env-lookup form
      only — uses the same fast path as the interpreter's
      `get_field` when reading from an upvalue-loaded register
      holding `_ENV`), `:add`, `:subtract`, `:multiply`, `:divide`,
      `:floor_divide`, `:modulo`, `:power`, `:negate`,
      `:bitwise_and`, `:bitwise_or`, `:bitwise_xor`, `:shift_left`,
      `:shift_right`, `:bitwise_not`, `:less_than`, `:less_equal`,
      `:greater_than`, `:greater_equal`, `:equal`, `:not_equal`,
      `:not`, `:length`, `:concatenate`, `:test`, `:test_true`,
      `:test_and`, `:test_or`, `:goto`, `:label`, `:numeric_for`,
      `:while_loop`, `:repeat_loop`, `:break`, `:call`, `:return`
      (count = 1).
      Out of scope and falling back:
      `:new_table`/`:get_table`/`:set_table`/`:set_list`/
      `:set_field`/non-env-form `:get_field` (→ B5c),
      `:closure`/`:set_upvalue`/`:get_open_upvalue`/
      `:set_open_upvalue`/`:vararg`/`:return_vararg`/
      `:return` count > 1/`:generic_for`/`:self`/`:tail_call`
      (→ B5d).
- [ ] `mix test` passes; 1705 tests + 51 properties + 55 doctests.
- [ ] `mix test --only lua53` does not regress.
- [ ] fib(25) beats Luerl by ≥5x in `mix run benchmarks/fibonacci.exs`.
      Stretch: ≥8x.
- [ ] No workload regresses on the existing benchmark suite by more
      than 5% (within noise).
- [ ] Compiled-mode failures (codegen bugs) fall back gracefully to
      interpretation — never crash. Logged via Logger.warning.

## Implementation notes

### Strategy

`Lua.Compiler.Erlang.compile/1` takes a `%Prototype{}` and returns
either `{:ok, compiled_prototype}` or `:fallback` if any opcode is
uncovered. The codegen walks the instruction stream once, building
Erlang abstract forms, then calls `:compile.forms/2` and
`:code.load_binary/3`.

Module names in this PR: `lua_proto_<unique_integer>`. Real
content-addressable naming and lifecycle is B5b's job. Yes this
leaks; one PR of leak is acceptable for the integration period.

### Codegen shape

The compiled function signature mirrors the spike's faithful path:

```elixir
@spec execute([term()], tuple(), State.t()) ::
        {[term()], State.t()}
def execute(args, upvalues, state) do
  # body
end
```

`args` is the call args as a list (matches `Executor.call_function/3`'s
`:lua_closure` clause). `upvalues` is the upvalue cell-ref tuple
threaded by the caller. `state` threads through.

Inside the function:

- A register variable for each register slot: `R0`, `R1`, …
  Single-assignment Erlang variables. Reassigning `R3` becomes
  `R3_1`, `R3_2`, … using a per-codegen-pass counter.
- The parameters land in `R0..R{param_count-1}` from the args list
  via pattern matching at the function head.
- State is threaded as `State_0`, `State_1`, … through any opcode
  that can mutate it. (`:call` and `:get_global` for upvalue
  resolution can.) Most arithmetic is state-pure.

### Control flow

`:numeric_for`, `:while_loop`, `:repeat_loop` compile to
**recursive Erlang helper functions** inside the generated module.
This is the BEAM-native loop idiom and what `:compile.forms`
produces for any Erlang `case`-based loop. Each loop gets a fresh
helper named `loop_<counter>/N` where N covers the loop variable,
limit, step, and any captured live variables.

`:goto` + `:label` resolve at codegen time to a function call into
a helper. The interpreter's `find_label/2` linear scan is replaced
by a compile-time label-to-helper map.

`:break` becomes an early return from the loop helper.

### Opcode lowering

Each covered opcode lowers to a fixed snippet of Erlang abstract
forms. Strategy:

- **Arithmetic/comparison** that already has integer fast paths in
  the executor (the work from PR #223 et al.): inline a guard
  clause for the integer-integer case, fall through to a helper
  call (`Lua.VM.Numeric.add/2` etc.) for the slow path. This
  preserves the exact semantics the interpreter delivers including
  metamethod dispatch — the helper calls back through
  `Executor.try_binary_metamethod/5`.
- **`:test`**: compile to an Erlang `case` over `Value.truthy?/1`,
  with the two branches inlined as instruction sequences. This is
  why we need control flow first — `:test` is everywhere.
- **`:call`**: dispatch to `Executor.call_function/3`. Args list is
  materialized from the relevant register range; results unbox into
  the right register slots. Pays the same call-protocol cost the
  third spike measured.
- **`:return` count = 1**: returns `{[elem(regs, base)], state}` —
  the standard CPS-frame-pop shape, but since this is the entry
  function not a continuation, it just returns to whoever called
  `Executor.call_function/3`.

### Dispatch wiring

`Lua.VM.Executor.call_function/3` learns a new clause:

```elixir
def call_function({:compiled_closure, mod, fun, upvalues}, args, state) do
  apply(mod, fun, [args, upvalues, state])
end
```

The `:call` opcode dispatch learns the same shortcut: bypass
register-tuple construction, materialize args list, call
`apply(mod, fun, ...)`. This is the spike's `:compiled_closure`
clause promoted to production. The spike already added these
clauses to `lib/lua/vm/executor.ex` on this branch — verify they
stay in place, are properly tested, and are no longer flagged as
"spike-only" in comments.

### Falling back

`Lua.Compiler.compile/2` (the existing entry) is changed to:

```elixir
def compile(source, opts \\ []) do
  proto = existing_compile_path(source, opts)
  case Lua.Compiler.Erlang.compile(proto) do
    {:ok, compiled} -> compiled
    :fallback -> proto
  end
end
```

`Lua.Compiler.Erlang.compile/1` walks the instructions and returns
`:fallback` on the first uncovered opcode. Sub-prototypes (nested
function definitions) recurse; if any sub-prototype falls back, the
parent does too (avoids the mixed-mode complexity of mixing call
shapes between parent and child).

### Where prototypes live after compile

`%Prototype{}` gains a new optional field `compiled_module ::
{atom(), atom()} | nil` — module name and function name. When set,
all execution sites that currently see `{:lua_closure, proto,
upvalues}` use `{:compiled_closure, mod, fun, upvalues}` instead.
The conversion happens at closure-creation time
(`:closure` opcode, `Lua.Compiler.compile_to_closure`, and the
top-level entry in `Lua.VM.execute/2`).

### Files

- `lib/lua/compiler/erlang.ex` (new) — abstract-forms generator.
  Public API: `compile/1`. Internal: per-opcode lowering helpers.
- `lib/lua/compiler/erlang/opcodes.ex` (new) — pure functions mapping
  each covered opcode to its Erlang form. Kept separate so opcode
  tables are easy to extend in later plans.
- `lib/lua/compiler/prototype.ex` — add `compiled_module` field.
- `lib/lua/compiler.ex` — wire the codegen into the public compile
  path. Fallback handling.
- `lib/lua/vm/executor.ex` — add `:compiled_closure` clauses to
  `call_function/3` and the `:call` opcode. Update closure-creation
  sites to emit `:compiled_closure` when `proto.compiled_module` is
  set.
- `lib/lua/vm.ex` — update entry point to dispatch the top-level
  prototype through the compiled module if present.
- `test/lua/compiler/erlang_test.exs` (new) — fixed-input prototype
  golden tests: every covered opcode in isolation, assert compiled
  result == interpreted result.
- `test/lua/compiler/erlang_fallback_test.exs` (new) — every
  uncovered opcode triggers `:fallback`. Sub-prototype fallback
  cascades to parent.

### Error fidelity (placeholder, full fix in B5e)

For this PR: runtime errors raised from compiled code carry the
line at codegen time of the originating opcode (already in the
`:source_line` opcodes). Source filename comes from the prototype.
This is good enough for most tests; B5e adds full position
threading via try/catch.

If a test asserts a specific stack trace shape that the compiled
path breaks, that test moves to an explicit `compiled: false` fixture
override **only after** confirming the assertion is about the
interpreter's stack trace specifically, not user-facing behaviour.
Track any such overrides in `## Discoveries`.

### Benchmarks

The spike benchmarks `benchmarks/b5_spike*.exs` ship as part of
this PR. They serve a dual purpose:

1. **Regression tests for the dispatch shape.** They exercise the
   `:compiled_closure` value type with hand-built modules,
   independent of the codegen. If a later plan breaks the
   dispatch protocol they fail loudly.
2. **Comparison baseline for codegen output.** The faithful spike
   represents what a hand-tuned compile would look like. The real
   codegen running through `Lua.Compiler.Erlang` should be within
   ~2x of the faithful spike on fib. Diverging from that means
   the codegen has room to optimise.

The spikes are kept as `benchmarks/b5_spike{,_faithful,_tables}.exs`
rather than renamed, to make their origin explicit.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# fib parity check (the main success criterion).
LUA_BENCH_MODE=full mix run benchmarks/fibonacci.exs

# Confirm other workloads don't regress.
LUA_BENCH_MODE=full mix run benchmarks/closures.exs
LUA_BENCH_MODE=full mix run benchmarks/oop.exs
LUA_BENCH_MODE=full mix run benchmarks/table_ops.exs
LUA_BENCH_MODE=full mix run benchmarks/string_ops.exs

# Confirm fallback path: every uncovered opcode triggers fallback,
# never a crash. (Tests cover this; this is the manual smoke.)
mix run -e '
{:ok, _, _} = Lua.eval(Lua.new(), "local t = {1,2,3}; return t[2]")
IO.puts("table fallback OK")
'
```

## Risks

- **`compile:forms/2` is slow (hundreds of microseconds per
  module).** For embedders that one-shot `Lua.eval!` of short
  scripts, compilation could be net slower than interpretation.
  Acceptable for this PR — B5b's content-addressable cache makes
  repeated evals of the same source share a module. If the
  one-shot cost is too high in real usage, B5b's cache can be
  extended to memoise by source-hash rather than only prototype-
  hash. Defer the call.
- **The compiled module path differs subtly from the interpreter
  on edge cases.** Float-to-integer coercion, NaN comparisons,
  string-to-number coercion in arithmetic. Mitigation: opcode-by-
  opcode golden tests in `erlang_test.exs` assert byte-for-byte
  result equality with the interpreter on a battery of inputs
  including the nasty corners (NaN, inf, -0.0, max_int + 1, "3" + 2).
- **BEAM atom table pressure.** Every prototype this PR compiles
  creates a unique module name. Run-once embedders that compile
  unique source forever could exhaust the atom table. Concrete
  ceiling: ~1M atoms in default BEAM config. This PR's leak is
  bounded for the integration period because nobody runs production
  for hours between B5a and B5b — but it's a real footgun if B5b
  slips. Mitigation: if B5b takes longer than a week to ship, add
  a hard cap here that disables further compilation past N modules.
- **Module loading is not crash-safe across hot reload.** If `mix
  test` recompiles `lib/` mid-run, compiled prototypes referencing
  old function definitions raise. Mitigation: regenerate prototypes
  at `Application.start/2` boot in the test env, and include the
  application boot hash in the module name. Same approach the plan
  parent (`B5`) calls for in Risks #3.
- **Some interpreter tests will fail by assertion of internal state**
  — e.g. tests that count instruction-list reductions, or compare
  inspectability of a `:lua_closure`. Track these in Discoveries
  and either update the assertion to be representation-agnostic or
  add a fixture override. Should be a small number.

## Discoveries

### Perf reality vs spike — the 5x target was not hit

Spike measured 12.4x faster than interpreter on fib(25). Production
codegen achieves only ~1.4x faster on fib(30) (1.07x vs Luerl). The
gap traces to three sources:

1. **`throw/catch` for non-tail `:return`** — every `:return` inside
   a `:test` branch becomes `throw({:b5_return, _, _})` caught at the
   function entry. Spike fib uses Erlang clause-matching to express
   the base case, so it never throws. Tail-position `:return` is now
   optimised to a natural return, saving roughly half the throws on
   fib (the recursive-case return). Returns inside branches still
   throw — fib hits this on every base-case exit.

2. **`setelement/3` per register write** — 22% of profile time, ~2.2M
   calls for fib(25). Equivalent to the interpreter's register-tuple
   cost; eliminated only by SSA promotion of registers to Erlang
   variables (deferred follow-up).

3. **Slow-path fallback for `apply_arith_op` etc.** — the integer
   fast path is inlined for `:add`/`:subtract`/`:multiply` and
   comparison, but `:divide` and friends always call into Executor.
   For fib all arithmetic stays on the fast path, so this is small.
   `apply_compare_op` is consulted only for `:equal`/`:not_equal`.

### Sub-prototype compile-status cascade

Original B5 plan said "if any sub-prototype falls back, the parent
falls back too." Spike honoured this rule. Real-world Lua almost
always wraps function definitions in chunks that use unsupported
opcodes (`:set_field` for `function f(...) end` writing to `_ENV`).
That cascade made every function compile-eligible code fall back.

Fix: sub-prototypes compile independently. The parent's `:closure`
opcode (interpreter side, since `:closure` itself isn't B5a-covered
yet) checks `nested_proto.compiled_module` and emits either
`{:compiled_closure, ...}` or `{:lua_closure, ...}`. After this
change fib's `function fib(...)` compiles even though the chunk that
defines it doesn't.

### `:compiled_closure` is a 5-tuple, not 4

Initial design: `{:compiled_closure, mod, fun, upvalues}`. Display
needed the prototype back (for source/line/arity metadata). Rather
than carry a separate proto lookup table, the value tuple gained a
5th element holding the source `%Prototype{}`. Execution itself
ignores it; only Display and `debug.getinfo` use it.

### `unsafe_var` lint warning in some `:test` shapes

When a `:test` branch writes a register and the function continues
past the branch, Erlang's lint reports `unsafe_var` (the register
variable is "exported" from a case branch). Currently those
prototypes fail to load and fall back. The `:test` lowering should
fork ctx per branch and emit phi-style register reconciliation;
deferred to a follow-up.

### Open-cell upvalue lowering needed per-clause variables

`:get_open_upvalue` initially used `:__OpenCellRef` as the bind name
in both case clauses. Erlang's lint flagged this as unsafe (variable
defined in one clause used in another). Fixed by minting a fresh
per-call `OpenRef_<n>` atom.

### Lua binary literals must round-trip byte-by-byte

`String.to_charlist/1` raises on non-UTF-8 binaries. Lua strings can
hold arbitrary bytes. The codegen's binary-literal lowering now emits
each byte as a separate `bin_element` rather than going through the
string-as-charlist encoding.
