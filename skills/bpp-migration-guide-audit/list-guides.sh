#!/usr/bin/env bash
# List endpoint migration guides from the central repo bpp-endpoint-migration-guides, read from origin/main.
# Usage: bash list-guides.sh [--no-fetch] [--all]
# Env:   GUIDES_DIR  local clone (default ~/Entwicklung/bpp/bpp-endpoint-migration-guides)
#        GUIDES_REF  ref to read (default origin/main; override only to test a branch, e.g. origin/feature/x)
# Output (TSV): repo  status  path  stem
#   repo:   the folder name = the backend repo the guide belongs to
#   status: open (_[].md / _[ ].md) | unmarked (no marker) | done (_[X].md, only with --all)
#   path:   path inside the guides repo, e.g. bpp-backend/__112_2026-10-09_..._[].md
#   stem:   __<n>_<YYYY-MM-DD> — numbers are unique per folder only, dedupe on repo + stem
set -euo pipefail
DIR=${GUIDES_DIR:-$HOME/Entwicklung/bpp/bpp-endpoint-migration-guides}
REF=${GUIDES_REF:-origin/main}
FETCH=1 ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) FETCH=0 ;;
    --all) ALL=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "FAIL: no clone at $DIR — git clone https://gitlab.com/lipso/clients/brokernet/bpp-endpoint-migration-guides.git $DIR" >&2; exit 1; }
if [ "$FETCH" = 1 ] && [ "${REF#origin/}" != "$REF" ]; then
  git -C "$DIR" fetch -q origin "${REF#origin/}" 2>/dev/null || echo "fetch-failed	(using cached $REF)" >&2
fi
git -C "$DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null || { echo "FAIL: $REF not found in $DIR" >&2; exit 1; }
echo "# guides=$DIR ref=$REF@$(git -C "$DIR" rev-parse --short "$REF")" >&2

git -C "$DIR" -c core.quotePath=false ls-tree -r --name-only "$REF" | grep -E '^[^/]+/[^/]+\.md$' |
while read -r f; do
  repo=${f%%/*} base=${f##*/}
  [ "$base" = README.md ] && continue
  case "$base" in
    *_\[[Xx]\].md) st=done ;;
    *_\[\].md|*_\[\ \].md) st=open ;;
    *) st=unmarked ;;
  esac
  [ "$st" = done ] && [ "$ALL" = 0 ] && continue
  stem=$(printf %s "$base" | grep -oE '^__[0-9]+_[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "?")
  printf '%s\t%s\t%s\t%s\n' "$repo" "$st" "$f" "$stem"
done || true
