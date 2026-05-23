---
id: B5
title: Dense bytecode + single dispatcher module (executor JIT, take 2)
issue: null
pr: null
branch: n/a (split into B5a-B5e)
base: main
status: split
direction: B
unlocks:
  - sub-Luerl latency on tight numeric/call workloads, without
    runtime BEAM code generation
  - "perf parity with Luerl, ±10%" 1.0 commitment headroom
supersedes: B5-compile-prototypes-to-erlang
---

## Why this plan replaces the old B5

The original B5 took the path Luerl explicitly didn't: lower each
prototype to Erlang abstract forms and call `:compile.forms/2` +
`:code.load_binary/3` per compile. B5a shipped a working version of
that and the perf number (1.07x vs Luerl on fib(30)) was real. The
lifecycle was not.

### What killed it

Every successful compile mints a fresh module atom and loads a new
BEAM binary. Atoms are never GC'd by the BEAM. Modules sit in the
code server until explicitly purged. And purging has two problems
that ref-counting can't fix:

1. `:code.soft_purge/1` returns `false` while any process is
   executing the module. A Lua coroutine suspended mid-call inside a
   compiled chunk pins the module forever — the host has no way to
   know when (or if) the coroutine will resume.
2. `:code.purge/1` (hard purge) kills every process executing in old
   code. That is not a behaviour we can expose to embedders. Their
   own GenServers and request handlers run "inside" the compiled
   module via continuations into the dispatch.

The B5b plan (content-addressable + ref-counted purging) addressed
the cache-hit case but never resolved (1) or (2). A Lua program
running `load(user_input)` in a loop — which is the literal point of
embedding Lua — exhausts the atom table and crashes the BEAM.

Luerl avoids this entirely by never calling `compile:*` or `code:*`.
Its compile output is just data (tuples and records from
`luerl_instrs.hrl`), walked by a hand-written interpreter
(`luerl_emul:emul_1/7`). GC reclaims compiled chunks like any other
Erlang term.

### What this plan does instead

Keep the codegen *structure* from B5a. Change the *output target*.
Instead of emitting Erlang abstract forms and loading a fresh BEAM
module per prototype, emit a dense, register-based **bytecode** —
plain Erlang terms — and ship a single hand-written **dispatcher
module** in `lib/` that interprets it. Compiled prototypes carry the
bytecode as data on the existing `%Prototype{}` value.

The dispatcher is one module, written once, included in the
application. No `:compile.forms`, no `:code.load_binary`, no atoms
minted per compile, no purging, no DoS surface. Compiled chunks are
GC'd as ordinary terms.

We give up some of the per-prototype inlining the BEAM JIT could do
on freshly loaded modules. We keep almost all of the dispatch win
that the spikes attributed to "no interpreter loop." The two costs
are not the same — dispatch is the bigger one (see B5a's
discoveries: `setelement/3` was the main remaining ceiling, not
opcode-selection cost).

## Status: split into B5a–B5e

The work is split into five sequential plans, each shippable as one
PR per the `ship-a-plan` contract:

- **B5a** — Dispatcher module + dense bytecode IR; covers fib +
  arithmetic + control flow. Falls back on tables and closures.
- **B5b** — Table opcodes added to the dispatcher.
- **B5c** — Closures, varargs, multi-return.
- **B5d** — Error position fidelity.
- **B5e** — Profile-guided opcode densification (super-instructions,
  inline fast paths). Optional; only ship if benchmarks justify it.

Note the renumbering: the old "B5b — module lifecycle" plan is
deleted, not superseded — there are no modules to manage. Tables
move from B5c to B5b, closures from B5d to B5c, errors from B5e to
B5d, and B5e becomes the optional perf-tuning phase.

This parent plan stays as the strategic record: spike data,
architectural decisions, and what was decided out of scope. Read
the child plans for what gets implemented.

## Why this is the right shape

Three constraints made the original B5 untenable; this plan
satisfies all three:

1. **No per-compile BEAM modules.** No atom growth, no code-server
   growth, no purge calls. A host that runs `load()` in a loop on
   untrusted input is GC-safe — every compile is just allocating
   data terms.
2. **No coroutine / in-flight execution hazard.** The dispatcher
   module is loaded once at boot like any other library module. It
   does not need to be unloaded. Lua coroutines suspended inside
   compiled bytecode pin nothing.
3. **No global state.** No `Lua.VM.CodeCache` GenServer. No process
   tree to supervise. Compiled chunks live where every other
   `%Lua.Chunk{}` lives — owned by the caller.

The fourth constraint — perf — needs a separate argument. The
question is whether a hand-written dispatcher in Elixir can match
what `:compile.forms` produced.

### Perf hypothesis

B5a's compiled-erlang path beat the interpreter by ~1.45x on
fib(30) and tied Luerl. The bottlenecks identified in B5a's
discoveries were:

- `throw/catch` for non-tail `:return` (~8% of profile).
- `setelement/3` per register write (~22% of profile).
- Per-opcode case scrutiny in the dispatch loop.

The first two have nothing to do with whether the executor is
generated or hand-written. They're properties of the *value
representation* (register tuple, return-via-throw). They survive
this rewrite unchanged. B5a's win over the interpreter came from
the third: collapsing the dispatch shape.

A hand-written dispatcher can collapse dispatch differently:

- **Dense bytecode**: opcodes become small integers (or short
  atoms), operands are unboxed integers where possible. Decoding
  is `case Op of 1 -> ...; 2 -> ...; end` over an integer — the
  BEAM compiles this to a jump table.
- **Register-based**: same register model as today, same operand
  positions, no operand decoding tricks. Keep the simple path.
- **One pattern-match per opcode**: the BEAM's case-clause selection
  on integer keys is already as fast as anything `:compile.forms`
  produces for dispatch. The win the codegen had was *not having to
  dispatch at all* per opcode — that win is gone here, replaced by
  a single tight dispatch.

Expected ceiling: somewhere between the current interpreter (1.07x
Luerl on B5a, but the interpreter is closer to 0.74x) and B5a's
codegen output. Likely ~1.1x–1.3x Luerl on fib. The target is to
match Luerl, not to beat it dramatically. Beating Luerl
dramatically requires giving up GC-safety, which is the lesson of
B5a.

If the dispatcher hits ~Luerl parity on fib and ~2x interpreter on
tables, that's the win condition. Hosts get safe, predictable
behaviour and the perf gap to Luerl closes. Anyone who needs more
than that runs PUC-Lua via a NIF.

### Why this is not just "rewrite the interpreter"

The current `Lua.VM.Executor` dispatches over a *list of tuples* —
`[{:add, 1, 2, 3}, {:move, 4, 1}, ...]`. Every opcode pays for:

- The list-cons cell traversal (`[op | rest]` pattern match).
- The tuple pattern match on the opcode atom.
- Construction of a new `rest` list spine on every step.
- A function call (the tail-recursion).

The new dispatcher:

- Stores opcodes in a **binary or a tuple**, indexed by PC integer.
  `:erlang.element/2` and `:binary.at/2` are O(1) and don't churn
  list cells.
- Decodes opcodes as small integers, dispatched via integer case.
- Keeps PC as an integer; jumps become `pc = N` rather than
  `find_label/2` linear scans (B4's planned win, never landed,
  inherited here).
- Eliminates the per-step list spine reallocation.

The codegen work in `lib/lua/compiler/erlang/opcodes.ex` translates
naturally — most of it is "given this Lua opcode and these operands,
emit a snippet." The snippet target changes from "Erlang abstract
forms that compute the result" to "a fixed-length record of
bytecode bytes/elements that drive the dispatcher to compute the
result." Same op-table, different encoder.

## Goal

For each `%Prototype{}`, generate a **compiled bytecode** value —
a packed sequence of opcodes + operands as plain Erlang data —
that the new `Lua.VM.Dispatcher` module executes via a single
tight pattern-matched loop. No runtime BEAM module generation.
No atoms minted per compile. No `:compile.forms`, no
`:code.load_binary`.

## Out of scope

- Native code generation, NIFs, or anything that leaves the BEAM.
- Eliminating the interpreter path. The list-of-tuples interpreter
  stays as a debugging fallback and a fidelity reference for the
  dispatcher's behaviour. New language features land there first;
  dispatcher catches up in a subsequent plan if perf needs it.
- Cross-prototype optimization (inlining one Lua function into
  another).
- Direct-threaded dispatch (computed-goto-equivalent on BEAM).
  Worth investigating only if the case-dispatch ceiling is the
  measured bottleneck after this plan lands.

## Success criteria

- [ ] `Lua.VM.Dispatcher` module exists, hand-written, exports an
      `execute/3` (or similar) that takes a `%Prototype{}` with
      compiled bytecode, args, and state, and returns
      `{results, state}`.
- [ ] `Lua.Compiler.Bytecode` module exists, takes a `%Prototype{}`
      with the current list-of-tuples instruction stream and emits
      the bytecode value. The current `lib/lua/compiler/erlang/`
      opcode-lowering knowledge port to it.
- [ ] All opcodes have a dispatcher clause (no fallback gaps after
      B5c lands).
- [ ] `mix test` passes; suite pass count does not regress.
- [ ] **No new atoms or modules introduced at compile/eval time.**
      Verified by: run `Lua.eval!` in a loop with N distinct sources,
      assert `length(:code.all_loaded())` is unchanged and
      `:erlang.system_info(:atom_count)` is unchanged (modulo
      Elixir's own atom interning of literal source strings).
- [ ] Lua's own `load()` / `loadstring()` builtins, fed untrusted
      bytes in a loop, do not grow VM memory or atom count.
- [ ] fib(25): match Luerl (±10%). Stretch: 1.2x faster.
- [ ] table_sum(1000): match Luerl (±10%). Stretch: 1.5x faster.
- [ ] No workload regresses from current `main` interpreter perf by
      more than 10%.

## Implementation notes

### Bytecode shape

Three options for the bytecode storage:

1. **Tuple of opcodes**: `{op1, op2, op3, ...}` where each opcode
   is itself a small tuple `{:add, 1, 2, 3}`. Dispatch via
   `:erlang.element(pc, code)`. **Drawback**: each opcode is still
   an allocated tuple — no allocation win over the current
   interpreter.
2. **Binary bytecode**: a packed `binary` of `<<opcode:8, operands>>`.
   Dispatch via `:binary.at/2` or pattern matching on a binary cursor.
   **Drawback**: operand decoding needs to handle variable-width
   operands (constants don't fit in 8 bits). Adds decode complexity.
3. **Tuple of integers + side tables**: bytecode is a tuple of
   16-bit integers `{op_code, arg1, arg2, ...}` where constants and
   atoms are indices into per-prototype constant pools (already
   present on `%Prototype{}` as `proto.constants`). Dispatch is
   `element/2`, no allocation per step.

Recommend (3). Reuses the existing `proto.constants` pool,
no decoding overhead beyond `element/2`, no per-step allocation,
and integer comparison is the BEAM's best case for case-clause
selection.

### Dispatcher shape

```elixir
defmodule Lua.VM.Dispatcher do
  # opcode integers — keep this in sync with Lua.Compiler.Bytecode.
  @op_load_constant 1
  @op_move 2
  @op_add 3
  # ...

  def execute(proto, args, state) do
    regs = initial_regs(proto, args)
    dispatch(proto.bytecode, proto.constants, 0, regs, proto.upvalues, state)
  end

  defp dispatch(code, consts, pc, regs, ups, state) do
    case :erlang.element(pc + 1, code) do
      {@op_load_constant, dest, k_idx} ->
        regs2 = :erlang.setelement(dest + 1, regs, :erlang.element(k_idx + 1, consts))
        dispatch(code, consts, pc + 1, regs2, ups, state)

      {@op_add, dest, a, b} ->
        # integer fast path inline, slow path delegates
        # ...
        dispatch(code, consts, pc + 1, regs2, ups, state)

      # ... one clause per opcode
    end
  end
end
```

This is **the same shape** as the current `do_execute/8` in
`lib/lua/vm/executor.ex`. The differences:

- Instructions are indexed by `pc` integer, not consumed off a list.
  PC math replaces list-spine consumption. Jumps are `pc = N`.
- Opcode head is an integer, not an atom. Case dispatch becomes a
  jump table.
- Function head matches `{@op_X, ...}` once per opcode. The opcode
  integer is the case scrutinee.

Whether this is meaningfully faster than the current list-of-tuples
interpreter is the gamble. The argument for "yes": B5a's perf gap
to the codegen came primarily from `setelement/3` and `throw/catch`,
neither of which this rewrite touches. B5a measured **dispatch
alone** to be ~10–20% of the gap. The new dispatcher targets that
slice without taking on the lifecycle hazard.

If after B5a-take-2 we are not faster than the current interpreter
by at least 1.2x on fib, this plan was the wrong bet and we should
revisit (option C in the discussion: stay interpreter, profile and
tune).

### Codegen reuse from the deleted B5

The `lib/lua/compiler/erlang/` tree has three files: `erlang.ex`,
`codegen.ex`, `opcodes.ex`. The `Opcodes.lower/2` function in
`opcodes.ex` (~798 lines) holds the per-opcode lowering rules.
Most of those rules ("for `:add`, lower to a guarded integer fast
path; for `:test`, branch on truthiness") translate directly to
the new bytecode encoder. The Erlang-AST output type goes away;
the structural decisions don't.

`erlang.ex` (`:compile.forms/2` + `:code.load_binary/3`
orchestration) deletes entirely.

`codegen.ex` becomes `lib/lua/compiler/bytecode.ex` — same role
(walk the prototype, build the output), different output.

`runtime.ex` (helpers called from generated code) becomes
`Lua.VM.Dispatcher` helpers.

The `:compiled_closure` value type stays but its third element
changes meaning: instead of `{:compiled_closure, mod, fun,
upvalues}` it's `{:compiled_closure, bytecode, proto, upvalues}`
(or just rename to keep the existing `:lua_closure` shape and
add a `bytecode` field on the prototype). The `Executor` already
has the right dispatch clause from B5a; it points to
`Dispatcher.execute/3` instead of `apply(mod, fun, ...)`.

### Fallback path

Each compiler entry point tries the bytecode path. If it fails
(opcode not yet covered, codegen bug), it falls back to the
existing list-of-tuples interpreter. Same all-or-nothing per
prototype as B5a.

Difference from B5a: fallback is cheap — no atom was minted, no
module was loaded, no purge required. Drop the result on the floor
and use the original prototype.

### Register representation

Stay with the register tuple. Same as current interpreter. SSA
promotion (eliminating `setelement/3`) was not realistic in
generated Erlang either (B5a's discoveries called it out as
deferred); it's even less realistic in a hand-written dispatcher
where the tuple is part of the API surface.

If `setelement/3` is the post-B5 ceiling, the next plan is mutable
register storage via `:array` or a small dedicated process
dictionary slot — not SSA. Out of scope for this rewrite.

### What changes in `%Prototype{}`

- Drop the B5a-added `compiled_module :: {atom(), atom()} | nil`
  field.
- Add `bytecode :: tuple() | nil` — the compiled bytecode value, or
  `nil` if the prototype falls back to interpretation.
- Constants pool stays put.

### Sub-prototype compilation

Same rule as B5a: sub-prototypes compile independently. The parent's
`:closure` opcode checks `nested_proto.bytecode` and emits the
right closure shape. This was the right call in B5a; it survives.

### Error fidelity

Same status as B5a's `:source_line`-based approach. The dispatcher
threads a `current_line` integer through dispatch, updated by
`:source_line` ops. On error, we raise with that line. Full position
fidelity (B5d in this plan's renumbering) lands later.

### Bench / lifecycle test

Critical regression test that didn't exist for B5a: assert the
codegen does **not** introduce VM growth. Add to the test suite:

```elixir
test "compiling N distinct sources does not grow atom table or code server" do
  before_atoms = :erlang.system_info(:atom_count)
  before_modules = length(:code.all_loaded())

  for i <- 1..1000 do
    {:ok, _, _} = Lua.eval(Lua.new(), "return #{i} + 1")
  end

  :erlang.garbage_collect()

  # Some atoms get interned from Elixir-side string ops, but not 1000.
  assert :erlang.system_info(:atom_count) - before_atoms < 50
  assert length(:code.all_loaded()) == before_modules
end
```

This is the test B5a should have had. Its absence is what shipped
the leak.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Perf check.
MIX_ENV=benchmark mix run benchmarks/fibonacci.exs
MIX_ENV=benchmark mix run benchmarks/oop.exs
MIX_ENV=benchmark mix run benchmarks/closures.exs
MIX_ENV=benchmark mix run benchmarks/table_ops.exs

# Leak check — must show no growth.
mix run -e '
before_atoms = :erlang.system_info(:atom_count)
before_modules = length(:code.all_loaded())
for i <- 1..10_000 do
  {:ok, _, _} = Lua.eval(Lua.new(), "return #{i}")
end
:erlang.garbage_collect()
IO.inspect(:erlang.system_info(:atom_count) - before_atoms, label: "new atoms")
IO.inspect(length(:code.all_loaded()) - before_modules, label: "new modules")
# Both should be ~0.
'
```

## Risks

- **The dispatcher does not beat the current interpreter
  meaningfully.** Possible — the current interpreter is already
  pretty tight. The B4 work that was meant to land flat-instruction-
  stream dispatch never shipped. If this rewrite ends up at +5–10%
  vs current interpreter, the work cost wasn't worth it and we
  should pause Direction B until a better lever is identified.
  Mitigation: B5a (the new B5a, not the deleted one) is the gating
  experiment. It must clear "+20% on fib vs current interpreter"
  to justify continuing.
- **Decoding cost hides the dispatch win.** Tuple-element access is
  cheap but not free; unpacking `{op, a, b, c}` per step costs
  something. If profiling shows decode dominates dispatch we may
  need to flatten to a tuple of bare integers and accept the loss
  of operand-shape readability. Defer until measured.
- **Mutation-via-setelement remains the ceiling.** Acknowledged.
  Out of scope here. If it's the next bottleneck, the follow-up
  plan is mutable register storage (process dict slot, `:array`,
  or a small NIF) — not more codegen.
- **Loss of speculative inlining the BEAM JIT was doing on B5a-
  generated modules.** Real, hard to quantify without measuring.
  Inlining wins were never the dominant factor in B5a's perf
  number; dispatch elimination was. We give up the smaller win to
  remove the safety hazard.

## Discoveries

### Why the original B5 path was abandoned

B5a shipped successfully and met its functional bar but introduced
an unbounded BEAM module + atom leak with no safe path to GC. Hard
purge kills in-flight processes; soft purge is blocked by Lua
coroutines suspended inside compiled chunks. A Lua program calling
`load(untrusted_bytes)` in a loop is an atom-table-exhaustion DoS.

See review of PR #235 (closed) for the full analysis. The decision
to pivot was: "compile to BEAM modules" is fundamentally unsafe in
a library that exposes runtime Lua compilation, no matter how
clever the cache. Luerl avoids this by never generating BEAM modules
in the first place. This plan adopts that constraint.

### Spike data inherited from the deleted B5

The faithful fib(25) spike measured 12.4x faster than interpreter
when dispatching through a hand-loaded BEAM module. That number is
not reachable from this plan — it came primarily from the
single-prototype module enabling BEAMASM speculative optimization.
The dispatcher path keeps the dispatch-elimination win (the
bigger slice) but not the per-prototype-inlining win.

Realistic target inherited from the spikes: ~2-3x interpreter on
fib, ~2x interpreter on tables. Enough to clear the Luerl gap
without claiming an unrealistic ceiling.

### What survives from B5a

- `Lua.VM.Executor` learned `:compiled_closure` dispatch. Useful;
  keep the clause, repoint it at `Dispatcher.execute/3`.
- `lib/lua/compiler/erlang/opcodes.ex` has per-opcode lowering
  decisions (integer fast-path inlining, comparison shape, etc.).
  Knowledge ports to the new bytecode encoder.
- Test infrastructure for "compiled-vs-interpreted result equality"
  ports unchanged.

### What does not survive

- `Lua.Compiler.Erlang` — entire `:compile.forms` + `:code.load_binary`
  orchestration. Delete.
- `Lua.Compiler.Erlang.Codegen` — Erlang-AST emission. Delete; some
  per-opcode shape decisions port to bytecode encoder.
- The `:erl_lint :unsafe_var` warning footgun goes away — bytecode
  doesn't go through `:compile.forms`.
- The `:throw/:catch` for non-tail return shape goes away (bytecode
  jumps don't need to escape an Erlang function call boundary).
  This may actually be a perf win the codegen path didn't have.
