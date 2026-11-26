#!/usr/bin/env bash
# Checks SKILL.md has the sections and key strings Task 6 asks for.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
f="$here/../SKILL.md"

if [ ! -f "$f" ]; then
  _fail "SKILL.md exists"
  finish
fi
md=$(cat "$f")

assert_contains "name: bpp-release-staging" "$md" "frontmatter name"
assert_contains "description: Use when" "$md" "frontmatter trigger description"
for h in "## Overview" "## Rules" "## How to run" "## Halt + resume" "## Secrets setup" \
  "### Ubuntu VM" "### Mac mini" "## Install checklist" "## TODOs" "## StageSql convention"; do
  assert_contains "$h" "$md" "section $h"
done
for s in "permissions" '"deny"' "Read(~/.bpp-release.env)" "Bash(cat ~/.bpp-release.env*)" \
  "umask 077" "chmod 600" "-T /usr/bin/security" "dry-run" "workflow.js" "state.json" \
  "run-stage-sql.sh --readonly staging --check" "BPP_RELEASE_SECRETS" \
  "gnu-sed" "coreutils" "auto-login" "Maintainer" "cron" "Henry"; do
  assert_contains "$s" "$md" "mentions $s"
done
assert_not_contains "$HOME/" "$md" "no hard-coded home path"
# resume, dry-run scope, lint command, StageSql per stage
for s in "starts again at phase 0" "no jump to the halted phase" "has-sql" \
  "still does local git updates" "shellcheck -x" "lists \`development\`" \
  "outside bpp-backend"; do
  assert_contains "$s" "$md" "mentions $s"
done
assert_not_contains "resumes from the halted phase" "$md" "no jump-to-phase resume"
# skill update switch: VM sets it off in ~/.claude/settings.json env, Mac mini keeps on
for s in "BPP_RELEASE_SKILL_UPDATE" "on|off|report" "unsynced local edits" \
  "Mac mini keeps \`on\`" "skill update off"; do
  assert_contains "$s" "$md" "mentions $s"
done
assert_not_contains "export BPP_RELEASE_SKILL_UPDATE=off" "$md" "switch is not set via a .bashrc export"
vm=$(printf '%s\n' "$md" | awk '/^### Ubuntu VM/{on=1;next} /^### /{on=0} on')
assert_contains "7. " "$vm" "Ubuntu VM setup has a step 7"
assert_contains "~/.claude/settings.json" "$vm" "Ubuntu VM setup names settings.json"
assert_contains '"BPP_RELEASE_SKILL_UPDATE": "off"' "$vm" "Ubuntu VM setup sets the switch off in env"
assert_contains "Merge it into the existing file" "$vm" "Ubuntu VM setup merges into the existing settings file"
assert_contains 'echo "${BPP_RELEASE_SKILL_UPDATE:-on}"' "$vm" "Ubuntu VM setup keeps the new-session check"
spec="$HOME/Entwicklung/ai-dev-workflows/docs/superpowers/specs/2026-11-26-bpp-release-design.md"
if [ -f "$spec" ]; then
  sp=$(cat "$spec")
  for s in "starts again at phase 0" "still does local git updates" "add-sql" "outside bpp-backend" \
    "lists \`development\`"; do
    assert_contains "$s" "$sp" "spec mentions $s"
  done
  assert_not_contains "resumes from that phase" "$sp" "spec: no jump-to-phase resume"
  row=$(printf '%s\n' "$sp" | grep '^| Skill updates |')
  assert_contains "BPP_RELEASE_SKILL_UPDATE" "$row" "spec: Skill updates row names the switch"
  assert_contains "report" "$row" "spec: Skill updates row names report mode"
  assert_contains "settings.json" "$row" "spec: Skill updates row names settings.json"
  assert_not_contains ".bashrc" "$row" "spec: Skill updates row has no .bashrc export"
  p0=$(printf '%s\n' "$sp" | grep '^0\. \*\*Skill update\*\*')
  assert_contains "BPP_RELEASE_SKILL_UPDATE" "$p0" "spec: phase 0 line names the switch"
  assert_contains "on|off|report" "$p0" "spec: phase 0 line names the modes"
fi
finish
