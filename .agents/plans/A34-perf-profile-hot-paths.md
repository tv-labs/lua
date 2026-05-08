---
id: A34
title: Perf profiling — fprof and eflambe on hot paths
issue: null
pr: null
branch: perf/profile-hot-paths
base: main
status: blocked
direction: A
unlocks:
  - per-hotspot fix plans
  - actionable optimization targets
---

## Blocked on

- A33 — we need the gap analysis to know which workloads are worth
  profiling.

## Goal

For every `red` and `yellow` workload from A33, capture a fprof
measurement and an eflambe flame graph. Identify the BEAM-level
hotspots — which functions consume the most reductions, where time
is spent in GC, where allocation pressure is high. Open per-hotspot
fix plans.

This plan does **no optimization**. It produces profiles and the
follow-up plans. Fixes are the per-hotspot follow-ups (`A34a`,
`A34b`, …).

## Out of scope

- Implementing optimizations.
- Profiling `green` workloads — they're not worth the cycles.
- Profiling Luerl or PUC-Lua. We profile *our* VM only.
- Microbenchmarks — we profile the same workloads A33 measures.

## Success criteria

- [ ] For each non-green workload from A33:
      - [ ] `fprof` profile captured, with an analysis file showing
            top 20 functions by `OWN` time and by `ACC` time.
      - [ ] `eflambe` flame graph captured (`.svg` committed under
            `bench_results/profiles/`).
      - [ ] Written analysis: which functions dominate, what the
            BEAM is spending time on (dispatch? allocation? GC?
            module dispatch? tuple destructuring?).
      - [ ] At least one specific hypothesis per workload, e.g.
            "the `do_execute/8` clause for `:add` allocates a new
            tuple every dispatch."
- [ ] A `bench_results/profiles/<date>/<workload>.md` file per
      workload, with:
      - [ ] commands used to capture (so future runs are
            reproducible).
      - [ ] top-N function list.
      - [ ] flame graph link.
      - [ ] hypotheses + suspected fix.
- [ ] One `A34<letter>-<hotspot>.md` plan per hypothesis worth
      acting on.
- [ ] No code changes to `lib/`. Measurement only.

## Implementation notes

### Tooling

- `:fprof` — built into the BEAM. Use:
  ```elixir
  :fprof.apply(fn -> run_workload() end, [])
  :fprof.profile()
  :fprof.analyse(dest: ~c"/tmp/fprof.txt", totals: true)
  ```
- `eflambe` — adds via `mix.exs` in the `:benchmark` env.
  ```elixir
  :eflambe.apply({M, :f, [args]}, [output_format: :brendan_gregg])
  ```

Capture each workload twice: once "warm" (after a few iterations,
to skip JIT/cache effects) and once cold.

### Workload reduction

Each benchmark file in `benchmarks/` has both a "string eval" and a
"compiled chunk" path. Profile the compiled-chunk path — that's the
production-mode usage and isolates VM perf from compile perf.

### Output structure

```
bench_results/
  profiles/
    2026-05-08/
      fibonacci.md
      fibonacci.fprof.txt
      fibonacci.svg          # eflambe
      closures.md
      closures.fprof.txt
      closures.svg
      ...
```

### Per-workload analysis template

```markdown
# fibonacci profile — 2026-05-08

## Setup
BEAM 27, Elixir 1.18, macOS 14.5, M1 Pro.
Ran `make_counter`-style 100x to warm; profile captures next 1000 calls.

## Top 20 by OWN time (fprof)
1. Lua.VM.Executor.do_execute/8       45.2%
2. Lua.VM.Executor.lookup_register/2  12.1%
3. ... (etc)

## Hypotheses
1. `do_execute/8` is hot because every opcode dispatches through it.
   Possible fix: split into per-opcode-family modules (arith,
   metamethod, control-flow), let the BEAM dispatch via module-fun.
2. `lookup_register/2` allocates tuples to compose register access.
   Possible fix: use raw tuple access at the call site.

## Follow-ups
- A34a-do-execute-dispatch.md
- A34b-lookup-register-alloc.md
```

### Files

- `bench_results/profiles/<date>/*` (new, committed).
- `mix.exs` — add `:eflambe` to `:benchmark` deps.
- `.agents/plans/A34<letter>-*.md` — per-hotspot fix plans.

## Verification

```bash
mix deps.get
# capture profiles per workload (commands in each profile file)
ls bench_results/profiles/<date>/
```

Sanity-check the flame graphs in a browser; they should be readable.

## Risks

- Profiling infrastructure can perturb the numbers — fprof is
  notoriously slow. Always cross-reference fprof's "this function is
  hot" claims with eflambe and with the actual benchmark medians
  before deciding a hotspot is real.
- Some hotspots are inherent to the BEAM (e.g. tuple destructuring
  cost). Plans for these need to think about whether the cost is
  payable elsewhere (different data shape, less destructuring) or
  whether it's a hard floor.
- "Parity with Luerl" may require structural changes (e.g. opcode
  dispatch via a different mechanism). Surface these honestly in the
  follow-up plans; large structural plans should be ones we ship
  intentionally, not as a side-effect of profiling.

## Discoveries

(populated during profiling)
