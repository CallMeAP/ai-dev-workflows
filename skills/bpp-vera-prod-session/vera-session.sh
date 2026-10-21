#!/usr/bin/env bash
# VERA PROD session on the bpp-vera-connector MAIN CHECKOUT (read-only against PROD VERA).
# Credential values are never printed. Sourced by bpp-vera-keyword-audit/vera-audit.sh for the shared functions.
#
#   vera-session.sh resolve <sel>              which creds.csv row <sel> picks (ids + tenant name only)
#   vera-session.sh status                     which row is in VeraDebugTestConsts.cs and in bin/ now + consts == backup?
#   vera-session.sh preflight                  write gates + PROD + cert + main checkout + backup (exit 1 = unsafe)
#   vera-session.sh routes                     GET allowlist and write-route denylist derived from the controllers
#   vera-session.sh poll --dry-run <paths>     validate a paths file against the GET guard (no network)
#   vera-session.sh use <sel> [paths]          preflight -> swap -> build -> Phase1 smoke [-> App + GET polls];
#                                              ALWAYS restores consts + rebuilds + leak-checks on exit/abort
#   vera-session.sh swap <sel>                 preflight + swap only (NO auto-restore: follow with restore)
#   vera-session.sh restore                    put the original consts back, verify with cmp
#
# <sel>: go_user_id (that broker) | tenant_id (oldest broker, user_idx=1) | T<tenant_idx> (same) | <idx> (row)
# <paths>: one request per line, "GET /api/debug/vera/<route>[?query]"; '#' comments and blank lines ignored.
# Effective config = appsettings.json + appsettings.local.json ONLY (ASPNETCORE_ENVIRONMENT=local is forced).
set -uo pipefail

# Fixed paths, never taken from the environment (a stray MAIN/APP/CONSTS/PORT must not redirect a swap or a poll).
MAIN=/home/alex/Entwicklung/bpp/bpp-vera-connector
SLN=$MAIN/BPP.VeraConnector.NET
APP=$SLN/BPP.VeraConnector.NET.App
CONSTS=$SLN/BPP.VeraConnector.NET.Vera/Consts/VeraDebugTestConsts.cs
TESTS=$SLN/BPP.VeraConnector.NET.Integration.Tests/BPP.VeraConnector.NET.Integration.Tests.csproj
AUDIT=$HOME/Downloads/.vera-audit
CREDS=$AUDIT/creds.csv
BACKUP=$AUDIT/VeraDebugTestConsts.cs.orig
SESSION=$AUDIT/session
PORT=5246   # applicationUrl of the App's "http" launch profile
# LOG/STATE: a sourcing script (vera-audit.sh) may set its own; standalone always uses the session dirs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then LOG=$SESSION/logs; STATE=$SESSION/.ratelimit; fi
: "${LOG:=$SESSION/logs}"
: "${STATE:=$SESSION/.ratelimit}"
RETRY_WAIT=${RETRY_WAIT:-30}
# Rate limiting toward VERA (all probe GETs go through get()):
MIN_INTERVAL_MS=${MIN_INTERVAL_MS:-1500}   # min gap between two probe GETs
MAX_RETRIES=${MAX_RETRIES:-3}              # per GET on 429/5xx/timeout, exponential backoff
BACKOFF_BASE=${BACKOFF_BASE:-5}            # seconds; 5, 10, 20 ... capped at BACKOFF_MAX
BACKOFF_MAX=${BACKOFF_MAX:-120}
MAX_CALLS_PER_ROW=${MAX_CALLS_PER_ROW:-200} # hard budget of probe GETs per row / session
MAX_CALLS_TOTAL=${MAX_CALLS_TOTAL:-6000}    # hard budget per invocation; abort when reached

umask 077
mkdir -p "$LOG" "$STATE"

export ASPNETCORE_ENVIRONMENT=local
unset DOTNET_ENVIRONMENT
for v in $(env | cut -d= -f1 | grep -iE '^(FeatureTogglesVeraSync|VeraIntegrationTesting)__'); do unset "$v"; done

die() { echo "ABORT: $*" >&2; exit 1; }

preflight() {
  [[ "$(pwd -P)" != *worktrees* ]] || die "running inside a worktree"
  [[ "${ASPNETCORE_ENVIRONMENT}" == "local" ]] || die "ASPNETCORE_ENVIRONMENT is not local"
  if env | grep -qiE '^(FeatureTogglesVeraSync|VeraIntegrationTesting)__'; then die "env var overrides a VERA gate"; fi
  python3 -I - "$APP" <<'PY' || exit 1
import json, sys
app = sys.argv[1]
base = json.load(open(f"{app}/appsettings.json"))
loc = json.load(open(f"{app}/appsettings.local.json"))
def eff(sec, key):
    v = loc.get(sec, {}).get(key)
    return v if v is not None else base.get(sec, {}).get(key)
ew = eff("FeatureTogglesVeraSync", "EnableWriteAccess")
wt = eff("VeraIntegrationTesting", "VeraWriteTestsEnabled")
# appsettings.local.json itself must pin both gates to false (it is the last JSON source for env=local)
lew = loc.get("FeatureTogglesVeraSync", {}).get("EnableWriteAccess")
lwt = loc.get("VeraIntegrationTesting", {}).get("VeraWriteTestsEnabled")
print(f"preflight: EnableWriteAccess={ew} VeraWriteTestsEnabled={wt} (appsettings.local.json: {lew}/{lwt}) env=local")
if ew is not False or wt is not False or lew is not False or lwt is not False:
    print("REFUSE: a VERA write gate is not explicitly false in appsettings.local.json"); sys.exit(1)
PY
}

preflight_session() { # preflight + PROD target, mTLS cert, main checkout on development, backup, nothing staged
  preflight || exit 1
  local gd cd top br staged
  gd=$(git -C "$MAIN" rev-parse --absolute-git-dir 2>/dev/null); cd=$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  top=$(git -C "$MAIN" rev-parse --show-toplevel 2>/dev/null); br=$(git -C "$MAIN" branch --show-current 2>/dev/null)
  staged=$(git -C "$MAIN" diff --cached --name-only | grep -cE 'VeraDebugTestConsts\.cs|appsettings\.local\.json|WebApplicationFactory')
  python3 -I - "$APP" "$CREDS" "$BACKUP" "$CONSTS" "$([[ "$gd" == "$cd" && "$top" == "$MAIN" ]] && echo 1)" "$br" "$staged" <<'PY' || exit 1
import filecmp, json, os, stat, sys
app, creds, backup, consts, main_ok, branch, staged = sys.argv[1:8]
base = json.load(open(f"{app}/appsettings.json")).get("Vera", {})
loc = json.load(open(f"{app}/appsettings.local.json")).get("Vera", {})
eff = lambda k: loc.get(k) if loc.get(k) is not None else base.get(k)
def prod(u): u = str(u or "").lower(); return bool(u) and "dmz211" not in u and "uniquare" not in u
cert = eff("ClientCertificateFileName") or "gobrokernet.p12"
checks = {
    "main_checkout": main_ok == "1",
    "branch_development": branch == "development",
    "vera_points_to_prod": prod(eff("ApiBaseUrl")) and prod(eff("ApiTokenBaseUrl")),
    "mtls_cert_present": os.path.isfile(f"{app}/Certificates/{cert}"),
    "cert_password_set": bool(str(eff("ClientCertificatePassword") or "").strip()),
    "creds_csv_mode_600": os.path.isfile(creds) and stat.S_IMODE(os.stat(creds).st_mode) == 0o600,
    "backup_consistent": not os.path.isfile(backup) or filecmp.cmp(backup, consts, shallow=False),
    "no_cred_file_staged": staged == "0",
}
print("preflight-session: " + " ".join(f"{k}={v}" for k, v in checks.items()))
bad = [k for k, v in checks.items() if not v]
if bad:
    print("REFUSE: " + ", ".join(bad)
          + (" (backup differs from consts: a swap is still in place or the backup is stale - run status, resolve by hand)"
             if "backup_consistent" in bad else "")); sys.exit(1)
PY
}

resolve() { # resolve <sel> -> prints "idx=.. tenant_idx=.. user_idx=.. tenant_name=.. go_user_id=.."; exit 1 on no/ambiguous match
  python3 -I - "$CREDS" "$1" <<'PY'
import csv, re, sys
creds, sel = sys.argv[1], sys.argv[2].strip()
rows = list(csv.DictReader(open(creds, newline="")))
uuid = re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", sel)
if uuid:
    s = sel.lower()
    by_user = [r for r in rows if r["go_user_id"].strip().lower() == s]
    by_tenant = [r for r in rows if r["tenant_id"].strip().lower() == s]
    if by_user and by_tenant: sys.exit("ABORT: selector matches a go_user_id and a tenant_id")
    if not by_user and not by_tenant:
        sys.exit(f"ABORT: no creds.csv row with that go_user_id or tenant_id ({len(rows)} rows; re-export if the broker is new)")
    if by_user:
        hits, kind = by_user, "go_user_id"
    else:
        hits, kind = [r for r in by_tenant if r["user_idx"] == "1"], "tenant_id (oldest broker)"
        if by_tenant and not hits: sys.exit("ABORT: tenant found but it has no user_idx=1 row")
elif re.fullmatch(r"[Tt]\d+", sel):
    hits, kind = [r for r in rows if r["tenant_idx"] == sel[1:] and r["user_idx"] == "1"], "tenant_idx (oldest broker)"
elif re.fullmatch(r"\d+", sel):
    hits, kind = [r for r in rows if r["idx"] == sel], "row idx"
else:
    sys.exit("ABORT: selector must be a go_user_id/tenant_id UUID, T<tenant_idx> or a row idx")  # never echo it
if not hits: sys.exit(f"ABORT: no creds.csv row for that {kind} ({len(rows)} rows; re-export if the broker is new)")
if len(hits) > 1:
    sys.exit("ABORT: ambiguous, rows " + ", ".join(r["idx"] for r in hits) + f" match that {kind}: pick one by row idx")
r = hits[0]
print(f"idx={r['idx']} tenant_idx={r['tenant_idx']} user_idx={r['user_idx']} tenant_name={r['tenant_name']} "
      f"go_user_id={r['go_user_id']} (by {kind})")
PY
}

sel_idx() { # sel_idx <sel> -> row idx on stdout (resolve line on stderr)
  local line; line=$(resolve "$1") || exit 1
  echo "$line" >&2; line=${line#idx=}; echo "${line%% *}"
}

swap() { # swap <row idx>
  local idx=$1
  [[ -f "$BACKUP" ]] || { cp -p "$CONSTS" "$BACKUP"; chmod 600 "$BACKUP"; }
  python3 -I - "$CREDS" "$idx" "$CONSTS" <<'PY' || die "swap failed for row $idx"
import csv, re, sys
creds, idx, path = sys.argv[1:4]
row = next((r for r in csv.DictReader(open(creds, newline="")) if r["idx"] == idx), None)
if row is None: sys.exit(f"row {idx} not found")
mapping = {"VeraUsername": "vera_username", "VeraPassword": "vera_password", "VeraApiKey": "vera_api_key",
           "VeraClientSecret": "vera_client_secret", "VeraClientId": "vera_client_id",
           "VeraUserToken": "vera_user_token"}
src = open(path, encoding="utf-8").read()
for const, column in mapping.items():
    value = row[column].strip()
    if '"' in value or "\\" in value or "\n" in value: sys.exit(f"{const}: value needs escaping")
    pattern = re.compile(r'(const\s+string\s+' + const + r'\s*=\s*)(@?"[^"\n]*")(\s*;)')
    if len(pattern.findall(src)) != 1: sys.exit(f"{const}: expected exactly one declaration")
    src = pattern.sub(lambda m: m.group(1) + '"' + value + '"' + m.group(3), src)
open(path, "w", encoding="utf-8").write(src)
print(f"swapped row {idx} (tenant_idx={row['tenant_idx']} user_idx={row['user_idx']})")
PY
}

restore() {
  [[ -f "$BACKUP" ]] || { echo "no backup, nothing to restore"; return 0; }
  # no -p: the restored file must be newer than obj/, or MSBuild skips CoreCompile and bin/ keeps the swapped creds
  cp "$BACKUP" "$CONSTS" && echo "restored original VeraDebugTestConsts.cs"
}

verify_restored() { # prints only restored / DIFFERS
  if cmp -s "$BACKUP" "$CONSTS"; then echo "restored"; else echo "DIFFERS"; return 1; fi
}

status() { # which creds.csv row the consts and the compiled bin/ hold (idx/tenant_name/go_user_id only) + consts == backup
  python3 -I - "$CREDS" "$CONSTS" "$SLN" <<'PY'
import csv, glob, re, sys
creds, consts, sln = sys.argv[1:4]
mapping = {"VeraUsername": "vera_username", "VeraPassword": "vera_password", "VeraApiKey": "vera_api_key",
           "VeraClientSecret": "vera_client_secret", "VeraClientId": "vera_client_id", "VeraUserToken": "vera_user_token"}
src = open(consts, encoding="utf-8").read()
cur = {}
for const, column in mapping.items():
    m = re.search(r'const\s+string\s+' + const + r'\s*=\s*@?"([^"\n]*)"\s*;', src)
    cur[column] = m.group(1).strip() if m else None
rows = list(csv.DictReader(open(creds, newline="")))
hits = [r for r in rows if all((r[c] or "").strip() == v for c, v in cur.items())]
if not hits: print("consts: no creds.csv row (original/local creds or a stale export)")
for r in hits: print(f"consts: row idx={r['idx']} tenant_idx={r['tenant_idx']} user_idx={r['user_idx']} "
                     f"tenant_name={r['tenant_name']} go_user_id={r['go_user_id']}")
# bin/: const strings are inlined (UTF-16LE user-string heap) into every assembly that uses them
def has(blob, vals): return all(v and v.encode("utf-16le") in blob for v in vals)
states = {}
for dll in sorted(glob.glob(f"{sln}/*/bin/Debug/*/BPP.VeraConnector*.dll")):
    blob = open(dll, "rb").read()
    if has(blob, cur.values()): st = "the current consts"
    else:
        rs = [r["idx"] for r in rows if has(blob, [(r[c] or "").strip() for c in mapping.values()])]
        if not rs: continue  # assembly does not embed the consts
        st = "creds.csv row(s) " + ",".join(rs) + " - NOT the current consts (stale build output: rebuild, or delete an orphan bin/)"
    states[st] = states.get(st, 0) + 1
if not states: print("bin: no built assembly embeds the current consts or a creds.csv row")
for st, n in states.items(): print(f"bin: {n} assembl{'y' if n == 1 else 'ies'} embed {st}")
PY
  if [[ ! -f "$BACKUP" ]]; then echo "backup: none"
  elif cmp -s "$BACKUP" "$CONSTS"; then echo "backup: consts == backup (original in place)"
  else echo "backup: consts DIFFER from backup (a swap is in place - run restore)"; fi
}

leak_check() { # leak_check <idx> <path>...: files holding a cred value of row <idx> (names only); exit 1 on a hit
  python3 -I - "$CREDS" "$BACKUP" "$@" <<'PY'
import csv, os, sys
creds, backup, idx, paths = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
COLS = ("vera_username", "vera_password", "vera_api_key", "vera_client_secret", "vera_client_id", "vera_user_token")
row = next((r for r in csv.DictReader(open(creds, newline="")) if r["idx"] == idx), None)
if row is None: sys.exit("leak-check: row not found")
orig = open(backup, "rb").read() if os.path.isfile(backup) else b""
# values shorter than 6 chars prove nothing; values also in the original consts are expected in bin/ after restore
needles = {v: c for c in COLS for v in [(row[c] or "").strip()] if len(v) >= 6 and v.encode() not in orig}
files = []
for p in paths:
    if os.path.isfile(p): files.append(p)
    for d, _, fs in os.walk(p):
        files += [os.path.join(d, f) for f in fs]
hits, n = set(), 0
for f in files:
    if f.endswith(".dll") and not os.path.basename(f).startswith("BPP.VeraConnector"): continue
    if os.path.getsize(f) > 64 << 20: continue
    blob = open(f, "rb").read(); n += 1
    for v, c in needles.items():
        if v.encode() in blob or v.encode("utf-16le") in blob: hits.add((c, f))
for c, f in sorted(hits): print(f"leak-check HIT {c}: {f}  (do not open; tell the user)")
print(f"leak-check: {n} file(s), {len(needles)} value(s) of row {idx}, {len(hits)} hit(s)")
sys.exit(1 if hits else 0)
PY
}

build() {
  dotnet build "$SLN/BPP.VeraConnector.sln" -c Debug -v q -nologo >"$LOG/build-$1.log" 2>&1 \
    || { echo "build failed (see $LOG/build-$1.log)"; return 1; }
}

smoke_once() {
  preflight >/dev/null || exit 1
  dotnet test "$TESTS" -c Debug --no-build --filter "FullyQualifiedName~Phase1_Smoke" \
    --logger "console;verbosity=minimal" >"$LOG/smoke-$1-$2.log" 2>&1
}

smoke() {
  local idx=$1
  if smoke_once "$idx" 1; then echo ok; return 0; fi
  sleep "$RETRY_WAIT"
  if smoke_once "$idx" 2; then echo ok-retry; return 0; fi
  echo failed; return 1
}

app_start() {
  ss -ltn "sport = :$PORT" | grep -q LISTEN && die "port $PORT already in use"
  preflight >/dev/null || exit 1
  (cd "$APP" && exec dotnet run --no-build --launch-profile http >"$LOG/app-$1.log" 2>&1) &
  APP_PID=$!
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "http://localhost:$PORT/" && return 0
    sleep 2
  done
  die "App did not start (see $LOG/app-$1.log)"
}

app_stop() {
  [[ -n "${APP_PID:-}" ]] || return 0
  pkill -P "$APP_PID" 2>/dev/null; kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
  for _ in $(seq 1 15); do ss -ltn "sport = :$PORT" | grep -q LISTEN || break; sleep 1; done
  APP_PID=
}

throttle() { # wait until MIN_INTERVAL_MS has passed since the last probe GET (persists across rows)
  local now last wait_ms
  now=$(date +%s%3N); last=$(cat "$STATE/last" 2>/dev/null || echo 0)
  wait_ms=$(( last + MIN_INTERVAL_MS - now ))
  (( wait_ms > 0 )) && sleep "$(awk -v m="$wait_ms" 'BEGIN{printf "%.3f", m/1000}')"
  date +%s%3N >"$STATE/last"
}

count_call() { # enforce per-row and total call budgets
  local row total
  row=$(( $(cat "$STATE/row" 2>/dev/null || echo 0) + 1 )); echo "$row" >"$STATE/row"
  total=$(( $(cat "$STATE/total" 2>/dev/null || echo 0) + 1 )); echo "$total" >"$STATE/total"
  (( total > MAX_CALLS_TOTAL )) && die "total VERA call budget ($MAX_CALLS_TOTAL) reached"
  (( row > MAX_CALLS_PER_ROW )) && { echo "row call budget ($MAX_CALLS_PER_ROW) reached" >>"$LOG/http-errors.log"; return 1; }
  return 0
}

get() { # get <url> <outfile> ; GET only, rate limited, backoff on 429/5xx (honours Retry-After)
  local code attempt=0 delay hdr ra
  hdr=$(mktemp)
  while :; do
    count_call || { rm -f "$hdr"; return 1; }
    throttle
    # -g: no URL globbing, or "[1-500]" / "{a,b}" in a URL would fan out into many requests past throttle + budget
    code=$(curl -sg -D "$hdr" -o "$2" -w '%{http_code}' --max-time 120 "$1")
    [[ "$code" == 200 ]] && { rm -f "$hdr"; return 0; }
    attempt=$((attempt + 1))
    if [[ "$code" != 429 && "$code" != 5* && "$code" != 000 ]] || (( attempt > MAX_RETRIES )); then
      echo "GET $1 -> $code (attempts $attempt)" >>"$LOG/http-errors.log"; rm -f "$hdr"; return 1
    fi
    delay=$(( BACKOFF_BASE * (1 << (attempt - 1)) )); (( delay > BACKOFF_MAX )) && delay=$BACKOFF_MAX
    ra=$(awk 'tolower($1)=="retry-after:"{gsub("\r","",$2); print $2}' "$hdr")
    [[ "$ra" =~ ^[0-9]+$ ]] && (( ra > delay )) && delay=$ra
    echo "GET $1 -> $code, backoff ${delay}s (attempt $attempt)" >>"$LOG/http-backoff.log"
    sleep "$delay"
  done
}

# --- GET guard: allowlist + denylist derived from the controllers of the main checkout ---------------------------
guard() { # guard <routes|check> [paths-file]: check prints ALLOW/REFUSE per line, exit 1 if any line is refused
  python3 -I - "$SLN/BPP.VeraConnector.NET.Vera" "$@" <<'PY'
import glob, re, sys
root, mode = sys.argv[1], sys.argv[2]
PREFIX = "api/debug/vera"            # only the unauthenticated debug read controllers are pollable
EXTRA_DENY = {"health-manual"}       # takes credentials in the query string
CRED_PARAM = re.compile(r"(pass|secret|token|apikey|api_key|username|clientid|client_id)", re.I)
# path: no %, [], {}, backslash (encoded traversal, curl globs); query: plain key=value pairs
URL_SHAPE = re.compile(r"/[A-Za-z0-9._~/-]+(\?[A-Za-z0-9._~%=&+,:-]*)?")
VERB = re.compile(r'\[Http(Get|Post|Put|Delete|Patch)(?:\("([^"]*)"\))?\]')
gets, writes = [], []
for f in sorted(glob.glob(f"{root}/**/*Controller.cs", recursive=True)):
    if "/obj/" in f or "/bin/" in f: continue
    src = open(f, encoding="utf-8").read()
    m = re.search(r'\[Route\("([^"]*)"\)\]\s*(?:\[[^\]]*\]\s*)*public\s+(?:sealed\s+)?class', src)
    prefix = m.group(1).strip("/") if m else ""
    for verb, tpl in VERB.findall(src):
        tpl = (tpl or "").strip("/")
        (gets if verb == "Get" else writes).append((prefix, tpl, verb.upper(), f.rsplit("/", 1)[-1]))
def pat(tpl): return "/".join("[^/]+" if re.fullmatch(r"\{[^}]+\}", seg) else re.escape(seg) for seg in tpl.split("/"))
def rx(tpl): return re.compile("^" + pat(tpl) + "$")
allow = [rx(t) for p, t, _, _ in gets if p == PREFIX and t not in EXTRA_DENY]
get_shapes = {(p, re.sub(r"\{[^}]+\}", "{}", t)) for p, t, _, _ in gets}
# write-only routes: a non-GET template without a GET twin of the same shape (GET twins stay pollable)
deny = sorted({(p, t, v, c) for p, t, v, c in writes if (p, re.sub(r"\{[^}]+\}", "{}", t)) not in get_shapes})
deny_rx = [(rx(t), p, t, v, c) for p, t, v, c in deny if t]
if mode == "routes":
    print(f"ALLOW (GET under /{PREFIX}/, {len(allow)} routes):")
    for p, t, _, c in gets:
        if p == PREFIX and t not in EXTRA_DENY: print(f"  GET /{p}/{t}")
    print(f"DENY (write-only routes, {len(deny)} + {sorted(EXTRA_DENY)}):")
    for p, t, v, c in deny: print(f"  {v} {('/' + p) if p else '<BaseController>'}/{t}  [{c}]")
    sys.exit(0)
bad = 0
lines = [l.strip() for l in open(sys.argv[3], encoding="utf-8")]
reqs = [l for l in lines if l and not l.startswith("#")]
if not reqs: print("REFUSE: paths file has no requests"); sys.exit(1)
for n, line in enumerate(reqs, 1):
    parts = line.split()
    why, path = None, ""
    if len(parts) != 2: why = 'expected "GET /api/debug/vera/<route>[?query]"'
    else:
        method, url = parts[0].upper(), parts[1]
        path, _, query = url.partition("?")
        path = path.strip("/")
        if method != "GET": why = f"method {method} (GET only)"
        elif not URL_SHAPE.fullmatch(url): why = "URL must be /path[?query] of plain characters (no %, [], {} or backslash in the path)"
        elif ".." in path or "//" in url: why = "path traversal / empty segment"
        elif any(CRED_PARAM.search(kv.split("=", 1)[0]) for kv in query.split("&") if kv): why = "credential-like query parameter"
        elif path.rsplit("/", 1)[-1] in EXTRA_DENY or any(path.startswith(PREFIX + "/" + x) for x in EXTRA_DENY):
            why = "denylisted route (takes credentials)"
        else:
            tail = path[len(PREFIX) + 1:] if path.startswith(PREFIX + "/") else None
            for r, p, t, v, c in deny_rx:
                cand = (tail if p == PREFIX else path) or ""
                if r.match(cand) or (p != PREFIX and re.search("(^|/)" + pat(t) + "$", path)):
                    why = f"write route {v} {t} [{c}]"; break
            if not why:
                if tail is None: why = f"not under /{PREFIX}/"
                elif not any(r.match(tail) for r in allow): why = "no matching GET route in the debug controllers"
    shown = line if len(parts) == 2 else "<malformed>"
    if why and "credential" in why: shown = f"{parts[0]} /{path}?<redacted>"   # never echo a cred-like query
    print(f"{'REFUSE' if why else 'ALLOW '} {n:3}: {shown}" + (f"  ({why})" if why else ""))
    bad += bool(why)
print(f"{len(reqs)} request(s), {bad} refused")
sys.exit(1 if bad else 0)
PY
}

poll() { # poll <paths-file> <outdir>: guarded, rate-limited GETs against the local App
  local n=0 method url slug paths=$2/paths.txt
  cp "$1" "$paths" || die "cannot copy the paths file"   # guard and loop read the same snapshot
  guard check "$paths" >"$2/guard.txt" || { cat "$2/guard.txt"; die "GET guard refused the paths file"; }
  echo 0 >"$STATE/row"
  while read -r method url; do
    [[ -z "$method" || "$method" == \#* ]] && continue
    n=$((n + 1)); slug=$(printf '%02d-%s' "$n" "$(echo "${url#/api/debug/vera/}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)")
    if get "http://localhost:$PORT$url" "$2/$slug.json"; then echo "ok   $method $url -> $2/$slug.json"
    else echo "FAIL $method $url (see $LOG/http-errors.log)"; fi
  done <"$paths"
}

session_cleanup() { # EXIT trap of use: stop App, restore, rebuild, leak-check (globals only: locals are gone here)
  app_stop; restore >/dev/null; echo "consts: $(verify_restored)"
  if [[ -n "$BUILT" ]]; then
    if build restore; then echo "rebuilt with original consts"
    else echo "WARNING: rebuild after restore failed: bin/ still holds the swapped creds"; fi
  fi
  [[ -n "$S_IDX" ]] && leak_check "$S_IDX" "$S_OUT" "$LOG" "$SLN"/*/bin/Debug
}

use_session() { # use_session <sel> [paths-file]
  local sel=$1 paths=${2:-} s
  if [[ -n "$paths" ]]; then guard check "$paths" >/dev/null || { guard check "$paths"; die "GET guard refused $paths"; }; fi
  preflight_session || exit 1
  S_IDX=$(sel_idx "$sel") || exit 1
  S_OUT=$SESSION/out/$(date +%Y%m%d-%H%M%S)-row$S_IDX; mkdir -p "$S_OUT"
  echo 0 >"$STATE/total"   # MAX_CALLS_TOTAL is per invocation
  BUILT=
  trap session_cleanup EXIT
  trap 'exit 130' INT TERM HUP
  swap "$S_IDX" || exit 1
  BUILT=1; build "$S_IDX" || exit 1
  s=$(smoke "$S_IDX") || die "Phase1 smoke $s (see $LOG/smoke-$S_IDX-*.log): VPN / cert / creds of row $S_IDX"
  echo "smoke: $s"
  [[ -n "$paths" ]] || return 0
  app_start "$S_IDX"
  poll "$paths" "$S_OUT"
  echo "output: $S_OUT"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0   # sourced: functions only

SELF=$(realpath "$0")
case "${1:-}" in # no main checkout cwd needed
  resolve) [[ -n "${2:-}" ]] || die "resolve <sel>"; resolve "$2"; exit $? ;;
  status) status; exit 0 ;;
  routes) guard routes; exit $? ;;
  poll) [[ "${2:-}" == --dry-run && -n "${3:-}" ]] || die "only 'poll --dry-run <paths>' runs standalone; live polls go through 'use <sel> <paths>'"
    guard check "$3"; exit $? ;;
  use) PATHS_FILE=; if [[ -n "${3:-}" ]]; then PATHS_FILE=$(realpath -e -- "$3") || die "paths file not found"; fi ;;
esac

cd "$MAIN" || die "main checkout missing"
case "${1:-}" in
  preflight) preflight_session ;;
  use) [[ -n "${2:-}" ]] || die "use <sel> [paths]"; use_session "$2" "$PATHS_FILE" ;;
  swap) [[ -n "${2:-}" ]] || die "swap <sel>"; preflight_session || exit 1; idx=$(sel_idx "$2") || exit 1
    swap "$idx" && echo "NOTE: creds stay swapped until 'restore' (then build once: bin/ embeds the consts)" ;;
  restore) restore; verify_restored ;;
  *) sed -n 2,17p "$SELF"; exit 1 ;;
esac
