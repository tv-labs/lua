---
id: A13
title: Cut 1.0.0 final
issue: 174
pr: null
branch: release/1-0-0
base: main
status: blocked
direction: A
---

## Goal

Publish `1.0.0` to Hex.pm. This is the final plan in Direction A. The
major version bump reflects the magnitude of the VM rewrite (Luerl →
Elixir-native) and a commitment to public API stability.

This plan was previously scoped to `1.0.0-rc.1`; rc.1 already shipped
(see CHANGELOG and `mix.exs @version`). This is the cut for `1.0.0`
final.

## Out of scope

- New features (must be in by now or wait for 1.1).
- Documentation rewrites beyond what A30/A31/A32 ship.

## Blocked on

- A19 — error line/source in stdlib raises.
- A20-A24 — suite triage clusters and their sub-plans, enough to hit
  the suite gate.
- A25 — `string.pack`.
- A26 — error message quality pass.
- A27-A32 — DX/docs track.
- A33-A35 — perf parity locked in.
- All milestone issues closed.

## Success criteria

- [ ] `mix.exs` `@version` set to `1.0.0`.
- [ ] `CHANGELOG.md` has a `1.0.0` section dated for the publish day,
      summarizing the diff vs `1.0.0-rc.1`.
- [ ] `mix test` passes (≥ current count + new tests from
      A19-A35).
- [ ] **Suite gate**: at least N/29 official Lua 5.3 suite files
      passing, where N is set by A20-A24 outcomes. Target is
      "near-fully compliant"; specific number to be set after triage
      lands. Files explicitly out of scope (`os.execute` etc.) are
      documented as deliberate non-goals in the README and
      CHANGELOG. **Best-guess: ≥22/29 with documented exclusions.**
- [ ] **Perf gate**: `mix lua.bench --compare-baseline` passes
      against the locked-in baseline from A35. No workload more than
      25% slower than Luerl on the same machine.
- [ ] **Errors gate**: every error category in A26's gallery renders
      cleanly with line/source; rendered output reviewed by Dave.
- [ ] **Docs gate**: `mix docs --warnings-as-errors` exits 0; README
      and `examples/` link consistently; doctests pass.
- [ ] **DX gate**: `mix lua.eval`, `mix lua.bench`, `mix lua.suite`
      all work end-to-end. `Lua.dbg/2` exists and is documented.
- [ ] `mix hex.build` succeeds.
- [ ] Tag created: `git tag v1.0.0` (manual).
- [ ] Pushed: `git push origin v1.0.0` (manual).
- [ ] Published: `mix hex.publish` (manual).

## Implementation notes

This plan is a checklist, not a coding task. The agent's role is to:

1. Verify all blockers are merged and gates are met.
2. Update `mix.exs` to `1.0.0`, write the CHANGELOG entry.
3. Run the full verification block.
4. Open the release PR.
5. After merge, do **not** auto-tag or publish. Hand off to human.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --include skip
mix docs --warnings-as-errors
mix lua.bench --compare-baseline
mix lua.suite
mix hex.build
```

## Risks

- Going to 1.0 commits to API stability. Any breaking change after
  this requires a 2.0.
- Anything broken in the doctest set will break `mix hex.publish`.
- Perf regressions snuck in between A35 baseline capture and the
  release cut would block this. If A35's CI has been running, this
  is unlikely; if not, run a fresh comparison before the release PR.

## Discoveries

(populated during implementation)
