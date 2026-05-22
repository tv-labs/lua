---
id: B4
title: Flat instruction stream + PC dispatch (replace list-of-tuples)
issue: null
pr: null
branch: perf/flat-instruction-stream
base: main
status: deferred
direction: B
unlocks:
  - B5 (Erlang-function compilation builds on flat layout)
  - measurable reduction in `do_execute/8` self-time
---

## Goal

Replace the current `instructions :: [tuple()]` representation with a
fixed-size tuple of opcodes plus an integer program counter. The
`do_execute/8` dispatch loop becomes `dispatch(pc, instrs, ...)` with
`elem(instrs, pc)` selection instead of list head-matching.

This eliminates the per-opcode list cons traversal cost. In the current
fib(22) profile `do_execute/8` accounts for **43.6%** of total time, and
a meaningful share of that is the implicit `[head | rest]` pattern
destructuring on every dispatch. A PC + tuple layout removes those
cons-cell reads.

## Why now

The fast-path work in PR #223 (numeric arith, comparison, string
concat, get_field) closed several arithmetic and table-access gaps.
The remaining dispatch cost is structural — it lives in the shape of
the instruction stream, not in any single opcode handler. Until that
shape changes, further per-opcode fast paths give diminishing returns.

## Out of scope

- Compiling instruction streams into Erlang functions. That is B5 and
  builds on whatever flat layout this plan lands.
- Changing the opcode set or the tuple shape of individual instructions.
- Performance work on `do_frame_return/6` or `copy_args_to_regs/5`.
  Those are separate plans.
- Changing the codegen output format beyond what's needed to emit a
  tuple + jump table instead of a list. Peephole optimizations are B2.

## Success criteria

- [ ] `Lua.Compiler.Prototype.instructions` is a tuple (or a struct
      wrapping a tuple plus a label-to-pc map), not a list.
- [ ] `Lua.VM.Executor.do_execute/N` takes a program counter and indexes
      into the instruction tuple via `elem/2`.
- [ ] Control flow (`:goto`, `:label`, `:while_loop`, `:repeat_loop`,
      `:numeric_for`, `:generic_for`, `:break`) resolves to integer PCs
      at compile time. No `find_label/2` linear scan at runtime.
- [ ] `mix test` passes (≥ 1273 tests; current is 1692 + 51 properties
      + 55 doctests).
- [ ] `mix test --only lua53` does not regress against the current
      pass count.
- [ ] Benchee microbenchmarks improve. Stretch target: **20%+ reduction
      in fib(25) median**. Floor: no workload regresses by more than
      2% (within noise).
- [ ] Profile after merge: `do_execute/N` self-time drops below 35%
      on fib(22) (currently 43.6%).

## Implementation notes

### Current layout (for reference)

```elixir
# Lua.Compiler.Prototype
defstruct [
  :instructions,     # list of tuples: [{:add, 0, 1, 2}, {:return, 0, 1}, ...]
  :max_registers,
  :param_count,
  ...
]

# Lua.VM.Executor dispatch
defp do_execute([{:add, dest, a, b} | rest], regs, ...) do
  ...
  do_execute(rest, new_regs, ...)
end
```

### Proposed layout

```elixir
defstruct [
  :instructions,     # tuple of tuples: {{:add, 0, 1, 2}, {:return, 0, 1}, ...}
  :labels,           # %{label_name => pc_integer} for resolving :goto
  :max_registers,
  :param_count,
  ...
]

# Dispatch via PC
defp do_execute(pc, instrs, regs, ...) when pc < tuple_size(instrs) do
  case elem(instrs, pc) do
    {:add, dest, a, b} -> ...; do_execute(pc + 1, instrs, ...)
    ...
  end
end
defp do_execute(_pc, _instrs, regs, ..., frames, ...) do
  # Off the end of instruction stream — same as the current `[]` case
  ...
end
```

Two viable shapes for the dispatch:

1. **Single `case` in a single function head** — closest to a bytecode
   interpreter. Easy to read. BEAM compiles a `case` on a tagged tuple
   into a jump table.
2. **Multi-head pattern match on `elem(instrs, pc)`** — same source
   as today's head-matching, but the head is the result of `elem/2`.
   May compile to less efficient code than a `case` because the BEAM
   re-tests the result type per head; needs measurement.

Recommend (1) for the initial implementation. If profiling shows the
`case` is the bottleneck, B5 supersedes this anyway.

### Control flow

The current `goto`/`label` implementation uses `find_label/2` at
runtime — a linear scan of the remaining instruction list. The new
layout resolves labels to PCs at codegen time:

```elixir
# Codegen pass: walk instructions once, build label index
@spec resolve_labels([tuple()]) :: {tuple(), %{atom() => non_neg_integer()}}
def resolve_labels(instructions) do
  {labels, _} =
    instructions
    |> Enum.with_index()
    |> Enum.reduce({%{}, 0}, fn
      {{:label, name}, idx}, {labels, _} -> {Map.put(labels, name, idx), idx}
      _, acc -> acc
    end)

  {List.to_tuple(instructions), labels}
end
```

`:goto label` becomes `{:goto, pc}` (resolved at codegen). `:label name`
stays in the stream as a no-op (executor skips it) so the PCs line up
with codegen's labeling.

### Loop CPS continuations

The current loop opcodes (`:while_loop`, `:numeric_for`, `:generic_for`,
`:repeat_loop`) carry inline `body` and `cond_body` instruction lists.
Under the flat layout, these become PC ranges or labels.

Two options:

1. **Keep inline lists** but lift them at codegen time into separate
   PC ranges in the same flat tuple, with header instructions like
   `{:numeric_for, base, loop_var, body_pc, exit_pc}`. The CPS frame
   stack still threads through the same way — it just stores PCs
   instead of instruction lists.

2. **Compile each loop body to a sub-prototype.** Simpler conceptually
   but adds a frame on every iteration (overhead, defeats the purpose).

Recommend (1). The CPS frames currently store `{:cps_numeric_for, base,
loop_var, body, rest, cont}`. Under the flat layout: `{:cps_numeric_for,
base, loop_var, body_pc, after_loop_pc}`.

### Compatibility

This is a breaking change to `Lua.Compiler.Prototype` and the executor's
internal protocol. Public API (`Lua.eval!/1,2,3`, `Lua.load_chunk!/2`,
`Lua.VM.execute/2`) stays unchanged.

`Lua.Chunk` wraps `%Prototype{}` — that struct's field types change, so
any saved/loaded chunks on disk would be invalid. We don't ship chunk
persistence and the dialyzer specs already mark `Prototype` internal.

### Files

- `lib/lua/compiler/prototype.ex` — add `labels` field, change
  `instructions` type to `tuple()`.
- `lib/lua/compiler/codegen.ex` — emit a tuple instead of a list,
  resolve labels to PCs in a final pass, lift loop bodies into PC
  ranges.
- `lib/lua/vm/executor.ex` — rewrite `do_execute/8` (currently takes
  an instruction list) to take `(pc, instrs, ...)`. Remove
  `find_label/2` and `find_loop_exit/1`.
- `lib/lua/vm.ex` — update entry point to pass PC=0 and the instructions
  tuple.
- `test/lua/compiler/integration_test.exs` — instruction-shape
  assertions need updates.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Microbenchmarks — capture before/after numbers in the PR body.
mix run benchmarks/fibonacci.exs
mix run benchmarks/oop.exs
mix run benchmarks/table_ops.exs

# Profile to confirm do_execute self-time dropped.
mix profile.tprof -e 'lua = Lua.new(); {_, lua} = Lua.eval!(lua, "function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end"); Lua.eval!(lua, "return fib(22)")'
```

## Risks

- The BEAM's pattern-match compiler may not produce a clean jump table
  for the unified `case elem(instrs, pc) do` form. If the post-merge
  profile shows no improvement (or worse, a regression), the structural
  change isn't paying for itself and B5 (Erlang functions) is the
  better lever.
- Loop body lifting is error-prone. Nested loops, `break` jumping out
  of nested loops, `goto` jumping into/out of loop bodies all need to
  resolve to the right PC. The existing CPS frame stack handles this
  semantically; the change is purely representational. Extensive
  test coverage exists (`for`, `while`, `repeat`, `break`, `goto` are
  hammered in the suite) — lean on it.
- Tuple-based instructions are non-resizable. Codegen must emit the
  full instruction stream before constructing the tuple; no streaming
  emit. The codegen already builds the full list before returning, so
  this is mostly a `List.to_tuple/1` at the end.
- One-time codegen cost goes up (tuple construction is O(n)). For
  long-lived chunks this is amortized; for one-shot `Lua.eval!` of
  short scripts it could be measurable. Stretch goal: codegen time
  does not regress by more than 5% on `Lua.eval!("return 1+1")`.

## Discoveries

Deferred without implementation after a pre-flight spike falsified the
plan's core dispatch hypothesis.

### The spike

Before committing to the ~2,400-line rewrite (executor + codegen + all
loop opcodes + label resolution), a synthetic microbench compared the
two dispatch shapes on identical work:

- **list-cons (current shape)** — `defp run([{:tag, ...} | rest], regs)`.
- **pc+elem `case` (proposed shape)** — `defp run(pc, instrs, regs) ...
  case elem(instrs, pc) do {:tag, ...} -> ...`.
- **pc+elem multi-head variant** — `do_step(elem(instrs, pc), pc, ...)`
  with multi-head dispatch on the step function.

Tagged-tuple shape, register layout, opcode mix (add/sub/mul/mov/load),
and per-op work were identical across all three. Only the dispatch
read changed. Stream length: 10,000 instructions. Stable over multiple
runs.

### Result

| Dispatch | IPS | Mean | vs current |
|---|---|---|---|
| list-cons (current) | 13.86 K | 72.13 µs | baseline |
| pc+elem `case` (proposed) | 12.69 K | 78.83 µs | **1.09x slower** |
| pc+elem multi-head | 12.10 K | 82.65 µs | **1.15x slower** |

Memory: identical to three decimal places.

### Why

The tagged-tuple jump table is the same in both shapes — BEAM compiles
both into a jump on the tag of the matched tuple. The only difference
is the dispatch read itself:

- `[h | t]` is a single indirect load. The BEAM is heavily tuned for
  cons-list iteration; it is the native iteration idiom on the platform.
- `elem(instrs, pc)` is a bounds-checked indirect load plus integer
  arithmetic.

Cons-list iteration wins by 9-15% on raw dispatch. In retrospect this
is unsurprising — but it had to be measured to be sure.

### Baseline confirms the dispatch problem is real

fib(22), main @ bc69a2e:

```
Lua.VM.Executor.do_execute/8       802388  50.98% self
:erlang.setelement/3               601788  25.49%
Lua.VM.Executor.do_frame_return/6   57313   5.96%
Lua.VM.Executor.copy_args_to_regs/5 114626   4.94%
Lua.VM.Numeric.to_signed_int64/1    85968   3.35%
```

`do_execute/8` is 51% of fib self-time (the plan referenced 43.6% from
an older baseline; PR #223 sharpened the surrounding code so the
proportional cost is higher now). The structural argument for attacking
dispatch was correct — *the right target* — but the proposed *shape*
doesn't help. The proposed shape makes it worse.

The plan's secondary wins also don't pay for the rewrite on this
benchmark: `find_label` and `find_loop_exit` do not appear in the
top hot functions, because fib has no `goto`/`break`/loops.

### What this means for the next move

The plan called this out explicitly under Risks #1:

> If the post-merge profile shows no improvement (or worse, a
> regression), the structural change isn't paying for itself and B5
> (Erlang functions) is the better lever.

That exit condition is met pre-merge. The right lever for the 51% is
**compiling instruction streams to native Erlang functions (B5)**,
which collapses dispatch entirely into the BEAM's function-call
mechanism — the BEAM-tuned operation we just measured beats every
data-shape alternative we tried.

### Conditions for reconsidering

A future plan could revisit B4 *as a structural prerequisite for B5*
(if compiling to Erlang functions wants integer entry points/labels
in the source representation). In that case the goal is not "dispatch
faster" — that's already disproven — but "lay out the IR for codegen
to Erlang." The success criteria would change accordingly: the bar
is "B5 compiles cleanly from the new layout," not "dispatch gets
faster."
