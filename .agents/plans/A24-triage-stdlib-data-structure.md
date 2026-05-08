---
id: A24
title: Triage cluster — stdlib & data-structure Assertion Failed files
issue: null
pr: null
branch: triage/stdlib-data-structure
base: main
status: blocked
direction: A
unlocks:
  - db.lua
  - literals.lua
  - constructs.lua
  - sort.lua
  - big.lua
  - strings.lua
  - calls.lua
  - locals.lua
---

## Blocked on

- A19 — stdlib raises need line/source for actionable triage.

## Goal

Diagnose eight suite files that fail with `Assertion Failed` and that
exercise the stdlib (string library, table library, debug library) or
core data-structure semantics (literals, table constructors, locals).
Produce per-file fix sub-plans (`A24a`, `A24b`, …) or documented
skips.

These are grouped together because the failures most likely surface
small bugs in stdlib functions or in how the lexer/parser handles
specific literal forms. Many may be one-line fixes once isolated.

## Out of scope

- Implementing fixes inline. Fixes go in follow-up `A24<letter>` plans.
- The metamethod/control-flow cluster (A23).
- The Runtime Type Error cluster (A21).
- `string.pack`/`string.unpack` — that's A25.
- Performance work.

## Success criteria

- [ ] Each of the eight files has a written diagnosis: which assert
      fails, what was expected vs received, and the suspected root
      cause.
- [ ] Each file has either a follow-up fix plan (`A24a`, …) under
      `.agents/plans/` or an `@tag :skip` with a clear deferred
      comment.
- [ ] Where multiple files share a root cause (likely for `db.lua` /
      `debug.*` and `strings.lua` / `string.*`), only one fix plan
      is written and the others reference it as their unblock.
- [ ] `mix test --include skip` count is unchanged after triage.

## Implementation notes

For each file, follow `triage-suite-failure`:

1. Repro standalone in `iex` against a fresh `Lua.new()`.
2. Read the line/source. Find the specific assert.
3. Print intermediate values: what does our stdlib return vs what
   PUC-Lua returns? Use `lua5.3` on the host where helpful.
4. Reduce to a 5-20 line repro under `test/lua/vm/`.
5. Classify and write `A24<letter>-<slug>.md`.

### Hypotheses to start with

- `db.lua` — `debug.*` library. Likely missing functions or wrong
  return values. `debug.getinfo`, `debug.traceback`, `debug.sethook`
  are common stubs.
- `literals.lua` — number/string literal parsing. Hex floats
  (`0x1p-3`), long strings with leading newline, `\z` skip-whitespace
  escape, `\xHH` byte escapes — any of these can be off-by-one.
- `constructs.lua` — table constructor edge cases. Mixing record-style
  and array-style entries, trailing commas, `[expr] = val` vs
  `name = val` precedence.
- `sort.lua` — `table.sort`. May be raising if the comparator returns
  something non-boolean, or may be unstable.
- `big.lua` — A10b (deferred) flagged perf. After A18 we have line
  info, so re-triage: is the actual *failure* a perf one (timeout) or
  a correctness one (assertion)? Behavior may have changed.
- `strings.lua` — `string.format` width/precision, `string.gsub` with
  replacement table, `string.byte`/`string.char` on non-ASCII.
- `calls.lua` — varargs, multiple returns, tail calls. We've shipped
  fixes here in A14/A15. Re-triage to see what's left.
- `locals.lua` — A6 fixed an early failure here. There's likely a
  different assert later in the file now.

### Files

- `lib/lua/vm/stdlib/string.ex` — likely fixes.
- `lib/lua/vm/stdlib/table.ex` — likely fixes.
- `lib/lua/vm/stdlib/debug.ex` (or wherever debug lives) — likely
  fixes for `db.lua`.
- `lib/lua/parser/*.ex` — likely fixes for `literals.lua` /
  `constructs.lua`.
- `lib/lua/lexer.ex` — possibly fixes for `literals.lua`.
- `.agents/plans/A24<letter>-*.md` — fix follow-ups.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test --include skip
```

## Risks

- This is the largest cluster (8 files). Some files may have
  multiple distinct asserts failing in sequence; reduce to the
  *first* failure per file and trust that fixing it unblocks
  whatever's behind.
- `big.lua` may still hit timeout rather than assertion failure.
  Coordinate with the perf track (A33-A35); a slow-but-correct
  result here is fine, a wrong-and-fast one is not.
- Some fixes may touch the parser/lexer in ways that have ripple
  effects. Sub-plans must include `mix test` runs of the *whole*
  suite, not just the file they're unblocking.

## Discoveries

(populated during triage)
