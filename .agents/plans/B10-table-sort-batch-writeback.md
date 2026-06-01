---
id: B10
title: Batch write-back in table.sort plain fast path
issue: 307
pr: null
branch: perf/table-sort-batch-writeback
base: main
status: in-progress
direction: B
---

## Goal

`table.sort` on plain (metatable-less) tables is ~1.44x slower than luerl
at n=100 (46.1µs vs 31.9µs in `benchmarks/table_ops.exs`). The plain-table
fast path (PR #299) reads and sorts efficiently, but the write-back loop in
`lib/lua/vm/stdlib/table.ex` (~312-326) still calls `Table.put/3` once per
index inside an `Enum.reduce`. Each call rebuilds the seven-field
`%Table{}` struct and walks the `order`/`dead` insertion-order bookkeeping,
so writing back an n-element slice is O(n) struct rebuilds.

Replace the per-index reduce with a single map build plus one
`Table.replace_data/2` call. `replace_data/2` already exists
(`lib/lua/vm/table.ex:80`): it sets `data`, rebuilds `order` from
`Map.keys(data)`, and clears `dead` in one struct update. Because sort
rewrites every integer key `1..len` and never depends on the prior
`order`/`dead` state, the wholesale replacement is observably identical to
the per-index writes.

This is a perf-only change. Observable behavior — sorted result, error
behavior, metatable path, comparator-mutation re-fetch — is unchanged.

Target: bring the plain-sort path to ≤ 1.10x luerl at n=100.

## Out of scope

- The metatable-backed sort path (`sort_via_metamethods/4`). It must keep
  reading via `__index` and writing via `__newindex` so metamethod
  observation order matches the reference impl; it is untouched here.
- The comparator/sort algorithm itself (`sort_values/3`) and the read loop
  (`Enum.map(1..len//1, ...)`). Only the write-back step changes.
- Any change to `Table.replace_data/2`, `Table.put/3`, or the `%Table{}`
  struct shape. This plan only changes the *caller* in the stdlib.
- Optimizing `table.insert`, `table.remove`, or other table stdlib ops.
- Array-part / threshold-promotion storage rework (the deferred B7 idea).

## Success criteria

- [ ] `mix format` clean and `mix compile --warnings-as-errors` passes.
- [ ] `mix test` full suite green with no regressions.
- [ ] `mix test test/lua/vm/stdlib/table_test.exs` passes — sort behavior
      (sorted result, custom comparator, comparator that mutates the table,
      stable handling of `len <= 1`) unchanged.
- [ ] `mix run benchmarks/table_ops.exs` shows the plain `table.sort` path
      at ≤ 1.10x luerl at n=100 (down from ~1.44x). New ratio recorded in
      the PR body.
- [ ] No behavior change: the write-back produces the same final table
      contents and `order`/`dead` state as a fresh sequence of `Table.put/3`
      writes over keys `1..len`.

## Implementation notes

Single file: `lib/lua/vm/stdlib/table.ex`, in `sort_plain/5` (~312-326).

Replace the per-index reduce:

```elixir
updated =
  sorted
  |> Enum.with_index(1)
  |> Enum.reduce(table, fn {val, idx}, tbl -> Table.put(tbl, idx, val) end)

{[], %{state | tables: Map.put(state.tables, id, updated)}}
```

with a single map build and one `Table.replace_data/2` call, e.g.:

```elixir
data =
  sorted
  |> Enum.with_index(1)
  |> Map.new(fn {val, idx} -> {idx, val} end)

updated = Table.replace_data(table, data)

{[], %{state | tables: Map.put(state.tables, id, updated)}}
```

Notes:

- `replace_data/2` (`lib/lua/vm/table.ex:80`) sets `data`, rebuilds `order`
  from `Map.keys(data)`, and clears `dead`. Since sort assigns every key
  `1..len`, this is equivalent to the per-key writes that the old reduce
  performed.
- `sorted` always has exactly `len` elements (it is the sorted permutation
  of the `len` values read at the top of `sort_plain/5`), so the rebuilt
  `data` map has keys `1..len` and no stale keys remain.
- Keep the `len <= 1` clause and the comparator-mutation re-fetch
  (`table = Map.fetch!(state.tables, id)`) exactly as they are; only the
  write-back lines change.
- Update the fast-path comment so it describes the single
  `Table.replace_data/2` write-back rather than per-index `Table.put/3`.
  Do not reference the plan id in any source comment.
- Run `mix format` after the edit.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/stdlib/table_test.exs
mix run benchmarks/table_ops.exs
```

Record the "Table Sort" n=100 luerl ratio from the benchmark output in the
PR body (before: ~1.44x; target: ≤ 1.10x). If `mix run benchmarks/table_ops.exs`
honors a bench mode env var, note which mode was used.

## Risks

- **Stale keys after replace.** If `sorted` somehow had fewer elements than
  the original `len`, `replace_data/2` would drop the extra keys. Mitigation:
  sort is a pure permutation of the `len` values read up front, so
  `length(sorted) == len` by construction; verified by the existing sort
  tests in `table_test.exs`.
- **Order/dead semantics divergence.** A future caller could rely on the
  old per-index revive-dead-key behavior. Not a concern here: a freshly
  sorted plain array has all keys `1..len` live, and `replace_data/2`
  clearing `dead` matches the observable result of overwriting every live
  key. Covered by full-suite `mix test`.
- **Benchmark target not met.** If the change lands below the projected win
  and stays above 1.10x, the perf criterion fails. Mitigation: the change
  is still a strict reduction in struct rebuilds and is safe to ship as an
  improvement; record the actual ratio and, if short of target, note a
  follow-up rather than expanding this PR's scope.
