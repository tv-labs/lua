---
id: A45
title: "Bisect constructs.lua short-circuit harness at level=4; pin green, narrow skip"
issue: 281
pr: null
branch: fix/short-circuit-level4
base: main
status: in-progress
direction: A
unlocks:
  - constructs.lua
---

# Goal

Bisect the dynamic short-circuit harness at `constructs.lua:287-298` at
`level=4`, find the smallest failing `((((a op b) op c) op d) op e)`
composition of `and`/`or`, reduce to a one-line repro, and classify the
suspected executor short-circuit edge case (register aliasing under
conditional-jump bytecode, or a `not` precedence wrinkle). Fix the
executor bug if tractable and land green; otherwise narrow the
`constructs.lua` skip range with a precise reason + issue and document
the reduced repro.

# Out of scope

- Implementing the `os` library (`os.time`).
- `debug.getinfo(..., "n").name` call-stack name introspection.
- Any feature beyond the short-circuit executor path.

# Findings

The suspected executor short-circuit bug does **not** reproduce. A faithful
replica of the harness — `createcases` up to `level=4`, the
`if %s then IX = true end; return %s` program template, run through the
suite-runner `load` — passes **all 204105 cases** for both `_ENV.GLOB1 = 0`
and `_ENV.GLOB1 = 1`. The `and`/`or` `test_and`/`test_or` CPS path in the
executor evaluates deep compositions correctly, including the
`not(<expr>)` wrapping the harness applies.

The real blockers gating lines 225-313 are upstream of the harness and
unrelated to short-circuiting:

1. **Line 226** `assert(debug.getinfo(1, "n").name == 'F')` — the VM's
   `debug.getinfo` always returns `name = nil`; call-stack name
   introspection is unimplemented.
2. **Line 237** `_ENV.GLOB1 = math.floor(os.time()) % 2` — `os.time` is
   nil (the `os` library is essentially unimplemented). `GLOB1` then
   feeds line 248's `print(... .. _ENV.GLOB1 .. ...)` and the harness
   leaf `(0==_ENV.GLOB1)`, so line 237 cannot simply be blanked.

Both gate the harness from ever executing inside the suite, which is why
the range was previously (incorrectly) attributed to a "load()-driven
short-circuit harness" edge case.

# Success criteria

- A regression test under `test/lua/vm/` pins the level-4 short-circuit
  harness as green, so a future executor regression at depth 4 is caught.
- The `constructs.lua` skip entry carries a precise, blocker-by-blocker
  reason and references issue #281, replacing the stale
  "load()-driven short-circuit harness" wording.
- `mix test` and `mix test test/lua53_suite_test.exs --only lua53` pass.

# Implementation notes

- Regression test drives `createcases` up to level 4 against the
  in-process VM via `Lua.eval!` with `load` available, asserting both the
  return value and the `IX` side-effect for every case.
- Skip-range reason rewritten to name the two upstream blockers
  (`debug.getinfo name`, `os.time`) and to record that the short-circuit
  harness itself is verified green by the regression test.

# Verification

- `mix format`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix test test/lua53_suite_test.exs --only lua53`

# Risks

- Low. No executor code changes; the change is a regression test plus a
  documentation-accurate skip reason. The harness behaviour is already
  correct, so the test should stay green.
