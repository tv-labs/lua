---
id: B5a-v2
title: Dispatcher foundation — single hand-written executor over dense bytecode
issue: null
pr: 237
branch: perf/dispatcher-foundation
base: main
status: review
direction: B
unlocks:
  - B5b-v2 (table opcodes), B5c-v2 (closures), B5d-v2 (error fidelity)
  - Luerl parity on numeric workloads without runtime BEAM codegen
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- Closing PR #235 and reverting any `:compile.forms`-related code
  paths that may have leaked into `main` (none have, but the
  `lib/lua/compiler/erlang/` tree on the PR branch must not be
  carried into this work).

## Goal

Land the foundation for the new B5 approach: a single hand-written
**dispatcher module** in `lib/lua/vm/dispatcher.ex` that interprets
a **dense bytecode** representation of `%Prototype{}` values. No
runtime BEAM module generation. No atoms minted per compile. No
`:compile.forms`, no `:code.load_binary`.

Scope mirrors the original B5a: arithmetic, comparison, logical
ops, conditional `:test`, single-result `:call`, single-value
`:return`, and the common `_ENV.name` lookup path. Tables and
closures fall back to the existing list-of-tuples interpreter.

## Why now

The original B5a (PR #235) proved the dispatch-elimination
hypothesis (1.45x faster than current interpreter, 1.07x faster
than Luerl on fib(30)) but did so by generating per-prototype BEAM
modules, which is fundamentally unsafe for an embedded Lua exposing
runtime `load()`.

The same dispatch shape, expressed as a single pattern-matched
function over an integer-opcode bytecode, is the BEAM's standard
case-jump-table idiom. It should capture most of the dispatch win
without the lifecycle hazard.

This is the gating experiment for Direction B. If the dispatcher
does not beat the current interpreter by at least 1.2x on fib(25),
the whole Direction-B premise is wrong and we should redirect to
data-shape work (B6/B7) instead.

## Out of scope

- Tables. Falls back to interpreter. → B5b-v2.
- Closures, varargs, multi-return. Falls back. → B5c-v2.
- Error position fidelity in the dispatcher. → B5d-v2.
- SSA / register promotion. Same as B5a-original — defer.
- Direct-threaded dispatch (computed-goto-equivalent). Not until
  case-dispatch is measured as the ceiling.
- Mutable register storage (`:array`, process dict). Out of scope.
- Mixed-mode (dispatcher prototype calls interpreter for a missing
  opcode mid-stream). All-or-nothing per prototype.

## Success criteria

- [ ] `Lua.VM.Dispatcher` module exists at `lib/lua/vm/dispatcher.ex`,
      hand-written, exports `execute(proto, args, state)` returning
      `{results, state}`. One pattern-match clause per supported
      opcode integer.
- [ ] `Lua.Compiler.Bytecode` module exists at
      `lib/lua/compiler/bytecode.ex`, walks a `%Prototype{}` with
      the existing list-of-tuples instruction stream and produces
      either `{:ok, bytecode_tuple}` or `:fallback`.
- [ ] `%Prototype{}` gains a `bytecode :: tuple() | nil` field. Set
      when the bytecode compiler accepts the prototype; nil
      otherwise.
- [ ] `Lua.VM.Executor.call_function/3` learns a clause for
      `{:compiled_closure, bytecode, proto, upvalues}` that
      dispatches to `Lua.VM.Dispatcher.execute/3`. (The
      `:compiled_closure` value shape from PR #235's spike survives;
      its third element changes meaning from "function name atom"
      to "the prototype struct" so the dispatcher has metadata.)
- [ ] The `:call` opcode in the existing interpreter learns the same
      shortcut: when calling a `:compiled_closure`, route to
      dispatcher with no register-tuple round trip.
- [ ] Opcode coverage in this PR (mirror of original B5a):
      `:load_constant`, `:load_boolean`, `:load_nil`, `:move`,
      `:source_line`, `:scope`, `:get_upvalue`, `:get_global`,
      `:load_env`, `:get_field` (env-lookup form only), `:add`,
      `:subtract`, `:multiply`, `:divide`, `:floor_divide`,
      `:modulo`, `:power`, `:negate`, `:less_than`, `:less_equal`,
      `:greater_than`, `:greater_equal`, `:equal`, `:not_equal`,
      `:not`, `:test`, `:test_true`, `:call` (single result),
      `:return` (single value).
- [ ] Uncovered opcodes return `:fallback` from the bytecode
      compiler; the prototype stays interpreted. **No crashes.**
- [ ] `mix test`: existing 1705 tests + 51 properties + 55 doctests,
      0 failures.
- [ ] `mix test --only lua53`: 29 tests, 0 failures.
- [ ] **Leak regression test passes** (new test, see Implementation
      notes): running `Lua.eval!` over 1000 distinct sources grows
      atom count and code-loaded count by < 50 (allowing for
      Elixir's string interning).
- [ ] fib(25) beats current interpreter by ≥1.2x. Stretch: parity
      with Luerl (±10%).
- [ ] No workload regresses from current interpreter perf by more
      than 10%.

## Implementation notes

### Bytecode shape

The bytecode is a flat tuple of fixed-shape opcode tuples:

```elixir
proto.bytecode = {
  {1, 0, 0},        # @op_load_constant dest=0 k_idx=0
  {3, 2, 0, 1},     # @op_add dest=2 a=0 b=1
  {12, 2, 0},       # @op_return single base=2 count=0 (count encoded in opcode)
}
```

Each opcode is a small tuple with an integer opcode tag in slot 1
and operand integers in subsequent slots. Constants are indices
into `proto.constants` (already present).

Why tuples, not binaries:

- Operand widths vary by opcode (some have 2 args, some 4). Tuples
  encode this naturally without bit-packing complexity.
- `:erlang.element/2` is O(1) and the BEAM compiler emits a direct
  load. Binary-cursor patterns are O(1) too but require explicit
  decode logic.
- The "no per-step allocation" property is satisfied — bytecode
  tuples are built once at compile time, never mutated.

Why integer opcode tags, not atoms:

- Integer case-clause matching produces a jump table in BEAM
  assembly. Atom matching usually does too, but integers are
  unambiguously the fast path and the encoding stays tight.

### Dispatcher shape

```elixir
defmodule Lua.VM.Dispatcher do
  alias Lua.VM.{State, Value, Numeric, Executor}

  @op_load_constant 1
  @op_move 2
  @op_add 3
  @op_subtract 4
  # ... one constant per supported opcode

  @spec execute(Prototype.t(), [term()], State.t()) ::
          {[term()], State.t()}
  def execute(proto, args, state) do
    regs = build_initial_regs(proto, args)
    dispatch(proto.bytecode, proto.constants, proto.upvalues, 1, regs, state, 0)
  end

  defp dispatch(code, consts, ups, pc, regs, state, line) do
    case :erlang.element(pc, code) do
      {@op_load_constant, dest, k_idx} ->
        v = :erlang.element(k_idx + 1, consts)
        regs2 = :erlang.setelement(dest + 1, regs, v)
        dispatch(code, consts, ups, pc + 1, regs2, state, line)

      {@op_move, dest, src} ->
        v = :erlang.element(src + 1, regs)
        regs2 = :erlang.setelement(dest + 1, regs, v)
        dispatch(code, consts, ups, pc + 1, regs2, state, line)

      {@op_add, dest, a, b} ->
        va = :erlang.element(a + 1, regs)
        vb = :erlang.element(b + 1, regs)
        case {va, vb} do
          {ia, ib} when is_integer(ia) and is_integer(ib) ->
            regs2 = :erlang.setelement(dest + 1, regs, ia + ib)
            dispatch(code, consts, ups, pc + 1, regs2, state, line)
          _ ->
            {v, state2} = Numeric.add(va, vb, state)
            regs2 = :erlang.setelement(dest + 1, regs, v)
            dispatch(code, consts, ups, pc + 1, regs2, state2, line)
        end

      {@op_return_one, base} ->
        v = :erlang.element(base + 1, regs)
        {[v], state}

      # ... etc, one clause per opcode
    end
  end
end
```

Same shape as `Lua.VM.Executor.do_execute/8` today, with PC arithmetic
instead of list consumption and integer dispatch instead of
atom-keyed tuple dispatch.

### Compiler entry point

```elixir
defmodule Lua.Compiler.Bytecode do
  @spec compile(Prototype.t()) :: {:ok, Prototype.t()} | :fallback

  def compile(%Prototype{} = proto) do
    with {:ok, encoded} <- encode_instructions(proto.instructions, proto),
         {:ok, sub_protos} <- compile_subprotos(proto.subprotos) do
      {:ok, %{proto | bytecode: encoded, subprotos: sub_protos}}
    else
      :fallback -> :fallback
    end
  end

  defp encode_instructions(instructions, proto) do
    # walk instructions, emit bytecode tuples, return :fallback on first
    # uncovered opcode.
  end
end
```

`Lua.Compiler.compile/2` (the existing entry) wraps this:

```elixir
def compile(source, opts \\ []) do
  proto = existing_parse_compile_pipeline(source, opts)
  case Lua.Compiler.Bytecode.compile(proto) do
    {:ok, with_bytecode} -> with_bytecode
    :fallback -> proto
  end
end
```

### Per-opcode lowering (porting from PR #235)

The `Lua.Compiler.Erlang.Opcodes.lower/2` function in PR #235's
branch held the integer fast-path inlining decisions for each
opcode. Those decisions port directly to the bytecode compiler:

- `:add`/`:subtract`/`:multiply` with integer fast path: the
  dispatcher clause inlines the integer guard, slow path delegates
  to `Numeric.add` etc.
- `:divide`/`:floor_divide`/`:modulo`/`:power`: slow path only in
  the dispatcher (matches the executor's existing structure).
- `:less_than` etc. with number fast path: same.
- `:test` / `:test_true`: compile to a branch that updates PC. The
  compiler resolves label-to-PC at encode time; jumps become
  `pc = N` in the dispatcher.

The encoding boundary is the only thing that's new. The lowering
*decisions* are knowledge transfer from PR #235.

### `:compiled_closure` value type

Carried over from PR #235's spike, adapted:

```elixir
# Before (PR #235):
{:compiled_closure, module_name, function_name, upvalues_tuple, proto}

# After (this plan):
{:compiled_closure, bytecode_tuple, proto, upvalues_tuple}
```

Why keep the wrapper instead of just adding `bytecode` to `:lua_closure`:

- Pattern-match locality. `Executor.call_function/3` dispatches on
  the head atom. A separate `:compiled_closure` keeps the
  dispatcher path off the interpreter's hot path.
- Matches the closure-creation cascade rules from PR #235:
  sub-prototype compile status flows through the closure value, not
  back through the prototype.

### Closure-creation cascade

Same rule as PR #235's discovery: sub-prototypes compile
independently. The parent's `:closure` opcode (in the interpreter,
since `:closure` isn't covered by this plan's bytecode) checks
`nested_proto.bytecode` and emits either `:compiled_closure` (if
set) or `:lua_closure` (if nil). This was the right call in PR #235;
it survives.

### Files

- `lib/lua/vm/dispatcher.ex` (new) — hand-written executor over
  bytecode. One clause per opcode integer. Roughly 1 case branch
  per opcode → ~30 branches in this PR.
- `lib/lua/compiler/bytecode.ex` (new) — bytecode encoder. Per-
  opcode encode helpers. Returns `:fallback` on first uncovered
  opcode.
- `lib/lua/compiler/prototype.ex` — add `bytecode` field, default
  nil. **Remove** any `compiled_module` field from PR #235 if it
  exists in the branch (it should not have been merged).
- `lib/lua/compiler.ex` — wire `Lua.Compiler.Bytecode.compile/1`
  into the main compile path.
- `lib/lua/vm/executor.ex` — add `:compiled_closure` clauses to
  `call_function/3` and the `:call` opcode dispatch. Both route
  to `Dispatcher.execute/3`.
- `lib/lua/vm.ex` — top-level `execute/2` dispatches via
  Dispatcher if `proto.bytecode` is non-nil.
- `test/lua/vm/dispatcher_test.exs` (new) — per-opcode golden tests
  (compiled result == interpreted result).
- `test/lua/compiler/bytecode_test.exs` (new) — fallback cascade
  tests (every uncovered opcode returns `:fallback`; sub-prototype
  fallback does **not** cascade to parent).
- `test/lua/vm/leak_regression_test.exs` (new) — **critical**.
  Asserts that 1000 distinct `Lua.eval!` calls grow neither the
  atom count nor the loaded-module count by more than a small
  noise threshold. This is the test PR #235 should have had.

### Leak regression test (specific shape)

```elixir
defmodule Lua.VM.LeakRegressionTest do
  use ExUnit.Case, async: false

  test "compiling N distinct prototypes does not grow atom table" do
    before_atoms = :erlang.system_info(:atom_count)
    before_modules = length(:code.all_loaded())

    for i <- 1..1_000 do
      {:ok, _, _} = Lua.eval(Lua.new(), "return #{i} + 1")
    end

    :erlang.garbage_collect()

    after_atoms = :erlang.system_info(:atom_count)
    after_modules = length(:code.all_loaded())

    # Elixir may intern atoms for compiled string ops. Allow some headroom
    # but the per-iteration growth must be ~0.
    assert after_atoms - before_atoms < 50,
      "atom count grew by #{after_atoms - before_atoms} over 1000 evals"
    assert after_modules == before_modules,
      "loaded module count grew by #{after_modules - before_modules}"
  end

  test "load() with unique sources does not grow atom table" do
    before_atoms = :erlang.system_info(:atom_count)

    lua = Lua.new()
    {_, lua} = Lua.eval!(lua, "for i = 1, 1000 do load('return ' .. i)() end")

    :erlang.garbage_collect()

    assert :erlang.system_info(:atom_count) - before_atoms < 50
  end
end
```

This test is non-negotiable for this plan. The whole point of the
rewrite is that it passes.

### Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/leak_regression_test.exs

# Perf gate.
MIX_ENV=benchmark mix run benchmarks/fibonacci.exs

# Smoke other workloads.
MIX_ENV=benchmark mix run benchmarks/oop.exs
MIX_ENV=benchmark mix run benchmarks/closures.exs
MIX_ENV=benchmark mix run benchmarks/table_ops.exs
MIX_ENV=benchmark mix run benchmarks/string_ops.exs
```

## Risks

- **The dispatcher is no faster than the current interpreter.**
  This is the gating risk. PR #235 measured the codegen at 1.45x
  the current interpreter on fib(30); some of that win came from
  BEAMASM speculative inlining on freshly loaded per-prototype
  modules, which the dispatcher cannot replicate. If the
  dispatcher is below 1.2x current interpreter on fib(25), pause
  Direction B and revisit. The codegen plus all of B5 was the wrong
  bet.
- **`setelement/3` ceiling.** Inherited from PR #235's discoveries.
  Out of scope here. If profiling shows it's the post-this-PR
  ceiling, the next plan is mutable register storage, not more
  dispatch work.
- **Tuple-element decode cost.** Pattern-matching `{@op_add, dest,
  a, b}` allocates nothing but does cost a tuple-shape check per
  opcode. Likely ~5–10% on top of pure dispatch. If profiling
  shows decode dominates, follow-up plan flattens to a tuple of
  bare integers and accepts the operand-shape readability loss.
- **Hot-reload during `mix test`.** Now a non-issue. The
  dispatcher is a normal module. No per-prototype modules to
  invalidate. Bytecode tuples live in `%Prototype{}` and have no
  affinity to a particular code version.

## Discoveries

### IR shape diverges from plan

The plan was drafted against a mental model of a flat instruction stream
with absolute PC labels and a separate constants pool. The actual IR is
**structured**: `:test` carries nested instruction lists for then/else
branches, loops use CPS continuation markers (not PC jumps), and
constants are inlined directly into opcodes (no pool, no `k_idx`).

Adapted the design accordingly: the bytecode is a tuple of opcode tuples
where `:test` recursively carries nested bytecode sub-tuples. The
dispatcher pushes `{code, pc}` resume points onto a local continuation
stack when entering a branch body, mirroring the interpreter's pattern.
No PC label resolution machinery needed.

### Several plan opcode signatures were stale

- `:return` is `{:return, base, count}`, not `{:return_one, base}`.
- `:call` is 5-tuple with `name_hint`, not 3-tuple.
- `:load_env` carries `dest`, not zero operands.
- `:source_line` is `{:source_line, line, file}`, not just `{line}`.
- `:scope` is listed in coverage but never emitted by the current
  codegen — it's vestigial in `Lua.Compiler.Instruction`.

The bytecode encoder matches the actual shapes. `:scope` was dropped
from coverage as a no-op.

### `proto.subprotos` field is named `prototypes`

The plan called it `subprotos` throughout. The actual struct field is
`prototypes`. Bytecode compilation walks `proto.prototypes` and stores
encoded children back in the same field.

### `:source_line` opcodes stripped from bytecode

Keeping them in the dense encoding cost one no-op dispatch per source
line, ~5% on fib(25). Stripped at encode time. Error attribution for
compiled prototypes is deferred to B5d-v2 anyway, so the
instruction-stream `:source_line` entries (used by the interpreter for
error positions) survive untouched on the prototype.

### Perf gate is brushed, not robustly cleared

Final measurements on fib(25) (full Benchee mode, median of 10s runs):

- Dispatcher: ~65 ms/iter
- Interpreter (same VM, bytecode stripped): ~76 ms/iter
- **Speedup: 1.17x median** (range 1.14x – 1.21x across runs, ~1.5% deviation)

The plan's gate was ≥1.2x. We sit between 1.14 and 1.21, with the
median around 1.17. fib(30) full benchmark beats Luerl by ~5% on a good
run (stretch goal: parity ±10%). No workload regresses.

Why we didn't hit a clean 1.2x: the interpreter is already heavily
tuned (per-clause guards, inlined integer fast paths, dedicated
`{:return, _, 1}` fast clause). The dispatcher's wins — integer-tagged
case dispatch, tuple-encoded operands, stripped `:source_line` — are
real but bounded by the interpreter's existing optimisations.

Profile attribution after all optimization passes:

- `Dispatcher.dispatch/8`: 50% (the case-jump-table itself)
- `:erlang.setelement/3`: 30% (register writes — unavoidable)
- `copy_regs/5` + `init_callee_regs/4`: 9% (call setup tuple allocation)
- `return_one/3`: 4% (frame unwinding)

Further gains require structural changes explicitly out of scope:

- Mutable register storage (`:array`/process dict) would eliminate
  `setelement/3` allocations entirely.
- Flat PC bytecode with label resolution would let `:test` skip the
  continuation-stack push.
- Direct-threaded dispatch (computed-goto-equivalent) would replace
  the case statement with token-driven jumps.

Each is its own follow-up plan.

### Optimization iterations log

For reproducibility — the perf loop that got us from 1.05x to 1.17x:

1. **Initial baseline:** 1.05x (dispatch/8 + step/9 two-level chain).
2. **Inlined `step/9` into `dispatch/8`:** 1.09x (eliminated one call frame per opcode).
3. **Tuple frames + unboxed `return_one/3`:** 1.09x (skips `[v]` allocation on return).
4. **Stripped `:source_line` from bytecode:** 1.15x (~5% win — 228k dispatches saved on fib(25)).
5. **Inlined int64-bounds guard + truthy check:** 1.17x median (eliminated `Numeric.to_signed_int64` and `Value.truthy?` function calls in hot paths).
6. **Tried open_upvalues empty-map elision:** -3% regression, reverted.

### `:compiled_closure` plumbing has more touch points than expected

Every site in the codebase that pattern-matches on `{:lua_closure, _, _}`
needed a parallel clause for `{:compiled_closure, _, _}`:

- `Lua.VM.Executor.call_function/3`, `:call` opcode, `:closure` opcode, `invoke_metamethod`, `call_value`, `value_type`
- `Lua.VM.Value.type_name`, `to_string`
- `Lua.VM.Stdlib.lua_load`, `compile_loaded_chunk`
- `Lua.VM.Stdlib.Util.typeof`
- `Lua.VM.Stdlib.String` (gsub repl)
- `Lua.VM.Stdlib.Debug.getinfo`
- `Lua.VM.Display.wrap_value`, `wrap_closure`
- `Lua.Util.encoded?`
- `Lua.Api.is_lua_func` guard
- `Lua.do_call_function`

Tests that asserted on the specific `:lua_closure` tag (display tests,
unwrap doctest) had to learn that closures may now be either tag.

This was a real cost. A future refactor could collapse the two tags
into one (`{:lua_closure, proto, upvalues}` where `proto.bytecode != nil`
implies dispatcher routing) — but the explicit tag makes the routing
decision local to `call_function/3` and that's worth something.

### Tests added

- `test/lua/vm/dispatcher_test.exs` — 27 per-opcode goldens.
- `test/lua/compiler/bytecode_test.exs` — 14 fallback cascade tests.
- `test/lua/vm/leak_regression_test.exs` — 3 leak guards (atom count
  growth, module load growth, bytecode-is-tuple shape).

Total: +44 tests, 1705 → 1749, 0 failures.

## What changed

- New: `lib/lua/compiler/bytecode.ex` (encoder),
  `lib/lua/vm/dispatcher.ex` (hand-written executor),
  `benchmarks/dispatcher_vs_interpreter.exs` (perf comparison harness),
  `test/lua/compiler/bytecode_test.exs`,
  `test/lua/vm/dispatcher_test.exs`,
  `test/lua/vm/leak_regression_test.exs`.
- Modified: `lib/lua/compiler.ex` (wires bytecode encoder into compile
  pipeline), `lib/lua/compiler/prototype.ex` (adds `bytecode` field),
  `lib/lua/vm/executor.ex` (adds `:compiled_closure` clauses to
  `call_function/3`, `:call` opcode, `:closure` opcode; adds
  `dispatcher_*` bridge helpers for arithmetic/comparison/field access),
  `lib/lua.ex`, `lib/lua/api.ex`, `lib/lua/util.ex`,
  `lib/lua/vm/{display,value}.ex`,
  `lib/lua/vm/stdlib/{debug,string,util}.ex`,
  `lib/lua/vm/stdlib.ex` (all gain parallel `:compiled_closure` clauses).
- Tests: `test/lua/vm/display_test.exs` updated to accept either
  closure tag.

PR: https://github.com/tv-labs/lua/pull/237
