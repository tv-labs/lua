---
id: A26
title: Error message quality pass — make the rendered output world-class
issue: 263
pr: 304
branch: errors/quality-pass
base: main
status: merged
direction: A
unlocks:
  - "world-class error messages" promise of the library
---

## Goal

A18 + A19 wired the *data* into every exception (`:line`, `:source`,
`:call_stack`, `:value_type`, `:error_kind`). A19 (PR #215, status
`review`) does this by auto-populating `:line`/`:source`/`:call_stack`
inside each exception module's `exception/1` from
`Lua.VM.Executor.current_position/0`, so the four user-visible VM
exception types (`TypeError`, `RuntimeError`, `AssertionError`,
`ArgumentError`) all carry location data. This plan answers the
question: **is the rendered output actually world-class?**

Audit every error message a user can see. For each, evaluate:

- Is the message clear about what went wrong?
- Is the source location prominent and accurate?
- Is the suggestion (when present) actually useful, or template
  filler?
- Is the call stack readable?
- Does the message look right on a non-TTY (stripped of ANSI codes)?

Then fix the rough edges. The audit is grounded in concrete findings
captured under **Implementation notes → Confirmed audit findings**;
the implementation work is to close those gaps, lock the output with
fixture tests, and ship a docs gallery.

## Out of scope

- Changing the exception struct shape (A18 settled this).
- Adding new error *categories* (the existing `error_kind` set is
  fixed). Wiring up suggestions for kinds that already exist is in
  scope; inventing new kinds is not.
- Implementing `traceback()` or `debug.traceback` — we already render
  the stack we have.
- Source maps past `load()` chunks.
- Fixing the two pre-existing data oddities A19 logged in its
  Discoveries (`table.insert(t, nil, 5)` reports arg `#1` instead of
  `#2`; `setmetatable(5, {})` on line 1 reports `line 0`). These are
  data-layer bugs, not rendering bugs; if confirmed during the audit,
  log them and open follow-ups rather than expanding scope.

## Success criteria

- [ ] A gallery test pins the rendered output (as an inline `expected`
      string) for each error category:
      - [ ] arithmetic on non-number
      - [ ] indexing nil / non-table
      - [ ] calling nil / non-function
      - [ ] concat non-string/number
      - [ ] compare incompatible types
      - [ ] length on non-string/table
      - [ ] table key is nil/NaN
      - [ ] stdlib bad-arg (e.g. `string.upper(nil)`)
      - [ ] `assert(false, msg)` and `assert(false)`
      - [ ] `error("msg")` and `error({tbl})`
      - [ ] runtime stack overflow / infinite recursion
- [ ] Each message leads with `at <source>:<line>:` before the message
      body (currently it renders *after* the header line — fix the
      ordering in `format/3`). Note the public exception still prefixes
      `Lua runtime error: `, so the first rendered line is
      `Lua runtime error: at <source>:<line>:`.
- [ ] The redundant double label is gone: today the public exception
      prefixes `Lua runtime error: ` and the formatter header also says
      `Runtime Type Error`. Pick one consistent presentation.
- [ ] Suggestions (when present) are specific to the error category and
      reachable. The formatter's `build_suggestion/3` matches
      `:arithmetic_type_error`, but the executor emits
      `:arithmetic_on_non_number` — that clause is dead. Align the
      atoms, and add category-specific suggestions for the emitted
      kinds that currently get none (`:compare_incompatible_types`,
      `:length_not_integer`). The generic
      `"...Check your logic."` assertion suggestion is filler — replace
      or remove it.
- [ ] Color rendering: messages render readably with ANSI on a TTY and
      cleanly without ANSI when written to a file or non-TTY pipe.
      Today `format/3` emits `IO.ANSI.*` unconditionally, so escape
      codes leak into non-TTY output — gate ANSI behind a TTY/enabled
      check (e.g. `IO.ANSI.enabled?/0`) so the same render path is safe
      either way.
- [ ] A small "error gallery" pins before/after for each category. (Shipped
      as inline `expected` strings in `test/lua/error_gallery_test.exs`; the
      standalone `guides/errors.md` draft was dropped during review.)
- [ ] `mix test` passes (1585 → 1585+, no regressions).

## Implementation notes

### Confirmed audit findings (grounded, not speculative)

Rendering `local x = nil; print(x + 1)` via `Lua.eval!` today produces:

```
Lua runtime error: <ESC>[31m<ESC>[1mRuntime Type Error<ESC>[0m

  at <eval>:2:

  attempt to perform arithmetic on a nil value (local 'x')
```

This single example confirms four of the things to fix:

1. **Double label.** `Lua runtime error: ` (from
   `Lua.RuntimeException`, see `@runtime_prefix`) plus
   `Runtime Type Error` (from `ErrorFormatter.format_header/1`) — two
   redundant "runtime"/"error" labels stacked.
2. **Location not prominent.** `at <eval>:2:` renders on its own line
   but *after* the header, not before the message body. The success
   criterion wants it up top.
3. **Raw ANSI leak.** `format/3` calls `IO.ANSI.red()` etc.
   unconditionally; piping to a file embeds raw escapes. Gate on
   `IO.ANSI.enabled?/0`.
4. **Missing / dead suggestions.** Executor emits these `error_kind`s:
   `:call_nil`, `:call_non_function`, `:index_non_table`,
   `:concatenate_type_error`, `:arithmetic_on_non_number`,
   `:compare_incompatible_types`, `:length_not_integer`,
   `:bitwise_on_non_integer`, `:for_loop_non_number`. The formatter's
   `build_suggestion/3` only matches `:call_nil`,
   `:call_non_function`, `:index_non_table`, `:arithmetic_type_error`
   (a name that is never emitted — dead clause), and
   `:concatenate_type_error`. So arithmetic gets *no* suggestion (atom
   mismatch), and compare / length get none either.

### Audit / gallery step

The gallery test triggers each error category listed in Success
criteria via `Lua.eval!`, captures the rendered `Exception.message/1`
output, and compares it to an inline `expected` string in the test
itself. Output is captured with ANSI disabled (`IO.ANSI.enabled? ==
false` path) so the expectations are plain text and stable across
terminals. The test asserts the rendered output equals the inline
expectation; updating it is an explicit edit when output intentionally
changes.

Each table-driven case carries its source snippet and expected render
inline, e.g.:

```
arithmetic on non-number ->
  source: print(x + y)  # x = "5", y = nil
  expected: "at gallery.lua:3:\n\n  attempt to perform arithmetic ..."
```

### Files

- `lib/lua/vm/error_formatter.ex` — main render path
  (`format/3`, `to_map/3`). Reorder location-before-body, gate ANSI on
  `IO.ANSI.enabled?/0`, align `build_suggestion/3` atoms with the
  kinds the executor actually emits, add the missing category
  suggestions, replace the filler assertion suggestion.
- `lib/lua/runtime_exception.ex` — `Exception.message/1` and
  `@runtime_prefix`: resolve the double-label with the formatter
  header.
- `lib/lua/vm/type_error.ex` — `exception/1` builds the message via
  `ErrorFormatter.format/3`; adjust if the prefix/ordering change
  requires it.
- `lib/lua/vm/runtime_error.ex` — same.
- `lib/lua/vm/assertion_error.ex` — same; drop or specialize the
  generic suggestion.
- `lib/lua/vm/argument_error.ex` — `message/1` routes stdlib bad-arg
  errors through `ErrorFormatter.format(:type_error, ...)`; make sure
  the stdlib bad-arg case stays correct after formatter changes.
- `test/lua/error_gallery_test.exs` (new) — gallery tests with inline
  `expected` strings for every reachable category.
- A standalone `guides/errors.md` was drafted then dropped during review;
  the before/after gallery is carried by the test above instead.

Note: the plan's earlier draft pointed at `lib/lua/error_formatter.ex`
and a `Lua.VM.TypeError.message/1`. The real formatter lives at
`lib/lua/vm/error_formatter.ex`, and the VM exceptions build their
message string eagerly inside `exception/1` (storing it in `:message`)
rather than via an `Exception.message/1` callback —
`ArgumentError` is the one that uses a `message/1` callback. The file
list above reflects the actual code.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/error_gallery_test.exs
```

Manual: pipe to a file, confirm no raw ANSI escape codes leak.

```bash
elixir -e 'IO.puts(Lua.eval!(Lua.new(), ~S{print(nil + 1)}))' > /tmp/out 2>&1 || cat /tmp/out
```

(Expected: the rescued message text, with no `\e[` escape sequences in
`/tmp/out`.)

## Risks

- "World-class" is subjective. Resist the urge to bikeshed; the
  minimum bar is "every error has line/source up top, every error has
  a category-appropriate body, no filler suggestions, no ANSI leak off
  a TTY."
- Pinned-output tests are brittle if the format keeps changing. Lock
  the format here and treat changes as opt-in (update the inline
  `expected` strings deliberately, never auto-pass).
- ANSI gating must not change the `to_map/3` wire-safe path, which is
  already documented to contain no escapes — only `format/3` should be
  affected.
- If the audit surfaces structural data issues (a category that
  doesn't carry the line/source it should), open follow-up plans
  rather than expanding scope. The two A19-flagged data oddities are
  explicitly out of scope here.

## Discoveries

(populated during implementation)

Pre-implementation notes carried over from the audit:

- **A19 is `status: review`, not merged to `main`.** If the branch is
  cut from a `main` that predates A19's merge, the four exception
  modules will not auto-populate `:line`/`:source`/`:call_stack` and
  many fixtures will render without a location line. Before
  generating fixtures, confirm `Lua.VM.TypeError.exception([value:
  "x"])` returns a struct with `:line`/`:source` populated when called
  inside a Lua execution; if not, A19 has not landed and this plan
  should wait (it remains blocked in practice even though the data is
  designed to be present). Audit what *is* present and note any
  category still missing line info here. (Resolved below: A19 data is
  present, and the gallery pins output via inline `expected` strings
  rather than checked-in fixture files.)
- **Dead suggestion clause.** `build_suggestion(:type_error,
  :arithmetic_type_error, _)` is never reached — the executor emits
  `:arithmetic_on_non_number`. Confirmed by grep of `lib/`.
- **Categories with no emitted suggestion today:**
  `:compare_incompatible_types`, `:length_not_integer`,
  `:bitwise_on_non_integer`, `:for_loop_non_number`. The first two are
  in the Success-criteria gallery list and get suggestions here; the
  latter two are noted for completeness.
- **Table-index-nil/NaN raise sites:** `lib/lua/vm/table.ex` documents
  the contract (§3.4.11) but the actual raise happens in the executor
  set path. Confirm the rendered message and whether it carries an
  `error_kind` before writing that case; if it has no kind, the
  case pins the body only (no suggestion) — do not invent a kind.

### Confirmed during implementation

- **A19 data IS present on this base.** `Lua.VM.Executor.current_position/0`
  exists, all nine `error_kind`s are emitted, and the four VM exceptions
  auto-populate `:line`/`:source`. Every type/argument/runtime/assertion
  error reachable from `Lua.eval!` carries a location, so the gallery
  cases render `at gallery.lua:<line>:` up top — except the
  stack-overflow case and the numeric `for`-loop control coercion case
  (see below).

- **Out-of-scope data-layer gaps (logged, not fixed):**
  - `#5` (length operator on a number) and `#true` return `0` rather than
    raising. The `:length_not_integer` kind is wired into the formatter as
    a suggestion, but the executor never raises it for these inputs, so
    "length on non-string/table" has no rendered message to pin. Data-layer
    bug; out of scope.
  - `t[nil] = 1` and `t[0/0] = 1` (nil / NaN table key) succeed silently
    instead of raising "table index is nil/NaN". No rendered message to
    pin. Data-layer bug; out of scope. These two categories are therefore
    documented here under "Known gaps" (and in the PR description) rather than
    pinned in the gallery.
  - Stack-overflow runtime errors carry no originating line, so they render
    without an `at <source>:<line>:` header and the stack frames show line
    `0`. The renderer is correct given the data; the missing line is a
    data-layer gap.
  - Numeric `for`-loop control coercion errors (`for_loop_non_number`) also
    render without an `at <source>:<line>:` header: the `raise` in
    `coerce_for_value/2` receives no position from `current_position/0`, so
    the location is `nil`. Identical on `main`, not a regression; the
    gallery honestly pins the location-less output. Data-layer gap.

- **`error()` with a non-string object** previously leaked an internal
  Elixir term (`runtime error: {:tref, 12}`). `Lua.VM.RuntimeError.stringify/1`
  now renders PUC-Lua's `(error object is a TYPE value)` for any non-string,
  non-number value, while strings and numbers still render verbatim. This is
  a rendering fix on a file already in scope.

- **`assert(false)` still double-texts** as `assertion failed: assertion
  failed!` because `AssertionError.raw_message/1` prefixes
  `"assertion failed: "` and the stdlib passes the literal default value
  `"assertion failed!"`. Removing the prefix is a behavioral change that
  ripples into `test/lua53_tests/errors.lua` and
  `test/lua/compiler/integration_test.exs`; the plan scoped the assertion
  change to its *suggestion* (now removed), not the message prefix. Left as
  a follow-up.

- **Tests updated as a direct consequence of the formatter change** (the
  golden snapshots tested the old header + unconditional ANSI):
  `test/lua/vm/error_to_map_test.exs` and `test/lua/error_messages_test.exs`.
  These are not in the plan's file list but directly assert the formatter's
  output; updating them is a necessary consequence of the in-scope change,
  not a scope expansion.

## What changed

Shipped in PR #304.

Files touched:

- `lib/lua/vm/error_formatter.ex` — `format/3` now leads with the location
  line, drops the standalone header (resolving the double label), gates all
  ANSI behind a `color/2` helper keyed on `IO.ANSI.enabled?/0`, realigns the
  dead `:arithmetic_type_error` suggestion to the emitted
  `:arithmetic_on_non_number`, adds suggestions for
  `:compare_incompatible_types`, `:length_not_integer`,
  `:bitwise_on_non_integer`, `:for_loop_non_number`, and removes the filler
  assertion suggestion.
- `lib/lua/vm/runtime_error.ex` — non-string/number `error()` objects render
  PUC-Lua's `(error object is a TYPE value)` instead of an internal term.
- `test/lua/error_gallery_test.exs` (new) — pins the rendered output for
  every reachable category with an inline `expected` string per case (no
  separate fixture files); update those strings deliberately when the format
  changes on purpose.
- The standalone `guides/errors.md` gallery was dropped during review: the
  before/after renders are pinned by `test/lua/error_gallery_test.exs` and the
  "Known gaps" data-layer holes are captured in this plan's Discoveries and the
  PR description instead of a separate guide.
- `test/lua/vm/error_to_map_test.exs`, `test/lua/error_messages_test.exs` —
  golden snapshots updated to the new format.

Tests: `mix test` 2104 passed / 0 failed; `mix test --only lua53` 17 passed.

Follow-ups to open (out of scope here): length operator / nil-NaN table key
not raising, stack-overflow errors carrying no line, and the
`assert(false)` double-text prefix.
