#!/usr/bin/env bash
# bpp-project-index — MODE:
#   (none)                 refresh, then index
#   refresh                steps 1-5: rebuild ~/.claude/bpp-fleet/manifest.tsv (read-only glab), print deltas
#   report                 step 5 only: deltas + renames from the existing manifest (offline)
#   index                  step 6: rewrite the AUTO:GITLAB-ONLY block of project_index.md only on a real change
#   candidates promote|audit|bump   consumer filter → name TAB enc (offline)
#   reposmd-diff           --write preview: unlisted active repos with a PROPOSED class, plus renamed repos.md rows
#   clone-preview          --clone preview: fleet repos with no checkout (MAX_CLONE, default 10)
#   clone <name>...        clone exactly the named repos from the preview set (only after the user's go)
# Kept beside SKILL.md, not inlined: skill args substitute dollar-digit placeholders in SKILL.md text.
set -uo pipefail

MANIFEST_DIR=~/.claude/bpp-fleet
MANIFEST="$MANIFEST_DIR/manifest.tsv"
INDEX="$HOME"/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md
DEV_ROOT="$HOME/Entwicklung/bpp"
GROUP=lipso%2Fclients%2Fbrokernet
KNOW=lipso%2Finternal%2Fagentic-coding-knowledge
# EOL repos: archived for good, never listed again even if a stray checkout or repos.md row resurfaces.
# Add a repo here only on the user's word.
EOL='lipso/clients/brokernet/bpp-message-dispatcher'   # EOL + archived, local checkout removed 2026-11-03

# ── helpers ───────────────────────────────────────────────────────────────────
policy_tags() {
  case "$1" in
    servo-backend)                 echo excluded-manual ;;
    bpp-audit-reports)             echo generated-output ;;
    bpp-endpoint-migration-guides) echo guides-store ;;
    bpp-shared-template)           echo scaffold ;;
    bpp-shared)                    echo shared-source ;;
    *)                             echo - ;;
  esac
}

url_to_path() { printf '%s' "$1" | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^ssh://[^@]*@?[^/]+/##; s#^https?://([^@/]+@)?[^/]+/##'; }

rows() { awk -F'\t' '!/^#/' "$MANIFEST"; }

# Build the manifest into $MANIFEST (never over a good one on a degraded listing). Prints the deltas.
do_refresh() {
  mkdir -p "$MANIFEST_DIR"
  local WORK; WORK=$(mktemp -d)
  local GITLAB_STATE=ok REPOSMD_STATE=ok

  # 1. GitLab listing — include_subgroups and archived=false are both mandatory
  glab api "/groups/${GROUP}/projects?include_subgroups=true&archived=false&per_page=100&simple=true" --paginate 2>/dev/null \
    | jq -r '.[] | [.path, .path_with_namespace, (.default_branch // "-")] | @tsv' \
    | LC_ALL=C sort -u > "$WORK/gitlab.tsv"
  [ -s "$WORK/gitlab.tsv" ] || GITLAB_STATE=unreachable

  # 2. repos.md — class comes from the section heading a row sits under
  glab api "projects/${KNOW}/repository/files/bpp%2Frepos.md/raw?ref=main" > "$WORK/repos.md" 2>/dev/null
  awk '
    /^##[ ]/ { sect = substr($0, 4); next }
    /^\|[^|]+\| *https:\/\/gitlab\.com\// {
      split($0, f, "|"); name = f[2]; link = f[3]
      gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", link)
      sub(/^https:\/\/gitlab\.com\//, "", link)
      cls = "other"
      if (sect ~ /^Backend/)       cls = "backend"
      else if (sect ~ /^Frontend/) cls = "frontend"
      else if (sect ~ /^Dokument/) cls = "docs"
      else if (sect ~ /^Infra/)    cls = "infra"
      print name "\t" link "\t" cls
    }' "$WORK/repos.md" | LC_ALL=C sort -u > "$WORK/reposmd.tsv"
  [ -s "$WORK/reposmd.tsv" ] || REPOSMD_STATE=unreachable

  # 3. Local checkouts — keyed on the ORIGIN URL, never on the folder name
  : > "$WORK/local.tsv"
  local d n u p
  for d in "$DEV_ROOT"/*/; do
    n=$(basename "$d"); case "$n" in *.worktrees) continue;; esac
    [ -e "$d/.git" ] || continue
    u=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
    [ -n "$u" ] || continue
    p=$(url_to_path "$u")
    printf '%s\t%s\t%s\n' "$p" "${d%/}" "$n" >> "$WORK/local.tsv"
  done
  LC_ALL=C sort -o "$WORK/local.tsv" "$WORK/local.tsv"

  # 4a. Raw union minus EOL
  { cut -f2 "$WORK/gitlab.tsv"; cut -f2 "$WORK/reposmd.tsv"; cut -f1 "$WORK/local.tsv"; } \
    | LC_ALL=C sort -u | grep -vxF "$EOL" > "$WORK/union.raw"

  # 4b. Probe every path not in the live listing: archived, gone, or RENAMED (the probe follows the
  #     redirect and returns a different path_with_namespace). Renames are folded onto the new path.
  : > "$WORK/probe.tsv"; : > "$WORK/renames.tsv"
  local pathns enc meta st br real
  if [ "$GITLAB_STATE" = ok ]; then
    while read -r pathns; do
      awk -F'\t' -v p="$pathns" '$2==p {f=1} END {exit !f}' "$WORK/gitlab.tsv" && continue
      enc=$(printf %s "$pathns" | sed 's#/#%2F#g')
      meta=$(glab api "/projects/${enc}" 2>/dev/null </dev/null \
        | jq -r 'if .id then [(if .archived then "archived" else "active" end), (.default_branch // "-"), .path_with_namespace] | @tsv else empty end')
      if [ -z "$meta" ]; then printf '%s\tgone\t-\n' "$pathns" >> "$WORK/probe.tsv"; continue; fi
      IFS=$'\t' read -r st br real <<<"$meta"
      if [ "$real" != "$pathns" ]; then
        printf '%s\t%s\n' "$pathns" "$real" >> "$WORK/renames.tsv"
        printf '%s\t%s\t%s\n' "$real" "$st" "$br" >> "$WORK/probe.tsv"
      else
        printf '%s\t%s\t%s\n' "$pathns" "$st" "$br" >> "$WORK/probe.tsv"
      fi
    done < "$WORK/union.raw"
  fi
  # Map old → new in the union, the repos.md class table and the local checkout table
  awk -F'\t' 'FILENAME==ARGV[1] {m[$1]=$2; next} {print (($0 in m) ? m[$0] : $0)}' \
    "$WORK/renames.tsv" "$WORK/union.raw" | LC_ALL=C sort -u | grep -vxF "$EOL" > "$WORK/union.txt"
  awk -F'\t' -v OFS='\t' 'FILENAME==ARGV[1] {m[$1]=$2; next} {if ($2 in m) $2=m[$2]; print}' \
    "$WORK/renames.tsv" "$WORK/reposmd.tsv" > "$WORK/reposmd.mapped"
  awk -F'\t' -v OFS='\t' 'FILENAME==ARGV[1] {m[$1]=$2; next} {if ($1 in m) $1=m[$1]; print}' \
    "$WORK/renames.tsv" "$WORK/local.tsv" > "$WORK/local.mapped"
  # Provenance lines: where each old path still lives (repos.md row and/or a checkout origin)
  : > "$WORK/renamed.txt"
  local old new
  while IFS=$'\t' read -r old new; do
    awk -F'\t' -v p="$old" '$2==p {f=1} END {exit !f}' "$WORK/reposmd.tsv" \
      && printf '#renamed\t%s\t%s\trepos.md\n' "$old" "$new" >> "$WORK/renamed.txt"
    awk -F'\t' -v p="$old" -v nw="$new" '$1==p {print "#renamed\t" p "\t" nw "\t" $2}' \
      "$WORK/local.tsv" >> "$WORK/renamed.txt"
  done < "$WORK/renames.tsv"

  # 4c. One row per union path
  : > "$WORK/manifest.body"; : > "$WORK/extra.txt"
  local name gl state defbr cls lp
  while read -r pathns; do
    name=${pathns##*/}
    enc=$(printf %s "$pathns" | sed 's#/#%2F#g')
    gl=$(awk -F'\t' -v p="$pathns" '$2==p {print $3; exit}' "$WORK/gitlab.tsv")
    if [ -n "$gl" ]; then state=active; defbr="$gl"
    else
      meta=$(awk -F'\t' -v p="$pathns" '$1==p {print $2 "\t" $3; exit}' "$WORK/probe.tsv")
      if [ -n "$meta" ]; then IFS=$'\t' read -r state defbr <<<"$meta"
      else state=gone; defbr="-"; fi   # only reached on a degraded listing (no probes ran)
    fi
    cls=$(awk -F'\t' -v p="$pathns" '$2==p {print $3; exit}' "$WORK/reposmd.mapped"); [ -n "$cls" ] || cls=unlisted
    # canonical checkout: prefer the folder whose basename == repo name; others become #extra
    lp=$(awk -F'\t' -v p="$pathns" -v n="$name" '$1==p && $3==n {print $2; exit}' "$WORK/local.mapped")
    [ -n "$lp" ] || lp=$(awk -F'\t' -v p="$pathns" '$1==p {print $2; exit}' "$WORK/local.mapped")
    [ -n "$lp" ] || lp="-"
    awk -F'\t' -v p="$pathns" -v c="$lp" -v n="$name" '$1==p && $2!=c {print "#extra\t" n "\t" $2}' \
      "$WORK/local.mapped" >> "$WORK/extra.txt"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$pathns" "$enc" "$cls" "$(policy_tags "$name")" "$state" "$lp" "$defbr" >> "$WORK/manifest.body"
  done < "$WORK/union.txt"

  local dupes; dupes=$(cut -f1 "$WORK/manifest.body" | LC_ALL=C sort | uniq -d)
  [ -n "$dupes" ] && echo "WARN — name collision across subgroups, consumers key on name: $dupes" >&2

  # Never overwrite a good manifest with a degraded one
  if [ "$GITLAB_STATE" = unreachable ] && [ -s "$MANIFEST" ]; then
    echo "DEGRADED — GitLab unreachable; keeping the existing manifest ($(grep -m1 '^#generated' "$MANIFEST"))" >&2
  elif [ ! -s "$WORK/manifest.body" ]; then
    echo "FAIL — built 0 rows; keeping the existing manifest (work dir kept: $WORK)" >&2; return 1
  else
    { echo "#generated $(date -Iseconds)"
      echo "#source gitlab=$GITLAB_STATE reposmd=$REPOSMD_STATE"
      cat "$WORK/extra.txt" "$WORK/renamed.txt"
      printf '#name\tpath_with_namespace\tenc\tclass\ttags\tstate\tlocal_path\tdefault_branch\n'
      LC_ALL=C sort "$WORK/manifest.body"
    } > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    echo "manifest: $(rows | wc -l) rows, gitlab=$GITLAB_STATE reposmd=$REPOSMD_STATE → $MANIFEST"
  fi
  [ "$REPOSMD_STATE" = unreachable ] && echo "WARN — class data unavailable — repos.md unreachable; every row is class=unlisted" >&2
  rm -rf "$WORK"
  do_report
}

# Step 5: the four deltas + renames, from the manifest only (offline)
do_report() {
  [ -s "$MANIFEST" ] || { echo "no manifest at $MANIFEST — run refresh" >&2; return 1; }
  grep -m1 '^#generated' "$MANIFEST"; grep -m1 '^#source' "$MANIFEST"
  echo "a) in GitLab, missing from repos.md (candidates for --write):"
  rows | awk -F'\t' '$4=="unlisted" && $6=="active" {print "  " $1 "\t" $2 "\t(" $8 ")"}'
  echo "b) fleet repo with no local checkout (candidates for --clone):"
  rows | awk -F'\t' '$7=="-" && $6=="active" && $4!~/^(infra|unlisted)$/ {print "  " $1}'
  echo "c) checked out locally but archived/gone in GitLab (informational):"
  rows | awk -F'\t' '$7!="-" && $6!="active" {print "  " $1 "\t" $6 "\t" $7}'
  echo "d) extra checkouts of the same repo:"
  grep '^#extra' "$MANIFEST" | sed 's/^/  /'
  echo "e) RENAMED — old path still referenced (update repos.md / the checkout origin):"
  local tag old new where u
  grep '^#renamed' "$MANIFEST" | while IFS=$'\t' read -r tag old new where; do
    if [ "$where" = repos.md ]; then
      echo "  renamed $old -> $new  (repos.md row still uses the old path; fix the row by hand; --write is append-only)"
    else
      u=$(git -C "$where" remote get-url origin 2>/dev/null)
      echo "  renamed $old -> $new  (checkout $where: git -C $where remote set-url origin ${u/$old/$new})"
    fi
  done
  return 0
}

# Step 6: AUTO:GITLAB-ONLY block, written only on a content change (refreshed-date line ignored)
do_index() {
  [ -s "$MANIFEST" ] || { echo "no manifest at $MANIFEST — run refresh" >&2; return 1; }
  local WORK; WORK=$(mktemp -d)
  {
    echo '<!-- BEGIN AUTO:GITLAB-ONLY — generated by bpp-project-index refresh; do not edit by hand -->'
    echo "## GitLab-only (not checked out locally) — auto-generated, refreshed $(date +%Y-%m-%d)"
    echo
    echo 'Repos in GitLab with no local checkout. Clone target: `~/Entwicklung/bpp/{name}` for every repo.'
    echo
    echo '| Repo | GitLab path | Class | Default branch |'
    echo '|---|---|---|---|'
    rows | awk -F'\t' '$7=="-" && $6=="active" {printf "| %s | `%s` | %s | %s |\n", $1, $2, $4, $8}'
    echo '<!-- END AUTO:GITLAB-ONLY -->'
  } > "$WORK/section.md"
  awk '/BEGIN AUTO:GITLAB-ONLY/{s=1} s{print} /END AUTO:GITLAB-ONLY/{s=0}' "$INDEX" > "$WORK/section.old"
  if [ ! -s "$WORK/section.old" ]; then
    echo "project_index.md has no AUTO:GITLAB-ONLY markers — not touched" >&2
  elif diff -q <(grep -v 'refreshed 20' "$WORK/section.old") <(grep -v 'refreshed 20' "$WORK/section.md") >/dev/null; then
    echo "project_index.md: no change"
  else
    awk -v section="$WORK/section.md" '
      /BEGIN AUTO:GITLAB-ONLY/ { while ((getline line < section) > 0) print line; skip=1; next }
      /END AUTO:GITLAB-ONLY/   { skip=0; next }
      !skip
    ' "$INDEX" > "$WORK/index.new" && mv "$WORK/index.new" "$INDEX"
    echo "project_index.md updated — bpp-backend now has an uncommitted change; the user decides when to commit."
  fi
  rm -rf "$WORK"
}

# Consumer filter sets → name TAB enc
do_candidates() {
  case "${1:-}" in
    promote) rows | awk -F'\t' '$6=="active" && $5!~/generated-output|excluded-manual|guides-store/ \
               && ($4=="backend" || $4=="frontend" || $4=="docs" || ($4=="unlisted" && $1 ~ /^bpp-|^brokernet-.*-ui$/)) \
               {print $1 "\t" $3}' ;;
    audit)   rows | awk -F'\t' '$6=="active" && $5!~/generated-output|excluded-manual|guides-store|scaffold/ \
               && ($4=="backend" || $4=="frontend" || $4=="docs" || ($4=="unlisted" && $1 ~ /^bpp-|^brokernet-.*-ui$/)) \
               {print $1 "\t" $3}' ;;
    bump)    rows | awk -F'\t' '$6=="active" && $1 ~ /^bpp-/ && $5!~/shared-source/ {print $1 "\t" $3}' ;;
    *) echo "usage: candidates promote|audit|bump" >&2; return 2 ;;
  esac
}

# --write preview: proposed rows (class is a heuristic PROPOSAL) + repos.md rows still on an old path
do_reposmd_diff() {
  echo "Proposed additions to bpp/repos.md (class is a heuristic proposal — confirm each):"
  rows | awk -F'\t' '$4=="unlisted" && $6=="active" {
    c = "Infrastruktur"; if ($1 ~ /-ui$/) c = "Frontend"; else if ($8 == "development") c = "Backend"
    print "  " c "\t| " $1 " | https://gitlab.com/" $2 " |"}'
  echo "repos.md rows on a renamed path (fix by hand; --write is append-only):"
  awk -F'\t' '/^#renamed/ && $4=="repos.md" {print "  " $2 " -> " $3}' "$MANIFEST"
}

clone_set() {
  rows | awk -F'\t' '$7=="-" && $6=="active" && $4!~/^(infra|unlisted)$/ {print $1 "\t" $2}' | head -n "${MAX_CLONE:-10}"
}

do_clone() {
  [ $# -gt 0 ] || { echo "clone needs explicit repo names from clone-preview (after the user's go)" >&2; clone_set; return 2; }
  local want name pathns hit
  for want in "$@"; do
    hit=$(clone_set | awk -F'\t' -v n="$want" '$1==n')
    [ -n "$hit" ] || { echo "SKIP $want — not in the clone set (unlisted/infra/inactive/already checked out)"; continue; }
    IFS=$'\t' read -r name pathns <<<"$hit"
    [ -e "$DEV_ROOT/$name/.git" ] && { echo "SKIP $name — already there"; continue; }
    git clone "https://gitlab.com/${pathns}.git" "$DEV_ROOT/$name" && echo "CLONED $name → $DEV_ROOT/$name" \
      || echo "FAIL $name — clone failed, continuing"
  done
}

# Sourced → stop here, helpers only
(return 0 2>/dev/null) && return 0

mode="${1:-all}"; shift 2>/dev/null || true
case "$mode" in
  all)           do_refresh; echo; do_index ;;
  refresh)       do_refresh ;;
  report)        do_report ;;
  index)         do_index ;;
  candidates)    do_candidates "$@" ;;
  reposmd-diff)  do_reposmd_diff ;;
  clone-preview) echo "Would clone (MAX_CLONE=${MAX_CLONE:-10}) into $DEV_ROOT:"; clone_set | sed 's/^/  /' ;;
  clone)         do_clone "$@" ;;
  *) echo "usage: refresh.sh [refresh|report|index|candidates promote|audit|bump|reposmd-diff|clone-preview|clone <name>...]" >&2; exit 2 ;;
esac
