---
id: A26
title: Error message quality pass — make the rendered output world-class
issue: null
pr: null
branch: errors/quality-pass
base: main
status: blocked
direction: A
unlocks:
  - "world-class error messages" promise of the library
---

## Blocked on

- A19 — every raise site needs to carry line/source first; otherwise
  this pass has nothing to render in many cases.

## Goal

A18 + A19 wired the *data* into every exception (`:line`, `:source`,
`:call_stack`, `:value_type`, `:error_kind`). This plan answers the
question: **is the rendered output actually world-class?**

Audit every error message a user can see. For each, evaluate:

- Is the message clear about what went wrong?
- Is the source location prominent and accurate?
- Is the suggestion (when present) actually useful, or template
  filler?
- Is the call stack readable?
- Does the message look right on a non-TTY (stripped of ANSI codes)?

Then fix the rough edges.

## Out of scope

- Changing the exception struct shape (A18 settled this).
- Adding new error categories.
- Implementing `traceback()` or `debug.traceback` — we already render
  the stack we have.
- Source maps past `load()` chunks.

## Success criteria

- [ ] A doc test or fixture file exists showing the rendered output
      for each error category:
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
      line, before the message body.
- [ ] Suggestions (when present) are specific to the error category.
      Generic "check your logic" filler is replaced or removed.
- [ ] Color rendering: messages render readably with ANSI on TTY and
      cleanly without ANSI on `IO.puts/2` to a file or non-TTY pipe.
- [ ] A small "error gallery" lives in the docs (probably
      `guides/errors.md` or as part of the README) showing
      before/after for each category.
- [ ] `mix test` passes.

## Implementation notes

### Audit step

Run a fixture script that triggers each error category, capture
stdout, and write the rendered output to
`test/fixtures/error_gallery/<category>.txt`. These become regression
tests: any change to the formatter that alters output requires
updating the fixture.

Suggested gallery file format:

```
=== category: arithmetic on non-number ===
=== source ===
local x = "5"
local y = nil
print(x + y)
=== expected output ===
** (Lua.RuntimeException) Lua runtime error: Runtime Type Error
  at gallery.lua:3:
  attempt to perform arithmetic on a nil value
  ...
```

### Likely improvements to make

- The current TypeError prefix "Lua runtime error: " followed by
  "Runtime Type Error" is redundant. Pick one.
- Suggestion text appears even when not useful. Consider making it
  category-specific or omitting it entirely when generic.
- Stack traces from native functions and Lua functions interleave;
  make sure the formatting distinguishes them clearly.
- Multi-line values in error messages (e.g. when a printed table is
  shown) should be indented consistently.

### Files

- `lib/lua/error_formatter.ex` — main render path.
- `lib/lua/runtime_exception.ex` — `Exception.message/1`.
- `lib/lua/vm/type_error.ex` — `Exception.message/1`.
- `lib/lua/vm/runtime_error.ex` — `Exception.message/1`.
- `lib/lua/vm/assertion_error.ex` — `Exception.message/1`.
- `test/lua/error_gallery_test.exs` (new) — fixture comparison tests.
- `test/fixtures/error_gallery/*.txt` (new) — expected outputs.
- `guides/errors.md` (new) or `README.md` section.

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

## Risks

- "World-class" is subjective. Resist the urge to bikeshed; the
  minimum bar is "every error has line/source up top, every error has
  a category-appropriate body, no filler suggestions."
- Fixture-based tests are brittle if the format keeps changing. Lock
  the format here and treat changes as opt-in.
- If the audit surfaces structural issues (e.g. a category that
  doesn't carry the data it should), open follow-up plans rather than
  expanding scope.

## Discoveries

(populated during implementation)
