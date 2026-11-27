#!/usr/bin/env bash
# Shape checks for workflow.js: phase list, banned calls, key strings, JS syntax.
# shellcheck disable=SC2016,SC1091
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
WF="$here/../workflow.js"

if [ ! -f "$WF" ]; then
  _fail "workflow.js exists"
  finish
fi
_pass "workflow.js exists"
SRC=$(cat "$WF")

# meta block = from "export const meta" to the first line that is only "}"
META=$(awk '/^export const meta/{on=1} on{print} on && /^}/{exit}' "$WF")
assert_contains "phases:" "$META" "meta has phases"

# the spec's phases 0-16 (incl. 5b) in the spec's order
WANT='Skill update
Preflight
Pull
Shared state
Local migrate
Dev migrate
Bump shared
Promote
UI versions
Wait green
Staging migrate
Merge
Watch deploy
ui_configs
Manual SQL
Henry ping
Report
Cleanup'
GOT=$(printf '%s\n' "$META" | sed -n "s/.*title: '\([^']*\)'.*/\1/p")
assert_eq "$WANT" "$GOT" "meta.phases titles match the spec phases in order"

# every meta title is also used by a phase() call
while IFS= read -r t; do
  assert_contains "phase('$t')" "$SRC" "phase('$t') is called"
done <<EOF
$WANT
EOF

# banned: they break workflow resume
assert_not_contains "Date.now" "$SRC" "no Date.now"
assert_not_contains "Math.random" "$SRC" "no Math.random"
assert_not_contains "new Date(" "$SRC" "no new Date("
assert_not_contains "$HOME/" "$SRC" "no literal home path"

for s in 'should_remove_source_branch=false' '--readonly' 'henry-ping.sh' 'state.sh lock' \
         'state.sh unlock' 'state.sh halt' 'migrate-stage.sh staging' 'run-stage-sql.sh staging' \
         'migrate-stage.sh staging --db document-analysis' 'migrate-stage.sh development --db document-analysis' \
         'migrate-stage.sh local --db document-analysis' '--readonly --db document-analysis' \
         'find-stage-sql.sh' 'args.runId' 'dry-run' 'block: true' '$HOME/.claude/skills/bpp-release-staging/lib'; do
  assert_contains "$s" "$SRC" "workflow mentions $s"
done

# a main stage never appears as a write target
assert_not_contains "migrate-stage.sh main" "$SRC" "no migrate-stage.sh main"
assert_not_contains "run-stage-sql.sh main" "$SRC" "no run-stage-sql.sh main"

# JS syntax: strip "export " and wrap the body in an async function, because the
# workflow body uses top-level await and return, as the Workflow runner allows
if command -v node >/dev/null 2>&1; then
  T=$(mktemp -d)
  { echo 'async function wf(args, agent, parallel, phase, log) {'; sed 's/^export //' "$WF"; echo '}'; } > "$T/wf.js"
  if node --check "$T/wf.js" 2> "$T/err"; then
    _pass "node --check parses workflow.js"
  else
    _fail "node --check parses workflow.js: $(head -5 "$T/err")"
  fi
  rm -rf "$T"
else
  _fail "node is installed (needed for the syntax check)"
fi

# Run workflow.js with stub agents (every worker ok, every critic approves) and
# check the prompts: Henry ping may run henry-ping.sh, Cleanup may run
# state.sh unlock, every other worker may not, and the critics get the same rule.
if command -v node >/dev/null 2>&1; then
  T=$(mktemp -d)
  cat > "$T/h.js" <<'EOF'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export /mg, '')
const wf = new Function('args', 'agent', 'parallel', 'phase', 'log', `return (async () => {${src}\n})()`)
const prompts = {}
const agent = async (p, o) => {
  prompts[o.label] = p
  if (o.schema && o.schema.properties && 'block' in o.schema.properties) return { block: false, reason: '' }
  if (o.label === 'halt') return { ping: '', notes: '' }
  return { ok: true, halt: false, reason: '', summary: 's', applied: [], evidence: [], ping: 'p',
    package: '1.0.0', shared_sha: 'abc', docana_sha: 'dcf', docana_pending_staging: ['20260101000000_DocAna'], heads: [{ repo: 'r', sha: 'a' }], staging_heads: [{ repo: 'r', sha: 'b' }],
    mrs: [{ repo: 'r', iid: 1, url: 'u', kind: 'dotnet' }],
    changed_skills: process.argv[5] === 'changed' ? ['bpp-pull-all-dev'] : [],
    skill_update: process.env.STUB_SKILL_UPDATE || 'on',
    release_blockers: (o.label === 'Preflight: worker' && process.env.STUB_BLOCKERS) ? [process.env.STUB_BLOCKERS] : [],
    ...((o.label === 'Wait green: worker' && process.env.STUB_WAIT_HEAD) ? { heads: [{ repo: 'r', sha: process.env.STUB_WAIT_HEAD }] } : {}) }
}
const parallel = async fns => Promise.all(fns.map(f => f()))
wf({ mode: process.argv[3], runId: '2026-11-26-0000' }, agent, parallel, () => {}, () => {}).then(r => {
  fs.writeFileSync(process.argv[4] + '/status', r.status + ' ' + r.phase)
  for (const [k, v] of Object.entries(prompts)) fs.writeFileSync(process.argv[4] + '/' + k.replace(/[^A-Za-z0-9]+/g, '_'), v)
})
EOF
  for mode in run dry-run; do
    O="$T/$mode"
    mkdir -p "$O"
    node "$T/h.js" "$WF" "$mode" "$O" 2> "$T/err" || _fail "$mode: stub run failed: $(head -5 "$T/err")"
    assert_eq "done Cleanup" "$(cat "$O/status" 2>/dev/null)" "$mode: stub run reaches Cleanup"
    hw=$(cat "$O/Henry_ping_worker" 2>/dev/null)
    cw=$(cat "$O/Cleanup_worker" 2>/dev/null)
    pw=$(cat "$O/Pull_worker" 2>/dev/null)
    assert_contains "henry-ping.sh\" info" "$hw" "$mode: Henry ping worker is told to run henry-ping.sh"
    assert_eq "" "$(printf '%s\n' "$hw" | grep -i 'not run.*henry-ping')" "$mode: Henry ping worker is not banned from henry-ping.sh"
    assert_contains "state.sh\" unlock" "$cw" "$mode: Cleanup worker is told to run state.sh unlock"
    assert_eq "" "$(printf '%s\n' "$cw" | grep -i 'not run.*state.sh unlock')" "$mode: Cleanup worker is not banned from state.sh unlock"
    assert_contains 'Do not run "state.sh halt", "state.sh unlock" or henry-ping.sh' "$pw" "$mode: other workers keep the ban"
    assert_contains 'Run henry-ping.sh only as the Task says' "$(cat "$O/Henry_ping_critic_1" 2>/dev/null)" "$mode: Henry ping critic gets the matching rule"
    assert_contains 'Run "state.sh unlock" only as the Task says' "$(cat "$O/Cleanup_critic_1" 2>/dev/null)" "$mode: Cleanup critic gets the matching rule"
    assert_contains 'Do not run "state.sh halt", "state.sh unlock" or henry-ping.sh' "$(cat "$O/Pull_critic_1" 2>/dev/null)" "$mode: other critics get the ban"

    # phase 0: every run pulls + installs the mirror; no diff critics when no used skill changed
    [ -f "$O/Skill_update_install_worker" ] && f=yes || f=no
    assert_eq yes "$f" "$mode: Skill update install runs even when no used skill changed"
    [ -f "$O/Skill_update_diff_critic_1" ] && f=yes || f=no
    assert_eq no "$f" "$mode: no diff critics when no used skill changed"

    # resume = start again at phase 0 and re-check every phase
    assert_contains 'starts again at phase 0' "$(cat "$O/Preflight_worker" 2>/dev/null)" "$mode: Preflight says a rerun starts again at phase 0"

    # phase 5: dev StageSql after the dev migration, skipping recorded files
    dw=$(cat "$O/Dev_migrate_worker" 2>/dev/null)
    assert_contains '--stage development' "$dw" "$mode: Dev migrate lists StageSql for development"
    assert_contains 'run-stage-sql.sh development' "$dw" "$mode: Dev migrate runs StageSql via run-stage-sql.sh development"
    assert_contains 'has-sql development' "$dw" "$mode: Dev migrate skips SQL already applied on development"
    # phase 9: only bpp-backend pre-deploy, skipping recorded files
    sw=$(cat "$O/Staging_migrate_worker" 2>/dev/null)
    assert_contains 'has-sql staging' "$sw" "$mode: Staging migrate skips SQL already applied on staging"
    # document analysis DB: own secrets, own migrator from a worktree at a fixed commit, read-only SQL
    assert_contains '--readonly --db document-analysis development --check' "$(cat "$O/Preflight_worker" 2>/dev/null)" "$mode: Preflight checks the document analysis dev secret"
    assert_contains '--readonly --db document-analysis development --query' "$(cat "$O/Shared_state_worker" 2>/dev/null)" "$mode: Shared state lists the document analysis migrations"
    assert_contains 'migration_id' "$(cat "$O/Shared_state_worker" 2>/dev/null)" "$mode: Shared state queries the snake_case history column"
    lw=$(cat "$O/Local_migrate_worker" 2>/dev/null)
    assert_contains 'worktree add --detach' "$lw" "$mode: Local migrate builds the document analysis worktree"
    assert_contains ' dcf' "$lw" "$mode: Local migrate pins the document analysis commit of phase 3"
    assert_contains 'migrate-stage.sh development --db document-analysis --repo-dir' "$dw" "$mode: Dev migrate runs the document analysis migrator"
    assert_contains 'migrate-stage.sh staging --db document-analysis --repo-dir' "$sw" "$mode: Staging migrate runs the document analysis migrator"
    assert_contains '20260101000000_DocAna' "$sw" "$mode: Staging migrate gets the phase 3 document analysis pending list"
    # exit 0 of the migrator does not prove the target: both stages re-read the target's history
    assert_contains 'run-stage-sql.sh --readonly --db document-analysis development --query' "$dw" "$mode: Dev migrate verifies the document analysis target DB afterwards"
    assert_contains 'run-stage-sql.sh --readonly --db document-analysis staging --query' "$sw" "$mode: Staging migrate verifies the document analysis target DB afterwards"
    assert_contains 'bpp-document-analysis must be in the preview list' "$(cat "$O/Promote_preview_worker" 2>/dev/null)" "$mode: Promote preview has the document analysis restart guard"
    assert_contains 'bpp-document-analysis must be one of those repos' "$(cat "$O/Watch_deploy_worker" 2>/dev/null)" "$mode: Watch deploy checks the document analysis redeploy"
    assert_not_contains 'run-stage-sql.sh staging --db document-analysis' "$sw" "$mode: no SQL write against the document analysis DB"
    # phase 13: StageSql outside bpp-backend is a fallback candidate
    mw=$(cat "$O/Manual_SQL_convention_worker" 2>/dev/null)
    assert_contains 'outside bpp-backend' "$mw" "$mode: Manual SQL treats StageSql outside bpp-backend as a fallback candidate"
    assert_contains 'has-sql staging' "$mw" "$mode: Manual SQL skips SQL already applied on staging"
  done

  # run mode: state setters instead of free text, spec phase labels
  O="$T/run"
  shw=$(cat "$O/Shared_state_worker" 2>/dev/null)
  assert_contains 'set-heads' "$shw" "run: Shared state records heads with state.sh set-heads"
  assert_contains 'set-package' "$shw" "run: Shared state records the package with state.sh set-package"
  assert_not_contains 'no heads setter' "$shw" "run: no free-text heads in applied"
  assert_contains 'set-phase 5b' "$(cat "$O/Bump_shared_worker" 2>/dev/null)" "run: Bump shared sets the spec phase label 5b"
  assert_contains 'set-phase 16' "$(cat "$O/Cleanup_worker" 2>/dev/null)" "run: Cleanup sets the spec phase label 16"
  assert_contains 'set-heads' "$(cat "$O/Bump_shared_worker" 2>/dev/null)" "run: Bump shared re-records heads with set-heads"
  assert_contains 'set-heads' "$(cat "$O/Promote_go_worker" 2>/dev/null)" "run: Promote re-records heads with set-heads"
  assert_contains 'add-sql development' "$(cat "$O/Dev_migrate_worker" 2>/dev/null)" "run: Dev migrate records each SQL file with add-sql"
  assert_contains 'add-sql staging' "$(cat "$O/Staging_migrate_worker" 2>/dev/null)" "run: Staging migrate records each SQL file with add-sql"
  assert_contains 'add-sql staging' "$(cat "$O/Manual_SQL_convention_worker" 2>/dev/null)" "run: Manual SQL records each SQL file with add-sql"

  # dry-run: local git updates are allowed, critics are told so
  assert_contains 'Local git updates' "$(cat "$T/dry-run/Pull_critic_1" 2>/dev/null)" "dry-run: critics allow local git updates"

  # no document analysis commit from Shared state -> halt there
  O="$T/nodocana"
  mkdir -p "$O"
  sed "s/docana_sha: 'dcf', //" "$T/h.js" > "$T/h2.js"
  node "$T/h2.js" "$WF" run "$O" 2> "$T/err" || _fail "nodocana: stub run failed: $(head -5 "$T/err")"
  assert_eq "halted Shared state" "$(cat "$O/status" 2>/dev/null)" "no document analysis head: halts in Shared state"

  # a used skill changed -> diff critics run before the install
  O="$T/changed"
  mkdir -p "$O"
  node "$T/h.js" "$WF" run "$O" changed 2> "$T/err" || _fail "changed: stub run failed: $(head -5 "$T/err")"
  [ -f "$O/Skill_update_diff_critic_1" ] && f=yes || f=no
  assert_eq yes "$f" "changed: diff critics run when a used skill changed"
  [ -f "$O/Skill_update_install_worker" ] && f=yes || f=no
  assert_eq yes "$f" "changed: install runs after the critics"

  # BPP_RELEASE_SKILL_UPDATE: the diff worker reads it (default on) and returns skill_update
  dw0=$(cat "$T/run/Skill_update_diff_worker" 2>/dev/null)
  assert_contains '${BPP_RELEASE_SKILL_UPDATE:-on}' "$dw0" "diff worker reads BPP_RELEASE_SKILL_UPDATE with default on"
  assert_contains 'temp clone' "$dw0" "diff worker: report mode uses a temp clone"
  assert_contains 'skill update off' "$dw0" "diff worker: off mode records skill update off"
  assert_contains 'skill_update' "$(cat "$T/run/Report_worker" 2>/dev/null)" "on: Report gets the skill update result"

  # off: no mirror pull, no install, no critics; the report says "skill update off"
  O="$T/off"
  mkdir -p "$O"
  STUB_SKILL_UPDATE=off node "$T/h.js" "$WF" run "$O" changed 2> "$T/err" || _fail "off: stub run failed: $(head -5 "$T/err")"
  assert_eq "done Cleanup" "$(cat "$O/status" 2>/dev/null)" "off: stub run reaches Cleanup"
  [ -f "$O/Skill_update_install_worker" ] && f=yes || f=no
  assert_eq no "$f" "off: no install"
  [ -f "$O/Skill_update_diff_critic_1" ] && f=yes || f=no
  assert_eq no "$f" "off: no diff critics"
  assert_contains 'skill update off' "$(cat "$O/Report_worker" 2>/dev/null)" "off: Report records skill update off"

  # report: temp clone only, never install, no critics; the report lists the differing skills
  O="$T/report"
  mkdir -p "$O"
  STUB_SKILL_UPDATE=report node "$T/h.js" "$WF" run "$O" changed 2> "$T/err" || _fail "report: stub run failed: $(head -5 "$T/err")"
  assert_eq "done Cleanup" "$(cat "$O/status" 2>/dev/null)" "report: stub run reaches Cleanup"
  [ -f "$O/Skill_update_install_worker" ] && f=yes || f=no
  assert_eq no "$f" "report: no install"
  [ -f "$O/Skill_update_diff_critic_1" ] && f=yes || f=no
  assert_eq no "$f" "report: no diff critics"
  rw=$(cat "$O/Report_worker" 2>/dev/null)
  assert_contains 'skill update report' "$rw" "report: Report records skill update report"
  assert_contains 'bpp-pull-all-dev' "$rw" "report: Report lists the differing skill"

  # fix 1: health + deploy baseline in Preflight, compared in Watch deploy
  for mode in run dry-run; do
    pf=$(cat "$T/$mode/Preflight_worker" 2>/dev/null)
    assert_contains 'health-map.sh" hosts' "$pf" "$mode: Preflight maps repos to Traefik hosts"
    assert_contains 'health-map.sh" map' "$pf" "$mode: Preflight maps Gatus endpoints to repos"
    assert_contains 'health.sh" json' "$pf" "$mode: Preflight reads Gatus statuses as JSON"
    assert_contains 'take the newest job whose name contains "deploy"' "$pf" "$mode: Preflight checks the latest staging deploy job"
    assert_contains '<repo>=<downloaded compose file>' "$pf" "$mode: Preflight maps repos without a local clone via the downloaded compose file"
    assert_contains 'release_blockers' "$pf" "$mode: Preflight returns release blockers"
    assert_contains '"skipped"' "$pf" "$mode: Preflight reports skipped head pipelines"
    wd=$(cat "$T/$mode/Watch_deploy_worker" 2>/dev/null)
    assert_contains 'health-map.sh" diff' "$wd" "$mode: Watch deploy compares with the baseline"
    assert_contains 'known_unhealthy' "$wd" "$mode: Watch deploy lists baseline-unhealthy endpoints as known"
    assert_contains 'fail_since + 15 minutes' "$wd" "$mode: Watch deploy waits until fail_since + 15 minutes per endpoint"
    assert_contains 'never return ok while a new_unhealthy endpoint is still unhealthy' "$wd" "$mode: Watch deploy never ends ok with an endpoint still unhealthy"
    # fix 2: skipped head pipeline is not green; empty CI commit after [skip ci]
    assert_contains 'chore: run CI after a skipped commit' "$(cat "$T/$mode/Wait_green_worker" 2>/dev/null)" "$mode: Wait green handles a skipped pipeline with an empty commit"
    # fix 3: restore bpp-shared by SHA
    cl=$(cat "$T/$mode/Cleanup_worker" 2>/dev/null)
    assert_contains 'HEAD (git rev-parse HEAD) equals the pre-move SHA -> nothing to restore' "$cl" "$mode: Cleanup task skips the restore when HEAD is the pre-move SHA"
    assert_contains 'verify git rev-parse HEAD equals git rev-parse origin/development' "$cl" "$mode: Cleanup task verifies HEAD == origin/development"
  done
  assert_contains 'set-baseline' "$(cat "$T/run/Preflight_worker" 2>/dev/null)" "run: Preflight stores the baseline with state.sh set-baseline"
  pfr=$(cat "$T/run/Preflight_worker" 2>/dev/null)
  b=$(printf '%s\n' "$pfr" | grep -n 'Health + deploy baseline (read-only' | head -1 | cut -d: -f1)
  n=$(printf '%s\n' "$pfr" | grep -n 'state.sh" new 2026' | head -1 | cut -d: -f1)
  [ -n "$b" ] && [ -n "$n" ] && [ "$b" -lt "$n" ] && ord=yes || ord=no
  assert_eq yes "$ord" "run: Preflight takes the baseline (and may halt) before state.sh new"
  assert_not_contains 'set-baseline' "$(cat "$T/dry-run/Preflight_worker" 2>/dev/null)" "dry-run: Preflight does not touch state"
  assert_contains 'set-pre-move-sha' "$(cat "$T/run/Shared_state_worker" 2>/dev/null)" "run: Shared state records the pre-move SHA in state"
  assert_contains 'pre-move-sha-' "$(cat "$T/dry-run/Shared_state_worker" 2>/dev/null)" "dry-run: Shared state records the pre-move SHA in a file"
  assert_contains 'git push origin HEAD:development' "$(cat "$T/run/Wait_green_worker" 2>/dev/null)" "run: Wait green pushes the empty commit"
  assert_contains 'WOULD RUN' "$(cat "$T/dry-run/Wait_green_worker" 2>/dev/null)" "dry-run: Wait green only prints the empty commit"

  # Wait green re-records heads after an empty CI commit; Merge uses them
  O="$T/waithead"
  mkdir -p "$O"
  STUB_WAIT_HEAD=feedc0de node "$T/h.js" "$WF" run "$O" 2> "$T/err" || _fail "waithead: stub run failed: $(head -5 "$T/err")"
  assert_contains 'feedc0de' "$(cat "$O/Merge_worker" 2>/dev/null)" "run: Merge gets the head Wait green re-recorded"
  assert_contains 'return heads' "$(cat "$O/Wait_green_worker" 2>/dev/null)" "run: Wait green returns heads"
  O="$T/waithead-dry"
  mkdir -p "$O"
  STUB_WAIT_HEAD=feedc0de node "$T/h.js" "$WF" dry-run "$O" 2> "$T/err" || _fail "waithead-dry: stub run failed: $(head -5 "$T/err")"
  assert_not_contains 'feedc0de' "$(cat "$O/Merge_worker" 2>/dev/null)" "dry-run: heads stay the phase 3 heads"

  # a release repo is unhealthy or its staging deploy failed -> halt in Preflight, before any write
  O="$T/blocked"
  mkdir -p "$O"
  STUB_BLOCKERS='bpp-agent: staging deploy job 1 failed: secret not found' node "$T/h.js" "$WF" run "$O" 2> "$T/err" || _fail "blocked: stub run failed: $(head -5 "$T/err")"
  assert_eq "halted Preflight" "$(cat "$O/status" 2>/dev/null)" "blocked: halts in Preflight"
  [ -f "$O/Pull_worker" ] && f=yes || f=no
  assert_eq no "$f" "blocked: no phase after Preflight runs"
  hl=$(cat "$O/halt" 2>/dev/null)
  assert_contains 'secret not found' "$hl" "blocked: halt reason names the blocker"
  assert_contains 'pre-move SHA' "$hl" "blocked: halt agent restores by pre-move SHA"
  assert_contains 'restore nothing' "$hl" "blocked: no move recorded -> nothing to restore"

  # any other value halts in Skill update
  O="$T/bad"
  mkdir -p "$O"
  STUB_SKILL_UPDATE=maybe node "$T/h.js" "$WF" run "$O" 2> "$T/err" || _fail "bad: stub run failed: $(head -5 "$T/err")"
  assert_eq "halted Skill update" "$(cat "$O/status" 2>/dev/null)" "bad value: halts in Skill update"
  rm -rf "$T"
fi

finish
