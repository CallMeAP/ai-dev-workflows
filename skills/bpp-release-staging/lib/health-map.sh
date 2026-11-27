#!/usr/bin/env bash
# Maps Gatus health endpoints to repos, for the release health baseline and the deploy watch.
# Usage:
#   health-map.sh hosts <repo>=<checkout dir | compose file> ...
#       TSV "repo<TAB>host" from origin/staging's infra/docker/compose/docker-compose.staging.yml:
#       Traefik Host(`...`) rules, network aliases (block or flow list), container_name and
#       hostname (Gatus checks some services by their internal name, e.g. staging-bpp-mail);
#       "repo<TAB>-" when there is none.
#       A checkout dir is read with git (run "git fetch origin staging" first); a regular file is
#       read as the compose file itself (for repos without a local clone: download it with glab).
#   health-map.sh map <gatus statuses.json> <hosts.tsv> <release repos, comma-separated> [group]
#       JSON {endpoints, release_unhealthy, known_unhealthy, unmapped} for one Gatus group
#       (default staging). statuses.json is the API's /api/v1/endpoints/statuses array
#       (health.sh json). An endpoint without results is unknown (healthy null).
#   health-map.sh diff <baseline map.json> <now map.json>
#       JSON {new_unhealthy, known_unhealthy}: unhealthy now and healthy or absent at
#       baseline -> new; unhealthy at baseline too -> known.
# fail_since is the timestamp where the current failure streak starts; fail_since_capped is
# true when every kept result failed (Gatus keeps ~100 results, so it may have started earlier).
# Exit 2 on bad usage or a missing file, 1 on invalid JSON.
set -u

die() { printf 'health-map.sh: %s\n' "$2" >&2; exit "$1"; }

COMPOSE=infra/docker/compose/docker-compose.staging.yml

# compose_names: compose YAML on stdin -> every Traefik host, network alias, container_name
# and hostname, one per line (plain awk, no YAML parser).
compose_names() {
  awk '
    function unq(v) { gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^["\047]|["\047]$/, "", v); return v }
    function ind(l) { match(l, /^ */); return RLENGTH }
    {
      line = $0
      rest = line
      while (match(rest, /Host\(`[^`]*`\)/)) {
        print substr(rest, RSTART + 6, RLENGTH - 8)
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (inal) {
        if (line ~ /^[ \t]*$/) next
        if (ind(line) > alind && line ~ /^[ \t]*- /) { v = line; sub(/^[ \t]*- /, "", v); print unq(v); next }
        inal = 0
      }
      if (line ~ /^[ \t]*aliases:[ \t]*\[/) {
        v = line; sub(/^[^\[]*\[/, "", v); sub(/\].*$/, "", v)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) { p = unq(parts[i]); if (p != "") print p }
        next
      }
      if (line ~ /^[ \t]*aliases:[ \t]*$/) { inal = 1; alind = ind(line); next }
      if (line ~ /^[ \t]*(container_name|hostname):[ \t]*[^ \t]/) {
        v = line; sub(/^[ \t]*(container_name|hostname):/, "", v); print unq(v)
      }
    }'
}

cmd_hosts() {
  local arg repo dir hosts found
  [ $# -gt 0 ] || die 2 "usage: health-map.sh hosts <repo>=<dir|compose file> ..."
  for arg in "$@"; do
    case "$arg" in
      *=*) ;;
      *) die 2 "expected <repo>=<dir>, got: $arg" ;;
    esac
    repo=${arg%%=*}
    dir=${arg#*=}
    found=0
    hosts=
    if [ -f "$dir" ]; then
      hosts=$(compose_names < "$dir" | grep -v '^$' | sort -u)
    elif [ -d "$dir" ]; then
      hosts=$(git -C "$dir" show "origin/staging:$COMPOSE" 2>/dev/null | compose_names | grep -v '^$' | sort -u)
    fi
    if [ -n "$hosts" ]; then
      printf '%s\n' "$hosts" | while IFS= read -r h; do printf '%s\t%s\n' "$repo" "$h"; done
      found=1
    fi
    [ "$found" = 1 ] || printf '%s\t-\n' "$repo"
  done
}

cmd_map() {
  local statuses=${1:-} hostsf=${2:-} repos=${3:-} group=${4:-staging}
  if [ -z "$statuses" ] || [ -z "$hostsf" ]; then
    die 2 "usage: health-map.sh map <statuses.json> <hosts.tsv> <repos> [group]"
  fi
  [ -f "$statuses" ] || die 2 "no such file: $statuses"
  [ -f "$hostsf" ] || die 2 "no such file: $hostsf"
  jq -e 'type == "array"' "$statuses" >/dev/null 2>&1 || die 1 "not a JSON array: $statuses"
  jq -n --slurpfile st "$statuses" --rawfile hosts "$hostsf" --arg repos "$repos" --arg group "$group" '
    ($hosts | split("\n") | map(select(length > 0) | split("\t") | {repo: .[0], host: .[1]})
      | map(select(.host != "-" and .host != null))) as $hm
    | ($repos | split(",") | map(select(length > 0))) as $rel
    | [ $st[0][] | select(.group == $group)
        | (.results // []) as $r
        | ($r | last) as $l
        | ($r | map(.success == true) | rindex([true])) as $ok
        | ($l.success) as $s
        | {key, name, group,
           host: ($l.hostname // null),
           healthy: (if $l == null then null else ($s == true) end),
           fail_since: (if $l == null or $s == true then null
                        elif $ok == null then $r[0].timestamp
                        else $r[$ok + 1].timestamp end),
           fail_since_capped: (if $l == null or $s == true then false else ($ok == null) end)}
        | . as $e
        | .repos = ([$hm[] | select(.host == $e.host) | .repo] | unique) ] as $eps
    | {endpoints: $eps,
       release_unhealthy: [ $eps[] | select(.healthy == false) | . as $e
                            | .repos[] | select(. as $x | $rel | index([$x]))
                            | {repo: ., key: $e.key, name: $e.name, host: $e.host,
                               fail_since: $e.fail_since, fail_since_capped: $e.fail_since_capped} ],
       known_unhealthy: [ $eps[] | select(.healthy == false)
                          | select(([.repos[] | . as $x | $rel | index([$x])] | map(select(. != null)) | length) == 0) ],
       unmapped: [ $rel[] | . as $x | select(([$eps[] | select(.repos | index([$x]))] | length) == 0) ]}'
}

cmd_diff() {
  local base=${1:-} now=${2:-}
  if [ -z "$base" ] || [ -z "$now" ]; then
    die 2 "usage: health-map.sh diff <baseline map.json> <now map.json>"
  fi
  [ -f "$base" ] || die 2 "no such file: $base"
  [ -f "$now" ] || die 2 "no such file: $now"
  jq -e '.endpoints | type == "array"' "$base" >/dev/null 2>&1 || die 1 "not a map JSON: $base"
  jq -e '.endpoints | type == "array"' "$now" >/dev/null 2>&1 || die 1 "not a map JSON: $now"
  jq -n --slurpfile b "$base" --slurpfile n "$now" '
    ($b[0].endpoints | map({key: .key, value: .healthy}) | from_entries) as $was
    | [ $n[0].endpoints[] | select(.healthy == false) ] as $bad
    | {new_unhealthy: [ $bad[] | select($was[.key] != false) ],
       known_unhealthy: [ $bad[] | select($was[.key] == false) ]}'
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  hosts) cmd_hosts "$@" ;;
  map) cmd_map "$@" ;;
  diff) cmd_diff "$@" ;;
  *) die 2 "unknown command: ${cmd:-<none>} (hosts|map|diff)" ;;
esac
