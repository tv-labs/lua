export const meta = {
  name: 'recover-triage-implement-review',
  description: 'Recovery run: finish the interrupted Lua 5.3 suite issues, then review and address feedback across all 8 PRs. Never merges.',
  phases: [
    { title: 'Implement', detail: 'finish #261 (open PR) and freshly do #281/#262/#259; already-open PRs pass through' },
    { title: 'Review', detail: 'rigorous diff review of each PR, posted to the PR' },
    { title: 'Address', detail: 'apply review feedback on the pushed branch and push' },
  ],
}

const CONV = `
REPO: tv-labs/lua — an embedded Lua 5.3 VM written in Elixir. Working dir is a
git worktree off 'main'. Use the gh CLI (authenticated as davydog187).

WORKTREE ISOLATION (CRITICAL): you run in an ISOLATED git worktree under
.claude/worktrees/, NOT the operator's primary checkout. Run EVERY git command
from your current working directory. NEVER \`cd\` to the canonical checkout and
NEVER pass \`git -C <canonical-path>\`. Before ANY state-changing git command
(checkout/branch/reset/commit/push), run \`git rev-parse --show-toplevel\` and
confirm it points at your worktree under .claude/worktrees/ — NOT the primary
repo. If it points at the primary checkout, STOP. Mutating the primary checkout
(detaching its HEAD, leaving uncommitted/broken files behind) corrupts the
operator's working tree and must not happen. Reading files at the canonical path
is fine; state-changing git there is forbidden.

NON-NEGOTIABLE CONVENTIONS (from .agents/skills/ship-a-plan/SKILL.md and CLAUDE.md):
- Commit subject and PR title scope = the affected SUBSYSTEM, never a plan id.
  e.g. 'feat(stdlib): ...', 'fix(vm): ...', 'feat(pattern): ...'. NEVER 'feat(A45): ...'.
  Allowed scopes: lexer, parser, compiler, vm, stdlib, pattern, string, table,
  coroutine, error, suite, plan, docs, bench. The one exception: a commit that
  touches ONLY .agents/plans/<id>-*.md may use 'chore(<id>): ...'.
- NO plan-id references in source files, test moduledocs, @doc, or comments.
- NO "Co-Authored-By" trailers for AI agents. Plain authorship.
- NEVER push red tests to a READY PR. 'mix test' and
  'mix test test/lua53_suite_test.exs --only lua53' must pass before a ready PR.
- DO NOT merge. Opening the PR is the stopping point.
- The PR body must contain 'Closes #<issue>'.

VALIDATION (run from the worktree root; deps/_build are per-worktree):
  mix deps.get            # if deps are missing
  mix format
  mix compile --warnings-as-errors
  mix test
  mix test test/lua53_suite_test.exs --only lua53

TRIAGE pattern (.agents/skills/triage-suite-failure/SKILL.md): reproduce against a
fresh Lua value via a /tmp script run with 'mix run', find the failing line, reduce
to a 5-20 line repro, add it as a regression unit test under test/lua/vm/, classify,
then fix the smallest tractable thing OR narrow the skip range in
test/lua53_skips.exs (smallest range, precise reason, issue number, no plan-id).

PLAN FILE: write .agents/plans/<id>-<slug>.md per .agents/plans/README.md.
Required frontmatter: id, title, issue, pr (null until opened), branch, base: main,
status, direction: A. Required sections: Goal, Out of scope, Success criteria,
Implementation notes, Verification, Risks. Commit the plan first
('chore(<id>): start plan'), implement, then set status: review + pr: <number>
after opening the PR.
`

// mode: 'have-pr' (already open), 'finish' (branch pushed, needs PR), 'fresh' (from scratch)
const ISSUES = [
  { num: 279, label: 'debug-getinfo', mode: 'have-pr', branch: 'feat/debug-getinfo-name', pr: 290 },
  { num: 280, label: 'os-stdlib', mode: 'have-pr', branch: 'fix/runtime-type-errors', pr: 289 },
  { num: 257, label: 'pattern-poscap', mode: 'have-pr', branch: 'feat/pattern-position-capture', pr: 288 },
  { num: 260, label: 'gc-vm', mode: 'have-pr', branch: 'fix/gc-vm-errors', pr: 287 },
  {
    num: 261, label: 'metamethod', mode: 'finish', planId: 'A23a',
    branch: 'fix/metamethod-control-flow',
    directive: `The branch fix/metamethod-control-flow is ALREADY PUSHED to origin with a commit
implementing gsub replacement-string/value validation, plus plan A23a
(.agents/plans/A23a-gsub-replacement-errors.md). NO PR exists yet — your job is to
finish it. Check out the branch, validate fully, fix any failures strictly in
scope, then OPEN THE PR with 'Closes #261'. If mix test AND the lua53 suite are
green, open it ready; otherwise open it as a draft documenting what remains.
Update the plan to status: review + pr: <number>.`,
  },
  {
    num: 281, label: 'short-circuit', mode: 'fresh', planId: 'A45',
    branch: 'fix/short-circuit-level4',
    directive: `Bisect the constructs.lua:287-298 short-circuit harness at level=4 to the smallest
failing ((((a op b) op c) op d) op e) composition of and/or, reduce to a one-line
repro, classify the executor short-circuit edge case (suspected register aliasing
under conditional-jump bytecode, or a 'not' precedence wrinkle). Fix the executor
bug if tractable and land green; otherwise narrow the constructs.lua skip range with
a precise reason + issue and open a DRAFT PR documenting the reduced repro. Add the
repro as a regression test under test/lua/vm/ either way. Closes #281.`,
  },
  {
    num: 262, label: 'stdlib-data', mode: 'fresh', planId: 'A24a',
    branch: 'fix/stdlib-data-structure',
    directive: `Triage cluster #262 (parent plan A24, files: db.lua, literals.lua, constructs.lua,
sort.lua, big.lua). Pick the SINGLE most tractable concrete failure. IMPORTANT:
do NOT touch constructs.lua os/debug/short-circuit cases (covered by other PRs in
this batch) — prefer literals.lua, sort.lua, or db.lua. Reduce to a repro, add a
regression test, and fix it green if small/isolated else narrow that file's skip
range with a precise reason. Create .agents/plans/A24a-<slug>.md referencing parent
A24 and #262. One PR. Closes #262.`,
  },
  {
    num: 259, label: 'runtime-type', mode: 'fresh', planId: 'A21a',
    branch: 'fix/runtime-type-cluster',
    directive: `Triage cluster #259 (parent plan A21, files: math.lua, all.lua, utf8.lua,
coroutine.lua). IMPORTANT: the os standard library is ALREADY being added in a
separate PR (#289) — do NOT implement os.* or touch os here. Pick a DIFFERENT
single tractable concrete failure across utf8.lua / coroutine.lua / math.lua /
all.lua (a real type-error or semantics bug unrelated to os), reduce to a repro,
add a regression test, and fix it green if small/isolated else narrow that file's
skip range with a precise reason. Create .agents/plans/A21a-<slug>.md referencing
parent A21 and #259. One PR. Closes #259.`,
  },
]

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['issue', 'branch', 'planFile', 'prNumber', 'prUrl', 'testsGreen', 'draft', 'summary'],
  properties: {
    issue: { type: 'number' }, branch: { type: 'string' },
    planFile: { type: ['string', 'null'] },
    prNumber: { type: ['number', 'null'] }, prUrl: { type: ['string', 'null'] },
    testsGreen: { type: 'boolean' }, draft: { type: 'boolean' }, summary: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['prNumber', 'findings', 'overallVerdict'],
  properties: {
    prNumber: { type: 'number' }, overallVerdict: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['severity', 'file', 'title', 'detail'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          file: { type: 'string' }, line: { type: 'string' },
          title: { type: 'string' }, detail: { type: 'string' }, suggestedFix: { type: 'string' },
        },
      },
    },
  },
}
const ADDRESS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['prNumber', 'addressed', 'skipped', 'pushed', 'testsGreen', 'summary'],
  properties: {
    prNumber: { type: 'number' },
    addressed: { type: 'array', items: { type: 'string' } },
    skipped: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['finding', 'reason'],
        properties: { finding: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    pushed: { type: 'boolean' }, testsGreen: { type: 'boolean' }, summary: { type: 'string' },
  },
}

log(`Recovery: ${ISSUES.length} issues — ${ISSUES.filter(i => i.mode === 'have-pr').length} already open, ${ISSUES.filter(i => i.mode === 'finish').length} to finish, ${ISSUES.filter(i => i.mode === 'fresh').length} fresh`)

const results = await pipeline(
  ISSUES,

  // Stage 1: Implement / finish / pass-through
  (issue) => {
    if (issue.mode === 'have-pr') {
      // Already open and pushed — pass straight to review.
      return {
        issue: issue.num, branch: issue.branch, planFile: null,
        prNumber: issue.pr, prUrl: null, testsGreen: true, draft: false,
        summary: `Pre-existing open PR #${issue.pr}; passing through to review/address.`,
      }
    }
    const finishMode = issue.mode === 'finish'
    return agent(
      `${CONV}

You are ${finishMode ? 'FINISHING an interrupted issue' : 'implementing a fix for ONE issue end-to-end'} and ${finishMode ? 'opening its PR' : 'opening a PR'}.

Issue: #${issue.num}. Read it: \`gh issue view ${issue.num} --repo tv-labs/lua\`.
Plan id: ${issue.planId}. Branch: ${issue.branch}.

Directive:
${issue.directive}

Steps:
1. You are in a fresh worktree off main. ${finishMode
        ? `Check out the existing pushed branch: 'git fetch origin ${issue.branch} && git checkout ${issue.branch}'.`
        : `Create branch ${issue.branch}.`} Run 'mix deps.get' if deps are missing.
2. Confirm the baseline compiles ('mix compile --warnings-as-errors').
${finishMode ? '' : `3. Triage per the triage skill and write .agents/plans/${issue.planId}-<slug>.md. Commit it first: 'chore(${issue.planId}): start plan'. Then implement the smallest shippable fix + regression tests.\n`}4. Validate fully: mix format, mix compile --warnings-as-errors, mix test, and
   mix test test/lua53_suite_test.exs --only lua53. Capture the lua53 delta.
5. Commit (subsystem scope, never the plan id; body has 'Plan: ${issue.planId}' and
   'Closes #${issue.num}'; no Co-Authored-By). Push the branch.
6. Open the PR with 'gh pr create' (body follows the ship-a-plan template, contains
   'Closes #${issue.num}'). Green → ready PR; not green → '--draft' documenting what
   remains. Never push red tests to a ready PR.
7. Update the plan frontmatter to status: review + pr: <number>; commit
   'chore(${issue.planId}): mark plan as review' and push. DO NOT MERGE.

Return the structured result.`,
      { label: `${finishMode ? 'finish' : 'impl'}:${issue.label}`, phase: 'Implement', isolation: 'worktree', schema: IMPL_SCHEMA },
    )
  },

  // Stage 2: Review
  (impl, issue) => {
    if (!impl || !impl.prNumber) return null
    return agent(
      `${CONV}

You are an independent reviewer running the equivalent of /review on an open PR.
Be rigorous and skeptical.

PR #${impl.prNumber} for issue #${issue.num} on branch ${impl.branch}.
  gh pr view ${impl.prNumber} --repo tv-labs/lua
  gh pr diff ${impl.prNumber} --repo tv-labs/lua
Read surrounding context from the repo at /Users/dave/code/tvlabs/lua as needed.
Also read any existing review comments to avoid duplicating them.

Review for: CORRECTNESS (real bugs, wrong Lua 5.3 §semantics — consult the 5.3
manual when unsure, missed edge cases, integer/float subtleties); TESTS (does the
regression test actually pin the bug and fail pre-fix? are skip ranges minimal with
precise reasons and no plan-id?); REPO CONVENTIONS (subsystem scope not plan id; no
plan-id in source/tests/comments; no Co-Authored-By; body has 'Closes #${issue.num}')
— convention violations are blockers; SIMPLIFICATION (dead code, duplication).
${impl.draft ? 'NOTE: this PR is a DRAFT (fix not landed green) — focus on whether the investigation/skip is sound and what is needed to finish.\n' : ''}
Post a concise review summary to the PR:
  gh pr comment ${impl.prNumber} --repo tv-labs/lua --body "<your review markdown>"

Return structured findings (only real, actionable ones; empty array if clean).`,
      { label: `review:${issue.label}`, phase: 'Review', schema: REVIEW_SCHEMA },
    ).then(r => (r ? { ...r, impl, issue } : null))
  },

  // Stage 3: Address
  (review, issue) => {
    if (!review) return null
    const actionable = (review.findings || []).filter(f => f.severity !== 'nit')
    if (actionable.length === 0) {
      return {
        prNumber: review.prNumber, addressed: [],
        skipped: (review.findings || []).map(f => ({ finding: f.title, reason: 'nit — left for human discretion' })),
        pushed: false, testsGreen: review.impl ? review.impl.testsGreen : false,
        summary: 'No actionable (blocker/major/minor) findings; nothing to push.',
      }
    }
    const findingsText = (review.findings || [])
      .map((f, i) => `${i + 1}. [${f.severity}] ${f.file}${f.line ? ':' + f.line : ''} — ${f.title}\n   ${f.detail}${f.suggestedFix ? '\n   Suggested: ' + f.suggestedFix : ''}`)
      .join('\n')
    return agent(
      `${CONV}

You are addressing code-review feedback on an open PR by pushing fixes to its branch.

PR #${review.prNumber} for issue #${issue.num}, branch ${issue.branch}.
You are in a fresh worktree off main. Check out the PR branch:
  git fetch origin ${issue.branch}
  git checkout ${issue.branch}
  mix deps.get   # if deps are missing

Findings:
${findingsText}

Rules:
- Address every BLOCKER and MAJOR finding; address MINOR when the fix is clear and
  low-risk. SKIP a finding only if it is wrong, out of scope, or a pure nit —
  record it in 'skipped' with a reason. Do not expand the PR's scope.
- Re-validate: mix format, mix compile --warnings-as-errors, mix test, and
  mix test test/lua53_suite_test.exs --only lua53. Never push red tests to a ready PR.
- Commit (subsystem scope, no plan id, no Co-Authored-By). Push to origin ${issue.branch}.
- If the PR was a draft and is now fully green, you may 'gh pr ready ${review.prNumber} --repo tv-labs/lua'.
- DO NOT MERGE.

Return the structured result.`,
      { label: `address:${issue.label}`, phase: 'Address', isolation: 'worktree', schema: ADDRESS_SCHEMA },
    )
  },
)

const report = ISSUES.map((issue, i) => {
  const row = results[i]
  return { issue: issue.num, label: issue.label, mode: issue.mode, ...(row || { error: 'no result' }) }
})
log('Recovery complete.')
return report
