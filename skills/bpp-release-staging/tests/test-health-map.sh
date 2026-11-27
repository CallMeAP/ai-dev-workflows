#!/usr/bin/env bash
# Tests for lib/health-map.sh: Traefik hosts per repo, Gatus endpoint <-> repo mapping, baseline diff.
# shellcheck disable=SC1091,SC2016
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
HM="$here/../lib/health-map.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

run_cmd() {
  "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# --- hosts: Host rules from origin/staging's compose file ---
mkrepo() { # mkrepo <dir> <compose text or empty>
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  if [ -n "$2" ]; then
    mkdir -p "$1/infra/docker/compose"
    printf '%s\n' "$2" > "$1/infra/docker/compose/docker-compose.staging.yml"
    git -C "$1" add infra
    git -C "$1" -c user.email=t@t -c user.name=t commit -q -m compose
  fi
  git -C "$1" update-ref refs/remotes/origin/staging HEAD
}
mkrepo "$TMP/agent" '    labels:
        - traefik.http.routers.staging_agent.rule=Host(`agent.staging.go-plattform.at`)'
mkrepo "$TMP/file" '        - traefik.http.routers.a.rule=Host(`file.staging.go-plattform.at`) || Host(`files.staging.go-plattform.at`)'
mkrepo "$TMP/ui" ''
mkrepo "$TMP/mail" '  mail:
    image: x
    networks:
      staging:
        aliases:
          - staging-bpp-mail
          - "staging-bpp-mail-2"
    environment:
      - SOME=thing'
mkrepo "$TMP/flow" '  svc:
    container_name: staging-bpp-flow
    hostname: "flow-host"
    networks:
      staging:
        aliases: [staging-bpp-jsreport-connector, '"'"'staging-quoted'"'"']'

run_cmd bash "$HM" hosts "bpp-agent=$TMP/agent" "bpp-file=$TMP/file" "cockpit=$TMP/ui"
assert_eq 0 "$RC" "hosts: status 0"
assert_contains "$(printf 'bpp-agent\tagent.staging.go-plattform.at')" "$OUT" "hosts: agent host"
assert_contains "$(printf 'bpp-file\tfile.staging.go-plattform.at')" "$OUT" "hosts: first of two hosts"
assert_contains "$(printf 'bpp-file\tfiles.staging.go-plattform.at')" "$OUT" "hosts: second of two hosts"
assert_contains "$(printf 'cockpit\t-')" "$OUT" "hosts: repo without compose file -> -"
run_cmd bash "$HM" hosts "bpp-mail=$TMP/mail" "bpp-js-report-connector=$TMP/flow"
assert_contains "$(printf 'bpp-mail\tstaging-bpp-mail')" "$OUT" "hosts: network alias from a block list"
assert_contains "$(printf 'bpp-mail\tstaging-bpp-mail-2')" "$OUT" "hosts: quoted alias in a block list"
assert_not_contains "SOME=thing" "$OUT" "hosts: list items after the aliases block are not aliases"
assert_contains "$(printf 'bpp-js-report-connector\tstaging-bpp-jsreport-connector')" "$OUT" "hosts: alias from a flow list"
assert_contains "$(printf 'bpp-js-report-connector\tstaging-quoted')" "$OUT" "hosts: quoted alias from a flow list"
assert_contains "$(printf 'bpp-js-report-connector\tstaging-bpp-flow')" "$OUT" "hosts: container_name"
assert_contains "$(printf 'bpp-js-report-connector\tflow-host')" "$OUT" "hosts: hostname"
printf '%s\n' '      staging:' '        aliases:' '          - staging-bpp-varias-sign' > "$TMP/varias-compose.yml"
run_cmd bash "$HM" hosts "brokernet-varias-sign=$TMP/varias-compose.yml"
assert_contains "$(printf 'brokernet-varias-sign\tstaging-bpp-varias-sign')" "$OUT" "hosts: a compose file instead of a checkout (repo without local clone)"
run_cmd bash "$HM" hosts "nodir=$TMP/missing"
assert_contains "$(printf 'nodir\t-')" "$OUT" "hosts: missing checkout -> -"
run_cmd bash "$HM" hosts "bad-arg"
assert_eq 2 "$RC" "hosts: arg without = -> 2"

# --- map: Gatus statuses (oldest result first) ---
cat > "$TMP/now.json" <<'EOF'
[
 {"name":"Agent Service","group":"staging","key":"staging_agent-service","results":[
   {"hostname":"agent.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T09:20:40Z"},
   {"hostname":"agent.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T10:59:40Z"}]},
 {"name":"File","group":"staging","key":"staging_file","results":[
   {"hostname":"file.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T10:00:00Z"},
   {"hostname":"file.staging.go-plattform.at","success":true,"timestamp":"2026-11-27T10:01:00Z"},
   {"hostname":"file.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T10:02:00Z"},
   {"hostname":"file.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T10:03:00Z"}]},
 {"name":"Chat","group":"staging","key":"staging_chat","results":[
   {"hostname":"chat.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T10:00:00Z"}]},
 {"name":"BPP Service","group":"staging","key":"staging_bpp","results":[
   {"hostname":"bpp.staging.go-plattform.at","success":true,"timestamp":"2026-11-27T10:00:00Z"}]},
 {"name":"Agent Service","group":"main","key":"main_agent-service","results":[
   {"hostname":"agent.go-plattform.at","success":false,"timestamp":"2026-11-27T10:00:00Z"}]},
 {"name":"New","group":"staging","key":"staging_new","results":[]}
]
EOF
printf 'bpp-agent\tagent.staging.go-plattform.at\nbpp-file\tfile.staging.go-plattform.at\nbpp-backend\tbpp.staging.go-plattform.at\ncockpit\t-\n' > "$TMP/hosts.tsv"

run_cmd bash "$HM" map "$TMP/now.json" "$TMP/hosts.tsv" "bpp-agent,bpp-backend,cockpit"
assert_eq 0 "$RC" "map: status 0"
printf '%s' "$OUT" > "$TMP/map.json"
assert_eq "staging_agent-service" "$(jq -r '.release_unhealthy[0].key' "$TMP/map.json")" "map: release repo with unhealthy endpoint"
assert_eq "bpp-agent" "$(jq -r '.release_unhealthy[0].repo' "$TMP/map.json")" "map: names the release repo"
assert_eq 1 "$(jq '.release_unhealthy | length' "$TMP/map.json")" "map: only one release_unhealthy"
assert_eq '["staging_chat","staging_file"]' "$(jq -c '[.known_unhealthy[].key] | sort' "$TMP/map.json")" "map: unhealthy endpoints of other repos are known"
assert_eq '["cockpit"]' "$(jq -c '.unmapped' "$TMP/map.json")" "map: release repo without endpoint is unmapped"
assert_eq "2026-11-27T10:02:00Z" "$(jq -r '.endpoints[] | select(.key=="staging_file") | .fail_since' "$TMP/map.json")" "map: fail_since = start of the trailing failure streak"
assert_eq "false" "$(jq -r '.endpoints[] | select(.key=="staging_file") | .fail_since_capped' "$TMP/map.json")" "map: streak with an older success is not capped"
assert_eq "2026-11-27T09:20:40Z" "$(jq -r '.endpoints[] | select(.key=="staging_agent-service") | .fail_since' "$TMP/map.json")" "map: all kept results failed -> oldest kept timestamp"
assert_eq "true" "$(jq -r '.endpoints[] | select(.key=="staging_agent-service") | .fail_since_capped' "$TMP/map.json")" "map: all failed -> capped"
assert_eq "null" "$(jq -r '.endpoints[] | select(.key=="staging_bpp") | .fail_since' "$TMP/map.json")" "map: healthy endpoint has no fail_since"
assert_eq "null" "$(jq -r '.endpoints[] | select(.key=="staging_new") | .healthy' "$TMP/map.json")" "map: endpoint without results is unknown (null)"
assert_eq 0 "$(jq '[.endpoints[] | select(.group != "staging")] | length' "$TMP/map.json")" "map: only the staging group by default"

printf '[{"name":"Mail","group":"staging","key":"staging_mail-service","results":[{"hostname":"staging-bpp-mail","success":false,"timestamp":"2026-11-27T10:00:00Z"}]}]' > "$TMP/mail.json"
printf 'bpp-mail\tstaging-bpp-mail\n' > "$TMP/mail.tsv"
run_cmd bash "$HM" map "$TMP/mail.json" "$TMP/mail.tsv" "bpp-mail"
assert_eq "bpp-mail" "$(printf '%s' "$OUT" | jq -r '.release_unhealthy[0].repo')" "map: endpoint with an internal hostname maps via the alias"
assert_eq "[]" "$(printf '%s' "$OUT" | jq -c '.unmapped')" "map: alias-mapped repo is not unmapped"

run_cmd bash "$HM" map "$TMP/now.json" "$TMP/hosts.tsv" "bpp-agent" main
assert_eq 0 "$(jq '[.endpoints[] | select(.group != "main")] | length' "$TMP/out")" "map: group argument selects main"

run_cmd bash "$HM" map "$TMP/missing.json" "$TMP/hosts.tsv" "bpp-agent"
assert_eq 2 "$RC" "map: missing statuses file -> 2"
assert_contains "no such file" "$ERR" "map: missing file is named on stderr"
printf 'not json' > "$TMP/bad.json"
run_cmd bash "$HM" map "$TMP/bad.json" "$TMP/hosts.tsv" "bpp-agent"
assert_eq 1 "$RC" "map: invalid statuses JSON -> 1"

# --- diff: baseline vs now ---
cat > "$TMP/base-statuses.json" <<'EOF'
[
 {"name":"Agent Service","group":"staging","key":"staging_agent-service","results":[{"hostname":"agent.staging.go-plattform.at","success":false,"timestamp":"2026-11-27T09:00:00Z"}]},
 {"name":"File","group":"staging","key":"staging_file","results":[{"hostname":"file.staging.go-plattform.at","success":true,"timestamp":"2026-11-27T09:00:00Z"}]},
 {"name":"BPP Service","group":"staging","key":"staging_bpp","results":[{"hostname":"bpp.staging.go-plattform.at","success":true,"timestamp":"2026-11-27T09:00:00Z"}]}
]
EOF
bash "$HM" map "$TMP/base-statuses.json" "$TMP/hosts.tsv" "bpp-agent" > "$TMP/base-map.json"
run_cmd bash "$HM" diff "$TMP/base-map.json" "$TMP/map.json"
assert_eq 0 "$RC" "diff: status 0"
printf '%s' "$OUT" > "$TMP/diff.json"
assert_eq '["staging_chat","staging_file"]' "$(jq -c '[.new_unhealthy[].key] | sort' "$TMP/diff.json")" "diff: healthy or absent at baseline, unhealthy now -> new"
assert_eq '["staging_agent-service"]' "$(jq -c '[.known_unhealthy[].key]' "$TMP/diff.json")" "diff: unhealthy at baseline -> known"
assert_eq "2026-11-27T10:02:00Z" "$(jq -r '.new_unhealthy[] | select(.key=="staging_file") | .fail_since' "$TMP/diff.json")" "diff: keeps fail_since for the 15-minute rule"

run_cmd bash "$HM" bogus
assert_eq 2 "$RC" "unknown command -> 2"

finish
