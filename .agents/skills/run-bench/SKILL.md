---
name: run-bench
description: |
  Execute the benchmark harness under benchmarks/ and produce a markdown
  report comparing this build against the recorded baseline (and optionally
  against Luerl and PUC-Lua). Flag regressions over a configurable threshold.

  Use when the user asks for a benchmark run, after any executor or codegen
  change in Direction B, or when a Direction B plan's verification calls
  for it.

  STATUS: stub. Will be filled in when Direction B begins. The benchee
  harness is already in benchmarks/ (added in PR #143).
---

# run-bench (stub)

This skill is a placeholder. It will be fleshed out when Direction B starts.

## What's already in place (don't re-build)

- `benchmarks/` directory with benchee scripts: `closures.exs`, `fibonacci.exs`,
  `oop.exs`, `string_ops.exs`, `table_ops.exs`. (PR #143)
- Comparison against Luerl and PUC-Lua via `luerl` and `luaport` deps.

## What this skill needs to add when Direction B starts

1. A standard "run all benchmarks" entry point (probably a mix task or shell
   script).
2. Output to `bench/results/<date>-<sha>.md` so we have a history.
3. A baseline stored at `bench/baseline.md` that gets updated explicitly
   (not on every run).
4. A diff renderer: takes two result sets, produces a markdown table
   showing percent change, flags regressions over a threshold (default 20%).
5. Convention for capturing PR-relevant numbers in the PR body.

## Until then

Run benchmarks manually:

```bash
mix run benchmarks/fibonacci.exs
mix run benchmarks/closures.exs
mix run benchmarks/oop.exs
mix run benchmarks/string_ops.exs
mix run benchmarks/table_ops.exs
```

Capture stdout and paste into the PR description. Until a baseline file
exists, "no regression" is judged by re-running before and after on the
same machine.
