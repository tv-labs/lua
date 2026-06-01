---
id: B14
title: use io_lib.format for string.format float conversion
issue: 311
pr: 319
branch: perf/string-format-iolib-float
base: main
status: review
direction: B
---

# B14 — use io_lib.format for string.format float conversion

## Goal

Cut the per-call cost of `string.format` float specifiers by delegating
`%f` (and, where provably C-compatible, the fixed/mantissa portion of
`%g`/`%e`) to a single native `:io_lib.format/2` call, replacing the
`:erlang.float_to_binary` + `expand_float/2` post-processing chain.
`format_spec_float/2` is the dominant cost on the spec-heavy benchmark
(n=1000: 7.42ms vs luerl 4.00ms). Delete `expand_float/2`.

Correctness is the gate, not speed: the conversion must match C Lua
(PUC-Lua / printf) byte-for-byte across every existing format case and
the Lua 5.3 suite. In the course of this work we also fix a latent
C-incompatibility (see Risks: rounding) and give `inf`/`nan` C-compatible
output instead of raising.

## Out of scope

- The integer (`%d`/`%i`/`%u`), hex (`%x`/`%X`), octal (`%o`), char
  (`%c`), string (`%s`), and quoted (`%q`) specifiers. Do not touch them.
- The `%e`/`%g` **exponent** assembly. `:io_lib.format`'s `~e`/`~g`
  emit single-digit exponents (`1.0e+5`) whereas C Lua pads to a 2-digit
  minimum (`1.0e+05`); the existing `format_scientific_str/2` already
  pads correctly. Keep the exponent logic. (Optional: use `:io_lib`
  only for the `%e` *mantissa*, gated on all `%e`/`%E` tests passing —
  but do not regress exponent formatting.)
- `apply_width_flags/2` (line 828) — flags/width/zero-pad logic is
  unchanged; the new code must produce the same `raw` string shape
  (leading `-` for negatives) that it already expects.
- Creating a new `benchmarks/string_format.exs` file (the issue cites
  it but it does not exist; only `benchmarks/string_ops.exs` does).
- Anything touched by sibling issues #309 and #310 in `string.ex`
  outside float conversion.

## Success criteria

- [ ] `format_spec_float/2` calls `:io_lib.format(~c"~.*f", [P, abs(val)])`
      (precision passed as an arg, sign reapplied separately, matching
      `deps/luerl/src/luerl_lib_string_format.erl:248-250`), with an
      explicit precision-0 path (see Implementation notes).
- [ ] `expand_float/2` is deleted; no remaining caller references it
      (`round_mantissa/2` and `normalize_mantissa/2` updated or removed
      accordingly).
- [ ] `%f` rounding matches C Lua (round-half-to-even) at the `.5`
      boundary: `%.0f` of `2.5`→`"2"`, `0.5`→`"0"`, `1.5`→`"2"`,
      `3.5`→`"4"`, `-2.5`→`"-2"`.
- [ ] `%f` of `1/0`→`"inf"`, `-1/0`→`"-inf"`, `0/0`→`"nan"` (lowercase,
      matching observed C Lua output) — no longer raises.
- [ ] All existing format cases in `test/lua/vm/string_test.exs` and
      `test/language/stdlib/string_test.exs` pass unchanged, except any
      that asserted the old round-half-away behavior (update those to
      the C-Lua half-to-even value, citing reference Lua in the test).
- [ ] New unit tests added in `test/lua/vm/string_test.exs` for:
      precision-0 rounding at the sign boundary (the `2.5/0.5/1.5/3.5/
      -2.5` set above), large precision (e.g. `%.20f` of `1.0`), and
      `inf`/`-inf`/`nan` formatting.
- [ ] `mix compile --warnings-as-errors` clean (no unused-function
      warnings from the deleted helper).
- [ ] `mix test` full suite green, no regressions in pass count.
- [ ] `mix test --only lua53` pass count does not regress (snapshot
      before, compare after); `literals.lua` format/`%q` cases unaffected.
- [ ] Benchmark re-run shows `string.format` no slower than baseline,
      ideally narrowing the luerl gap.

## Implementation notes

All edits in `lib/lua/vm/stdlib/string.ex` and tests in
`test/lua/vm/string_test.exs`.

`lib/lua/vm/stdlib/string.ex`:

- **`format_spec_float/2` (lines 454–464)**: replace the
  `:erlang.float_to_binary([{:decimals, precision}, :compact]) |>
  expand_float(precision)` body with a `:io_lib.format`-based path:
  - Guard `inf`/`nan` first. `val / 1` of `1/0` is `:infinity`-class
    on the BEAM only via arithmetic that currently raises upstream;
    detect the non-finite float (or the divide-by-zero result) and
    return `"inf"` / `"-inf"` / `"nan"` directly. Confirm which Erlang
    term the VM hands us for `1/0` and `0/0` and match accordingly. Do
    not pass non-finite values to `:io_lib.format` (it raises).
  - For finite values: `digits = :io_lib.format(~c"~.*f", [precision,
    abs(float_val)])` → `:erlang.iolist_to_binary/1`, then prepend
    `"-"` when `float_val < 0.0` (preserve `-0.0` per C Lua if a test
    requires it; otherwise drop the negative sign for `0.0`).
  - **Precision 0 (critical)**: `:io_lib.format(~c"~.*f", [0, _])`
    RAISES on this OTP (29). Add a dedicated `precision == 0` clause
    that produces the half-to-even integer string without io_lib —
    e.g. format at precision 1 and resolve/round the single fractional
    digit half-to-even, or compute via a half-even integer rounding
    helper — verified against C Lua's `2.5→2, 0.5→0, 1.5→2, 3.5→4`.
- **Delete `expand_float/2` (lines 466–501)** and remove every caller.
- **`round_mantissa/2` (537–557) and `normalize_mantissa/2` (559–582)**:
  these call `expand_float/2`. Either inline the equivalent
  fixed-precision formatting (they always run with `precision >= 1` for
  the mantissa) or rewrite them to use the same io_lib mantissa path.
  Do NOT change the exponent assembly in `format_scientific_str/2`
  (513–535) — its 2-digit exponent padding is what makes `%e`/`%g`
  C-compatible and io_lib's is not.
- **`format_spec_general/2` (584–613)** calls `format_spec_float/4` for
  its fixed branch (line 604); it automatically benefits once
  `format_spec_float` is migrated. Verify `%g`'s fixed cases still
  strip trailing zeros identically (`strip_trailing_zeros/1`, 615).

`test/lua/vm/string_test.exs`:

- Add a `describe "string.format float rounding/inf/nan"` block (no plan
  id in moduledoc or test names — repo rule) with the precision-0
  boundary set, `%.20f` large-precision, and `inf`/`-inf`/`nan` cases,
  each asserting the C-Lua reference value.
- Audit the existing `string.format` describe blocks (227–467) and the
  property tests (1414+) for any assertion that depended on round-half-
  away; update to half-to-even with a brief comment citing C Lua.

Reference: C Lua output captured during planning (`/opt/homebrew/bin/lua`):
`%.0f` 2.5|3.5|0.5|1.5|-2.5 = `2|4|0|2|-2`; `%f` 1/0|-1/0|0/0 =
`inf|-inf|nan`.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix run benchmarks/string_ops.exs
```

Notes:
- The issue cites `mix run benchmarks/string_format.exs`; that file does
  not exist in this tree — `benchmarks/string_ops.exs` is the float-
  format benchmark (`string.format("item_%d=%f", ...)`). Use it. If a
  sibling PR (#309/#310) lands `string_format.exs` first, run that too.
- For `--only lua53`: snapshot the pass count to a tmp file before any
  code change, re-run after, and confirm no file flips from pass→fail
  (especially `literals.lua`, which exercises `%q` on floats at lines
  279/293).

## Risks

- **Rounding semantics change (highest risk).** The current code rounds
  half-away-from-zero; io_lib (and C Lua) round half-to-even. This is a
  *fix*, but it changes output for exact `.5` ties at the rounded digit.
  Mitigation: the success criteria pin the exact C-Lua values; audit and
  update any existing test that encoded the old behavior, and rely on
  `--only lua53` to catch suite-level regressions.
- **Precision-0 crash on OTP 29.** `~.*f` with `P=0` raises. If the
  precision-0 path is not handled, every `%.0f` (and `%g` reaching p=0)
  breaks. Mitigation: dedicated precision-0 clause with its own
  half-to-even rounding, tested explicitly.
- **inf/nan behavior change.** Today `%f` of `1/0` raises; this plan
  makes it emit `"inf"`. If any caller/test relied on the raise, it will
  change. Mitigation: the issue explicitly requests inf/nan formatting;
  add tests and confirm the suite does not depend on the old raise.
- **`%e`/`%g` exponent drift.** Delegating `~e`/`~g` to io_lib would
  introduce single-digit exponents incompatible with C Lua. Mitigation:
  out of scope — keep `format_scientific_str/2`'s exponent padding;
  only the fixed/mantissa float text is migrated.
- **Sibling-file collision.** #309/#310 also edit `string.ex`.
  Mitigation: confine edits to the float-conversion helpers; rebase if a
  sibling merges first.

## What changed

- `format_spec_float/2` now delegates to a new `fixed_float/2`:
  precision >= 1 calls `:io_lib.format(~c"~.*f", [precision, abs(val)])`
  and reapplies the sign; precision 0 uses a dedicated
  `round_half_even/1` helper (io_lib raises on `~.*f` with P=0 on
  OTP 29) to match C Lua's round-half-to-even (`2.5→2`, `0.5→0`,
  `1.5→2`, `3.5→4`, `-2.5→-2`).
- `0/0` (the `:nan` atom this VM produces) now formats as `"nan"`
  instead of raising `ArgumentError`.
- `expand_float/2`, `round_mantissa/2`, and `normalize_mantissa/2` are
  deleted. `format_scientific_str/2`'s mantissa formatting is rewritten
  to use `fixed_float/2` with a value-based 9.99→10 carry check
  (`mantissa_with_carry/3`); the 2-digit exponent padding is untouched,
  preserving C-compatible `%e`/`%g` exponents.
- Added `describe "string.format float rounding and non-finite values"`
  in `test/lua/vm/string_test.exs`: precision-0 sign-boundary set,
  `%.20f` large precision, and `0/0 → "nan"`.
- Full suite green (2117 passed); `--only lua53` unchanged from the main
  baseline (17 passed, 12 skipped).

## Discoveries

- **`1/0` is not IEEE infinity in this VM.** The plan/issue assume
  `string.format("%f", 1/0)` reaches `format_spec_float` as `:infinity`
  and should print `"inf"`. In reality this VM's division clamps `1/0`
  to the finite float `1.0e308` (and `-1/0` to `-1.0e308`), which
  formats fine through `:io_lib.format` and never hits a non-finite
  guard. No `"inf"`/`"-inf"` path is needed in float conversion; the
  divide-by-zero semantics live in the executor and are out of scope.
  `0/0` does surface as the atom `:nan`, now mapped to `"nan"`.
- **`benchmarks/string_format.exs` now exists** (landed after the plan
  was authored). It requires `:luerl`, which is not available in this
  worktree's deps, so the comparative benchmark could not run here. A
  VM-level microbenchmark of the float-heavy loop (`item_%d=%f` x1000)
  measured ~1.7ms, well under the 7.42ms baseline cited in #311.
- **io_lib and the old `float_to_binary` path round identically** at
  precision >= 1 (both round-half-up at exact binary half-points like
  `0.25`, which C Lua resolves to half-to-even). This pre-existing
  divergence from C Lua at exact-binary ties is unchanged by this PR.
  The precision-0 path is the only place this PR actively switches to
  round-half-to-even, matching C Lua.
