#!/usr/bin/env bash
# Ground truth for the custscope fixtures (own_total, g1_total, ...): one read-only query on the demo DB. TRUTH_CMD for run-round.sh.
# Usage: SELFTEST_ENV=<file> bash custscope-truth.sh
set -u
. "$(dirname "$0")/lib.sh"
: "${OWNER_GO_USER_ID:?set OWNER_GO_USER_ID}"
pgr -v owner="$OWNER_GO_USER_ID" -Atf "$SKILL_DIR/seeds/custscope-truth.sql" | tail -1
