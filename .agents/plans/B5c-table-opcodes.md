---
id: B5c
title: Compile table opcodes — make table-heavy workloads bypass the interpreter
issue: null
pr: null
branch: perf/erlang-codegen-tables
base: main
status: ready
direction: B
unlocks:
  - ~2x speedup on table_ops benchmarks
  - the full OOP benchmark workload (depends on tables + closures)
---

## Blocked on

- B5a (foundation)
- B5b (lifecycle) — required before adding more opcodes to the
  codegen, otherwise the cache pressure scales with surface area.

## Goal

Extend `Lua.Compiler.Erlang` to lower the table opcode family:
`:new_table`, `:get_table`, `:set_table`, `:set_list`, `:get_field`
(full path, not just env lookup), `:set_field`. After this PR,
prototypes that touch tables compile end-to-end and stay out of
the interpreter fallback path.

The third spike measured **2.1x faster than interpreter** on
run_table_sum(1000). This PR delivers that.

## Why now

Once tables compile, the OOP benchmark and most real-world Lua
code stops falling back to the interpreter. The win is smaller per
opcode than fib's (3.8x vs 12.4x at faithful), but it removes a
large class of fallback cases — the dominant blocker after B5a.

## Out of scope

- Closures (`:closure`, upvalue mutation). B5d.
- Error position fidelity. B5e.
- Optimising table data shape (this is a B-series follow-up that
  was deferred: B6/B7). B5 saves dispatch around the table
  mutation, not the mutation itself.

## Success criteria

- [ ] Opcodes added to the codegen: `:new_table`, `:get_table`,
      `:set_table`, `:set_list`, `:get_field` (full path),
      `:set_field`.
- [ ] `mix test` passes; no regression in unit, suite, or property
      tests.
- [ ] `LUA_BENCH_MODE=full mix run benchmarks/table_ops.exs`:
      `lua (chunk)` beats Luerl by ≥1.5x on `Table Iterate/Sum`
      and `Table Map + Reduce` at n=500 and n=1000. Stretch: ≥2x.
- [ ] `mix run benchmarks/oop.exs`: no regression now that more
      of the OOP path is compiled. Stretch: measurable improvement
      once `:closure` lands in B5d.
- [ ] No regression on numeric benchmarks (fibonacci, etc.) — the
      shared codegen pieces don't slow down what B5a already won.

## Implementation notes

### Lowering each opcode

The interpreter's table opcodes already have fast paths (PR #223
and follow-ups). The compiled lowering mirrors them inline rather
than calling back into the interpreter helpers, **except** when the
slow path is hit (metamethod dispatch, type errors). The slow
paths delegate to `Lua.VM.Executor` helpers that already exist.

#### `:new_table`

```erlang
{Tref0, State0} = 'Elixir.Lua.VM.State':alloc_table(State_in),
R_dest = Tref0,
State_out = State0
```

State threads through.

#### `:get_table`

Two cases. Integer or binary key on a `{:tref, _}`: inline the
fast path from `executor.ex:1300-1323`:

```erlang
TableVal = R_table,
Key = R_key,
case TableVal of
    {tref, Id} when is_integer(Key); is_binary(Key) ->
        Table = erlang:map_get(Id, maps:get(tables, State_in)),
        case erlang:map_get(data, Table) of
            #{Key := Value} ->
                R_dest = Value,
                State_out = State_in;
            _ ->
                case erlang:map_get(metatable, Table) of
                    nil ->
                        R_dest = nil,
                        State_out = State_in;
                    _ ->
                        {Value, State1} = 'Elixir.Lua.VM.Executor':index_value(
                            TableVal, Key, State_in, Line, Source, NameHint),
                        R_dest = Value,
                        State_out = State1
                end
        end;
    _ ->
        {Value, State1} = 'Elixir.Lua.VM.Executor':index_value(
            TableVal, Key, State_in, Line, Source, NameHint),
        R_dest = Value,
        State_out = State1
end
```

`index_value/6` needs to be promoted from `defp` to `def` in the
executor so the compiled module can call it. Add `@doc false` to
keep it out of the public API surface.

#### `:set_table`

```erlang
case R_table of
    {tref, _} ->
        State_out = 'Elixir.Lua.VM.Executor':table_newindex(
            R_table, R_key, R_value, State_in);
    _ ->
        'Elixir.Lua.VM.Executor':raise_index_type_error(
            R_table, Line, Source, NameHint)
end
```

`table_newindex/4` is already `def` (executor.ex:1919).
`raise_index_type_error/4` needs promoting.

#### `:set_list`

Iterates over a register range and calls `table_newindex` per
entry. Compile as a recursive helper (same pattern as
`:numeric_for` from B5a).

#### `:get_field`, `:set_field`

B5a already covers `:get_field` for env lookups. Generalise: the
fast path uses the table's `:data` map with the literal binary
key. Falls through to `index_value` / `table_newindex` for
metatable cases.

### Promoting helpers

The executor's table helpers that the compiled code calls into:

- `Lua.VM.Executor.table_newindex/4` — already `def`.
- `Lua.VM.Executor.index_value/6` — currently `defp`. Promote to
  `def` with `@doc false`.
- `Lua.VM.Executor.raise_index_type_error/4` — currently `defp`.
  Promote.

The `@doc false` keeps these from showing up in the user-facing
documentation but lets the compiled module call them by their
fully-qualified `'Elixir.Lua.VM.Executor':function(...)` form.

### Files

- `lib/lua/compiler/erlang/opcodes.ex` — add lowering clauses for
  the table family.
- `lib/lua/compiler/erlang.ex` — remove table opcodes from the
  fallback set; allow them in the codegen.
- `lib/lua/vm/executor.ex` — promote `index_value/6` and
  `raise_index_type_error/4` to public.
- `test/lua/compiler/erlang_test.exs` — golden tests for each table
  opcode (compiled vs interpreted result equality on a battery of
  inputs including metatable cases).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

LUA_BENCH_MODE=full mix run benchmarks/table_ops.exs
LUA_BENCH_MODE=full mix run benchmarks/oop.exs
LUA_BENCH_MODE=full mix run benchmarks/fibonacci.exs    # no regression
```

## Risks

- **Metatable semantics are subtle.** `__index` and `__newindex`
  can recurse through long chains. The compiled fast path skips
  metatable dispatch only when `metatable == nil` on the table.
  Any non-nil metatable falls through to the existing
  `index_value` / `table_newindex` helpers, which already handle
  the chains. Risk is limited to "is the fast-path predicate
  right" — covered by golden tests.
- **`set_list` codegen is the most complex per-opcode lowering.**
  It needs to compile a register-range loop into a recursive
  helper that's careful about register aliasing. Test with both
  short ranges (typical: `{1, 2, 3}` table constructor) and long
  ranges.
- **Promoting `defp` to `def` widens the executor's public API.**
  `@doc false` mitigates discoverability. The executor's
  `@moduledoc` should mention that these are runtime helpers used
  by compiled modules and should not be called directly by user
  code.
- **The third spike's 2.1x was measured at faithful, not real
  codegen.** Real codegen has overheads the spike skipped (full
  opcode coverage means more dispatch within the compiled
  function). The success-criteria floor (≥1.5x) accommodates this.

## Discoveries

(populated during implementation)
