export const meta = {
  name: 'ship-issue-batch',
  description: 'Plan, implement, PR, and loop-review 7 tv-labs/lua issues following ship-a-plan',
  phases: [
    { title: 'Preflight', detail: 'verify main is clean, compiles, tests green' },
    { title: 'Plan', detail: 'per issue: read/author a ship-a-plan-conformant plan' },
    { title: 'Implement', detail: 'per issue: branch + implement + green tests + PR (worktree-isolated)' },
    { title: 'Review', detail: 'per PR: adversarial review -> fix, loop until clean (max 3)' },
  ],
}

// ---- The 7 issues, with everything an agent needs to act autonomously ----
const ITEMS = [
  {
    issue: 264, id: 'A30', slug: 'examples-directory', branch: 'docs/examples',
    type: 'docs', scope: 'examples', planState: 'ready',
    planFile: '.agents/plans/A30-examples-directory.md',
    guidance: 'Plan is already status: ready. Read it and implement EXACTLY what it specifies (an examples/ directory of runnable scripts). Do not expand scope.',
  },
  {
    issue: 266, id: 'A32', slug: 'docstring-audit', branch: 'docs/docstring-audit',
    type: 'docs', scope: 'stdlib', planState: 'ready',
    planFile: '.agents/plans/A32-docstring-audit.md',
    guidance: 'Plan is already status: ready. Read it and implement EXACTLY (audit + fill @doc/@moduledoc on public API). Pure docstring/doc work; no behavior changes.',
  },
  {
    issue: 273, id: 'B9', slug: 'stdlib-hot-paths', branch: 'perf/stdlib-hot-paths',
    type: 'perf', scope: 'stdlib', planState: 'missing',
    planFile: '.agents/plans/B9-stdlib-hot-paths.md',
    guidance: 'No plan file exists yet — AUTHOR .agents/plans/B9-stdlib-hot-paths.md from issue #273. Scope (from the issue): (1) string.format iolist accumulation + single IO.iodata_to_binary at end in lib/lua/vm/stdlib/string.ex (~333-350), replacing per-char binary concat; (2) table.sort/table.concat fast path that skips Executor.table_index/3 + table_newindex/3 when table.metatable == nil, in lib/lua/vm/stdlib/table.ex (~249-288); (3) apply_width_flags use byte_size not String.length for single-byte %d/%f output. OUT OF SCOPE: the O(n^2) comparator insertion sort, and Table.put order_tail allocation. Behavior must be identical — these are perf-only. mix test must stay green.',
  },
  {
    issue: 276, id: 'A47', slug: 'open-upvalue-block-close', branch: 'fix/open-upvalue-block-close',
    type: 'fix', scope: 'vm', planState: 'missing',
    planFile: '.agents/plans/A47-open-upvalue-block-close.md',
    guidance: 'No plan file exists — AUTHOR .agents/plans/A47-open-upvalue-block-close.md from issue #276 (a real VM bug). Root cause: state.open_upvalues is keyed by register and never closed at block (do/if/while/for/repeat) end; a later block reusing the same register reuses a stale cell ref (lib/lua/vm/executor.ex:707). Preferred fix (option 1 in the issue): emit a :close_open_upvalues instruction at block-scope end, parametrised by the registers that opened cells in that block; the executor removes ONLY those entries from state.open_upvalues, never touching state.upvalue_cells (existing closures hold valid cell refs and resolve through it). CRITICAL: loops re-enter the block body across iterations — cells must persist across iterations and close only on loop exit. ACCEPTANCE: the two-sibling-do-block repro in the issue passes; remove calls.lua:65-69 from test/lua53_skips.exs and narrow that file range; add a regression test to test/lua/vm/upvalue_test.exs (two sibling do blocks declaring captured locals on the same register). Run `mix test` AND `mix test --only lua53`; no regressions in upvalue/closure tests or the suite.',
  },
  {
    issue: 263, id: 'A26', slug: 'error-message-quality', branch: 'errors/quality-pass',
    type: 'feat', scope: 'error', planState: 'blocked',
    planFile: '.agents/plans/A26-error-message-quality.md',
    guidance: 'Plan is status: blocked on A19 (error line-info), which is now status: review — the :line/:source/:call_stack data is wired in. UNBLOCK it: set frontmatter status: ready, then execute. Audit every user-visible error message against PUC-Lua and fix rough edges per the plan: prominent `at <source>:<line>:` line, category-specific suggestions (no generic filler), readable on TTY and non-TTY. Add the fixture/gallery tests the plan lists. If some raise sites still lack line info (because A19 is not merged to main), note exactly which in ## Discoveries and audit what is present rather than expanding scope.',
  },
  {
    issue: 265, id: 'A31', slug: 'readme-rewrite', branch: 'docs/readme-rewrite',
    type: 'docs', scope: 'readme', planState: 'blocked', dep: 'A30',
    planFile: '.agents/plans/A31-readme-rewrite.md',
    guidance: 'Plan is status: blocked on A30 (README links to examples). A30 ships in a SIBLING PR in this same batch — its example files will NOT be in your worktree. UNBLOCK by decoupling: read .agents/plans/A30-examples-directory.md to learn the exact example filenames/paths A30 creates, and have the README link to those paths (they resolve once both PRs merge). Set frontmatter status: ready and execute the rewrite (1.0 positioning, quickstart, tour). Note the cross-PR link dependency in ## Discoveries.',
  },
  {
    issue: 297, id: 'A48', slug: 'vfs-sandbox', branch: 'feat/vfs-sandbox',
    type: 'feat', scope: 'stdlib', planState: 'missing',
    planFile: '.agents/plans/A48-vfs-sandbox.md',
    guidance: 'No plan file and no labels — this is a NEW FEATURE. First AUTHOR .agents/plans/A48-vfs-sandbox.md. Goal (issue #297): make os/filesystem operations safe by default by running the VM inside a virtual filesystem instead of sandboxing. Integrate github.com/ivarvong/vfs (a VFS.Mountable protocol with pluggable backends). Default backend = in-memory FS. Provide an API for users to populate the FS with files and mount other backends. Use a special dir (e.g. /lua/deps) as the mechanism for pulling Lua dependencies via require. Rewire lib/lua/vm/stdlib/os.ex (and any file IO) to operate through the VFS. THIS IS LARGE: research the vfs library API first (its README/hexdocs), design the integration in the plan, add the dep to mix.exs, then implement incrementally. If you cannot reach green tests with a complete feature, DO NOT open a PR with red tests — instead implement the smallest coherent slice that is green (e.g. dep + in-memory VFS + os ops rerouted, deferring deps-dir require), document the deferral in ## Discoveries, and open the PR for that slice. Keep mix test green.',
  },
]

const PLAN_SCHEMA = {
  type: 'object',
  required: ['id', 'issue', 'branch', 'ready', 'planMarkdown', 'filesToTouch', 'commitType', 'commitScope', 'title'],
  properties: {
    id: { type: 'string' },
    issue: { type: 'number' },
    branch: { type: 'string' },
    title: { type: 'string', description: 'one-line plan title for the commit/PR subject (NO plan id)' },
    commitType: { type: 'string', enum: ['feat', 'fix', 'perf', 'docs', 'chore', 'refactor', 'test'] },
    commitScope: { type: 'string', description: 'affected subsystem, NEVER the plan id' },
    ready: { type: 'boolean', description: 'true if the plan is complete, in-scope, and safe to implement' },
    planMarkdown: { type: 'string', description: 'the FULL plan file contents incl YAML frontmatter with status: ready and all required sections (Goal, Out of scope, Success criteria, Implementation notes, Verification, Risks)' },
    filesToTouch: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const IMPL_SCHEMA = {
  type: 'object',
  required: ['opened', 'testsGreen', 'summary'],
  properties: {
    opened: { type: 'boolean', description: 'true only if a PR was actually opened' },
    prNumber: { type: ['number', 'null'] },
    prUrl: { type: ['string', 'null'] },
    branch: { type: ['string', 'null'] },
    testsGreen: { type: 'boolean' },
    blockedReason: { type: ['string', 'null'], description: 'if no PR opened, why (e.g. red tests, scope too large)' },
    summary: { type: 'string' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['clean', 'findings', 'summary'],
  properties: {
    clean: { type: 'boolean', description: 'true if no real blocker/major findings remain' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'severity', 'real'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          real: { type: 'boolean' },
          rationale: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  required: ['pushed', 'summary'],
  properties: {
    pushed: { type: 'boolean' },
    addressed: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}

const SHIP_RULES = `
WORKTREE ISOLATION (CRITICAL — read first):
- You run in an ISOLATED git worktree under .claude/worktrees/, NOT the operator's
  primary checkout. Run EVERY git command from your current working directory.
- NEVER \`cd\` to the canonical checkout path and NEVER pass \`git -C <canonical-path>\`.
  Do not use absolute paths that resolve into the primary checkout for any git write.
- Before ANY state-changing git command (checkout, branch, reset, commit, push), run
  \`git rev-parse --show-toplevel\` and confirm it points at your worktree under
  .claude/worktrees/ — NOT the primary repo. If it points at the primary checkout, STOP
  and do not run the command. Mutating the primary checkout (detaching its HEAD, leaving
  uncommitted/broken files behind) corrupts the operator's working tree — this has
  happened before and must not recur. Reading files under the canonical checkout is fine;
  state-changing git there is forbidden.

SHIP-A-PLAN CONTRACT (.agents/skills/ship-a-plan/SKILL.md) — follow exactly:
- Branch off main inside this worktree: git checkout -b <branch>.
- First commit: create/update the plan file with status: in-progress, commit "chore(<id>): start plan" (this commit touches ONLY the plan file).
- Implement ONLY what is in the plan's scope. Touch only the files named. If something out of scope appears, record it in the plan's "## Discoveries" section, do NOT expand scope.
- Run: mix format; mix compile --warnings-as-errors; mix test  (plus "mix test --only lua53" if the plan's success criteria mention the suite). NEVER push or PR with red tests — if you cannot get green, stop and report opened:false with blockedReason.
- Implementation commit subject is "<type>(<scope>): <title>" where <scope> is the SUBSYSTEM (vm, stdlib, parser, error, examples, readme, ...), NEVER the plan id. Body includes a short why + "Plan: <id>" + "Closes #<issue>".
- ABSOLUTELY NO "Co-Authored-By" trailer for AI. Plain authorship.
- Before pushing, run: git log --format="%h %s" main..HEAD and confirm no subject scope is a plan id (A30, B9, etc.) except plan-only "chore(<id>): ..." commits.
- git push -u origin <branch>; then gh pr create with title "<type>(<scope>): <title>" and a body from the ship-a-plan template (## title, Plan: link, Closes #<issue>, Goal, Success criteria as checked boxes with how-verified, Changes from git diff --stat, Verification output tail, Out of scope).
- After PR opens: set plan frontmatter status: review and pr: <number>, append a "## What changed" section, commit "chore(<id>): mark plan as review", push.
- DO NOT run gh pr merge. Stop at PR creation.
`

function planPrompt(item) {
  return `You are preparing a ship-a-plan plan file for issue #${item.issue} in the tv-labs/lua repo (an Elixir implementation of Lua 5.3).

Run \`gh issue view ${item.issue}\` for full context. Read ROADMAP.md and the ship-a-plan skill at .agents/skills/ship-a-plan/SKILL.md for conventions. Plan state: ${item.planState}. Target plan file: ${item.planFile}. Branch: ${item.branch}.

${item.guidance}

Produce a COMPLETE, ship-a-plan-conformant plan as structured output. The planMarkdown field must be the full file contents: YAML frontmatter (id: ${item.id}, title, issue: ${item.issue}, pr: null, branch: ${item.branch}, base: main, status: ready, direction) followed by the required sections — Goal, Out of scope, Success criteria (checkbox list), Implementation notes (name the exact files), Verification (exact commands), Risks. ${item.planState === 'ready' ? 'A ready plan already exists at the target path — read it and return its content essentially as-is (confirm it is complete; keep status: ready).' : item.planState === 'blocked' ? 'A blocked plan exists — read it, resolve the blocker per the guidance, and return an UNBLOCKED version with status: ready.' : 'Author the plan from scratch based on the issue.'}

This is a READ/THINK step only — do NOT modify any files, branch, or push. Set ready:true only if the plan is complete and safe to implement now. Pick commitType/commitScope per ship-a-plan (scope = subsystem, never the plan id).`
}

function implPrompt(item, plan) {
  return `You are implementing plan ${item.id} for issue #${item.issue} in tv-labs/lua, end-to-end, in this isolated git worktree (a fresh checkout of main). You MUST follow the ship-a-plan contract precisely.

${SHIP_RULES}

Plan title: ${plan.title}
Branch: ${item.branch}
Commit/PR subject scope: ${item.type}(${item.scope})  (confirm against ship-a-plan; scope is the subsystem, never the plan id)
Plan file to create/update: ${item.planFile}
Files expected in scope: ${(plan.filesToTouch || []).join(', ') || '(see plan)'}

The plan file contents to write (status: in-progress for the first commit, then status: review at the end):
--- BEGIN PLAN ---
${plan.planMarkdown}
--- END PLAN ---

${item.guidance}

Work the contract: pre-flight (you are already on a clean main checkout), branch, plan-start commit, implement, format/compile/test green, implementation commit (Closes #${item.issue}), push, gh pr create, plan status->review commit, push. Return opened:true with prNumber/prUrl only if a PR was actually created with green tests. If you cannot reach green or the scope is too large to finish safely, return opened:false with a precise blockedReason and leave no broken PR.`
}

function reviewPrompt(item, prNumber, round) {
  return `You are a skeptical senior reviewer (round ${round}) of PR #${prNumber} (plan ${item.id}, issue #${item.issue}) in tv-labs/lua, an Elixir Lua 5.3 VM.

Inspect it read-only: \`gh pr view ${prNumber}\`, \`gh pr diff ${prNumber}\`, and \`gh pr checks ${prNumber}\` if available. You may also \`git fetch origin ${item.branch}\` and \`git show origin/${item.branch}:<path>\` to read files at the branch HEAD — do NOT check out, edit, branch, or push anything.

Hunt for REAL problems, default to skepticism but mark real:false for anything you cannot substantiate:
- Correctness bugs / regressions, especially in VM/executor or stdlib hot paths.
- Scope violations: changes to files not in the plan, or behavior changes in a perf-only/docs-only PR.
- Missing or weak tests for the behavior changed; for fix/perf PRs, is there a regression test?
- ship-a-plan rule violations: plan id used as a commit/PR subject scope (e.g. "fix(A47): ..."), a "Co-Authored-By" AI trailer present, red tests, or merged-without-review.
- Doc/quality PRs: accuracy, broken links, claims that don't match the code.

POST your review to the PR so it leaves a durable, visible trail (mark it clearly as an
automated round-${round} review). GitHub blocks self-approval because the PR author is the
gh user, so use the --comment event, NEVER --approve:
  gh pr review ${prNumber} --repo tv-labs/lua --comment --body "<your review markdown>"
The posted body should lead with a one-line verdict (clean / clean-with-nits /
changes-requested) and then the findings, each tagged [blocker]/[major]/[minor]/[nit] with
file:line and a concrete rationale. If clean, say so and note what you verified. This is a
read-only review otherwise: do NOT check out, edit, branch, or push anything.

Classify each finding severity (blocker|major|minor|nit) and real (true/false). Set clean:true ONLY if no real blocker or major findings remain (minor/nit do not block).`
}

function fixPrompt(item, prNumber, review) {
  return `You are addressing review feedback on PR #${prNumber} (plan ${item.id}, issue #${item.issue}) in tv-labs/lua, in this isolated worktree.

Check out the PR branch here: \`git fetch origin ${item.branch} && git checkout ${item.branch}\`.

Review findings to address (fix every real blocker/major; fix real minors if quick; ignore nits and real:false):
${JSON.stringify(review.findings || [], null, 2)}

Make the minimal correct changes, stay within the plan's scope, run \`mix format\` and \`mix test\` (and \`mix test --only lua53\` if this plan touches the suite) until green. Commit as "${item.type}(${item.scope}): address review feedback" — NO plan-id scope, NO Co-Authored-By trailer — and \`git push\`. Do NOT merge. Return pushed:true only if you committed and pushed a fix; pushed:false if nothing needed changing.`
}

// ---------------- run ----------------

phase('Preflight')
const pre = await agent(
  `In the tv-labs/lua repo working dir, verify the base is shippable before a batch of PRs is opened. Run: \`git status --porcelain\`, \`git rev-parse --abbrev-ref HEAD\` (should be main), \`mix compile --warnings-as-errors\`, and \`mix test\`. The tree is "clean enough" if the ONLY entries in git status are untracked files under .agents/workflows/ (the orchestration scripts themselves — these never enter a worktree checkout and are not part of any PR); ignore those. Report ok:true only if, ignoring .agents/workflows/ untracked files, the tree has no other changes, you are on main, it compiles with no warnings, and the full test suite passes. Include the test pass/fail counts in baseline.`,
  { phase: 'Preflight', schema: { type: 'object', required: ['ok', 'baseline'], properties: { ok: { type: 'boolean' }, baseline: { type: 'string' }, detail: { type: 'string' } } } },
)
if (!pre || !pre.ok) {
  log(`Preflight FAILED — aborting before any PR is opened: ${pre ? pre.detail || pre.baseline : 'no result'}`)
  return { aborted: true, reason: 'preflight failed', preflight: pre }
}
log(`Preflight green (${pre.baseline}). Fanning out ${ITEMS.length} issues: plan -> implement -> review.`)

const results = await pipeline(
  ITEMS,
  // Stage 1: plan
  (item) => agent(planPrompt(item), { label: `plan:${item.id}`, phase: 'Plan', schema: PLAN_SCHEMA })
    .then((plan) => ({ item, plan })),

  // Stage 2: implement + PR (worktree-isolated)
  ({ item, plan }) => {
    if (!plan || !plan.ready) {
      log(`Skip implement ${item.id}: plan not ready (${plan ? plan.notes || 'not ready' : 'no plan'})`)
      return { item, plan, impl: { opened: false, testsGreen: false, summary: 'plan not ready', blockedReason: 'plan not ready' } }
    }
    return agent(implPrompt(item, plan), { label: `impl:${item.id}`, phase: 'Implement', isolation: 'worktree', schema: IMPL_SCHEMA })
      .then((impl) => ({ item, plan, impl }))
  },

  // Stage 3: review loop (max 3), fix in worktree until clean
  async ({ item, plan, impl }) => {
    if (!impl || !impl.opened || !impl.prNumber) {
      return { id: item.id, issue: item.issue, opened: false, prNumber: null, blockedReason: impl ? impl.blockedReason : 'implement failed', summary: impl ? impl.summary : 'no impl result' }
    }
    const rounds = []
    for (let r = 1; r <= 3; r++) {
      const review = await agent(reviewPrompt(item, impl.prNumber, r), { label: `review:${item.id}#${r}`, phase: 'Review', schema: REVIEW_SCHEMA })
      rounds.push(review)
      const actionable = review && review.findings ? review.findings.filter((f) => f.real && (f.severity === 'blocker' || f.severity === 'major')) : []
      if (!review || review.clean || actionable.length === 0) {
        log(`PR #${impl.prNumber} (${item.id}) clean after ${r} review round(s).`)
        break
      }
      if (r === 3) {
        log(`PR #${impl.prNumber} (${item.id}) still has ${actionable.length} actionable finding(s) after 3 rounds — left for human review.`)
        break
      }
      const fix = await agent(fixPrompt(item, impl.prNumber, review), { label: `fix:${item.id}#${r}`, phase: 'Review', isolation: 'worktree', schema: FIX_SCHEMA })
      if (!fix || !fix.pushed) {
        log(`PR #${impl.prNumber} (${item.id}): fix round ${r} pushed nothing — stopping loop.`)
        break
      }
    }
    return { id: item.id, issue: item.issue, opened: true, prNumber: impl.prNumber, prUrl: impl.prUrl, reviewRounds: rounds.length, finalClean: rounds.length ? !!rounds[rounds.length - 1].clean : false, summary: impl.summary }
  },
)

const opened = results.filter((r) => r && r.opened)
const notOpened = results.filter((r) => !r || !r.opened)
return {
  preflight: pre.baseline,
  opened: opened.map((r) => ({ issue: r.issue, plan: r.id, pr: r.prNumber, url: r.prUrl, reviewRounds: r.reviewRounds, finalClean: r.finalClean })),
  notOpened: notOpened.map((r) => ({ issue: r ? r.issue : null, plan: r ? r.id : null, reason: r ? r.blockedReason || r.summary : 'null result' })),
}
