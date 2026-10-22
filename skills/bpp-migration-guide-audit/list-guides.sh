#!/usr/bin/env bash
# List endpoint migration guides across the BPP fleet, read from origin/<branch> (default development).
# Usage: bash list-guides.sh [--no-fetch] [--all] [--branch <b>]
# Output (TSV): repo  status  path  stem
#   status: open (_[].md / _[ ].md) | unmarked (no marker) | done (_[X].md, only with --all)
#   stem:   __<n>_<YYYY-MM-DD>  — guide numbers alone are NOT unique, dedupe on path or stem
# Repos without a local checkout are printed to stderr as "unscanned", never silently dropped.
set -euo pipefail
MANIFEST=~/.claude/bpp-fleet/manifest.tsv
FETCH=1 ALL=0 BR=development
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0 ;;
    --all) ALL=1 ;;
    --branch) BR=$2; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
[ -r "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing — run bpp-project-index" >&2; exit 1; }
echo "# $(grep -m1 '^#generated' "$MANIFEST") branch=origin/$BR" >&2

awk -F'\t' '!/^#/ && $6=="active" && ($4=="backend" || $4=="unlisted") {print $1 "\t" $7}' "$MANIFEST" |
while IFS=$'\t' read -r repo path; do
  if [ "$path" = "-" ] || ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "unscanned	$repo	no local checkout" >&2; continue
  fi
  [ "$FETCH" = 1 ] && { git -C "$path" fetch -q origin "$BR" 2>/dev/null || echo "fetch-failed	$repo	(using cached origin/$BR)" >&2; }
  git -C "$path" rev-parse -q --verify "origin/$BR" >/dev/null || { echo "unscanned	$repo	no origin/$BR" >&2; continue; }
  git -C "$path" ls-tree -r --name-only "origin/$BR" | grep -E '/endpoint-migration-guides/[^/]+\.md$' |
  while read -r f; do
    base=${f##*/}
    case "$base" in
      *_\[[Xx]\].md) st=done ;;
      *_\[\].md|*_\[\ \].md) st=open ;;
      *) st=unmarked ;;
    esac
    [ "$st" = done ] && [ "$ALL" = 0 ] && continue
    stem=$(printf %s "$base" | grep -oE '^__[0-9]+_[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "?")
    printf '%s\t%s\t%s\t%s\n' "$repo" "$st" "$f" "$stem"
  done || true
done
