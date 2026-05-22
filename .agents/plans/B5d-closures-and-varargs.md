---
id: B5d
title: Compile closures, varargs, and multi-return — every opcode has a compiled path
issue: null
pr: null
branch: perf/erlang-codegen-closures
base: main
status: ready
direction: B
unlocks:
  - 100% opcode coverage in the codegen (no more fallbacks except for diagnostics)
  - the closures benchmark workload
  - the OOP benchmark workload now fully compiled
---

## Blocked on

- B5a (foundation), B5b (lifecycle), B5c (tables).

## Goal

Cover the remaining opcodes. After this PR, no prototype falls
back to the interpreter for opcode-coverage reasons. Every opcode
in the codegen.

Opcodes added:

- `:closure` — closure construction with upvalue capture.
- `:set_upvalue` — mutate a captured upvalue cell.
- `:get_open_upvalue`, `:set_open_upvalue` — open-cell access for
  upvalues that still reference live caller registers.
- `:vararg`, `:return_vararg` — varargs.
- `:return` with count > 1 — multi-return.
- `:generic_for` — the `for k, v in pairs(t)` family.

## Why now

After B5c, table-heavy code compiles. After this PR, closure-heavy
code does too — which is the dominant remaining real-world Lua
idiom. From here on, additional B5 work is about polish (error
fidelity, B5e) and the wider B-series mutable-data follow-up that
B5 itself does not address.

## Out of scope

- Mixed-mode interpret-from-pc (still all-or-nothing per prototype).
- Cross-prototype optimisation (inlining one Lua function into
  another).
- Error position fidelity. B5e.

## Success criteria

- [ ] Opcodes added: `:closure`, `:set_upvalue`,
      `:get_open_upvalue`, `:set_open_upvalue`, `:vararg`,
      `:return_vararg`, `:return` (count > 1), `:generic_for`.
- [ ] After this PR, the codegen's `:fallback` cases are only:
      genuinely unrecognised opcode shapes (programmer error) or
      explicit opt-outs added by future plans. No production-Lua
      opcode falls back.
- [ ] `mix test` passes; no regression.
- [ ] `mix test --only lua53` does not regress.
- [ ] `LUA_BENCH_MODE=full mix run benchmarks/closures.exs`: lua
      (chunk) beats Luerl by ≥2x.
- [ ] `LUA_BENCH_MODE=full mix run benchmarks/oop.exs`: lua (chunk)
      beats Luerl by ≥1.5x. (OOP is a mix of closures + tables;
      both contribute.)
- [ ] No regression on numeric or table workloads.

## Implementation notes

### Closure construction (`:closure`)

`:closure` creates a `{:lua_closure, sub_proto, captured_upvalues}`
value in the interpreter. The compiled version creates either:

- `{:compiled_closure, mod, fun, captured_upvalues}` if the
  sub-prototype itself compiled.
- `{:lua_closure, sub_proto, captured_upvalues}` if the
  sub-prototype fell back to interpretation.

The codegen checks `sub_proto.compiled_module` at codegen time.
This works because sub-prototypes are compiled in a separate
codegen pass (bottom-up) before the parent.

Upvalue capture: the parent prototype's `:closure` opcode
specifies which upvalue descriptors to populate from which parent
registers / parent upvalues. In the compiled module this becomes
a fresh upvalue tuple constructed inline. Open cells get a fresh
reference (`make_ref/0`) and state.open_upvalues entry; closed
cells inherit from the parent upvalues tuple.

### Upvalue mutation (`:set_upvalue`)

Mirrors the interpreter (`executor.ex:362-367`):

```erlang
CellRef = element(Index + 1, Upvalues),
Value = R_source,
NewUpvalueCells = maps:put(CellRef, Value,
    maps:get(upvalue_cells, State_in)),
State_out = setelement(StateUpvalueCellsIdx, State_in, NewUpvalueCells)
```

Updating a struct field at runtime via `setelement` works because
the State struct's field positions are stable.
`StateUpvalueCellsIdx` is determined at codegen time from
`%State{}`'s field order.

### Open upvalues (`:get_open_upvalue`, `:set_open_upvalue`)

These read/write a cell ref but resolve to either a register (if
the cell is still open) or `state.upvalue_cells` (if closed). The
compiled version mirrors `executor.ex:367-401` directly, including
the open-cell fast path that avoids touching state for the common
case.

### `:vararg`, `:return_vararg`

Vararg storage is on `proto.varargs`. In the compiled function,
this is just a closure-time-captured argument list. The codegen
adds an extra parameter to the compiled function (or threads
varargs through state, depending on what's cleaner; the
interpreter currently uses `proto.varargs`, which works because
proto is a runtime value).

### Multi-return `:return` (count > 1)

B5a covered count = 1. For count > 1, the compiled function
returns `{Values, State}` where Values is a list of length `count`
constructed from the register range. `continue_after_call/11`
unpacks the list into the caller's registers.

For the `{:multi, _}` count form (caller wants all available
returns), the compiled function returns `{Values, State}` with
exactly the multi-return values; the caller's `:call` opcode
handles slot expansion.

### Generic for (`:generic_for`)

Like `:numeric_for` (B5a) but the loop helper calls the iterator
function on every iteration via `Executor.call_function/3` rather
than incrementing a counter. The CPS frame logic from the
interpreter (executor.ex:518-547) translates cleanly to a tail-
recursive Erlang helper.

### Files

- `lib/lua/compiler/erlang/opcodes.ex` — lowering for every
  remaining opcode.
- `lib/lua/compiler/erlang.ex` — remove these from the fallback
  set.
- `test/lua/compiler/erlang_test.exs` — golden tests per opcode.
- `test/lua/compiler/erlang_closures_test.exs` (new) — focused
  tests on closure construction + upvalue lifecycle, since these
  are the trickiest to get right.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

LUA_BENCH_MODE=full mix run benchmarks/closures.exs
LUA_BENCH_MODE=full mix run benchmarks/oop.exs
LUA_BENCH_MODE=full mix run benchmarks/fibonacci.exs   # no regression
LUA_BENCH_MODE=full mix run benchmarks/table_ops.exs   # no regression
```

## Risks

- **Open upvalue lifetime is the trickiest concept in the VM.**
  Cells move from "open" (still referencing a live register) to
  "closed" (value snapshotted into `state.upvalue_cells`) when
  the owning frame returns. The compiled version must replicate
  this transition. The existing `close_open_upvalues_at_or_above/2`
  helper handles it for the interpreter; the compiled `:return`
  opcode needs to call it (promote to `def` if currently `defp`).
- **`:closure` with a fall-through sub-prototype.** A parent
  prototype that compiled but contains an uncompiled sub-prototype
  produces a `:lua_closure` value for the inner function. Mixed-
  mode-in-the-value-graph is fine; mixed-mode-within-a-prototype
  is what we ruled out.
- **Stress test: upvalue chains.** A closure capturing a closure
  capturing a closure tests the upvalue-descriptor walking
  exhaustively. Existing tests in
  `test/lua/compiler/integration_test.exs` cover this; rerun
  against compiled mode.
- **Multi-return with `{:multi, fixed_count}`.** Codegen has to
  match the exact slot-counting the interpreter does for
  expressions like `return f(), g()` where g returns N values.
  Test against the existing multi-return tests.

## Discoveries

(populated during implementation)
