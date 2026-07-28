# Benchmark environment — lua v0.4.0 (full mode)

- **Ref**: `v0.4.0` (tag), commit `5bf2069`
- **CPU**: Apple M4
- **OTP**: Erlang/OTP 29 [erts-17.0] [source] [64-bit] [smp:10:10] [ds:10:10:10] [async-threads:1] [jit]
- **Elixir**: 1.20.0 (compiled with Erlang/OTP 29)
- **Mode**: `LUA_BENCH_MODE=full MIX_ENV=benchmark`
- **Setup timestamp**: 2026-07-28T13:59:36Z (UTC)
- **luaport (C Lua)**: not installed — skipped by all workloads as expected
- **luerl**: 1.5.1 (unconditional dep at this tag)

## Worktree setup

```
git -C /Users/dave/code/tvlabs/lua worktree add --detach \
  /private/tmp/claude-501/-Users-dave-code-tvlabs-lua/baeced00-0f95-4dc6-8d8e-c16607ffb143/scratchpad/bench-v0.4.0 v0.4.0

cp -R /Users/dave/code/tvlabs/lua/benchmarks <worktree>/benchmarks

# mix.exs deps edit (worktree only): added
#   {:benchee, "~> 1.3", only: :benchmark}
# alongside the existing {:luerl, "~> 1.5.1"} unconditional dep.

MIX_ENV=benchmark mix deps.get
MIX_ENV=benchmark mix compile
```

No lockfile/dep conflicts were encountered; `deps.get` resolved cleanly (benchee 1.5.1, deep_merge 1.0.2, statistex 1.1.1 added; luerl/ex_doc/dialyxir unchanged).

## Measurement commands

Each workload run strictly serially, one at a time, via:

```
(cd <worktree> && LUA_BENCH_MODE=full MIX_ENV=benchmark mix run benchmarks/<workload>.exs) \
  > <results dir>/<workload>.txt 2>&1
```

Order: fibonacci, closures, oop, string_ops, string_format, table_ops, patterns, metamethods, pcall_varargs, vm_new, encode_decode.

Excluded: `dispatcher_vs_interpreter.exs` (crashes on v0.4.0), `array_vs_map_probe.exs` (runs no Lua).

`encode_decode.exs` uses its own `:timer.tc` harness (not Benchee) and prints its own table directly.

## Cleanup

```
git -C /Users/dave/code/tvlabs/lua worktree remove --force \
  /private/tmp/claude-501/-Users-dave-code-tvlabs-lua/baeced00-0f95-4dc6-8d8e-c16607ffb143/scratchpad/bench-v0.4.0
```

## Results

Parsed into `summary.json` in this directory. Raw Benchee/harness stdout for each
workload is preserved verbatim in `<workload>.txt`.
