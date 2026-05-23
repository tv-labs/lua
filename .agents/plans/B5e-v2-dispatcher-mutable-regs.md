---
id: B5e-v2
title: Dispatcher mutable register storage — close the memory gap with Luerl
issue: null
pr: null
branch: perf/dispatcher-mutable-regs
base: main
status: blocked
direction: B
unlocks:
  - parity with (or better than) Luerl on memory for compiled workloads
  - removes ~80% of dispatcher allocations on fib(25)
  - sets the stage for further dispatch-cycle wins (no tuple copy per opcode)
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (dispatcher foundation) — PR #237, in review.

## Goal

Replace the dispatcher's immutable register tuple with **mutable
process-dictionary-backed register storage**, eliminating the
`:erlang.setelement/3` allocation that currently accounts for ~80% of
dispatcher memory traffic. The dispatcher's hot path should read and
write registers without allocating a new tuple per opcode.

Scope is **dispatcher-only**. The interpreter's tuple-based register
file is untouched — only prototypes that compile to bytecode benefit.
The interpreter remains the correctness reference; dispatcher diverges
only in *how* registers are stored, not in observable semantics.

## Why now

fib(25), full Benchee mode, after B5a-v2:

| Path        | Time     | Memory   |
|-------------|----------|----------|
| Dispatcher  | 51.6 ms  | 263 MB   |
| Luerl       | 64.5 ms  | **227 MB** |
| Interpreter | 73.7 ms  | 673 MB   |

We are 1.25x faster than Luerl on time but 1.16x heavier on memory.
The memory deficit traces to `:erlang.setelement/3` copying an 11-word
tuple on every register write. fib(22) executes ~600k register writes;
each copies 11 words, accounting for 16 MB of the 18 MB total dispatcher
allocations attributable to the register file.

This is the largest single allocation source remaining in the
dispatcher, and the largest gap between us and Luerl. The plan's risk
section in B5a-v2 explicitly called out mutable register storage as
the follow-up for closing it.

## Out of scope

- Interpreter register file. Stays as tuple-of-tuples. Mutable storage
  in the dispatcher is enough — out-of-scope opcodes still fall back to
  the interpreter.
- NIF-backed mutable storage (`:atomics`, custom resource types). Too
  heavy for one PR and incompatible with arbitrary Lua values
  (`:atomics` is int64-only).
- ETS-backed registers. Cross-process visibility and table-creation
  overhead per call wouldn't pay off.
- `:array` module. Same allocation profile as tuples — copy on write.
- Compile-time register lifetime analysis. Orthogonal — would help
  *peak* register count, not per-write allocation.
- Register sharing between caller and callee (Luerl-style stack
  splice). Larger structural change.

## Success criteria

- [ ] `Lua.VM.Dispatcher` stores its current-frame register file in
      the **process dictionary** under a small fixed set of keys,
      keyed by `{dispatcher_regs, reg_idx}` (or similar; the exact
      key shape is a discovery during implementation).
- [ ] `:erlang.setelement/3` no longer appears in the dispatcher's
      hot path. Verified via `mix profile.tprof --type memory` on
      fib(22): combined `setelement` + `make_tuple` drop below 10%
      of total dispatcher allocations.
- [ ] Call setup: callee register slots initialise via
      `Process.put/2` (or a batched equivalent). Frame save on call
      captures the *outgoing* register values into the dispatcher's
      frame stack (a single map or list). Frame restore on return
      writes them back.
- [ ] Closure capture (`:get_open_upvalue` / `:set_open_upvalue`)
      reads the current process-dict register value when an upvalue
      cell hasn't been allocated yet. Existing
      `state.open_upvalues` semantics for created cells stay intact.
- [ ] All existing tests pass: `mix test` → 1749 tests + 51 properties
      + 55 doctests, 0 failures.
- [ ] `mix test --only lua53` → 29 tests, 0 failures.
- [ ] Leak regression test still passes — process-dict keys are
      cleared on dispatcher exit (`try/after` block).
- [ ] **Memory gate:** fib(25) dispatcher allocation drops by ≥50%
      from current 263 MB → ≤130 MB.
- [ ] **Memory stretch:** fib(25) dispatcher allocation ≤ Luerl's
      227 MB. Parity with Luerl on memory.
- [ ] **Time:** fib(25) speedup vs interpreter improves to ≥1.5x
      (currently 1.43x), or at minimum holds at 1.4x. No workload
      regresses on time by more than 5%.
- [ ] **Concurrency safety:** every dispatcher invocation cleans
      up its process-dict keys before returning, including the error
      path (uncaught Lua exception bubbling out). A new test holds
      this property: run 100 dispatcher invocations on the same
      process, assert `Process.get_keys/0` size is unchanged before
      and after.

## Implementation notes

### Storage shape

The dispatcher needs:
- An array-like indexed slot store (registers).
- Cheap save/restore for the entire register file (on call frames).
- Cheap reset on error.

The process dictionary offers `Process.put/2`, `Process.get/1`,
`Process.delete/1`. Each is O(1) hash-table access, allocation-free
for primitive values, allocation-equal-to-value for compound values
(no carrier tuple, unlike `:erlang.setelement/3`).

Two layout options:

**Option A — Flat key per slot:**

```elixir
Process.put({:disp_reg, 0}, value)   # write reg 0
v = Process.get({:disp_reg, 5})       # read reg 5
```

Each register slot is a separate process-dict key. Save/restore for a
frame requires reading N keys into a list, then writing them back. For
fib's 11-register file, that's 11 reads on call entry, 11 writes on
return.

**Option B — Single carrier with `setelement`:**

```elixir
regs = Process.get(:disp_regs)
regs = :erlang.setelement(N + 1, regs, value)
Process.put(:disp_regs, regs)
```

This still allocates the tuple — same problem we started with. Reject.

**Option C — Tuple in process dict, mutate by replacing:**

Same as B but only writes the carrier back on the final access of a
frame. Hard to know when "final" is. Reject.

**Recommendation: Option A.** Per-slot keys. Each `setelement` becomes
`Process.put({:disp_reg, idx}, value)` — no carrier tuple at all.

The complication: **frame save/restore** is no longer "save one tuple
pointer". On a `:call_one` we must snapshot all N caller registers into
the frame before resetting the slots for the callee. On return we
restore them.

Mitigation: track `caller_regs_count` per call site in the bytecode
encoder. The encoder already knows `max_registers` at compile time, so
each `:call_one` can carry the exact number of slots to snapshot.

Alternative mitigation: snapshot lazily — only save slots that the
callee actually writes. Too clever for v1; defer.

### Frame save / restore

The dispatcher's frame tuple (currently
`{code, pc, regs, upvalues, proto, cont, base, open_upvalues}`)
replaces `regs` with `saved_regs :: tuple()` — a one-time snapshot of
all active register slots at call time. On return we replay the snapshot
back into the process dict.

```elixir
# On :call_one entering a compiled callee:
saved = snapshot_regs(caller_proto.max_registers)
Process.put({:disp_reg, 0}, arg0)
# ... copy args
frame = {code, pc + 1, saved, upvalues, proto, cont, base, open_upvalues}
# tail call into callee dispatch

# On return:
restore_regs(saved)
Process.put({:disp_reg, base}, result)
dispatch(...)
```

`snapshot_regs/1` allocates one N-element tuple per call. That tuple
is the only per-call allocation. For fib with N=11, that's 11 words
per call frame — same as today's full register tuple. **The win is
that intra-body writes no longer allocate.**

Net allocation count for fib(22):
- Today: 600k setelement × 11 words = 6.6M words (registers) + 57k call frames × 11 words = 0.6M words. Total: 7.2M words.
- After this PR: 57k call frames × 11 words = 0.6M words. **~92% reduction.**

### Closure interaction — `:get_open_upvalue` / `:set_open_upvalue`

These opcodes are currently `:fallback` in the bytecode encoder, so the
dispatcher doesn't handle them yet. **This PR does not change their
fallback status.** The interpreter handles them via its tuple-backed
register file as today. If a prototype touches open upvalues, it falls
back regardless of register storage.

A future plan can extend dispatcher coverage to open upvalues,
which would require the dispatcher's `make_ref()`-cell creation logic
to read from the process-dict slot, then write the cell ref into
`state.open_upvalues`. Out of scope here.

### Concurrency / reentry safety

The process dict is shared across the calling Erlang process. If
`Lua.eval!` is called from a function the dispatcher invokes via
`:native_func` (an Elixir callback running `Lua.eval!` on the same
state), the nested dispatcher invocation would clobber the outer
frame's registers.

Mitigation: at every dispatcher entry, save the current `{:disp_reg, *}`
key set (one tuple snapshot) and restore on exit:

```elixir
def execute(proto, args, upvalues, state) do
  saved = snapshot_all_disp_regs()
  try do
    do_execute_top(proto, args, upvalues, state)
  after
    restore_all_disp_regs(saved)
  end
end
```

`snapshot_all_disp_regs/0` walks `Process.get_keys/0` filtering for
`{:disp_reg, _}` shape and reads each. One-time O(N) cost per
dispatcher entry. Acceptable because dispatcher entries are
order-of-magnitude rarer than per-opcode writes.

Alternative: nested dispatcher invocations use a depth-prefixed key
(`{:disp_reg, depth, idx}`) with `depth` tracked in process dict. More
mechanism, no allocation savings — reject for v1.

### Bytecode changes

None. The bytecode tuple format is unchanged. Only `Lua.VM.Dispatcher`
changes internally.

### Files

- `lib/lua/vm/dispatcher.ex` — main rewrite. The `dispatch/8` case
  arms change from `:erlang.setelement(dest + 1, regs, value)` and
  `:erlang.element(src + 1, regs)` to `Process.put({:disp_reg, dest},
  value)` and `Process.get({:disp_reg, src})`. The `regs` parameter
  is dropped from `dispatch/8` (down to `dispatch/7`).
- `test/lua/vm/dispatcher_test.exs` — existing per-opcode goldens
  should pass unchanged. Add a reentry / process-dict-cleanup test.
- `test/lua/vm/leak_regression_test.exs` — extend with the
  process-dict-key leak guard: assert `Process.get_keys/0` size is
  unchanged across 1000 dispatcher invocations.

### Verification

```bash
mix format
mix compile --warnings-as-errors
mix test                                                # 1749 tests pass
mix test --only lua53                                   # 29 tests pass

# Memory gate
LUA_BENCH_MODE=full MIX_ENV=benchmark \
  mix run benchmarks/dispatcher_vs_interpreter.exs

# Three-way memory comparison (custom script during dev)
# Dispatcher should be ≤227 MB on fib(25)

# Smoke other workloads for regression
MIX_ENV=benchmark mix run benchmarks/fibonacci.exs
MIX_ENV=benchmark mix run benchmarks/{oop,closures,table_ops,string_ops}.exs

# Memory attribution
MIX_ENV=benchmark mix profile.tprof --type memory -e '...'
# Confirm setelement + make_tuple combined < 10% of dispatcher allocations
```

## Risks

- **Process dict throughput is not free.** Each `Process.put/2` does a
  hash lookup and insert into the process's internal dict. The BEAM
  implements this as an open-addressed hash table; for small dicts
  (~16 entries) it's effectively constant-time, but it's not as fast
  as `setelement` on a hot pre-existing tuple. **First measurement
  could show time regression** even with memory wins. If time drops
  below 1.3x vs interpreter on fib(25), this plan is the wrong bet
  and we should revisit (likely back to tuple-based with smarter
  in-place update hints, or accept the memory deficit).

- **Reentry edge cases.** If a `:native_func` called from compiled
  code recursively calls `Lua.eval!` (or any code path that re-enters
  the dispatcher), the snapshot/restore at dispatcher entry must
  cover it. A pcall/error-during-snapshot-restore could leak keys.
  Mitigated by `try/after` at every entry point, but the test
  surface for this is non-trivial.

- **Process dict size growth on long-running processes.** If
  snapshot/restore has a bug that leaves keys behind, the dict grows
  unboundedly. Leak regression test guards this; the property test
  in B5a-v2 already runs 1000 distinct evals — extend it to assert
  `Process.get_keys/0` size is stable.

- **No win for short-running workloads.** Programs that compile to
  10 bytecode opcodes and execute once won't see any meaningful
  memory difference — the per-call snapshot now costs *more*
  per call than the old per-write `setelement`. The break-even is
  around 5-10 opcodes per call. Long workloads (fib, table ops,
  string parsing) benefit; one-shot evals slightly regress on memory.
  Acceptable tradeoff.

- **Compilers / static analyzers.** Some Elixir style tools complain
  about process-dict usage. Add a `# credo:disable-for-this-file`
  or equivalent comment with rationale. The dispatcher is one of the
  few places in the codebase where process-dict is the right tool —
  this is a deliberate exception, not unidiomatic code.

## Discoveries

(Will be filled in during implementation.)
