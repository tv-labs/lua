---
description: Open a PR for the current branch using its matching plan file
agent: build
---

Current branch: !`git branch --show-current`

Recent commits on this branch (vs main): !`git log --oneline main..HEAD 2>/dev/null | head -10`

Diff stat: !`git diff --stat main...HEAD 2>/dev/null | tail -20`

Find the plan file under `.agents/plans/` whose frontmatter `branch:`
matches the current branch.

If no matching plan exists, ask me whether to:
1. Open the PR without a plan (and write the body manually).
2. Stop and create a plan first.

If a matching plan exists:

1. Verify its status is `in-progress` or `review`. If it's still `ready`,
   ask whether `ship-a-plan` was started — there may be a missed step.

2. Generate the PR body from the plan. Template:

   ```markdown
   ## {Plan title}

   Plan: [`.agents/plans/{id}-{slug}.md`](link to file at HEAD)
   Closes #{issue from plan frontmatter}

   ### Goal
   {From plan}

   ### Success criteria
   {Render as checkboxes; check off the ones the diff actually achieves}

   ### Verification

   - mix test: <count> passing, <count> failures
   - mix test --only lua53: <count>/24 passing
   - <other commands from plan's Verification section>

   ### Changes
   {git diff --stat output}

   ### Out of scope (intentional)
   {From plan's "Out of scope" section}

   ### Discoveries
   {From plan's Discoveries section if non-empty, otherwise omit}
   ```

3. Open the PR:

   ```bash
   gh pr create --title "{type}({id}): {plan title}" --body "$(cat <<'EOF'
   ...body...
   EOF
   )"
   ```

   Where `{type}` is feat/fix/perf/chore/docs based on the plan's direction
   and nature.

4. Update the plan file:
   - Set frontmatter `status: review`.
   - Set frontmatter `pr: <new PR number>`.
   - Append `## What changed` if not already present.
   - Commit this update with message `chore({id}): mark plan as review`.
   - Push.

5. Output the PR URL.

Stop. Do not run `gh pr merge`. Wait for human review.
