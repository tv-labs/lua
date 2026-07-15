# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Upgrading from a Luerl-based `0.x` release? See
> [Upgrading from 0.x](#upgrading-from-0x-luerl-based-versions) below, or the
> full [Migrating to 1.0](guides/migrating-to-1.0.md) guide for step-by-step
> before/after code.

## Upgrading from 0.x (Luerl-based versions)

`1.0.0` replaces the Luerl backend with an Elixir-native Lua 5.3 VM, and
Luerl is no longer a runtime dependency. Most code built on the high-level
`Lua` API (`Lua.new/1`, `Lua.eval!/2`, `Lua.set!/3`, `deflua`,
`Lua.load_api/2`) keeps working unchanged. The breaking changes are all at
the value-encoding and error boundaries:

- **Encoded table / userdata / function tags changed.** Values that carried
  Luerl's internal tags now use the new VM's representation: tables are
  `{:tref, integer()}` (was `:luerl.tref()`), userdata is
  `{:udref, integer()}` (was `:luerl.usdref()`), and Elixir-defined Lua
  callables are `{:native_func, fun}` (was `:luerl.erl_func()`); compiled Lua
  functions are `{:lua_closure, _, _}`. If you pattern-matched the old
  tuples, update the patterns — better still, treat encoded refs as opaque
  and round-trip them through `Lua.decode!/2`.
- **MFA callback encoding was removed.** `Lua.encode!/2` no longer accepts the
  `{module(), atom(), list()}` MFA tuple form. Replace it with a function
  literal or a `deflua` callback.
- **Parser error messages have a new format.** The Luerl-style
  `"Line 1: syntax error before: ';'"` is gone; the native parser produces
  messages like `"Expected expression"`, with rich structured data available
  via `Lua.Parser.parse_structured/1`. Assertions that string-matched the old
  wording need updating.
- **64-bit integers wrap on overflow.** Arithmetic and bitwise ops follow Lua
  5.3 §3.4.1 (wrap-around at 2^63) instead of widening to bignums as Luerl
  did. Code depending on arbitrary-precision integer results will now see
  wrapped values.
- **Chunks are self-contained.** `Lua.Chunk` now holds a compiled prototype
  and is reusable across `Lua.eval!/2` calls; there is no separate load step.
- **Exceptions are public.** `Lua.RuntimeException` and `Lua.CompilerException`
  are documented, so user code can rescue and pattern-match them.

Everything else — the default sandbox, `_G`/`_ENV` semantics, metatables, and
the standard-library surface — is compatible. The full breaking-change list
is in the [`1.0.0-rc.0`](#100-rc0---2026-05-26) entry below.

## [Unreleased]

### Added
- `Lua.format_exception/1` renders a `Lua.RuntimeException` or
  `Lua.CompilerException` as the rich, human-readable report — location, source
  context, stack trace, and suggestions — with ANSI color when
  `IO.ANSI.enabled?/0` is true. This is the report `mix lua.eval` prints.
- `Lua.RuntimeException.to_map/2` and `Lua.CompilerException.to_map/1` expose a
  wire-safe structured representation (no ANSI) for JSON payloads, structured
  logs, and UI-facing error reporting (#393).

### Changed
- `Exception.message/1` on `Lua.RuntimeException` and `Lua.CompilerException`
  now returns a plain, single-line, ANSI-free string suitable for `Logger` and
  error trackers, rather than the multi-line ANSI report. The rich report moved
  to `Lua.format_exception/1`. This removes ANSI escapes from logs even when the
  app is started from a TTY (where `IO.ANSI.enabled?/0` is true). If you relied
  on `Exception.message/1` for the rich render, switch to `Lua.format_exception/1`
  (#393).

## [1.0.0] - 2026-07-15

The first stable release on the Elixir-native Lua 5.3 VM, culminating the
`1.0.0-rc.0` through `rc.3` series. Upgrading from the last public release,
`0.4.0`? See [Migrating to 1.0](guides/migrating-to-1.0.md) for the full
walkthrough. The changes below are those since `rc.3`.

### Changed
- Elixir callbacks now receive the public `Lua.t` (`%Lua{}`) as their state
  argument **regardless of how they enter the VM**. Previously a two-arity
  callback (`fn args, state -> {results, state} end`) got a `%Lua{}` when set
  at a path or loaded via `deflua`/`Lua.load_api/2`, but the raw internal
  `Lua.VM.State` when it reached the VM as an encoded value — nested inside a
  value passed to `Lua.set!/3`, or produced by `Lua.encode!/2`. Those paths
  now wrap the state consistently and validate the callback's return value, so
  the same closure behaves identically everywhere. Code relying on the rc.3
  raw-state behaviour (or a `%Lua{state: raw}` workaround) should drop the
  workaround (#379).

<!-- A50: API pre-freeze fixes — breaking-before-1.0 changes are called out
     explicitly so they never surprise anyone after the surface freezes. -->

### Changed (breaking, before 1.0 freeze)
- Encoding a bare Elixir struct now raises. Previously `Lua.encode!/2` (and
  `Lua.set!/3`) matched a struct as a plain map and silently encoded a Lua
  table carrying a `"__struct__"` key — a lossy, accidental conversion.
  Convert structs explicitly first (e.g. `Map.from_struct/1`), selecting the
  fields Lua needs. This lands before 1.0 so the planned `Lua.Encoder`
  protocol (#341) can be added without breaking a behaviour people relied on.
- Removed the `is_mfa` guard from `Lua.API`. It was a Luerl-era compatibility
  shim that always returned `false` and was imported into every `use Lua.API`
  module; the VM has no MFA references. Remove any `when is_mfa(value)` clauses
  (they never matched).
- **The public runtime exception is now solely `Lua.RuntimeException`.** The
  five internal VM error structs — `Lua.VM.RuntimeError`, `Lua.VM.TypeError`,
  `Lua.VM.ArgumentError`, `Lua.VM.AssertionError`, `Lua.VM.InternalError` — are
  no longer part of the public surface. They are wrapped into
  `Lua.RuntimeException` before crossing any API boundary, so the whole public
  exception surface is just `Lua.RuntimeException` (runtime failures) and
  `Lua.CompilerException` (compile-time failures). To discriminate a runtime
  failure, read the wrapper's new `:kind` field
  (`:error | :type | :argument | :assertion | :internal`); the underlying VM
  struct remains available on `:original`.
- The public `{:error, _}`-returning APIs now hand back the exception struct
  uniformly, instead of a pre-rendered message string, so callers own
  rendering (`Exception.message/1`) and can pattern-match the concrete error.
  - `Lua.call_function/3` returns `{:error, exception, lua}` where `exception`
    is always a `Lua.RuntimeException`. The raised Lua value (`error(42)`, a
    table, `nil`, `false`) is preserved on `:value`, matching what `pcall`
    hands back inside Lua, with the category on `:kind` and the underlying VM
    struct on `:original`. Code matching on a string reason should switch to
    the exception (or call `Exception.message/1` on it).
  - `Lua.parse_chunk/1` returns `{:error, %Lua.CompilerException{}}` instead of
    `{:error, [String.t()]}`. Call `Exception.message/1` to render the full,
    human-readable report; the `:errors` field carries the bare, ANSI-free
    messages for programmatic inspection.
- Lua exceptions render their message lazily at `Exception.message/1` call
  time, so the `:message` **struct field** is `nil` on the
  `Lua.RuntimeException` wrapper when it wraps an internal VM exception (and on
  the internal VM structs themselves). Read the message through
  `Exception.message/1` (the idiomatic accessor) rather than the `e.message`
  field. Likewise `Lua.CompilerException`'s
  `:errors` field now holds bare, ANSI-free messages rather than the fully
  formatted (and previously ANSI-colored) diagnostics — the rich report moved
  to `Exception.message/1`. This is what lets the ANSI gate hold at output time
  (#384).

### Changed
- `Lua.new/1`'s `:max_string_bytes` now accepts `:infinity` for no limit,
  making it uniform with its siblings `:max_call_depth` and
  `:max_instructions`.
- `Lua.CompilerException` no longer has a `:state` field. It was never
  populated (always `nil`); `:errors` carries all the formatted diagnostics.

### Fixed
- Lua exception messages no longer leak ANSI escape codes (and multi-line rich
  rendering) into non-terminal sinks such as log files, container stdout, or a
  Sentry/AppSignal title. Messages were formatted eagerly during VM execution —
  where `IO.ANSI.enabled?/0` is true — freezing escape codes into the struct
  that survived long after the TTY gate. They now render at `Exception.message/1`
  call time, so the ANSI gate is evaluated where the message is actually written
  (#384).
- `Lua.eval!/3` now accepts a `:source` option when evaluating a pre-compiled
  `Lua.Chunk`, matching the string-script clause. Previously
  `eval!(lua, chunk, source: "x")` raised via `Keyword.validate!`. For a chunk
  the option is accepted but ignored — the chunk already carries the source
  name it was compiled with.
- `Lua.encode!/2` now maps Elixir `nil` to Lua `nil` instead of the string
  `"nil"`. Previously top-level `nil` fell into the atom-encoding head and
  became `"nil"`, which is truthy in Lua — silently inverting `if not value
  then ...` checks and breaking `return nil, "reason"` error patterns. The
  round trip `decode!(encode!(nil))` is now lossless, matching the existing
  behaviour for `nil` inside tables and function result lists (#374).
- `string.rep` now sizes its allocation to the actual result length instead of
  the raw repeat count, so a large count paired with an empty or short string
  (e.g. `string.rep("", 1e9)`) no longer over-allocates or trips the
  string-size guard spuriously. The guard still refuses genuinely oversized
  results (#376).

### Documentation
- The Lua 5.3 official test suite now passes **20/29** files. The 9 excluded
  files are deliberate, documented exclusions rather than open bugs:
  - **Filesystem / subprocess non-goals** — `main`, `files`, `attrib`,
    `verybig` (shell-out, file I/O, and filesystem `require`, which a
    sandboxed embedded VM does not support).
  - **Capability non-goals** — `coroutine`, `db` (the full
    continuation/coroutine model and the full `debug` library).
  - **Perf-bound, revisit in 1.0.x** — `big`, `closure` (run past the suite
    timeout on the BEAM tuple-copy ceiling; the VM results are correct).
  - **PUC error-wording divergence** — `errors` (our structured error
    messages diverge from PUC-Lua's exact strings).

## [1.0.0-rc.3] - 2026-06-15

The fourth release candidate for `1.0.0`. It builds on rc.2 with a
structured parse-error API for tooling, conformant `goto`/`label` on
both VM engines, several order-of-magnitude performance wins on the
table and recursive-call paths, and a batch of parser error-location
and protected-call error-value fixes. All public API changes are
additive — nothing from rc.2 is broken.

### Added
- `Lua.Parser.parse_structured/1` returns `{:ok, Chunk.t()} | {:error,
  [%Lua.Parser.Error{}]}`, exposing the parser's rich structured error
  data directly instead of as a pre-formatted ANSI string — a stable
  contract for editors, LSPs, and web frontends that render parse errors
  in their own UI. `Lua.Parser.Error.to_map/1,2` emits a
  JSON-serializable map with the **same wire shape** as
  `Lua.VM.ErrorFormatter.to_map/3` (`type`, `message`, `source`, `line`,
  `call_stack`, `source_context`, `suggestion`, `error_kind`), so parse
  and runtime errors can flow through a single renderer; the `^` pointer
  column now lands on the real offending token (#363).
- `Lua.new/1` accepts `:max_instructions` (default `:infinity`), bounding the
  number of VM instructions a single evaluation may execute. Exceeding the
  budget raises a catchable `"instruction budget exceeded"` runtime error,
  giving a deterministic CPU bound without wrapping each call in a host
  `Task` plus wall-clock timeout. Enforced at loop back-edges and call
  boundaries on both the interpreter and compiled-dispatcher paths via a
  single `Lua.VM.State.tick!/2` call that is a true no-op at `:infinity`
  (no increment, no struct rebuild), so the default `:infinity` carries no
  per-opcode cost; the budget is fresh per top-level evaluation and
  recoverable via `pcall` (#320).

### Performance

- **Register tuples are sized to an honest peak, with no slack buffer, on
  both VM engines (#312, #324).** Both the interpreter (`call_function/3`,
  the `:call` opcode, `call_value/5`) and the dispatcher
  (`init_callee_regs/4`) used to over-allocate every call frame's register
  tuple — the interpreter with a `+16` buffer, the dispatcher with the `+16`
  slack #347 added. On call-dense, work-light code (naive `fib(30)` most
  visibly, ~25%+ slower than rc.0) that per-frame over-allocation dominated.
  Both buffers existed to mask a latent codegen bug: `max_registers` could
  undercount the true register peak for some deeply-nested expression
  shapes. Codegen's new `instruction_peak/1` backstop makes `max_registers`
  honest (it counts every statically-fixed destination the emitted stream
  writes), so both engines now size to exactly `max(max_registers,
  param_count)` and grow on demand only for runtime-dynamic writes (vararg
  spread, multi-return distribution). The interpreter path is ~26% faster
  on `fib(25)` (closing the dispatcher–interpreter gap to ~1.02×), and
  `fib(30)` on the dispatcher improves from ~1.32× slower than Luerl to
  ~1.11× (Apple M-series, drift-controlled), with no other workload slower.
- **Recursive-call path closes the fibonacci gap with Luerl (#360).**
  Two profiler-driven fixes: call frames defer name decoding (a flat
  3-tuple `{source, line, name_hint}` decoded lazily at the cold
  traceback/`debug.getinfo` readers instead of an eager 4-key map per
  call), and codegen reclaims the register window after single-result
  calls so sibling calls reuse freed registers (`fib` drops from
  `max_registers = 10` to `6`, shrinking every per-frame `setelement`).
  `fib(30)` goes from ~1.18× slower than Luerl to ~1.03× (within run-to-run
  noise) and total allocations fall ~26%.
- **`#t` is now O(1) on tables with no holes (#350).** Lua tables cache
  their array-sequence border, so the length operator no longer rescans
  the array part on every read. Append loops (`t[#t+1]=v`,
  `table.insert(t, v)`) collapse from O(n²) to O(n) — **−98%** at n=2000
  (21.96 ms → 0.44 ms). The cache is only re-established when `1..n` is
  provably dense, so holey tables fall back to a correct scan.
- **`pairs` over hash-keyed tables is O(n), not O(n²) (#349).**
  `lua_next` memoizes the hash-key iteration order on the first step of
  an iteration, making each subsequent `next` O(1) instead of rescanning
  from the front. Iterating a large string-keyed table improves **−92.5%**
  at n=2000 (11.43 ms → 0.86 ms), with the gap widening as n grows.
- **Bitwise opcodes (`band`/`bor`/`bxor`/`shl`/`shr`) and `set_list`
  multi-return tails now compile on the dispatcher (#347)** instead of
  falling back to the interpreter, closing dispatcher coverage gaps. The
  micro-benchmark delta is noise-dominated; this is a coverage fix, not a
  measurable speedup.

### Fixed
- **`goto`/`label` are conformant on both VM engines (#364).** The
  interpreter previously resolved labels with a forward-only scan, so
  backward jumps (manual loops), `continue`-style jumps out of an `if`,
  and break-style jumps out of a loop all raised "goto target not found".
  Labels are now resolved ahead of execution on both the interpreter
  (`Lua.Compiler.GotoResolution`) and the compiled dispatcher
  (`Bytecode.resolve_gotos/2`), closing open upvalues at the block-exit
  level per Lua 5.3 §3.3.4. (One dispatcher gap remains: short-circuit
  `and`/`or` still falls back to the interpreter.)
- **Parse errors are reported at the real offending token (#357, #365,
  #366).** A syntax error deep inside a function-call argument list — e.g.
  an unclosed `(` several lines down — was blamed at the call's opening
  line instead of where the mistake actually is. The parser no longer
  swallows a committed deep error to "recover" a partial argument list,
  and position-independent error shapes (`bare_expression`,
  `invalid_assign_target`, `unclosed_delimiter`, `unexpected_end`) always
  propagate. Unclosed tables and empty bracket lists now blame the opening
  delimiter with an "add a closing X" suggestion, matching the convention
  calls and indexes already followed.
- **`Lua.call_function/3` returns the terse Lua error value for
  `ArgumentError` (#354).** A missing `error_value/1` clause let
  `ArgumentError` fall through to `Exception.message/1`, embedding ANSI
  codes and the `at <source>:<line>:` header in the reason returned by
  `call_function/3` and `pcall`/`xpcall`. It now returns the §6.1-faithful
  terse string (e.g. `"bad argument #1 to 'pairs' (table expected, got
  string)"`); `call_function!/3` remains the escape hatch carrying the
  structured exception.
- **Compiled-chunk errors attribute the correct source line (#355).** The
  dispatcher baked per-call source lines into the call opcodes, so native
  raise sites (`pairs("asdf")`, `error("boom")`) in compiled chunks now
  include the line in their §6.1 prefix instead of omitting it. The hot
  path is unchanged (same single tuple-read per call).
- **Freshly `require`d modules now appear in `pairs(package.loaded)`
  (#356).** `cache_module_result/3` wrote `Table.data` directly, bypassing
  the iteration-order bookkeeping, so a required module was reachable by
  direct index but never enumerated. Routing the write through
  `Table.put/3` fixes the enumeration.
- **`tostring` on a function now returns a `function: 0x...` address**
  instead of the bare string `"function"`, matching PUC-Lua's
  `tostring(print)`-style output (builtins render as
  `function: builtin: 0x...`). The address is a deterministic
  per-value pseudo-pointer. Table rendering (`table: 0x...`) is
  unchanged. `type(f)` still returns `"function"`.

## [1.0.0-rc.2] - 2026-06-10

The third release candidate for `1.0.0`. It builds on rc.1 with a major
table-storage performance win, two non-standard `os` epoch helpers, and
a batch of protected-call and error-value correctness fixes that bring
`pcall` / `xpcall` and `Lua.call_function/3` in line with Lua 5.3 §6.1.
The public API is unchanged from rc.1.

### Performance

- **Split-storage tables (Erlang `:array` + map)** — dense
  positive-integer keys (`1..n`) now route to an Erlang `:array` for
  O(1) functional read/write and dense iteration ordering, while
  strings, sparse/non-positive integers, and other key types stay in
  the hash map with the existing iteration bookkeeping (#328).
  String-keyed reads (globals, fields, metatable lookups) are unchanged.
  Table-heavy workloads improve **28–37%** at n=1000 (Apple M4, `lua`
  chunk path): Build **−36%**, Iterate/Sum **−36%**, Map+Reduce
  **−37%**, Sort **−28%**. Build, Iterate, and Map+Reduce now beat
  Luerl; Sort closes most of the gap.

### Added

- **`os.time_ms()` and `os.time_us()`** — non-standard extensions
  returning the current epoch in milliseconds / microseconds, for
  programs that need sub-second precision (`os.time()` is unchanged and
  still returns whole seconds). Both are current-time-only and are
  documented as extensions not present in PUC-Lua (#340).
- The `os.clock()` monotonic origin is now seeded in `install/1` rather
  than lazily on the first call, so elapsed time is measured from a
  stable startup point instead of drifting to whenever a program first
  happened to call `os.clock()` (#340).

### Fixed

- **`deflua/2` guarded heads register under their real name** (#344). A
  guarded head with no state argument
  (`deflua clamp(a) when is_integer(a)`) was registered under the name
  `:when` instead of `clamp`, making it uncallable from Lua (calling it
  raised an undefined-function error). The macro now unwraps the `:when`
  AST node to reach the real name, matching the `deflua/3` (state-arg)
  variant, which was never affected.
- **`Lua.call_function/3` returns the terse Lua error value, not the terminal
  render** (#336). Its `{:error, reason, _}` previously surfaced the
  terminal-formatted error string — ANSI escape codes, the `at <source>:<line>:`
  header, the `Suggestion:` block, stack-trace frames, and a doubled
  `Lua runtime error: … runtime error:` prefix — where a programmatic value was
  expected. `reason` is now exactly what `pcall` hands back (§6.1): the
  `source:line:`-prefixed message for string errors, and the raw value
  (table/number/`nil`/`false`) passed through verbatim for non-string error
  objects. Note `reason` may therefore now be a non-string Lua value. The
  raising variant `Lua.call_function!/3` is unchanged — it still raises a
  `Lua.RuntimeException` carrying the rich formatted render.
- **`pcall` passes the raised error value through as-is** (#334). Per Lua 5.3
  §6.1, `error(value)` raises an arbitrary Lua value and `pcall` returns it
  verbatim as its second result — previously non-string values were
  stringified (`error({code = 1})` came back as `"table: 0x..."`). Structured
  error objects, numbers, booleans, and `nil` now survive `pcall`/`xpcall`,
  and the `xpcall` message handler receives the untouched value. String
  messages gain the reference `source:line:` position prefix (suppressed by
  `error(msg, 0)`); note `pcall`'s second result may therefore now be a
  non-string Lua value. Host-facing `Lua.VM.RuntimeError` rendering is
  unchanged.
- **Protected calls no longer roll back heap effects** (#331). When a function
  called via `pcall`/`xpcall` (or `Lua.call_function/3` from Elixir) raised an
  error, mutations made before the error — global writes, table field updates,
  upvalue assignments, metatable changes — were silently discarded, diverging
  from reference Lua. VM exceptions now carry the raise-time state, and
  protected-call boundaries recover it: heap state is kept, control state
  (call stack, open upvalues) unwinds. The `xpcall` message handler now also
  observes those mutations, matching PUC-Lua's handler semantics.

### Known issues

- **Deep recursion is ~25% slower than rc.0.** Carried forward from
  rc.1: the configurable call-depth limit (#283) adds per-call
  bookkeeping that recursion-dense workloads (e.g. naive `fib(30)`) pay
  in full. Workloads that do real work per call are unaffected or
  faster. This remains a deliberate safety/speed tradeoff for the RC and
  will be addressed before `1.0.0` final.

## [1.0.0-rc.1] - 2026-06-02

The second release candidate for `1.0.0`. It builds on rc.0 with a new
`os` and `utf8` standard library, richer `debug` and error introspection,
a sizeable `string.format` and `table` performance pass, and a batch of
correctness fixes around upvalue lifetimes and Lua 5.3 semantics. The
public API is unchanged from rc.0.

### Performance

A focused pass on the two hottest stdlib areas and the VM dispatcher.
Numbers are pre-compiled-chunk throughput vs. rc.0, full Benchee runs on
the same machine (Luerl and PUC-Lua used as drift controls, ±3%):

- **`string.format` rewritten around iolist accumulation** — literal runs
  and padding are appended to an iolist instead of repeatedly concatenating
  binaries, format flags are parsed once and dispatched on the integer
  specifier, and float conversion goes through `io_lib.format` (#299, #317,
  #319, #316). The literal-heavy path is **+143%** (now ~2.7× faster than
  Luerl); width-flagged specifiers **+83%**; many-specifier strings **+26%**.
- **Plain-table `table.sort` / `table.concat` fast paths** for the common
  array-like case, with batched write-back in the sort path (#299, #318).
  `table.sort` is **+35%** at n=1000; `table.concat`-based string building
  is **+66%**.
- **Expanded VM dispatcher coverage** to closures, varargs, multiple
  returns, numeric/generic loops, `self` method calls, concat, and table
  opcodes (#275, #277). Object-oriented method dispatch is **+41%** (now
  faster than Luerl).
- **Batched table-literal construction** through `Table.put_many/2` in a
  single pass instead of element-by-element (#321).

### Added
- `os` standard library, sandboxed: `time`, `clock`, `date`, `difftime`,
  `getenv` (no-op), and friends, with host-affecting calls neutered (#289).
- `utf8` standard library, plus aligned integer-arithmetic error wording
  (#258).
- `debug` introspection: upvalue name tracking with `debug.getupvalue` /
  `debug.setupvalue` (#285), and `debug.getinfo` now populates `name` /
  `namewhat` from the call site (#290).
- Position captures `()` in patterns across `find` / `match` / `gmatch` /
  `gsub` (#288).
- Configurable maximum call depth to bound recursion (#283).
- Allocation-bomb DoS hardening with documented sandboxing limits (#305).
- Structured error data on runtime errors (#246); arithmetic and bitwise
  type errors now thread operand hints into the message (#270).

### Changed
- Rendered errors now lead with the source location, and ANSI colour is
  gated on whether output is a TTY (#304).
- Broader Lua 5.3 official test suite coverage: triaged and promoted
  `literals` / `goto` / `events` / `nextvar`, and narrowed the remaining
  skips (`pm`, `gc`, `constructs`) to precise sub-ranges (#251, #282, #287,
  #294, #295).
- README rewritten for 1.0 positioning with a quickstart and tour (#298),
  runnable embedding examples under `examples/` (#300), and `@spec` / type
  definitions across the public API (#301).

### Fixed
- Open upvalues are now closed at the exit of `do`, `if`, `while`, `for`,
  and `repeat` blocks (#286, #303), and the caller's `open_upvalues` are
  restored after a nested execution returns (#245).
- `require` no longer leaks the loaded module's `open_upvalues` map back
  to the calling chunk. Loading a module whose body created closures over
  its own top-level locals could alias the caller's locals to stale inner
  upvalue cells, breaking real-world libraries (e.g. `luassert.assertions`,
  `luassert.array`, `luassert.spy`) that follow the pattern
  `local x = require(...)` → many `local function` defs → `x:method(...)`.
  As a side effect, `Lua.call_function/3` (public API) now preserves the
  caller's `open_upvalues` across calls (#244).
- Integer divide and modulo by zero now match PUC-Lua semantics (#292).
- `table.unpack` rejects oversized ranges instead of attempting a huge
  allocation (#293).
- `gsub` validates its replacement string and value (#291).
- A parenthesised call or vararg now adjusts to a single value (#278).
- Function-declaration head names resolve during scope analysis (#274).
- `obj:method(...)` calls expand multiple values in the argument list
  (#248).
- `require()` converts dotted module names to path separators (#242).

### Known issues
- **Deep recursion is ~25% slower than rc.0.** The configurable call-depth
  limit (#283) adds per-call bookkeeping that recursion-dense workloads
  (e.g. naive `fib(30)`) pay in full. Workloads that do real work per call
  are unaffected or faster. This is a deliberate safety/speed tradeoff for
  the RC and will be addressed before `1.0.0` final.

## [1.0.0-rc.0] - 2026-05-26

This is the first release candidate for `1.0.0`. The library has been
rewritten on a new Elixir-native Lua 5.3 virtual machine, and the public
API is intended to be stable. Please report any regressions before final.

### Added
- New Elixir-native Lua 5.3 virtual machine: lexer, parser, compiler, and
  register-based executor, with no Erlang or C dependencies.
- Standard library: `string` (including `string.format` width/precision,
  `string.pack`/`unpack`/`packsize`, and the full pattern engine for
  `find`/`match`/`gmatch`/`gsub`), `table`, `math` (including `math.fmod`),
  `debug`, `io` stubs (sandboxed), `os` (sandboxed), `package`/`require`.
- `_G` global table and Lua 5.3 `_ENV` semantics for global access.
- Full metamethod dispatch: `__index`, `__newindex`, `__call`, plus the
  arithmetic, comparison (including `~=` via `__eq` and `<=`/`>=` falling
  back through `__lt`), length, concat, and `tostring` metamethods.
- Varargs (`...`), multiple returns, generic `for`, `goto`/`label`, `break`,
  protected calls (`pcall`, `xpcall`).
- `userdata` support for passing arbitrary Elixir terms across the boundary.
- Beautiful Lua-style stack traces and error messages with source line
  tracking. Every runtime error carries line and source info (#214, #215),
  and `attempt to call`/`attempt to index` errors name the offending
  callee/target (#228).
- `Inspect` protocol support for VM values returned across the
  `Lua.eval!/2` boundary via display structs for tables, closures,
  userdata, and native functions (#218).
- Mix tasks: `mix lua.eval`, `mix lua.suite`, `mix lua.bench` (#220).
- Lua 5.3 official test suite integration with per-file rationale for
  suite files that are deferred as intentional non-goals (`main.lua`,
  `files.lua`, `attrib.lua`, `verybig.lua` — shell-out, file I/O, and
  filesystem `require` semantics that conflict with a sandboxed embedded
  VM) (#216).
- Benchmark harness comparing against Luerl and PUC-Lua, with quick mode
  and multi-`n` inputs (#230) and a `setup_luaport.sh` helper (#225).

### Changed
- **VM backend**: Luerl is no longer a runtime dependency. The library now
  runs on its own Elixir-native VM. Luerl is kept only as a `:benchmark`-env
  dependency for performance comparison.
- Encoded value tags now use the new VM's internal representation:
  `{:tref, integer()}` for tables (replacing `:luerl.tref()`), `{:udref,
  integer()}` for userdata (replacing `:luerl.usdref()`), `{:native_func,
  fun}` for Elixir-defined Lua callables (replacing `:luerl.erl_func()`),
  and `{:lua_closure, _, _}` for compiled Lua functions.
- Parser error messages have a new format. The old Luerl-style
  `"Line 1: syntax error before: ';'"` is now produced by the new parser
  (e.g. `"Expected expression"`); user-visible string contents differ.
- Chunks no longer require a separate "load" step — `Lua.Chunk` now holds a
  compiled prototype and is reusable across `Lua.eval!/2` calls.
- 64-bit integer arithmetic and bitwise ops wrap on overflow per Lua 5.3
  §3.4.1, instead of widening to bignums (Luerl's behaviour).
- `Lua.RuntimeException` and `Lua.CompilerException` are now publicly
  documented; user code can pattern-match and rescue them.

### Removed
- The `{module(), atom(), list()}` MFA encoding form is no longer accepted
  by `Lua.encode!/2`. Use a function literal or a `deflua` callback
  instead.

### Performance
- Right-size register tuple allocations (#153).
- O(N²) → O(N) upvalue collection in the closure handler (#154).
- O(1) upvalue access by storing upvalues as a tuple (#155).
- Fully tail-recursive CPS executor with line tracking moved off the heap
  (#156).
- Fast-path the executor dispatch loop (#223).
- Fast-path `Numeric.to_signed_int64` for in-range integers (#227).

### Fixed
- 64-bit integer overflow wrapping for arithmetic and bitwise ops (#177).
- Empty/missing-key table reads now return `nil` per Lua 5.3 §3.4.11
  (#179, #200).
- Long-string `[[ ... ]]` lexer handles embedded `]` and bracket levels
  like `[==[ ... ]==]`, including `main.lua`-style headers (#180).
- Comment tokens no longer leak past the lexer in expression lists (#182).
- Stdlib modules are pre-populated in `package.loaded` so `require"io"`
  resolves (#184); module sentinel is set before executing required
  modules (#191).
- For-loop variable now binds per statement, fixing register reuse (#195).
- Closure-handler crash on missing upvalue cells in `get_open_upvalue` and
  `set_open_upvalue` (#196).
- `_ENV` semantics for global variable access (#197).
- Hex literal and string coercion in bitwise ops (#198); `math.fmod`
  implemented for `bitwise.lua` verification (#199).
- Function declaration assigned to in-scope local rather than shadowing
  it (#185).
- Multi-return expansion no longer overflows the register tuple (#189).
- Pattern engine threads VM state through `gsub` callbacks and preserves
  capture order (#188, #190).
- Atom values encode to strings (#158).
- Files containing only comments load successfully.
- Unicode characters supported in Lua scripts.
- `pairs` survives mid-iteration deletion by tracking dead keys (#202).
- Metamethod closures receive operands through varargs (#203).
- Float division by zero yields ±`math.huge` instead of raising (#204);
  `//` and `%` with a float-zero divisor return `inf`/`nan` (#211).
- Lexer treats vertical tab and form feed as whitespace (#206).
- Table-library functions (`insert`, `remove`, `concat`, etc.) honor
  `__index`, `__newindex`, and `__len` (#208).
- Numeric `for` coerces string control values per Lua 5.3 §3.3.5 (#209).
- `io` is now exposed as a table of sandboxed stubs (#210).
- `~=` routes through the `__eq` metamethod (#212); `<=`/`>=` fall back
  through `__lt` per Lua 5.3 §3.4.4 (#213).
- Parser threads position info through bare-expression and
  unexpected-end errors (#222).
- Internal Lua VM frames pruned from `Lua.RuntimeException` stacks by
  default; opt back in with `Lua.new(debug: true)` (#221).
- Line number attribution for the first line of a chunk (#240).
- `string.pack` no longer emits compile warnings (#224).

## [0.4.0] - 2025-12-06

### Changed
- Upgrade to Luerl 1.5.1

### Fixed
- Warnings on Elixir 1.19

## [0.3.0] - 2025-06-09

### Added
- Guards for encoded Lua values in `deflua` functions
  - `is_table/1`
  - `is_userdata/1`
  - `is_lua_func/1`
  - `is_erl_func/1`
  - `is_mfa/1`

### Fixed
- `deflua` function can now specify guards when using or not using state

## [0.2.1] - 2025-05-14

### Added
- `Lua.encode_list!/2` and `Lua.decode_list!/2` for encoding and decoding function arguments and return values

### Fixed
- Ensure that list return values are properly encoded

## [0.2.0] - 2025-05-14

### Changed
- Any data returned from a `deflua` function, or a function set by `Lua.set!/3` is now validated. If the data is not an identity value, or an encoded value, it will raise an exception. In the past, `Lua` and Luerl would happily accept bad values, causing downstream problems in the program. This led to unexpected behavior, where depending on if the data passed was decoded or not, the program would succeed or fail.


## [0.1.1] - 2025-05-13

### Added
- `Lua.put_private/3`, `Lua.get_private/2`, `Lua.get_private!/2`, and `Lua.delete_private/2` for working with private state

## [0.1.0] - 2025-05-12

### Fixed

- Errors now correctly propagate state updates
- Fixed version requirements issues, causing references to undefined `luerl_new`
- Allow Unicode characters to be used in Lua scripts
- Files with only comments can be loaded

### Changed

- Upgrade to Luerl 1.4.1
- Tables must now be explicitly decoded when receiving as arguments `deflua` and other Elixir callbacks

[1.0.0]: https://github.com/tv-labs/lua/compare/v0.4.0...v1.0.0
[1.0.0-rc.3]: https://github.com/tv-labs/lua/compare/v1.0.0-rc.2...v1.0.0-rc.3
[1.0.0-rc.2]: https://github.com/tv-labs/lua/compare/v1.0.0-rc.1...v1.0.0-rc.2
[1.0.0-rc.1]: https://github.com/tv-labs/lua/compare/v1.0.0-rc.0...v1.0.0-rc.1
[1.0.0-rc.0]: https://github.com/tv-labs/lua/compare/v0.4.0...v1.0.0-rc.0
[0.4.0]: https://github.com/tv-labs/lua/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/tv-labs/lua/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tv-labs/lua/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tv-labs/lua/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/tv-labs/lua/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tv-labs/lua/compare/v0.0.22...v0.1.0
