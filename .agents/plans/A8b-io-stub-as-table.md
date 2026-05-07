---
id: A8b
title: "io stdlib should be a table of sandboxed functions, not a single function"
issue: null
pr: null
branch: fix/io-stub-as-table
base: main
status: ready
direction: A
unlocks:
  - events.lua advances past line 188 (`assert(not pcall(rawlen, io.stdin))`)
---

## Goal

Make the global `io` a *table* whose keys are sandboxed function stubs
(`stdin`, `stdout`, `stderr`, `read`, `write`, `open`, `close`,
`lines`, `popen`, `tmpfile`, `output`, `input`, `flush`, `type`),
matching the shape of the `os` and `package` stubs. Today `io` is a
single sandboxed function value, so any access like `io.stdin` raises
`attempt to index a function value` instead of returning a sandboxed
function (or sandbox-blocking sentinel).

## Out of scope

- Implementing real I/O. Every entry stays a sandboxed stub.
- Other stdlib gaps in events.lua post-line-188 — this plan only
  unblocks the `io.stdin` line. If events.lua fails further down,
  document the next stop and split into A8e (or whatever the next
  free id is).
- Promoting `events.lua` to `@ready_tests`. Promotion follows once
  the file passes end-to-end.

## Success criteria

- [ ] `type(io)` returns `"table"` (currently `"function"`).
- [ ] `io.stdin`, `io.stdout`, `io.stderr` are values that don't raise
      on access. They can be sandboxed stubs that error on call (the
      pattern `os.getenv` already uses) or table-like stubs — whichever
      matches the existing sandbox convention more closely.
- [ ] `io.write("x")` raises with a message of the form
      `io.write(_) is sandboxed`, mirroring `os.execute()`.
- [ ] `io.read`, `io.open`, `io.close`, `io.lines`, `io.popen`,
      `io.tmpfile`, `io.output`, `io.input`, `io.flush`, `io.type`
      all behave the same (raise sandbox error on call).
- [ ] events.lua advances past line 188 standalone. (Will likely stop
      somewhere new; document that.)
- [ ] `pcall(rawlen, io.stdin)` returns `false, <error>` rather than
      raising synchronously. (Specifically: events.lua line 188 wraps
      the `rawlen(io.stdin)` call in `pcall`, so reaching the
      sandbox-error path needs to be raisable but catchable.)
- [ ] Unit tests pinning the new shape (a small `test/lua/io_stub_test.exs`
      or addition to `test/lua/stdlib_test.exs`).
- [ ] `mix test` passes; no regressions.

## Implementation notes

The other sandboxed modules (`os`, `package`) are tables of
`{:native_func, &…/2}` entries. Find where `io` is currently bound and
replace its single-function form with the same table-of-stubs shape.

Each stub raises a `Lua.VM.RuntimeError` with `value: "io.<name>(_) is
sandboxed"`. For `io.stdin`/`io.stdout`/`io.stderr` (which are
*values* in real Lua, not functions), pick the convention that matches
how `package.path` etc. are stubbed. Most likely a function that
errors on call is fine — events.lua's `pcall(rawlen, io.stdin)` only
needs a value that doesn't raise on lookup, and `rawlen` on a function
will raise (which is what the test wants — `pcall` catches it).

Repro confirmed on main on 2026-05-07:

```elixir
{:ok, _} = Lua.eval!(Lua.new(), "print(type(io))")
# prints "function" — should be "table"
```

```lua
print(type(io))                    -- "function"
local ok, err = pcall(rawlen, io.stdin)
                                   -- never reaches the pcall — raises
                                   -- "attempt to index a function value"
```

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

Plus: re-run events.lua standalone via the probe pattern (or just run
the existing skipped suite test by removing `@tag :skip` locally) and
confirm it advances past line 188. Document the next stop.

## Risks

- Real Lua programs use `io` heavily as a real I/O library. Anyone
  bringing existing Lua scripts in expects `io.read`/`io.write` to
  work. Sandbox stubs are the right call for a sandboxed VM, but the
  error message should be findable and clearly attributed (so users
  don't think it's a parser/VM bug). Match the existing
  `os.execute() is sandboxed` wording.
- If existing user code in this codebase or downstream relies on
  `type(io) == "function"` (unlikely but possible) it will break. Grep
  for such checks before changing.

## Background

Discovered while bisecting events.lua for A8a's Discoveries follow-up
"events.lua's downstream function-indexing failure". A8a recorded the
*symptom* (`attempt to index a function value`) but didn't identify
the cause. The actual cause is that `io` is bound as a single sandbox
function instead of as a table of sandboxed stubs — so `io.stdin`
indexes a function value rather than looking up a key in a table.

This re-scopes A8a's first follow-up: the events.lua failure isn't an
`__index` dispatch bug, it's a stdlib stub-shape bug.
