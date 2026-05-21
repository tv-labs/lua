---
id: B7
title: Split table storage into array + hash parts
issue: null
pr: null
branch: perf/table-array-hash-split
base: main
status: ready
direction: B
unlocks:
  - O(1) `t[#t + 1] = x` (supersedes A10b)
  - amortized O(1) `#t` length
  - lower memory ratio vs Luerl on table-heavy workloads
  - ipairs becomes a tight loop, not a Map walk
---

## Goal

Reshape `Lua.VM.Table` so contiguous integer keys (the "array part")
live in a tuple-backed structure and other keys (the "hash part") stay
in the current map. This is what PUC-Lua and Luerl both do internally.

For the common case `t = {1, 2, 3, ...}` or `for i = 1, n do t[i] = ...`,
this:

- Cuts memory: the array part is a tuple of N values plus an integer
  length, not an N-entry map (~6x smaller per element).
- Cuts time: integer-indexed reads are `elem/2`, integer-indexed
  contiguous writes are `setelement/3` or `Tuple.append/2`. No map
  hashing, no key normalization.
- Makes `#t` O(1) (length is stored, not scanned).
- Makes `ipairs` a fast loop over the tuple, not a sequence of
  `Map.get` calls.

## Why now

The B-series wins so far closed the per-opcode dispatch gap. The
remaining table-workload gap vs Luerl (~1.27x slower on
table_build+sum) is dominated by allocation churn and Map operations
specific to using a single Erlang map as the backing store. No amount
of dispatch optimization will close that — the data shape itself is
the bottleneck.

The memory ratio is the more glaring problem. The original benchee run
showed this library at **15,989x** memory vs C Lua and **5x more
memory than Luerl** on table_build. The array part lands a meaningful
chunk of that ratio.

A10b (the deferred plan for `big.lua` perf) describes a smaller form
of this — cached sequence length only. This plan supersedes A10b:
shipping the full array+hash split delivers the sequence-length win
"for free" while also unlocking the broader benchmark improvements.
A10b stays open as a fallback if this plan is judged too large for one
PR; in that case A10b ships first as the sequence-length subset.

## Out of scope

- Migrating to a "true" mutable array via NIFs or ETS. We stay on the
  BEAM with immutable tuples.
- Implementing Lua 5.4 borrowing semantics, weak tables, or finalizers.
- Reusing this representation for stdlib internal tables (string,
  math, io). Those are stable-shape, hash-only tables; the array part
  adds overhead with no payoff.
- The hashmap-side encoding. We keep `data: %{}` for non-integer keys.

## Success criteria

- [ ] `Lua.VM.Table` carries an `array :: tuple()` and `array_len ::
      non_neg_integer()` field. Contiguous integer keys `1..array_len`
      live in the tuple; gaps and non-integer keys live in `data`.
- [ ] `Lua.VM.Value.sequence_length/1` is O(1) — returns `array_len`
      when the array part has no holes, falls back to today's logic
      only when the array is empty or non-contiguous.
- [ ] `t[i]` for integer `i` in `1..array_len` is `elem(array, i)` —
      no `Map.get`, no `normalize_key`.
- [ ] `t[#t + 1] = v` is amortized O(1): if `i == array_len + 1`,
      append via `Tuple.append`, else fall back to `data` map.
- [ ] `ipairs(t)` iterates the tuple directly.
- [ ] `mix test` passes; `mix test --only lua53` does not regress.
- [ ] Microbenchmarks improve. Stretch targets:
      - **table_build+sum (n=500): 30% faster** (currently ~180μs).
      - **`big.lua` completes within 30 seconds** (currently times out
        per A10b).
      - **Table memory usage drops to 2-3x Luerl, from current 5x.**
- [ ] No workload regresses by more than 2%.

## Implementation notes

### Data layout

```elixir
defstruct [
  array: {},             # tuple of values for keys 1..array_len
  array_len: 0,          # contiguous prefix length (#t value)
  data: %{},             # hash part for non-integer keys, holes, large ints
  order: [],             # iteration order for hash part (B0 fix preserved)
  order_tail: [],
  dead: %{},
  metatable: nil
]
```

The `data` map remains the catchall for non-integer keys, integer keys
outside `1..array_len`, and any integer key written into a hole that
doesn't extend the contiguous prefix.

### Promotion / demotion rules

Per PUC-Lua's model, with simplifications:

- **Write `t[i] = v` where `i == array_len + 1` and `v != nil`:**
  append to `array`, increment `array_len`. Then check if any key
  `i + 1` exists in `data` — if so, "absorb" it into `array` and
  increment again (handles fill-in-the-blank patterns).
- **Write `t[i] = v` where `1 <= i <= array_len`:** `setelement(i, ...)`.
  If `v == nil`, shrink `array_len` to `i - 1`, push the tail back to
  `data`. (Lua semantics: `nil` removes the key.)
- **Write `t[i] = v` where `i > array_len + 1` or `i < 1` or `i` is
  not an integer:** goes to `data`.
- **Read `t[i]` where `1 <= i <= array_len`:** `elem(array, i)`.
- **Read `t[i]` outside that range:** check `data`.

### Hot-path read

```elixir
def get(table, key) when is_integer(key) and key >= 1 and key <= table.array_len do
  :erlang.element(key, table.array)
end

def get(table, key) do
  Table.get_data(table.data, key)
end
```

That's the entire fast path. Two function clauses, guard-tested,
no map lookup at all for in-range integer reads.

### Sequence length

```elixir
def sequence_length(%__MODULE__{array_len: n, data: data}) do
  if map_size(data) == 0 do
    n
  else
    # Fall through to current logic only when there might be a
    # contiguous extension past the array part via the hash side.
    sequence_length_with_hash(n, data)
  end
end
```

For tables built linearly via `t[i] = x` or `t = {1, 2, 3}`, `data` is
empty and `array_len` is authoritative — O(1).

### Migration

The struct field changes break any caller that constructs `%Table{}`
literally with `data:` keyword. Audit:

- `Lua.VM.Table.from_data/1` — used by `State.alloc_table/2` and stdlib
  init. Needs to split incoming map into array + hash.
- `Lua.VM.Table.replace_data/2` — used by `table.sort`. Needs to
  rebuild array_len.
- Anywhere `table.data` is read directly — there are several call
  sites; replace with a `Lua.VM.Table.get/2` API that hides the split.

### Files

- `lib/lua/vm/table.ex` — the bulk of the change.
- `lib/lua/vm/value.ex` — `sequence_length/1` becomes a struct read.
- `lib/lua/vm/stdlib.ex` — `table.insert`, `table.remove`, `table.sort`,
  `table.concat`, `ipairs` iterator. Each gets a fast path against the
  array part.
- `lib/lua/vm/executor.ex` — `:get_table`, `:set_table`, `:get_field`,
  `:set_field`, `:set_list`, `:length` opcodes. Most already dispatch
  through `Lua.VM.Table` helpers; the helper changes cascade.
- `test/lua/vm/table_test.exs` (new or expanded) — explicit tests for
  promotion, demotion, ipairs over mixed arrays.

### Phasing

If review pressure demands a smaller first PR, split:

- **B7a**: add `array` / `array_len` fields, route reads through them,
  keep writes going through `data` (no perf win yet, just plumbing).
- **B7b**: route writes through the array part, add promotion logic.
- **B7c**: fast-path stdlib (`ipairs`, `table.insert`, etc.).

Default to landing as one plan unless a discovery makes phasing
necessary.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Specifically exercise the promotion rules.
mix test test/lua/vm/table_test.exs

# Microbenchmarks
mix run benchmarks/table_ops.exs
mix run benchmarks/fibonacci.exs   # confirm no regression on non-table workloads

# big.lua suite test, which A10b was about
mix test --only lua53 test/lua53_suite_test.exs:NN  # the big.lua test line

# Memory check
mix run -e '
script = "local t = {} for i = 1, 5000 do t[i] = i end return t"
lua = Lua.new()
{chunk, _} = Lua.load_chunk!(lua, script)
:erlang.garbage_collect()
{_, before_mem} = :erlang.process_info(self(), :memory)
Enum.each(1..100, fn _ -> Lua.eval!(lua, chunk) end)
:erlang.garbage_collect()
{_, after_mem} = :erlang.process_info(self(), :memory)
IO.puts("delta=#{after_mem - before_mem}B")
'
```

## Risks

- **Promotion edge cases.** Lua semantics say `t[k] = nil` removes the
  key — splitting that into "shrink array part" vs "drop from hash" is
  where reference Lua implementations have classically had subtle bugs.
  Test coverage must include: setting middle of array to nil, then
  reading length; building array out of order; writing nil at the
  array boundary; reviving a hole.
- **Iteration order via `pairs`** must match Lua 5.3 §6.1: iteration
  is "unspecified" but must visit each live key exactly once. The
  array part walks 1..array_len then `order` walks the hash part.
  Tests exist for this via `nextvar.lua` — lean on them.
- **`table.sort` is hash-only-style today.** The fast path becomes
  "sort the array tuple, leave hash alone". `table.sort` operating on
  a sparse table is a weird case; the current implementation works
  there. Make sure the split doesn't regress sparse-table sort.
- **Memory savings depend on workload shape.** Tables used as records
  (`{name = "x", id = 1}`) don't benefit — they have no array part.
  The fix doesn't make those slower, but the headline number is
  for sequential-integer-key workloads.
- **`Tuple.append/2` is O(n) under the hood.** Repeated appends to a
  large tuple are O(n²). Mitigation: pre-allocate when the size is
  known (e.g. `t = {1, 2, 3, ..., N}` in source code → codegen emits
  a single sized-tuple construction), use exponential growth for
  dynamic appends. PUC-Lua doubles array capacity on grow; we should
  too.

## Discoveries

(populated during implementation)
