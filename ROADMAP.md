# Lua VM Roadmap

This is the strategic overview. For per-PR detail, see [`.agents/plans/`](.agents/plans).

## Status: 2026-05-21

- **Unit tests**: 1,705 passing, 0 failing, 30 skipped.
- **Lua 5.3 official suite**: 6/29 files passing (`simple_test.lua`,
  `api.lua`, `bitwise.lua`, `code.lua`, `tpack.lua`, `vararg.lua`).
- **Current focus**: post-B-series consolidation. See [Direction B —
  Performance](#direction-b--performance-1-0-x) for what was tried,
  what shipped, and what we learned about the limits.

## Done

The new Elixir-native VM (replacing Luerl) is built up through:

- **Foundation (Phases 0–10)**: lexer, parser, codegen, register-based executor,
  value encoding/decoding, public `Lua.*` API integration. Luerl removed.
- **Phase 11**: Compiler fundamentals — multi-assign, `break`, `goto`/`label`,
  `Statement.Do`, `LocalFunc`.
- **Phase 12**: Full metamethod dispatch (`__index`, `__newindex`, `__call`,
  arithmetic/comparison/length/concat/tostring metamethods).
- **Phase 13**: String pattern engine (`string.find`/`match`/`gmatch`/`gsub`).
- **Phase 14a**: Bitwise correctness, math return types.
- **Phase 15**: `debug` library, module registration polish.
- **Phase 16**: `string.format` width/precision support.
- **Phase 17**: Vararg expansion, scope fixes, `_G`, `_ENV`, hex floats, multi-return.
- **Performance baseline**: benchmark harness vs Luerl and C Lua (PR #143).
- **Performance wins on main**:
  - Right-size register tuple allocations (PR #153).
  - O(N²) → O(N) upvalue collection in closure handler (PR #154).
  - O(1) upvalue access by storing upvalues as a tuple (PR #155).
  - Fully tail-recursive CPS executor with line tracking off heap (PR #156).
  - Fast-path executor dispatch (numeric arith, comparisons, string
    concat, `get_field` / `set_field`) (PR #223).
  - In-range fast path for `Numeric.to_signed_int64/1` (B8, PR #227).
    -3% on fib(30).
  - Bench harness: quick mode + multi-n inputs via
    `LUA_BENCH_MODE` (PR #230). 17 min → 80 s for the full suite in
    quick mode; full mode preserved for publishable numbers.

## In flight: Direction A — Suite Triage (milestone `1.0.0`)

**Goal**: push the official Lua 5.3 test suite from 6/29 to a healthier
pass rate, without regressing unit tests, then cut `1.0.0-rc.1`.

The version jump from `0.4` to `1.0` reflects the magnitude of the VM
rewrite (Luerl is no longer a runtime dependency) and a commitment to
public API stability. Cutting an `rc` first leaves room to catch
regressions before locking 1.0 final.

Per-PR plans live in [`.agents/plans/A*.md`](.agents/plans). Issues track them
under the [`0.5.0` milestone](https://github.com/tv-labs/lua/milestone/1).

### High-leverage fixes (one bug → many files)

- ~~**A0**: 64-bit integer overflow wrapping for arithmetic and bitwise ops
  (Lua 5.3 §3.4.1; deliberate divergence from Luerl bignum semantics).~~
  Shipped in PR #177.
- ~~**A1**: Empty/missing-key table reads return `nil` (unblocks ~6 files).~~
  In review in PR #179.
- ~~**A2**: Long-string `[[ … ]]` lexer handles embedded `]` and level brackets `[==[`.~~
  In review in PR #180.
- ~~**A3**: Comment tokens leak past lexer in `calls.lua`.~~
  In review in PR #182.
- **A4**: Pre-load Lua stdlibs into `package.loaded` so `require"io"` resolves.

### Per-file assertions (one PR each, ≤ ½ day)

- **A5–A9**: `bitwise`, `locals`, `nextvar`, `events`, `pm`.

### Investigations

- **A10**: Timeouts in `big.lua`, `closure.lua`, `utf8.lua`.

### Polish

- ~~**A11**: Clear in-source TODOs (`compiler.ex:34`, `compiler_exception.ex:27`,
  `stdlib.ex:412`).~~ Shipped in PR #194.
- **A12**: README and CHANGELOG for 1.0.0-rc.1.
- **A13**: Cut `1.0.0-rc.1` (blocked on the rest).

## Direction B — Performance (`1.0.x`)

Several B-direction wins landed early on (PRs #153–#156, #223). The
B4–B8 sweep in May 2026 then attempted four larger architectural
levers; the results are summarised here so the lessons survive the
ephemeral plan files.

### Shipped

- **B8 — Numeric narrowing fast path** (PR #227). Guard-clause short
  circuits `Numeric.to_signed_int64/1` for in-range integers.
  −3.3% on fib(30) chunk, no regressions. The realised win came
  entirely from the guard short-circuit; `@compile {:inline, ...}`
  does not cross module boundaries, so the cross-module call sites in
  `Executor` / `Value` still trip a function boundary.
- **Bench harness rework** (PR #230). `LUA_BENCH_MODE=quick` (default)
  cuts the full suite from ~17 min to ~80 s; `LUA_BENCH_MODE=full`
  preserves the long windows plus a multi-`n` sweep (`{10, 100,
  1000}`) for the table workloads. This harness is what surfaced B7's
  scale regression — the single-`n` measurement we had before would
  have hidden it.

### Tried and deferred (with findings)

- **B6 — Eliminate per-tref `Map.fetch!` re-resolution.** Deferred in
  PR #229 / #231. Post-PR #223 profile no longer supports the
  hypothesis: `Map.get` is ~3.3% on fib(22) and ~0.04% on table_build.
  The earlier headline number (~6.4%) was absorbed by the fast-path
  work in PR #223. The remaining audit cleanup is worth doing later
  as a refactor, not as a perf plan.
- **B7 — Array + hash split for `Lua.VM.Table`.** Implemented in PR
  #229, closed unmerged. Wins at small `n` (-14% to -21% at `n=100`),
  loses badly at large `n` (+30% to +40% at `n=1000`). Memory
  regresses 3-5x at `n=1000`. The crossover is structural: BEAM
  tuples are immutable, so every `setelement/3` on a 1024-cell tuple
  copies the whole tuple. PUC-Lua avoids this with in-place mutation
  in C; we cannot. A future plan could revisit with
  *threshold-based promotion* (stay in the data map until
  `array_len ≥ N`, then promote) — the small-`n` wins are real and
  worth preserving if the regression can be avoided.
- **B4 — Flat instruction stream + PC dispatch.** Implemented end-to-
  end on a throwaway branch (all 1705 tests + 29 lua53 suite tests
  passed), closed unmerged (PR #233 records the findings). fib(30)
  regressed 3%; `do_execute` self-time was unchanged (50.6% vs main's
  50.8%). On the BEAM, `[head | rest]` head-match destructures
  head + tail in one op while `case :erlang.element(pc + 1, instrs)
  do` is two ops (fetch + case discriminate); the hoped-for jump-
  table optimization did not produce a net win. The
  `Lua.Compiler.Linearize` design that the implementation used is
  reusable as a **compile-time** input to B5 without affecting the
  runtime executor.

### What we learned

- **Measure against today's profile, not the plan's old profile.**
  B6's hypothesis was already obsolete when we got to it — PR #223
  had absorbed the win. Each B-plan should re-baseline before
  starting.
- **Multi-`n` measurement is essential for table workloads.** A
  single `n=500` data point is right on the BEAM-tuple-copy crossover
  for B7-style array promotion; either side of that crossover tells
  a completely different story. The bench harness rework was net
  positive for the rest of the series — without it the B7 regression
  at scale would have shipped.
- **BEAM optimisations are subtle.** `[head | rest]` head-matching is
  heavily optimized and is hard to beat with `case`-on-tuple-element.
  `@compile {:inline, ...}` does not cross module boundaries.
  Refactors that *should* help on theoretical grounds may not on the
  BEAM specifically; we have to measure.
- **Immutable data structures bound how fast we can be.** B7 hit this
  with `setelement/3` on large tuples. The same constraint shapes
  what B5 can deliver — register-tuple `setelement/3` is still 25%
  of every workload's profile and the BEAM gives us no way around
  that without going outside the VM (NIFs, ETS, persistent_term).

### Remaining lever: B5 — Compile prototypes to Erlang functions

B5 is the architectural lever for serious throughput: translate each
`%Lua.Compiler.Prototype{}` to an Erlang function body and call
`:compile.forms/2`, letting the BEAM JIT (BEAMASM on OTP 25+)
natively optimize the hot path. Plan stretch: fib parity with Luerl
(±5%). Plan:
[`.agents/plans/B5-compile-prototypes-to-erlang.md`](.agents/plans/B5-compile-prototypes-to-erlang.md).

B4's deferral does not block B5: the `Lua.Compiler.Linearize`
implementation from B4 can be reintroduced as a compile-time
preparation step (feeding B5's codegen flat bytecode) without
touching the runtime executor.

B5 is larger than B4 — full Erlang-AST codegen, module compile / load
/ purge lifecycle, fallback path for opcodes not yet translated. The
plan acknowledges that landing the framework is itself a
multi-month effort. Default position until a clear motivating
workload appears: **paused, with the implementation findings above
documenting why incremental dispatch-shape work is unlikely to move
the needle**.

## Deferred (intentional, not in 1.0)

These suite files exercise capabilities that conflict with this library's
role as a sandboxed embedded Lua VM. They are tracked as deliberate
non-goals, not "missing features we'd take a PR for". Per-file rationale
lives alongside the `@deferred_permanent` map in
`test/lua53_suite_test.exs`.

- **Standalone interpreter** (`main.lua`) — shells out via `os.execute`,
  writes Lua programs to temp files, invokes `lua` as a subprocess. We
  are an embedded VM with no shell-out and no standalone interpreter.
- **File I/O** (`files.lua`) — `io.open`, `io.input`, `io.output`,
  `io.lines`, `io.read`, `io.write`, `io.tmpfile`, plus `os.getenv`,
  `os.remove`, `os.rename`. `io.*` is a stub by design.
- **`require` semantics that need filesystem I/O** (`attrib.lua`) — writes
  `libs/A.lua`, `libs/B.lua`, etc. to disk and dynamically loads them.
- **>64K constants harness via tmpfile + dofile** (`verybig.lua`) — the RK/
  large-constants behaviour is interesting, but the harness writes a
  generated program with `os.tmpname()`/`io.output()` and `dofile`s it.
  A future plan could stub these for the suite runner only.

Other deferrals in this milestone:

- **Coroutines** (`coroutine.lua`) — full continuation/process model, weeks of work.
- **Garbage collection / weak tables** (`gc.lua`).
- **Full debug library** (`db.lua`).
- **C-stack tests** (`cstack.lua`).
- **Backward `goto` and goto-out-of-conditional** (3 skipped unit tests in
  `test/lua/compiler/integration_test.exs`).

## Glossary

- **Suite** — the official Lua 5.3 test files in `test/lua53_tests/`.
- **Plan** — a single-PR-shaped chunk of work, lives in `.agents/plans/`.
- **Direction** — strategic grouping (A = correctness/suite, B = performance).
- **Milestone** — GitHub milestone tracking direction-scoped issues for a release.

## Cadence

- The agent updates the **Status** section above on each merged PR via the
  `ship-a-plan` skill.
- The human (Dave) updates the **In flight / Next / Deferred** sections on Mondays
  or whenever strategy shifts.
