# Lua VM Roadmap

This is the strategic overview. For per-PR detail, see [`.agents/plans/`](.agents/plans).

## Status: 2026-05-02

- **Unit tests**: 1,273 passing, 0 failing, 32 skipped.
- **Lua 5.3 official suite**: 4/24 files passing (`simple_test.lua`, `api.lua`, `code.lua`, `vararg.lua`).
- **Current focus**: [Direction A — Suite Triage](#in-flight-direction-a--suite-triage-milestone-050).

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

## In flight: Direction A — Suite Triage (milestone `0.5.0`)

**Goal**: push the official Lua 5.3 test suite from 4/24 to ≥ 12/24 passing files,
without regressing unit tests, then cut `0.5.0-rc.1`.

Per-PR plans live in [`.agents/plans/A*.md`](.agents/plans). Issues track them
under the [`0.5.0` milestone](https://github.com/tv-labs/lua/milestone/1).

### High-leverage fixes (one bug → many files)

- ~~**A0**: 64-bit integer overflow wrapping for arithmetic and bitwise ops
  (Lua 5.3 §3.4.1; deliberate divergence from Luerl bignum semantics).~~
  Shipped in PR #177.
- **A1**: Empty/missing-key table reads return `nil` (unblocks ~6 files).
- **A2**: Long-string `[[ … ]]` lexer handles embedded `]` and level brackets `[==[`.
- **A3**: Comment tokens leak past lexer in `calls.lua`.
- **A4**: Pre-load Lua stdlibs into `package.loaded` so `require"io"` resolves.

### Per-file assertions (one PR each, ≤ ½ day)

- **A5–A9**: `bitwise`, `locals`, `nextvar`, `events`, `pm`.

### Investigations

- **A10**: Timeouts in `big.lua`, `closure.lua`, `utf8.lua`.

### Polish

- **A11**: Clear in-source TODOs (`compiler.ex:34`, `compiler_exception.ex:27`,
  `stdlib.ex:412`).
- **A12**: README and CHANGELOG for 0.5.0.
- **A13**: Cut `0.5.0-rc.1` (blocked on the rest).

## Next: Direction B — Performance (milestone `0.5.x`)

Several B-direction wins shipped already (PRs #153–#156). What remains:

- **B1**: Drop `source_line` instructions in non-debug compilation.
- **B2**: Codegen peephole pass (fold `load_constant N k; move M N` → `load_constant M k`).
- **B3**: Re-baseline benchmarks against Luerl and PUC-Lua. Decide whether further
  architectural work (e.g. flat instruction stream + PC dispatch) is justified.

Per-PR plans land in [`.agents/plans/B*.md`](.agents/plans) when Direction A
wraps.

## Deferred (intentional, not in 0.5)

- **Coroutines** (`coroutine.lua`) — full continuation/process model, weeks of work.
- **Garbage collection / weak tables** (`gc.lua`).
- **File I/O** (`files.lua`).
- **Full debug library** (`db.lua`).
- **C-stack tests** (`cstack.lua`).
- **Backward `goto` and goto-out-of-conditional** (3 skipped unit tests in
  `test/lua/compiler/integration_test.exs`).
- **`string.pack` / `unpack` / `packsize`** (`tpack.lua`) — mechanical, but not
  blocking 0.5.

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
