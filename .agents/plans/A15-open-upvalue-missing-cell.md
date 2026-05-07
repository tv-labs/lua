---
id: A15
title: set_open_upvalue / get_open_upvalue crash when cell is missing
issue: null
pr: 196
branch: fix/open-upvalue-missing-cell
base: main
status: merged
direction: A
unlocks:
  - sort.lua
  - strings.lua
  - verybig.lua
---

## Goal

Fix the `Map.fetch!` crash inside `set_open_upvalue` and `get_open_upvalue`
in `lib/lua/vm/executor.ex` (lines 301 and 310 at the time of writing).
When these handlers run with a register that has no entry in
`state.open_upvalues`, the VM raises:

```
Lua runtime error: key N not found in: %{}
```

instead of behaving correctly. This was discovered while shipping plan A1:
A1's stated table-read bug already passes, but the same error message also
appears here from a completely unrelated path.

## Reproduction

`test/lua53_tests/sort.lua` fails partway through with:

```
testing (parts of) table library
testing unpack
Lua runtime error: key 3 not found in:

    %{}
```

Stacktrace ends at `lib/lua/vm/executor.ex:310` inside `set_open_upvalue`.
`strings.lua` and `verybig.lua` produce the same error shape with
different keys.

## Out of scope

- The for-loop register regression in A14 (separate bug, separate symptom).
- Any other suite failure that surfaces *after* this fix lands.
- Refactors of the upvalue / closure pipeline beyond what is needed.

## Success criteria

- [ ] `mix test` passes (no regressions vs. baseline).
- [ ] `mix test test/lua/vm/table_index_test.exs` still green (sanity).
- [ ] New unit test in `test/lua/vm/upvalue_test.exs` (or appropriate
      existing file) reproduces the original sort.lua-style failure as a
      minimal Lua snippet and asserts it does not crash.
- [ ] At least one of `sort.lua`, `strings.lua`, `verybig.lua` makes more
      progress than before (passes outright if no further bugs surface;
      otherwise fails later, at a different site, and that site is logged
      in `## Discoveries`).

## Implementation notes

The crash is `Map.fetch!(state.open_upvalues, reg)` against an empty (or
not-yet-populated) `open_upvalues`.

Read the lifecycle:

```bash
grep -nE "open_upvalues|open_upvalue|set_open_upvalue|get_open_upvalue" \
  lib/lua/vm/executor.ex
```

`open_upvalues` is reset to `%{}` at:

- VM entry (line ~30)
- Tailcall / call boundaries (lines ~59, 551, 1252, 1470, 1515, 1564)
- Loop-end cleanups (`Map.reject(...)` at lines ~197, 230, 416, 453)

Cells are only *created* by the `closure` handler around line 470, which
adds `{reg => cell_ref}` when a nested prototype captures a parent local.

Hypothesis: a code path emits `set_open_upvalue` / `get_open_upvalue` for
a register that was never claimed by a `closure`. Either:

1. The compiler emits these instructions when it shouldn't, or
2. A `Map.reject` cleanup is too eager and removes a cell that is still
   live, or
3. `open_upvalues` is reset (`%{}`) without first promoting live cells
   into closed-upvalue cells, leaving dangling instructions.

Reduce sort.lua to the smallest snippet that reproduces, then bisect from
there. A starting reduction:

```bash
elixir -e 'try do Lua.eval!(File.read!("test/lua53_tests/sort.lua")) rescue e -> IO.puts(Exception.format_stacktrace(__STACKTRACE__)) end'
```

Tag the snippet, copy into `test/lua/vm/upvalue_test.exs`, and iterate.

Likely fix shape: either make `set_open_upvalue` / `get_open_upvalue` fall
back to creating the cell on demand (mirroring `closure`'s logic at line
470), or fix the offending compiler emission / cleanup site.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/upvalue_test.exs
mix test --only lua53
```

Capture suite delta in PR body.

## Risks

- Falling back to "create cell on demand" hides real compiler bugs. Prefer
  to find the upstream cause first.
- Eager cleanup via `Map.reject` may be the root cause. Tightening it
  could leak upvalue cells; verify with the metatable / closure regression
  tests in `test/lua/vm/metatable_test.exs` and any closure tests.

## Discoveries

### Root cause

The codegen for `Statement.LocalFunc` in `lib/lua/compiler/codegen.ex` (around
line 684) decided whether to emit `set_open_upvalue` based on
`MapSet.member?(ctx.scope.captured_locals, name)`. `captured_locals` is the
*final* set of parent-locals captured by *any* descendant closure across the
current scope -- it is computed by scope analysis across the full block
before codegen runs.

That made the check too permissive. For non-recursive `local function L`,
the closure for `L` doesn't capture itself, so no upvalue cell is created
when the closure instruction runs. But if a *later* sibling closure
captures `L` by name, `captured_locals` contains `L`, so codegen emitted a
`set_open_upvalue` immediately after `move dest_reg, closure_reg`. That
instruction crashed with `key N not found in: %{}` because the cell only
gets created later, when the sibling closure's `closure` instruction
executes.

A second, structurally identical bug lived in `gen_var_by_name` (around
line 1313). It emitted `get_open_upvalue` for FuncDecl table-chain targets
(`function obj.method() end`) when `obj` was captured by a later closure.
Same crash shape, different opcode.

### Fix

Two complementary changes:

1. **Compiler-level (codegen.ex)**: In `LocalFunc`, only emit
   `set_open_upvalue` when the function's own closure captures itself --
   the genuine recursive case. The check uses the closure's
   `upvalue_descriptors` instead of the surrounding scope's
   `captured_locals`. This eliminates the wasteful, broken emission for
   non-recursive locals.

2. **Executor-level (executor.ex)**: Make `get_open_upvalue` and
   `set_open_upvalue` cell-aware. If the register has no entry in
   `open_upvalues`, the register itself is the source of truth -- read
   from / write to it directly. The next closure that captures the
   register will create a cell from the current register value via the
   existing `closure` handler logic. This handles `gen_var_by_name` and
   any other downstream sites the compiler can't easily detect at codegen
   time.

### Suite delta

`sort.lua`, `strings.lua`, `verybig.lua` all now make further progress:

- `sort.lua` reaches an `assert` failure inside `checkerror("wrong number of
  arguments", table.insert, ...)` -- our `table.insert` raises with a
  message that doesn't match `"wrong number of arguments"` ("bad argument
  #1 to 'table.insert' (table expected, got table)"). Out of scope for A15.
- `strings.lua` reaches an `assert` failure inside
  `testing strings and string library` -- separate stdlib issue.
- `verybig.lua` reaches `os.tmpname()` which is sandboxed by default.

None of the three now crash with the original `key N not found in: %{}`
shape. The lua53 suite keeps these files in `@skipped_tests` until those
downstream bugs are also fixed; this plan only unblocks them, it does not
flip them to ready.

## What changed

PR: https://github.com/tv-labs/lua/pull/196

Files touched:

- `lib/lua/compiler/codegen.ex` -- only emit `set_open_upvalue` for
  `LocalFunc` when the closure captures itself (recursive case). Adds
  `captures_self?/3` helper.
- `lib/lua/vm/executor.ex` -- `get_open_upvalue` falls back to reading
  the register when no cell exists; `set_open_upvalue` is a no-op in
  that case (the register already holds the correct value).
- `test/lua/vm/upvalue_test.exs` -- new file with 7 regression tests
  covering the LocalFunc-sibling-capture case, the FuncDecl
  table-chain-capture case, the recursive case (still works), and a
  shared-upvalue-cell case.

Test delta: `mix test` 1375 → 1382 (1373 unchanged + 7 new + 2
existing-but-untouched-by-this-change net of for-loop-register tests
that landed concurrently in main). 0 failures, 0 regressions.

Suite delta (`mix test --only lua53`): no change (29 tests, 0 failures,
25 skipped). The three unblocked files (`sort.lua`, `strings.lua`,
`verybig.lua`) stay in `@skipped_tests` until their downstream failures
are fixed -- those are separate plans.
