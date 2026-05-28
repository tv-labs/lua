---
id: B5c-v2
title: Dispatcher closures, varargs, and multi-return — every opcode covered
issue: 272
pr: null
branch: perf/dispatcher-closures
base: main
status: in_progress
direction: B
unlocks:
  - 100% opcode coverage in the dispatcher (no more fallbacks)
  - closures and OOP benchmarks fully dispatcher-routed
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (foundation, PR #237, merged), B5b-v2 (tables, PR #275, merged).

## Goal

Cover the remaining opcodes in `Lua.VM.Dispatcher`:

- `:closure` — closure construction with upvalue capture.
- `:set_upvalue`.
- `:get_open_upvalue`, `:set_open_upvalue` — open-cell access for
  captures of mutable locals.
- `:vararg`, `:return_vararg`.
- `:return` with count > 1, including `{:multi_return, _}` shape.
- `:call` with variable result counts (`-1`, `-2`, `n > 1`) and
  `{:multi, _}` arg counts.
- `:generic_for`, `:while_loop`, `:repeat_loop`, `:break`.
- `:self`.
- `:concatenate`.

`:tail_call` is verified dead in the current codegen (only
`Lua.Compiler.Instruction.tail_call/3` exists as an unused
constructor); tail-position calls compile to `:call` with
`result_count = -1`, which falls out of the multi-return work above.

After this PR no prototype falls back to the list-of-tuples
interpreter for opcode-coverage reasons.

## Out of scope

- Tail-call elimination beyond what the BEAM gives us "for free"
  from tail-recursive dispatch.
- Optimised closure capture (escape analysis, capture-by-value
  promotion). Defer.
- Error position fidelity in the dispatcher → B5d-v2. All new
  bridges and call-site failures pass `line: 0`.
- Mutable register storage / `setelement/3` elimination → its own
  plan if perf-justified after this lands.
- Mutable table storage. `Table.put/3` allocation churn is the
  ceiling for table workloads on the BEAM; not addressed here.

## Success criteria

- [ ] `Lua.Compiler.Bytecode` accepts every opcode listed above; the
      catch-all `:fallback` clause now matches only opcodes whose
      lowering is genuinely out of scope (`:goto`, `:label`,
      `:bitwise_*`, `:set_global` — see Discoveries).
- [ ] `Lua.VM.Dispatcher` has one `case` branch per new opcode plus
      new continuation markers (`:cps_while_test`,
      `:cps_while_body`, `:cps_repeat_body`, `:cps_repeat_cond`,
      `:cps_generic_for`, `:loop_exit`) handled in
      `finish_body/6`.
- [ ] Frame tuple gains a `{:multi, dest, count}` variant so
      `:call`-multi and `:return`-multi share one frame shape.
- [ ] `Lua.VM.Executor` exposes new `dispatcher_*` bridges where the
      dispatcher needs metamethod / stdlib coupling:
      `dispatcher_index_method_target/5` for `:self`,
      `dispatcher_call_value/5` for `:generic_for` step,
      `dispatcher_concat/5` for `:concatenate` slow path.
- [ ] `:break` inside `:numeric_for` no longer forces fallback (the
      B5b-v2 `contains_break?` guard is removed).
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` passes, no regressions vs. main.
- [ ] `mix test --only lua53` passes.
- [ ] `test/lua/vm/leak_regression_test.exs` still passes.
- [ ] `closures`, `oop`, `string_ops` benchmark inner functions
      compile to `:compiled_closure` end-to-end (no fallback chain).
- [ ] No workload regresses by >10% vs. interpreter on the
      `dispatcher_vs_interpreter`-style A/B harness.
- [ ] `closures.exs` beats the interpreter by ≥1.5x.

## Implementation notes

### New opcode tags (slots 37-47)

Reserve a contiguous block in both `Lua.Compiler.Bytecode` and
`Lua.VM.Dispatcher`:

```
@op_closure          37
@op_set_upvalue      38
@op_get_open_upvalue 39
@op_set_open_upvalue 40
@op_vararg           41
@op_return_vararg    42
@op_return_multi     43   # :return with count > 1
@op_call_multi       44   # :call with result_count ∉ {0, 1}
@op_self             45
@op_concatenate      46
@op_break            47
@op_while_loop       48
@op_repeat_loop      49
@op_generic_for      50
```

`:tail_call` reserves no slot — never emitted by codegen.

### Frame tuple variant

Today `base` in the frame tuple is either an integer or `:discard`.
Add a third shape `{:multi, dest, count}` for multi-return:

- `count == -1` — forward all results to the caller's caller; used
  by `result_count = -1` (tail-position calls).
- `count == -2` — expand all results into consecutive regs starting
  at `dest`, set `state.multi_return_count`; used by table
  constructors with trailing call (`{1, 2, f()}`) and similar.
- `count > 1` — write exactly `count` results, pad with nil.

`return_one/3` becomes `return_results/3` covering the three frame
variants. Single-result fast path stays.

### Multi-return contract

Multi-return is `state.multi_return_count` threading, identical to
the interpreter. `:vararg`-count-0, multi-return `:call`, and
`:return` with `count < 0` all read/write `state.multi_return_count`
on the same contract as `Lua.VM.Executor`.

Arg-count resolution for `:call_multi`:

```
{:multi, fixed_count}      -> fixed_count + state.multi_return_count
n when n > 0               -> n
n when n < 0               -> -(n + 1) + state.multi_return_count
0                          -> 0
```

Same as `executor.ex:832`.

### Loop CPS markers

`:while_loop`, `:repeat_loop`, `:generic_for` each push one of two
markers onto `cont` (one when entering condition/body, the second
when re-entering after the body) and an additional `:loop_exit`
marker beneath them. `:break` scans `cont` for the nearest
`:loop_exit` marker and resumes there. The interpreter's
`find_loop_exit/1` (executor.ex:1891) ports verbatim.

After the port, the B5b-v2 `contains_break?` guard at
`bytecode.ex:243` can be removed — `:break` inside `:numeric_for`
is no longer special.

### `:self` bridge

`:self` resolves `obj[method_name]` via `index_value/6`, the same
helper that backs `:get_field`'s slow path. Wrap as
`dispatcher_index_method_target/5` and return both `{func, state}`.

### `:concatenate`

Mirror executor.ex:1210-1241:

1. Both binary → `left <> right`.
2. Either binary-or-number on both sides → `concat_coerce/3` on each
   then `<>`.
3. Else → bridge through `dispatcher_concat/5` which wraps
   `try_binary_metamethod("__concat", ...)`.

Per-pair binary `:concatenate` opcodes (no n-ary chains in the
codegen; `a..b..c` lowers to two sequential `:concatenate` ops).

### Compiled vs. interpreted closure values

`:closure` builds `{:compiled_closure, proto, upvalues}` when
`nested_proto.bytecode != nil`, else `{:lua_closure, ...}`. Decision
flows through the tag — no parent-level metadata. Mirrors the
existing executor path verbatim.

### Files

- `lib/lua/compiler/bytecode.ex` — 14 new opcode constants, 14 new
  `encode/1` clauses, tag accessor methods.
- `lib/lua/vm/dispatcher.ex` — 14 new dispatch branches, 6 new
  `finish_body/6` continuation clauses, `find_loop_exit/1`
  port, frame-multi return path, closure-cell allocation helper.
- `lib/lua/vm/executor.ex` — 3 new `dispatcher_*` bridges:
  `dispatcher_index_method_target`,
  `dispatcher_call_value`,
  `dispatcher_concat`. The existing public `call_function/3` and
  `dispatcher_close_open_upvalues_at_or_above/2` cover the rest.
- `test/lua/compiler/bytecode_test.exs` — flip fallback assertions
  for the now-covered opcodes; add new fallback tests for genuinely
  unsupported shapes (`:goto`, `:bitwise_*`, `:set_global`).
- `test/lua/vm/dispatcher_test.exs` — per-opcode goldens for every
  new dispatch branch plus benchmark-shape goldens for closures,
  oop, and string_ops.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/dispatcher_test.exs
mix test test/lua/compiler/bytecode_test.exs
mix test test/lua/vm/leak_regression_test.exs

# Closures gap check — primary perf gate.
MIX_ENV=benchmark mix run benchmarks/closures.exs

# Smoke other workloads (no regression > 10%).
MIX_ENV=benchmark mix run benchmarks/oop.exs
MIX_ENV=benchmark mix run benchmarks/string_ops.exs
MIX_ENV=benchmark mix run benchmarks/table_ops.exs
MIX_ENV=benchmark mix run benchmarks/fibonacci.exs
```

## Risks

- **Multi-return frame plumbing touches every call site.** Every
  `:call_*` and `:return_*` branch updates. Mitigation: keep the
  single-result and zero-result fast paths; only the new
  `:call_multi` / `:return_multi` / `:return_vararg` branches use
  the `{:multi, _, _}` frame slot.
- **Closure-tag cascade between compiled parent and interpreted
  child.** When `proto.bytecode != nil` but a nested closure's
  `:closure` opcode encounters a child with `bytecode == nil`, the
  dispatcher must emit `:lua_closure`, not `:compiled_closure`.
  Symmetric on the interpreter side. Tested directly.
- **`:break` marker scanning.** `find_loop_exit/1` must skip
  non-loop continuations (`{code, pc}` from `:test`,
  `:cps_for` from `:numeric_for`) and stop at the first
  `:loop_exit`. Port the interpreter's matchspec verbatim.
- **Vararg state leakage.** `state.multi_return_count` must reset
  after a single-return call following a multi-return call.
  Mirroring the interpreter's behaviour: `continue_after_call`'s
  count-1 branch never touches `multi_return_count`, but the next
  multi-return read picks up the new value. Tested with
  back-to-back multi/single calls.

## Discoveries

### `:tail_call` is dead code

The frontmatter listed `:tail_call` as an opcode to cover. After
grepping the entire codebase, the only reference is the unused
constructor helper `Lua.Compiler.Instruction.tail_call/3`. Codegen
never emits this opcode — tail-position calls compile to `:call` with
`result_count = -1`, which forwards through the multi-return machinery.
Once `:call_multi` was wired, `:tail_call` was implicitly covered. No
dedicated opcode added.

### `:return_vararg` and multi-return `:return` are different data sources

The original plan conflated `:return_vararg` (returns `proto.varargs`
verbatim — used for `return ...`) with `:return base count<0` /
`{:multi_return, fixed}` (collects from regs, including a fixed prefix
plus `state.multi_return_count` trailing). They share the unwind path
(`return_multi/3`) but read from different sources, so the encoder
emits two distinct opcodes:

- `@op_return_proto_varargs` (42) — single-tag opcode, reads `proto.varargs`.
- `@op_return_collect` (43) — `{tag, base, fixed}`, reads regs.

### Falling-off-the-end ≠ explicit `:return _ 0`

Codegen emits *no* return instruction when a function falls off its
last statement (e.g., a function whose only body is `if cond then
return … end`). The interpreter handles this at executor.ex:506 by
returning the empty list `[]`. The dispatcher's `finish_body([])`
initially called `return_one(nil, …)` which wraps to `[nil]` — that
broke the `range(0, 255)` test where the empty-tail base case
otherwise pads a spurious nil into the multi-return chain. Fix:
`finish_body([])` now calls `return_multi([], …)`. Explicit
`:return _ 0` still returns `[nil]` via `:return_zero` (matching the
interpreter's `count == 0 -> [nil]` branch).

### `:call_one`/`:call_zero` had to grow vararg setup

Previously the comment on `:call_one` said "Vararg bodies are out of
scope for the bytecode encoder, so a `{:compiled_closure, ...}` is, by
construction, never a vararg function." After `:vararg` lowering
landed, that invariant no longer holds — a compiled callee can be
vararg. Both fast-path call opcodes now call `setup_vararg_proto/4`
to collect varargs from the caller's regs before the dispatch. The
helper short-circuits at one tuple-field read for the non-vararg
hot path (fib, every recursive call).

### Frame's `dest` slot generalises to four shapes

The B5b-v2 frame had `dest` as `integer` (single-result) or
`:discard` (zero-result). B5c-v2 adds `{:multi, base, count}` for the
multi-return shapes (-1 forward, -2 expand, n > 1 fixed multi). The
`:call_multi` opcode picks the slot based on `result_count`:
`result_count == 0` reuses `:discard`, `== 1` reuses `integer base`,
everything else uses the tagged tuple. `return_one/3` (fast path)
and `return_multi/3` (list path) both pattern-match on all four
shapes; the fib hot path stays on the integer-base branch.

### Register tuple needs lazy growth on multi-return

The dispatcher's `init_regs/2` sizes the register tuple exactly to
`max_registers`, with no `+16` safety buffer like the interpreter.
Multi-return expansion (`{a, b, c} = f()` where `f` returns 256
values) can outrun that bound. Added `grow_regs/2` and threaded it
through `write_varargs/4`, `write_results/3`, `write_results_n/4`,
and `pad_nils/3`. Growth is rare and bounded by the call's actual
result count; the fib hot path (single-value returns, integer-base
frames) never triggers it.

### `dispatcher_call_function` bridge for name_hint fidelity

The plain `Executor.call_function/3` doesn't take a `name_hint` arg.
When the dispatcher's `:call_*` routes a nil or non-callable through
it, the resulting `TypeError` drops the `(upvalue 'x')`-style
suffix. Added a new bridge `Executor.dispatcher_call_function/5`
that mirrors `:call`'s nil / non-function / __call branches inline,
so error wording stays in lockstep with the interpreter
(`Lua.ErrorMessagesTest` pins this directly).

### `call_stack` push/pop on dispatcher → dispatcher and dispatcher → lua_closure calls

The pre-B5c-v2 dispatcher didn't update `state.call_stack` around
compiled-closure calls. With closures, OOP, and vararg now
dispatcher-routed, many error-context tests started failing
(`error.call_stack` empty when they expected ≥2 entries).
Push/pop now happens at every dispatcher `:call_*` site for both
`:compiled_closure` (push at call site, pop in `return_one/3` /
`return_multi/3`) and `:lua_closure` (synchronous push around the
`Executor.call_function/3` invocation). `:native_func` and `__call`
metamethod paths don't push, matching the interpreter's behaviour
at executor.ex:880-882.

### Perf gates

- **Hard floor (≤10% regression on any workload):** Met.
- **Soft target (`closures.exs` ≥1.5x interpreter):** Brushed at
  1.22x. Profile attribution: closure-construction allocation,
  upvalue cell allocation, and generic-for iterator dispatch
  dominate. Further closure-benchmark wins require post-B5 work
  (mutable register storage, mutable upvalue cells, escape
  analysis).
- **`dispatcher_vs_interpreter` fib(25):** 1.15x (vs B5a-v2's 1.17x
  baseline). The ~2% loss is the call_stack push/pop that B5c-v2
  added to match the interpreter's error-context invariants.
- **OOP A/B:** 1.07x faster than interpreter. The `:self` lookup,
  table construction, and concatenation dominate over dispatch
  wins.

### Coverage outcome

`closures.exs`, `oop.exs`, `string_ops.exs` all compile end-to-end
(no fallback in any sub-prototype). The encoder's catch-all
`:fallback` clause now only matches the opcodes called out as out
of scope: `:goto` / `:label` (label resolution), `:set_global`
(codegen vestige), and `:bitwise_*` (their own follow-up plan).
