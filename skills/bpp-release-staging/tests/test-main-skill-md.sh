#!/usr/bin/env bash
# Checks the shape of bpp-release-main/SKILL.md: 11 steps in order, go per step, no DB write scripts.
# shellcheck disable=SC1091
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
F="$here/../../bpp-release-main/SKILL.md"

if [ ! -f "$F" ]; then
  _fail "bpp-release-main/SKILL.md exists"
  finish
fi
_pass "bpp-release-main/SKILL.md exists"
TEXT=$(cat "$F")

assert_eq "---" "$(head -1 "$F")" "frontmatter starts on line 1"
assert_contains "name: bpp-release-main" "$TEXT" "frontmatter name"
assert_contains "description: Use when" "$TEXT" "trigger description"

# Step headings 1..11, each once, in order
prev=0
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  count=$(grep -c "^### Step $n[.:] " "$F")
  assert_eq "1" "$count" "step $n heading present once"
  line=$(grep -n "^### Step $n[.:] " "$F" | head -1 | cut -d: -f1)
  if [ -n "$line" ] && [ "$line" -gt "$prev" ]; then _pass "step $n after step $((n - 1))"; else _fail "step $n after step $((n - 1))"; fi
  prev=${line:-$prev}
done
assert_eq "0" "$(grep -c '^### Step 12' "$F")" "no step 12"

assert_contains "bpp-checkout-shared-at-stage" "$TEXT" "uses bpp-checkout-shared-at-stage"
assert_contains "restore mode" "$TEXT" "restores bpp-shared"
assert_contains "AskUserQuestion" "$TEXT" "go per step via AskUserQuestion"
assert_contains "bpp-promote-dev-to-staging" "$TEXT" "uses the promote skill"
assert_contains "bpp-go-health" "$TEXT" "checks health"
assert_contains "ui_configs" "$TEXT" "prints ui_configs SQL"
assert_contains "pgAdmin" "$TEXT" "user runs SQL in pgAdmin"
assert_contains "henry-ping.sh" "$TEXT" "prints the Henry ping"
assert_contains "should_remove_source_branch=false" "$TEXT" "merge keeps the source branch"

assert_not_contains "migrate-stage.sh" "$TEXT" "never calls migrate-stage.sh"
assert_not_contains "run-stage-sql.sh" "$TEXT" "never calls run-stage-sql.sh"
assert_not_contains "$HOME/" "$TEXT" "no literal home path"
assert_eq "0" "$(grep -c 'dotnet run' "$F")" "never runs DbMigrator itself"

finish
