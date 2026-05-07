---
id: A5
title: Fix bitwise.lua failing assertion
issue: 166
pr: 198
branch: fix/bitwise-suite
base: main
status: review
direction: A
unlocks:
  - bitwise.lua
---

## Goal

Make `bitwise.lua` pass the official Lua 5.3 suite. Currently fails with
`Assertion Failed: assertion failed!` (no line info, indicating an early
assertion).

## Out of scope

- Architectural bitwise changes (covered in A0).
- Anything not directly tied to a failing assertion in `bitwise.lua`.

## Success criteria

- [x] `mix test` passes (≥ 1273, no regressions)
- [x] Each fixed assertion has a corresponding unit test in
      `test/lua/vm/bitwise_test.exs`.
- [ ] `bitwise.lua` passes end-to-end. (Partially: lines 1–270 now pass.
      Final third blocked on `math.fmod`, deferred to A5a.)

## Implementation notes

This plan is `blocked` until A0 (integer overflow wrapping) ships. A0 may
fix this entirely; if so, this plan can be closed without doing additional
work.

Triage workflow once A0 is merged:

1. Re-run `bitwise.lua` to confirm what (if any) assertions still fail.
2. If still failing, load the `triage-suite-failure` skill and follow the
   workflow:
   - Find the failing line via line-print.
   - Reduce to a unit test.
   - Classify (likely stdlib edge case in `Bitwise` module wrapping).
   - Fix, verify, ship.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/bitwise_test.exs
```

## Risks

- May reveal multiple distinct issues. If so, split into A5a, A5b, etc.

## Discoveries

A0 fixed the integer arithmetic wrap but **not** integer literal lexing or
string-to-number coercion. Three distinct issues surfaced while running
`bitwise.lua`:

1. **Hex integer literal wrapping (lexer).** `0xFFFFFFFFFFFFFFFF` was
   parsed as the unsigned int `18446744073709551615`. Per Lua 5.3 §3.1,
   hex integer literals overflow-wrap into the signed 64-bit range. Fixed
   inline in `Lua.Lexer.scan_hex_number` (didn't reach for `Lua.VM.Numeric`
   to keep the lexer free of VM-internal deps).

2. **`Value.parse_number` (string → number coercion).**
   - Same hex-overflow issue as the lexer.
   - Did not handle a leading `-` or `+` (e.g. `"-0xfffffffffffffffe"` →
     `nil`). `bitwise.lua` line 54-55 use this form for coercion via `&`.
   - Did not handle hex *floats* in strings (`"0xAA.0"`). `bitwise.lua`
     line 24-25 use them as bitwise operands. Fixed by adding hex-float
     parsing matching the lexer's existing hex-float scanner.

3. **Float → int coercion in bitwise ops (`Executor.to_integer!`).** Was
   doing unconditional `trunc/1`. Per Lua 5.3 §3.4.3, the float must
   represent an integer **exactly** and fit in the signed 64-bit range,
   otherwise the bitwise op must error. `bitwise.lua` line 59 explicitly
   tests this with `pcall`.

4. **`require` did not consult `package.preload` (stdlib).** The
   `bitwise.lua` test installs its own `bit32` implementation via
   `package.preload.bit32 = function () ... end` and then calls
   `require'bit32'`. Our `require` only checked `package.loaded` and the
   filesystem search path. Added a narrow `package.preload` lookup ahead
   of the path search. **Did not** introduce a full `package.searchers`
   table — that's a separate concern.

5. **`math.fmod` is not implemented.** `bitwise.lua` lines 278–279 use
   `math.fmod` to verify `bit32.lshift` numerically. Out of scope for a
   "bitwise" plan; deferred to **A5a**
   (`A5a-bitwise-suite-math-fmod.md`). With `math.fmod` in place,
   `bitwise.lua` is expected to pass end-to-end (no other gaps were found
   downstream of line 278 in line-by-line bisect; see `## What changed`).

## What changed

PR: #198

**Files touched:**

- `lib/lua/lexer.ex` — wrap hex integer literals to signed 64-bit
  in `scan_hex_number`. Inlined `wrap_int64/1` using existing `Bitwise`
  import; lexer stays VM-dep-free.
- `lib/lua/vm/value.ex` — rewrite `parse_number/1` to handle leading
  `-`/`+` signs (with negation through `Numeric.to_signed_int64`) and
  hex floats in strings (`"0xAA.0"`, `"0x1.8p3"`). Hex int strings now
  also wrap.
- `lib/lua/vm/executor.ex` — split `to_integer!/1` so the float and
  string-parsed-to-float paths go through `float_to_integer!/1`, which
  raises unless the float represents an integer exactly and is in the
  signed 64-bit range (Lua 5.3 §3.4.3).
- `lib/lua/vm/stdlib.ex` — `lua_require` now consults
  `package.preload[modname]` before falling through to the path search.
  Loader is called via `Executor.call_function`. Result caching matches
  `parse_and_execute_module` (sentinel `true` before call, replaced
  after).
- `test/lua/vm/bitwise_test.exs` — new file with 12 reduced-repro
  assertions, one per failing case found in `bitwise.lua` lines 8–62.

**Suite delta:** `bitwise.lua` was failing on its very first assertion
(line 8 area, no line info). Now runs cleanly through line 270, including
the entire `bit32` library block (lines 173–270). Final ~50 lines blocked
on `math.fmod`.

**Test count:** 1382 → 1394 (+12 from new bitwise_test.exs). 0 failures,
32 skipped (unchanged).

**Follow-ups opened:**

- `.agents/plans/A5a-bitwise-suite-math-fmod.md` — implement `math.fmod`
  to finish `bitwise.lua` end-to-end. Status `ready`.
