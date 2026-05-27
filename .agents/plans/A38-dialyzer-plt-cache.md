---
id: A38
title: "Cache the Dialyzer PLT in CI to cut job time from ~3m30s to <60s"
issue: null
pr: null
branch: ci/dialyzer-plt-cache
base: main
status: in-progress
direction: A
---

## Goal

Cache the Dialyzer PLT files in GitHub Actions so the dialyzer job runs in
under 60 seconds on cache hits instead of ~3m30s every run.

## Out of scope

- Changing what dialyzer actually checks (no new ignores, no flag changes).
- Moving dialyzer off the merge-gating path.
- Enabling dialyzer on the OTP 29 / Elixir 1.20 matrix row.
- Any change to `mix test` or other CI jobs.

## Success criteria

- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` passes (no regressions).
- [ ] `mix dialyzer` passes locally (PLT builds to `priv/plts/`).
- [ ] CI workflow YAML is valid (yamllint or manual inspection).
- [ ] On first run (cache miss) the dialyzer job completes successfully.
- [ ] On second run (cache hit) the `mix dialyzer` step takes < 60s.

## Implementation notes

### 1. Pin PLT paths in `mix.exs`

Add `plt_core_path` and `plt_local_path` to the `dialyzer:` keyword list so
the PLT files land in a stable, cache-able directory (`priv/plts/`):

```elixir
dialyzer: [
  plt_add_apps: [:ex_unit],
  plt_core_path: "priv/plts/core",
  plt_local_path: "priv/plts/local"
]
```

Drop `:mix` from `plt_add_apps` — `lib/` does not reference `Mix.*` at
runtime (only `tasks/` does, and that's excluded from the production
`elixirc_paths/1`).

### 2. Add `priv/plts/` to `.gitignore`

The PLT files are build artefacts; they must not be committed.

### 3. Update `.github/workflows/ci.yml`

In the `dialyzer` job:
- Add a `Restore PLT cache` step (using `actions/cache@v4`) immediately
  after `install-deps`, caching `priv/plts`. Cache key:
  `${{ runner.os }}-elixir${{ matrix.elixir }}-otp${{ matrix.otp }}-plt-${{ hashFiles('**/mix.lock') }}`
  with a `restore-keys` fallback keyed on OS/Elixir/OTP so a `mix.lock`
  bump triggers an incremental PLT update instead of a full rebuild.
- Split the single `mix dialyzer` step into two:
  - `Build PLT` — `mix dialyzer --plt` (skipped on cache hit by dialyxir's
    own PLT-up-to-date check, but makes the CI log show build vs. analysis
    time separately).
  - `Run dialyzer` — `mix dialyzer` (fast on cache hit).

## Verification

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix dialyzer --plt    # builds to priv/plts/ — must succeed
mix dialyzer          # must exit 0
```

## Risks

- **Cache eviction**: GitHub Actions caches expire after 7 days of no use.
  After eviction, the next run pays the full ~3m rebuild cost — acceptable
  and self-healing.
- **PLT path mismatch**: if `mix dialyzer` writes somewhere other than
  `priv/plts/`, the cache step won't capture it. Verify by running locally
  and confirming the directory exists.
- **Cache storage budget**: PLT files are ~30-50 MB per Elixir/OTP
  combination, well within the typical 10 GB org cache cap.
