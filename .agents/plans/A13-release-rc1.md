---
id: A13
title: Cut 0.5.0-rc.1
issue: null
pr: null
branch: release/0-5-0-rc-1
base: main
status: blocked
direction: A
---

## Goal

Publish `0.5.0-rc.1` to Hex.pm. This is the final plan in Direction A and
gates on the rest of the milestone closing.

## Out of scope

- New features (must be in by now or wait for 0.5.0 final).
- Documentation rewrites beyond what A12 ships.

## Success criteria

- [ ] `mix.exs` `@version` bumped to `0.5.0-rc.1`.
- [ ] `CHANGELOG.md` has a `0.5.0-rc.1` section dated and entry-listed.
- [ ] All `0.5.0` milestone issues closed or moved to `0.5.x`.
- [ ] `mix test` passes (≥ 1273)
- [ ] `mix test --only lua53` passes ≥ 12/24 files (target)
- [ ] `mix docs` builds cleanly.
- [ ] Tag created: `git tag v0.5.0-rc.1`
- [ ] Pushed: `git push origin v0.5.0-rc.1`
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

- Pre-release semver (`0.5.0-rc.1`) may not be visible by default in Hex
  resolvers; the user should know.
- Anything broken in the doctest set will break `mix hex.publish`.

## Discoveries

(populated during implementation)
