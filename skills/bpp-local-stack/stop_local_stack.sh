#!/usr/bin/env bash
# Stop the local BPP service stack. Thin wrapper around `start_local_stack.sh stop`
# so the SERVICES registry stays single-sourced.
#
# Usage:
#   ./stop_local_stack.sh

set -euo pipefail

exec "$(dirname "$0")/start_local_stack.sh" stop
