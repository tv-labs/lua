---
id: A9a
title: Fix multi-return register expansion exposed by pm.lua
issue: null
pr: 189
branch: fix/pm-suite-executor
base: main
status: review
direction: A
unlocks:
  - pm.lua (continuation of A9, blocked behind A9b)
---

## Goal

Make `pm.lua` runnable past line 112 by fixing the executor's multi-return
handling. Once unblocked, finish triaging any remaining pm.lua failures
and land the suite test under `@ready_tests`.

## Out of scope

- Pattern-engine work (covered by A9 / future A9b if needed).
- General executor refactors. Make the smallest change that grows the
  register tuple safely on multi-return.

## Success criteria

- [ ] `string.char(<256 returns from a recursive multi-return function>)`
      no longer crashes.
- [ ] `pm.lua` passes end-to-end (or the next failure surfaces and is
      either fixed in scope or split into A9b).
- [ ] `pm.lua` is moved from `@skipped_tests` to `@ready_tests` in
      `test/lua53_suite_test.exs`.
- [ ] Unit test added in `test/lua/vm/call_stack_test.exs` (or new file)
      that exercises a recursive multi-return ≥ 100 values feeding a
      variadic native call.
- [ ] `mix test` passes (≥ current count, no regressions).

## Implementation notes

Failure (reproducible from `pm.lua` line 112):

```
:erlang.setelement(26, {tuple of 25 elements}, 255)
lib/lua/vm/executor.ex:1143  do_frame_return/6
```

Triggered by:

```lua
local function range(i, j)
  if i <= j then return i, range(i+1, j) end
end
local abc = string.char(range(0, 255))
```

`range(0, 255)` returns 256 values via tail-position multi-return. The
`-2` (multi-return expansion) branch in `do_frame_return/6` writes them
into the caller's register tuple starting at `base`, but the tuple was
allocated by the compiler for the syntactic call site and isn't sized
for 256 expanded slots.

Likely fix: in the `-2` arm of `do_frame_return/6`, ensure
`caller_regs` is grown to at least `base + length(results_list)` slots
before the `Enum.reduce/3` writes happen. The same precaution probably
belongs in the fixed-N arm (`n > 0`) and in `continue_after_call/12`.

Use `:erlang.tuple_size/1` to check capacity, and rebuild the tuple
with appended `nil`s if needed. Keep the change to a single helper
function so the three call sites stay aligned.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/call_stack_test.exs
mix test test/lua/vm/string_test.exs
```

## Risks

- Growing the register tuple changes a hot-path invariant. Make sure
  the new path is taken only when actually needed (`needed_size >
  tuple_size(regs)`), so the common case stays a single `put_elem`.
- Coroutines and pcall use the same return path; verify their tests
  still pass before opening the PR.

## Discoveries

The executor fix lands cleanly: `string.char(range(0, 255))` now
returns the expected 256-byte string and pm.lua advances past line 114
(`assert(string.len(abc) == 256)`).

The next failure — pm.lua line 122, `strset('[\200-\210]')` — is a
**pattern-engine bug**, explicitly out of scope per this plan's
"Out of scope" section. Minimal repro: `string.gsub("abc", "[a-c]",
"X")` returns `"abc"` instead of `"XXX"`. The gsub character-class
matcher appears to drop matches.

Split into [`A9b`](.agents/plans/A9b-pm-suite-pattern.md) — `fix/pm-suite-pattern`.
pm.lua remains in `@skipped_tests` until A9b lands.

**Implementation summary:**

- Added `ensure_regs_capacity/2` helper in `lib/lua/vm/executor.ex`.
  When a multi-return expansion would write past the end of the
  caller's register tuple, the helper grows the tuple lazily with a
  small headroom (16 extra slots) so back-to-back expansions don't
  thrash. The common case (sufficient capacity) remains a single
  `tuple_size/1` check.
- Applied at the three call sites: the `-2` and `n > 0` arms of
  `do_frame_return/6`, and the matching arms in `continue_after_call/12`.
- Test coverage in `test/lua/vm/call_stack_test.exs` covers four
  shapes: 256-value multi-return into a variadic native call,
  100-value into a variadic native call, fixed-count assignment from a
  large multi-return (taking only the first N), and table constructor
  expansion from a large multi-return.

## What changed

PR: #189

Files touched:

- `lib/lua/vm/executor.ex` — `ensure_regs_capacity/2` helper, applied
  at the three multi-return write sites (`do_frame_return/6` -2 and
  n>0 arms, plus the matching arms in `continue_after_call/12`).
- `test/lua/vm/call_stack_test.exs` — four new tests under the
  "multi-return register expansion" describe block.

Suite delta: pm.lua advances past line 114 but still fails at line 122.
Remains in `@skipped_tests`. Will move to `@ready_tests` when A9b lands.

Test count: 1342 → 1346 (4 new tests), 0 failures, no regressions.

Follow-up: [A9b](A9b-pm-suite-pattern.md) — `fix/pm-suite-pattern`.
