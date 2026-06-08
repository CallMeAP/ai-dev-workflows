#!/usr/bin/env bash
#
# bpp-check-translation-keys
# Report transloco keys referenced in brokernet-cockpit-ui that are MISSING from
# the bpp-backend served translation files (de.json / en.json).
#
# Compares development -> development for BOTH repos, read straight from the
# `origin/development` ref via `git grep <ref>` and `git show <ref>:file` — no
# branch switching, no clean-tree requirement, no effect on either working tree.
#
# Override repo locations with env vars if your clones live elsewhere:
#   UI_REPO=/path/to/brokernet-cockpit-ui  BE_REPO=/path/to/bpp-backend  ./check-i18n-keys.sh
#
set -uo pipefail
export LC_ALL=C   # stable sort/comm ordering

UI_REPO="${UI_REPO:-$HOME/Entwicklung/brokernet/brokernet-cockpit-ui}"
BE_REPO="${BE_REPO:-$HOME/Entwicklung/bpp/bpp-backend}"
REF="origin/development"
DE_PATH="BPP.Backend.NET/BPP.Backend.NET.App/wwwroot/i18n/de.json"
EN_PATH="BPP.Backend.NET/BPP.Backend.NET.App/wwwroot/i18n/en.json"

for d in "$UI_REPO" "$BE_REPO"; do
  [ -d "$d/.git" ] || { echo "FAIL — not a git repo: $d" >&2; exit 1; }
done
command -v jq >/dev/null || { echo "FAIL — jq not found" >&2; exit 1; }

echo "Fetching $REF for both repos…"
git -C "$UI_REPO" fetch -q origin development || { echo "FAIL — cockpit-ui fetch" >&2; exit 1; }
git -C "$BE_REPO" fetch -q origin development || { echo "FAIL — bpp-backend fetch" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# (1) Referenced keys from cockpit-ui dev: template pipes + TS service calls (static literals only).
{
  git -C "$UI_REPO" grep -hoE "['\"][A-Za-z0-9_.]+['\"] *\| *transloco" "$REF" -- '*.html' '*.ts' 2>/dev/null
  git -C "$UI_REPO" grep -hoE "\.(translate|selectTranslate|selectTranslateObject|translateObject)\( *['\"][A-Za-z0-9_.]+['\"]" "$REF" -- '*.ts' '*.html' 2>/dev/null
} | grep -oE "['\"][A-Za-z0-9_.]+['\"]" | tr -d "'\"" | sort -u > "$tmp/referenced.txt"

# (2) Backend key sets from dev ref (flat dotted-key JSON).
git -C "$BE_REPO" show "$REF:$DE_PATH" | jq -r 'keys[]' | sort -u > "$tmp/de.txt"
git -C "$BE_REPO" show "$REF:$EN_PATH" | jq -r 'keys[]' | sort -u > "$tmp/en.txt"

# (3) Diffs.
comm -23 "$tmp/referenced.txt" "$tmp/de.txt" > "$tmp/missing_de.txt"
comm -23 "$tmp/referenced.txt" "$tmp/en.txt" > "$tmp/missing_en.txt"
comm -12 "$tmp/missing_de.txt" "$tmp/missing_en.txt" > "$tmp/missing_both.txt"
comm -23 "$tmp/missing_de.txt" "$tmp/missing_en.txt" > "$tmp/missing_de_only.txt"
comm -23 "$tmp/missing_en.txt" "$tmp/missing_de.txt" > "$tmp/missing_en_only.txt"

# First cockpit-ui reference (file:line) for a key.
locate() {
  git -C "$UI_REPO" grep -nE "['\"]${1//./\\.}['\"]" "$REF" -- '*.html' '*.ts' 2>/dev/null \
    | head -1 | sed -E "s#^$REF:##" | cut -d: -f1-2
}
dump() {  # $1 = file, $2 = heading
  local n; n=$(wc -l < "$1" | tr -d ' ')
  echo; echo "$2 ($n):"
  [ "$n" -eq 0 ] && { echo "  — none —"; return; }
  while IFS= read -r key; do printf '  %-48s %s\n' "$key" "$(locate "$key")"; done < "$1"
}

echo "=============================================================="
echo " bpp-check-translation-keys — cockpit-ui vs bpp-backend ($REF)"
echo "=============================================================="
dump "$tmp/missing_both.txt"    "MISSING in BOTH de+en  (new keys never added)"
dump "$tmp/missing_en_only.txt" "MISSING in EN only     (de exists, en not nachgezogen)"
dump "$tmp/missing_de_only.txt" "MISSING in DE only"

# (4) Unresolvable / dynamic keys — listed, never counted as missing.
git -C "$UI_REPO" grep -nE "\| *transloco" "$REF" -- '*.html' '*.ts' 2>/dev/null \
  | grep -vE "['\"][A-Za-z0-9_.]+['\"] *\| *transloco" | sed -E "s#^$REF:##" > "$tmp/dyn_pipe.txt"
git -C "$UI_REPO" grep -nE "\.(translate|selectTranslate|selectTranslateObject|translateObject)\( *[^'\")[:space:]]" "$REF" -- '*.ts' 2>/dev/null \
  | sed -E "s#^$REF:##" > "$tmp/dyn_ts.txt"
dyn=$(( $(wc -l < "$tmp/dyn_pipe.txt") + $(wc -l < "$tmp/dyn_ts.txt") ))
echo; echo "UNRESOLVABLE / dynamic keys ($dyn) — check manually, NOT counted above:"
{ head -5 "$tmp/dyn_pipe.txt"; head -5 "$tmp/dyn_ts.txt"; } | sed -E 's/^ +//; s/^/  /' | cut -c1-120

echo
echo "Summary: referenced(static)=$(wc -l < "$tmp/referenced.txt" | tr -d ' ')"\
" · de-keys=$(wc -l < "$tmp/de.txt" | tr -d ' ')"\
" · en-keys=$(wc -l < "$tmp/en.txt" | tr -d ' ')"\
" · missing-both=$(wc -l < "$tmp/missing_both.txt" | tr -d ' ')"\
" · missing-en-only=$(wc -l < "$tmp/missing_en_only.txt" | tr -d ' ')"\
" · dynamic=$dyn"
echo
echo "NOTE: dynamic keys ('prefix.'+var, key()|transloco, selectTranslateObject subtrees)"
echo "      and component @Input key-strings are NOT verified — triage the dynamic list by hand."
