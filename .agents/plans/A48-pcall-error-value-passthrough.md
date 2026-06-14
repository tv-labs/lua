---
id: A48
title: pcall/xpcall pass the raw Lua error value through; error() adds the §6.1 position prefix
issue: 334
pr: 335
branch: fix/pcall-error-value-passthrough
base: main
status: merged
direction: A
unlocks:
  - structured error objects (error({code = ...})) survive pcall
  - §6.1 position prefix on string errors
---

# A48 — pcall/xpcall pass the raw Lua error value through; error() adds the §6.1 position prefix

## Goal

Fix two distinct defects in `lib/lua/vm/stdlib.ex` so `pcall`/`xpcall`
behave per Lua 5.3 §6.1, **without disturbing host-facing error
rendering** (the `Lua.VM.RuntimeError.message` / `to_map` path and the
`ErrorFormatter` `at source:line:` header must stay byte-identical).

1. **Pass-through.** `error(value)` raises any Lua value verbatim, and
   `pcall` must return that value AS-IS as its second result (and
   `xpcall` must hand it to the message handler untouched). Today
   `extract_error_message/1` (`stdlib.ex:255-257`) runs
   `Value.to_string/1` on every non-binary non-nil value, so
   `error({code = 1})` comes back as `"table: 0x..."`, `error(42)` as
   `"42"`. The fix returns the raw `:value`.

2. **§6.1 position prefix.** `error(message [, level])` prepends
   `source:line: ` to `message` ONLY when `message` is a string and
   `level != 0` (default `level == 1`). `lua_error` currently matches
   `[message | _]`, discards `level`, and stores the value with no
   prefix. So `error("boom")` returns `"boom"` where reference Lua
   returns `"file:1: boom"`.

The reference target (verified against PUC-Lua 5.3 on this machine):

```
error({code=1})  -> pcall: false, type "table",  err.code == 1
error(42)        -> pcall: false, type "number",  err == 42
error("boom")    -> pcall: false, type "string",  err == "src:1: boom"
error("hi", 0)   -> pcall: false, type "string",  err == "hi"  (level 0 suppresses)
error() / error(nil) -> pcall: false, err == nil
```

Returning a `tref` across pcall's rescue is safe post-PR #333:
`State.unwind_to(state, e.state)` (already at `stdlib.ex:215/235`)
restores the raise-time heap so the referenced table survives.

## Out of scope

- **`error()` level >= 2** (attribute the prefix to the caller's
  caller). Needs per-frame line numbers the call stack does not carry
  (frames are `line: 0` under the dispatcher). Implement level `0` and
  `1` only; the issue's repro and `errors.lua` only exercise those.
  Level `>= 2` is a documented follow-up.
- **Position prefix on INTERNAL raises** (`TypeError`,
  `ArgumentError`, divide-by-zero, stdlib bad-argument). Reference Lua
  prefixes these too, but they already render location via the host
  `ErrorFormatter`, and many tests pin their exact strings. This issue
  is explicitly about `error()`-raised string values only. The new
  prefix MUST NOT touch them.
- **Correct compiled-closure prefix LINE under the dispatcher.** The
  dispatcher strips `:source_line` at encode time (`dispatcher.ex:80-81`)
  and `Executor.dispatcher_call_function/5`'s `:native_func` clause
  (`executor.ex:491-492`) sets no per-call position, so `error()` inside
  a compiled closure reads a stale outer position. Recovering a per-call
  line requires encoder/opcode changes larger than this PR. We ship with
  the prefix **suppressed** (`{nil, source}` -> no prefix) rather than
  emit a wrong line, and file the dispatcher line-plumbing bridge as a
  follow-up (blocker: `dispatcher.ex:80-81` source_line strip; the
  suppression edit lands at `executor.ex:491`). The `:interpreted`
  engine and the top-level-on-executor path attribute correctly.
- **Unskipping `test/lua53_tests/errors.lua`.** Blocked on an unrelated
  `load()` parse-error-prefix mismatch (`lua53_skips.exs:121-129`). Its
  level-0 case (`errors.lua:45`) and `error()`/nil case (`errors.lua:48`)
  are reproduced in the new dedicated unit test instead.
- **Changing host-facing rendering.** `RuntimeError.stringify/1`
  (`runtime_error.ex:77-82`, `(error object is a TYPE value)`) and the
  `at source:line:` header stay exactly as-is.

## Success criteria

- [ ] New file `test/lua/vm/pcall_error_value_test.exs`, modeled on
      `pcall_state_preservation_test.exs` (dual-engine matrix over
      `[:compiled, :interpreted]` via `strip_bytecode/1`), green under
      BOTH engines. Cases:
  - `pcall(fn() error({code=1}) end)` -> `[false]`,
    `type(err) == "table"`, `err.code == 1` (reads the field — proves
    the tref survives PR #333 preservation).
  - `error(42)` -> `type(err) == "number"`, `err == 42`.
  - `error(true)` -> boolean passthrough.
  - `error(false)` -> `type(err) == "boolean"`, `err == false`.
    Together with the `error()`/`error(nil)` nil case below, this pins
    the KEY-PRESENCE (not `not is_nil`) behavior of the
    `%{value: value}` clause: a `true` passthrough does not exercise the
    falsy-but-present path the clause exists to protect — only `false`
    and `nil` do.
  - `error("boom")` on a known-good line -> `err =~ ~r/:\d+: boom$/`
    (asserts §6.1 prefix SHAPE, not an exact line, to avoid coupling to
    the pre-existing A18/A19 source_line off-by-one). Add an
    `:interpreted`-engine assertion that the prefix begins with the
    SOURCE name, not the digit: `err =~ ~r/^\w[^:]*:\d+: boom$/`, so a
    swapped `{source, line}` destructure (emitting `line:source:`) fails
    rather than slipping past the looser shape regex.
  - `error("hi", 0)` -> `err == "hi"` (level 0 suppresses prefix;
    mirrors `errors.lua:45`).
  - `error()` / `error(nil)` -> `err == nil` (mirrors `errors.lua:48`).
  - `xpcall(fn() error({code=2}) end, fn(e) return e end)` -> handler
    receives the raw table, returned `err.code == 2`.
  - `xpcall(fn() error({code=2}) end, fn(_) error("handler boom") end)`
    -> the handler itself raises; per `run_xpcall_handler`'s rescue
    (`stdlib.ex:251`) the returned error is the ORIGINAL raw value
    (`type(err) == "table"`, `err.code == 2`), NOT a stringification.
    Covers the handler-failure path left untouched by Step 4.
  - **Regression guard:** a genuine `TypeError` under pcall (e.g. a
    `nil` call) stays `is_binary(err)` and is NOT prefixed — protects
    `pcall_test.exs:84-86` and the arithmetic type-error assertions.
- [ ] `mix test` passes; host-message canaries unchanged:
      `error_gallery_test.exs:104-115`, `integration_test.exs:1382`,
      `lua_test.exs:940`, `runtime_exception_test.exs:34-35`.
- [ ] `mix test --only lua53` no regression.
- [ ] `mix format`, `mix compile --warnings-as-errors`, `mix credo` clean.

## Implementation notes

All of `error`/`pcall`/`xpcall` are registered once
(`stdlib.ex:29/31/32`) and not duplicated in `dispatcher.ex` /
`executor.ex`, so the value-passthrough and prefix logic is
single-source. The only two-engine work is the (deferred, suppressed)
dispatcher line bridge — see Out of scope.

### Step 1 — RED tests first

Write `test/lua/vm/pcall_error_value_test.exs` with every case above
over the `[:compiled, :interpreted]` matrix. Assert decoded values
(`err.code == 1`, `err == 42`, prefix shape) — never `=~` substrings
that a stringified or mis-prefixed value would pass. Run; confirm the
non-string cases fail with stringified values.

### Step 2 — host-preserving field on RuntimeError

Add a `:lua_value` field to `RuntimeError`'s `defexception` list
(`runtime_error.ex:26`). Default `nil`. Document its contract ON the
struct: **Lua-facing only** — it carries the §6.1-prefixed string that
`pcall`/`xpcall` hand back to Lua, and is NEVER read by `message`,
`to_map`, `format_message`, `raw_message`, or `stringify`. Those keep
reading `:value` only, so the host path is provably untouched (this is
what prevents the doubled-location bug: `at gallery.lua:1: ... runtime
error: gallery.lua:1: boom`). Add it to the `@derive {Inspect, except:}`
list if appropriate.

### Step 3 — §6.1 prefix in lua_error

Change the head to capture the level argument:

- `lua_error([message | rest], state)` — extract `level` (default `1`)
  from `rest`. Normalize floats: treat `0` and `0.0` as suppression;
  integer-coerce per `luaL_checkinteger` semantics.
- Keep the no-arg clause `lua_error([], state)`.

Add a private prefixer. NOTE the tuple order: `Executor.current_position/0`
returns `{line, source}` — **line first** (`executor.ex:55-56`), and the
suppressed dispatcher position is therefore written `{nil, source}`. For
a **binary** `message` AND `level != 0` AND a non-nil `source` and
`line`, build `prefixed = "#{source}:#{line}: #{message}"` — **source
first** in the string, matching reference Lua (`src:1: boom`, never
`1:src: boom`). Otherwise `prefixed = message` (non-strings and level 0
pass through unchanged; when position is `{nil, _}` the prefix is
omitted — the deferred dispatcher case). Destructure as
`{line, source} = Executor.current_position()`; do not swap the binding
order.

Raise `RuntimeError` with `value: message` (RAW, for host),
`lua_value: prefixed`, plus `line:`, `source:`, `state:`. The no-arg
clause keeps `value: nil, lua_value: nil`.

### Step 4 — replace extract_error_message with error_value

Replace `extract_error_message/1` (`stdlib.ex:255-257`) with
`error_value/1`. Use the minimal two-clause shape (matching on KEY
PRESENCE, not `not is_nil`, so `nil`/`false`-carrying structs still
match and pass through):

```elixir
defp error_value(%{lua_value: lv}) when not is_nil(lv), do: lv
defp error_value(%{value: value}), do: value
defp error_value(e), do: Exception.message(e)
```

- Clause 1: the §6.1 view from `lua_error` (already a Lua value).
- Clause 2: raw passthrough. A bare `%{value: value}` match catches
  `RuntimeError` (incl. `value: nil`/`false`), `AssertionError`
  (`assertion_error.ex:19`), and `TypeError` (`type_error.ex:24`).
  `value: nil` MUST match here so `pcall(error())` returns `nil` like
  PUC-Lua, rather than falling to `Exception.message`.
- Clause 3: fallback for `ArgumentError` (NO `:value` field —
  `argument_error.ex:53-63`) and plain Elixir exceptions; keeps a Lua
  string. Clause ordering is load-bearing.

Wire `error_value/1` into ONLY the two sites where a live exception
`e` is in scope: `lua_pcall`'s rescue (`stdlib.ex:214`) and
`lua_xpcall`'s rescue (`stdlib.ex:235`). Leave `run_xpcall_handler`
(`stdlib.ex:246-252`) untouched — its `error_msg` parameter is the
ALREADY-EXTRACTED value passed in by `lua_xpcall` at `stdlib.ex:235`,
not a live exception. Its rescue at `stdlib.ex:251` returns that
already-extracted value verbatim when the handler itself fails; calling
`error_value/1` there would wrongly re-process it (e.g. a raw scalar
`42` would fall to clause 3 `Exception.message(42)`, which raises
because `42` is not an exception). Pass `error_msg` through unchanged.
After grep-confirming `extract_error_message` has no other callers,
delete it.

### Step 5 — dispatcher parity (suppress, do not mis-attribute)

For `error()` inside a COMPILED closure routed through the dispatcher,
`Executor.current_position()` returns a STALE line (the outer pcall call
site, set at `executor.ex:1080-1081`), NOT nil. Verified empirically:
there is no dispatcher "native-call boundary" that sets position — the
dispatcher `:call` opcode for a native function (`dispatcher.ex:1085`,
the `_ ->` branch) calls `Executor.dispatcher_call_function/5`, whose
`:native_func` clause (`executor.ex:491-492`) delegates straight to the
shared `call_function/3` (`executor.ex:183-193`), which sets NO position.
So suppression requires ACTIVELY setting `{nil, proto.source}`.

Per the scope cut, the correct fix (a dispatcher native-call line bridge
mirroring `executor.ex:1080/1099`) is deferred. For THIS PR, implement
suppression by wrapping the `:native_func` clause of
`Executor.dispatcher_call_function/5` (`executor.ex:491`) with
`set_position(nil, proto.source)` + restore (mirroring the
save/set/restore at `executor.ex:1080/1099`). That function is called
ONLY from the dispatcher (`dispatcher.ex:627/688/1085`), so it is
dispatcher-local and will NOT affect the interpreted engine. With a nil
line on that path the §6.1 prefixer in `lua_error` omits the prefix
rather than emitting a wrong line.

**Caveat — blanket suppression at `executor.ex:491` clears position for
ALL native calls under the dispatcher,** not just `error()`: `assert()`
and stdlib bad-argument checks raised inside compiled closures
(`AssertionError`/`ArgumentError`/`TypeError`) read `current_position`
for their host line/source. Today they read a (wrong) stale line under
the dispatcher; this change would shift them to no line. Before adopting
the blanket edit, run the nested-closure assert / bad-argument canaries
under `:compiled` (see Verification) to confirm no host line-attribution
regression. If a regression appears, fall back to scoping suppression to
the `error()` path — e.g. have `lua_error` itself omit the prefix when
the live position line is unreliable — rather than mutating the shared
dispatcher native clause.

The `:interpreted` engine and the top-level chunk (always on the
executor, `vm.ex:26`) attribute correctly. Verify with a multi-line case
(pcall on line 1, `error("boom")` on line 3): prefix line correct under
`:interpreted`; prefix shape (not a wrong line) under `:compiled`. File
the bridge follow-up.

### Step 6 — run RED suite green, then full suite

Confirm the new file is green under both engines, then run the full
suite to surface migration churn.

## Migration (deliberate test changes)

From the test-landscape research — change only assertions whose
semantics legitimately changed; verify the canaries stay green
unchanged.

- `test/lua/vm/pcall_state_preservation_test.exs:66-67` — `assert err
  =~ "boom"` (at :67) still passes through the new prefix; tighten to
  assert the prefix shape.
- `test/lua/vm/pcall_state_preservation_test.exs:286-301` — the
  "mutation before error() with a table error object is kept" test. Its
  `return x, ok, err ~= nil` (:295) currently asserts `[2, false, true]`
  (:300). Tighten to read `err.code == 1` now that a real table is
  returned (regression guard for PR #333 across the returned table).
  **Do NOT touch** the `gsub callback heap mutation` test at
  `:190-207` — it legitimately asserts `[2, false]` from an
  invalid-return error and has no table error object / no `err.code`.

Verify GREEN unchanged (assert `RuntimeError.message`, which we did not
touch):

- `test/lua/error_gallery_test.exs:104-115` (table/number host messages,
  not prefixed) AND `:98-102` (the `error_string` case — confirm no
  doubled location).
- `test/lua/compiler/integration_test.exs:1382`, `test/lua_test.exs:940`,
  `test/lua/runtime_exception_test.exs:34-35`.

Verify `=~` substring tests survive an added prefix:
`test/lua/vm/string_test.exs:999-1038`, `test/lua/vm/limits_test.exs:16-87`,
`test/lua/vm/arithmetic_test.exs:236/253/270`, `test/language/load_test.exs`,
`test/language/math_test.exs:56`, `test/lua/vm/pcall_test.exs:84-86`.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/pcall_error_value_test.exs
mix test
mix test --only lua53
mix credo
```

**Nested-closure host line-attribution canary (guards the
`executor.ex:491` suppression).** Because suppression clears position for
ALL native calls under the dispatcher, add `:compiled`-engine cases that
raise `assert()` and a stdlib bad-argument error from inside a nested
compiled closure, and confirm their host-facing
`RuntimeError`/`AssertionError`/`ArgumentError` messages (line/source
attribution) do not regress versus the current build. If they regress,
fall back to the `error()`-scoped suppression described in Step 5.

Add a CHANGELOG `### Fixed` entry under `## Unreleased` describing the
passthrough + §6.1 prefix fix (#334), noting that pcall's second result
may now be a non-string Lua value.

## Risks

- **Dispatcher parity / stale line.** The dispatcher returns a STALE
  position (not nil) for nested compiled closures — verified: `error()`
  inside a compiled closure reads the outer pcall call-site `{1, source}`
  set at `executor.ex:1080-1081`, never nil — so a naive prefix emits a
  WRONG line under the default engine, a silent cross-engine divergence.
  Mitigation: suppress the prefix by setting `{nil, proto.source}` at the
  `:native_func` clause of `Executor.dispatcher_call_function/5`
  (`executor.ex:491`, the only dispatcher-local suppression point) and
  defer the line bridge; the multi-line matrix test enforces "correct
  line on `:interpreted`, no wrong line on `:compiled`".
- **Blanket suppression clears position for ALL dispatcher native
  calls.** The `executor.ex:491` edit suppresses position for every
  native call under the dispatcher, not just `error()` — including
  `assert()` and stdlib bad-argument checks raised inside compiled
  closures, whose `AssertionError`/`ArgumentError`/`TypeError` read
  `current_position` for host line/source. Today they read a (wrong)
  stale line; the change shifts them to no line. Mitigation: the
  nested-closure host-message canary (see Verification) gates the edit;
  if it regresses, scope suppression to the `error()` path inside
  `lua_error` instead of mutating the shared dispatcher native clause.
- **`ArgumentError` has no `:value`** (`argument_error.ex:53-63`).
  `error_value/1`'s fallback MUST keep using `Exception.message(e)` for
  it and plain Elixir exceptions, or pcall returns `nil` for stdlib
  bad-argument errors. Clause ordering
  (`lua_value` -> `value` -> `Exception.message`) is exact.
- **`value: nil`/`false` must match the `%{value: value}` clause** on
  KEY PRESENCE, not `not is_nil`, so `pcall(error())` returns `nil` and
  `error(false)` returns `false`. Do not reintroduce an `is_nil` guard.
- **Callers assuming pcall's 2nd result is a binary.** Returning a
  table/number/nil/boolean is the intended fix but could surprise
  Elixir-side consumers; `tref` decodes to a map (`value.ex:272`),
  scalars pass through. Audit downstream code that did String ops on
  pcall's error.
- **`:lua_value` contract leakage.** If any future host-rendering code
  reads `:lua_value`, the doubled-location bug returns. The struct
  doc must state the field is Lua-facing only.
- **Pre-existing A18/A19 source_line off-by-one** (setmetatable-on-line-1
  reports line 0) could make an otherwise-correct prefix line wrong; the
  new test asserts prefix SHAPE on a known-good line, not an exact line.
- **Internal raises must NOT be prefixed.** `TypeError`/`ArgumentError`
  flow through different structs than `lua_error`; the dedicated
  regression case guards `pcall_test.exs:84-86` and the arithmetic
  type-error assertions against an over-broad prefix.

## Which structs carry :value (clause-ordering reference)

- `RuntimeError` — `runtime_error.ex:26` (gains `:lua_value` here).
- `AssertionError` — `assertion_error.ex:19`.
- `TypeError` — `type_error.ex:24`.
- `ArgumentError` — NO `:value` (`argument_error.ex:53-63`); hits the
  `Exception.message/1` fallback.

## Discoveries

- `mix credo` is listed in Verification but credo is not a dependency of
  this repo; skipped. `mix compile --warnings-as-errors` + `mix format`
  + full suite stand in.
- The `executor.ex` `dispatcher_call_function/5` `:native_func`
  suppression changes nested-compiled-closure host messages from NO
  location header (`{nil, nil}` position) to a source-only header
  (`at <eval>:`). Before/after canary confirmed: strictly added
  information, no wrong-line attribution, no existing test pinned the
  old bytes (`ErrorFormatter.format_location(source, nil)` is an
  explicit supported clause). The plan's fallback (error()-scoped
  suppression) was not needed.
- The dispatcher line-bridge follow-up issue could not be filed from
  the shipping session (permission); its full text is drafted in PR
  #335's Discoveries section pending a human-approved `gh issue create`.

## What changed

- `lib/lua/vm/stdlib.ex` — `lua_error` gains level handling + §6.1
  prefixer into `:lua_value`; `extract_error_message/1` replaced by
  `error_value/1` (lua_value -> raw value by key presence ->
  `Exception.message`), wired into the two live-exception rescues only.
- `lib/lua/vm/runtime_error.ex` — new Lua-facing-only `:lua_value`
  field; host rendering paths untouched.
- `lib/lua/vm/executor.ex` — `dispatcher_call_function/5` `:native_func`
  clause publishes `{nil, proto.source}` (save/restore) so dispatcher
  raises omit the line instead of reading a stale one.
- `test/lua/vm/pcall_error_value_test.exs` — new 26-case dual-engine
  matrix (red-first).
- `test/lua/vm/pcall_state_preservation_test.exs` — tightened the
  string-error assertion to prefix shape and the table-error-object test
  to read `err.code == 1`; the gsub callback test untouched.
- `CHANGELOG.md` — Unreleased/Fixed entry for #334.
- Suite: 2234 passed / 0 failures; lua53 17 passed / 12 skipped
  (identical to main baseline).
