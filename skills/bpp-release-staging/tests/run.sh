#!/usr/bin/env bash
# Runs every tests/test-*.sh; exits non-zero when any of them fails.
dir=$(cd "$(dirname "$0")" && pwd)
failed=0
for t in "$dir"/test-*.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t")"
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
done
if [ "$failed" -ne 0 ]; then
  echo "RESULT: $failed test file(s) failed"
  exit 1
fi
echo "RESULT: all test files passed"
