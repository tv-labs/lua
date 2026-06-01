---
id: B11
title: batch insert for :setlist instead of per-key Table.put
issue: 308
pr: null
branch: perf/setlist-batch-insert
base: main
status: in-progress
direction: B
---

# B11 — batch insert for `:setlist` instead of per-key `Table.put`

## Goal

Make `:set_list` (table constructor backfill) accumulate its
`{index, value}` pairs and apply them to the `%Lua.VM.Table{}` in a
single mutation, instead of walking one key at a time through
`Table.put/3` and paying the seven-field struct rebuild on every slot.

Table construction is currently **1.14× slower than luerl** at `n=100`
(25.5µs vs 22.3µs in `benchmarks/table_ops.exs`). Luerl amortises the
same work to a single `:array:set` mutation. Batching the inserts should
close most of that gap. Target: **≤ 1.05× luerl** at `n=100`, with no
regression at larger `n`.

This is a **performance-only** change. Observable behavior — stored
values, iteration order, dead-key (nil-clear) semantics, and the public
`Lua.*` API — must remain identical.

## Out of scope

- The B7-style array/hash split for `Lua.VM.Table` (deferred — see
  ROADMAP "Tried and deferred"). This plan does not change the table's
  underlying representation, only how `:set_list` writes into it.
- Any change to `Table.put/3`, `Table.put_data/3`, or the
  `order`/`order_tail`/`dead` invariants themselves beyond what is
  needed to expose a correct batch-write path.
- Other hot dispatch paths (`set_table`, `set_field`, `rawset`). Only
  the `:set_list` opcode is in scope.
- Changes to the encoder/compiler that emits `:set_list`.

## Success criteria

- [ ] `mix test` — full suite stays green, no regressions in pass count.
- [ ] `mix test test/lua/vm/stdlib/table_test.exs` passes.
- [ ] `mix run benchmarks/table_ops.exs` records a `setlist` /
      table-build ratio of **≤ 1.05× luerl** at `n=100`, with the ratio
      recorded in the PR body.
- [ ] No regression at larger `n` (`n=1000`) in the table-build
      workload — record the multi-`n` numbers in the PR body.
- [ ] `mix compile --warnings-as-errors` is clean.
- [ ] `mix format` is clean.
- [ ] Iteration order and dead-key semantics are unchanged: a constructor
      that backfills consecutive integer keys yields the same `pairs`/
      `ipairs` order and the same nil-clear behavior as the per-`put`
      loop (covered by an added/updated test in `table_test.exs` if not
      already covered).

## Implementation notes

Three files, two mirror sites plus a shared helper:

1. **`lib/lua/vm/table.ex`** — `Table.replace_data/2` already exists
   (line ~79), but it rebuilds `order` from `Map.keys(data)` and clears
   `dead`. That is **not** behavior-identical to the per-slot
   `Table.put/3` loop, which preserves insertion order via `order_tail`
   and revives dead keys in place. Do **not** route `:set_list` through
   `replace_data/2` naively. Either:
   - add a focused batch helper (e.g. `Table.put_many/2` taking the
     table and an ordered list of `{key, value}` pairs) that folds the
     pairs into `data` while maintaining `order`/`order_tail`/`dead`
     exactly as repeated `put/3` would, but rebuilding the struct only
     once at the end; or
   - if analysis shows the constructor backfill only ever targets
     fresh consecutive integer keys (no dead-key revival, no overwrite),
     document that precondition and use a narrower fast path. Confirm
     this against the encoder before relying on it; otherwise use the
     general `put_many/2`.
   The win comes from rebuilding the `%Table{}` struct once instead of
   `count` times; the data map and order lists can still be built with
   an `Enum.reduce`/recursion over the slots.

2. **`lib/lua/vm/dispatcher.ex`** — `set_list_into_table/6` (~1410–1415),
   called from the `@op_set_list` arm at ~769. Replace the per-slot
   `Table.put/3` recursion with: collect the `{offset + i + 1, value}`
   pairs from `regs`, then apply the batch helper once. Keep the inline,
   allocation-light register walk; only the table mutation collapses to
   a single struct rebuild.

3. **`lib/lua/vm/executor.ex`** — mirror the change in **both**
   `:set_list` handlers so the two executors stay in lockstep:
   - the integer-count form, `do_execute([{:set_list, table_reg, start,
     count, offset} | rest], ...)` (~1832), including its `count == 0`
     multi-return branch; and
   - the `{:multi, init_count}` form, `do_execute([{:set_list, ...,
     {:multi, init_count}, offset} | rest], ...)` (~1802).
   Both currently `Enum.reduce` over `Table.put/3`; route them through
   the same batch helper added in step 1.

Run `mix format` after each change. Keep the dispatcher and executor
implementations structurally parallel — they are intentional mirrors.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/stdlib/table_test.exs
mix run benchmarks/table_ops.exs
```

Record the `table_ops` luerl ratio at `n=100` and `n=1000` in the PR
body (use `LUA_BENCH_MODE=full` if the multi-`n` sweep is needed for the
recorded numbers). Confirm the ratio is ≤ 1.05× luerl at `n=100` and not
regressed at `n=1000`.

## Risks

- **Behavior drift via `replace_data/2`.** The biggest risk: routing
  `:set_list` through the existing `replace_data/2` would clear `dead`
  and rebuild `order` from `Map.keys/1`, silently changing iteration
  order and dropping the in-place dead-key invariant. Mitigation: use a
  batch helper that preserves `order`/`order_tail`/`dead` exactly as the
  `put/3` loop does; cover with the table_test assertion in the success
  criteria.
- **Two sites falling out of sync.** Dispatcher and executor must mirror
  each other. Mitigation: share one helper in `table.ex` so both call
  the same logic; review both `:set_list` handlers (3 arms total) in the
  diff.
- **No measurable win.** Per ROADMAP's Direction-B lessons, BEAM
  optimisations are subtle and `setelement/3`-style churn dominates some
  workloads. The struct rebuild is `count` allocations today, so
  collapsing to one should help, but re-baseline before claiming the
  win and record the actual ratio. If the win does not materialise,
  surface it rather than shipping a neutral change as a perf PR.
- **Multi-return / `count == 0` edge case.** The executor's
  `count == 0` branch backfills `state.multi_return_count` values from a
  vararg/multi-return call. Ensure the batch path handles `total == 0`
  (empty) and the multi-return slot offsets identically to the current
  reduce.
