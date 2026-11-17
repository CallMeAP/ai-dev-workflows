#!/usr/bin/env bash
# One scheduled resume of a latency bucket (run by a systemd user timer): Codex stop, agent ready, Codex link, then latency.mjs resume.
# A skipped resume is recorded in results.jsonl, so the report shows it instead of a silent gap.
# Usage: SELFTEST_ENV=<file> bash latency-resume.sh <out-dir> <bucket>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
export LAT_DIR=$1; B=$2
skip() { echo "{\"bucket\":\"$B\",\"phase\":\"resume\",\"skipped\":\"$1\"}" >> "$LAT_DIR/results.jsonl"; echo "skip: $1"; exit "$2"; }
quota_guard || skip "codex quota stop" 3
curl -fsS -o /dev/null --max-time 10 "$AGENT_URL/health/ready" || skip "agent not ready" 4
J=$(mktemp); trap 'rm -f "$J"' EXIT
login "$J" || skip "login failed" 4
codex_linked "$J" || skip "codex link (not linked or relink required)" 4
node "$SCRIPTS/latency.mjs" resume "$B"
