#!/usr/bin/env bash
# Model-switch suite (Luna -> Astra by default). Two mechanisms, picked from the agent's swagger:
#   session  the build has PATCH /api/agent-session/{id}/provider (mid-session switch with handover): cases/model-switch.json runs as is
#            (facts in turns 1-2, switch, turn 3 must recall them); agent_turn.model proves which model answered.
#   restart  no mid-session switch: the Codex model is agent config (Llm__Codex__Model). The agent is restarted on the target model,
#            the read cases run, and a trap restarts it on the default model. GLOBAL SWITCH: nothing else may run meanwhile.
# Haiku/Claude: only with an Anthropic Console API key with a spend limit in the agent config, never a subscription OAuth token.
# Usage: SELFTEST_ENV=<file> JAR=<jar> bash model-switch.sh <out-dir> [to-model, default gpt-6-astra]
set -u
. "$(dirname "$0")/lib.sh"
: "${JAR:?set JAR}"
OUT=$1; TO=${2:-gpt-6-astra}; mkdir -p "$OUT"
if curl -s --max-time 10 "$AGENT_URL/api-doc/v1/swagger.json" | jq -e '.paths["/api/agent-session/{sessionId}/provider"].patch' >/dev/null 2>&1; then
  echo "mode session -> $TO"
  jq --arg m "$TO" 'map(.followUps |= map(if .switchTo then .switchTo.model = $m else . end))' "$SKILL_DIR/cases/model-switch.json" > "$OUT/cases.json"
  bash "$SCRIPTS/run-round.sh" "$OUT/cases.json" "$OUT"
else
  echo "mode restart -> $TO (global: run alone)"
  no_latency_timers || exit 6
  : "${DEMO_HOME:?}"; [ -x "$DEMO_HOME/start.sh" ] || { echo "no $DEMO_HOME/start.sh" >&2; exit 6; }
  wait_ready() { for _ in $(seq 1 60); do curl -fsS -o /dev/null --max-time 5 "$AGENT_URL/health/ready" && return 0; timeout 5 tail -f /dev/null; done; return 1; }
  restore() { "$DEMO_HOME/stop.sh" agent; timeout 30 tail -f /dev/null; "$DEMO_HOME/start.sh" agent; wait_ready && echo "restored default model"; }
  trap restore EXIT
  "$DEMO_HOME/stop.sh" agent; timeout 30 tail -f /dev/null
  Llm__Codex__Model=$TO "$DEMO_HOME/start.sh" agent
  wait_ready || { echo "agent not ready on $TO" >&2; exit 5; }
  jq 'map(select(.id | startswith("ms-read")))' "$SKILL_DIR/cases/model-switch.json" > "$OUT/cases.json"
  bash "$SCRIPTS/run-round.sh" "$OUT/cases.json" "$OUT"
fi
# which model answered each turn (agent_turn, read-only)
for f in "$OUT"/*.turns.json; do [ -f "$f" ] && jq -r --arg id "$(basename "$f" .turns.json)" '.[] | "\($id) \(.provider) \(.model) \(.status)"' "$f"; done
