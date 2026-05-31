export const meta = {
  name: 'triage-implement-review',
  description: 'For each Lua 5.3 suite issue: triage, plan, implement in an isolated worktree, open a ready PR, review it, and address the review feedback. Never merges.',
  phases: [
    { title: 'Implement', detail: 'triage + plan + implement + open ready PR (one worktree per issue)' },
    { title: 'Review', detail: 'rigorous diff review of each PR, posted to the PR' },
    { title: 'Address', detail: 'apply review feedback on the pushed branch and push' },
  ],
}

// ---------------------------------------------------------------------------
// Shared repo conventions every agent must honor (from .agents/skills/*).
// ---------------------------------------------------------------------------
const CONV = `
REPO: tv-labs/lua — an embedded Lua 5.3 VM written in Elixir. Working dir is a
git worktree off 'main'. Use the gh CLI (authenticated as davydog187).

NON-NEGOTIABLE CONVENTIONS (from .agents/skills/ship-a-plan/SKILL.md and CLAUDE.md):
- Commit subject and PR title scope = the affected SUBSYSTEM, never a plan id.
  e.g. 'feat(stdlib): ...', 'fix(vm): ...', 'feat(pattern): ...'. NEVER 'feat(A43): ...'.
  Allowed scopes: lexer, parser, compiler, vm, stdlib, pattern, string, table,
  coroutine, error, suite, plan, docs, bench. The one exception: a commit that
  touches ONLY .agents/plans/<id>-*.md may use 'chore(<id>): ...'.
- NO plan-id references in source files, test moduledocs, @doc, or comments.
  The plan id lives in the commit body ('Plan: <id>') and the PR body only.
- NO "Co-Authored-By" trailers for AI agents. Plain authorship.
- NEVER push red tests to a READY PR. 'mix test' and
  'mix test test/lua53_suite_test.exs --only lua53' must pass before a ready PR.
- DO NOT merge. Opening the PR is the stopping point.
- Use conventional-commit types: feat, fix, perf, chore, docs, test, refactor.
- The PR body must contain 'Closes #<issue>'.

VALIDATION (run from the worktree root; deps/_build are per-worktree):
  mix deps.get            # only if deps are missing
  mix format
  mix compile --warnings-as-errors
  mix test
  mix test test/lua53_suite_test.exs --only lua53

TRIAGE pattern (from .agents/skills/triage-suite-failure/SKILL.md): reproduce a
suite failure against a fresh Lua value via a /tmp script run with 'mix run', find
the failing line, reduce to a 5-20 line repro, add it as a regression unit test
under test/lua/vm/ (or test/lua/vm/stdlib/), classify, then fix the smallest
tractable thing OR narrow the skip range in test/lua53_skips.exs (smallest range,
precise reason, issue number — no plan-id references in the reason).

PLAN FILE: write .agents/plans/<id>-<slug>.md following .agents/plans/README.md.
Required frontmatter: id, title, issue, pr (null until opened), branch, base: main,
status, direction: A. Required sections: Goal, Out of scope, Success criteria,
Implementation notes, Verification, Risks. Commit the plan as the first commit
('chore(<id>): start plan'), then implement, then update status to 'review' and
set pr: <number> after opening the PR.
`

// ---------------------------------------------------------------------------
// Per-issue directives. Each pre-assigned a unique plan id + branch so the 8
// lifecycles never collide. Cluster issues (#259-262) are triage umbrellas
// spanning many suite files — the directive scopes them to ONE shippable fix.
// ---------------------------------------------------------------------------
const ISSUES = [
  {
    num: 280,
    planId: 'A43',
    branch: 'feat/os-stdlib',
    label: 'os-stdlib',
    directive: `Add a new Lua.VM.Stdlib.Os module (lib/lua/vm/stdlib/os.ex) implementing the
side-effect-free functions: os.time([table]), os.date([format[, time]]),
os.clock(), os.difftime(t2, t1), and a safe os.getenv stub (returns nil).
Mirror the layout of lib/lua/vm/stdlib/math.ex. Register it in
lib/lua/vm/stdlib.ex alongside String/Math/Table/Utf8/Debug. Keep
os.execute/exit/remove/rename/tmpname sandboxed (do NOT install them).
This is well-scoped and should reach a fully GREEN ready PR. Narrow the
constructs.lua skip range that covered the os.time gap (around lines 237-248).`,
  },
  {
    num: 279,
    planId: 'A44',
    branch: 'feat/debug-getinfo-name',
    label: 'debug-getinfo-name',
    directive: `Implement name/namewhat for debug.getinfo(level, 'n') in
lib/lua/vm/stdlib/debug.ex (currently hardcoded nil at lines ~64-126).
This is explicitly NON-TRIVIAL. Use the tractable approach: capture the
declared name during codegen for the common 'function X(...)' and
'local function X(...)' forms, retain it on Lua.Compiler.Prototype, and
populate name/namewhat from it. Document in the plan's "Out of scope" that
table-field, dynamic-dispatch, and anonymous-closure naming (the full
PUC-Lua getfuncname caller-instruction walk) are deferred. Add a regression
test pinning the issue's repro (function F; F(1); debug.getinfo(1,'n').name == 'F').
Narrow constructs.lua skip line 226. If the codegen change proves infeasible to
land green in scope, open a DRAFT PR documenting the investigation and narrow
the skip with a precise reason instead.`,
  },
  {
    num: 281,
    planId: 'A45',
    branch: 'fix/short-circuit-level4',
    label: 'short-circuit-level4',
    directive: `Bisect the constructs.lua:287-298 short-circuit harness at level=4 (the suite
default) to the smallest failing ((((a op b) op c) op d) op e) composition of
and/or, reduce it to a one-line repro, and classify the executor short-circuit
edge case (suspected register aliasing under conditional-jump bytecode, or a
'not' precedence wrinkle). Fix the executor bug if tractable and land it green;
otherwise narrow the constructs.lua skip range with a precise reason + issue
number and open a DRAFT PR documenting the reduced repro. Add the repro as a
regression test under test/lua/vm/ either way.`,
  },
  {
    num: 257,
    planId: 'A46',
    branch: 'feat/pattern-position-capture',
    label: 'pattern-position-capture',
    directive: `The issue is a multi-feature pattern-engine epic; ship ONE focused PR. Per the
issue's suggested order, implement POSITION CAPTURE '()' first (smallest, most
mechanical): an empty parenthesised group captures the current 1-based position
as an integer, not a substring. Work in lib/lua/vm/stdlib/pattern.ex; cover
string.find/match/gmatch/gsub. Add regression tests in
test/lua/vm/stdlib/pattern_test.exs. Advance pm.lua's skip range in
test/lua53_skips.exs to the next failure point. Leave %f[set] frontier, %b
balanced match, and %1..%9 backreferences for explicit follow-up plans (note
them in "Out of scope"). Target a GREEN ready PR for position capture alone.`,
  },
  {
    num: 259,
    planId: 'A21a',
    branch: 'fix/runtime-type-errors',
    label: 'runtime-type-errors',
    parent: 'A21',
    directive: `Triage cluster #259 (parent plan A21, files: math.lua, all.lua, utf8.lua,
coroutine.lua). Do NOT try to fix the whole cluster. Run each file per the
triage skill, pick the SINGLE most tractable concrete failure (prefer a real
fix over a skip when small and isolated), reduce it to a repro, add a
regression test, and either fix it green or narrow that file's skip range with
a precise reason. Create a focused sub-plan .agents/plans/A21a-<slug>.md that
references parent A21 and #259 in its body. One PR.`,
  },
  {
    num: 260,
    planId: 'A22a',
    branch: 'fix/gc-vm-errors',
    label: 'gc-vm-errors',
    parent: 'A22',
    directive: `Triage cluster #260 (parent plan A22, files: gc.lua and attrib.lua). NOTE:
attrib.lua is permanently deferred (filesystem/package I/O) — focus on gc.lua.
Run gc.lua per the triage skill, find the first VM-level error, reduce to a
repro, add a regression test, and either fix it green if tractable or narrow
gc.lua's skip range with a precise reason + issue. Create a focused sub-plan
.agents/plans/A22a-<slug>.md referencing parent A22 and #260. One PR.`,
  },
  {
    num: 261,
    planId: 'A23a',
    branch: 'fix/metamethod-control-flow',
    label: 'metamethod-control-flow',
    parent: 'A23',
    directive: `Triage cluster #261 (parent plan A23, files: events.lua, errors.lua,
closure.lua, pm.lua, goto.lua — metamethod & control-flow assertion failures).
Pick the SINGLE most tractable concrete failure, reduce to a repro, add a
regression test, and fix it green if small/isolated else narrow that file's
skip range with a precise reason. Create a focused sub-plan
.agents/plans/A23a-<slug>.md referencing parent A23 and #261. One PR.`,
  },
  {
    num: 262,
    planId: 'A24a',
    branch: 'fix/stdlib-data-structure',
    label: 'stdlib-data-structure',
    parent: 'A24',
    directive: `Triage cluster #262 (parent plan A24, files: db.lua, literals.lua,
constructs.lua, sort.lua, big.lua — stdlib & data-structure assertion failures).
Pick the SINGLE most tractable concrete failure (avoid overlap with the
constructs.lua os/debug/short-circuit issues already covered by other PRs in
this batch — prefer literals.lua, sort.lua, or db.lua), reduce to a repro, add
a regression test, and fix it green if small/isolated else narrow that file's
skip range. Create a focused sub-plan .agents/plans/A24a-<slug>.md referencing
parent A24 and #262. One PR.`,
  },
]

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['issue', 'branch', 'planFile', 'prNumber', 'prUrl', 'testsGreen', 'draft', 'summary'],
  properties: {
    issue: { type: 'number' },
    branch: { type: 'string' },
    planFile: { type: 'string', description: 'path to the plan file created' },
    prNumber: { type: ['number', 'null'] },
    prUrl: { type: ['string', 'null'] },
    testsGreen: { type: 'boolean', description: 'true if mix test AND the lua53 suite passed' },
    draft: { type: 'boolean', description: 'true if the PR was opened as a draft (fix not landed green)' },
    summary: { type: 'string', description: '3-6 sentences: what was triaged, the fix or skip shipped, suite delta' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['prNumber', 'findings', 'overallVerdict'],
  properties: {
    prNumber: { type: 'number' },
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

const ADDRESS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['prNumber', 'addressed', 'skipped', 'pushed', 'testsGreen', 'summary'],
  properties: {
    prNumber: { type: 'number' },
    addressed: { type: 'array', items: { type: 'string' } },
    skipped: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['finding', 'reason'],
        properties: { finding: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    pushed: { type: 'boolean' },
    testsGreen: { type: 'boolean' },
    summary: { type: 'string' },
  },
}

// ---------------------------------------------------------------------------
// Pipeline: each issue flows Implement -> Review -> Address independently.
// No barriers — issue A can be in Address while issue B is still implementing.
// ---------------------------------------------------------------------------
log(`Starting triage→implement→review for ${ISSUES.length} issues: ${ISSUES.map(i => '#' + i.num).join(', ')}`)

const results = await pipeline(
  ISSUES,

  // --- Stage 1: Implement (isolated worktree) ---
  (issue) => agent(
    `${CONV}

You are implementing a fix for ONE GitHub issue end-to-end, then opening a PR.

Issue: #${issue.num}. Read it first: \`gh issue view ${issue.num} --repo tv-labs/lua\`.

Pre-assigned (use these EXACTLY so parallel work does not collide):
- Plan id: ${issue.planId}
- Branch:  ${issue.branch}
${issue.parent ? `- Parent cluster plan: ${issue.parent}\n` : ''}
Directive for this issue:
${issue.directive}

Steps:
1. You are already in a fresh worktree off main. Run 'mix deps.get' if deps are
   missing, then confirm the baseline is clean: 'mix compile --warnings-as-errors'
   and 'mix test' must pass before you change anything. If the baseline is broken,
   stop and report it in the summary (prNumber null).
2. Create branch ${issue.branch}.
3. Triage the failure per the triage skill and write the plan file
   .agents/plans/${issue.planId}-<slug>.md. Commit it first: 'chore(${issue.planId}): start plan'.
4. Implement the smallest shippable fix in the directive. Add regression tests.
   Run 'mix format' after meaningful changes. Stay strictly in scope — log any
   out-of-scope discovery in the plan's ## Discoveries instead of expanding.
5. Validate: mix format, mix compile --warnings-as-errors, mix test, and
   mix test test/lua53_suite_test.exs --only lua53. Capture the lua53 file delta.
6. Commit with a conventional-commit subject scoped to the SUBSYSTEM (never the
   plan id), body explaining the change + 'Plan: ${issue.planId}', and 'Closes #${issue.num}'.
   No Co-Authored-By trailers.
7. Push the branch to origin and open the PR with 'gh pr create'. The PR body
   must follow the ship-a-plan template (Goal, Success criteria as checked boxes,
   Changes, Verification output, Out of scope) and contain 'Closes #${issue.num}'.
   - If mix test AND the lua53 suite are GREEN: open a normal ready PR.
   - If you could NOT land the fix green in scope: open a DRAFT PR
     ('gh pr create --draft') whose body documents the reduced repro / narrowed
     skip and what remains. Never push red tests to a ready PR.
8. Update the plan frontmatter to status: review and pr: <number>; commit
   'chore(${issue.planId}): mark plan as review' and push.
9. DO NOT MERGE.

Return the structured result. testsGreen reflects whether BOTH mix test and the
lua53 suite passed. draft reflects whether you opened the PR as a draft.`,
    { label: `impl:${issue.label}`, phase: 'Implement', isolation: 'worktree', schema: IMPL_SCHEMA },
  ),

  // --- Stage 2: Review (no worktree; reads the PR via gh) ---
  (impl, issue) => {
    if (!impl || !impl.prNumber) return null
    return agent(
      `${CONV}

You are an independent reviewer running the equivalent of the /review command on
an open PR. Be rigorous and skeptical — assume the author may have missed something.

PR #${impl.prNumber} for issue #${issue.num} on branch ${impl.branch}.
Read the diff and metadata:
  gh pr view ${impl.prNumber} --repo tv-labs/lua
  gh pr diff ${impl.prNumber} --repo tv-labs/lua
You may also read the full files in the repo at /Users/dave/code/tvlabs/lua to
get surrounding context for the diff.

Review for:
- CORRECTNESS: real bugs, wrong Lua 5.3 §semantics (check the 5.3 reference
  manual when unsure), missed edge cases, off-by-one, error-message mismatches,
  integer/float subtleties.
- TESTS: does the regression test actually pin the bug? Would it fail before the
  fix? Are edge cases covered? Did the lua53 skip range narrow correctly (smallest
  range, precise reason, no plan-id in the reason)?
- REPO CONVENTIONS (these are blockers if violated): commit/PR scope is the
  subsystem not a plan id; no plan-id references in source/test/comments; no
  Co-Authored-By trailers; PR body has 'Closes #${issue.num}'.
- SIMPLIFICATION / reuse: dead code, needless complexity, duplication.
${impl.draft ? '- NOTE: this PR is a DRAFT (fix not landed green). Focus your review on whether the investigation/skip is sound and what is needed to finish.\n' : ''}
Post a concise review to the PR summarizing your findings:
  gh pr comment ${impl.prNumber} --repo tv-labs/lua --body "<your review markdown>"

Then return the structured findings. Only include findings that are real and
actionable. If the PR is clean, return an empty findings array with a positive
overallVerdict.`,
      { label: `review:${issue.label}`, phase: 'Review', schema: REVIEW_SCHEMA },
    ).then(r => (r ? { ...r, impl, issue } : null))
  },

  // --- Stage 3: Address feedback (worktree on the pushed branch) ---
  (review, issue) => {
    if (!review) return null
    const actionable = (review.findings || []).filter(f => f.severity !== 'nit')
    if (actionable.length === 0) {
      return {
        prNumber: review.prNumber,
        addressed: [],
        skipped: (review.findings || []).map(f => ({ finding: f.title, reason: 'nit — left for human discretion' })),
        pushed: false,
        testsGreen: review.impl ? review.impl.testsGreen : false,
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

You are in a fresh worktree off main. Check out the PR branch onto it:
  git fetch origin ${issue.branch}
  git checkout ${issue.branch}
  mix deps.get   # if deps are missing

Review findings to address:
${findingsText}

Rules:
- Address every BLOCKER and MAJOR finding. Address MINOR findings when the fix is
  clear and low-risk. You may SKIP a finding only if it is wrong, out of scope for
  this PR, or a pure nit — record it in 'skipped' with a reason. Do not expand the
  PR's scope to chase unrelated improvements.
- Re-validate: mix format, mix compile --warnings-as-errors, mix test, and
  mix test test/lua53_suite_test.exs --only lua53. Do not push red tests to a
  ready PR.
- Commit with a conventional-commit subject scoped to the subsystem
  ('fix(<scope>): address review feedback' or more specific). No plan-id scope,
  no Co-Authored-By. Push to origin ${issue.branch}.
- If the PR was a draft and is now fully green, you may mark it ready with
  'gh pr ready ${review.prNumber} --repo tv-labs/lua'.
- DO NOT MERGE.

Return the structured result.`,
      { label: `address:${issue.label}`, phase: 'Address', isolation: 'worktree', schema: ADDRESS_SCHEMA },
    )
  },
)

// ---------------------------------------------------------------------------
// Assemble the final report.
// ---------------------------------------------------------------------------
const report = ISSUES.map((issue, i) => {
  const row = results[i]
  return { issue: issue.num, label: issue.label, ...(row || { error: 'pipeline produced no result' }) }
})

log('All issue pipelines complete.')
return report
