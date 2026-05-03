---
name: ship-a-plan
description: |
  Execute one plan file from .agents/plans/ as a single PR against main.
  Reads the plan, verifies preconditions, implements only what's in scope,
  runs full validation, opens a PR, and updates the plan file's status. Stops
  before merging — review is human-gated.

  Use this skill when the user invokes /next-plan, asks to "ship the next
  plan", "start plan A1" or similar, or when picking up a specific plan file
  by id. One plan = one PR = one issue = one merge to main. Do not batch
  multiple plans into a single PR.
---

# ship-a-plan

The contract for executing one plan file from `.agents/plans/` as a single
PR. Read this skill carefully before touching code.

## What this skill is for

- Executing exactly one plan file end-to-end: branch creation → implementation
  → tests → PR creation → status update.
- Stopping at PR creation. Humans merge.
- Producing predictable, narrow PRs that match their plan file.

## What this skill is NOT for

- Implementing multiple plans at once.
- Merging PRs.
- Deciding which plan to work on (that's `/next-plan`'s job, or the user's).
- Changing scope mid-execution. If a discovery emerges, log it and stay scoped.

## Workflow

### 1. Read and validate the plan

- Read the named plan file under `.agents/plans/<id>-<slug>.md`.
- Parse YAML frontmatter. Required fields: `id`, `title`, `branch`, `base`,
  `status`, `direction`.
- **Refuse to proceed** if `status:` is not `ready`. Tell the user the current
  status and stop.
- **Refuse to proceed** if the plan body is missing any required section
  (Goal, Out of scope, Success criteria, Implementation notes, Verification,
  Risks).

### 2. Pre-flight checks

Run from a clean tree on `base:` (default `main`):

```bash
git status                                      # must be clean
git checkout {base}
git pull origin {base}
mix compile --warnings-as-errors                # must pass
mix test                                        # must pass
```

If any pre-flight check fails, stop and report. Do not start work on a
broken tree.

### 3. Branch

```bash
git checkout -b {branch}
```

If the branch already exists locally, ask the user whether to reuse or
delete it.

### 4. Update plan status

Set frontmatter `status: in-progress`. Commit this change as a separate first
commit on the branch:

```
chore({id}): start plan
```

This makes the plan's lifecycle visible in the PR diff.

### 5. Implement

- Touch only the files named in "Implementation notes" unless absolutely
  necessary.
- If you discover something that wasn't anticipated:
  - If it's small and in scope, fix it and note in `## Discoveries` at the
    bottom of the plan file.
  - If it's a separate concern, **stop, append it to `## Discoveries`, and
    open a follow-up issue or new plan file. Do NOT expand this PR's scope.**
- Add or update unit tests as the plan requires.
- Run `mix format` after every meaningful change.

### 6. Verify

Run the exact commands in the plan's "Verification" section. At minimum:

```bash
mix format
mix compile --warnings-as-errors
mix test
```

If `mix test --only lua53` is part of the plan's success criteria, run it
both before any code changes (snapshot in a tmp file) and after, capture the
delta in pass count and which files changed status.

If anything fails, fix or revert before opening the PR. **Do not ship red
tests.**

### 7. Commit and push

Stage the changes for this plan only. Use a clear commit message:

```
{type}({id}): {one-line summary from plan title}

{2-3 sentence body explaining what this plan does and why}

Closes #{issue}
```

Where `{type}` is `feat`, `fix`, `perf`, `chore`, `docs`, etc. Choose based
on the plan's `direction:` and the nature of the change.

**Do NOT add Co-Authored-By lines for AI agents.** Plain authorship.

```bash
git push -u origin {branch}
```

### 8. Open the PR

The PR body is generated from the plan file. Template:

```markdown
## {Plan title}

Plan: [`.agents/plans/{id}-{slug}.md`](link to file on this branch)
Closes #{issue}

### Goal
{Copy from plan}

### Success criteria
{Render as checkbox list, with each box checked off and a note about how it was verified}
- [x] mix test passes (1273 → 1273, no regressions)
- [x] Suite count: 4/24 → 9/24
- [x] Specific files now passing: constructs.lua, errors.lua, ...

### Changes
{Generate from `git diff --stat main...HEAD`}

### Discoveries
{Copy from plan if any}

### Verification
```
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```
{Paste the relevant tail output for each}

### Out of scope (intentional)
{Copy from plan}
```

Use `gh pr create --title "..." --body "$(cat <<'EOF' ... EOF)"` so the PR
body is exactly what was generated.

### 9. Update the plan file

After PR opens:

- Set frontmatter `status: review`.
- Set frontmatter `pr: <number>`.
- Append `## What changed` section with: files touched, suite delta if
  applicable, links to any follow-up issues opened.

Commit this update as a final commit on the branch:

```
chore({id}): mark plan as review
```

This keeps the plan file synchronized with reality and adds context to the
PR for the reviewer.

### 10. Update ROADMAP.md if relevant

If this plan changes the suite count, the "Done" list, or the "In flight"
shape, propose an edit to `ROADMAP.md`. **Ask the user before pushing the
roadmap update** — strategic narrative is human-owned.

### 11. Stop

Output a summary:

```
✓ Plan {id} shipped to PR #{number}: {pr-url}
  Suite delta: 4/24 → 9/24
  Tests: 1273 passing, 0 failing
  Status: ready → review
```

**Do not run `gh pr merge`.** Wait for human review.

## Failure modes and recovery

### Pre-flight tests fail on `main`

Stop. Report the failure. Do not branch or write code. The base is broken
and that's an upstream issue.

### Implementation breaks tests partway

- If the breakage is expected (e.g. you're refactoring), continue and fix
  before the verification step.
- If unexpected, investigate. If it's a real downstream issue exposed by your
  change, decide:
  - Small fix in scope → include it, note in Discoveries.
  - Separate concern → revert, open a new plan, ship the original after the
    blocker is fixed.

### Suite count regresses

Stop. The plan's success criteria explicitly require no regression. Either
fix the regression or, if the regression is intentional and worth the
tradeoff, escalate to the user before continuing.

### Discoveries balloon out of scope

Stop. Open a follow-up plan file or issue for the new work. Ship the
original plan with what's done, narrowed if necessary.

## Conventions

- **Branch naming**: as specified in the plan's `branch:` field. Typical
  patterns: `fix/<slug>` for bug fixes, `feat/<slug>` for features,
  `perf/<slug>` for perf, `chore/<slug>` for cleanup, `docs/<slug>` for docs.
- **Commit prefixes**: match the branch type (`feat:`, `fix:`, `perf:`,
  `chore:`, `docs:`).
- **PR title**: typically `{type}({id}): {plan title}` for traceability.
- **No co-authoring**: AI agents do not appear in `git log`.
- **Format always passes**: run `mix format` before every commit.
- **Tests always pass**: never push red tests, even WIP.

## When you're not sure

Ask the user. Do not guess. The plan file exists exactly so that scope is
unambiguous; if it's still ambiguous, surface it.
