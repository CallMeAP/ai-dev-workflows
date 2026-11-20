#!/usr/bin/env bash
# disk-check / report.sh — READ-ONLY disk report, one section per check, then a reclaim table.
# Never deletes, never sudo, never --force. Writes only two state lists: ~/.claude/state/disk-check-build-dirs.tsv
# (item 8, read back by apply-build.sh) and stale.sh's own ~/.claude/state/stale-worktrees.tsv. Target runtime < 3 min (bounded find depths, timeout on du).
# Verdicts: KEEP | DELETABLE (apply-cache.sh / worktree scripts after the user's go) | ON-GO (only on an explicit go)
#           | USER-SUDO (the user runs the printed command) | USER (user action, not disk) | INFO
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
WT=$HOME/.claude/skills/bpp-cleanup-merged-worktrees
BPP=${BPP_ROOT:-$HOME/Entwicklung/bpp}
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
ROWS=$TMPD/rows; : > "$ROWS"
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >> "$ROWS"; }   # item what size_MB reclaim_MB verdict
hr() { printf '\n== %s ==\n' "$*"; }
T0=$(date +%s)
# slowest check first, in the background (cleanup.sh plan queries GitLab, ~75 s)
( timeout 150 bash "$WT/cleanup.sh" plan > "$TMPD/cleanup.txt" 2>&1; echo "exit=$?" >> "$TMPD/cleanup.txt" ) &
CLPID=$!

hr "1. Free space and ext4 reserve"
df -h / /home /tmp 2>/dev/null | awk 'NR==1 || !seen[$1 $6]++'
{ findmnt -no TARGET --target /; findmnt -no TARGET --target "$HOME"; } | sort -u | while IFS= read -r MP; do
  read -r BT BF BA BS < <(stat -f -c '%b %f %a %S' "$MP")
  RES=$(( (BF - BA) * BS / 1048576 ))
  echo "Reserved for root on $MP (statfs free - avail, no sudo needed): ${RES} MB = $(awk -v r="$BF" -v a="$BA" -v t="$BT" 'BEGIN{printf "%.1f", (r-a)*100/t}')%"
  echo "-> explains 'size - used > avail'. Lowering it is optional and root-only: ! sudo tune2fs -m 1 $(findmnt -no SOURCE --target "$MP")  (keeps 1%)"
  row 1 "ext4 root reserve on $MP" "$RES" "0" "USER-SUDO optional"
done

hr "2. GNOME tracker"
TP=$(pgrep -u "$(id -u)" -f 'tracker-(miner-fs|extract)-3' | paste -sd, )
if [ -n "$TP" ]; then ps -o pid,pcpu,etime,comm -p "$TP"; else echo "not running"; fi
TS=0; for d in "$HOME/.cache/tracker3" "$HOME/.local/share/tracker3"; do
  if [ -d "$d" ]; then s=$(mb "$d"); echo "$s MB  $d"; TS=$((TS + ${s/\?/0})); else echo "absent  $d"; fi; done
echo "-> CPU, not disk. User runs: tracker3 daemon --pause-miner fs   or exclude ~/Entwicklung (Settings > Search > Search Locations)"
row 2 "tracker index" "$TS" "0" "USER (CPU)"

hr "3. Cypress cache ($CY_CACHE)"
INST=$(cypress_installed); RUN=$(cypress_running); PIN=$(cypress_pinned)
echo "installed in node_modules:"; printf '%s\n' "$INST" | awk -F'\t' 'NF{print "  " $1 "  " $2}' | sed "s#$DEV_ROOT/##"
echo "used by a running process: ${RUN:-none}"
echo "pinned in package-lock.json (by version, count): $(printf '%s\n' "$PIN" | awk -F'\t' 'NF{c[$1]++} END{for(k in c) printf "%s x%d  ", k, c[k]}')"
CYR=0
if [ -d "$CY_CACHE" ]; then for d in "$CY_CACHE"/*/; do d=${d%/}; v=$(basename "$d"); s=$(mb "$d")
  IFS=$'\t' read -r verdict why < <(cypress_verdict "$v" "$INST" "$RUN" "$PIN")
  printf '  %-10s %6s MB  %-9s %s\n' "$v" "$s" "$verdict" "$why"
  [ "$verdict" = DELETABLE ] && { CYR=$((CYR + ${s/\?/0})); row 3 "$d" "$s" "$s" DELETABLE; }
done; else echo "absent"; fi
echo "-> a checkout without node_modules re-downloads its pinned version on the next npm ci (see CAVEAT)"

hr "4. Claude session scratch ($SCRATCH_ROOT)"
OPEN=$(scratch_open_sessions)
echo "current session: ${CLAUDE_CODE_SESSION_ID:-unknown (not run from Claude)}; sessions with open fds: $(printf '%s' "$OPEN" | paste -sd' ' | grep . || echo none)"
for d in "$SCRATCH_ROOT"/*/ "$SCRATCH_ROOT"/*/*/; do d=${d%/}; [ -d "$d" ] || continue
  case "$d" in */scratchpad|*/tasks|*/bash-edit-diff/*) continue;; esac
  base=$(basename "$d")
  # a project dir holds session dirs: judge those, not the project dir itself
  printf '%s' "$base" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-' || printf '%s' "$base" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || continue
  s=$(mb "$d" 30)
  IFS=$'\t' read -r verdict why < <(scratch_verdict "$d" "$OPEN")
  printf '  %6s MB  %-9s %s  (%s)\n' "$s" "$verdict" "${d#$SCRATCH_ROOT/}" "$why"
  [ "$verdict" = DELETABLE ] && row 4 "$d" "$s" "$s" DELETABLE
done

hr "5. systemd journal"
J=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1); echo "${J:-unknown}"
JM=$(printf '%s' "$J" | awk '/G$/{printf "%d", $0*1024} /M$/{printf "%d", $0} /K$/{print 0}')
echo "-> user runs: ! sudo journalctl --vacuum-size=1G"
row 5 "journal" "${JM:-?}" "$(( ${JM:-0} > 1024 ? ${JM:-0} - 1024 : 0 ))" USER-SUDO

hr "6. Caches: ~/.nuget, ~/.cache, ~/.claude, docker"
NG=$(mb "$HOME/.nuget/packages" 60); echo "$NG MB  ~/.nuget/packages ($(ls "$HOME/.nuget/packages" 2>/dev/null | wc -l) packages); largest:"
timeout 60 du -smx "$HOME/.nuget/packages"/* 2>/dev/null | sort -rn | head -5 | sed 's#^#    #'
echo "  -> ON-GO: dotnet nuget locals global-packages --clear (next builds re-download everything)"
row 6 "~/.nuget/packages" "$NG" "$NG" ON-GO
echo "~/.cache top entries (MB):"; timeout 60 du -smx "$HOME/.cache"/* 2>/dev/null | sort -rn | head -10 > "$TMPD/cache"; sed 's#^#    #' "$TMPD/cache"
# big caches with no verdict of their own: listed as INFO so they show in the SUMMARY (Cypress and tracker have their own items)
awk -F'\t' '$1>=500' "$TMPD/cache" | while IFS=$'\t' read -r s p; do case "$p" in "$CY_CACHE"|*/tracker3) continue;; esac
  row 6 "$p" "$s" 0 "INFO (owner tool decides)"; done
CL=$(mb "$HOME/.claude" 60); echo "$CL MB  ~/.claude; projects (session jsonl) per project, top 5:"
timeout 60 du -smx "$HOME/.claude/projects"/* 2>/dev/null | sort -rn | head -5 | sed 's#^#    #'
OLD=$(find "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl' -mtime +30 -printf '%s\n' 2>/dev/null | awk '{s+=$1;n++} END{printf "%d files, %d MB", n, s/1048576}')
echo "  jsonl older than 30 d: $OLD  -> KEEP (session history, needed for --resume; never proposed)"
echo "  plugins cache: $(mb "$HOME/.claude/plugins/cache") MB"
row 6 "~/.claude" "$CL" 0 KEEP
if command -v docker >/dev/null; then timeout 20 docker system df 2>&1; echo "  -> ON-GO: docker system prune (user decides)"; else echo "docker: not installed"; fi

wait "$CLPID" 2>/dev/null
hr "7. BPP worktrees (bpp-cleanup-merged-worktrees, plan only)"
echo "Worktree trees by repo (MB, top 8):"
timeout 60 du -smx "$BPP"/*.worktrees "$BPP"/.wt-* 2>/dev/null | sort -rn | head -8 | sed "s#$BPP/##; s#^#    #"
echo "-- cleanup.sh plan (merged):"; grep -E '^(REMOVE|LANDED|REMOVE-AFTER)' "$TMPD/cleanup.txt" | cut -c1-160 | sed 's#^#    #'
grep -E '^SUMMARY|^exit=' "$TMPD/cleanup.txt"
grep -q '^exit=124' "$TMPD/cleanup.txt" && echo "    cleanup.sh timed out after 150 s - rerun it alone"
MS=0; for p in $(grep -E '^(REMOVE|LANDED|REMOVE-AFTER-SCAFFOLD) ' "$TMPD/cleanup.txt" | awk '{print $2}' | sed "s#^\.\.\./#$BPP/#"); do
  s=$(mb "$p"); MS=$((MS + ${s/\?/0})); done
row 7 "merged worktrees (cleanup.sh apply <path>...)" "$MS" "$MS" DELETABLE
echo "-- stale.sh plan --days 7 (idle, clean, pushed; branches kept):"
timeout 60 bash "$WT/stale.sh" plan --days 7 --exclude bpp-document-analysis 2>&1 | grep -v '^Candidate list' | sed 's#^#    #'
SS=$(awk -F'\t' '{s+=$4} END{print s+0}' "$HOME/.claude/state/stale-worktrees.tsv" 2>/dev/null)
row 7 "stale worktrees (stale.sh apply <path>...)" "$SS" "$SS" DELETABLE
echo "  -> apply only with explicit approved paths, never the \$(cut ...) blanket form"

hr "8. Build output in idle worktrees (idle = no source file changed in 7 d; size only)"
STAMP=$TMPD/stamp; touch -d '-7 days' "$STAMP"; BO=$TMPD/build; : > "$BO"
for g in "$BPP"/*/.git; do [ -d "$g" ] || continue; r=$(dirname "$g")
  printf '%s' "$r" | grep -qE "$NO_TOUCH_RE" && continue
  git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' | tail -n +2 | while IFS= read -r W; do
    [ -d "$W" ] || continue; printf '%s' "$W" | grep -qE "$NO_TOUCH_RE" && continue
    [ $(( $(date +%s) - T0 )) -gt 160 ] && { echo "TIME" > "$TMPD/timeout8"; break; }
    worktree_idle "$W" "$STAMP"; rc=$?
    [ $rc = 2 ] && { echo "  skipped (find timed out, idle unknown): ${W#$BPP/}"; continue; }
    [ $rc = 1 ] && continue
    find "$W" -maxdepth 5 \( -name node_modules -o -name bin -o -name obj -o -name .angular -o -name dist \) -type d -prune -print 2>/dev/null |
    while IFS= read -r b; do [ -n "$(git -C "$W" ls-files -- "${b#$W/}" 2>/dev/null | head -1)" ] && continue   # tracked => not build output
      printf '%s\t%s\t%s\n' "$(mb "$b" 20)" "$b" "$W"; done >> "$BO"
  done
done
[ -f "$TMPD/timeout8" ] && echo "(stopped early at the time budget - totals are a lower bound)"
awk -F'\t' '{split($2,a,"/"); n=a[length(a)]; s[n]+=$1; t+=$1} END{for(k in s) printf "  %-14s %7d MB\n", k, s[k]; printf "  TOTAL          %7d MB in %d dirs\n", t, NR}' "$BO"
echo "Largest 10:"; sort -rn "$BO" | head -10 | cut -f1,2 | sed "s#$BPP/##; s#^#    #"
B8=$(awk -F'\t' '{t+=$1} END{print t+0}' "$BO"); cp "$BO" "${DISK_CHECK_BUILD_LIST:-$HOME/.claude/state/disk-check-build-dirs.tsv}" 2>/dev/null
echo "  -> list saved to ${DISK_CHECK_BUILD_LIST:-$HOME/.claude/state/disk-check-build-dirs.tsv}; ON-GO only"
row 8 "build output in idle worktrees" "$B8" "$B8" ON-GO

hr "SUMMARY (MB; reclaim = what the verdict frees)"
printf '%-4s %-48s %9s %9s  %s\n' item what size reclaim verdict
awk -F'\t' '{w=$2; if (length(w)>48) w="..." substr(w, length(w)-44); printf "%-4s %-48s %9s %9s  %s\n", $1, w, $3, $4, $5}' "$ROWS"
awk -F'\t' '$5=="DELETABLE"{d+=$4} $5 ~ /^USER-SUDO$/{u+=$4} $5=="ON-GO"{o+=$4} END{printf "\nDELETABLE now: %.1f GB | USER-SUDO: %.1f GB | ON-GO (bigger, costs rebuilds/downloads): %.1f GB\n", d/1024, u/1024, o/1024}' "$ROWS"
echo "runtime: $(( $(date +%s) - T0 )) s"
