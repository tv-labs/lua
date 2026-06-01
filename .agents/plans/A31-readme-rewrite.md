---
id: A31
title: README rewrite for 1.0 positioning, quickstart, and tour
issue: 265
pr: 298
branch: docs/readme-rewrite
base: main
status: review
direction: A
unlocks:
  - "first-impression" of the library on Hex/GitHub
---

## Goal

Rewrite the README for the 1.0 audience. The current README is
serviceable but reads like internal docs. The 1.0 README should:

1. **Position** in one paragraph: native Elixir Lua 5.3, no NIFs / no C
   / no Erlang runtime dependency, for sandboxed embedding.
2. **Quickstart** that compiles and runs in 30 seconds.
3. **Tour** of the killer features: error messages with source/line,
   calling Elixir from Lua, userdata, sandboxing, metatables.
4. **Status & coverage** honestly: which parts of Lua 5.3 are
   supported, which suite files pass, what's deliberately not
   supported (e.g. `os.execute`, file I/O).
5. **Links** to examples, guides, and the changelog.

## Out of scope

- Long-form tutorials (those live in `guides/`).
- API reference content (that's `mix docs` / hexdocs).
- Marketing copy or testimonials.
- Creating the `examples/` files themselves — that is plan A30,
  shipping in a sibling PR. This plan only *links* to those paths.
- Splitting coverage into `guides/coverage.md` (deferred; only do it
  if the inline list becomes unwieldy, and note in Discoveries).

## Success criteria

- [ ] README opens with a one-sentence pitch and a one-paragraph
      "what is this".
- [ ] The `<!-- MDOC !-->` marker is preserved in its current position
      so `Lua`'s `@moduledoc` (sourced from this file in `lib/lua.ex`)
      still resolves to the content after the marker.
- [ ] Quickstart section: install snippet for `mix.exs`, then a 5-10
      line "your first Lua eval" block. The eval snippet is a working
      doctest (`iex>` form) so `mix test` exercises it.
- [ ] Tour section: 4-6 short subsections with code snippets:
      - [ ] Error messages with source/line.
      - [ ] Calling Elixir functions from Lua (`Lua.set!/3` +
            `deflua`).
      - [ ] Userdata (`{:userdata, term}` round-trip).
      - [ ] Sandboxing (default sandbox + how to allow specific
            `os.*` ops explicitly).
      - [ ] (optional) Metatables and metamethods.
- [ ] "Coverage and status" section: lists supported subsystems and
      explicitly names what's not in scope (`os.execute`, file I/O,
      coroutines, GC/weak tables). States coverage qualitatively and
      links the suite-status decision rather than hardcoding a brittle
      pass count.
- [ ] "Examples" section: links the six canonical A30 example files
      with a one-line description each (see Implementation notes for
      exact paths). Links resolve once A30 merges.
- [ ] "Compatibility" / "vs Luerl" subsection: brief honest
      comparison — pure-Elixir, no shared mutable state, better error
      messages, perf comparable (post-perf-track). Reuse the Credits
      framing already in the README.
- [ ] Every doctested snippet in the README still passes `mix test`.
- [ ] Hex / Hexdocs / CI / license badges present near the top.
- [ ] `mix docs` still builds clean.

## Implementation notes

Keep the README under ~250 lines. Push depth to `guides/` and
`examples/`. The README is the trailer, not the movie.

### CRITICAL: README is the source of `Lua`'s `@moduledoc`

`lib/lua.ex` (lines 1-7) does:

```elixir
external_resource = "README.md"

defmodule Lua do
  @moduledoc external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)
```

Consequences the rewrite MUST respect:

- The literal marker `<!-- MDOC !-->` must remain exactly once, after
  the `# Lua` title/badges and before the body. Everything after it
  becomes the module doc shown on hexdocs. If the marker is removed or
  duplicated, `mix docs` and compilation of `lib/lua.ex` break.
- The indented `iex>` blocks (e.g. `iex> {[4], _} = Lua.eval!("return
  2 + 2")`) are real doctests executed by `mix test`. Any snippet
  written in `iex>` form must be valid and pass. Snippets that are not
  meant to be doctested should stay in fenced ```` ```elixir ```` blocks
  (the current README already mixes both deliberately).

### Decoupling from A30 (the former blocker)

A30 (`docs/examples`, sibling PR) creates the `examples/` directory.
Those files are NOT in this worktree. Link to the exact paths A30's
plan defines — they resolve once both PRs merge to `main`. Link only
the six **non-optional** files so there are no dangling links if A30
drops the optional bonus examples:

- `examples/01_quickstart.exs` — eval some Lua, get the result.
- `examples/02_userdata.exs` — pass an Elixir struct as userdata, call
  methods on it from Lua.
- `examples/03_custom_stdlib.exs` — add an Elixir-defined function to
  the state, call it from Lua.
- `examples/04_sandboxing.exs` — default sandbox + allowing specific
  `os.*` ops explicitly.
- `examples/05_chunks.exs` — compile once, eval many times.
- `examples/06_error_handling.exs` — `pcall`, structured exception
  fields, source/line attribution.
- `examples/README.md` — index of the above.

Do not link `07_metatables.exs` / `08_repl.exs` (A30 marks them
optional). Link the `examples/README.md` index as the umbrella entry.

### Coverage section

Per `ROADMAP.md` (2026-05-21): 6/29 official Lua 5.3 suite files pass,
version is `1.0.0-rc.0`. State this qualitatively (supported
subsystems + named non-goals) and link `ROADMAP.md` for the live
count rather than baking `6/29` into the README, where it will rot.
Named non-goals to call out: standalone interpreter / `os.execute`,
file I/O (`io.*` is a stub by design), filesystem `require`,
coroutines, GC / weak tables, full `debug` library.

### Suggested structure

```
# Lua

[badges]

<!-- MDOC !-->

One-sentence pitch.
One-paragraph "what is this".

## Installation        (mix.exs snippet)
## Quickstart          (5-10 line first eval, doctested)
## Tour
  ### Error messages with source and line
  ### Calling Elixir from Lua
  ### Userdata
  ### Sandboxing
  ### Metatables (optional)
## Coverage            (supported / not supported, link ROADMAP)
## Examples            (links to examples/*.exs from A30)
## Documentation       (hexdocs, guides/working-with-lua.livemd)
## Compatibility / Credits (vs Luerl)
## License
```

### Files

- `README.md` — full rewrite. Preserve the `<!-- MDOC !-->` marker and
  keep all `iex>` doctests valid.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix docs
```

`mix test` must pass because the README's `iex>` snippets are
doctests for `Lua`. `mix docs` must build clean because `Lua`'s
`@moduledoc` is sourced from `README.md` after the `<!-- MDOC !-->`
marker.

Manual: read the README top-to-bottom from a "first time looking at
this library" mindset. Does the path from "should I use this?" to "my
first eval" take more than 60 seconds? If yes, tighten. Spot-check
that every `examples/...` link points at one of the six A30 paths
listed above.

## Risks

- **README is load-bearing for `@moduledoc` and doctests.** Removing or
  duplicating the `<!-- MDOC !-->` marker, or breaking an `iex>`
  snippet, fails `mix test` / `mix docs`. Mitigation: the Verification
  step runs both; preserve the marker and validate every doctest.
- **Cross-PR link dependency.** The `examples/` links are dead until
  A30 merges. Mitigation: link the exact stable paths from A30's plan;
  link only the six non-optional files; reviewers merge both PRs in
  this batch.
- Drift between snippets in README and actual API. Mitigation: Tour
  snippets mirror the `examples/` files 1:1 so there's a single place
  to update.
- "Coverage" section can become a moving target. Mitigation: state the
  status qualitatively and link `ROADMAP.md` for the live suite count
  instead of hardcoding numbers.

## Discoveries

- **README.md is the source of `Lua`'s `@moduledoc`.** `lib/lua.ex`
  reads `README.md`, splits on `<!-- MDOC !-->`, and uses everything
  after the marker as the module doc. The indented `iex>` blocks are
  doctests run by `mix test`. The rewrite must preserve the marker and
  keep the doctests valid; `mix test` + `mix docs` are part of
  Verification for this reason.
- **Cross-PR link dependency (former blocker, now resolved).** This
  plan was `blocked` on A30 because the README links to `examples/`.
  A30 ships as a sibling PR in this batch, so its files are absent from
  this worktree. Decoupled by linking the exact stable paths A30's plan
  defines (`examples/01_quickstart.exs` … `examples/06_error_handling.exs`,
  `examples/README.md`); the links resolve once both PRs land on
  `main`. Optional A30 examples (`07_metatables.exs`, `08_repl.exs`)
  are intentionally not linked to avoid dangling links.
- Version is `1.0.0-rc.0` and suite coverage is 6/29 (ROADMAP,
  2026-05-21). Coverage section links ROADMAP for the live count
  rather than hardcoding it.
- The public runtime exception is `Lua.RuntimeException` (fields
  `:line`, `:source`, `:message`, `:call_stack`, `:state`,
  `:original`), not the internal `Lua.VM.RuntimeError`. The Tour's
  error snippets use the public type.
- Specific sandboxed ops are allowed via the `:exclude` option, e.g.
  `Lua.new(exclude: [[:os, :getenv]])`.
- `{:userdata, term}` round-trips directly through `Lua.set!/3`; no
  explicit `Lua.encode!/2` is required for the Tour snippet.

## What changed

- `README.md` — full rewrite. New structure: badges + `<!-- MDOC !-->`
  marker (preserved) + one-line pitch and positioning paragraph;
  Installation; Quickstart (doctested); Tour (errors with source/line +
  `pcall`, calling Elixir from Lua, userdata, sandboxing, metatables);
  Coverage and status (supported subsystems + named non-goals, links
  `ROADMAP.md`); Examples (six A30 paths + index, absolute `blob/main`
  links); Documentation; Compatibility and credits (vs Luerl); License.
  201 lines, under the ~250 target.
- `.agents/plans/A31-readme-rewrite.md` — plan lifecycle: stub →
  in-progress → review.
- No suite delta (docs-only change). `mix test`: 2096 passed, 0 failed.
  `mix docs` builds with no warnings.
- Cross-PR link dependency: the `examples/` links resolve once sibling
  PR A30 (`docs/examples`) merges to `main`.
