---
id: A8e
title: "__le falls back to `not (b < a)` when __le is unset"
issue: null
pr: 213
branch: fix/le-fallback-not-lt
base: main
status: merged
direction: A
unlocks:
  - events.lua advances past line 258 (`assert((Set{1,2,3,4} <= Set{1,2,3,4}))`)
  - any user code that defines `__lt` on tables but omits `__le`
---

## Goal

Make the `:less_equal` opcode fall back to `not (b < a)` when neither
operand has an `__le` metamethod, per Lua 5.3 §3.4.4. Today,
`:less_equal` looks up `__le` and — if missing — runs
`safe_compare_le`, which raises `attempt to compare table with table`
on table operands. The reference manual is explicit:

> The `<=` operation is translated to `not (b < a)` if there is no
> `__le` metamethod.

So when `__le` is unset, dispatch should consult `__lt` (with operands
*swapped*) and negate the result. Only fall through to
`safe_compare_le` when neither metamethod is defined and the operands
have a primitive `<=` (numbers, strings).

The same fallback covers the reverse: in the official manual `>=` is
defined as `b <= a`, so `:greater_equal` already routes through this
path. Verify in the implementation that fixing `:less_equal` also
fixes `>=` between tables when `__lt` is the only comparison
metamethod present.

## Out of scope

- Changing `__lt` itself. Single-direction `__lt` dispatch on table
  operands already works (verified on main on 2026-05-07: a metatable
  with only `__lt` makes `Op(1) < Op(2)` return the expected value).
- The `:not_equal` / `__eq` short-circuit. That is A8d's territory and
  shipped (or will ship) under its own plan.
- Strict-mode raw-equality between primitives. §3.4.4's primitive
  short-circuit already applies and isn't touched here.
- Promoting `events.lua` to `@ready_tests`. There may be further stops
  past line 258; advance the file probe and document the next stop in
  Discoveries before promoting.

## Success criteria

- [ ] `Op(1) <= Op(2)` returns `true` when only `__lt` is set on the
      metatable (current behaviour: raises `attempt to compare table
      with table`).
- [ ] `Op(2) <= Op(1)` returns `false` in the same setup. The fallback
      uses `__lt(b, a)` and negates: `not (Op(1) < Op(2)) == false`.
- [ ] `Op(1) <= Op(1)` returns `true` (negation of `not (a < a)`).
- [ ] `__le` (when set) still wins. The fallback only fires when neither
      operand exposes `__le`.
- [ ] `>=` between tables defined only via `__lt` works for the same
      reason (existing translation `a >= b ⇒ b <= a` chains into the
      new fallback).
- [ ] `safe_compare_le` still raises for primitive operands of mixed,
      non-comparable type (e.g. `1 <= "x"` still raises). The fallback
      is for *table* operands missing `__le`, not a license to compare
      mismatched primitives.
- [ ] events.lua line 258 (`assert((Set{1,2,3,4} <= Set{1,2,3,4}))`)
      passes standalone. Document the next stop after line 258 in
      Discoveries.
- [ ] Unit tests pinning the new fallback in
      `test/lua/vm/comparison_metamethod_test.exs` (new file) or as an
      addition to the existing metatable test file. At minimum:
      - metatable with `__lt` only, table-table `<=` and `>=`
      - metatable with `__le` only, table-table `<=` (must still call
        `__le`, not `__lt`)
      - metatable with both, `<=` calls `__le` (not `__lt`)
      - mixed: one operand has `__le`, other doesn't — `__le` from
        either operand wins (matches existing
        `try_binary_metamethod` lookup order)
- [ ] `mix test` passes; no regressions.

## Implementation notes

The fix is local to `lib/lua/vm/executor.ex`. The current
`:less_equal` opcode is at line 948:

```elixir
defp do_execute([{:less_equal, dest, a, b} | rest], regs, ...) do
  val_a = elem(regs, a)
  val_b = elem(regs, b)

  {result, new_state} =
    try_binary_metamethod("__le", val_a, val_b, state, fn -> safe_compare_le(val_a, val_b) end)
  ...
end
```

`try_binary_metamethod/5` is at line 1572:

```elixir
defp try_binary_metamethod(metamethod_name, a, b, state, default_fn) do
  metamethod =
    lookup_metamethod(a, metamethod_name, state) ||
      lookup_metamethod(b, metamethod_name, state)

  invoke_metamethod(metamethod, [a, b], state, default_fn)
end
```

The `default_fn` runs when no `__le` is found on either operand. Today
`default_fn` is `safe_compare_le`, which raises on tables. Replace the
default with one that:

1. Looks up `__lt` on `b` (then `a`, matching the existing dispatch
   order).
2. If `__lt` exists, invoke it with operands **swapped** (`__lt(b, a)`)
   and negate the result.
3. If `__lt` is also absent, fall through to `safe_compare_le` (which
   handles numbers/strings and raises on incompatible types).

Sketch:

```elixir
defp do_execute([{:less_equal, dest, a, b} | rest], regs, ..., state, ...) do
  val_a = elem(regs, a)
  val_b = elem(regs, b)

  {result, new_state} =
    try_binary_metamethod("__le", val_a, val_b, state, fn ->
      try_binary_metamethod("__lt", val_b, val_a, state, fn ->
        safe_compare_le(val_a, val_b)
      end)
      |> negate()
    end)
  ...
end

# Helper: negate the {result, state} tuple's first element.
defp negate({result, state}), do: {not result, state}
```

Watch for two subtleties:

- `try_binary_metamethod` returns `{result, state}`. The outer
  `default_fn` must also return `{result, state}` — both because
  `try_binary_metamethod` calls `default_fn.()` and uses its return
  directly (look at `invoke_metamethod` line 1607-1614 for the
  exact contract).
- The negation must wrap the *whole* `{result, state}` tuple, not
  just the boolean. The test for "`__le` calls `__le`, not `__lt`"
  exists specifically to prevent over-eager negation when `__le` is
  set but happens to delegate to `__lt` somewhere.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/comparison_metamethod_test.exs  # new file (if added)
mix test test/lua/vm/metatable_test.exs              # existing regressions
```

Repro that should change behaviour:

```lua
local t = {}
t.__lt = function(a, b) return a.x < b.x end
-- t.__le intentionally unset
local function Op(x) return setmetatable({x=x}, t) end
print(Op(1) <= Op(2))  -- on main: raises; after A8e: prints true
```

Repro from events.lua line 258 that should pass standalone:

```lua
local t = {}
local function rawSet(x) local s={}; for _,v in ipairs(x) do s[v]=true end; return s end
local function Set(x) return setmetatable(rawSet(x), t) end
t.__lt = function (a,b)
  for k in pairs(a) do
    if not b[k] then return false end
    b[k] = nil
  end
  return next(b) ~= nil
end
t.__le = nil
assert((Set{1,2,3,4} <= Set{1,2,3,4}))
```

## Risks

- `:greater_equal` and `:greater_than` may also rely on
  `safe_compare_*` and need parallel treatment. Check the executor
  near line 959 onward — if `:greater_equal` is implemented as
  `:less_equal` with swapped operands, the A8e fix already covers it.
  If it's a separate opcode, mirror the change.
- If `try_binary_metamethod` short-circuits on `__le` *before*
  consulting `__lt`, the fallback is correct. If for any reason a
  metatable has both `__le` and `__lt` and the user expects only
  `__le` to fire (which is the spec), the existing lookup order is
  fine — `__lt` is only consulted when `__le` is nil.
- Performance: every `<=` between non-numeric, non-string operands
  now does up to two metatable lookups instead of one. The cost is
  negligible (metamethod lookup is already in the hot path for any
  table comparison) but worth flagging if a benchmark regresses.

## Background

Discovered while shipping A8b (`fix/io-stub-as-table`, PR #210).
After A8b unblocked events.lua line 188 (`pcall(rawlen, io.stdin)`),
the suite advanced and stopped at line 258. Triage on 2026-05-07 with
the file-probe pattern from the `triage-suite-failure` skill:

1. Bisected events.lua's truncated-with-`do return end` execution
   between lines 250 and 280.
2. Confirmed line 258 (`assert((Set{1,2,3,4} <= Set{1,2,3,4}))`) is
   the first hit.
3. Reduced to:

   ```lua
   local t = {}
   t.__lt = function(a, b) return a.x < b.x end
   local function Op(x) return setmetatable({x=x}, t) end
   return Op(1) <= Op(2)  -- raises "attempt to compare table with table"
   ```

4. Verified `__lt` itself dispatches correctly: a metatable with only
   `__lt` makes `Op(1) < Op(2)` return `true` without raising.
5. Verified `__le`, when set, dispatches correctly too: a metatable
   with `__lt` and `__le` makes `Op(1) <= Op(2)` return whatever
   `__le` returns.

So the gap is precisely the §3.4.4 fallback — and only that.

This plan was opened as the documented follow-up from A8b's
Discoveries section. PR #210 (A8b) carries a Discoveries pointer to
this plan id.

## Context for the picking agent

A few cross-plan details worth knowing before starting:

- **A8b's first Discoveries entry was wrong and has been corrected.**
  It originally claimed `__lt` and `__le` don't dispatch on tables.
  Re-triage proved that's not true — both dispatch correctly when set.
  Only the `__le` fallback is missing. The corrected entry in
  `.agents/plans/A8b-io-stub-as-table.md` and PR #210's body now
  reflect that. Don't be misled by any earlier draft of the A8b
  description if you read it via cached state.

- **A8d notes "`__lt` / `__le` are already routed through
  `try_binary_metamethod`."** That's accurate for *direct* dispatch.
  A8d is silent on the §3.4.4 fallback path, which is what A8e fills
  in. There's no conflict between A8d and A8e — they touch different
  code paths in the same opcode family.

- **The picker order is A8c → A8d → A8e.** A8c (floor-div-mod-float-zero)
  and A8d (`~=` / `__eq` dispatch) are independent of this plan and
  can ship first or last. None of the three blocks the others. If the
  user wants A8e prioritised, they can pick it directly by id.

- **events.lua remains in `@skipped_tests`** in
  `test/lua53_suite_test.exs:18`. After A8e ships, advance the
  file-probe past line 258, document the next stop in this plan's
  Discoveries, and decide whether to promote events.lua to
  `@ready_tests` or open the next follow-up plan. Promotion is
  out of scope for A8e itself.

- **Reuse the file-probe pattern** from the `triage-suite-failure`
  skill if you need to find the next stop. The Background section
  above already names the truncated-with-`do return end` pattern
  used to bisect line 258. The same pattern picks up where A8e
  leaves off.

## What changed

PR: https://github.com/tv-labs/lua/pull/213

Files touched:

- `lib/lua/vm/executor.ex`: added `compare_le/3` helper implementing
  the §3.4.4 fallback (`__le` → `__lt(b, a)` negated → primitive
  `<=`). Routed `:less_equal` through it. Also routed `:greater_equal`
  through `compare_le(b, a, state)` per `a >= b ⇔ b <= a`, and
  `:greater_than` through `try_binary_metamethod("__lt", b, a, ...)`
  per `a > b ⇔ b < a`. Removed now-unreferenced `safe_compare_gt` and
  `safe_compare_ge`.
- `test/lua/vm/metatable_test.exs`: 6 new tests pinning the fallback
  semantics across `<=`, `>=`, `>`, the precedence rules, and the
  primitive-raise edge case.

Test delta: 1564 → 1570 (+6 new tests), 0 failures, 31 skipped.
Lua 5.3 suite unchanged: 4/24 ready, 24 skipped.

## Discoveries

- **`:greater_than` skipped metamethod dispatch entirely.** Anticipated
  in the plan's Risks section. Fixing it was necessary in scope:
  events.lua's `test()` function calls `Op(1) > Op(1)` etc., which
  triggered the same "attempt to compare table with table" failure
  even with `__lt` set. Per spec `a > b ⇔ b < a`, so `:greater_than`
  now routes through `__lt(b, a)`.

- **`:greater_equal` is a separate opcode, not a desugaring.** Codegen
  at `lib/lua/compiler/codegen.ex:929` emits `:greater_equal` for `>=`.
  So mirroring the `:less_equal` fix to `:greater_equal` was required
  for success criterion #5.

- **events.lua next stop: line 285.** With A8e shipped and A8b
  patched out (still in review on main), the file probes cleanly
  through line 284. Line 285 is `assert(Set{1,3,5,1} ==
  rawSet{3,5,1})` — comparing a table with `__eq` to a raw table.
  Per Lua 5.3 §3.4.4 this should consult `__eq`. Adjacent to A8d's
  `~=` / `__eq` dispatch territory; a separate follow-up plan can
  pick it up. events.lua remains in `@skipped_tests`.

- **events.lua line 188 (`pcall(rawlen, io.stdin)`) still blocks the
  file** because A8b is in review and not yet merged on main. Once
  A8b ships, the file should advance through to line 285 in one go.
