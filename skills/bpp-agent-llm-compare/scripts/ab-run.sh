#!/usr/bin/env bash
# Runs the cases of one set (tune/ or heldback/ from split.py) on the given arms through the main skill's run-round.sh, then its
# score.py (hard checks) per arm and suite. Output: <out>/<arm>/<suite>/ exactly as the main skill writes it.
#   pref mode (challenger in the llamacpp slot): both arms in one call, interleaved per case (A,B then B,A) by switching the
#     developer's provider choice (PUT /api/llm-provider-preference); the earlier choice is restored on exit.
#   restart mode: one arm per call, on the agent challenger.sh left running (up = challenger, down = luna); the arm is checked
#     against the provider new sessions start on.
# Stops: exit 3 at the Codex stop (from run-round.sh's quota guard), exit 4 when a hosted challenger's estimated spend of this run
# reaches BUDGET_USD (agent_turn tokens x list price; the Console spend limit stays the hard backstop). Rerun the same command to
# resume: finished cases are skipped.
# Every arm gets its own SELFTEST_RUN_ID "<COMPARE_RUN>-<arm>", so the two arms' synthetic mails never share a thread.
# Usage: SELFTEST_ENV=<f> COMPARE_ENV=<f> JAR=<jar> COMPARE_RUN=<run-id> bash ab-run.sh <set-dir> <out> luna challenger
set -u
SELFTEST_SKILL=${SELFTEST_SKILL:-$HOME/.claude/skills/bpp-agent-llm-selftest}
. "$SELFTEST_SKILL/scripts/lib.sh"
: "${COMPARE_ENV:?}"; . "$COMPARE_ENV"; : "${JAR:?}"; : "${COMPARE_RUN:?set COMPARE_RUN (e.g. 20261118-0900-i0)}"
SET=$1; OUT=$2; shift 2; ARMS=("$@"); [ ${#ARMS[@]} -gt 0 ] || ARMS=(luna challenger)
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=$(bash "$HERE/challenger.sh" mode)
mkdir -p "$OUT"; [ -s "$OUT/.start" ] || date -u +%FT%TZ > "$OUT/.start"
prov() { [ "$1" = luna ] && echo "$LUNA_PROVIDER" || echo "$CHALLENGER_PROVIDER"; }
cur() { curl -s -b "$JAR" --max-time 10 "$AGENT_URL/api/llm-provider-preference" | jq -r '.provider // empty'; }
put() { curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X PUT -H 'content-type: application/json' --max-time 10 \
          -d "$(jq -nc --arg p "$1" '{provider:$p}')" "$AGENT_URL/api/llm-provider-preference"; }
budget_ok() {
  [ "$CHALLENGER_KIND" = hosted ] || return 0
  local t; t=$(pgr -Atc "select coalesce(sum(input_tokens),0)||' '||coalesce(sum(output_tokens),0) from agent_turn
                          where provider='$CHALLENGER_PROVIDER' and created_at >= '$(cat "$OUT/.start")'" | tail -1)
  local usd; usd=$(awk -v t="$t" -v i="$PRICE_IN_PER_M_USD" -v o="$PRICE_OUT_PER_M_USD" 'BEGIN{split(t,a," "); printf "%.4f", a[1]/1e6*i + a[2]/1e6*o}')
  echo "$usd" > "$OUT/.spend-usd"
  awk "BEGIN{exit !($usd < $BUDGET_USD)}" || { echo "BUDGET STOP: estimate $usd USD >= $BUDGET_USD USD" >&2; return 1; }
}
if [ "$MODE" = pref ]; then
  BEFORE=$(cur); trap '[ -n "$BEFORE" ] && put "$BEFORE" >/dev/null' EXIT
else
  [ ${#ARMS[@]} -eq 1 ] || { echo "restart mode: one arm per call (challenger.sh up -> challenger, down -> luna)" >&2; exit 2; }
  [ "$(cur)" = "$(prov "${ARMS[0]}")" ] || { echo "REFUSING: new sessions start on '$(cur)', not on arm ${ARMS[0]} ($(prov "${ARMS[0]}"))" >&2; exit 6; }
fi
k=0
for f in "$SET"/*.json; do
  suite=$(basename "$f" .json)
  for id in $(jq -r '.[].id' "$f"); do
    k=$((k + 1)); order=("${ARMS[@]}"); [ $((k % 2)) -eq 0 ] && [ ${#ARMS[@]} -eq 2 ] && order=("${ARMS[1]}" "${ARMS[0]}")
    for arm in "${order[@]}"; do
      [ -s "$OUT/$arm/$suite/$id.json" ] && continue
      [ "$arm" = challenger ] && { budget_ok || exit 4; }
      if [ "$MODE" = pref ]; then
        code=$(put "$(prov "$arm")"); [ "$code" = 200 ] || { echo "provider switch to $(prov "$arm") failed: HTTP $code" >&2; exit 5; }
      fi
      SELFTEST_RUN_ID="$COMPARE_RUN-$arm" bash "$SELFTEST_SKILL/scripts/run-round.sh" "$f" "$OUT/$arm/$suite" "$id"
      rc=$?; [ $rc -eq 3 ] && { echo "QUOTA STOP (Codex 95/95): rerun after the reset"; exit 3; }
    done
  done
done
for arm in "${ARMS[@]}"; do
  for d in "$OUT/$arm"/*/; do [ -d "$d" ] && SELFTEST_RUN_ID="$COMPARE_RUN-$arm" python3 -I "$SELFTEST_SKILL/scripts/score.py" "$d" | tail -1 | sed "s|^|$arm $(basename "$d"): |"; done
done
echo "AB $(basename "$SET") DONE"
