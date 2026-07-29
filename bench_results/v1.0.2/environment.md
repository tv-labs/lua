# Benchmark environment — main (1.0.2)

- **Ref**: `main` — the main checkout itself, commit `3a0d3923249cbb05380a3f17d3920a0b3ed55cb0` (the 1.0.2 release). No worktree was created or removed for this run; the main checkout was read but not modified.
- **Mode**: `full` (`LUA_BENCH_MODE=full`)
- **CPU**: Apple M4 (see `cpu.txt`)
- **Elixir / OTP**: Elixir 1.20.0, Erlang/OTP 29 [erts-17.0] [64-bit] [jit] (see `versions.txt`)
- **Run timestamp**: Tue Jul 28 11:14:31 EDT 2026 (see `timestamp.txt`)
- **This document written**: Tue Jul 28 11:37:22 EDT 2026

## Command form

Each workload was run serially, one process per file, on an otherwise quiet
machine, from the main checkout root:

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

- `cpu.txt`, `versions.txt`, `timestamp.txt`, `commit.txt` — raw environment
  probes.
- `<workload>.txt` — raw stdout of each `mix run` invocation (11 files).
- `summary.json` — parsed structured form of the above (workload -> case ->
  jobs/comparison/memory), same schema as `results/v1.0.0/summary.json`.
