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

### The SHA is the branch HEAD — nothing else

`repos[repo][branch].sha` is **the commit id of the branch tip**, taken from the branch probe
(`/repository/branches/<br>` → `.commit.id`). It is a watermark, not a finding.

**Never record the newest commit of the reviewed window.** Verified failure 2026-09-08: the fleet run
stored the newest commit of the 24-hour bootstrap window. Those commits sit on feature branches, so
commits merged into `development` from *sibling* branches are not their ancestors — the next
`compare?from=<that sha>` resurfaced 15 bpp-stella, 10 bpp-file and 8 bpp-stella-ui commits dated
**days earlier** than the ones already reviewed. Only `bpp-backend`, where a real branch head happened
to be stored, deduped correctly.

The rule: capture `head` during A2's branch probe and write **that** value at the end of the run.

**Advance a repo/branch SHA only when its scan completed.** A repo in `failed.tsv` keeps its old SHA
so the next run rescans the same window. This is what stops a transient API error from creating a
permanent blind spot.

## findings.jsonl

```json
{"fingerprint":"…","first_seen":"2026-09-08T12:07:00+02:00","last_seen":"2026-09-08T12:07:00+02:00","run_id":"2026-09-08-1207","repo":"bpp-backend","branch":"development","file":"BPP.Backend.NET.Contract/Services/ContractService.cs","rule_id":"r1.ef-tracking","severity":"high","ticket":"BRO-1234","claim":"…","verdict":"real","outcome":"mr","mr_url":"https://gitlab.com/…/merge_requests/301","escalation_path":null}
```

`outcome` ∈ `mr` | `fixed` | `rejected` | `escalated` | `false-positive` | `needs-human` | `deferred`.

`mr` means *an MR is open* — it is a **transient** state, not a conclusion. Every run resolves it
further (see below). `fixed` = its MR merged. `rejected` = its MR was closed unmerged.

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

**`branch` is included, and that is a sharp edge.** The same defect on `development` and on `staging`
fingerprints differently. That is correct for a genuine branch-exclusive divergence, and wrong for a
promoted commit — which is why cross-branch commit dedup (`discovery.md` A3b) must run in Phase A,
*before* fingerprints are computed. Fingerprinting cannot clean up after a missing A3b.

## Refresh open MR outcomes — first thing, every run

Before dedup, re-check every finding recorded as `mr`. Leaving them at `mr` forever is what turns a
rejection into permanent silence.

```bash
jq -r 'select(.outcome=="mr") | "\(.repo)\t\(.mr_url)\t\(.fingerprint)"' ledger/findings.jsonl
# for each: GET the MR, then
#   merged            -> outcome "fixed"
#   closed, no merge  -> outcome "rejected"  + surface once (see references/act.md)
#   still open        -> leave as "mr"
```

## Dedup rule

| Recorded outcome | On a later run |
|---|---|
| `mr` | skip — only `last_seen` is updated (after the refresh above) |
| `fixed` | skip — but if the same claim reappears, it is a **regression**: raise it as new |
| `rejected` | skip the MR, **never re-open one**; surface once for a reason, then `known-non-issues.md` or a standing escalation |
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
