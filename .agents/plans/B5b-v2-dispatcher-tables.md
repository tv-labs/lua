---
id: B5b-v2
title: Dispatcher table opcodes — make table-heavy workloads bypass the interpreter
issue: null
pr: null
branch: perf/dispatcher-tables
base: main
status: blocked
direction: B
unlocks:
  - ~2x speedup on table_ops benchmarks
  - the full OOP benchmark workload (depends on tables + closures)
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (dispatcher foundation).

## Goal

Extend `Lua.VM.Dispatcher` and `Lua.Compiler.Bytecode` to lower the
table opcode family: `:new_table`, `:get_table`, `:set_table`,
`:set_list`, `:get_field` (full path, not just env lookup),
`:set_field`. After this PR, prototypes that touch tables compile
end-to-end and stay out of the interpreter fallback path.

The original B5 third spike measured **2.1x faster than interpreter**
on run_table_sum(1000). The dispatcher should land at a similar or
slightly worse ratio (the spike used a compiled BEAM module; the
dispatcher pays per-step dispatch).

## Out of scope

- Mutable table storage. `Table.put/3` allocation churn is the
  ceiling for table workloads on the BEAM; not addressed here.
- Metamethod dispatch via `__index` / `__newindex` short-circuiting.
  The dispatcher delegates to existing `Executor.index_value/6`
  helpers, which handle metamethods.

## Success criteria

(To be detailed when this plan unblocks. Mirrors original B5c
success criteria but targets the dispatcher rather than codegen.)

## Discoveries

(Empty until implementation.)
