---
id: B13
title: defer string.format width padding to iolist
issue: 310
pr: 316
branch: perf/string-format-width-iolist
base: main
status: review
direction: B
---

# B13 — defer string.format width padding to iolist

## Goal

Eliminate the per-specifier binary allocation in `string.format` width
padding. `apply_width_flags/3` currently builds
`String.duplicate(pad_char, deficit)` and concatenates the padding onto
the formatted value with `<>`, producing a fresh binary for every
width-flagged specifier. Make `apply_width_flags/3` return an **iolist**
(`[pad, str]` for right-justify, `[str, pad]` for left-justify) and let it
flow through the iolist accumulator introduced in PR #299, so the padded
result is materialised exactly once at the top level via
`IO.iodata_to_binary/1`.

This is a **performance-only** change. Output must be byte-identical to
the current implementation for every input. The benchmark target is the
width-flagged case in `benchmarks/string_format.exs` (n=1000), currently
~2.03× slower than luerl; this closes most of that gap by removing the
intermediate per-specifier binaries.

## Out of scope

- Any change to formatting *semantics* — width/precision/flag behavior,
  rounding, sign handling, octal/hex/float output. Bytes out are unchanged.
- The numeric formatting helpers (`format_spec_integer`,
  `format_spec_float`, `format_spec_hex`, etc.). They keep returning
  binaries; only the width/padding layer changes shape.
- `format_string/3` / `format_directive/3` parsing logic, the literal
  fast path, and the `:binary.split/2` chunking from PR #299. Those stay
  as they are; the iolist simply threads through the existing
  `[acc, str]` append.
- Any other code in `string.ex`. **Sibling-file warning:** issues #309
  and #311 also edit `lib/lua/vm/stdlib/string.ex`. This plan touches ONLY
  the width-padding code (`apply_width_flags/3` and its single call site)
  and must not stray into other specifiers, patterns, or helpers.
- Pre-padding the value differently for codepoint vs byte width — width is
  measured in bytes today and stays measured in bytes.

## Success criteria

- [ ] `apply_width_flags/3` returns an iolist (e.g. `[pad, str]` /
  `[str, pad]`) instead of a concatenated binary; the no-padding branch
  may continue to return `str` unchanged (a bare binary is a valid iolist
  element).
- [ ] The padded result threads through `format_string/3` /
  `format_directive/3` without an intermediate `IO.iodata_to_binary` per
  specifier; materialisation happens only at the `format_string/3` base
  case via `IO.iodata_to_binary/1`.
- [ ] Output is byte-identical for left-justify (`-`), right-justify
  (default), space padding, and zero padding — including the zero-padded
  negative-number case where the sign must stay leftmost
  (`%05d` of `-7` -> `-0007`).
- [ ] Byte-width semantics for multibyte `%s` are preserved
  (e.g. `format("%6s", "café")` -> `" café"`, one fill byte).
- [ ] `mix test test/lua/vm/stdlib/string_test.exs` passes with no
  regressions.
- [ ] Full `mix test` passes with no regressions.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix run benchmarks/string_format.exs` shows the width-flagged
  (n=1000) case improved versus the pre-change run (recorded in the PR).

## Implementation notes

Single file: `lib/lua/vm/stdlib/string.ex`.

1. `apply_width_flags/3` (lines ~828-859):
   - Keep the byte-based `deficit = width - byte_size(str)` calculation and
     the existing multibyte comment that explains width is measured in
     bytes (lines 831-835).
   - When `deficit <= 0`, return `str` unchanged.
   - When padding is needed, build `pad = String.duplicate(pad_char,
     deficit)` exactly as today, but **return an iolist instead of `<>`
     concatenation**:
     - Left-justify (`-` flag): `[str, pad]`.
     - Right-justify, zero-pad with leading sign: `["-", pad,
       binary_part(str, 1, byte_size(str) - 1)]` (sign stays leftmost).
     - Right-justify otherwise: `[pad, str]`.
   - The `String.duplicate/2` call for the pad itself is retained; the win
     is removing the outer `<>` that copies `str` + `pad` into a new
     binary every specifier.

2. Caller in `apply_format_spec/2` -> `format_directive/3` (lines ~358-363,
   413-434):
   - `apply_format_spec/2` returns whatever `apply_width_flags/3` returns
     (now an iolist or bare binary). No call-site rewrite is required
     because `format_directive/3` already appends with `[acc, str]`, and
     an iolist `str` is a valid iolist element. Verify this path; do not
     add a redundant flatten.
   - The base case in `format_string/3` (line 347) already calls
     `IO.iodata_to_binary([acc, literal])`, which materialises the whole
     nested iolist — including the new padding cells — exactly once.

3. Run `mix format` after the change.

The plan id (B13) belongs in the commit body (`Plan: B13`) and the PR
description only — never in source files, comments, or the commit/PR
scope. Commit/PR scope is `stdlib`.

## Verification

```
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/stdlib/string_test.exs
mix test
mix run benchmarks/string_format.exs
```

For the benchmark: capture the width-flagged (n=1000) timing on `main`
before the change and after the change, and record both in the PR body to
demonstrate the improvement (target: close most of the ~2.03× luerl gap).

## Risks

- **Output drift.** The change must be byte-for-byte transparent. Highest
  risk is the zero-padded-with-sign branch; the existing
  `string_test.exs` cases plus full `mix test` guard this. If any
  formatting test changes output, stop — the iolist shape is wrong.
- **Sibling-file collision.** #309 and #311 also touch `string.ex`. Stay
  strictly inside `apply_width_flags/3` and its single call site to
  minimise merge conflict surface; do not reformat or refactor unrelated
  regions.
- **Accidental early flatten.** Calling `IO.iodata_to_binary/1` (or `<>`)
  inside `apply_width_flags/3` or `apply_format_spec/2` would defeat the
  optimization. Materialisation must happen only at the `format_string/3`
  base case.
- **No expected suite-count change.** This is perf-only; `mix test`
  pass/fail counts should be identical before and after.

## What changed

- `lib/lua/vm/stdlib/string.ex`: `apply_width_flags/3` now returns an
  iolist for the padded cases — `[str, pad]` (left-justify),
  `["-", pad, binary_part(...)]` (zero-pad with leading sign), and
  `[pad, str]` (right-justify default). The no-padding branch still
  returns the bare `str`. The outer `<>` concatenation that copied
  `str` + `pad` into a new binary per specifier is gone; the result
  threads through the existing `[acc, str]` append in
  `format_directive/3` and is materialised once at the
  `format_string/3` base case via `IO.iodata_to_binary/1`. Single call
  site (`apply_format_spec/2`) needed no change.
- `.agents/plans/B13-string-format-width-iolist.md`: lifecycle commits.

Verification: `mix test` 2114 passed / 19 skipped / 1 excluded (identical
to pre-change). String coverage `test/lua/vm/string_test.exs` 152 passed.
Output byte-identical across left/right/space/zero padding, zero-pad-with-sign
(`%05d` of `-7` -> `-0007`), and multibyte `%s` (`%6s` of `"café"` -> `" café"`).
Width-flagged benchmark (n=1000): ~3.88 ms/call -> ~3.39 ms/call (~13% faster).

Discovery: the plan named `test/lua/vm/stdlib/string_test.exs`, which does
not exist; string.format coverage lives in `test/lua/vm/string_test.exs`.
No scope change.
