---
id: B12
title: parse string.format flags once and dispatch on integer specifier
issue: 309
pr: 317
branch: perf/string-format-flags-bitmask
base: main
status: review
direction: B
---

# B12 — string.format flag bitmask + integer specifier dispatch

## Goal

Speed up the `string.format` per-specifier hot path in
`lib/lua/vm/stdlib/string.ex` by removing redundant per-site work, with
zero change to observable output:

1. **Parse flags once.** Today `parse_flags/2` collects the flag
   characters into a binary, and `apply_width_flags/3` re-scans that
   binary with `String.contains?(flags, "0")`, `String.contains?(flags,
   "-")` on *every* specifier application. Parse the flags exactly once
   at parse time into a small fixed-shape representation (a tuple of
   booleans, or a single integer mask) so the apply path reads
   precomputed fields instead of re-scanning a binary.
2. **Dispatch on an integer specifier.** Today `parse_specifier/1`
   returns the conversion character as a one-byte binary (`"d"`,
   `"f"`, …) and `apply_format_spec/2` dispatches with a `case` over
   string literals. Store and match the conversion char as an integer
   code point (`?d`, `?f`, …) so the `case` compiles to BEAM
   integer-pattern dispatch, which is faster than binary matching.

This mirrors Luerl's precomputed bitmask + `$d`-style integer dispatch
(`deps/luerl/src/luerl_lib_string_format.erl`). Expected to close ~10%
of the spec-heavy gap; stacks with the sibling string.format plans.

## Out of scope

- Any change to formatted output. This is a pure internal refactor; the
  rendered string for every input must be byte-for-byte identical.
- The per-specifier formatter bodies: `format_spec_integer/1`,
  `format_spec_unsigned/1`, `format_spec_float/2`,
  `format_spec_scientific/3`, `format_spec_general/3`,
  `format_spec_hex/2`, `format_spec_octal/1`, `format_char/1`,
  `format_spec_string/2`, `format_quoted/1`, and their helpers. Sibling
  plans #310 and #311 edit `string.ex` too; this plan must not touch
  those bodies. Only the flag representation, the specifier token type,
  and the dispatch/padding sites that consume them change.
- Starting to honor flags that are currently parsed-and-discarded.
  `parse_flags/2` accepts `-+ 0#`, but only `0` and `-` are consulted
  downstream; `+`, space, and `#` are parsed and ignored today. The
  refactored representation must preserve that exact behavior (it may
  carry those bits, but they must not change output).
- `string.format` argument validation, error messages, or arity.
- Any other stdlib function or any file other than
  `lib/lua/vm/stdlib/string.ex`.

## Success criteria

- [ ] `string.format` produces byte-for-byte identical output for all
      existing tests (no regression in
      `test/lua/vm/stdlib/string_test.exs`).
- [ ] Flags are parsed exactly once, at parse time, into a fixed-shape
      representation (boolean tuple or integer mask). No
      `String.contains?(flags, ...)` re-scan remains on the
      per-specifier apply path (`apply_width_flags/3`).
- [ ] The conversion specifier is stored and matched as an integer
      code point (`?d`/`?f`/…), not a one-byte binary; the
      `apply_format_spec/2` `case` dispatches on integers.
- [ ] Flags currently parsed-but-ignored (`+`, space, `#`) remain
      ignored — output unchanged.
- [ ] `mix compile --warnings-as-errors` is clean.
- [ ] Full `mix test` passes with no regressions.
- [ ] `mix run benchmarks/string_format.exs` runs to completion; record
      before/after numbers in the PR description.

## Implementation notes

All edits are confined to `lib/lua/vm/stdlib/string.ex`, in the format
parser and dispatch region (roughly lines 365–434 and 828–859):

1. **Flag representation.** Change `parse_flags/2` (line 374) to emit a
   fixed-shape value instead of accumulating a binary. Two acceptable
   shapes (pick one and keep it internal):
   - a tuple/struct of booleans, e.g. `{minus?, zero?, plus?, space?,
     hash?}`, or
   - a single integer mask with named bit constants.
   Whichever is chosen, it is computed once during
   `parse_format_spec/1` (line 366) and threaded through the
   `{flags, width, precision, specifier}` tuple unchanged in arity/shape
   at the tuple level (only the `flags` element's type changes).

2. **Specifier as integer.** Change `parse_specifier/1` (line 404) from
   `{<<c>>, rest}` to `{c, rest}` (the raw integer code point). Update
   the empty-string clause (line 406) unchanged. Rewrite the
   `apply_format_spec/2` `case` (lines 415–431) to match integer code
   points: `?d`, `?i`, `?u`, `?f`, `?e`, `?E`, `?g`, `?G`, `?x`, `?X`,
   `?o`, `?c`, `?s`, `?q`, with the `_ ->` fallback raising the same
   `"invalid option '%#{specifier}'"` error. NOTE: the interpolation
   `#{specifier}` currently relies on `specifier` being a binary; with
   an integer it must be rendered back to its character for the error
   message (e.g. `<<specifier>>` or `List.to_string([specifier])`) so
   the error text is unchanged.

3. **Padding path.** Rewrite `apply_width_flags/3` (line 828) to read
   the precomputed flag fields instead of `String.contains?(flags,
   "0")` (line 842), `String.contains?(flags, "-")` (line 846). The
   pad-char selection (`"0"` when zero-flag set and minus-flag unset,
   else `" "`), left-justify branch, and the sign-aware zero-pad branch
   (line 852, `"-" <> pad <> binary_part(...)`) must remain semantically
   identical.

4. Run `mix format` after edits. Keep the `# Format string parser`
   comments accurate; do not add any plan-id references in source.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test test/lua/vm/stdlib/string_test.exs
mix test
mix run benchmarks/string_format.exs
```

Capture the `benchmarks/string_format.exs` output before and after the
change and paste the comparison into the PR description. The
`string_test.exs` run is the primary correctness gate (output
unchanged); the full `mix test` run guards against any caller of
`string.format` elsewhere in the suite.

## Risks

- **Silent output drift.** The dispatch and flag-handling rewrite could
  subtly change a padding or specifier edge case. Mitigation: the
  refactor preserves every branch one-to-one; `string_test.exs` plus
  full `mix test` are the gate. If a case is thin in coverage (e.g. the
  zero-pad-with-sign branch), confirm an existing test exercises it
  before relying on green.
- **Error-message regression.** The invalid-option error interpolates
  the specifier; switching it to an integer requires re-rendering the
  character so `'%z'`-style messages stay identical. Called out in
  Implementation note 2.
- **Sibling-file collision.** #310 and #311 also edit `string.ex`. This
  plan stays inside the flag-parsing / specifier-dispatch region and
  does not touch the `format_spec_*` formatter bodies, minimizing merge
  conflicts. If a sibling lands first, rebase and re-confirm the
  apply-path region is still as described.
- **No measurable win.** Per the Direction B findings, BEAM dispatch
  refactors do not always pay off. If the benchmark shows no
  improvement, the change is still a correctness-neutral simplification
  (one flag parse instead of N re-scans); ship it on those grounds and
  record the measured delta honestly in the PR.

## What changed

Implemented in `lib/lua/vm/stdlib/string.ex` (PR #317):

- `parse_flags/2` now folds the flag characters into an integer bitmask
  in a single pass (`@flag_minus`, `@flag_zero`, `@flag_plus`,
  `@flag_space`, `@flag_hash`) instead of accumulating a binary;
  `parse_format_spec/1` seeds it with `0`. `+`, space, and `#` are still
  carried but unconsulted, preserving today's ignore-them behavior.
- `parse_specifier/1` returns the conversion char as a raw integer code
  point; `apply_format_spec/2` dispatches on `?d`/`?i`/.../`?q` integer
  patterns. The invalid-option error re-renders the char with
  `<<specifier>>` so the message text is byte-for-byte identical.
- `apply_width_flags/3` reads `flags &&& @flag_minus` / `@flag_zero`
  instead of `String.contains?/2`, removing the per-specifier re-scan
  from the padding path. All padding branches are preserved one-to-one.
- Added `import Bitwise` for `|||` / `&&&`.

Verification: `mix test test/lua/vm/string_test.exs` (152 passed),
full `mix test` (2114 passed, 19 skipped, 1 excluded),
`mix compile --warnings-as-errors` clean. Benchmark (Apple M4, lua chunk)
showed ~+17% / +30% / +23% ips across the three workloads; the
width-flagged path (the one that carried the re-scan) gained the most.

### Deviations from plan

- The plan's verification named `test/lua/vm/stdlib/string_test.exs`,
  which does not exist; the format coverage is in
  `test/lua/vm/string_test.exs`. Used that file plus full `mix test`.
- The benchmark's optional `luaport` dep needs C Lua headers (absent in
  this environment) and its dep-compile aborts `mix run` before the
  runtime skip fires. Numbers were captured with `luaport` temporarily
  excluded from `mix.exs` for the bench run only; `mix.exs` is unchanged
  in the PR.
