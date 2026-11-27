export const meta = {
  name: 'bpp-release-staging',
  description: 'BPP dev -> staging release: migrate, bump, promote, merge, deploy, SQL; critic agents gate every phase',
  whenToUse: 'Run by the bpp-release-staging skill. args: {mode: "run"|"dry-run", runId: "<yyyy-mm-dd-hhmm>", ack?: "<note>"}',
  phases: [
    { title: 'Skill update', detail: 'pull the skills mirror; critics review changed skills before install (BPP_RELEASE_SKILL_UPDATE on|off|report)' },
    { title: 'Preflight', detail: 'lock, tools, glab rights, DB secrets readable (bpp + document analysis), disk, previous run state, health + deploy baseline' },
    { title: 'Pull', detail: 'bpp-pull-all-dev' },
    { title: 'Shared state', detail: 'newest BPP.Shared.NET package, check out its commit, pending migrations (bpp + document analysis), dev heads' },
    { title: 'Local migrate', detail: 'migrate-stage.sh local, bpp then document analysis' },
    { title: 'Dev migrate', detail: 'migrate-stage.sh development, bpp then document analysis, + StageSql' },
    { title: 'Bump shared', detail: 'bpp-bump-shared-version to the phase 3 package' },
    { title: 'Promote', detail: 'bpp-promote-dev-to-staging preview, critics, then go' },
    { title: 'UI versions', detail: 'package.json versions in every UI promotion MR' },
    { title: 'Wait green', detail: 'pipelines green and mergeable; Duo findings judged' },
    { title: 'Staging migrate', detail: 'migrate-stage.sh staging, bpp then document analysis, + pre-deploy StageSql' },
    { title: 'Merge', detail: 'merge promotion MRs at the recorded heads' },
    { title: 'Watch deploy', detail: 'staging deploys + bpp-go-health, compared with the preflight baseline' },
    { title: 'ui_configs', detail: 'cockpit/kundenportal ui_configs on staging, never stella' },
    { title: 'Manual SQL', detail: 'post-deploy StageSql; fallback SQL only when all critics approve' },
    { title: 'Henry ping', detail: 'release summary, store release, stella ui_configs' },
    { title: 'Report', detail: 'final summary, state done' },
    { title: 'Cleanup', detail: 'restore bpp-shared, remove merged worktrees, unlock' },
  ],
}

// ---- inputs ----
const A = args || {}
const MODE = A.mode
const RUN_ID = A.runId
const ACK = typeof A.ack === 'string' ? A.ack : ''
const DRY = MODE === 'dry-run'

if (MODE !== 'run' && MODE !== 'dry-run') {
  return { status: 'halted', phase: 'Preflight', summary: 'args.mode must be "run" or "dry-run"', uiConfigsSql: '', henryPing: '' }
}
if (typeof RUN_ID !== 'string' || !/^[A-Za-z0-9._:-]+$/.test(RUN_ID)) {
  return { status: 'halted', phase: 'Preflight', summary: 'args.runId missing or has characters other than letters, digits and ._:- (expected yyyy-mm-dd-hhmm)', uiConfigsSql: '', henryPing: '' }
}

// ---- paths (agents expand $HOME in their own shell) ----
const LIB = '$HOME/.claude/skills/bpp-release-staging/lib'
const STATE = `bash "${LIB}/state.sh"`
const PING = `bash "${LIB}/henry-ping.sh"`
const SDIR = '$HOME/.claude/state/bpp-release'
const SHARED = '$HOME/Entwicklung/bpp/bpp-shared'
const BACKEND = '$HOME/Entwicklung/bpp/bpp-backend'
// bpp-document-analysis has its own database (bpp_document_analysis, own Postgres) and its own DbMigrator
const DOCANA = '$HOME/Entwicklung/bpp/bpp-document-analysis'
const DOCANA_MIG = 'BPP.DocumentAnalysis/BPP.DocumentAnalysis.DbMigrator/Migrations'
const DOCANA_WT = `${SDIR}/docana-${RUN_ID}`
const DOCANA_HISTORY = `--query 'SELECT migration_id FROM "__EFMigrationsHistory" ORDER BY 1'`
const MIRROR = '$HOME/Entwicklung/lipso/agentic-coding-knowledge'
const HEALTH = 'bash "$HOME/.claude/skills/bpp-go-health/health.sh"'
const HMAP = `bash "${LIB}/health-map.sh"`
// baseline files of this run (both modes): statuses, hosts.tsv, map.json, deploys.json
const BDIR = `${SDIR}/baseline-${RUN_ID}`

// spec phase label per meta title, used in prompts and stored by state.sh set-phase
const TITLES = ['Skill update', 'Preflight', 'Pull', 'Shared state', 'Local migrate', 'Dev migrate', 'Bump shared',
  'Promote', 'UI versions', 'Wait green', 'Staging migrate', 'Merge', 'Watch deploy', 'ui_configs', 'Manual SQL',
  'Henry ping', 'Report', 'Cleanup']
const SPEC_NO = ['0', '1', '2', '3', '4', '5', '5b', '6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '16']

// ---- schemas ----
const BASE_PROPS = {
  ok: { type: 'boolean' },
  halt: { type: 'boolean' },
  reason: { type: 'string' },
  summary: { type: 'string' },
  applied: { type: 'array', items: { type: 'string' } },
  evidence: { type: 'array', items: { type: 'string' } },
  lock_lost: { type: 'boolean', description: 'true when state.sh lock exited 7 (another run holds the lock)' },
}
const BASE_REQ = ['ok', 'halt', 'reason', 'summary', 'applied', 'evidence']
function workerSchema(extra) {
  return { type: 'object', properties: Object.assign({}, BASE_PROPS, extra || {}), required: BASE_REQ }
}
const HEADS = { type: 'array', items: { type: 'object', properties: { repo: { type: 'string' }, sha: { type: 'string' } }, required: ['repo', 'sha'] } }
const MRS = {
  type: 'array',
  items: {
    type: 'object',
    properties: {
      repo: { type: 'string' }, project_id: { type: 'string' }, iid: { type: 'number' }, url: { type: 'string' },
      kind: { type: 'string', enum: ['dotnet', 'ui', 'other'] },
    },
    required: ['repo', 'iid', 'url', 'kind'],
  },
}
const CRITIC = {
  type: 'object',
  properties: { block: { type: 'boolean' }, reason: { type: 'string' } },
  required: ['block', 'reason'],
}
const HALT_SCHEMA = {
  type: 'object',
  properties: { ping: { type: 'string', description: 'the henry-ping.sh output, verbatim' }, notes: { type: 'string' } },
  required: ['ping', 'notes'],
}

// ---- shared prompt parts ----
const SAFETY = `Safety rules (all phases, no exceptions):
- Never print, echo, cat, log or write a secret or connection string. Never read ~/.bpp-release.env, never run "security find-generic-password", never call get_secret or source secret-env.sh yourself.
- Databases only through the wrappers: ${LIB}/migrate-stage.sh and ${LIB}/run-stage-sql.sh. Use run-stage-sql.sh --readonly for every read. There is no main stage; never touch the main/prod DB.
- Two databases per stage: bpp (the default) and document analysis (--db document-analysis). The document analysis DB is written only by migrate-stage.sh --db document-analysis; run-stage-sql.sh reads it (--readonly --db document-analysis) and never writes it. No SQL file ever runs against it.
- Git: worktrees for any repo change; never amend, rebase, reset, stash or force-push (the only allowed reset --hard is the one bpp-checkout-shared-at-stage does on the bpp-shared checkout). "git add <path>" only, never "git add -A". Commit trailer: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
- This is an unattended run: ask no questions. When a halt condition applies, or you are unsure, stop and return halt: true with a precise reason.
- Waiting: bounded loops only (sleep inside a loop with a fixed number of rounds, each Bash call under 10 minutes). Never "cat /dev/zero" or an unbounded loop.`

// which of state.sh halt/unlock and henry-ping.sh a phase worker may run (Henry ping: the ping, Cleanup: the unlock)
function callRule(idx) {
  if (idx === 15) return '- Run henry-ping.sh only as the Task says (once, level info). Do not run "state.sh halt" or "state.sh unlock"; the workflow does that.'
  if (idx === 17) return '- Run "state.sh unlock" only as the Task says (its last step). Do not run "state.sh halt" or henry-ping.sh; the workflow does that.'
  return '- Do not run "state.sh halt", "state.sh unlock" or henry-ping.sh; the workflow does that.'
}

function stateRules(idx) {
  if (DRY || idx === 0) {
    const why = DRY ? 'this is a DRY RUN' : 'state.json may still belong to the previous run until Preflight archives it'
    return `State: ${why}. First run: ${STATE} lock ${RUN_ID}  (exit 7 -> another run holds the lock: return ok: false, halt: true, lock_lost: true, and stop). Do NOT run state.sh new/set-phase/add-applied/done here.`
  }
  const setPhase = idx === 1 ? `After step 7 below (state.sh new): ${STATE} set-phase ${SPEC_NO[idx]}` : `Then: ${STATE} set-phase ${SPEC_NO[idx]}`
  return `State: first run: ${STATE} lock ${RUN_ID}  (heartbeat; exit 7 -> another run holds the lock: return ok: false, halt: true, lock_lost: true, and stop). ${setPhase}
After every write that succeeded (DB migration, SQL file, push, MR created/merged/closed), run: ${STATE} add-applied "<phase ${SPEC_NO[idx]}: what was applied>"  and list the same text in "applied".`
}

// how SQL files are named in state.sh add-sql / has-sql
function sqlId(stage) {
  return `SQL file id for "state.sh add-sql" / "state.sh has-sql": "<repo>:<path>" for a file from git (repo folder name and the path find-stage-sql.sh lists), "<mr>#<n>" for an MR description block (the entry's mr field; n = the block number b in its sql_file name mr-<i>-<b>.sql).
Before running a SQL file: ${STATE} has-sql ${stage} <id>; exit 0 = already applied on ${stage} by an earlier run -> skip it and say so in evidence. ${DRY ? 'DRY RUN: still check has-sql, but run and record nothing.' : `After it ran: ${STATE} add-sql ${stage} <id> (and add-applied as usual).`}`
}

const RESULT_RULES = `Return: ok (phase done and every check passed), halt (a halt condition applies), reason (why, empty when fine), summary (2-5 lines), applied (writes done in this phase), evidence (the exact commands you ran and the key output lines, secrets never included - wrapper output is already redacted). Critic agents read your evidence and block the release when it is missing, so include proof for every check.`

let ctx = {
  mode: MODE, runId: RUN_ID, ack: ACK, previous: null, package: null, shared_sha: null,
  pending_dev: [], pending_staging: [], docana_sha: null, docana_pending_dev: [], docana_pending_staging: [], heads: [], staging_heads: [], mrs: [], duo: [], ui_configs_sql: '', stella_sql: '',
  applied: [], promote_preview: '', sql_candidates: [], skill_update: '',
  baseline: null, pre_move_sha: null,
}
function ctxText() {
  return 'Run context so far (JSON):\n' + JSON.stringify(ctx, null, 2)
}

function workerPrompt(idx, title, body, rules) {
  return `You are the worker for phase ${SPEC_NO[idx]} "${title}" of the BPP dev -> staging release (skill bpp-release-staging, run ${RUN_ID}, mode ${MODE}).
Spec: $HOME/Entwicklung/ai-dev-workflows/docs/superpowers/specs/2026-11-26-bpp-release-design.md (section "Phases (bpp-release-staging)"); read it if a rule below is unclear.

${SAFETY}
${callRule(idx)}

${stateRules(idx)}

Task:
${body}

Halt conditions for this phase (from the spec):
${rules}

${ctxText()}

${RESULT_RULES}`
}

const LENSES = [
  'EVIDENCE lens: does the evidence prove every check and every halt condition of this phase was actually run and passed? Claims without command output count as missing.',
  'SAFETY lens: anti-goals - a secret in the output, a write to the wrong stage or to main, SQL meant for another stage, a destructive or old-code-incompatible change, a merge while anything is red, conflicting or not computed, a write in dry-run mode.',
  'STATE lens: is the result consistent with the run context (package, shared sha, recorded heads, MR list), is the applied list complete and exact, and would a halt here say precisely what is already applied?',
]

function criticPrompt(idx, title, rules, result, lens) {
  return `You are a critic agent gating phase ${SPEC_NO[idx]} "${title}" of the BPP dev -> staging release (run ${RUN_ID}, mode ${MODE}). The next phase starts only if every critic approves.
${lens}

You may verify with read-only commands (git log/show/diff/ls-remote, glab api GET, ${LIB}/run-stage-sql.sh --readonly ...). Never write: no DB writes, no push, no MR changes, no state.sh calls other than "state.sh get". Never print secrets; never read ~/.bpp-release.env.

Worker call rule for this phase: ${callRule(idx).slice(2)}

Phase rules (from the spec):
${rules}
${DRY ? '\nDRY RUN: DB writes, GitLab writes (MR create/merge/close/note, push, shared bump) and SQL must only be printed, never executed; one that was executed is a block. Local git updates are allowed and expected in dry-run: pull (bpp-pull-all-dev), the bpp-shared checkout and its restore, and the skills mirror pull + install.\n' : ''}
Worker result (JSON):
${JSON.stringify(result, null, 2)}

${ctxText()}

Return block: true with a reason when anything is wrong, unproven or missing. Default to block: true when evidence is missing or does not prove the rule was checked. Return block: false only when the evidence shows the phase is correct and complete.`
}

// bpp-shared restore: by SHA, not by branch name (phase 3's reset --hard keeps the branch name)
function restoreShared() {
  const known = ctx.pre_move_sha ? `the pre-move SHA is ${ctx.pre_move_sha}` : (DRY
    ? `read the pre-move SHA from ${SDIR}/pre-move-sha-${RUN_ID} if that file exists`
    : `read the pre-move SHA with: ${STATE} get pre_move_sha  (only if state.json's run_id is ${RUN_ID})`)
  return `Restore bpp-shared in ${SHARED} by SHA: ${known}.
   - No pre-move SHA recorded -> phase 3 never moved the checkout: restore nothing, say so.
   - HEAD (git rev-parse HEAD) equals the pre-move SHA -> nothing to restore, say so.
   - Otherwise: the tree must be clean (git status --porcelain empty) -> git switch development && git pull --ff-only, then verify git rev-parse HEAD equals git rev-parse origin/development.
   - Dirty tree, a refused switch/pull, or HEAD != origin/development afterwards -> do not stash, reset or force anything; report it (it needs a human).`
}

// ---- halt handling ----
function Halt(title, reason, lockLost) {
  this.halt = true
  this.title = title
  this.reason = reason
  this.lockLost = !!lockLost
}

let cur = 'Skill update'
async function gate(idx, body, rules, opts) {
  const o = opts || {}
  const title = TITLES[idx]
  cur = title
  const label = o.label || title
  const r = await agent(workerPrompt(idx, title, body, rules), { schema: workerSchema(o.extra), label: `${label}: worker`, phase: title })
  if (!r) throw new Halt(title, `${label}: worker returned no result`)
  if (r.applied && r.applied.length) ctx.applied = ctx.applied.concat(r.applied)
  if (r.lock_lost) throw new Halt(title, `${label}: another run holds the release lock (state.sh lock exit 7)`, true)
  if (r.halt || !r.ok) throw new Halt(title, `${label}: ${r.reason || 'worker reported not ok'}`)
  if (o.critics === 0) return r
  await review(idx, rules, r, o.critics || 2, label)
  return r
}

// n critics read a result; any block halts
async function review(idx, rules, result, n, label) {
  const title = TITLES[idx]
  const votes = await parallel(LENSES.slice(0, n).map((l, i) => () =>
    agent(criticPrompt(idx, title, rules, result, l), { schema: CRITIC, label: `${label}: critic ${i + 1}`, phase: title })))
  const blocks = votes.map((v, i) => (!v ? `critic ${i + 1}: no verdict` : (v.block ? `critic ${i + 1}: ${v.reason}` : null))).filter(Boolean)
  if (blocks.length) throw new Halt(title, `${label}: blocked by critics - ${blocks.join(' | ')}`)
  log(`${label}: approved (${n} critics)`)
}

async function doHalt(h) {
  const idx = TITLES.indexOf(h.title)
  const ownLock = !h.lockLost
  const prompt = `You are the halt agent of the BPP dev -> staging release (run ${RUN_ID}, mode ${MODE}). The run stopped in phase ${SPEC_NO[idx]} "${h.title}".
Reason: ${h.reason}

${SAFETY}

Do exactly this, in order:
${ownLock ? `1. ${DRY ? 'DRY RUN: do not touch state.json.' : `Run ${STATE} get. Only if its run_id is ${RUN_ID}: ${STATE} halt "phase ${SPEC_NO[idx]} ${h.title}: <reason, one line>". Otherwise leave it alone (it is the previous run's state).`}
2. Write the ping body with the Write tool to ${SDIR}/ping-${RUN_ID}.txt (expand $HOME first). Content: run id, mode, the phase it stopped in, the reason, and an exact "already applied" list: ${JSON.stringify(ctx.applied)} plus anything "${STATE} get" lists under applied${DRY ? ' (dry run: nothing was applied)' : ''}. Say what a human must decide or do next, and that a rerun starts with a re-check of every phase.
3. ${PING} blocker "bpp-release-staging ${DRY ? '[dry-run] ' : ''}halted in ${h.title}" "${SDIR}/ping-${RUN_ID}.txt"
4. ${restoreShared()} Put the outcome in notes.
5. ${STATE} unlock ${RUN_ID}`
    : `Another run holds the release lock. Do NOT run state.sh halt or unlock and do NOT touch the bpp-shared checkout: they belong to the other run.
1. ${PING} blocker "bpp-release-staging ${DRY ? '[dry-run] ' : ''}refused: lock held" "<one paragraph: run ${RUN_ID} did not start because another run holds the lock; show the output of: cat ${SDIR}/lock>"`}

Return ping = the henry-ping.sh output verbatim, notes = anything that failed above.`
  const r = await agent(prompt, { schema: HALT_SCHEMA, label: 'halt', phase: h.title })
  return {
    status: 'halted',
    phase: h.title,
    summary: `Halted in phase ${SPEC_NO[idx]} "${h.title}": ${h.reason}. Applied so far: ${ctx.applied.length ? ctx.applied.join('; ') : 'nothing'}.${r && r.notes ? ' Halt agent notes: ' + r.notes : ''}`,
    uiConfigsSql: ctx.ui_configs_sql,
    henryPing: r ? r.ping : 'halt agent returned nothing - run henry-ping.sh by hand',
  }
}

// ---- phase rules, quoted from the spec ----
const R = {
  skill: `- Switch BPP_RELEASE_SKILL_UPDATE (on|off|report, default on), read from the environment. off: no mirror pull, no install; the report says "skill update off". report: pull into a temp clone, list which used skills differ, never install. on: as below.
- on: every run pulls the mirror's main and installs it (also in dry-run: a local update). Only when a skill this run uses changed since the last run do critics review its diff first; any block -> halt + ping.
- Skills this run uses: bpp-release-staging, bpp-pull-all-dev, bpp-bump-shared-version, bpp-checkout-shared-at-stage, bpp-promote-dev-to-staging, bpp-migration-guide-audit, bpp-project-index, bpp-go-health, bpp-cleanup-merged-worktrees.
- Halt when the install would overwrite a local skill file that has edits the mirror does not have (that would destroy unsynced work).`,
  preflight: `- glab auth + Maintainer rights (staging merge/push = Maintainers) in every repo that may be promoted, dotnet, psql, jq, timeout or gtimeout.
- DB secrets readable without a popup, with a timeout, for both databases: run-stage-sql.sh --readonly <development|staging> --check and run-stage-sql.sh --readonly --db document-analysis <development|staging> --check. Exit 3 = entry missing, 4 = env file mode/owner wrong, 5 = Keychain timeout/denied/locked: each is a preflight blocker (halt naming the cause), never a hang.
- Disk: at least 10 GB free in $HOME.
- No other release run holds the lock file (state.sh lock exit 7 -> halt).
- Health + deploy baseline, before any write: release repos = every active repo with a staging branch whose development head differs from its staging head, plus every repo with an open Development -> Staging MR. For each: its Traefik hosts (health-map.sh hosts) and its latest staging deploy job (newest job named like deploy across the last 5 staging pipelines, retried jobs included). Gatus staging statuses via bpp-go-health (health.sh json) mapped with health-map.sh map.
- Halt in Preflight, before any write, when an endpoint of a release repo is unhealthy (release_unhealthy) or a release repo's latest staging deploy job failed; the reason names repo, endpoint, job id and the first error line. Unhealthy endpoints of other repos are known (report only); release repos without a Gatus endpoint are unmapped (report only).
- Report promotion MRs whose head pipeline is skipped (report only; Wait green handles them).
- Previous run state: a halt records phase, reason, and what is already applied. A rerun starts again at phase 0 and re-checks every phase (no jump to the halted phase), or reports that a human must decide. SQL files recorded in state (state.sh has-sql) are never run again.`,
  pull: `- bpp-pull-all-dev. Halt if bpp-shared or bpp-backend were skipped (or are not on development afterwards).`,
  shared: `- Resolve the newest BPP.Shared.NET package (the one bpp-bump-shared-version will pick: newest by created_at in the GitLab registry) and its bpp-shared commit (+<sha>), check it out (same mechanism as bpp-checkout-shared-at-stage) and list the migrations the dev and staging DBs lack (query __EFMigrationsHistory with run-stage-sql.sh --readonly).
- The staging DB must be migrated from exactly that bpp-shared state; anything else is an anti-goal.
- Critics check: every new migration is safe with the old staging code (no drop/rename of a column/table/enum value the old code uses). Migrations run before the merge, so they must work with the old code for a few minutes; a migration that drops/renames something the old code uses is a blocker.
- Halt if a DB already has a migration id that the checked-out bpp-shared commit does not contain (DB ahead of the package).
- Record each repo's development head; the merge phase merges with sha=<recorded head> so GitLab refuses an MR that moved.
- Document analysis has its own database and its own EF migrations (bpp-document-analysis, ${DOCANA_MIG}); bpp-shared's migrations never touch it. List the migrations its dev and staging DBs lack against the recorded development head of bpp-document-analysis (its __EFMigrationsHistory has snake_case columns: migration_id). Halt if one of these DBs has a migration id that commit does not contain.
- The critics' old-code check covers the document analysis migrations too: they also run before the merge.`,
  local: `- migrate-stage.sh local from that bpp-shared state. Halt on failure.
- bpp-shared HEAD must still be the phase 3 commit; else halt.
- Then migrate-stage.sh local --db document-analysis from a worktree of bpp-document-analysis at its phase 3 commit. Halt on failure.`,
  dev: `- migrate-stage.sh development. Halt on failure.
- bpp-shared HEAD must still be the phase 3 commit; else halt.
- Afterwards every migration listed as pending for development must be in its __EFMigrationsHistory (read-only check); else halt.
- Then migrate-stage.sh development --db document-analysis from a worktree of bpp-document-analysis at its phase 3 commit; afterwards every id in docana_pending_dev must be in that DB's __EFMigrationsHistory; else halt. Its running dev containers cache enum labels and columns (Npgsql) until they are redeployed: report whether migrations were applied.
- Then the new bpp-backend StageSql files whose "-- stages:" header lists development (added between the recorded bpp-backend staging and development heads): pre-deploy first, then post-deploy (the dev code is already deployed), each via run-stage-sql.sh development. Files recorded as applied on development (state.sh has-sql) are skipped. Halt on failure.`,
  bump: `- bpp-bump-shared-version to exactly the package from phase 3 (halt if a newer one appeared).
- Runs after the dev migration on purpose: the bump commits redeploy every .NET consumer on dev, so they restart with the new schema.
- Halt if it reports skipped or unverified consumers ("already current" is fine; any other skip reason, a dirty props file, an off-branch repo or an unverified push is not).
- New development heads may only differ from the recorded ones by this phase's own bump commits.`,
  promotePreview: `- bpp-promote-dev-to-staging (direction dev->staging). The "go" its preview asks for is given by the workflow after critics approve the preview.
- Includes bumps, conflict back-merge (its step 6b), migration-guide audit.
- Restart guard: when phase 3 found pending migrations, every .NET consumer with a staging branch must have a promotion MR; one missing -> halt. (The Java services bpp-mail and bpp-js-report-connector have no Postgres config.)
- Document analysis restart guard: when phase 3 found pending document analysis migrations for staging, bpp-document-analysis must have a promotion MR; missing -> halt (its staging containers must be redeployed after its DB is migrated).
- Preview stage: read-only; nothing is created or pushed.`,
  promoteGo: `- Run bpp-promote-dev-to-staging with the go given, for exactly the repo set of the approved preview; a different repo set -> halt.
- Restart guard: when phase 3 found pending migrations, every .NET consumer with a staging branch must have a promotion MR; one missing -> halt.
- Document analysis restart guard: when phase 3 found pending document analysis migrations for staging, bpp-document-analysis must have a promotion MR; missing -> halt.
- Conflicts: the skill's step 6b back-merge in a worktree; an unresolved conflict -> halt.
- New development heads may only differ from the recorded ones by this phase's own commits (version bumps, back-merges); any other new commit -> halt.
- MRs: should_remove_source_branch must be false on every MR.`,
  ui: `- For every UI promotion MR: package.json version on development > staging (and > main), lock entries match (the promote skill's post-bump check, re-run). Halt on mismatch.`,
  wait: `- Poll every promotion MR: pipeline success, detailed_merge_status=mergeable. One retry of a failed job; still red -> halt. Bounded wait (90 min) -> halt on timeout.
- A head pipeline with status skipped is not green. If the MR head commit message contains [skip ci] or [ci skip]: push one empty commit "chore: run CI after a skipped commit" to that repo's development (worktree, no force; dry run prints it), record it in applied, and keep waiting; still skipped after that -> halt. Any other skipped pipeline -> halt.
- Never merge while any promotion MR is red, conflicting or un-computed.
- Each MR's head sha must equal the recorded development head of its repo; a moved MR -> halt.
- Duo requested_changes on a promotion MR -> Duo path: critics judge Duo's findings; all agree non-issue -> at merge time the MR is closed with a note why, development is merged into staging in a worktree and staging is pushed; confirmed critical or unclear -> halt + Henry ping (Bypass needs a human).`,
  duo: `- Judge Duo's requested_changes findings on promotion MRs. Non-issue = the finding is wrong, cosmetic, or already handled, and leaving it does not break staging.
- Confirmed critical or unclear -> block (halt + Henry ping; the Bypass needs a human).`,
  stagingMigrate: `- migrate-stage.sh staging, then the new *.pre-deploy.sql files for staging via run-stage-sql.sh staging. Halt on failure.
- bpp-shared HEAD must still be the phase 3 commit, and the staging pending list must be unchanged since phase 3 (a new shared pin or migration since phase 3 -> halt; the next run starts again at phase 0 and re-checks every phase).
- Then migrate-stage.sh staging --db document-analysis from a worktree of bpp-document-analysis at its recorded development head (the commit its promotion MR merges). The migration ids at that commit must equal the ones at the phase 3 commit, and its staging pending list must be unchanged since phase 3; else halt. Afterwards every pending id must be in that DB's __EFMigrationsHistory; else halt. No SQL file runs against the document analysis DB.
- StageSql convention: only bpp-backend's StageSql/*.pre-deploy.sql added between staging and the recorded development head, whose "-- stages:" header lists staging; plain SQL, no BEGIN/COMMIT, "-- idempotent: yes". A file whose stages header omits staging, a post-deploy file, or a file outside bpp-backend must not run here. Files recorded as applied on staging (state.sh has-sql) are skipped.`,
  merge: `- Merge all staging promotion MRs with sha=<head recorded> and should_remove_source_branch=false, then verify development still exists in each repo.
- A refused merge (MR moved) -> halt; say exactly which MRs are already merged.
- Duo-path MRs whose findings all critics judged non-issue: close the MR with a note why, merge development (at the recorded sha) into staging in a worktree and push staging (no force).
- Merging while any promotion MR is red, conflicting or un-computed is an anti-goal.`,
  deploy: `- Each merged repo's staging pipeline and deploy job to success (bounded wait 60 min); a failed one -> halt.
- Then bpp-go-health staging, compared with the Preflight baseline (health-map.sh diff): halt only on endpoints that were healthy (or absent) at baseline and are still unhealthy once their fail_since + 15 minutes has passed (bounded polling; never "done" while one is still unhealthy). Endpoints already unhealthy at baseline are known: list them, no halt.
- When document analysis migrations were applied on staging in phase 9, bpp-document-analysis must be among the merged repos and its staging pipeline must have deployed (the old containers cache enum labels and columns until they are replaced); else halt.`,
  ui_configs: `- Run the staging statements marked "changed by this promotion" for cockpit and kundenportal (the promote skill's SQL) through run-stage-sql.sh staging; then the read-only check SELECT.
- Never stella: it waits for the store release.
- Before the staging DbMigrator applied the ui_configs migration the table does not exist: halt instead of running SQL that fails.`,
  manual: `- find-stage-sql.sh: convention: bpp-backend StageSql/*.post-deploy.sql added in this promotion whose stages: header lists staging -> run. bpp-backend pre-deploy files ran in phase 9. Any StageSql file outside bpp-backend (pre- or post-deploy) is never skipped silently: it is a fallback candidate.
- SQL files recorded as applied on staging (state.sh has-sql) are skipped, never run twice.
- Fallback, over every feature MR merged into development since the last staging release (all promoted repos): SQL blocks in MR descriptions and changed .sql files outside StageSql/ (excluding CypressSql/, SeedSql/, InsertSql/, SyncSql/ and migrations) -> critics judge (right stage, idempotent, not destructive, not already applied); all approve -> run; else halt + ping.
- Running SQL that no critic looked at, or SQL meant for another stage, is an anti-goal.`,
  ping: `- Print: what was released (MR list, versions), the go-stella app version that now needs submitting/unlocking in App Store + Play Store, and the stella ui_configs statement to run after the store release.`,
  report: `- Final summary; state file marked done. A silent partial release is an anti-goal.`,
  cleanup: `- Restore bpp-shared by SHA: when HEAD differs from the pre-move SHA recorded in phase 3, and the tree is clean, git switch development && git pull --ff-only, then verify HEAD == origin/development; dirty or mismatch -> halt, never stash or force. No move recorded -> nothing to restore. Then bpp-cleanup-merged-worktrees (plan, apply only its REMOVE/LANDED rows; never --force).
- Release the lock (state.sh unlock).`,
}

// the bpp-document-analysis DbMigrator runs from a detached worktree at one exact commit
function docanaWorktree(sha) {
  return `in ${DOCANA}: git fetch origin; git worktree add --detach "${DOCANA_WT}" ${sha} (expand $HOME; if the directory is left over from an earlier call, git worktree remove it first; never --force). Check git -C "${DOCANA_WT}" rev-parse HEAD equals ${sha}`
}
const DOCANA_WT_REMOVE = `git -C ${DOCANA} worktree remove "${DOCANA_WT}" (no --force; a refusal goes into evidence, it is not a halt)`

function dryNote(what) {
  return DRY ? `\nDRY RUN: do not execute ${what}. Print the exact command(s) you would run, with their arguments, in evidence (prefix "WOULD RUN:"), and run only the read-only checks.` : ''
}

// ---- the run ----
try {
  // 0. Skill update
  phase('Skill update')
  const su = await gate(0, `Mirror: ${MIRROR} (GitLab lipso/internal/agentic-coding-knowledge, branch main). Its install.sh renders the skills; read install.sh and README to learn the install command, do not guess.
0. Run: printf '%s\\n' "\${BPP_RELEASE_SKILL_UPDATE:-on}"  and return skill_update = that value exactly. Not on, off or report -> halt with the value in the reason.
   - off: do nothing else (no fetch, no pull, no install). Return changed_skills = [] and put "skill update off" in evidence.
   - report: do not touch the mirror checkout or $HOME/.claude/skills. git clone the mirror's origin (branch main) into a temp clone (mktemp -d), compare it with the installed skills as in step 1, return changed_skills, list local edits the mirror lacks in evidence (no halt for them), then remove the temp clone. Never install. Skip steps 1-3.
   - on: steps 1-3.
1. In the mirror: git fetch origin main, then compare origin/main with the installed skills in $HOME/.claude/skills for the skills listed in the rules (read-only: git diff / diff -r against what install.sh would render).
2. Return changed_skills = only the skills this run uses (list in the rules) that changed. For each, put the unified diff path or a short excerpt in evidence. Check whether the installed copy has local edits the mirror lacks (halt if so).
3. Do NOT install yet.`, R.skill, {
    label: 'Skill update (diff)', critics: 0,
    extra: {
      changed_skills: { type: 'array', items: { type: 'string' } },
      skill_update: { type: 'string', description: 'value of BPP_RELEASE_SKILL_UPDATE (default on)' },
    },
  })
  const changed = su.changed_skills || []
  const suMode = su.skill_update || 'on'
  if (!['on', 'off', 'report'].includes(suMode)) throw new Halt('Skill update', `BPP_RELEASE_SKILL_UPDATE must be on, off or report, got "${suMode}"`)
  if (suMode === 'off') {
    ctx.skill_update = 'skill update off'
    log('Skill update: skill update off (BPP_RELEASE_SKILL_UPDATE=off); no mirror pull, no install')
  } else if (suMode === 'report') {
    ctx.skill_update = `skill update report: ${changed.length ? `differ: ${changed.join(', ')}` : 'no used skill differs'}; nothing installed`
    log(`Skill update: ${ctx.skill_update}`)
  } else {
    ctx.skill_update = `skill update on: ${changed.length ? `installed after review: ${changed.join(', ')}` : 'no used skill changed; mirror installed'}`
    if (changed.length) await review(0, R.skill, su, 2, 'Skill update (diff)')
    else log('Skill update: no skill this run uses changed; no diff review')
    await gate(0, `${changed.length ? `The critics approved the mirror diff for: ${changed.join(', ')}.` : 'No skill this run uses changed; install anyway (every run installs the mirror).'}
Fast-forward the mirror checkout to origin/main (git pull --ff-only; no reset, no force) and install with the mirror's install.sh for the skills. This is a local update and runs in dry-run too.
Then verify the installed files match the mirror (diff) and list them in evidence. Note: this running workflow keeps its current script; a changed workflow.js takes effect next run.`, R.skill, { label: 'Skill update (install)', critics: 2 })
  }

  // 1. Preflight
  phase('Preflight')
  const pf = await gate(1, `1. ${STATE} lock ${RUN_ID} (the stateRules above already say this; exit 7 -> lock_lost).
2. Tools: glab auth status; dotnet --version; psql --version; jq --version; command -v timeout || command -v gtimeout.
3. Maintainer rights: for each repo in $HOME/.claude/bpp-fleet/manifest.tsv (state=active) that has a staging branch, check the glab user's access_level >= 40 (glab api user, then glab api projects/<id>/members/all/<user id>). List repos without it.
4. DB secrets, four checks: bash ${LIB}/run-stage-sql.sh --readonly development --check and the same for staging; then bash ${LIB}/run-stage-sql.sh --readonly --db document-analysis development --check and the same for staging. Report each exit code; map 3/4/5 to its cause (missing entry, env file mode/owner, Keychain timeout/denied/locked).
5. Disk: df -h "$HOME".
6. Previous state: ${STATE} get (exit 3 = none). If a previous run is "halted": put its halt_reason and applied list in previous_halt/previous_applied (read-only here; step 8 archives it).${ACK ? ` The user acknowledged it with: "${ACK}".` : ' If its halt_reason needs a human decision (Keychain, Duo finding, unsafe migration, unclear SQL, refused merge with partial merges) and no ack was given (args.ack), halt and say so.'} If status is "running" with another run_id, report it (its lock is stale or the lock check would have refused).
7. Health + deploy baseline (read-only; mkdir -p ${BDIR}). It comes before any local write, so a blocker halts the run before state.json is touched:
   a. Release repos: for every active repo in $HOME/.claude/bpp-fleet/manifest.tsv with a staging branch, git ls-remote origin refs/heads/development refs/heads/staging; heads differ -> release repo. Add every repo with an open Development -> Staging MR (glab api "groups/lipso%2Fclients%2Fbrokernet/merge_requests?state=opened&source_branch=development&target_branch=staging&per_page=100"). Write them one per line to ${BDIR}/repos.txt.
   b. Hosts: in each release repo's local checkout (manifest column 7) git fetch -q origin staging. A repo without local clone: download its staging compose file with glab api "projects/<enc>/repository/files/infra%2Fdocker%2Fcompose%2Fdocker-compose.staging.yml/raw?ref=staging" > ${BDIR}/<repo>-compose.yml. Then ${HMAP} hosts <repo>=<checkout> ... <repo>=<downloaded compose file> ... > ${BDIR}/hosts.tsv (Traefik hosts plus network aliases, container_name and hostname).
   c. Gatus: ${HEALTH} json > ${BDIR}/statuses.json; then ${HMAP} map ${BDIR}/statuses.json ${BDIR}/hosts.tsv <release repos, comma-separated> > ${BDIR}/map.json.
   d. Deploys: for each release repo: glab api "projects/<enc>/pipelines?ref=staging&per_page=5", then for those pipelines glab api "projects/<enc>/pipelines/<id>/jobs?per_page=100&include_retried=true"; take the newest job whose name contains "deploy". Record {repo, pipeline, job, status}; for status failed also the first error line of its trace (glab api projects/<enc>/jobs/<job>/trace, ANSI stripped, first line matching error|not found|failed). Write the list to ${BDIR}/deploys.json. A repo without any deploy job: status "none".
   e. Skipped: open promotion MRs whose head_pipeline.status is "skipped" -> skipped_mrs ["<repo>!<iid>"] (report only).
   f. baseline = {release_repos, map: <map.json>, deploys: <deploys.json>, skipped_mrs}; return it as baseline (the files above keep it for phase 11).
   g. release_blockers = one line per map.json release_unhealthy entry ("<repo>: endpoint <key> (<host>) unhealthy since <fail_since>") and per deploy with status failed ("<repo>: staging deploy job <job> failed: <first error line>"). Non-empty -> halt: true with all of them in the reason. known_unhealthy and unmapped go into the summary only.
8. Only when step 7 found no release_blockers: ${DRY ? 'DRY RUN: do not run state.sh new.' : `If the previous state is halted: copy ${SDIR}/state.json to ${SDIR}/state-<its run_id>.json first. If the previous state is absent, done, or halted (and copied): ${STATE} new ${RUN_ID} (it keeps the sql_applied list of a run that did not finish, so no SQL runs twice). If it already has run_id ${RUN_ID}, keep it. Then record phase 0 writes: ${STATE} add-applied "<text>" for each of ${JSON.stringify(ctx.applied)}, and store the baseline: ${STATE} set-baseline '<the step 7 baseline JSON, compact>'.`}
A rerun after a halt starts again at phase 0 and re-checks every phase; there is no jump to the halted phase.`, R.preflight, {
    critics: 2,
    extra: {
      previous_halt: { type: 'string' }, previous_applied: { type: 'array', items: { type: 'string' } },
      baseline: { type: 'object' },
      release_blockers: { type: 'array', items: { type: 'string' } },
      skipped_mrs: { type: 'array', items: { type: 'string' } },
    },
  })
  if (pf.previous_halt) ctx.previous = { halt: pf.previous_halt, applied: pf.previous_applied || [] }
  if (pf.release_blockers && pf.release_blockers.length) throw new Halt('Preflight', `release repo unhealthy or its staging deploy failed (before any write): ${pf.release_blockers.join(' | ')}`)
  ctx.baseline = pf.baseline || null
  if (pf.skipped_mrs && pf.skipped_mrs.length) log(`Preflight: skipped head pipelines (Wait green handles them): ${pf.skipped_mrs.join(', ')}`)

  const resumeNote = ctx.previous ? '\nA previous run halted (see run context "previous"). This run starts again at phase 0 and re-checks every phase; re-check its applied work instead of assuming it: migrations are idempotent, SQL recorded in state (has-sql) is skipped, open promotion MRs are reused, already-merged MRs are not merged again.' : ''

  // 2. Pull
  phase('Pull')
  await gate(2, `Use the Skill tool to load bpp-pull-all-dev and follow it for all repos. Afterwards report for bpp-shared and bpp-backend: branch, HEAD, and whether they were pulled or skipped.${resumeNote}`, R.pull)

  // 3. Shared state
  phase('Shared state')
  const ss = await gate(3, `1. Resolve the newest BPP.Shared.NET package exactly as bpp-bump-shared-version step 1 does (load that skill with the Skill tool and read its step 1; newest by created_at; do not run the bump). Take the bpp-shared commit from its +<sha> build metadata.
2. Before moving anything, record the pre-move SHA (git -C ${SHARED} rev-parse HEAD): ${DRY ? `write it to ${SDIR}/pre-move-sha-${RUN_ID} (one line, mkdir -p ${SDIR})` : `${STATE} set-pre-move-sha <sha>`}, and return it as pre_move_sha. Then check out that commit in ${SHARED} the way bpp-checkout-shared-at-stage does (load the skill; clean tree, ancestor-of-origin/development guard, then its own reset --hard).
3. Migrations in the checkout: list the EF migration ids under the bpp-shared Migrations folder at that commit.
4. Applied migrations: bash ${LIB}/run-stage-sql.sh --readonly development --query 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1' and the same for staging.
5. pending_dev / pending_staging = ids in the checkout missing in that DB. Halt if a DB has an id the checkout lacks.
6. For each pending migration put its file path (the .cs with Up()) in evidence, so critics can read it.
7. Heads: for every active repo in $HOME/.claude/bpp-fleet/manifest.tsv with a staging branch, git ls-remote origin refs/heads/development -> heads [{repo, sha}], and refs/heads/staging -> staging_heads [{repo, sha}] (the base of this release).
8. Document analysis DB (its own database and migrations; bpp-shared's do not apply to it): docana_sha = the development head of bpp-document-analysis from step 7 (not in the manifest -> git -C ${DOCANA} ls-remote origin refs/heads/development; no such repo or branch -> halt). In ${DOCANA}: git fetch origin, then list the migration ids at that commit: git ls-tree --name-only <docana_sha>:${DOCANA_MIG} (the <timestamp>_<Name>.cs files, without .Designer.cs and the ModelSnapshot).
9. Applied there: bash ${LIB}/run-stage-sql.sh --readonly --db document-analysis development ${DOCANA_HISTORY} and the same for staging (snake_case column, unlike the bpp DB).
10. docana_pending_dev / docana_pending_staging = ids at docana_sha missing in that DB. Halt if a DB has an id the commit lacks. For each pending migration put "git -C ${DOCANA} show <docana_sha>:<path of the .cs with Up()>" in evidence, so critics can read it.
${DRY ? '' : `11. ${STATE} set-package <version>, then ${STATE} set-heads '<JSON object {"<repo>": "<development sha>", ...}>' built from heads, then ${STATE} add-applied "phase 3: bpp-shared checked out at <sha> (package <version>)".`}`, R.shared, {
    critics: 3,
    extra: {
      package: { type: 'string' }, shared_sha: { type: 'string' }, pre_move_sha: { type: 'string' },
      pending_dev: { type: 'array', items: { type: 'string' } },
      pending_staging: { type: 'array', items: { type: 'string' } },
      docana_sha: { type: 'string', description: 'development head of bpp-document-analysis the document analysis migrations are listed from' },
      docana_pending_dev: { type: 'array', items: { type: 'string' } },
      docana_pending_staging: { type: 'array', items: { type: 'string' } },
      heads: HEADS,
      staging_heads: HEADS,
    },
  })
  ctx.package = ss.package || null
  ctx.shared_sha = ss.shared_sha || null
  ctx.pre_move_sha = ss.pre_move_sha || null
  ctx.pending_dev = ss.pending_dev || []
  ctx.pending_staging = ss.pending_staging || []
  ctx.docana_sha = ss.docana_sha || null
  ctx.docana_pending_dev = ss.docana_pending_dev || []
  ctx.docana_pending_staging = ss.docana_pending_staging || []
  ctx.heads = ss.heads || []
  ctx.staging_heads = ss.staging_heads || []
  if (!ctx.package || !ctx.shared_sha || !ctx.heads.length || !ctx.staging_heads.length) throw new Halt('Shared state', 'package, shared sha, development heads or staging heads missing from the result')
  if (!ctx.docana_sha) throw new Halt('Shared state', 'development head of bpp-document-analysis (docana_sha) missing from the result')

  // 4. Local migrate
  phase('Local migrate')
  await gate(4, `1. Check git -C ${SHARED} rev-parse HEAD equals ${ctx.shared_sha}. Then: bash ${LIB}/migrate-stage.sh local
Report the exit code and the last 30 output lines.
2. Document analysis: ${docanaWorktree(ctx.docana_sha)}. Then: bash ${LIB}/migrate-stage.sh local --db document-analysis --repo-dir "${DOCANA_WT}"
Report the exit code and the last 30 output lines. Then ${DOCANA_WT_REMOVE}.${dryNote('migrate-stage.sh or the git worktree commands')}`, R.local)

  // 5. Dev migrate
  phase('Dev migrate')
  await gate(5, `1. Check git -C ${SHARED} rev-parse HEAD equals ${ctx.shared_sha}. Then: bash ${LIB}/migrate-stage.sh development
Report the exit code and the last 30 output lines. Then verify with run-stage-sql.sh --readonly development --query on __EFMigrationsHistory that every id in pending_dev is applied.
2. Document analysis: ${docanaWorktree(ctx.docana_sha)}. Then: bash ${LIB}/migrate-stage.sh development --db document-analysis --repo-dir "${DOCANA_WT}"
Report the exit code and the last 30 output lines. Exit 0 alone is no proof that the development DB was the target: verify with bash ${LIB}/run-stage-sql.sh --readonly --db document-analysis development ${DOCANA_HISTORY} that every id in docana_pending_dev (${JSON.stringify(ctx.docana_pending_dev)}) is applied. Then ${DOCANA_WT_REMOVE}. Say in the summary whether document analysis migrations were applied on development.
3. Development StageSql (bpp DB only): in ${BACKEND}: git fetch origin; bash ${LIB}/find-stage-sql.sh --repo ${BACKEND} --from <recorded bpp-backend staging head> --to <recorded bpp-backend development head> --stage development. Take only entries with source=convention (their stages header lists development). Run all pre-deploy ones first, then all post-deploy ones (the dev code is already deployed): show each file's content in evidence, then bash ${LIB}/run-stage-sql.sh development <sql_file>. Any failure -> halt. Remove the temp dir find-stage-sql.sh made.
${sqlId('development')}${dryNote('migrate-stage.sh development (either database), the git worktree commands or any run-stage-sql.sh write (read-only queries and find-stage-sql.sh still run)')}`, R.dev, { critics: 2 })

  // 5b. Bump shared
  phase('Bump shared')
  const bs = await gate(6, `Re-resolve the newest BPP.Shared.NET package; if it is not ${ctx.package}, halt (a newer one appeared).
Use the Skill tool to load bpp-bump-shared-version and run it for exactly ${ctx.package}.${dryNote('the bump (no commits, no pushes)')}
Afterwards list every consumer with its result (bumped / already current / skipped + reason / unverified). Then git ls-remote each repo's development and return heads [{repo, sha}] for all repos in the run context heads; for each changed head show in evidence that the only new commits are this bump's commits (git log <old>..<new> --oneline).${DRY ? '' : ` Then record them: ${STATE} set-heads '<JSON object {"<repo>": "<sha>", ...}>'.`}`, R.bump, { critics: 2, extra: { heads: HEADS } })
  if (!DRY && bs.heads && bs.heads.length) ctx.heads = bs.heads

  // 6. Promote: preview, critics, go
  phase('Promote')
  const pp = await gate(7, `Use the Skill tool to load bpp-promote-dev-to-staging, direction development -> staging. Run it up to and including its step 4 Preview, then STOP: do not answer the go, create nothing, push nothing.
Return the preview verbatim in preview, and the repo list it would promote. Check the restart guard: pending_staging = ${JSON.stringify(ctx.pending_staging)}; if non-empty, every .NET consumer (BPP.*/Directory.Build.props has <BppSharedVersion>) with a staging branch must be in the preview list or already have an open promotion MR. Document analysis restart guard: docana_pending_staging = ${JSON.stringify(ctx.docana_pending_staging)}; if non-empty, bpp-document-analysis must be in the preview list or already have an open promotion MR.`, R.promotePreview, {
    label: 'Promote (preview)', critics: 2,
    extra: { preview: { type: 'string' }, repos: { type: 'array', items: { type: 'string' } } },
  })
  ctx.promote_preview = pp.preview || ''
  const pg = await gate(7, `The critics approved this bpp-promote-dev-to-staging preview (development -> staging) for repos ${JSON.stringify(pp.repos || [])}:
${ctx.promote_preview}

Use the Skill tool to load bpp-promote-dev-to-staging and run it again with the go given (the user's go is this approved preview). If its preview now lists a different repo set, halt. Run all its steps after go (4b migration-guide audit, 5, 6, 6b conflict back-merge, 7 report).${dryNote('the go: create no MRs, push nothing')}
Return mrs (every open dev -> staging promotion MR, including ones that already existed: repo, project_id, iid, url, kind dotnet|ui|other), heads (git ls-remote development for every repo in the run context heads, with git log old..new proof that new commits are only this phase's own), and ui_configs_sql (its "ui_configs SQL to run on the staging DB" block plus the full reference block, verbatim).
Re-check the restart guard and the document analysis restart guard against the MR list.${DRY ? '' : `
Record the new heads: ${STATE} set-heads '<JSON object {"<repo>": "<sha>", ...}>'.`}`, R.promoteGo, {
    label: 'Promote (go)', critics: 2,
    extra: { mrs: MRS, heads: HEADS, ui_configs_sql: { type: 'string' } },
  })
  ctx.mrs = pg.mrs || []
  if (!DRY && pg.heads && pg.heads.length) ctx.heads = pg.heads
  ctx.ui_configs_sql = pg.ui_configs_sql || ''
  if (!DRY && !ctx.mrs.length) throw new Halt('Promote', 'no promotion MRs after go')

  // 7. UI versions
  phase('UI versions')
  await gate(8, `For every UI promotion MR in the run context (kind ui)${DRY ? ', or in dry run every UI repo from the approved preview,' : ''}: read package.json (and the bumped project package.json the promote skill names, e.g. bpp-stella-ui's) on development, staging and main via glab api files/.../raw. Version on development must be > staging and > main (semver). Re-run the promote skill's post-bump check for the lock entries (package-lock.json root + packages[""] versions match package.json). Put each version triple in evidence.`, R.ui)

  // 8. Wait green
  phase('Wait green')
  const wg = await gate(9, DRY
    ? `DRY RUN: no promotion MRs were created. Print the poll you would run for each preview repo (pipeline status, detailed_merge_status, head sha vs recorded head). Read-only: for every open promotion MR with head_pipeline.status "skipped" whose head commit message contains [skip ci] or [ci skip], print the empty commit you would push (WOULD RUN: git commit --allow-empty -m "chore: run CI after a skipped commit" ... git push origin HEAD:development in <repo>). Run nothing else. Return duo_mrs empty.`
    : `For every promotion MR in the run context: poll glab api projects/<id>/merge_requests/<iid> every 2 minutes for at most 90 minutes total (several bounded Bash calls).
Done when every MR has head_pipeline.status=success, detailed_merge_status=mergeable and sha equal to the recorded development head of its repo.
A failed job: retry it once (glab api -X POST projects/<id>/jobs/<job id>/retry); failed again -> halt. A moved sha -> halt. Timeout -> halt naming the MRs still waiting.
head_pipeline.status "skipped" is not green. Read the MR head commit message (glab api projects/<id>/repository/commits/<sha>): it contains [skip ci] or [ci skip] -> once per repo, in a new worktree of the repo on origin/development: git commit --allow-empty -m "chore: run CI after a skipped commit" plus the commit trailer, git push origin HEAD:development (no force), remove the worktree, ${STATE} add-applied "phase 8: empty CI commit <sha> on <repo> development", and update that repo's recorded head to the new sha (${STATE} set-heads with the full object). Then keep polling. Still skipped after that, or skipped without such a message -> halt.
At the end return heads: git ls-remote origin refs/heads/development for every repo in the run context heads (they include any empty CI commit pushed above), with git log old..new proof that a changed head differs only by that commit.
An MR whose only blocker is a Duo requested_changes review (pipeline green, no conflicts): do not halt; return it in duo_mrs with every Duo finding verbatim (discussion notes from GitLabDuo).`, R.wait, {
    critics: 2,
    extra: {
      heads: HEADS,
      duo_mrs: {
        type: 'array',
        items: { type: 'object', properties: { repo: { type: 'string' }, iid: { type: 'number' }, url: { type: 'string' }, findings: { type: 'string' } }, required: ['repo', 'iid', 'findings'] },
      },
    },
  })
  if (!DRY && wg.heads && wg.heads.length) ctx.heads = wg.heads
  ctx.duo = []
  for (const d of (wg.duo_mrs || [])) {
    const vs = await parallel([0, 1, 2].map(i => () => agent(`You are Duo critic ${i + 1} for promotion MR ${d.url || d.repo + '!' + d.iid} of the BPP dev -> staging release (run ${RUN_ID}). GitLab Duo requested changes. Read the MR diff (glab api, read-only) and judge each finding.
Rules (from the spec):
${R.duo}
Findings (verbatim):
${d.findings}

Read-only: no MR changes, no push. Default to block: true when unsure. Return block: false only when every finding is a non-issue, with the reason per finding.`, { schema: CRITIC, label: `Duo ${d.repo}!${d.iid}: critic ${i + 1}`, phase: 'Wait green' })))
    const bad = vs.map((v, i) => (!v ? `critic ${i + 1}: no verdict` : (v.block ? `critic ${i + 1}: ${v.reason}` : null))).filter(Boolean)
    if (bad.length) throw new Halt('Wait green', `Duo findings on ${d.repo}!${d.iid} not cleared (Bypass needs a human): ${bad.join(' | ')}`)
    ctx.duo.push({ repo: d.repo, iid: d.iid, url: d.url || '', why: vs.map(v => v.reason).join(' / ') })
  }

  // 9. Staging migrate
  phase('Staging migrate')
  await gate(10, `1. Check git -C ${SHARED} rev-parse HEAD equals ${ctx.shared_sha}.
2. Re-list pending staging migrations (bash ${LIB}/run-stage-sql.sh --readonly staging --query 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1' vs the checkout). It must equal ${JSON.stringify(ctx.pending_staging)}; else halt.
3. bash ${LIB}/migrate-stage.sh staging  - report exit code and last 30 lines; verify every pending id is now applied (read-only query).
4. Document analysis: head = the recorded development head of bpp-document-analysis (run context heads; the commit its promotion MR merges). In ${DOCANA}: git fetch origin; the migration ids at head (git ls-tree --name-only <head>:${DOCANA_MIG}) must equal the ones at ${ctx.docana_sha}; else halt. Re-list its pending staging migrations (bash ${LIB}/run-stage-sql.sh --readonly --db document-analysis staging ${DOCANA_HISTORY} vs that list). It must equal ${JSON.stringify(ctx.docana_pending_staging)}; else halt.
5. ${docanaWorktree('<head>')}. Then: bash ${LIB}/migrate-stage.sh staging --db document-analysis --repo-dir "${DOCANA_WT}"  - report exit code and last 30 lines. Exit 0 alone is no proof that the staging DB was the target: verify with bash ${LIB}/run-stage-sql.sh --readonly --db document-analysis staging ${DOCANA_HISTORY} that every pending id is now applied there; else halt. Then ${DOCANA_WT_REMOVE}.
6. Pre-deploy SQL, bpp-backend only, bpp DB only: in ${BACKEND}: git fetch origin; bash ${LIB}/find-stage-sql.sh --repo ${BACKEND} --from <recorded bpp-backend staging head> --to <recorded bpp-backend development head> --stage staging. Take only entries with source=convention and timing=pre-deploy. Show each file's content in evidence, then run each: bash ${LIB}/run-stage-sql.sh staging <sql_file>. Any failure -> halt. Remove the temp dir find-stage-sql.sh made. StageSql files of other repos do not run here; phase 13 hands them to the critics.
${sqlId('staging')}${dryNote('migrate-stage.sh staging (either database), the git worktree commands or any run-stage-sql.sh write (read-only --readonly queries and find-stage-sql.sh still run)')}`, R.stagingMigrate, { critics: 3 })

  // 10. Merge
  phase('Merge')
  await gate(11, `Merge every promotion MR that is not on the Duo path: glab api -X PUT "projects/<id>/merge_requests/<iid>/merge" -f sha=<recorded development head of that repo> -f should_remove_source_branch=false
After each merge: ${DRY ? '(dry run: nothing)' : `${STATE} add-applied "phase 10: merged <repo>!<iid>"`}. A refused merge -> stop at once and halt, listing the MRs already merged.
Duo path (critics judged every finding a non-issue): ${JSON.stringify(ctx.duo)}. For each: add an MR note with the critics' reasons, close the MR (glab api -X PUT projects/<id>/merge_requests/<iid> -f state_event=close), then in a new worktree of the repo on origin/staging: git merge --no-ff <recorded development head> -m "Merge development into staging (release ${RUN_ID})" plus the commit trailer, git push origin HEAD:staging (no force), remove the worktree.
Finally verify development still exists in every repo: git ls-remote origin refs/heads/development non-empty; if missing, recreate is a human decision -> halt.${dryNote('any merge, close, note or push')}`, R.merge, { critics: 3 })

  // 11. Watch deploy
  phase('Watch deploy')
  await gate(12, `1. For every repo merged in phase 10: wait for its newest staging pipeline (glab api projects/<id>/pipelines?ref=staging) and its deploy job to reach success, polling every 2 minutes, at most 60 minutes. Failed -> halt naming the repo, job id and first error line.
2. Health against the Preflight baseline (${BDIR}): ${HEALTH} json > ${BDIR}/statuses-now.json; ${HMAP} map ${BDIR}/statuses-now.json ${BDIR}/hosts.tsv <release repos from ${BDIR}/repos.txt, comma-separated> > ${BDIR}/map-now.json; ${HMAP} diff ${BDIR}/map.json ${BDIR}/map-now.json.
3. new_unhealthy (healthy or absent at baseline, unhealthy now): re-run step 2 every 3 minutes. An endpoint that turns healthy is done. An endpoint still unhealthy once its fail_since + 15 minutes has passed -> halt naming endpoint, host and repos. Keep polling until every new_unhealthy endpoint is either healthy or past fail_since + 15 minutes (bounded: at most 10 rounds, each Bash call under 10 minutes; reaching the bound with one still unhealthy -> halt). You may never return ok while a new_unhealthy endpoint is still unhealthy. known_unhealthy (already unhealthy at baseline): list them in summary, no halt.
Document analysis: docana_pending_staging = ${JSON.stringify(ctx.docana_pending_staging)}; if non-empty, bpp-document-analysis must be one of those repos and its staging pipeline must have run its deploy job; else halt.
Baseline from Preflight (run context baseline): use the files in ${BDIR}; if they are missing, halt (no baseline to compare with).${dryNote('nothing (no merge happened); still run steps 2-3 read-only')}`, R.deploy)

  // 12. ui_configs
  phase('ui_configs')
  const uc = await gate(13, `ui_configs SQL from the promote phase (verbatim):
${ctx.ui_configs_sql || '(none returned)'}

1. Take only the staging group's statements marked "changed by this promotion" for ui_type 'cockpit' and 'kundenportal'. Never stella. If none: say "no ui_configs change for staging" and skip to 4.
2. Check the table exists: bash ${LIB}/run-stage-sql.sh --readonly staging --query "SELECT to_regclass('ui_configs')". Missing -> halt.
3. Write those statements (plain SQL, no BEGIN/COMMIT) with the Write tool to ${SDIR}/ui-configs-${RUN_ID}.sql (expand $HOME), check it contains no "stella", then: bash ${LIB}/run-stage-sql.sh staging <that file>.
4. Read-only check: bash ${LIB}/run-stage-sql.sh --readonly staging --query "SELECT ui_type, version_number, updated_at FROM ui_configs WHERE is_soft_deleted = false ORDER BY ui_type;"
Return sql = the statements you ran (or would run), stella_sql = the staging stella statement from the block (for the Henry ping, not run).${dryNote('the UPDATE file (steps 2 and 4 still run)')}`, R.ui_configs, {
    critics: 2,
    extra: { sql: { type: 'string' }, stella_sql: { type: 'string' } },
  })
  ctx.stella_sql = uc.stella_sql || ''
  ctx.ui_configs_sql = (uc.sql ? 'Ran on staging:\n' + uc.sql + '\n\n' : '') + (ctx.stella_sql ? 'After the store release (stella):\n' + ctx.stella_sql : '')

  // 13. Manual SQL: find + convention post-deploy, critics, then fallback
  phase('Manual SQL')
  const ms = await gate(14, `1. Last staging release: the newest merged MR into staging before this run, per repo (glab api projects/<id>/merge_requests?target_branch=staging&state=merged&order_by=merged_at), excluding the MRs merged in phase 10.
2. For every promoted repo: merged feature MRs into development since then -> JSON [{iid, project, description}] written with the Write tool to ${SDIR}/mrs-${RUN_ID}-<repo>.json.
3. For every promoted repo checkout under $HOME/Entwicklung/bpp: bash ${LIB}/find-stage-sql.sh --repo <dir> --from <recorded staging head of that repo> --to <recorded development head> --stage staging --mr-json <that file>. Move every listed sql_file into ${SDIR}/sql-${RUN_ID}/ (keep names unique) and remove the temp dir.
4. bpp-backend convention entries with timing post-deploy (stages lists staging): show content in evidence, then run each: bash ${LIB}/run-stage-sql.sh staging <file>. Failure -> halt.
5. bpp-backend convention pre-deploy entries ran in phase 9: skip them. Every other entry is a fallback candidate: source diff or mr-description, timing unknown, and every convention (StageSql) entry from a repo outside bpp-backend, pre-deploy or post-deploy (never skipped silently). Leave out entries already recorded on staging (has-sql exit 0) and list them in evidence. Return each candidate in candidates with its sql_file path, source, origin (repo:path or MR url), id (the SQL file id below) and the full SQL text. Do not run candidates.
${sqlId('staging')}${dryNote('step 4 (find-stage-sql.sh and has-sql still run)')}`, R.manual, {
    label: 'Manual SQL (convention)', critics: 3,
    extra: {
      candidates: {
        type: 'array',
        items: { type: 'object', properties: { sql_file: { type: 'string' }, source: { type: 'string' }, origin: { type: 'string' }, id: { type: 'string' }, sql: { type: 'string' } }, required: ['sql_file', 'source', 'origin', 'id', 'sql'] },
      },
    },
  })
  ctx.sql_candidates = ms.candidates || []
  if (ctx.sql_candidates.length) {
    const fallbackRules = R.manual + '\n- Judge each candidate: meant for staging (not only main or dev), idempotent (safe to run twice), not destructive (no DROP/TRUNCATE/DELETE without a narrow WHERE), not already applied (check with run-stage-sql.sh --readonly), no BEGIN/COMMIT. Any doubt on any candidate -> block.'
    const fc = await parallel([0, 1, 2].map(i => () => agent(criticPrompt(14, 'Manual SQL', fallbackRules, { candidates: ctx.sql_candidates }, LENSES[i]), { schema: CRITIC, label: `Manual SQL (fallback): critic ${i + 1}`, phase: 'Manual SQL' })))
    const bad = fc.map((v, i) => (!v ? `critic ${i + 1}: no verdict` : (v.block ? `critic ${i + 1}: ${v.reason}` : null))).filter(Boolean)
    if (bad.length) throw new Halt('Manual SQL', `fallback SQL not approved by all critics: ${bad.join(' | ')}`)
    await gate(14, `All critics approved these fallback SQL candidates: ${JSON.stringify(ctx.sql_candidates.map(c => ({ sql_file: c.sql_file, origin: c.origin, id: c.id })))}.
Check each file's content is unchanged from the approved text (run context sql_candidates). Run each: bash ${LIB}/run-stage-sql.sh staging <sql_file>. Failure -> halt (say which ran).
${sqlId('staging')}${dryNote('any of them')}`, R.manual, { label: 'Manual SQL (fallback run)', critics: 2 })
  } else {
    log('Manual SQL: no fallback candidates')
  }

  // 14. Henry ping
  phase('Henry ping')
  const hp = await gate(15, `Build the release ping. Write the body with the Write tool to ${SDIR}/ping-${RUN_ID}.txt (expand $HOME):
- released: every promotion MR (url) and the versions (BPP.Shared.NET ${ctx.package}, UI versions from phase 7)
- go-stella app version that now needs submitting/unlocking in App Store + Play Store (read projects/bpp-stella-app/package.json on bpp-stella-ui staging)
- the stella ui_configs statement to run after the store release: ${ctx.stella_sql || '(take it from the run context ui_configs_sql)'}
- what ran on the DBs (run context applied)${DRY ? '\n- mark it clearly as a DRY RUN: nothing was written' : ''}
Then: ${PING} info "bpp-release-staging ${DRY ? '[dry-run] ' : ''}${RUN_ID} released to staging" "${SDIR}/ping-${RUN_ID}.txt"
Return ping = the output verbatim.`, R.ping, { critics: 2, extra: { ping: { type: 'string' } } })

  // 15. Report
  phase('Report')
  const rp = await gate(16, `Write the final report: phases passed, MRs merged, DB changes on development and staging for both databases (bpp and document analysis), SQL run, ui_configs, open TODOs (store release, stella ui_configs; and, when document analysis migrations were applied on development but bpp-document-analysis got no new development commit in this run, "recreate the BPP.DocumentAnalysis.App containers on development"), and the phase 0 result as one line, word for word: ${ctx.skill_update}. ${DRY ? 'DRY RUN: do not run state.sh done; list every WOULD RUN command from the run context instead.' : `Then: ${STATE} done and show ${STATE} get.`}`, R.report, { critics: 2 })

  // 16. Cleanup
  phase('Cleanup')
  await gate(17, `1. ${restoreShared()} A dirty tree or a mismatch -> halt, no force.
2. Use the Skill tool to load bpp-cleanup-merged-worktrees; run its plan. ${DRY ? 'DRY RUN: plan only, apply nothing.' : 'Apply only the paths of its REMOVE and LANDED rows (apply <path>...); never --force, never apply-scaffold, never stale.sh.'}
3. rm -rf ${SDIR}/sql-${RUN_ID} ${BDIR} ${SDIR}/pre-move-sha-${RUN_ID} (only these). If "${DOCANA_WT}" still exists: ${DOCANA_WT_REMOVE}.
4. ${STATE} unlock ${RUN_ID}`, R.cleanup)

  return {
    status: 'done',
    phase: 'Cleanup',
    summary: `${DRY ? '[dry-run] ' : ''}${rp.summary}`,
    uiConfigsSql: ctx.ui_configs_sql,
    henryPing: hp.ping || '',
  }
} catch (e) {
  if (e && e.halt) return await doHalt(e)
  // unexpected script error: still record the halt and release the lock
  return await doHalt(new Halt(cur, `workflow script error: ${e && e.message ? e.message : String(e)}`))
}
