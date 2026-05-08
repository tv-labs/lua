---
id: A35
title: Perf regression CI — lock in parity once reached
issue: null
pr: null
branch: perf/regression-ci
base: main
status: blocked
direction: A
unlocks:
  - confidence that perf doesn't drift
  - meaningful "perf parity" claim in 1.0
---

## Blocked on

- A34 and its `A34<letter>` follow-ups — we lock in *after* parity is
  reached on the workloads that matter.

## Goal

Once parity is reached on each non-green workload from A33, lock it
in:

1. Capture a baseline run as `bench_results/baseline.json` (or
   similar).
2. Add `mix lua.bench --compare-baseline` to compare a fresh run
   against the committed baseline and exit non-zero on a regression
   over the threshold.
3. Wire that into CI as a non-blocking job (emits a comment / report
   on each PR).
4. Document the threshold and the update process for the baseline
   when intentional perf trade-offs are made.

Without this, parity drifts the moment someone optimizes for clarity
or refactors.

## Out of scope

- Running the bench job on every PR push (CI cost). Run on a
  schedule (nightly) or on a label (`run-bench`) instead.
- Comparing across architectures (CI runner is what it is; baseline
  is captured on the runner).
- Adding new benchmarks beyond what `benchmarks/` already has.

## Success criteria

- [ ] `bench_results/baseline.json` (or chosen format) is committed,
      with one entry per workload: ips, median, deviation,
      timestamp, runner info.
- [ ] `mix lua.bench --compare-baseline` exists and:
      - [ ] Runs all 5 workloads.
      - [ ] Compares each median against the baseline.
      - [ ] Reports each as `OK` (within threshold) or `REGRESSION`
            (over threshold).
      - [ ] Exits 0 if all OK, 1 if any regression.
      - [ ] Threshold default: 5% slower than baseline. Configurable
            via `--threshold-pct N`.
- [ ] CI workflow runs the bench compare on a nightly schedule and
      on PRs labeled `run-bench`. Reports results as a PR comment
      or build artifact.
- [ ] `bench_results/README.md` documents:
      - [ ] How the baseline is captured.
      - [ ] How to update the baseline (intentional change).
      - [ ] Threshold rationale.
- [ ] `mix test` passes.

## Implementation notes

### Baseline format

JSON for machine-readability:

```json
{
  "captured_at": "2026-05-08T12:00:00Z",
  "runner": {"os": "linux", "arch": "x86_64", "beam": "27", "elixir": "1.18"},
  "workloads": {
    "fibonacci": {"ips": 14.2, "median_us": 70_400, "deviation_pct": 1.8},
    "closures":  {"ips": 8.1,  "median_us": 123_000, "deviation_pct": 2.3},
    ...
  }
}
```

### Compare logic

```elixir
defmodule Mix.Tasks.Lua.Bench do
  ...
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: [
      compare_baseline: :boolean,
      threshold_pct: :integer
    ])
    threshold = opts[:threshold_pct] || 5

    if opts[:compare_baseline] do
      current = run_workloads()
      baseline = load_baseline()
      compare_and_report(current, baseline, threshold)
    else
      run_workloads()
    end
  end
end
```

### CI

```yaml
# .github/workflows/bench.yml
name: bench
on:
  schedule:
    - cron: "0 5 * * *"
  pull_request:
    types: [labeled]

jobs:
  bench:
    if: github.event_name == 'schedule' || github.event.label.name == 'run-bench'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27"
          elixir-version: "1.18"
      - run: mix deps.get
      - run: mix lua.bench --compare-baseline
```

### Files

- `bench_results/baseline.json` (new, committed).
- `bench_results/README.md` — document update process.
- `lib/mix/tasks/lua/bench.ex` — extend with `--compare-baseline`
  (this builds on A29).
- `.github/workflows/bench.yml` (new) — CI workflow.

## Verification

```bash
mix lua.bench --compare-baseline                # passes against committed baseline
mix lua.bench --compare-baseline --threshold-pct 0  # almost certainly fails (variance)
mix lua.bench --compare-baseline --threshold-pct 50 # always passes
```

CI: trigger via label, confirm the job runs.

## Risks

- CI runners are noisy. A 5% threshold may be too tight; tune after
  observing variance. If we see false alarms more than once a week,
  bump to 10%.
- Baseline goes stale. Update process must be explicit: any
  intentional perf change writes a new baseline in the same PR with
  a justification.
- Schedule-only runs miss regressions until the next night.
  Mitigation: the `run-bench` label lets a developer trigger on
  demand for a suspect PR.

## Discoveries

(populated during implementation)
