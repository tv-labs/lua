---
id: B9
title: "stdlib hot paths: string.format iolist + plain-table fast paths"
issue: 273
pr: 299
branch: perf/stdlib-hot-paths
base: main
status: review
direction: B
unlocks:
  - closes most of the string.format gap vs Luerl (1.77x) and C Lua (5.5x)
  - removes per-slot Executor dispatch overhead from table.sort / table.concat on plain tables
---

## Goal

Close three stdlib-side performance gaps surfaced by the benchmark suite.
All three are pure constant-factor wins on hot paths; observable behavior
is byte-for-byte identical before and after.

1. **`string.format` iolist accumulation.** `format_string/3` in
   `lib/lua/vm/stdlib/string.ex` (around lines 333-350) builds its result
   with per-character binary concatenation (`acc <> <<char::utf8>>` and
   `acc <> str`). Each literal byte forces a binary reallocation, making
   format O(n^2) in the length of the format string. Accumulate an iolist
   instead and collapse it once with `IO.iodata_to_binary/1` at the base
   case. This is the dominant cost in the 1.77x-vs-Luerl / 5.5x-vs-C-Lua
   gap for `string.format`.

2. **`table.sort` / `table.concat` plain-table fast path.** Both
   functions in `lib/lua/vm/stdlib/table.ex` route every element read
   through `Executor.table_index/3` and (for sort) every write-back
   through `Executor.table_newindex/3`. For a plain integer-indexed table
   with no metatable these dispatch calls do ~200 extra `Map.fetch!` +
   branch checks per 100-element sort. When `table.metatable == nil`,
   read directly with `Lua.VM.Table.get_data/2` and write directly with
   `Lua.VM.Table.put/3` + a single `Map.put/3` into `state.tables`,
   skipping the metamethod-chain machinery entirely. This mirrors the
   no-metatable fast path that already exists in
   `Executor.table_newindex/5`.

3. **`apply_width_flags` byte-length padding.** `apply_width_flags/3` in
   `lib/lua/vm/stdlib/string.ex` (around lines 815-836) measures the
   string with `String.length/1` (O(graphemes), full UTF-8 decode) to
   decide padding. The output of `%d` / `%f` / `%x` etc. is by definition
   single-byte ASCII, so `byte_size/1` gives the same width count without
   the grapheme walk.

## Out of scope

- The O(n^2) insertion-sort path used when a user-supplied Lua comparator
  is passed (`sort_values/2` and `insert_sorted/4` in `table.ex`). Latent
  but no current benchmark exercises it; defer until a comparator workload
  motivates it. The comparator branch must keep going through
  `Executor.call_function/3` and the existing read/write-back code so its
  semantics (state threading, `__index`/`__newindex` observation) are
  unchanged.
- `Lua.VM.Table.put/3`'s `order_tail` allocation on every write. Defer;
  re-profile after #271 to see whether it is still the ceiling.
- Any change to the comparator-driven `table.sort` write-back, error
  messages, or argument validation.

## Success criteria

- [ ] `mix format` produces no diff.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` is green with no regressions (same pass/fail counts as
      `main` before the change).
- [ ] `mix test --only lua53` shows no regression in suite pass count.
- [ ] `string.format` builds its result via an iolist with a single
      `IO.iodata_to_binary/1` at the base case; no `acc <> ...` binary
      concatenation remains in `format_string/3`.
- [ ] `table.sort` and `table.concat` read plain (metatable-less) tables
      via `Lua.VM.Table.get_data/2`, and `table.sort` writes them back via
      `Lua.VM.Table.put/3` + `Map.put/3`, only when
      `table.metatable == nil`.
- [ ] Tables that DO have a metatable still go through
      `Executor.table_index/3` / `Executor.table_newindex/3` (the
      `__index` / `__newindex` / `__len` observation path is unchanged).
- [ ] `apply_width_flags/3` uses `byte_size/1` rather than
      `String.length/1` for the width comparison.
- [ ] No behavioral change: existing
      `test/lua/vm/stdlib/string_test.exs` and
      `test/lua/vm/stdlib/table_test.exs` pass unmodified (no test
      expectations changed).

## Implementation notes

Files to touch:

- `lib/lua/vm/stdlib/string.ex`
  - `format_string/3` (~lines 333-350): change `acc` from a binary to an
    iolist. The `""` base clause returns `IO.iodata_to_binary(acc)` (the
    accumulator should be reversed-append-safe — prepend with
    `[acc | piece]` is wrong for order; append with `[acc, piece]` keeps
    order and is still O(1) per step since iolists nest). Concretely:
    `format_string("", _args, acc), do: IO.iodata_to_binary(acc)`;
    the `%%` clause becomes `format_string(rest2, args, [acc, "%"])`;
    the spec clause becomes `format_string(rest2, remaining_args, [acc, str])`;
    the literal clause becomes
    `format_string(rest, args, [acc, <<char::utf8>>])`. The initial caller
    `string_format/2` passes `""` today; `""` is a valid iodata seed so it
    can stay, or switch to `[]`.
  - `apply_width_flags/3` (~lines 815-836): replace
    `if String.length(str) >= width` with
    `if byte_size(str) >= width`. The padding branches
    (`String.pad_leading/3`, `String.pad_trailing/3`,
    `String.slice/2`) are left unchanged — they already operate on the
    single-byte ASCII output of the numeric specifiers.

- `lib/lua/vm/stdlib/table.ex`
  - `table_sort/2` (~lines 262-301): after resolving `len` (keep the
    existing `Executor.table_length/2` call so `__len` is still observed),
    branch on the table's metatable. Fetch the table once via
    `Map.fetch!(state.tables, id)` (destructure the `id` from the `tref`).
    When `table.metatable == nil`, build `values` with
    `Lua.VM.Table.get_data(table.data, i)` over `1..len` and write the
    sorted slice back with a single fold that threads an updated `data`
    map / table struct and ends with one `Map.put(state.tables, id, ...)`
    — i.e. use `Lua.VM.Table.put/3` per slot on the in-memory struct and
    store the result once. When the metatable is present, fall through to
    the existing `Executor.table_index/3` read loop and
    `Executor.table_newindex/3` write-back loop unchanged. The
    comparator-vs-default sort (`sort_values/2`) is untouched.
  - `table_concat/2` (~lines 180-247): same metatable branch for the
    element read loop (~lines 218-244). When `table.metatable == nil`,
    read each slot via `Lua.VM.Table.get_data(table.data, idx)`; otherwise
    keep `Executor.table_index/3`. The `Executor.table_length/2` call for
    the default `j` must stay (it observes `__len`). The
    `is_binary`/`is_number`/error handling for each value, and the final
    `Enum.join/2`, are unchanged.

Subtleties:

- `Lua.VM.Table.get_data/2` already normalizes the key (it does
  `Map.get(data, normalize_key(key))`), so integer indices behave the same
  as the `Executor.table_index/3` path for plain tables. Do not
  re-normalize.
- The fast path must only trigger when `metatable == nil`. Any non-nil
  metatable (even one without `__index`/`__newindex`/`__len`) keeps the
  Executor path, to preserve identical observable access ordering against
  the reference impl.
- Keep `IO.iodata_to_binary/1` at exactly one place (the base case) so a
  single binary is produced; do not intersperse `to_string`/`<>` collapses.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/stdlib/string_test.exs
mix test test/lua/vm/stdlib/table_test.exs
mix test
mix test --only lua53
```

Capture `mix test` and `mix test --only lua53` pass/fail counts on `main`
before changing code and confirm the post-change counts match. The
`string_test.exs` and `table_test.exs` runs must pass without editing any
test expectations, since the change is behavior-preserving.

## Risks

- **iolist ordering bug.** Appending in the wrong order (`[piece | acc]`)
  reverses the output. Mitigation: append as `[acc, piece]` and rely on
  the existing `string_test.exs` `%%`, literal-text, and multi-spec cases
  to catch a regression.
- **Fast path diverges from metatable path semantics.** If `get_data`/`put`
  key normalization differed from `table_index`/`table_newindex`, plain
  tables could read/write the wrong slot. Mitigation: both paths funnel
  through `normalize_key/1`; gate strictly on `metatable == nil` and keep
  metatable tables on the Executor path. `table_test.exs` covers both
  plain and metatable-backed sort/concat.
- **`byte_size` vs `String.length` for non-ASCII.** `%s` can carry
  multi-byte content, where `byte_size` over-counts graphemes. This change
  is scoped to `apply_width_flags/3`, which is fed the numeric/ASCII
  specifier output; verify no `%s` width test regresses in
  `string_test.exs`. If a `%s` width case exists and relies on grapheme
  width, restrict the `byte_size` swap to the numeric specifiers only.
- **Out-of-scope creep.** The comparator insertion sort is tempting to
  "fix while here." Do not. Leave `sort_values/2` / `insert_sorted/4` and
  `Table.put` `order_tail` exactly as-is; log any new finding under
  `## Discoveries`.

## What changed

Shipped as PR #299.

Files touched:

- `lib/lua/vm/stdlib/string.ex`
  - `format_string/3` now accumulates an iolist (`[acc, piece]`) and
    materializes once with `IO.iodata_to_binary/1` at the `""` base
    clause. The initial seed in `string_format/2` switched from `""` to
    `[]`. No `acc <> ...` concatenation remains.
  - `apply_width_flags/3` compares width with `byte_size/1` instead of
    `String.length/1`. This also brings `%s` width into line with
    PUC-Lua, which measures by bytes.
- `lib/lua/vm/stdlib/table.ex`
  - Added `alias Lua.VM.Table`.
  - `table_concat/2` binds the `tref` id, fetches the table once, and
    reads slots via `Table.get_data/2` when `metatable == nil`; the
    metatable case keeps `Executor.table_index/3`. Per-element coercion
    extracted into `concat_value/2`.
  - `table_sort/2` branches on `metatable`: `sort_plain/5` reads directly
    from `data`, sorts, re-fetches the table (so a state-mutating
    comparator is honored), writes back with `Table.put/3` per slot, and
    stores once with `Map.put/3`. `sort_via_metamethods/4` preserves the
    original `Executor.table_index/3` read + `table_newindex/3`
    write-back for metatable-backed tables.

Verification: `mix test` 2092 passed / 19 skipped / 1 excluded and
`mix test --only lua53` 17 passed / 12 skipped — both identical to `main`.

No follow-up issues opened; no `## Discoveries`.
