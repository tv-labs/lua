---
id: B6
title: Eliminate per-access Map.fetch! for table dereferencing
issue: null
pr: null
branch: perf/direct-table-refs
base: main
status: ready
direction: B
unlocks:
  - measurable reduction in Map.get/2,3 cost across all table-heavy
    workloads
  - cleaner future ground for B7 (array+hash split)
---

## Goal

Every read or write on a `{:tref, id}` value currently re-fetches the
table struct from `state.tables` via `Map.fetch!(state.tables, id)`.
For nested operations (table-of-tables, metatable chains) this fires
multiple times per opcode. Profiling shows `Map.get/2` + `Map.get/3` is
~6.4% of fib(22) and ~2.6% of the OOP workload — pure indirection
overhead.

The fix: pass the resolved `%Lua.VM.Table{}` struct (or a more compact
mutable representation) directly through the operations that need it,
instead of re-resolving by ID. The tref atom remains the externally
visible identifier — only the executor's internal dispatch changes.

## Why now

This is independent of B4/B5 (dispatch shape) and pays back on every
table workload regardless of how the executor's outer loop is
structured. Pulling it forward also reduces noise in subsequent B4/B5
profiles — every Map.fetch! that shows up there is a real signal, not
incidental indirection.

## Out of scope

- Eliminating `state.tables` entirely. The map of id-to-table is still
  the source of truth; we're just avoiding re-resolution when the
  resolved struct is already in hand.
- Switching to mutable references (ETS, `:persistent_term`,
  process-dict). The state monad is preserved; this is a representation
  change inside the executor, not a semantic change.
- Changing how `Lua.VM.Table` itself stores data. B7 may revisit that.
- Changing the public tref shape. `{:tref, id}` stays as the value Lua
  code passes around.

## Success criteria

- [ ] `Lua.VM.Executor.table_index/3,4` and `table_newindex/4,5` accept
      a resolved table struct (or a thin handle that carries it) where
      they currently re-resolve from state.
- [ ] The hot opcode handlers `:get_field`, `:set_field`, `:get_table`,
      `:set_table`, `:set_list`, `:self` resolve the table struct once
      per opcode, then pass it down.
- [ ] Metatable chain traversal (in `index_value`, `table_newindex`,
      `lookup_metamethod`) resolves each metatable once per step, not
      twice.
- [ ] `mix test` passes; suite pass count does not regress.
- [ ] Profile after merge: combined `Map.get/2 + Map.get/3` self-time
      drops below 3% on fib(22) (currently ~6.4%).
- [ ] Microbenchmarks improve. Stretch target: **10% reduction in
      table_build+sum median** (currently ~180μs, target ~160μs).
      Floor: no workload regresses by more than 2%.

## Implementation notes

### Current pattern (illustrative)

```elixir
# Lua.VM.Executor.table_index/4
defp table_index({:tref, id}, key, state, depth) do
  table = Map.fetch!(state.tables, id)               # fetch #1

  case Table.get_data(table.data, key) do
    nil ->
      case table.metatable do
        {:tref, mt_id} ->
          mt = Map.fetch!(state.tables, mt_id)       # fetch #2
          case Map.get(mt.data, "__index") do
            {:tref, _} = idx_tbl ->
              table_index(idx_tbl, key, state, depth + 1)  # fetch #3
            ...
          end
        ...
      end
    v -> {v, state}
  end
end
```

Three `Map.fetch!`s for a two-level metatable chain.

### Proposed pattern

Two viable shapes:

1. **Pass the resolved struct alongside the tref.** Helpers take
   `(tref, table_struct, ...)`. Slight signature churn but very
   minimal change to data flow.

   ```elixir
   defp table_index({:tref, _} = tref, table, key, state, depth) do
     case Table.get_data(table.data, key) do
       nil ->
         case table.metatable do
           {:tref, _} = mt_tref ->
             mt = Map.fetch!(state.tables, elem(mt_tref, 1))
             ...
         end
       v -> {v, state}
     end
   end
   ```

2. **Pass `{:tref, id, struct}` "fat refs"** through the executor's
   internal channels (registers stay as `{:tref, id}` — Lua code never
   sees the fat form). Helpers can be `tref`-shape-only. This requires
   thinking carefully about when to re-resolve (writes invalidate the
   struct).

Recommend (1). It's clearer, easier to audit, and doesn't introduce a
parallel "internal vs external" tref representation that future
contributors have to track.

### Write-through

When a helper takes a resolved struct and then writes to the table, the
new struct must be committed back to `state.tables` before the next
read that depends on the change. The cleanest discipline: helpers
return both the new struct and the new state, callers always thread
state forward. The `set_field`/`set_table` fast paths landed in
PR #223 already do this — generalize the pattern.

### Where Map.fetch! still belongs

The opcode dispatch (`:get_field` etc.) does need exactly one
`Map.fetch!(state.tables, id)` per opcode entry — that's the
authoritative resolution. The goal is one fetch per opcode, not zero.

The metatable chain is where the savings concentrate: a chain of N
metatables currently costs N+1 fetches; this plan brings it to 1
fetch plus an internal walk that doesn't re-resolve.

### Files

- `lib/lua/vm/executor.ex` — `table_index/4,5`, `table_newindex/4,5`,
  `index_value/5`, `lookup_metamethod/3`, `get_metatable/2`.
- `lib/lua/vm/state.ex` — possibly add a `get_table_struct/2` alias
  that documents the contract.
- `lib/lua/vm/stdlib.ex` — anywhere stdlib re-resolves a tref it
  already holds (e.g. iterating in `table.concat`, `table.sort`).

### Audit checklist

- [ ] grep `Map.fetch!(state.tables` — every site is a candidate.
      Most should be the opcode entry points only.
- [ ] grep `state.tables\[` — same.
- [ ] grep `State.get_table` — same. Callers that already have the
      tref's resolved struct shouldn't be calling this.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Profile to confirm Map.get drop.
mix profile.tprof -e '
fib = "function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end"
lua = Lua.new()
{_, lua} = Lua.eval!(lua, fib)
{chunk, _} = Lua.load_chunk!(lua, "return fib(22)")
Lua.eval!(lua, chunk)
'
# Confirm `Map.get/2` and `Map.get/3` together are < 3% of total.

# Microbenchmarks
mix run benchmarks/fibonacci.exs
mix run benchmarks/table_ops.exs
mix run benchmarks/oop.exs
```

## Risks

- **Stale struct after mutation.** If helper A reads the table struct,
  calls helper B which mutates the same table via state, then helper A
  uses its stale struct — subtle correctness bug. Defense: any helper
  that calls into something which threads state must either re-read
  the struct after the call or not need it after the call. Test
  coverage: metatable `__newindex` chains that mutate the parent table.
- **Signature churn touches many call sites.** The interpreter is
  ~2300 lines; this is a wide refactor. Mitigation: dialyzer + the
  full test suite catch shape mismatches; land the change with the
  audit checklist completed.
- **Stdlib helpers that take only a tref now need state too.** Public
  helpers like `Lua.VM.Executor.table_index/3` are documented; their
  signatures should stay compatible. Add internal `_with_struct/N`
  variants and keep the public `/3` arity calling the new internals
  with a fresh resolution.
- **Diminishing returns.** If the Map.get cost is bound up in the
  `table.data` per-key Map.get rather than the per-tref Map.fetch!,
  this plan moves less than expected. That cost is structural to using
  Erlang maps for table data and is B7's territory.

## Discoveries

(populated during implementation)
