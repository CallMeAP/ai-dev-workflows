#!/usr/bin/env bash
# Force a new BPP.Shared.NET package: one-line commit to .release-trigger on bpp-shared development
# (GitLab API commit, no local checkout touched), then wait until the package of that commit is published.
# Usage: release.sh "<reason>"
# Prints "PUBLISHED <version>" on success; non-zero exit on failure.
set -u
PROJ="lipso%2Fclients%2Fbrokernet%2Fbpp-shared"
FILE=".release-trigger"
REASON="${1:-forced package release}"
WAIT_SECONDS="${WAIT_SECONDS:-1500}"

glab auth status >/dev/null 2>&1 || { echo "FAIL glab not authenticated" >&2; exit 1; }

# (1) create or update the trigger file — one line, so the commit is a pure release trigger
if glab api "/projects/$PROJ/repository/files/$FILE?ref=development" >/dev/null 2>&1; then ACTION=update; else ACTION=create; fi
LINE="Forced package release $(date -u +%Y-%m-%dT%H:%M:%SZ): ${REASON}"
COMMIT=$(jq -n --arg a "$ACTION" --arg f "$FILE" --arg c "$LINE" \
  --arg m "chore(release): force BPP.Shared.NET package (${REASON})" \
  '{branch:"development", commit_message:$m, actions:[{action:$a, file_path:$f, content:($c+"\n")}]}' \
  | glab api --method POST "/projects/$PROJ/repository/commits" -H 'Content-Type: application/json' --input - \
  | jq -r '.id // empty')
[ -n "$COMMIT" ] || { echo "FAIL api commit" >&2; exit 1; }
SHORT=${COMMIT:0:8}
echo "COMMIT $SHORT ($ACTION $FILE)"

# (2) wait for the publish of exactly this commit (version ends with +<short sha>)
END=$(( $(date +%s) + WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$END" ]; do
  V=$(glab api "/projects/$PROJ/packages?package_name=BPP.Shared.NET&order_by=created_at&sort=desc&per_page=5" 2>/dev/null \
      | jq -r --arg s "+$SHORT" '[.[] | select(.version | endswith($s))][0].version // empty')
  [ -n "$V" ] && { echo "PUBLISHED $V"; exit 0; }
  ST=$(glab api "/projects/$PROJ/pipelines?sha=$COMMIT&ref=development&per_page=1" 2>/dev/null | jq -r '.[0].status // "none"')
  case "$ST" in
    failed|canceled)
      PL=$(glab api "/projects/$PROJ/pipelines?sha=$COMMIT&per_page=1" | jq -r '.[0].id')
      echo "FAIL pipeline $PL $ST" >&2
      glab api "/projects/$PROJ/pipelines/$PL/jobs?per_page=100" | jq -r '.[] | select(.status=="failed") | "  \(.name) \(.web_url)"' >&2
      exit 2;;
  esac
  sleep 30
done
echo "FAIL timeout after ${WAIT_SECONDS}s (pipeline status: ${ST:-unknown})" >&2
exit 3
