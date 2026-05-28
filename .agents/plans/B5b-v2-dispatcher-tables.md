---
id: B5b-v2
title: Dispatcher table opcodes — make table-heavy workloads bypass the interpreter
issue: 271
pr: 275
branch: perf/dispatcher-tables
base: main
status: review
direction: B
unlocks:
  - ~2x speedup on table_ops benchmarks
  - the full OOP benchmark workload (depends on tables + closures)
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (dispatcher foundation). **Unblocked**: PR #237 merged.

## Goal

Extend `Lua.VM.Dispatcher` and `Lua.Compiler.Bytecode` to lower the
table opcode family plus `:numeric_for`. After this PR, all four
`table_ops` benchmarks compile end-to-end and stay out of the
interpreter fallback path, plus the orchestrators in the `closures`
and `string_ops` benchmarks.

The original B5 third spike measured **2.1x faster than interpreter**
on run_table_sum(1000). The dispatcher should land at a similar or
slightly worse ratio (the spike used a compiled BEAM module; the
dispatcher pays per-step dispatch).

## Out of scope

- `:closure` opcode and varargs → **B5c-v2**.
- `:while_loop`, `:repeat_loop`, `:generic_for` → not blockers for the
  named benchmarks. Defer.
- `:break` inside `:numeric_for` → handled as fallback for now. Add to
  B5c-v2 if needed by benchmarks.
- `:set_list` with `{:multi, _}` (multi-return spread into table) →
  fallback.
- Multi-return `:call` / `:return` → still fallback.
- Mutable table storage. `Table.put/3` allocation churn is the
  ceiling for table workloads on the BEAM; not addressed here.
- Mutable register storage / `setelement/3` elimination → its own plan
  if perf-justified after this lands.
- Metamethod dispatch via `__index` / `__newindex` short-circuiting.
  The dispatcher delegates to existing `Executor` helpers, which
  handle metamethods.
- Error position fidelity in the dispatcher → **B5d-v2**. All new
  bridges pass `line: 0`.

## Success criteria

- [ ] `Lua.Compiler.Bytecode` learns encoders for `:new_table`,
      `:get_table`, `:set_table`, `:set_field`, `:set_list` (basic
      non-multi-return form), `:length`, and `:numeric_for` (body
      encoded recursively, falls back if body contains an uncovered
      opcode or `:break`).
- [ ] `Lua.VM.Dispatcher` gains one `case` branch per new opcode plus
      the for-loop continuation marker.
- [ ] `Lua.VM.Executor` exposes `dispatcher_*` bridges for the new
      slow paths (`dispatcher_get_table`, `dispatcher_set_table`,
      `dispatcher_set_field`, `dispatcher_length`,
      `dispatcher_coerce_numeric_for_controls`,
      `dispatcher_close_open_upvalues_at_or_above`).
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` passes, no regressions vs. main.
- [ ] `mix test --only lua53` passes.
- [ ] `test/lua/vm/leak_regression_test.exs` still passes.
- [ ] All four `table_ops` benchmark functions compile to bytecode
      end-to-end (no `:fallback` on any of them).
- [ ] Closures benchmark `run_closures` orchestrator compiles
      (its sub-prototype `make_counter` may still fall back because
      it emits `:closure` — that's B5c-v2).
- [ ] No workload regresses by more than 10% vs. interpreter on the
      `dispatcher_vs_interpreter`-style A/B harness.
- [ ] Soft target: `run_table_sum(1000)` ≥1.5x interpreter when
      compiled. Hard floor: ≥1.0x (no regression).

## Implementation notes

### 1. Bytecode encoder (`lib/lua/compiler/bytecode.ex`)

Add `@op_*` constants for the new opcodes. The B5a encoder ends at
`@op_source_line 29`; slot 25 freed by removed `@op_test_true` is
reusable. Pick a contiguous block starting at 30:

- `@op_new_table 30`
- `@op_get_table 31`
- `@op_set_table 32`
- `@op_set_field 33`
- `@op_set_list 34`
- `@op_length 35`
- `@op_numeric_for 36`

Per-opcode encoders:

- `:new_table` → `{tag, dest}`. Array/hash hints discarded — the
  executor handler also ignores them. (`_array_hint`, `_hash_hint`.)
- `:get_table` → `{tag, dest, table_reg, key_reg, name_hint}`.
- `:set_table` → `{tag, table_reg, key_reg, value_reg, name_hint}`.
- `:set_field` → `{tag, table_reg, name, value_reg, name_hint}`.
- `:set_list` only the basic, non-multi-return form (third element
  is a positive integer, not `{:multi, _}`). `{tag, table_reg,
  start, count, offset}`.
- `:length` → `{tag, dest, source}`.
- `:numeric_for` → `{tag, base, loop_var, body_bytecode}`. `body` is
  encoded recursively. If the body contains any uncovered opcode
  *or* a `:break` atom, the whole `:numeric_for` returns `:fallback`.

`encode_list/2` already strips `:source_line` opcodes and that
propagates into the recursive body encoding for free.

### 2. Dispatcher (`lib/lua/vm/dispatcher.ex`)

Mirror the new constants in the dispatcher's `@op_*` block. Add one
`case` branch per opcode inside `dispatch/8`:

- `@op_new_table` — call `State.alloc_table/1`, `setelement(dest+1,
  regs, tref)`. Single line.
- `@op_get_table` — inline the executor's tref + integer/binary-key
  fast path. Fall through to a new `Executor.dispatcher_get_table/6`
  bridge for non-tref, non-fast-key, or metatable cases.
- `@op_set_table` — tref fast path: `Executor.dispatcher_set_table/6`
  (wraps `table_newindex`). Non-tref: bridge raises
  `raise_index_type_error`. Mirrors `:set_field` from B5a.
- `@op_set_field` — same as `:set_table` but with a constant name.
  Bridge to a new `Executor.dispatcher_set_field/6`.
- `@op_set_list` — inline tref reduce-loop, identical to the
  executor's non-multi branch. No bridge needed.
- `@op_length` — integer fast path (`{:tref, _}` with no `__len`
  metatable → `Value.sequence_length(table.data)`); bridge to
  `Executor.dispatcher_length/4` for the metamethod path and
  non-tref values.
- `@op_numeric_for` — the most involved. Inline the loop setup:
  1. Coerce the three control registers via
     `Executor.dispatcher_coerce_numeric_for_controls/3`.
  2. Write the canonical numbers back to `base`, `base+1`, `base+2`.
  3. Check `should_continue`. If false: continue at `pc+1`.
  4. If true: write counter to `loop_var`, call
     `Executor.dispatcher_close_open_upvalues_at_or_above/2`, then
     dispatch into `body_bytecode` with a new continuation marker
     `{:cps_for, base, loop_var, body_bytecode, code, pc + 1}`
     pushed onto `cont`.

  Extend `finish_body/6` with a third clause matching the for-loop
  continuation tuple: increment counter, re-check, either re-enter
  the body (push the marker again) or pop back to outer `(code,
  pc+1)`.

### 3. Executor bridges (`lib/lua/vm/executor.ex`)

Add public bridges. All accept `line: 0` for now (line attribution
is B5d-v2):

```elixir
def dispatcher_get_table({:tref, _} = tref, key, state, proto, name_hint), do: ...
def dispatcher_get_table(value, key, state, proto, name_hint), do: ...

def dispatcher_set_table({:tref, _} = tref, key, value, state, _proto, _hint), do: ...
def dispatcher_set_table(value, _key, _value, _state, proto, name_hint), do: ...
  # raises raise_index_type_error/4

def dispatcher_set_field({:tref, _} = tref, name, value, state, _proto, _hint), do: ...
def dispatcher_set_field(value, _name, _value, _state, proto, name_hint), do: ...

def dispatcher_length(value, state, proto, _name_hint), do: ...
  # wraps try_unary_metamethod("__len", ...) + Value.sequence_length

def dispatcher_coerce_numeric_for_controls(init, limit, step), do: ...
  # wraps coerce_numeric_for_controls/3

def dispatcher_close_open_upvalues_at_or_above(state, threshold), do: ...
  # wraps close_open_upvalues_at_or_above/2
```

All wrap existing `defp` helpers — fidelity-for-free with the
interpreter.

### 4. Tests

#### `test/lua/compiler/bytecode_test.exs` — update

- Flip `:new_table causes fallback` → `:new_table compiles`.
- Flip `for-loops cause fallback` → split into:
  - `numeric for-loop compiles`,
  - `generic for-loop causes fallback`.
- Add minimal tests for `:get_table`, `:set_table`, `:set_field`,
  `:length`, `:set_list` (basic form).
- Keep `:set_list multi-return causes fallback` test.
- Keep `:break inside :numeric_for causes fallback` test.

#### `test/lua/vm/dispatcher_test.exs` — add goldens

One golden per new opcode plus benchmark-shaped end-to-end goldens:

- `run_table_build(50)`, `run_table_sum(50)`, `run_table_map_reduce(50)`
  reference shapes assert dispatcher path and correct result.
- Nested numeric_for (one loop inside another).
- `:set_field` on the result of `:new_table` (chained access).
- `:length` after `:set_list` (`return #{1,2,3}` style).

### 5. Benchmark verification

- `MIX_ENV=benchmark mix run benchmarks/table_ops.exs` — sanity-check
  no crashes, capture median.
- `MIX_ENV=benchmark mix run benchmarks/dispatcher_vs_interpreter.exs`
  — if needed, adapt to target a table workload to verify the
  dispatcher path matches the soft target.

### Files

- `lib/lua/compiler/bytecode.ex` — 7 new opcodes + tag accessors.
- `lib/lua/vm/dispatcher.ex` — 7 new case branches + for-loop
  continuation handling in `finish_body/6`.
- `lib/lua/vm/executor.ex` — 6 new `dispatcher_*` public bridges.
- `test/lua/compiler/bytecode_test.exs` — updated for new coverage.
- `test/lua/vm/dispatcher_test.exs` — new goldens.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/dispatcher_test.exs
mix test test/lua/compiler/bytecode_test.exs
mix test test/lua/vm/leak_regression_test.exs

# Confirm all four table_ops functions compile end-to-end.
mix run -e '
fns = [:run_table_build, :run_table_sort, :run_table_sum, :run_table_map_reduce]
src = File.read!("benchmarks/table_ops.exs")
# Pull the inlined `table_def` and assert each function ends up with
# a non-nil bytecode field.
'

# Perf (informational, not a hard gate):
MIX_ENV=benchmark mix run benchmarks/table_ops.exs
MIX_ENV=benchmark mix run benchmarks/dispatcher_vs_interpreter.exs
```

## Risks

- **`:numeric_for` continuation handling complicates `finish_body/6`.**
  B5a's dispatch loop is tight because the continuation stack only
  carries `{code, pc}` post-test markers. Adding a tagged for-loop
  continuation expands the `finish_body` head from 2 clauses to 3.
  Mitigation: profile after landing; if `finish_body` shows up in
  the hot path more than ~5%, consider a flat PC bytecode (separate
  follow-up plan).
- **Bridge overhead vs. inlining.** Each `dispatcher_*` call costs a
  function frame. For `:get_table` / `:set_table`, the executor's
  slow path is already several calls deep — bridging adds at most
  one frame. For `:length`, the metamethod path is rare. Should be
  invisible.
- **Test churn from flipped fallbacks.** Two tests in
  `bytecode_test.exs` currently assert that `:new_table` and `for`
  cause fallback. Those tests must flip. Risk low — the flip is
  mechanical.
- **`Table.put/3` allocation churn** (out of scope per parent plan).
  If `table_ops` benchmarks underperform the spike's 2.1x target,
  the answer is mutable table storage, not more dispatch work.
  Document the ceiling; don't chase it here.

## Discoveries

### `:call` with `result_count == 0` was needed to compile `run_table_sort`

The original B5b coverage list did not include `:call_zero` (statement
calls). `run_table_sort` calls `table.sort(t)` at statement position,
which the codegen lowers to `{:call, base, 1, 0, name_hint}`. Without
coverage, `run_table_sort` falls back even though `:numeric_for` /
`:set_table` etc. are all supported.

Added `@op_call_zero 25` (reusing the slot freed by the removed
`@op_test_true`). The dispatcher's `:call_one` and `:call_zero`
clauses share the same compiled-closure / interpreter-bridge shape;
the only difference is the frame slot's "where to write the result"
marker (`base` integer vs `:discard` sentinel) and the bridge
discards the native-call result list.

This kept the PR honest to its acceptance criterion — "all four
table_ops benchmarks compile end-to-end" — without expanding to the
broader multi-return machinery, which stays B5c-v2.

### string_ops orchestrators do **not** fully compile

The issue claimed "orchestrators in `closures` and `string_ops`"
would compile. Closures' `run_closures` does (the inner `make_counter`
falls back as expected because of `:closure`). But both
`string_ops` orchestrators end with `return table.concat(...)` /
`return string.format(...)`, which the codegen lowers as
`:call` with `result_count = -1` followed by `:return_vararg` —
multi-return shapes that are explicitly out of scope per the parent
plan ("multi-return calls, vararg ... fall back").

Three paths considered:

1. Extend scope to handle `:call` with `result_count = -1` +
   `:return_vararg`. This pulls in the `multi_return_count`
   threading and the vararg-args collection machinery, which is the
   exact domain of B5c-v2.
2. Stay narrow and accept the partial outcome.
3. Mid-ground: handle `:return_vararg` alone for single-return-value
   callees only. Brittle — the codegen doesn't distinguish, so the
   dispatcher would have to look at the callee at runtime.

Picked (2): stay scoped. Documented here so a future B5c-v2 can pick
this up alongside the rest of multi-return.

### `:break` inside `:numeric_for` forces fallback

The interpreter's `:break` opcode unwinds the continuation stack via
`find_loop_exit/1`, which scans for the nearest `{:loop_exit, _}`
marker. Reproducing that in the dispatcher would require mixing
`{code, pc}` post-test markers with `{:loop_exit, _}` markers and
extending `find_loop_exit` to walk dispatcher-side `cont` stacks.
That's plumbing churn for what's effectively a B5c-v2 concern (the
generic-for / while-loop / break family all want the same
machinery).

The encoder rejects `:numeric_for` bodies containing a `:break`
opcode upfront, walking the body recursively to catch `:break`s
buried inside `:test` branches. The whole enclosing prototype falls
back. Pinned with a `test/lua/compiler/bytecode_test.exs` case.

### Numeric-for continuation marker integrates cleanly

The B5a `cont` stack carried only `{code, pc}` post-test resume
points. Adding `{:cps_for, base, loop_var, body_bc, code, pc + 1}`
markers expands `finish_body/6` to three clauses. The marker stays
on the stack across each loop iteration — re-pushed when the body
restarts — so nested numeric-fors compose naturally on the same
stack. No perf hit measurable on fib (the marker doesn't fire on
non-loop workloads).

### Perf is a soft win on `table_ops`, healthy on fib

Mini-bench results (`mix run -e`, 100–200 iter median, warmed):

| Workload                    | Dispatcher | Interpreter | Speedup |
|-----------------------------|------------|-------------|---------|
| `run_table_build(500)`      | 90 µs      | 106 µs      | 1.18x   |
| `run_table_sum(500)`        | 121 µs     | 129 µs      | 1.06x   |
| `run_table_sum(1000)`       | 254 µs     | 289 µs      | 1.13x   |
| `run_table_map_reduce(500)` | 241 µs     | 245 µs      | 1.02x   |
| `fib(22)`                   | 12.2 ms    | 18.7 ms     | 1.54x   |

The hard floor (no regression) is met across the board. The soft
target (≥1.5x on `run_table_sum(1000)`) is **not** met — the
dispatcher is at 1.13x. Profile attribution: `Table.put/3`
allocation churn and `setelement/3` register writes dominate the
table workloads, exactly as the parent plan flagged ("table-storage
churn is the post-B5b ceiling, not addressed here").

fib (which has neither cost) lands at 1.54x, well above B5a-v2's
1.17x median — a sign the table-opcode additions did not push the
arithmetic path off any inlining cliff.

The follow-up plan for closing the gap on table workloads is
mutable table storage, not more dispatch work.

### `set_list_into_table` calls `Lua.VM.Table.put/3` directly

The interpreter wraps the same loop in `State.update_table/3` plus a
`Table.put/3` per iteration. The dispatcher's inline reduce-loop
calls `Lua.VM.Table.put/3` against the table struct and only writes
back to `state.tables` once via `State.update_table/3` at the end.
Single-allocation per iteration matches the interpreter; the
encoding boundary doesn't introduce a new allocation pattern.

## What changed

- New: 7 table opcodes + `:numeric_for` + `:call_zero` in
  `lib/lua/compiler/bytecode.ex` and `lib/lua/vm/dispatcher.ex`.
  Six `dispatcher_*` public bridges in `lib/lua/vm/executor.ex`.
- New: `:cps_for` continuation marker in
  `Lua.VM.Dispatcher.finish_body/6` for numeric-for body
  completion; `:discard` sentinel in the frame's `base` slot for
  statement-call result suppression.
- Modified: `test/lua/compiler/bytecode_test.exs` — flipped two
  fallback assertions (`:new_table`, "for-loops cause fallback"),
  added three: `:generic_for causes fallback`, `while-loops cause
  fallback`, `:break inside numeric_for causes fallback`. The
  "cascade independence" sibling-fallback test was retargeted to
  use a multi-return shape (`return next(t)`) since `{1, 2, 3}` now
  compiles.
- New: 21 dispatcher goldens (7 table opcodes, 6 numeric_for shapes,
  4 table_ops benchmark functions, 1 `:call_zero`, plus a setup
  block that compiles all four `run_table_*` benchmarks and asserts
  they're `:compiled_closure`).
- Tests: **1882 → 1902** (+20), **0 failures**, 25 skipped.
- PR: https://github.com/tv-labs/lua/pull/275
