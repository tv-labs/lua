---
id: A9b
title: Fix pattern-engine character classes blocking pm.lua line 122+
issue: null
pr: 190
branch: fix/pm-suite-pattern
base: main
status: review
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

The plan's "minimal repro" was misleading: `string.gsub("abc", "[a-c]", "X")`
already worked end-to-end. The character-class compiler and matcher were
fine. The actual bug was that the **gsub-with-function-callback path
discarded the threaded VM state**. The lambda built in `string.ex` for
Lua-closure / native-func replacements called `Executor.call_function`
and pattern-matched `{results, _state}`, throwing away the new state. So
upvalue mutations and table writes inside the callback silently no-op'd.
That explains why `string.gsub(s, '[a-c]', function(c) res.s = res.s .. c end)`
returned `""`: the callback ran, but its state changes never reached
the surrounding script.

Fixes landed in this PR (in roughly the order they were uncovered):

1. **State threading through `gsub` callbacks.** Added
   `Pattern.gsub_stateful/5` that takes a 2-arity `(args, state) ->
   {value, state}` replacement and threads `state` through every match.
   `string.ex` now uses this for closure/native/table replacements;
   string replacements stay state-pass-through. The legacy `Pattern.gsub/4`
   API is preserved for any external callers but documented as
   non-state-threading. Resolves SC1/SC2/SC3 immediately.

2. **`%z` and `%Z` character classes.** Lua 5.3's reference manual
   carries them over from 5.1; PUC-Lua treats `%z` as the byte 0 and
   `%Z` as its complement. Our matcher had no clause and fell through
   to the literal-character case, so `%Z` matched literal `Z`. Added
   the two clauses to `match_char_class/2`. This unblocked pm.lua
   line 131 (`strset('%Z') == strset('[\1-\255]')`).

3. **Capture ordering for nested groups.** Captures are numbered by
   the position of the opening `(`, but the matcher accumulated closed
   captures by close time — so `(((.).).* (%w*))` returned innermost
   first. Refactored: `captures` is now a list in opening order with
   entries tagged `{:open, start_pos}` while in flight and
   `{:done, value}` once closed. `cstack` holds indices into that list,
   so capture-end can look up and replace by index. Position captures
   record `{:done, pos+1}` directly. Updated backref to match the new
   wrapper. This fixed pm.lua line 140.

4. **Position captures in replacement strings.** `replace_captures`
   appended capture values via binary `<>`, but position captures are
   integers. Erlang iodata flattening would have reinterpreted them
   as raw bytes. Added `capture_to_binary/1` that converts integers
   to digit strings. Fixed pm.lua line 155.

5. **`%1` with no captures means whole match.** PUC-Lua quirk: when
   the pattern has no captures, `%1` aliases `%0`. We were returning
   `""`. Special-cased `idx == 1 and captures == []`. Fixed pm.lua
   line 158.

6. **Lua 5.3.3 empty-match-skip rule for `gsub`.** After a non-empty
   match, an empty match starting at the same position must not fire
   a replacement — otherwise `string.gsub("a b cd", " *", "-")`
   produces `"-a--b--c-d-"` instead of `"-a-b-c-d-"`. Threaded a
   `skip_empty?` flag through `gsub_from`. Set the flag only after
   a non-empty match (so a leading empty match like `^` still fires
   at end-of-string). Fixed pm.lua line 167.

7. **`gmatch` lastmatch tracking.** PUC's `gmatch_aux` records the end
   position of the last returned match and skips a subsequent match
   whose end equals that. Without it, `()%s*()` over `"a  \nbc\t\td"`
   returned 7 results instead of 5 and the test loop produced
   `"-a--b-c--d-"`. Added a `lastmatch` parameter to `gmatch_from`.

After these fixes pm.lua progresses from line 87 (where it failed
before A9b) past line 166. **It then hits a separate VM bug**: a
`do` block containing a generic `for ... in ... do ... end` loop
raises "bad argument in arithmetic expression" before the loop body
runs. The same loop outside a `do` block works fine. This is not a
pattern-engine issue and is out of scope for A9b; it should be split
into A9c.

Minimal repro of the follow-up bug:

```lua
do
  for k, v in pairs({a=1, b=2}) do
    print(k, v)
  end
end
```

## What changed

PR: [#190](https://github.com/tv-labs/lua/pull/190)

Files touched:
- `lib/lua/vm/stdlib/pattern.ex` — six pattern-engine fixes (state-
  threading gsub, %z/%Z, capture order, position-capture coercion,
  %1-with-no-captures, empty-match-skip rule for both gsub and gmatch).
- `lib/lua/vm/stdlib/string.ex` — switch to `Pattern.gsub_stateful/5`
  for closure / native / table replacements.
- `test/lua/vm/string_test.exs` — eight new regression tests covering
  each fix.

Suite delta: pm.lua remains in `@skipped_tests` (4/24 ready, unchanged)
until A9c lands. Unit tests: 1346 → 1354, 0 regressions.

Follow-up: A9c should investigate the `do`-block + `for-in` VM bug
documented above before pm.lua can move to `@ready_tests`.
