# Ledger — state, findings, fingerprinting

Lives in the `bpp-audit-reports` checkout at `~/Entwicklung/bpp/bpp-audit-reports`.

```
ledger/state.json      last scanned SHA per repo/branch, Jira status snapshot, deferred queue
ledger/findings.jsonl  one JSON object per finding, append-only
```

## state.json

```json
{
  "schema": 1,
  "last_run": "2026-09-08T12:07:00+02:00",
  "repos": {
    "bpp-backend": {
      "development": { "sha": "d057741ba", "scanned_at": "2026-09-08T12:07:00+02:00" },
      "staging":     { "sha": "…",         "scanned_at": "…" },
      "main":        { "sha": "…",         "scanned_at": "…" }
    }
  },
  "jira": { "BRO-1234": { "status": "Staging-Deployed", "updated": "2026-09-07T09:12:00.000+0200" } },
  "deferred": [ { "repo": "bpp-stella", "branch": "development", "reason": "cap:repos" } ],
  "nuget": { "bpp-backend": { "swept_at": "…", "last_mr": "…" } }
}
```

**Advance a repo/branch SHA only when its scan completed.** A repo in `failed.tsv` keeps its old SHA
so the next run rescans the same window. This is what stops a transient API error from creating a
permanent blind spot.

## findings.jsonl

```json
{"fingerprint":"…","first_seen":"2026-09-08T12:07:00+02:00","last_seen":"2026-09-08T12:07:00+02:00","run_id":"2026-09-08-1207","repo":"bpp-backend","branch":"development","file":"BPP.Backend.NET.Contract/Services/ContractService.cs","rule_id":"r1.ef-tracking","severity":"high","ticket":"BRO-1234","claim":"…","verdict":"real","outcome":"mr","mr_url":"https://gitlab.com/…/merge_requests/301","escalation_path":null}
```

`outcome` ∈ `mr` | `escalated` | `false-positive` | `needs-human` | `deferred`.

## Fingerprint

```
sha256( repo | branch | normalized_file_path | rule_id | normalized_claim )
```

`normalized_claim` = claim lowercased, reduced to alphanumerics and single spaces, truncated to 200
characters.

```bash
fingerprint() {   # repo branch path rule_id claim
  local claim_n
  claim_n=$(printf '%s' "$5" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | tr -s ' ' | cut -c1-200)
  printf '%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$claim_n" | sha256sum | cut -d' ' -f1
}
```

**Line numbers are deliberately excluded.** Code shifts; the finding does not. Including the line
would re-report the same bug after any unrelated edit above it.

## Dedup rule

| Recorded outcome | On a later run |
|---|---|
| `mr` | skip — only `last_seen` is updated |
| `escalated` | skip — only `last_seen` is updated |
| `false-positive` | skip — only `last_seen` is updated |
| `needs-human` | skip — only `last_seen` is updated |
| `deferred` | **re-queue first**, ahead of new work |

A finding that reappears after being genuinely fixed produces a *new* fingerprint only if its claim
or file changed. If it recurs verbatim, it is correctly treated as the same unresolved finding and
is not re-MR'd — the escalation report is where a persistent unfixed finding stays visible.

## Concurrency

Only one run at a time. Take a lock before touching the ledger:

```bash
exec 9>"$HOME/.local/state/bpp-daily-audit/run.lock"
flock -n 9 || { echo "another audit run holds the lock; aborting"; exit 1; }
```
