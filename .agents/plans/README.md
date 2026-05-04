# Plan files

This directory holds **plan files**. One plan = one PR = one issue = one merge to `main`.

Plan files are the primary unit of work for this project. They are short, focused, and
machine-readable so that agents can pick them up via `/next-plan`, execute them via the
`ship-a-plan` skill, and produce predictable PRs.

## Why `.agents/plans/`

Plans live under `.agents/` — the cross-tool agent convention. Plans are
tool-agnostic markdown with YAML frontmatter; any agent runner can read them.

The whole orchestration tree has a single source of truth under `.agents/`:

```
.agents/plans/      ← per-PR plans (here)
.agents/skills/     ← agent skills
.agents/commands/   ← slash commands
```

For tool-specific discovery, `.opencode/commands` and `.claude/skills` are
symlinks back into `.agents/`. There is exactly one copy of every plan,
skill, and command — no parallel trees to keep in sync.

## Naming

`<id>-<short-slug>.md`, where `<id>` is `A0`, `A1`, …, `B1`, `B2`, etc.

- `A` = Direction A: suite triage to 0.5.0
- `B` = Direction B: performance investigation
- The number is sequential within each direction; lower numbers ship first.

If a plan grows multiple sub-PRs, split it into `A5a`, `A5b`, etc., each with its own file.

## Frontmatter schema

Every plan file starts with YAML frontmatter:

```yaml
---
id: A1
title: "One-line description of the change"
issue: 200                        # GitHub issue number, optional until opened
pr: null                          # GitHub PR number, set by /open-pr
branch: fix/some-slug
base: main
status: ready                     # ready | in-progress | review | merged | deferred | blocked
direction: A                      # A | B
unlocks:                          # optional: which suite files this is expected to unlock
  - constructs.lua
  - errors.lua
---
```

### Status lifecycle

- `ready` — plan is written, branch can be created, `/next-plan` will pick it up.
- `in-progress` — agent is actively executing this plan. Set by `ship-a-plan` on start.
- `review` — PR is open, awaiting human review/merge. Set by `ship-a-plan` after `/open-pr`.
- `merged` — PR has merged to `main`. Set by the agent on next session that observes this.
- `deferred` — plan exists but is intentionally postponed. Should explain why.
- `blocked` — plan cannot start until another plan merges. Body should name the blocker(s).

## Body sections

Required:

```markdown
## Goal
One sentence.

## Out of scope
- Bullet list of things this PR is NOT doing.
- Anything not on this list that comes up becomes a follow-up plan, not scope creep.

## Success criteria
- [ ] `mix test` passes (≥ 1273)
- [ ] (any other measurable acceptance)

## Implementation notes
- Concrete starting points, files to touch, hypotheses.

## Verification
- The exact commands to run before opening the PR.

## Risks
- Known unknowns and what could go wrong.
```

Optional, appended by the agent during execution:

```markdown
## Discoveries
- Anything found mid-implementation that wasn't anticipated.

## What changed
- Files touched, suite count delta, follow-up issues opened.
```

## Workflow

1. **Pick a plan**: agent reads `.agents/plans/`, finds the lowest-id `status: ready` plan.
2. **Verify preconditions**: `ship-a-plan` skill runs `mix test` against `base:` to confirm a clean tree.
3. **Branch and implement**: switch to `branch:`, change `status:` to `in-progress`.
4. **Verify**: run the verification block. If anything fails, fix or revert before moving on.
5. **Open PR**: `/open-pr` generates the PR body from the plan's success criteria + diff stat.
6. **Status: review**: agent sets `status: review` and stops. Human merges.
7. **After merge**: next session detects the merge and sets `status: merged`.

## Why this format

- **One file per PR** keeps PRs small and bisectable.
- **YAML frontmatter** lets `/next-plan`, `/open-pr`, and `ship-a-plan` work without ambiguity.
- **"Out of scope"** is the most important section: it stops the agent from drifting.
- **Plans live in git** so they're versioned alongside the code they describe.
