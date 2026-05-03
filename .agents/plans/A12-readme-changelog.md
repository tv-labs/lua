---
id: A12
title: Update README and CHANGELOG for 0.5.0
issue: null
pr: null
branch: docs/0-5-0
base: main
status: ready
direction: A
---

## Goal

Refresh user-facing docs to reflect the new VM. The current README still
references Luerl as the backend, which is no longer true.

## Out of scope

- API changes (none planned for 0.5).
- Migration guides for breaking changes (there aren't any — public API is
  stable).
- New feature docs not yet shipped.

## Success criteria

- [ ] `README.md` accurately describes the new VM (no Luerl references).
- [ ] `CHANGELOG.md` has a `0.5.0` section summarizing:
  - VM rewrite (Luerl → Elixir-native)
  - Performance improvements (PRs #143, #153–#156)
  - Lua 5.3 suite pass rate
  - Behavioral differences from 0.4 (sandbox model, encoding, error format)
  - Bug fixes referenced by PR/issue.
- [ ] Doctests in `lib/lua.ex` still pass (running on the new VM).
- [ ] `mix docs` builds cleanly without warnings.

## Implementation notes

### README sections to revise

- "Features": still mentions Luerl, replace with new VM messaging.
- "Credits": update to reflect that this is a new implementation that
  drew inspiration from Luerl but no longer depends on it.
- Encoding/decoding table: the `:luerl.tref()` etc. types should be
  rewritten as the new VM's internal types.

### CHANGELOG entry

Use the existing CHANGELOG style (semver + date). One bulleted section
per heading: Added / Changed / Removed / Fixed / Performance.

### Things to verify before publishing

- All doctests pass (`mix test --only doctest`).
- Code examples in README still work (paste each into iex and confirm).
- No broken links.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix docs
```

## Risks

- Doctests run on real code; if any reference removed/renamed APIs, they'll
  fail. Fix or remove as appropriate.
- Link to Luerl is fine to keep in "Credits" as historical reference, but
  not as "this is what we use".

## Discoveries

(populated during implementation)
