# Benchmark environment — v1.0.0

- **Ref**: `v1.0.0` (commit `69e13a6`)
- **Mode**: `full` (`LUA_BENCH_MODE=full`)
- **CPU**: Apple M4 (see `cpu.txt`)
- **Elixir / OTP**: Elixir 1.20.0, Erlang/OTP 29 [erts-17.0] [64-bit] [jit] (see `versions.txt`)
- **Worktree setup timestamp**: Tue Jul 28 10:48:16 EDT 2026 (see `timestamp.txt`)
- **Run date (this document)**: Tue Jul 28 11:20:58 EDT 2026

## Command form

Each workload was run serially, one process per file, on an otherwise quiet
machine, from the worktree root:

```
LUA_BENCH_MODE=full MIX_ENV=benchmark mix run benchmarks/<workload>.exs
```

Workloads run: `fibonacci`, `closures`, `oop`, `string_ops`, `string_format`,
`table_ops`, `patterns`, `metamethods`, `pcall_varargs`, `vm_new`,
`encode_decode`.

`encode_decode.exs` is not Benchee-based (it uses a `:timer.tc` harness
directly), but was invoked with the same command form for consistency.

C Lua via `luaport` was not available in this environment (no local luaport
build) and was skipped by each script's own fallback path; all comparisons
below are lua (chunk)/lua (eval) vs. luerl only.

## Artifacts

- `cpu.txt`, `versions.txt`, `timestamp.txt` — raw environment probes captured
  at worktree setup time.
- `<workload>.txt` — raw stdout of each `mix run` invocation (11 files).
- `summary.json` — parsed structured form of the above (workload -> case ->
  jobs/comparison/memory).
