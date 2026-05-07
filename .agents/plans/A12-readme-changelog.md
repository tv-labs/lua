---
id: A12
title: Update README and CHANGELOG for 1.0.0-rc.1
issue: 173
pr: 201
branch: docs/0-5-0
base: main
status: merged
direction: A
blocked_on: [A14, A15, A16]
---

## Goal

Refresh user-facing docs to reflect the new VM and bump the version to
`1.0.0-rc.1`. The VM rewrite (Luerl → Elixir-native) is significant
enough to warrant the major version bump; cutting an `rc` first leaves
room to catch regressions before locking in 1.0 final.

## Out of scope

- API changes (none planned for 0.5).
- Migration guides for breaking changes (there aren't any — public API is
  stable).
- New feature docs not yet shipped.

## Success criteria

- [ ] `README.md` accurately describes the new VM (no Luerl references
  except a historical note in Credits).
- [ ] `CHANGELOG.md` has a `1.0.0-rc.1` section summarizing:
  - VM rewrite (Luerl → Elixir-native)
  - Performance improvements (PRs #143, #153–#156)
  - Lua 5.3 suite pass rate
  - Behavioral differences from 0.4 (encoded value tags, error format,
    integer wrapping, MFA encoding removed)
  - Bug fixes referenced by PR/issue.
- [ ] `mix.exs` `@version` bumped to `1.0.0-rc.1`.
- [ ] Doctests in `lib/lua.ex` still pass (running on the new VM).
- [ ] `mix docs` does not introduce new warnings (pre-existing warnings
  about hidden modules are out of scope).

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

- **Version**: framing this as `0.5.0` undersells the magnitude of the VM
  rewrite. After discussion the version was bumped to `1.0.0-rc.1` —
  pre-release leaves room to catch regressions before locking 1.0 final
  while still signaling that this is a major release.
- `mix docs` emits 6 pre-existing warnings on `main` (references to hidden
  modules `Lua.CompilerException`, `Lua.Compiler.Scope.State`). These are
  about code visibility, not docs content, so they're out of scope for a
  README/CHANGELOG plan. This PR does not introduce new warnings.
- ROADMAP said 4/24 suite files passing; the actual count is 5/29
  (`simple_test.lua`, `api.lua`, `bitwise.lua`, `code.lua`, `vararg.lua`
  — `bitwise.lua` was added as ready in #198/#199). ROADMAP updated.
- The `{module(), atom(), list()}` MFA encoding form is no longer accepted
  by `Lua.encode!/2` in the new VM. Documented in the CHANGELOG's Removed
  section.

## What changed

Files touched:
- `README.md` — rewrote tagline, Features list, encoding/decoding table
  rows, and Credits section. No more Luerl claims in user-facing copy
  (only a historical reference in Credits).
- `CHANGELOG.md` — new `[v1.0.0-rc.1]` entry covering Added / Changed /
  Removed / Performance / Fixed; updated link refs.
- `mix.exs` — `@version` bumped from `0.4.0` to `1.0.0-rc.1`.
- `ROADMAP.md` — milestone names updated (`0.5.0` → `1.0.0`,
  `0.5.x` → `1.0.x`); stale 4/24 suite count corrected to 5/29; current
  unit test count updated.
- `.agents/plans/A13-release-rc1.md` — retitled and rebranched to
  `1.0.0-rc.1`; success criteria updated to reflect that A12 already
  bumped `mix.exs` and seeded the CHANGELOG entry.

Suite delta: none — pure docs/release-prep PR.

Tests: 1420 passing, 0 failing, 31 skipped (unchanged).

PR: #201.
