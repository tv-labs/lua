---
id: A9b
title: Fix pattern-engine character classes blocking pm.lua line 122+
issue: null
pr: null
branch: fix/pm-suite-pattern
base: main
status: ready
direction: A
unlocks:
  - pm.lua (continuation of A9a)
---

## Goal

Make the second wave of `pm.lua` assertions pass. With A9a's executor
fix landed, `pm.lua` now reaches line 122 where `strset('[\200-\210]')`
fails — the pattern engine appears to drop matches for character-class
patterns over the full byte range (and possibly other character-class
edge cases). Fix the pattern engine bug(s), advance pm.lua, and ideally
move the suite test from `@skipped_tests` to `@ready_tests`.

## Out of scope

- Executor / register-tuple work (covered by A9a).
- Lexer escape work (covered by A9).
- Reworking the pattern engine architecturally — make the smallest fix
  that gets the failing class of asserts passing.

## Success criteria

- [ ] `string.gsub("abcde", "[a-c]", fn)` invokes the callback with
      `"a"`, `"b"`, `"c"` — minimal repro of the strset failure.
- [ ] `strset('[a-z]') == "abcdefghijklmnopqrstuvwxyz"` passes.
- [ ] `strset('[\200-\210]')` returns 11 bytes as in PUC-Lua.
- [ ] `pm.lua` passes end-to-end OR the next failure is documented and
      split into A9c.
- [ ] If pm.lua passes end-to-end, move it from `@skipped_tests` to
      `@ready_tests` in `test/lua53_suite_test.exs`.
- [ ] Unit tests in `test/lua/vm/string_test.exs` (or
      `test/lua/vm/stdlib/pattern_test.exs` if it exists) covering the
      fixed classes.
- [ ] `mix test` passes (≥ current count, no regressions).

## Implementation notes

Minimal repro (confirmed against this branch after A9a):

```lua
local s = "abcde"
local res = {s=''}
string.gsub(s, '[a-c]', function (c) res.s = res.s .. c end)
-- res.s is "" but should be "abc"
```

Even simpler: `string.gsub("abc", "[a-c]", "X")` should return `"XXX"`.

Investigate `lib/lua/vm/stdlib/pattern.ex` — likely culprits:

- Character-class set matching (`[...]` ranges) when invoked through
  `gsub` rather than `find`/`match`.
- The interaction between the gsub callback path and the captured
  range bounds.

Check: does `string.match("abc", "[a-c]")` already work? If yes, the
bug is gsub-specific. If no, the bug is in core class compilation.

Cross-reference A9's discoveries (1–5) — the lexer/escape and
position-capture fixes there are now baseline.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/string_test.exs
```

## Risks

- Pattern engine has many corner cases; fixing class-set matching may
  regress other patterns. Run the existing string tests as guardrails.
- Lua patterns are NOT regexes. Range semantics use byte values, not
  Unicode codepoints.

## Discoveries

(populated during implementation)
