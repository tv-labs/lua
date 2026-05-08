---
id: A31
title: README rewrite for 1.0 positioning, quickstart, and tour
issue: null
pr: null
branch: docs/readme-rewrite
base: main
status: blocked
direction: A
unlocks:
  - "first-impression" of the library on Hex/GitHub
---

## Blocked on

- A30 — README links to examples; those need to exist first.

## Goal

Rewrite the README for the 1.0 audience. The current README is
serviceable but reads like internal docs. The 1.0 README should:

1. **Position** in one paragraph: native Elixir Lua 5.3, no NIFs, for
   sandboxed embedding.
2. **Quickstart** that compiles and runs in 30 seconds.
3. **Tour** of the killer features: error messages with source/line,
   metamethods, userdata, sandboxing.
4. **Status & coverage** honestly: which parts of Lua 5.3 are
   supported, which suite files pass, what's deliberately not
   supported (e.g. `os.execute`).
5. **Links** to examples, guides, and the changelog.

## Out of scope

- Long-form tutorials (those go in `guides/`).
- API reference content (that's `mix docs`).
- Marketing copy or testimonials.

## Success criteria

- [ ] README opens with a one-sentence pitch and a one-paragraph
      "what is this".
- [ ] Quickstart section: install snippet for `mix.exs`, then a 5-10
      line "your first Lua eval" block that demonstrably works.
- [ ] Tour section: 4-6 short subsections with code snippets:
      - [ ] Error messages with source/line.
      - [ ] Calling Elixir functions from Lua.
      - [ ] Userdata.
      - [ ] Sandboxing (default and customization).
      - [ ] (optional) Metatables and metamethods.
- [ ] "Coverage and status" section: lists supported subsystems and
      explicitly names what's not in scope (`os.execute`, etc.). If
      the suite gate from A20 lands first, link to that decision.
- [ ] "Examples" section: links every file in `examples/` with a
      one-line description.
- [ ] "Compatibility" or "vs Luerl" subsection: brief honest
      comparison. Errors are better; perf is comparable
      (post-perf-track); pure-Elixir; no shared mutable state.
- [ ] All snippets in the README run as-is (or are doctested in
      `lib/lua.ex` and the README references them).
- [ ] Project status badge / Hex badge present.
- [ ] `mix docs` still builds clean.

## Implementation notes

Keep the README under ~250 lines. Push depth to `guides/` and
`examples/`. The README is the trailer, not the movie.

### Suggested structure

```
# Lua

[badges]

One-sentence pitch.

One-paragraph "what is this".

## Installation

mix.exs snippet.

## Quickstart

5-10 line "first Lua eval" example.

## Tour

### Error messages with source and line
### Calling Elixir from Lua
### Userdata
### Sandboxing
### Compatibility with Lua 5.3

## Coverage

What's supported, what's not, link to suite status.

## Examples

Links to `examples/*.exs`.

## Documentation

Link to `mix docs` output / hexdocs.

## License
```

### Files

- `README.md` — full rewrite.
- `guides/coverage.md` (new, optional) — long-form coverage doc if
  the README list gets unwieldy.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix docs
```

Manual: read the README top-to-bottom from a "first time looking at
this library" mindset. Does the path from "should I use this?" to
"my first eval" take more than 60 seconds? If yes, tighten.

## Risks

- Drift between snippets in README and actual API. Mitigation: the
  snippets in the Tour should mirror examples in `examples/` 1:1, so
  there's only one place to update.
- "Coverage" section can become a moving target. Defer the precise
  numbers until A20-A24 triage clusters land. State the gate
  qualitatively until then.

## Discoveries

(populated during implementation)
