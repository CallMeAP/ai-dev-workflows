#!/usr/bin/env bash
# The Codex stop for the node suites (ui, latency): exit 0 = go, 3 = stop. Same rule as lib.sh quota_guard.
# Usage: SELFTEST_ENV=<file> bash quota-guard.sh
. "$(dirname "$0")/lib.sh"
quota_guard >&2 || exit 3
