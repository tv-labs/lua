---
id: A47
title: Close open upvalues at if/while/for/repeat block exit
issue: 276
pr: null
branch: fix/open-upvalue-block-close
base: main
status: in-progress
direction: A
unlocks:
  - calls.lua
---

# A47 — Close open upvalues at if/while/for/repeat block exit

## Goal

Fix a live VM bug where `state.open_upvalues` (keyed by register) is
never closed when an `if`/`while`/`for`/`repeat` block ends. When a
later sibling block reuses the same register for a new captured local,
the closure handler reuses the stale cell ref, so reads of the new local
(directly via `get_open_upvalue` or through any inner closure that
captures it) return the *previous* block's value.

`do…end` was already fixed in PR #286 by emitting a
`:close_upvalues` instruction at block exit and sweeping
`open_upvalues` in the executor. The remaining block-scoping statements
(`if`, `while`, `for`-numeric, `for`-in, `repeat`) do not close their
body locals' cells, so the bug still surfaces — confirmed by reproducing
it with two sibling `if` blocks, which crashes with
`attempt to index a number value (upvalue 'a')`. This is the downstream
blocker for `calls.lua:65–69`, surfaced by the FuncDecl head-resolution
fix in PR #274.

The fix extends the existing block-close mechanism to every block-scoping
statement, removing only the entries that went out of scope and never
touching `state.upvalue_cells` (existing closures hold valid cell refs
and resolve through it).

## Out of scope

- Option 2 in the issue (full per-block open-range tracking in scope
  analysis à la PUC-Lua `OP_CLOSE`). We take option 1: emit a close at
  block-scope end parametrised by the block's register watermark, reusing
  the `do`-block machinery already on `main`.
- Any change to `state.upvalue_cells` semantics or to the closure
  capture handler.
- The other `calls.lua` skip ranges (24–36, 135–137, 217–218, 219–401);
  those have separate, unrelated causes already documented in
  `test/lua53_skips.exs`.
- Rewriting the threshold-based sweep into an explicit register-set
  parameter. The existing `close_open_upvalues_at_or_above/2` sweeps
  entries at-or-above the block's pre-entry `next_register` watermark,
  which is exactly the set of registers the block's locals occupied; the
  registers below the watermark belong to enclosing scopes and are left
  intact. This already satisfies the issue's "remove ONLY the block's
  entries, never touch `upvalue_cells`" requirement.

## Success criteria

- [ ] The two-sibling-`do`-block repro from issue #276 passes (already
      green on `main` via PR #286 — guard against regression).
- [ ] The two-sibling-`if`-block repro passes (currently crashes with
      `attempt to index a number value (upvalue 'a')`).
- [ ] Sibling `while`, `for`-numeric, `for`-in, and `repeat` blocks that
      declare a captured local on the same register no longer leak a
      stale cell.
- [ ] A loop whose body captures a local and is re-entered across
      iterations still observes correct per-iteration values (cells
      persist within an iteration, close on iteration boundary and on
      loop exit).
- [ ] `calls.lua:65..69` removed from `test/lua53_skips.exs`; the
      `calls.lua` range list narrows accordingly (the next downstream
      blocker, if any, is documented in the same file).
- [ ] Regression test added to `test/lua/vm/upvalue_test.exs`: two
      sibling `do` blocks declaring captured locals on the same register,
      plus the `if`/loop variants exercising the same register reuse.
- [ ] `mix test` passes; no regressions in `test/lua/vm/upvalue_test.exs`
      or closure-style tests.
- [ ] `mix test --only lua53` passes with no suite regressions;
      `calls.lua` passes further than before.

## Implementation notes

The close machinery already exists and is shared by both executors —
the work is extending emission to the non-`do` block types.

**`lib/lua/compiler/scope.ex`** — `Statement.Do` resolution
(`resolve_statement/2`, ~line 359) stashes the pre-block register
watermark under `{:do_close_threshold, do_stmt}`. Add the same watermark
stash for the block-scoping statements that currently lack it:
- `Statement.If` (~line 180) — per `then_block`, each elseif block, and
  the `else_block`. Note `if` blocks resolve through
  `with_block_scope/2`; capture the watermark for each sub-block so
  codegen can emit a close at the end of each branch body.
- `Statement.While` (~line 202) and `Statement.Repeat` (~line 207).
- `Statement.ForNum` (~line 220) and `Statement.ForIn` (~line 316).
  These already save `saved_next_register`; stash a per-statement close
  threshold keyed on the statement struct.

Use distinct `var_map` keys per block type (mirroring
`{:do_close_threshold, do_stmt}`) so codegen can fetch them.

**`lib/lua/compiler/codegen.ex`** — mirror the `Statement.Do`
generator (~line 733, which appends `Instruction.close_upvalues(threshold)`
to the block body):
- `Statement.If` (~line 453) and `gen_elseifs_and_else`/`gen_block`
  callers (~line 853, 861): append a close to the end of each branch's
  body instructions before they are wrapped in the `:test` instruction.
- `Statement.While` (~line 472) and `Statement.Repeat` (~line 485):
  append the close to `body_instructions` so the body closes its locals
  on each iteration boundary AND on loop exit (the close runs at the tail
  of the body, before the loop re-test).
- `Statement.ForNum` (~line 499) and `Statement.ForIn` (~line 551):
  append the close to `body_instructions`.

For loops, the existing per-iteration `close_open_upvalues_at_or_above`
calls in the continuation handlers
(`lib/lua/vm/executor.ex:574,603`) key on the loop-variable register and
already sweep body-local cells at the iteration boundary; appending a
body-tail close handles the within-iteration block scope and the
final-iteration exit. Confirm with the loop repro that cells still
persist correctly within an iteration (a closure created mid-body and
called later in the same iteration must see the live value).

**`lib/lua/vm/executor.ex`** — no new handler needed. The
`:close_upvalues` instruction handler (~line 708) and
`close_open_upvalues_at_or_above/2` (~line 2867, with its
`map_size == 0` fast path) already exist and do exactly the required
work: `Map.reject` entries at-or-above the threshold from
`open_upvalues`, leaving `upvalue_cells` untouched. Verify the emitted
thresholds land in this handler unchanged.

**`lib/lua/vm/dispatcher.ex`** — the PC-dispatch executor is on the hot
path: `Executor` routes function calls through `Dispatcher.execute/4`
(`executor.ex:146,971`), so a closure created in a block may run under
the dispatcher. It already handles `@op_close_upvalues` (op 52,
~line 958) via `Executor.dispatcher_close_open_upvalues_at_or_above/2`
and has per-iteration loop closes (~line 830, 878). Confirm the new
`close_upvalues` instructions encode and decode correctly through
`lib/lua/compiler/bytecode.ex` (op 52 already wired at
`bytecode.ex:349`) and run under the dispatcher; add coverage if the
sibling-block repro routes through it. No new opcode is required.

**`test/lua/vm/upvalue_test.exs`** — add a `describe` block covering
register reuse across sibling blocks. Include: two sibling `do` blocks
(guards the PR #286 fix), two sibling `if` blocks (the primary repro for
this issue), and `while`/`for`/`repeat` variants where both blocks
declare a captured local landing on the same register. Add at least one
loop case asserting per-iteration values are correct (cells do not leak
across iterations and a closure created in iteration N sees iteration
N's value). Do not reference the plan id in any moduledoc or comment;
describe the §3.4.10 contract being pinned.

**`test/lua53_skips.exs`** — remove the `calls.lua` `lines: 65..69`
skip entry (the `:executor` / issue 276 one). Re-run `calls.lua` to
confirm where it next stops; if a new downstream blocker appears,
document it as a fresh skip entry with its own one-line reason.

## Verification

Run before any code change to snapshot the suite state, and again after:

```
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/upvalue_test.exs
mix test
mix test --only lua53
```

Manual repro (must crash before the fix, pass after):

```
do
  local res = 1
  local function fact (n)
    if n == 0 then return res else return n * fact(n - 1) end
  end
  assert(fact(5) == 120)
end
do
  local a = {x = 100}
  local function read_a() return a.x end
  assert(read_a() == 100, "expected 100, got stale-cell value")
end
```

and the `if`/`while`/`for`/`repeat` variants of the same two-block
shape. Capture the `mix test --only lua53` pass-count delta and confirm
`calls.lua` advances past line 69 with no other suite file regressing.

## Risks

- **Closing cells at block end is a subtle change to executor
  invariants.** Existing closures hold cell refs and resolve through
  `state.upvalue_cells`, which must NOT be touched — only the
  `open_upvalues` index map. The reused `close_open_upvalues_at_or_above/2`
  already respects this; verify no new code path mutates
  `upvalue_cells`.
- **Loops re-enter the block body across iterations.** Cells must
  persist within an iteration (a closure created mid-body and called
  later in the same iteration sees the live value) and close only at the
  iteration boundary and loop exit. The body-tail close plus the existing
  per-iteration sweep must not close a cell that the current iteration's
  later statements still read. The loop regression test guards this.
- **`if` branches share register slots.** Both the `then` and `else`
  branches reuse the same register watermark; closing at the end of each
  branch body must not strand a cell that an enclosing scope still owns.
  The threshold is the pre-branch `next_register`, so only branch-local
  registers are swept.
- **Two executors must stay consistent.** `Executor` and `Dispatcher`
  both run block code; an asymmetric fix would leave the bug live on one
  path. Both already route `:close_upvalues` / op 52, so the risk is
  emission coverage, not handler divergence — exercise both via the
  closure-call repro.
- **Over-closing could regress unrelated upvalue tests.** The full
  `upvalue_test.exs` and closure-style suites must stay green; run them
  explicitly before the broader `mix test`.
