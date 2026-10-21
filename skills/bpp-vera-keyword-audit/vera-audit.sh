#!/usr/bin/env bash
# VERA keyword audit driver (read-only against PROD VERA).
#
#   vera-audit.sh preflight          write gates + environment check (exit 1 = unsafe)
#   vera-audit.sh swap <idx>         put cred row <idx> into VeraDebugTestConsts.cs (backs up the original once)
#   vera-audit.sh restore            put the original VeraDebugTestConsts.cs back
#   vera-audit.sh run <idx> [inv]    swap + build + smoke (1 retry) + catalog fingerprint [+ inventory];
#                                    updates that row in out/results.tsv, restores the original consts at the end
#   vera-audit.sh refetch <idx>      swap + build + inventory only (re-fetch after VERA 500s); restores at the end
#   vera-audit.sh run-all            run every row (refuses while out/ holds a previous audit); one inventory per tenant (first user whose smoke is green);
#                                    restores the original consts at the end, also on abort
#   vera-audit.sh check-fingerprints per tenant: do all users see one catalog? (exit 1 = mismatch, 2 = unverified rows)
#   vera-audit.sh manifest           write out/manifest.json: one inventory row per tenant + contract sample status
#                                    (exit 1 = a tenant has no inventory row)
#   check-fingerprints and manifest only read out/results.tsv, out/row-*/ and logs/skipped-*.log (no VERA calls).
#
# Credential values are never printed. Effective config = appsettings.json + appsettings.local.json ONLY
# (ASPNETCORE_ENVIRONMENT=local is forced; any env override of the gates aborts).
set -uo pipefail

SELF=$(realpath "$0")
AUDIT=$HOME/Downloads/.vera-audit
OUT=$AUDIT/out
LOG=$AUDIT/logs
STATE=$AUDIT/.ratelimit
PORT=5246
BASE=http://localhost:$PORT/api/debug/vera
ROW_COOLDOWN=${ROW_COOLDOWN:-15}           # pause between two cred rows (smoke burst + catalog)
SMOKE_COOLDOWN=${SMOKE_COOLDOWN:-10}       # pause after a smoke run before the catalog fetch

# Shared with bpp-vera-prod-session: paths (MAIN, SLN, APP, CONSTS, TESTS, CREDS, BACKUP), rate-limit env vars,
# forced env=local, die, preflight, swap, restore, build, smoke_once, smoke, app_start, app_stop, throttle,
# count_call, get. Paths and PORT are fixed there; the library honours LOG/STATE set above.
# shellcheck source=../bpp-vera-prod-session/vera-session.sh
source "$(dirname "$SELF")/../bpp-vera-prod-session/vera-session.sh" || { echo "ABORT: shared vera-session.sh missing" >&2; exit 1; }
mkdir -p "$OUT" "$LOG" "$STATE"

catalog() { # catalog <idx> -> writes $OUT/row-<idx>/catalog.json + prints fingerprint
  local idx=$1 t p; local dir=$OUT/row-$idx
  rm -rf "$dir/raw"; mkdir -p "$dir/raw"   # stale pages of an earlier fetch would enter the fingerprint
  for t in section division bundle product; do
    p=1
    while :; do
      get "$BASE/search-products-vera?productType=$t&size=100&page=$p" "$dir/raw/$t-$p.json" || return 1
      python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if len(d.get("items") or [])==100 else 1)' "$dir/raw/$t-$p.json" || break
      p=$((p+1)); [[ $p -le 50 ]] || break
    done
  done
  python3 - "$dir" <<'PY'
import glob, hashlib, json, os, sys
d = sys.argv[1]
nodes = {}
for f in glob.glob(f"{d}/raw/*.json"):
    for it in json.load(open(f)).get("items") or []:
        nodes[it["productId"]] = {k: it.get(k) for k in
            ("productId", "parentProductId", "productName", "productNo", "productSectionId", "productType", "isActive")}
rows = sorted(nodes.values(), key=lambda n: n["productId"])
json.dump(rows, open(f"{d}/catalog.json", "w"), ensure_ascii=False, indent=1)
fp = hashlib.sha256("\n".join("|".join(str(n[k]) for k in ("productId","productNo","productName","productType","parentProductId")) for n in rows).encode()).hexdigest()
open(f"{d}/catalog.sha256", "w").write(fp)
print(f"{len(rows)} {fp}")
PY
}

inventory() { # inventory <idx> -> doc types, compact contracts, enum-value counts (no customer data saved)
  local idx=$1 p; local dir=$OUT/row-$idx
  mkdir -p "$dir/tmp"
  : >"$LOG/skipped-$idx.log"   # one inventory per log: a refetch must not double-count skipped tens
  get "$BASE/document-types-vera" "$dir/tmp/doctypes.json" \
    && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));json.dump(d,open(sys.argv[2],"w"),ensure_ascii=False,indent=1)' "$dir/tmp/doctypes.json" "$dir/doctypes.json"
  local k sub
  for p in $(seq 1 20); do
    if get "$BASE/search-contracts-vera?policyNumber=0&size=100&page=$p" "$dir/tmp/c-$p.json"; then
      python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if len(d.get("items") or [])==100 else 1)' "$dir/tmp/c-$p.json" || break
    else
      # VERA returns 500 for a whole page when one record in it is broken: re-read the page in tens, skip bad tens
      rm -f "$dir/tmp/c-$p.json"
      for k in $(seq 1 10); do
        sub=$(( (p - 1) * 10 + k ))
        MAX_RETRIES=1 get "$BASE/search-contracts-vera?policyNumber=0&size=10&page=$sub" "$dir/tmp/c-$p-$k.json" \
          || { rm -f "$dir/tmp/c-$p-$k.json"; echo "skipped contracts $(( (sub - 1) * 10 + 1 ))-$(( sub * 10 )) (VERA 500)" >>"$LOG/skipped-$idx.log"; }
      done
    fi
  done
  for p in 1 2 3 4 5; do
    get "$BASE/search-customers-vera?size=100&page=$p" "$dir/tmp/k-$p.json" || break
  done
  python3 - "$dir" <<'PY'
import collections, glob, json, sys
d = sys.argv[1]
KEEP = ("policyDivisionId", "policyProductId", "insuranceInstituteNumber", "insuranceInstitute", "contractState",
        "policyDivision", "productName")
rows, total = [], None
for f in sorted(glob.glob(f"{d}/tmp/c-*.json")):
    j = json.load(open(f)); total = j.get("total", total)
    rows += [{k: it.get(k) for k in KEEP if k in it} for it in j.get("items") or []]
json.dump({"total": total, "rows_returned": len(rows), "rows": rows}, open(f"{d}/contracts_compact.json", "w"),
          ensure_ascii=False, indent=0)
ENUM_KEYS = {"gender", "legalForm", "legalform", "rechtsform", "countryCode", "country",
             "vehicleType", "customerType", "personType", "maritalStatus", "nationality", "title"}
counts = collections.defaultdict(collections.Counter)
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ENUM_KEYS and (v is None or isinstance(v, (str, int, bool))): counts[k][str(v)] += 1
            else: walk(v)
    elif isinstance(o, list):
        for x in o: walk(x)
for f in glob.glob(f"{d}/tmp/k-*.json") + glob.glob(f"{d}/tmp/c-*.json"):
    walk(json.load(open(f)))
json.dump({k: dict(c.most_common()) for k, c in counts.items()}, open(f"{d}/enum_values.json", "w"),
          ensure_ascii=False, indent=1)
print(f"contracts={len(rows)}/{total} enum_keys={sorted(counts)}")
PY
  rm -rf "$dir/tmp"
}

run_one() { # run_one <idx> <with_inventory 0|1>  -> one TSV line on stdout
  local idx=$1 inv=${2:-0} s fp="-" n="-"
  preflight >/dev/null || exit 1
  swap "$idx" >/dev/null
  build "$idx" || { echo -e "$idx\tbuild-failed\t-\t-"; return 1; }
  s=$(smoke "$idx") || { echo -e "$idx\tsmoke-$s\t-\t-"; return 1; }
  sleep "$SMOKE_COOLDOWN"
  echo 0 >"$STATE/row"
  app_start "$idx"
  if read -r n fp < <(catalog "$idx"); then
    [[ "$inv" == 1 ]] && inventory "$idx" >"$LOG/inventory-$idx.log" 2>&1
  else
    fp="catalog-failed"
  fi
  app_stop
  echo -e "$idx\tsmoke-$s\t$n\t$fp"
}

update_results() { # update_results <tsv line of run_one>: replace or add that row in out/results.tsv
  python3 - "$OUT/results.tsv" "$CREDS" "$1" <<'PY'
import csv, os, sys
tsv, creds, line = sys.argv[1:4]
idx, st, nodes, fp = line.split("\t")
r = next(r for r in csv.DictReader(open(creds, newline="")) if r["idx"] == idx)
hdr = ["idx", "tenant_idx", "user_idx", "status", "nodes", "fingerprint"]
rows = list(csv.reader(open(tsv, newline=""), delimiter="\t"))[1:] if os.path.isfile(tsv) else []
rows = sorted([x for x in rows if x and x[0] != idx] + [[idx, r["tenant_idx"], r["user_idx"], st, nodes, fp]],
              key=lambda x: int(x[0]))
with open(tsv + ".tmp", "w", newline="") as f:
    csv.writer(f, delimiter="\t", lineterminator="\n").writerows([hdr] + rows)
os.replace(tsv + ".tmp", tsv)
PY
}

run_all() {
  # row dirs of an earlier audit would be read by manifest (idx shifts when GoUsers are added) - start clean
  compgen -G "$OUT/row-*" >/dev/null && die "$OUT holds a previous audit: move out/ and logs/ aside first"
  trap 'app_stop; restore; echo "results: $OUT/results.tsv"' EXIT
  trap 'exit 130' INT TERM
  preflight || exit 1
  # the backup is taken once; if it differs from the consts now, a swap is still in place or the backup is stale
  if [[ -f "$BACKUP" ]] && ! cmp -s "$BACKUP" "$CONSTS"; then
    trap - EXIT; die "backup differs from VeraDebugTestConsts.cs (swap left in place or stale backup): resolve by hand"
  fi
  echo -e "idx\ttenant_idx\tuser_idx\tstatus\tnodes\tfingerprint" >"$OUT/results.tsv"
  declare -A done_inv
  while IFS=, read -r idx tidx uidx; do
    # a budget hit inside run_one only ends that subshell: stop the whole run here (no further smoke runs)
    (( $(cat "$STATE/total" 2>/dev/null || echo 0) >= MAX_CALLS_TOTAL )) && die "total VERA call budget ($MAX_CALLS_TOTAL) reached"
    local inv=0; [[ -z "${done_inv[$tidx]:-}" ]] && inv=1
    line=$(run_one "$idx" "$inv")
    IFS=$'\t' read -r _ st nodes fp <<<"$line"
    [[ "$inv" == 1 && "$st" == smoke-ok* && "$fp" != catalog-failed ]] && done_inv[$tidx]=$idx
    echo -e "$idx\t$tidx\t$uidx\t$st\t$nodes\t$fp" | tee -a "$OUT/results.tsv"
    sleep "$ROW_COOLDOWN"
  done < <(python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1],newline="")): print(r["idx"],r["tenant_idx"],r["user_idx"],sep=",")' "$CREDS")
}

check_fingerprints() { # read-only: out/results.tsv
  python3 - "$OUT/results.tsv" <<'PY'
import collections, csv, sys
rows = list(csv.DictReader(open(sys.argv[1], newline=""), delimiter="\t"))
by = collections.defaultdict(list)
for r in rows: by[int(r["tenant_idx"])].append(r)
mismatch = unverified = False
for t in sorted(by):
    ok = [r for r in by[t] if len(r["fingerprint"]) == 64]
    bad = [r["idx"] for r in by[t] if len(r["fingerprint"]) != 64]
    fps = {r["fingerprint"] for r in ok}
    if len(fps) > 1:
        mismatch = True
        groups = collections.defaultdict(list)
        for r in ok: groups[r["fingerprint"][:12]].append(r["idx"])
        print(f"T{t}: MISMATCH rows by fingerprint {dict(groups)}")
    elif not ok:
        unverified = True; print(f"T{t}: UNVERIFIED no usable fingerprint (rows {bad})")
    else:
        if bad: unverified = True
        print(f"T{t}: ok, {len(ok)} user(s) share {next(iter(fps))[:12]}" + (f", UNVERIFIED rows {bad}" if bad else ""))
rc = 1 if mismatch else 2 if unverified else 0  # a mismatch always wins
print({0: "all tenants consistent", 1: "MISMATCH: stop and report", 2: "unverified rows: re-run them"}[rc])
sys.exit(rc)
PY
}

manifest() { # read-only: out/results.tsv, out/row-*/, logs/skipped-*.log -> writes out/manifest.json
  python3 - "$OUT" "$LOG" <<'PY'
import csv, json, os, sys
out, log = sys.argv[1:3]
rows = list(csv.DictReader(open(f"{out}/results.tsv", newline=""), delimiter="\t"))
manifest, seen, missing = [], {}, []
for t in sorted({int(r["tenant_idx"]) for r in rows}):
    cand = sorted((r for r in rows if int(r["tenant_idx"]) == t and len(r["fingerprint"]) == 64
                   and os.path.isfile(f"{out}/row-{r['idx']}/contracts_compact.json")), key=lambda r: int(r["idx"]))
    if not cand: missing.append(t); continue
    r = cand[0]; d = f"{out}/row-{r['idx']}"; fp = r["fingerprint"]
    c = json.load(open(f"{d}/contracts_compact.json"))
    total, returned = int(c.get("total") or 0), int(c.get("rows_returned") or 0)
    sk = f"{log}/skipped-{r['idx']}.log"
    skipped = 10 * sum(1 for _ in open(sk)) if os.path.isfile(sk) else 0
    expected = min(total, 2000)  # inventory reads at most 20 pages of 100
    manifest.append({"tenant_idx": t, "row": int(r["idx"]), "nodes": int(r["nodes"]), "fingerprint": fp, "dir": d,
                     "same_catalog_as_tenant": seen.get(fp),
                     "contracts": {"total": total, "returned": returned, "skipped": skipped, "expected": expected,
                                   "short": expected - returned - skipped >= 10},
                     "missing_files": [f for f in ("catalog.json", "doctypes.json", "enum_values.json")
                                       if not os.path.isfile(f"{d}/{f}")]})
    seen.setdefault(fp, t)
json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=1)
for m in manifest:
    c = m["contracts"]
    same = f" same_catalog_as=T{m['same_catalog_as_tenant']}" if m["same_catalog_as_tenant"] else ""
    flags = (" SHORT" if c["short"] else "") + (f" missing={m['missing_files']}" if m["missing_files"] else "")
    print(f"T{m['tenant_idx']}: row {m['row']} nodes={m['nodes']} contracts={c['returned']}+{c['skipped']}skipped/{c['expected']}{same}{flags}")
print(f"{len(manifest)} tenants, {len({m['fingerprint'] for m in manifest})} distinct catalogs -> {out}/manifest.json")
for t in missing: print(f"T{t}: MISSING no row with fingerprint + inventory (run <idx> 1 on a green row of it)")
sys.exit(1 if missing else 0)
PY
}

case "${1:-}" in # read-only subcommands: no main checkout, no preflight needed
  check-fingerprints) check_fingerprints; exit $? ;;
  manifest) manifest; exit $? ;;
esac

cd "$MAIN" || die "main checkout missing"
case "${1:-}" in
  preflight) preflight ;;
  swap) preflight && swap "$2" ;;
  restore) restore ;;
  run) trap 'app_stop; restore' EXIT; line=$(run_one "$2" "${3:-0}"); rc=$?
    echo "$line"; [[ -n "$line" ]] && update_results "$line"; exit $rc ;;
  run-all) echo 0 >"$STATE/total"; run_all ;;
  refetch) # refetch <idx>: re-run only the inventory for one row (e.g. after contract-search 500s)
    trap 'app_stop; restore' EXIT; preflight || exit 1; swap "$2" >/dev/null; build "$2" || exit 1
    echo 0 >"$STATE/row"; app_start "$2"; inventory "$2" ;;
  *) sed -n 2,19p "$SELF"; exit 1 ;;
esac
