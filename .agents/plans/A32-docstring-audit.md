---
id: A32
title: Public API docstring audit — every public function carries its weight
issue: 266
pr: null
branch: docs/docstring-audit
base: main
status: in-progress
direction: A
unlocks:
  - "world-class docs" promise
  - mix hex.publish without warnings
---

## Goal

Every public function and module on the library's surface has a
docstring that:

1. Says what it does in one sentence.
2. Documents arguments and return values precisely.
3. Has at least one example block (doctest where reasonable).
4. Cross-links related functions.

Run `mix docs --warnings-as-errors` and fix every warning.

## Out of scope

- Internal modules (`Lua.VM.Executor`, `Lua.Compiler.*`,
  `Lua.Lexer`). They can have docstrings, but it's not blocking.
- Long-form guides (those go in `guides/`).
- Hex publish itself (that's the release plan).

## Success criteria

- [ ] Every public module has a `@moduledoc` that is not just the
      module name. Modules in scope:
      - [ ] `Lua`
      - [ ] `Lua.Chunk`
      - [ ] `Lua.API` (and any related behavior modules)
      - [ ] `Lua.RuntimeException`
      - [ ] `Lua.VM.TypeError`
      - [ ] `Lua.VM.RuntimeError`
      - [ ] `Lua.VM.AssertionError` (if public)
      - [ ] Any `Lua.Table`, `Lua.Closure`, `Lua.Userdata`,
            `Lua.NativeFunc` structs from A27.
- [ ] Every public function has `@doc` with:
      - [ ] One-sentence summary.
      - [ ] `## Arguments` and `## Returns` (or equivalent prose).
      - [ ] At least one `## Examples` block.
- [ ] At least 10 of those example blocks run as doctests
      (`mix test --include doctest` or whatever runs them).
- [ ] `mix docs --warnings-as-errors` exits 0.
- [ ] `@spec` is present on every public function.
- [ ] `@deprecated` annotations on anything we're removing in 1.0.
- [ ] `mix test` passes.

## Implementation notes

Audit pattern per module:

1. Open the module.
2. Read every `def` that isn't `defp`.
3. For each, check: is the docstring clear? Are args described?
   Is there an example?
4. Add or revise.
5. Add `@spec` if missing.

Lean on doctests where the example is small and deterministic. For
state-bearing examples, use the iex-style format and don't doctest
them.

### `mix docs --warnings-as-errors`

The current build has some doc warnings (unresolved cross-refs,
missing types). This plan fixes all of them. Add the flag to a CI
step so future PRs can't regress.

### Files

- `lib/lua.ex` — most touched.
- `lib/lua/chunk.ex` — exists, audit it.
- `lib/lua/api.ex` — audit.
- `lib/lua/runtime_exception.ex` — audit.
- `lib/lua/vm/*.ex` (public ones) — audit.
- (whatever A27 added) — audit.
- `mix.exs` — possibly tighten the `docs` config (logo, extras list,
  groups for modules).
- `.github/workflows/*` — add `mix docs --warnings-as-errors` to CI
  if not present.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix test
```

Manual: open `doc/index.html` in a browser, sanity-check the table
of contents and the rendered prose. The first-time-reading
experience should be coherent.

## Risks

- Adding `@spec` aggressively can surface dialyzer warnings the
  project hasn't been catching. Run `mix dialyzer` after and fix
  anything new before merging.
- Doctests are flaky if the output isn't deterministic. Stick to
  return-value assertions; avoid printing.
- "World-class docs" is subjective. The mechanical bar (every public
  function has a docstring + example + spec; mix docs is clean) is
  what we measure.

## Discoveries

(populated during implementation)
