---
id: A17
title: Lexer accepts vertical tab and form feed as inter-token whitespace
issue: 205
pr: null
branch: fix/lexer-vt-ff-whitespace
base: main
status: in-progress
direction: A
unlocks:
  - literals.lua  # partial — unblocks line 11; full pass depends on later content
---

## Goal

Make `Lua.Lexer.tokenize/1` recognize `\v` (vertical tab, 0x0B) and `\f`
(form feed, 0x0C) as inter-token whitespace, per Lua 5.3 reference
manual §3.1. Same fix in `skip_whitespace_in_string/2` so the `\z`
escape consumes them too.

## Out of scope

- The `Lua.new(exclude: [..., [:load], ...])` quirk where `load` remains
  callable despite being in the exclude list. Surfaced during triage,
  not in scope here. File a follow-up issue if desired — the suite
  runner is currently relying on `load` being available, so flipping
  this is independently risky.
- Promoting `literals.lua` from `@skipped_tests` to `@ready_tests` in
  `test/lua53_suite_test.exs`. That depends on whether the rest of the
  file passes after this fix; if it does, it's a one-line follow-up
  plan, not part of this PR.
- Any other `literals.lua` failures past the line-11 assertion. Pin a
  unit test for the line-11 repro and stop.
- Other lexer/parser issues unrelated to whitespace.

## Success criteria

- [ ] `Lua.Lexer.tokenize("x\v=1")` returns `{:ok, [...]}` with three
      tokens (`x`, `=`, `1`) plus EOF.
- [ ] `Lua.Lexer.tokenize("x\f=1")` ditto.
- [ ] `Lua.Lexer.tokenize("x \v\f = \t\r 'a\\0a' \v\f\f")` parses
      cleanly (this is the inner source from `literals.lua:11`).
- [ ] New unit tests in `test/lua/lexer_test.exs` under
      `describe "whitespace"`:
  - `\v` between tokens
  - `\f` between tokens
  - mixed VT/FF/space/tab/CR
  - `\z` followed by `\v`/`\f` consumes them (string escape path)
- [ ] `mix test` passes with no regressions; total count strictly
      greater than current baseline by the number of new tests added.
- [ ] `mix test --only lua53` passes (5 ready, no regressions).
- [ ] Standalone repro from the triage script:
      `mix run /tmp/triage_dostring.exs` shows the `dostring` call
      compiling and `len: 3` printing.

## Implementation notes

The lexer is in `lib/lua/lexer.ex`. Two surgical changes:

1. Line ~71, `do_tokenize/3` whitespace clause:

   ```elixir
   defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?\s, ?\t] do
   ```

   Change to:

   ```elixir
   defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?\s, ?\t, ?\v, ?\f] do
   ```

2. Line ~499, `skip_whitespace_in_string/2`:

   Add two new clauses parallel to the existing `?\s` and `?\t` ones:

   ```elixir
   defp skip_whitespace_in_string(<<?\v, rest::binary>>, pos) do
     skip_whitespace_in_string(rest, advance_column(pos, 1))
   end

   defp skip_whitespace_in_string(<<?\f, rest::binary>>, pos) do
     skip_whitespace_in_string(rest, advance_column(pos, 1))
   end
   ```

Position tracking: `\v` and `\f` are NOT line terminators in Lua, so
they should advance the column by 1 and leave the line number alone —
same treatment as space/tab. Do not touch the `?\n` / `?\r` clauses.

Lua 5.3 §3.1 lists the full whitespace set: ` \t\n\v\f\r`. Newline and
CR are already handled (they advance the line counter). VT and FF are
the gap.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/lexer_test.exs
mix test --only lua53
```

Optional spot check:

```bash
mix run /tmp/triage_dostring.exs   # should print "x = a a   len: 3"
```

## Risks

- Low. The change widens an accept-set in a single-byte branch with no
  shared state. No reasonable Lua program uses `\v`/`\f` as significant
  bytes outside string literals — string literals are tokenized through
  a separate code path that doesn't go through `do_tokenize/3`.
- Position tracking: VT/FF are not standardized as line terminators in
  any reference I'm aware of, so column-advance is correct. The Lua
  reference compiler treats them as plain whitespace; our test suite
  doesn't pin column positions against VT/FF source so there's no
  existing assertion to invalidate.
- The `\z` change is effectively dead code unless someone writes
  `"foo\z\vbar"` — but it's the right fix and is one line each.
