---
id: A33
title: Perf baseline & Luerl gap analysis
issue: null
pr: null
branch: perf/baseline-luerl-gap
base: main
status: merged
direction: A
unlocks:
  - per-workload perf fix plans
  - A34 (profiling needs known-bad workloads to focus on)
  - A13 perf gate criteria
---

## Goal

Run the benchee harness in `benchmarks/` against this VM, Luerl, and
luaport (PUC-Lua) and produce a written gap analysis. For every
workload where we are materially behind Luerl (>20% slower in
ips/median), open a follow-up plan (`A33a`, `A33b`, …) describing the
suspected cause and the perf target.

This plan does **no optimization**. It produces the report and the
follow-up plans. Profiling and fixes are A34.

The library's 1.0 commitment includes "perf parity with Luerl, ±10%
on representative workloads." Without this baseline, that commitment
is unfalsifiable.

## Out of scope

- Implementing optimizations.
- Writing new benchmarks (we use the existing 5: closures, fibonacci,
  oop, string_ops, table_ops).
- Comparing against PUC-Lua for parity targets — PUC-Lua is faster
  than any Erlang-based Lua, by a lot. We track it as a reference,
  not a target.
- Running profilers — that's A34.

## Success criteria

- [ ] All 5 benchmarks in `benchmarks/` run cleanly against this VM,
      Luerl, and (where available) luaport.
- [ ] A `bench_results/baseline-<date>.md` file is committed,
      containing for each workload:
      - this VM ips/median.
      - Luerl ips/median.
      - PUC-Lua ips/median (if luaport is available).
      - ratio: `(luerl_median / our_median)` — values <1.0 mean we're
        slower.
      - one-paragraph "what this workload exercises" (so future
        readers know why it matters).
- [ ] Gap classification per workload:
      - `green` — we're within 10% of Luerl.
      - `yellow` — 10-25% slower than Luerl.
      - `red` — >25% slower than Luerl.
- [ ] A follow-up plan file `A33<letter>-<workload>.md` exists for
      every `red` and `yellow` workload, describing what the workload
      exercises, the current gap, and a stretch target.
- [ ] `bench_results/README.md` describes how to reproduce.
- [ ] No code changes to `lib/`. This plan is *measurement only*.

## Implementation notes

### Reproducible runs

Benchee variability is real. The protocol:

1. Quiesce the machine: close other apps, plug in power, disable
   spotlight indexing where possible.
2. Run each workload three times. Take the median of medians.
3. Run with `time: 5` and `warmup: 2` (or whatever the harness
   already uses).
4. Record CPU model, OS, BEAM version, Elixir version, Lua version.

### luaport availability

luaport is optional and requires C Lua dev headers. The plan should
handle both "luaport works" and "luaport not available" cases —
report Luerl-only when luaport is missing, with a clear note.

### Gap analysis structure

For each workload:

```markdown
## fibonacci (fib(30))

What it exercises: recursive function calls, integer arithmetic,
small frame creation/teardown. Stresses opcode dispatch and
call/return.

Results:
| VM           | ips    | median (μs) |
|--------------|--------|-------------|
| Lua (this)   | 12.3   | 81 ms       |
| Luerl        | 14.5   | 69 ms       |
| PUC-Lua      | 280    | 3.6 ms      |

Ratio vs Luerl: 0.85 (yellow — 17% slower)

Suspected cause: opcode dispatch overhead, possibly the new
line/source threading from A18.

Follow-up: A33a-fibonacci-dispatch.md
```

### Files

- `bench_results/baseline-<date>.md` (new, committed).
- `bench_results/README.md` (new) — how to reproduce.
- `.agents/plans/A33<letter>-*.md` — per-workload follow-ups.
- `mix.exs` — possibly add `:eflambe` and `:fprof` (already in BEAM)
  to `:benchmark` env if not present.

## Verification

```bash
# In the :benchmark env (or whatever the harness uses):
mix deps.get
mix run benchmarks/closures.exs
mix run benchmarks/fibonacci.exs
mix run benchmarks/oop.exs
mix run benchmarks/string_ops.exs
mix run benchmarks/table_ops.exs

# Capture the output, write the report.
```

A29 (mix tasks) plans `mix lua.bench` — if that's already merged,
this plan can use it. If not, run the scripts directly.

## Risks

- Benchee variance can make a 10% gap look like a 25% gap on a noisy
  machine. Always take the median of three runs, and spell out what
  hardware was used.
- A18's line/source threading added ~2-3% on fib(30). The baseline
  captures the post-A18 state — that overhead is now baked into the
  numbers and is the new ground truth. Don't try to revert it.
- "Parity with Luerl" is the target, but Luerl has had 10+ years of
  perf attention. Some workloads may not reach parity by 1.0; that's
  okay if the gap is documented and bounded.

## Discoveries

The baseline was captured and committed as
[`benchmarks/BASELINE.md`](../../benchmarks/BASELINE.md) (2026-06-15),
which supersedes the planned `bench_results/baseline-<date>.md` path.
