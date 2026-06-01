export const meta = {
  name: 'pr-feedback-stabilize',
  description: 'For each open PR: address current review feedback (pr-feedback-handler method) and push, then run an independent review round, looping address→review until the PR stabilizes (no actionable findings) or a round cap is hit. Posts each review to the PR. Never merges.',
  phases: [
    { title: 'Round 1', detail: 'address existing PR feedback + push, then independent review' },
    { title: 'Round 2', detail: 'address round-1 review findings + push, then re-review' },
    { title: 'Round 3', detail: 'address round-2 review findings + push, then final review' },
  ],
}

const MAX_ROUNDS = 3

// ---------------------------------------------------------------------------
// PRs to stabilize (branch names from `gh pr list`).
// ---------------------------------------------------------------------------
const PRS = [
  { num: 305, branch: 'vm-dos-resource-limits',      label: 'vm-dos',          title: 'Harden the VM against allocation-bomb DoS; document sandboxing' },
  { num: 304, branch: 'errors/quality-pass',         label: 'error-render',    title: 'feat(error): lead rendered errors with location and gate ANSI on TTY' },
  { num: 302, branch: 'feat/vfs-sandbox',            label: 'vfs',             title: 'feat(stdlib): route os/require file IO through a virtual filesystem' },
  { num: 300, branch: 'docs/examples',               label: 'examples',        title: 'docs(examples): add runnable embedding examples' },
  { num: 298, branch: 'docs/readme-rewrite',         label: 'readme',          title: 'docs(readme): rewrite for 1.0 positioning, quickstart, and tour' },
  { num: 282, branch: 'chore/constructs-triage-narrow', label: 'constructs-narrow', title: 'chore(suite): narrow constructs.lua skip with per-failure tracking' },
]

// ---------------------------------------------------------------------------
// Shared repo conventions every agent must honor (from .agents/skills/* and
// the sibling triage-implement-review workflow).
// ---------------------------------------------------------------------------
const CONV = `
REPO: tv-labs/lua — an embedded Lua 5.3 VM written in Elixir. The canonical
checkout is /Users/dave/code/tvlabs/lua. Use the gh CLI (authenticated as
davydog187) for all GitHub operations.

NON-NEGOTIABLE CONVENTIONS:
- Commit subject and PR title scope = the affected SUBSYSTEM, never a plan id.
  e.g. 'fix(vm): ...', 'feat(stdlib): ...', 'docs(readme): ...', 'chore(suite): ...'.
  Allowed scopes: lexer, parser, compiler, vm, stdlib, pattern, string, table,
  coroutine, error, suite, plan, docs, bench.
- NO plan-id references in source files, test moduledocs, @doc, or comments.
  Plan ids live only in the commit body ('Plan: <id>') and the PR body.
- NO "Co-Authored-By" trailers for AI agents. Plain authorship.
- Conventional-commit types: feat, fix, perf, chore, docs, test, refactor.
- NEVER push red tests to a ready PR. NEVER force-push. NEVER merge — the PR
  stays open for human review.

WORKTREE ISOLATION (CRITICAL): you run in an ISOLATED git worktree under
.claude/worktrees/, NOT the operator's primary checkout at the canonical path.
Run EVERY git command from your current working directory. NEVER \`cd\` to the
canonical checkout and NEVER pass \`git -C <canonical-path>\`. Before ANY
state-changing git command (fetch is fine; checkout/detach/reset/commit/push are
not), run \`git rev-parse --show-toplevel\` and confirm it points at your worktree
under .claude/worktrees/ — NOT the canonical checkout. If it points at the primary
repo, STOP. Running \`git checkout --detach\` against the primary checkout detaches
the operator's HEAD and corrupts their working tree — this has happened and must
not recur. Reading files at the canonical path is fine; state-changing git is not.

GIT PUSH PROTOCOL (you run in a fresh worktree off 'main'; the PR's local
branch may already be checked out in another worktree, so do NOT check it out
by name — work in DETACHED HEAD off the remote tip, FROM YOUR WORKTREE CWD):
  git rev-parse --show-toplevel   # MUST be your .claude/worktrees/ path, not the primary repo
  git fetch origin <branch>
  git checkout --detach origin/<branch>
  mix deps.get            # only if deps/_build are missing in this worktree
  ...make changes, commit...
  git push origin HEAD:<branch>

VALIDATION (run from the worktree root; deps/_build are per-worktree):
  mix format
  mix compile --warnings-as-errors
  mix test
  mix test test/lua53_suite_test.exs --only lua53
All must pass before you push. (Docs-only PRs: the suite still runs fast.)
`

const ADDRESS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['prNumber', 'round', 'noFeedback', 'addressed', 'skipped', 'pushed', 'testsGreen', 'summary'],
  properties: {
    prNumber: { type: 'number' },
    round: { type: 'number' },
    noFeedback: { type: 'boolean', description: 'true if there was nothing actionable to address this round' },
    addressed: { type: 'array', items: { type: 'string' }, description: 'one line per finding/comment addressed' },
    skipped: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['finding', 'reason'],
        properties: { finding: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    pushed: { type: 'boolean', description: 'true if a fix-commit was pushed to the PR branch' },
    testsGreen: { type: 'boolean', description: 'true if mix test AND the lua53 suite passed after changes' },
    summary: { type: 'string', description: '2-5 sentences on what changed and why' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['prNumber', 'round', 'overallVerdict', 'findings'],
  properties: {
    prNumber: { type: 'number' },
    round: { type: 'number' },
    overallVerdict: { type: 'string', description: 'one-paragraph overall assessment' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'file', 'title', 'detail'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          file: { type: 'string' },
          line: { type: 'string' },
          title: { type: 'string' },
          detail: { type: 'string' },
          suggestedFix: { type: 'string' },
        },
      },
    },
  },
}

const ACTIONABLE = new Set(['blocker', 'major', 'minor'])
const fmtFindings = (findings) =>
  (findings || [])
    .map((f, i) => `${i + 1}. [${f.severity}] ${f.file}${f.line ? ':' + f.line : ''} — ${f.title}\n   ${f.detail}${f.suggestedFix ? '\n   Suggested: ' + f.suggestedFix : ''}`)
    .join('\n')

// ---------------------------------------------------------------------------
// Address step — pr-feedback-handler method, headless. Round 1 pulls the PR's
// existing unresolved feedback; later rounds address the prior review findings.
// Runs in an isolated worktree because it mutates the branch and pushes.
// ---------------------------------------------------------------------------
function addressAgent(pr, round, priorFindings) {
  const feedbackSection =
    round === 1
      ? `FETCH CURRENT FEEDBACK (round 1). Get every UNRESOLVED review thread plus
top-level PR review/comment bodies. Thread resolution is NOT in 'gh pr view --json';
use the GraphQL API:
  gh api graphql -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:100){nodes{isResolved isOutdated path line comments(first:20){nodes{author{login} body}}}}}}}' -f o=tv-labs -f r=lua -F p=${pr.num}
  gh pr view ${pr.num} --repo tv-labs/lua --json reviews,comments
Act ONLY on threads where isResolved is false, plus substantive review/comment
bodies. Ignore bot chatter and already-resolved threads. If there is NO actionable
feedback, make no changes: set noFeedback true, pushed false, and return.`
      : `ADDRESS PRIOR-ROUND REVIEW FINDINGS (round ${round}). These came from the
workflow's own review of the PR after the last push:
${fmtFindings(priorFindings)}
If none of these are actually actionable, set noFeedback true, pushed false, return.`

  return agent(
    `${CONV}

You are addressing review feedback on an open PR using the pr-feedback-handler
method (classify → propose → implement → validate → push), running headless.

PR #${pr.num} "${pr.title}" — branch ${pr.branch}. Round ${round} of up to ${MAX_ROUNDS}.

Set up your worktree per the GIT PUSH PROTOCOL (detached HEAD off origin/${pr.branch}).

${feedbackSection}

For each actionable item:
- Classify it: simple change / discussion-needed / pushback-worthy.
- Address every BLOCKER and MAJOR item, and any MINOR item whose fix is clear and
  low-risk. Honor Elixir philosophy: locality, immutability, small focused changes.
- SKIP an item only if it is wrong, out of scope for this PR, or a pure nit —
  record each skip in 'skipped' with a concrete reason. A pushback-worthy item
  (e.g. reviewer asks for global state where a pure solution exists) counts as a
  skip with the reason being your pushback rationale. Do NOT expand PR scope to
  chase unrelated improvements.
- Update or add tests whenever you change behavior.

Then VALIDATE (all must pass) and push the fix-commit to the PR branch with a
conventional-commit subject scoped to the subsystem (no plan id, no Co-Authored-By):
  git push origin HEAD:${pr.branch}

If a review thread was fully resolved by your change you may resolve it via the
GraphQL resolveReviewThread mutation. DO NOT MERGE. DO NOT force-push.

Return the structured result for round ${round}. testsGreen reflects whether BOTH
mix test and the lua53 suite passed.`,
    { label: `address:${pr.label}#r${round}`, phase: `Round ${round}`, isolation: 'worktree', schema: ADDRESS_SCHEMA },
  )
}

// ---------------------------------------------------------------------------
// Review step — independent /review-equivalent on the freshly pushed PR. Reads
// via gh, posts a comment, returns structured findings. No worktree needed.
// ---------------------------------------------------------------------------
function reviewAgent(pr, round) {
  return agent(
    `${CONV}

You are an independent reviewer running the equivalent of the /review command on
an open PR. Be rigorous and skeptical — assume the author may have missed something.
The address step just pushed to this branch, so review the CURRENT remote state.

PR #${pr.num} "${pr.title}" — branch ${pr.branch}. Review round ${round}.
Read the latest diff and metadata:
  gh pr view ${pr.num} --repo tv-labs/lua
  gh pr diff ${pr.num} --repo tv-labs/lua
You may read full files under /Users/dave/code/tvlabs/lua for surrounding context,
but the pushed branch may be AHEAD of that working copy — trust 'gh pr diff'.

Review for:
- CORRECTNESS: real bugs, wrong Lua 5.3 §semantics (consult the 5.3 reference
  manual when unsure), missed edge cases, off-by-one, integer/float subtleties,
  error-message mismatches.
- TESTS: do the tests actually pin the behavior? Would they fail before the fix?
  Are edge cases covered? For suite PRs, did the lua53 skip range narrow correctly
  (smallest range, precise reason, no plan-id in the reason)?
- REPO CONVENTIONS (blockers if violated): commit/PR scope is the subsystem not a
  plan id; no plan-id in source/test/comments; no Co-Authored-By trailers; PR body
  references the issue it closes where applicable.
- SIMPLIFICATION / reuse: dead code, needless complexity, duplication.
- DOCS PRs specifically: do the example snippets actually run as written? Broken
  links, stale version claims, copy-paste errors, mismatched output.

Post a concise review to the PR (clearly mark it as an automated round-${round}
review):
  gh pr comment ${pr.num} --repo tv-labs/lua --body "<your review markdown>"

Then return the structured findings. Include ONLY real, actionable findings. If the
PR is clean, return an empty findings array with a positive overallVerdict — that
is how the loop detects stabilization.`,
    { label: `review:${pr.label}#r${round}`, phase: `Round ${round}`, schema: REVIEW_SCHEMA },
  )
}

// ---------------------------------------------------------------------------
// Per-PR loop: address → review, repeated until stabilized or MAX_ROUNDS.
// Rounds are inherently sequential (must push before re-review).
// ---------------------------------------------------------------------------
async function stabilizePr(pr) {
  const rounds = []
  let priorFindings = []
  let stabilized = false

  for (let round = 1; round <= MAX_ROUNDS; round++) {
    const address = await addressAgent(pr, round, priorFindings)

    // Round 1 with genuinely no feedback and nothing pushed: still review once to
    // confirm the PR is clean, then we can stabilize on a clean review.
    const review = await reviewAgent(pr, round)
    rounds.push({ round, address, review })

    if (!review) {
      log(`#${pr.num} ${pr.label}: review round ${round} produced no result — stopping.`)
      break
    }

    const actionable = (review.findings || []).filter((f) => ACTIONABLE.has(f.severity))
    log(`#${pr.num} ${pr.label}: round ${round} — ${actionable.length} actionable finding(s), ${(review.findings || []).length} total.`)

    if (actionable.length === 0) {
      stabilized = true
      log(`#${pr.num} ${pr.label}: STABILIZED after round ${round}.`)
      break
    }
    priorFindings = review.findings
    if (round === MAX_ROUNDS) {
      log(`#${pr.num} ${pr.label}: hit round cap (${MAX_ROUNDS}) with ${actionable.length} finding(s) still open.`)
    }
  }

  return {
    prNumber: pr.num,
    label: pr.label,
    branch: pr.branch,
    title: pr.title,
    stabilized,
    roundsRun: rounds.length,
    rounds,
  }
}

// ---------------------------------------------------------------------------
// Drive all PRs concurrently; each runs its own sequential address→review loop.
// ---------------------------------------------------------------------------
log(`Stabilizing ${PRS.length} PRs (cap ${MAX_ROUNDS} rounds each): ${PRS.map((p) => '#' + p.num).join(', ')}`)

const results = await parallel(PRS.map((pr) => () => stabilizePr(pr)))

const report = PRS.map((pr, i) => results[i] || { prNumber: pr.num, label: pr.label, error: 'no result' })

const stable = report.filter((r) => r.stabilized).map((r) => '#' + r.prNumber)
const unstable = report.filter((r) => r && !r.stabilized && !r.error).map((r) => '#' + r.prNumber)
log(`Done. Stabilized: ${stable.join(', ') || 'none'}. Hit cap / unresolved: ${unstable.join(', ') || 'none'}.`)

return report
