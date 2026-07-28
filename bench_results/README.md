# `bench_results/`

Recorded benchmark runs and the reports written from them.

The benchmark **scripts** live in [`benchmarks/`](../benchmarks/). This
directory holds their **output**: raw stdout, a parsed JSON summary, environment
probes, and the human-readable report for each measurement campaign. Nothing
here is used by the library at runtime, and none of it ships in the Hex package.

## Contents

| Path | What it is |
|---|---|
| [`versions-2026-07-28.md`](./versions-2026-07-28.md) | Cross-version comparison — v0.4.0 vs v1.0.0 vs 1.0.2 (`main` @ `3a0d392`), with Luerl 1.5.1 as a same-run control in every table. Supersedes the 1.0.0-era numbers in [`benchmarks/BASELINE.md`](../benchmarks/BASELINE.md). |
| [`v0.4.0/`](./v0.4.0/), [`v1.0.0/`](./v1.0.0/), [`v1.0.2/`](./v1.0.2/) | The data behind that report — one directory per released version. This is the ongoing convention: each release gets its own directory here, measured with the full suite of its day. |

### Layout of a version directory

```
<version>/
  environment.md      # ref, commit, mode, CPU, OTP/Elixir, timestamp, command form
  summary.json        # parsed results: workload -> case -> jobs + comparison lines
  <workload>.txt      # verbatim stdout of one `mix run benchmarks/<workload>.exs`
  cpu.txt versions.txt timestamp.txt commit.txt
```

`summary.json` schema, as produced for the 2026-07-28 run:

- Top level is keyed by **workload** (`fibonacci`, `table_ops`, `vm_new`, …).
- Each workload maps to its **case banners** (`"default"` for single-case
  workloads, otherwise the banner the script printed, e.g.
  `"patterns: gsub template substitution (n=200)"`).
- Each case has `jobs` — a list of `{name, ips, average, deviation, median,
  p99, memory}` — plus the verbatim Benchee `comparison` lines and, when memory
  measurement was on, `memory_comparison` or `memory_note`.
- `table_ops` cases nest one level deeper under `by_input` (or `inputs` on the
  v0.4.0 run) keyed by input label — `small (n=10)`, `medium (n=100)`,
  `large (n=1000)`.
- `vm_new` carries `cold_call` and `second_call` alongside its jobs: the
  first-ever and second `Lua.new()` on the node, measured before Benchee starts.
- `encode_decode` is `{"raw": "..."}`. That script uses its own `:timer.tc`
  harness rather than Benchee and prints a per-element-nanoseconds table, so it
  is stored unparsed.

Case-name keys are **not** byte-identical across refs: the v0.4.0 run appends
`" (mode: full)"` to banners and uses `"(single case)"` where later runs use
`"default"`. Normalise by stripping the mode suffix before joining across refs.

## Reproducing a run

Full per-ref instructions — including the three adaptations v0.4.0 needs and
the language constraints a cross-version workload must respect — are in the
[Reproduction section of the report](./versions-2026-07-28.md#reproduction).
The short version:

```sh
MIX_ENV=benchmark mix deps.get
for w in fibonacci closures oop string_ops string_format table_ops \
         patterns metamethods pcall_varargs vm_new encode_decode; do
  LUA_BENCH_MODE=full MIX_ENV=benchmark mix run "benchmarks/$w.exs"
done
```

Two rules are not optional:

- **Serially, one `mix run` at a time, on a quiet machine.** Concurrent load
  inflates deviation badly — the table and OOP cases swing enough to flip
  orderings.
- **`LUA_BENCH_MODE=full` for anything published.** The default `quick` mode
  uses short windows, skips memory measurement, and collapses the table
  workloads to a single input size. It is for "did my change move the needle"
  iteration, not for numbers anyone reads.

### Older refs

Each ref is measured in a throwaway detached worktree so the main checkout is
never modified:

```sh
git worktree add --detach /tmp/lua-<tag> <tag>
```

- **v1.0.0** — copy in the four workloads that postdate it
  (`patterns`, `metamethods`, `pcall_varargs`, `vm_new`), then
  `MIX_ENV=benchmark mix deps.get`.
- **v0.4.0** — copy in the whole `benchmarks/` directory (the tag has none) and
  add `{:benchee, "~> 1.3", only: :benchmark}` to `deps/0`. `luerl` is already
  an unconditional dependency there, so the control rows need nothing.

Remove the worktree when done (`git worktree remove --force /tmp/lua-<tag>`).

## Benchmarking a new release

The convention: **every released version gets a directory here**, so the
series grows one column per release.

1. After tagging, run the full suite against the tag (serially, full mode,
   quiet machine — see above) and put the outputs in
   `bench_results/<version>/` with the same file layout as the existing
   directories (`environment.md`, `summary.json`, one `.txt` per workload,
   plus the env probes).
2. Include the Luerl control rows — they are what make the new column
   comparable to the old ones despite machine/OTP drift between sittings.
3. If the suite gained workloads since the last release, note in
   `environment.md` which workloads are new (older version directories will
   simply lack those files).
4. Write or extend a report named `<topic>-<YYYY-MM-DD>.md` quoting
   **medians**, not averages — several workloads have allocation-driven GC
   pauses that pull the mean around.
5. Add a row to the Contents table above, and update the hosted page at
   `website/priv/static/benchmarks.html` if the headline story changed.
6. Do not edit `benchmarks/BASELINE.md`. It is the historical 1.0.0 gate
   record; a newer report supersedes it by saying so.
