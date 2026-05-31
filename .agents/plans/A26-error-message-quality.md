---
id: A26
title: Error message quality pass — make the rendered output world-class
issue: 263
pr: null
branch: errors/quality-pass
base: main
status: in-progress
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

- [ ] A fixture file exists showing the rendered output for each error
      category:
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
- [ ] Each message prominently shows `at <source>:<line>:` on its own
      line, before the message body (currently it renders *after* the
      header line — fix the ordering in `format/3`).
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
- [ ] A small "error gallery" lives in `guides/errors.md` showing
      before/after for each category.
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

### Audit / fixture step

Write a fixture script (in the test) that triggers each error category
listed in Success criteria via `Lua.eval!`, captures the rendered
`Exception.message/1` output, and compares it to a checked-in
`test/fixtures/error_gallery/<category>.txt`. Generate fixtures with
ANSI disabled (`IO.ANSI.enabled? == false` path) so the committed
files are plain text and stable across terminals. The test asserts the
rendered output equals the fixture; regenerating is an explicit opt-in
when output intentionally changes.

Suggested gallery file format:

```
=== category: arithmetic on non-number ===
=== source ===
local x = "5"
local y = nil
print(x + y)
=== expected output ===
** (Lua.RuntimeException) ...
  at gallery.lua:3:
  attempt to perform arithmetic on a nil value
  ...
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
  the stdlib bad-arg fixture stays correct after formatter changes.
- `test/lua/error_gallery_test.exs` (new) — fixture comparison tests.
- `test/fixtures/error_gallery/*.txt` (new) — expected outputs.
- `guides/errors.md` (new) — before/after gallery.

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
- Fixture-based tests are brittle if the format keeps changing. Lock
  the format here and treat changes as opt-in (regenerate fixtures
  deliberately, never auto-pass).
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
  category still missing line info here.
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
  `error_kind` before writing that fixture; if it has no kind, the
  fixture pins the body only (no suggestion) — do not invent a kind.
