#!/usr/bin/env bash
# Runs the cases of <cases.json> sequentially, each as a new session (chat) or a synthetic mail (channel "mail" -> mail-case.sh),
# with the Codex stop before every case (default 95 % 5 h / 95 % week). Idempotent: a case with a result file is skipped.
# Per case it writes <id>.case.json, <id>.json (client view), <id>.turns.json (agent_turn rows, read-only), <id>.db.json (the
# case's "db" check before/after, read-only).
# Usage: SELFTEST_ENV=<file> JAR=<cookie-jar> bash run-round.sh <cases.json> <out-dir> [ids...]
#   env SELFTEST_RUN_ID  required, unique per run ({{RUN}}, mail subjects); SKILL step 0 exports it
#   env SELFTEST_OWNER   fixture owner this round serves (default makler_a); cases with another session.owner are skipped
#   env TRUTH_CMD        optional command that prints ground-truth JSON (custscope-truth.sh, dashboard-truth.sh); stored as <id>.truth.json
# Exit 3 = quota stop (rerun after the reset; finished cases are kept).
set -u
. "$(dirname "$0")/lib.sh"
: "${JAR:?set JAR (scripts/lib.sh login <jar>)}"
CASES=$1; OUT=$2; shift 2; ONLY="$*"
: "${SELFTEST_RUN_ID:?export SELFTEST_RUN_ID (unique per run, e.g. RUN=\$(date -u +%Y%m%d-%H%M))}"
mkdir -p "$OUT"
OWNER=${SELFTEST_OWNER:-makler_a}
export SELFTEST_TAG=${SELFTEST_TAG:-selftest-$SELFTEST_RUN_ID}
# other owners' cases: case file only, so score.py lists them as NOT RUN instead of dropping them
ids=$(python3 -I -c "
import json,os,sys
for c in json.load(open(sys.argv[1])):
    o=(c.get('session') or {}).get('owner') or 'makler_a'
    if o==sys.argv[2]: print(c['id']); continue
    print('skip '+c['id']+': owner '+o+' (SELFTEST_OWNER='+o+')',file=sys.stderr)
    f=os.path.join(sys.argv[3],c['id']+'.case.json')
    if not os.path.exists(f): json.dump(c,open(f,'w'),ensure_ascii=False)" "$CASES" "$OWNER" "$OUT")
for id in $ids; do
  [ -n "$ONLY" ] && ! [[ " $ONLY " == *" $id "* ]] && continue
  [ -s "$OUT/$id.json" ] && continue
  quota_guard || exit 3
  python3 -I -c "import json,sys;c=[c for c in json.load(open(sys.argv[1])) if c['id']==sys.argv[2]][0];json.dump(c,open(sys.argv[3],'w'),ensure_ascii=False)" "$CASES" "$id" "$OUT/$id.case.json"
  dbsql=$(jq -r '.db.sql // empty' "$OUT/$id.case.json" | sed "s/{{RUN}}/$SELFTEST_RUN_ID/g")
  before=; [ -n "$dbsql" ] && before=$(pgr -Atc "$dbsql" 2>&1 | tail -1)
  channel=$(jq -r '.channel // "chat"' "$OUT/$id.case.json")
  if [ "$channel" = mail ]; then
    bash "$SCRIPTS/mail-case.sh" "$OUT/$id.case.json" "$OUT"; echo "$id mail exit $?"
  else
    timeout 1200 node "$SCRIPTS/chat-case.mjs" "$JAR" "$OUT/$id.case.json" "$OUT/$id.json"; echo "$id exit $?"
    sid=$(jq -r '.sessionId // empty' "$OUT/$id.json" 2>/dev/null)
    [ -n "$sid" ] && pgr -Atc "select coalesce(json_agg(json_build_object('id',id,'created',created_at,'kind',turn_kind,'status',status,'provider',provider,'model',model,
      'latency',latency_ms,'iter',iterations,'in',input_tokens,'out',output_tokens,'group',backoffice_group_id,'err',error_code,'tools',tool_call_log) order by created_at),'[]')
      from agent_turn where session_id='$sid'" 2>/dev/null | tail -1 > "$OUT/$id.turns.json"
  fi
  if [ -n "$dbsql" ]; then
    after=$(pgr -Atc "$dbsql" 2>&1 | tail -1)
    jq -n --arg b "$before" --arg a "$after" '{before:$b, after:$a}' > "$OUT/$id.db.json"
  fi
  [ -n "${TRUTH_CMD:-}" ] && bash -c "$TRUTH_CMD" > "$OUT/$id.truth.json" 2>/dev/null
done
echo "ROUND $(basename "$OUT") DONE"
