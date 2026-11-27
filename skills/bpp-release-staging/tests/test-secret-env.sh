#!/usr/bin/env bash
# Tests for lib/secret-env.sh. Uses a temp HOME and stub tools; never reads a real secret.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=assert.sh
. "$here/assert.sh"
LIB="$here/../lib/secret-env.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
ENVF="$HOME/.bpp-release.env"
unset BPP_RELEASE_ENV_FILE BPP_KEYCHAIN_TIMEOUT
export BPP_RELEASE_SECRETS=envfile

# write_env <mode> <content>
write_env() {
  printf '%s' "$2" > "$ENVF"
  chmod "$1" "$ENVF"
}

# gs <stage> [db] - runs get_secret in a subshell; sets OUT, ERR, RC
gs() {
  ( . "$LIB" && get_secret "$@" ) > "$TMP/out" 2> "$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# plain value, mode 600
write_env 600 'BPP_DB_STAGING="Host=h;Password=p1"
'
gs staging
assert_eq 0 "$RC" "envfile: status 0"
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: double-quoted value"

# CRLF line endings and single quotes
write_env 600 "BPP_DB_DEVELOPMENT='Host=d;Password=p1'"$'\r\n'"BPP_DB_STAGING='Host=h;Password=p1'"$'\r\n'
gs staging
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: CRLF + single quotes give clean value"
gs development
assert_eq 'Host=d;Password=p1' "$OUT" "envfile: other stage line read"

# last line without newline
write_env 600 'BPP_DB_STAGING=Host=h;Password=p1'
gs staging
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: unquoted value, no final newline"

# trailing whitespace after a closing quote
write_env 600 "$(printf 'BPP_DB_STAGING="Host=h;Password=p1"  \t\nBPP_DB_DEVELOPMENT=%s   \n' "'Host=d;Password=p1'")"
gs staging
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: trailing whitespace after a closing double quote trimmed"
gs development
assert_eq 'Host=d;Password=p1' "$OUT" "envfile: trailing whitespace after a closing single quote trimmed"

# trailing comment after a closing quote
write_env 600 "$(printf 'BPP_DB_STAGING="Host=h;Password=p#1" # staging DB\nBPP_DB_DEVELOPMENT=%s\n' "'Host=d;Password=p1' # it's dev")"
gs staging
assert_eq 'Host=h;Password=p#1' "$OUT" "envfile: comment after a closing double quote removed, # inside kept"
gs development
assert_eq 'Host=d;Password=p1' "$OUT" "envfile: comment with a quote after a closing single quote removed"

# unquoted: a # may be part of the password, so nothing is cut
write_env 600 'BPP_DB_STAGING=Host=h;Password=p#1 # x
'
gs staging
assert_eq 'Host=h;Password=p#1 # x' "$OUT" "envfile: unquoted value keeps # text, only trailing spaces trimmed"

# the real password is still redacted when the line has a trailing comment
write_env 600 'BPP_DB_STAGING="Host=h;Username=u;Password=s3cr-et" # staging
'
OUT=$( (. "$LIB" && . "$here/../lib/redact.sh" && conn=$(get_secret staging) &&
  printf 'Npgsql: bad connection %s\nauth failed for password s3cr-et\n' "$conn" | redact_stream "$conn") 2>&1)
assert_not_contains 's3cr-et' "$OUT" "redact: password from a commented line is still redacted"
assert_contains '***' "$OUT" "redact: replacement marker present"

# wrong mode
write_env 644 'BPP_DB_STAGING="Host=h;Password=p1"
'
gs staging
assert_eq 4 "$RC" "envfile: mode 644 refused with status 4"
assert_contains 600 "$ERR" "envfile: mode error mentions 600"
assert_not_contains p1 "$ERR$OUT" "envfile: mode error does not leak the secret"

# unknown stages
write_env 600 'BPP_DB_STAGING="Host=h;Password=p1"
'
gs main
assert_eq 2 "$RC" "get_secret main: status 2"
assert_eq '' "$OUT" "get_secret main: no output"
gs prod
assert_eq 2 "$RC" "get_secret prod: status 2"
gs ''
assert_eq 2 "$RC" "get_secret without stage: status 2"

# second database: document analysis has its own lines; neither database reads the other's
write_env 600 'BPP_DB_STAGING="Host=h;Password=p1"
BPP_DB_DOCUMENT_ANALYSIS_STAGING="Host=da;Password=p3"
BPP_DB_DOCUMENT_ANALYSIS_DEVELOPMENT="Host=dd;Password=p4"
'
gs staging document-analysis
assert_eq 0 "$RC" "envfile document-analysis: status 0"
assert_eq 'Host=da;Password=p3' "$OUT" "envfile document-analysis: staging value"
gs development document-analysis
assert_eq 'Host=dd;Password=p4' "$OUT" "envfile document-analysis: development value"
gs staging bpp
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: explicit bpp is the default database"
gs staging
assert_eq 'Host=h;Password=p1' "$OUT" "envfile: bpp value unchanged by the document analysis lines"
gs development
assert_eq 3 "$RC" "envfile: a document analysis line does not count as the bpp line"
write_env 600 'BPP_DB_STAGING="Host=h;Password=p1"
'
gs staging document-analysis
assert_eq 3 "$RC" "envfile document-analysis: missing line gives status 3"
assert_contains 'BPP_DB_DOCUMENT_ANALYSIS_STAGING' "$ERR" "envfile document-analysis: error names the missing key"
gs staging other
assert_eq 2 "$RC" "get_secret unknown database: status 2"
assert_eq '' "$OUT" "get_secret unknown database: no output"
gs main document-analysis
assert_eq 2 "$RC" "get_secret main document-analysis: status 2"

# missing line / missing file / empty value
gs development
assert_eq 3 "$RC" "envfile: missing stage line gives status 3"
write_env 600 'BPP_DB_STAGING=""
'
gs staging
assert_eq 3 "$RC" "envfile: empty value gives status 3"
rm -f "$ENVF"
gs staging
assert_eq 3 "$RC" "envfile: missing file gives status 3"

# BPP_RELEASE_ENV_FILE override
printf 'BPP_DB_STAGING="Host=o;Password=p2"\n' > "$TMP/other.env"
chmod 600 "$TMP/other.env"
OUT=$( (BPP_RELEASE_ENV_FILE="$TMP/other.env"; export BPP_RELEASE_ENV_FILE; . "$LIB" && get_secret staging) 2>/dev/null)
assert_eq 'Host=o;Password=p2' "$OUT" "envfile: BPP_RELEASE_ENV_FILE override"

# nothing in the file executes
write_env 600 'BPP_DB_STAGING=$(touch pwned)
BPP_DB_DEVELOPMENT="`touch pwned`"
'
mkdir -p "$TMP/cwd"
( cd "$TMP/cwd" && . "$LIB" && get_secret staging && get_secret development ) > "$TMP/out" 2>&1
assert_eq no "$( [ -e "$TMP/cwd/pwned" ] || [ -e "$HOME/pwned" ] && echo yes || echo no)" "envfile: command substitution not executed"
assert_eq '$(touch pwned)' "$(head -n 1 "$TMP/out")" "envfile: value returned literally"

# keychain: hanging security stub is cut off by the timeout
cat > "$TMP/bin/security" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$TMP/bin/security"
start=$(date +%s)
( PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain BPP_KEYCHAIN_TIMEOUT=1; export PATH BPP_RELEASE_SECRETS BPP_KEYCHAIN_TIMEOUT
  . "$LIB" && get_secret staging ) > /dev/null 2> "$TMP/err"
RC=$?
took=$(( $(date +%s) - start ))
assert_eq 5 "$RC" "keychain: hanging security gives status 5"
assert_eq yes "$( [ "$took" -le 3 ] && echo yes || echo no)" "keychain: returns within 3 s (took ${took}s)"

# keychain: value returned; argv checked
cat > "$TMP/bin/security" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_ARGS"
printf 'Host=k;Password=kc1\n'
STUB
export STUB_ARGS="$TMP/args"
OUT=$( (PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain; export PATH BPP_RELEASE_SECRETS; . "$LIB" && get_secret development) 2>/dev/null)
assert_eq 'Host=k;Password=kc1' "$OUT" "keychain: value returned"
assert_eq 'find-generic-password -s bpp-db-development -a bpp -w' "$(cat "$TMP/args")" "keychain: security called with service and account"

OUT=$( (PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain; export PATH BPP_RELEASE_SECRETS; . "$LIB" && get_secret staging document-analysis) 2>/dev/null)
assert_eq 'Host=k;Password=kc1' "$OUT" "keychain document-analysis: value returned"
assert_eq 'find-generic-password -s bpp-db-document-analysis-staging -a bpp -w' "$(cat "$TMP/args")" "keychain document-analysis: own service name"

# keychain: item not found (security exit 44) gives 3, denied gives 5
printf '#!/usr/bin/env bash\nexit 44\n' > "$TMP/bin/security"
( PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain; export PATH BPP_RELEASE_SECRETS; . "$LIB" && get_secret staging ) >/dev/null 2>&1
assert_eq 3 "$?" "keychain: item not found gives status 3"
ERR=$( (PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain; export PATH BPP_RELEASE_SECRETS; . "$LIB" && get_secret development document-analysis) 2>&1 >/dev/null)
assert_contains 'bpp-db-document-analysis-development not found' "$ERR" "keychain document-analysis: not-found error names the entry"
printf '#!/usr/bin/env bash\nexit 51\n' > "$TMP/bin/security"
( PATH="$TMP/bin:$PATH" BPP_RELEASE_SECRETS=keychain; export PATH BPP_RELEASE_SECRETS; . "$LIB" && get_secret staging ) >/dev/null 2>&1
assert_eq 5 "$?" "keychain: denied gives status 5"

# backend from uname when BPP_RELEASE_SECRETS is unset
printf '#!/usr/bin/env bash\necho Darwin\n' > "$TMP/bin/uname"
printf '#!/usr/bin/env bash\necho Host=mac\n' > "$TMP/bin/security"
chmod +x "$TMP/bin/uname"
OUT=$( (PATH="$TMP/bin:$PATH"; export PATH; unset BPP_RELEASE_SECRETS; . "$LIB" && get_secret staging) 2>/dev/null)
assert_eq 'Host=mac' "$OUT" "backend: Darwin uses keychain"
printf '#!/usr/bin/env bash\necho Linux\n' > "$TMP/bin/uname"
write_env 600 'BPP_DB_STAGING="Host=lin"
'
OUT=$( (PATH="$TMP/bin:$PATH"; export PATH; unset BPP_RELEASE_SECRETS; . "$LIB" && get_secret staging) 2>/dev/null)
assert_eq 'Host=lin' "$OUT" "backend: non-Darwin uses envfile"

finish
