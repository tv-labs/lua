---
id: A13
title: Cut 1.0.0-rc.1
issue: 174
pr: null
branch: release/1-0-0-rc-1
base: main
status: blocked
direction: A
---

## Goal

Publish `1.0.0-rc.1` to Hex.pm. This is the final plan in Direction A and
gates on the rest of the milestone closing. The major version bump
reflects the magnitude of the VM rewrite (Luerl → Elixir-native) and a
commitment to public API stability.

## Out of scope

- New features (must be in by now or wait for 1.0.0 final).
- Documentation rewrites beyond what A12 ships (note: A12 already bumps
  `mix.exs` and writes the CHANGELOG entry — this plan only needs to
  date the entry, tag, and publish).

## Success criteria

- [x] `mix.exs` `@version` bumped to `1.0.0-rc.1` (done in A12 / PR #201).
- [x] `CHANGELOG.md` has a `1.0.0-rc.1` section (done in A12 / PR #201).
- [ ] CHANGELOG entry's date is the actual publish date.
- [ ] All `1.0.0` milestone issues closed or moved to `1.0.x`.
- [ ] `mix test` passes (≥ 1420).
- [ ] `mix test --only lua53` passes (target: improve on 5/29).
- [ ] `mix docs` does not introduce new warnings.
- [ ] Tag created: `git tag v1.0.0-rc.1`
- [ ] Pushed: `git push origin v1.0.0-rc.1`
- [ ] Published: `mix hex.publish` (manual; pre-release flag).

## Blocked on

- A0–A12 complete.
- Suite count target met.
- Final review by Dave.

## Implementation notes

This plan is a checklist, not a coding task. The agent's role is to:

1. Verify all blockers are resolved (milestone issue count = 0).
2. Update version, CHANGELOG date, suite count in CHANGELOG.
3. Open the release PR.
4. After merge, do NOT auto-tag or publish. Hand off to human.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix docs
mix hex.build
```

## Risks

- Pre-release semver (`1.0.0-rc.1`) may not be visible by default in Hex
  resolvers; the user should know.
- Anything broken in the doctest set will break `mix hex.publish`.
- Going to 1.0 commits to API stability. Any breaking change after this
  requires a 2.0.

## Discoveries

(populated during implementation)
