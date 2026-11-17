#!/usr/bin/env bash
# One mail case: a synthetic mail through the connector's developer test-mail form (real mailbox sync stays OFF) into the owner's
# mailbox, then the agent's mail loop over the private RabbitMQ. Waits up to 15 min for a terminal job state, then stores the job,
# its turns and messages (read-only) as <out>/<id>.json.
# Every mail gets its own subject "mp-<run>-<id> <subject>": synthetic test mails must never share a thread (a shared thread
# turns the second mail into a follow-up and the case measures the wrong thing). The subject prefix mp- is what the agent's
# Mail__DevSubjectPrefix accepts.
# Usage: SELFTEST_ENV=<file> JAR=<cookie-jar> bash mail-case.sh <case.json> <out-dir>
set -u
. "$(dirname "$0")/lib.sh"
: "${JAR:?set JAR}"
CASE=$1; OUT=$2; RUN=${SELFTEST_RUN_ID:-run}
ID=$(jq -r .id "$CASE")
FROM=$(jq -r .from "$CASE"); FROMNAME=$(jq -r .fromName "$CASE")
SUBJ="mp-$RUN-$ID $(jq -r .subject "$CASE" | sed "s/{{RUN}}/$RUN/g")"; BODY=$(jq -r .body "$CASE" | sed "s/{{RUN}}/$RUN/g")
curl -s -b "$JAR" -X POST "$CONNECTOR_URL/api/external-mail-dashboard-synthetic-mail" --form-string "FromAddress=$FROM" \
  --form-string "FromName=$FROMNAME" --form-string "Subject=$SUBJ" --form-string "Body=$BODY" > "$OUT/$ID.send.json"
MID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$OUT/$ID.send.json" | head -1)
if [ -z "$MID" ]; then jq -n --arg id "$ID" --arg e "$(head -c 300 "$OUT/$ID.send.json")" '{id:$id,channel:"mail",error:("no mail id: "+$e)}' > "$OUT/$ID.json"; exit 4; fi
st=; for _ in $(seq 1 90); do
  st=$(pgr -Atc "select state from agent_job where third_party_sync_link_id='$MID' order by created_at desc limit 1" | tail -1)
  case "$st" in needs_attention|completed|dismissed|rejected|awaiting_approval|failed) break ;; esac
  timeout 10 tail -f /dev/null
done
echo "mail $MID state=${st:-none}"
job=$(pgr -Atc "select coalesce(json_agg(json_build_object('id',j.id,'state',j.state,'reason',j.reason_code,'eval',j.eval_result,'toolsets',j.selected_toolsets,
  'summary',j.summary,'tools_used',j.tool_calls_used,'thread',j.thread_key,
  'turns',(select coalesce(json_agg(json_build_object('id',t.id,'created',t.created_at,'kind',t.turn_kind,'status',t.status,'provider',t.provider,'model',t.model,'err',t.error_code,
     'finish',t.finish_reason,'tools',t.tool_call_log) order by t.created_at),'[]') from agent_turn t where t.job_id=j.id or t.id=j.current_turn_id),
  'pending',(select coalesce(json_agg(json_build_object('id',p.id,'status',p.status,'verb',p.verb,'path',p.path_template,'customer',p.customer_id)),'[]')
     from agent_pending_action p where p.job_id=j.id),
  'messages',(select coalesce(json_agg(json_build_object('role',m.role,'kind',m.content_kind,'content',left(m.content,3000)) order by m.created_at),'[]')
     from agent_message m join agent_turn t on t.id=m.turn_id where t.job_id=j.id))),'[]') from agent_job j where j.third_party_sync_link_id='$MID'" 2>&1 | tail -1)
jq -n --arg id "$ID" --arg mid "$MID" --arg st "${st:-none}" --arg subj "$SUBJ" --argjson job "${job:-[]}" \
  '{id:$id, channel:"mail", mailId:$mid, subject:$subj, state:$st, jobs:$job}' > "$OUT/$ID.json" 2>/dev/null \
  || jq -n --arg id "$ID" --arg mid "$MID" --arg st "${st:-none}" --arg raw "$job" '{id:$id, channel:"mail", mailId:$mid, state:$st, raw:$raw}' > "$OUT/$ID.json"
