---
id: A7
title: Fix nextvar.lua "concatenate nil" failure
issue: 168
pr: 200
branch: fix/nextvar-suite
base: main
status: review
direction: A
unlocks:
  - nextvar.lua  # partial — full pass requires A7a (dead-key tracking)
---

## Goal

Make `nextvar.lua` pass. Current failure is "attempt to concatenate a nil
value", which is likely a downstream symptom of A1 (table reads returning
nil correctly will let downstream code distinguish absent from present).

## Out of scope

- Anything outside the specific failure(s) in `nextvar.lua`.

## Success criteria

- [x] `mix test` passes (≥ 1273, no regressions) — 1420 tests, 0 failures
- [x] Each fixed issue has a unit test in `test/lua/vm/nextvar_*_test.exs`
      (`test/lua/vm/nextvar_semantics_test.exs`, 18 cases)
- [ ] `nextvar.lua` passes end-to-end — **partial**. Three of four root
      causes fixed; the fourth (dead-key tracking for iterate-then-clear)
      is split out to plan A7a.

## Implementation notes

Blocked until A1 lands. After A1:

1. Re-run `nextvar.lua`. If it passes, close this plan as resolved.
2. If still failing, run `triage-suite-failure` workflow.
3. The "concatenate nil" pattern strongly suggests `next()` or `pairs()`
   returning `nil` where the test expects a real value. Inspect
   `lib/lua/vm/stdlib.ex` `lua_next` and `lua_pairs`.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- May reveal multiple issues; split into sub-plans if needed.

## Discoveries

The `nextvar.lua` failure had shifted by the time A7 ran — A1 had landed
and the original "concatenate nil" symptom was gone, replaced by an
assertion failure deeper in the file. Bisecting line by line surfaced
four distinct Lua 5.3 semantics gaps in the VM and stdlib:

1. **Assigning `nil` to a table key did not delete the key.**
   `set_table`, `set_field`, `set_list`, `table_newindex`, and `rawset`
   all called `Map.put(data, key, nil)` instead of `Map.delete(data, key)`.
   Consequences: `#{nil}` returned 1, `for k,v in pairs(t) do t[k] = nil end`
   left every key visible, and `next(t)` returned a key whose value was
   `nil`.

2. **Float keys with an exact integer value were stored as floats.**
   `t[2.0] = v` and `t[2] = v` lived in different slots; `t[1]` after
   `for i=0,4 do t[2^i] = true end` returned nil because `2^0` is `1.0`
   (float). Lua 5.3 §3.4.11 mandates integer-valued floats collapse to
   integers as table keys.

3. **`pairs` and `ipairs` did not validate their argument.** Calling
   them with no argument or with a non-table value crashed the BEAM
   process with a `FunctionClauseError` instead of raising the Lua-level
   "bad argument" error.

4. **`next(t, k)` does not handle keys that were valid mid-iteration
   and are now nil.** Real Lua keeps removed keys reachable in the hash
   chain (the "dead key" trick) so `for k,v in pairs(t) do t[k] = nil end`
   works. We don't have dead-key tracking, so iteration breaks as soon
   as a key is cleared. Per Lua 5.3 §6.1, a strict `next` should also
   raise "invalid key" when the key never existed in the table — but
   that strict check conflicts with mid-iteration deletion until dead
   keys are implemented.

This PR fixes (1), (2), and (3), each with a focused unit test in
`test/lua/vm/nextvar_semantics_test.exs`. The `next` error path is
left lenient (returns `nil, nil` for missing keys) so the dead-key gap
in (4) can be closed in plan **A7a — dead keys for `next`** without
this PR causing iteration regressions in the meantime. With (4) fixed,
`nextvar.lua` should pass end-to-end and be promoted to `@ready_tests`
in `test/lua53_suite_test.exs`.

### Files touched

- `lib/lua/vm/table.ex` — added `put_data/3`, `get_data/2`, `has_data?/2`,
  `normalize_key/1`, `invalid_key?/1` so every table-data access can
  share the same write-as-delete and integer-coercion rules.
- `lib/lua/vm/executor.ex` — routed `set_table`, `set_field`, `set_list`
  (both variants), `table_index`, and `table_newindex` through the new
  helpers.
- `lib/lua/vm/state.ex` — `set_global` now deletes when the value is
  `nil` so `x = nil` at top level removes the global.
- `lib/lua/vm/stdlib.ex` — `rawset`/`rawget` use the new helpers;
  `pairs`/`ipairs` raise `ArgumentError` for missing or wrong-typed
  arguments; `next` normalizes float-int keys.
- `test/lua/vm/nextvar_semantics_test.exs` — new file pinning each fix.

## What changed

- PR: #200 (`fix(vm): align table key semantics with Lua 5.3 §3.4.11`)
- `mix test`: 1402 → 1420 (+18 unit tests; 0 failures, 31 skipped).
- `mix test --only lua53`: 5 ready / 24 skipped (unchanged — `nextvar.lua`
  stays skipped until A7a lands).
- Files touched (5): `lib/lua/vm/table.ex`, `lib/lua/vm/executor.ex`,
  `lib/lua/vm/state.ex`, `lib/lua/vm/stdlib.ex`, plus new
  `test/lua/vm/nextvar_semantics_test.exs`.
- Follow-up: `.agents/plans/A7a-nextvar-dead-keys.md` — dead-key
  tracking so `next(t, k)` survives `t[k] = nil` mid-iteration, plus
  the strict "invalid key" raise it unblocks. Promoting `nextvar.lua`
  to `@ready_tests` happens there.
