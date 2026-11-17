#!/usr/bin/env bash
# Latency suite: primes 3 chats per bucket (13h, 1h, 15m, 0s, in that order so no prime overlaps a resume), schedules each resume as
# a systemd user timer (unit selftest-latency-<run>-<bucket>), runs the 0s resume at once, and schedules the final analysis 13 h 40 min
# out. Timers survive the session; the 13 h bucket means the run's report is final only the next day.
# Usage: SELFTEST_ENV=<file> bash latency-run.sh <out-dir> [buckets, default "13h 1h 15m 0s"]
# Every prime and resume passes the Codex stop first. Inspect: systemctl --user list-timers 'selftest-latency-*'
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OUT=$(mkdir -p "$1" && cd "$1" && pwd); BUCKETS=${2:-"13h 1h 15m 0s"}; RUN=$(basename "$OUT")
declare -A GAP=([13h]=13h [1h]=60min [15m]=15min)
sched() { systemd-run --user --unit="$1" --on-active="$2" --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=SELFTEST_ENV="$SELFTEST_ENV" \
            --working-directory="$OUT" /bin/bash -c "$3 >> '$OUT/$1.log' 2>&1"; }
export LAT_DIR=$OUT
for b in $BUCKETS; do
  quota_guard || exit 3
  node "$SCRIPTS/latency.mjs" prime "$b" || continue
  if [ "$b" = 0s ]; then node "$SCRIPTS/latency.mjs" resume 0s
  else sched "selftest-latency-$RUN-$b" "${GAP[$b]}" "bash '$SCRIPTS/latency-resume.sh' '$OUT' $b"; fi
done
case " $BUCKETS " in *" 13h "*) report_at=13h40min ;; *) report_at=75min ;; esac
sched "selftest-latency-$RUN-report" "$report_at" \
  "set -a; . '$SELFTEST_ENV'; set +a; python3 -I '$SCRIPTS/latency-analyze.py' '$OUT' final"
systemctl --user list-timers "selftest-latency-$RUN-*" --no-pager
echo "$(date -u +%FT%TZ) latency-run done; interim tables: python3 -I $SCRIPTS/latency-analyze.py $OUT interim"
