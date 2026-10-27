---
name: bpp-create-mr
description: Use when turning current local work in a BPP .NET repo into a reviewed merge request — phrases like "create an MR", "open a merge request for my changes", "MR my pending work", "push this and make an MR", "create MR and run unit tests". Auto-branches off a protected branch, commits unstaged work, pushes, creates a GitLab MR targeting development assigned to yourself with the repo's reviewer (backend/.NET apittrich, Angular/frontend chaslauer), runs unit tests, and pings when ready for an e2e run. Then watches the MR's Qodana job and GitLab Duo review: auto-fixes findings the MR introduced, fixes overlooked pre-existing ones when local and safe, replies to and resolves fixed Duo threads, and posts one MR comment explaining every Qodana finding left unfixed. Also use to re-run the watchers after undrafting an MR ("watch duo findings", "handle duo review").
---

# bpp-create-mr

## Overview

One-shot path from local work → reviewed MR in a BPP GitLab repo. Auto-creates a feature branch when on a protected branch, commits pending changes, **verifies the new public surface the branch adds (controller endpoints, public `I*Service` methods, DTO validation/mapper classes) is covered by tests**, pushes, creates (or reuses) an MR targeting `development` **assigned to yourself**, with the reviewer picked by repo kind (**apittrich** for .NET/backend repos, **chaslauer** for Angular/frontend repos), then runs the **unit** test suite as a regression gate. On green it pings the user that e2e can start; on red it reports the failures and pings — it never runs the e2e/integration suite itself (that's `bpp-run-integration-tests`). Finally a **Qodana watcher** (step 9) and a **GitLab Duo watcher** (step 10) run as one combined loop: per HEAD they wait for the qodana job (and, in round 1, Duo's single initial review), fix what the MR introduced, triage pre-existing findings, reply on (and resolve, when fixed) every Duo thread, and post one Qodana summary comment.

## When to Use

- "create an MR", "open a merge request", "MR my changes / pending work"
- "push this and make an MR", "create MR and run unit tests"
- After finishing a chunk of work that should go up for review + regression-checked before e2e.

Not for: bulk dev→staging promotion (`bpp-promote-dev-to-staging`), running e2e/integration tests (`bpp-run-integration-tests`).

## Defaults (non-negotiable unless user overrides)

| Field | Value |
|-------|-------|
| Push remote | `origin` (the cwd repo — **never** `glab-base`) |
| Target branch | `development` |
| Assignee | **yourself** — the authenticated glab user (`glab api user \| jq -r .username`). Never another person; the author drives the MR until merge |
| Reviewer | by repo kind: `apittrich` for .NET/backend repos, `chaslauer` for Angular/frontend repos (`brokernet-cockpit-ui`, `bpp-stella-ui`/`go-stella`, `*-ui`) |
| Protected branches | `development`, `staging`, `main`, `master` |
| New branch prefix | `feature/` + kebab slug from the diff |
| Commit message | auto-generated, conventional (`feat:`/`fix:`/`chore:` …) from the diff |
| MR title/desc | title = last commit subject, description = commit subjects since `origin/development` |
| Unit test filter | `Category!=LocalIntegration&Category!=Integration` |

## The `glab-base` trap (read first)

BPP repos carry **two** remotes: `origin` → the repo itself, and `glab-base` → `lipso/clients/brokernet/bpp-shared`. Bare `glab` may resolve to `glab-base` and create the MR **in bpp-shared**. Always derive the project from `origin` and pin `-R lipso/clients/brokernet/<repo>` on every `glab` call.

```bash
REPO=$(git remote get-url origin | sed -E 's#.*/brokernet/##; s#\.git$##')   # e.g. bpp-backend
PROJ="lipso/clients/brokernet/${REPO}"
```

## Workflow

### 1. Preflight

```bash
glab auth status >/dev/null 2>&1 || { echo "FAIL — glab not authenticated"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "FAIL — not a git repo"; exit 1; }
```

Resolve `REPO` / `PROJ` as above. If `origin` does not point at `lipso/clients/brokernet/*`, STOP and ask.

### 2. Branch resolution

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

- **On a protected branch** (`development`/`staging`/`main`/`master`): generate a concise kebab-case slug (3–6 words) describing the change from `git status` + `git diff` (staged + unstaged), then:
  ```bash
  git switch -c "feature/<slug>"   # uncommitted changes follow into the new branch
  BRANCH="feature/<slug>"
  ```
- **Already on a feature branch**: keep it.

### 3. Commit pending work

```bash
if [ -n "$(git status --porcelain)" ]; then
  git status --porcelain                      # review: never stage appsettings.local.json or other local config,
                                              # never an endpoint migration guide (it goes in its own MR, step 6b)
  git add -- "${FILES[@]}"                     # FILES = explicit paths picked from that list, never `git add -A`
  git commit -m "<auto conventional message from the diff>"
fi
```

Show the committed message to the user. If the tree was clean AND the branch has no commits ahead of `origin/development`, STOP — nothing to MR.

### 4. Coverage gate — new public surface MUST ship with tests

New functionality is covered by tests or it does not go up. Run this **before** the push/MR so any gap is fixed in the same branch. This gate checks that tests *exist*; the unit suite in step 7 checks that they *pass*.

```bash
git fetch -q origin development
BASE=origin/development
git diff "$BASE...HEAD" --stat   # what this branch changes vs development
```

**4a — Enumerate the NEW public surface** the branch adds (added lines / new files only):

| Surface | Find it |
|---|---|
| New controller endpoints | `git diff "$BASE...HEAD" -- '*Controller.cs' \| grep -E '^\+.*\[Http(Get\|Post\|Put\|Delete)'` |
| New public service methods | `git diff "$BASE...HEAD" -- '*/Services/Interfaces/*' \| grep -E '^\+\s*Task'` |
| New DTO validators / mappers | `git diff "$BASE...HEAD" --name-status --diff-filter=A \| grep -E '(Attribute\|DtoMapper)\.cs$'` |

Write down the concrete members found (route + verb, `I*Service` method names, new `*Attribute` / `*DtoMapper` classes). That list is the gate's input. The grep rows are starting aids, not the source of truth: `--diff-filter=A` surfaces only new *files*, so also read the raw `git diff "$BASE...HEAD"` for public members added to **existing** files (a new method on an existing `I*Service`, a new mapping in a `*DtoMapper`, a new `ValidationAttribute`). If you did not read the diff, you have not enumerated.

**4b — Genuinely no new surface → gate passes.** Passes ONLY when you have read the diff and it adds no endpoint, no `I*Service` method, and no DTO/mapper class — a pure refactor / rename / config-only change. Record "no new public surface" and continue to step 5. A grep that matched nothing is NOT a confirmed-empty diff: a member the grep missed still needs a test.

**4c — For every enumerated member, prove coverage** — in the branch diff OR already present in the repo:

| New member | Coverage it needs |
|---|---|
| Controller endpoint | an integration/e2e test hitting the route (`[Category("Integration")]` / `LocalIntegration`, per the repo's convention) **and** a unit test on the service method behind it |
| Public `I*Service` method | a `{Service}Tests` unit test — happy path **and** the error/404 branch |
| `*DtoMapper` | a `{Entity}DtoMapperTests` asserting each mapped property (read, projection, create, update) |
| Custom `ValidationAttribute` | an `{Attribute}Tests` unit test — one valid + one invalid case |

```bash
git diff "$BASE...HEAD" --name-only | grep -E 'Tests?\.cs$'   # tests added/changed on the branch
git grep -n '<RouteOrMethodName>' -- '*Tests*'                # pre-existing coverage in the repo
```

A test-file match is a lead, not proof — open it and confirm it actually calls/asserts the new member, not merely mocks or name-mentions it.

**4d — Any member without coverage → STOP. Do not push or create the MR yet.** List every uncovered member to the user, then close the gap:

- **Unit gap** → write the `{Class}Tests` / `{Entity}DtoMapperTests` / `{Attribute}Tests` now, `git add <test files> && git commit`, then continue.
- **Integration/e2e gap for a new endpoint or flow** → add the test per the **`bpp-add-integration-tests`** skill and commit it. (This skill still does NOT run e2e — it only makes the test EXIST; running it stays with `bpp-run-integration-tests`.)
- **Explicit user waiver** → only a statement from the user, in this session, to skip coverage for a *named* member counts. Record which member and that the user waived it.

A green unit suite is NOT coverage: it proves the tests that exist pass, never that a member no test calls is exercised. Never create the MR with uncovered new surface and no named waiver.

| Rationalization | Reality |
|---|---|
| "The unit suite is green, so it's covered" | Green = the tests that exist pass. A new method no test calls is still untested. Coverage = a test that exercises THIS member. |
| "This endpoint/method is too simple to test" | The 404 / validation / auth branch is where simple public surface breaks in prod. Public surface gets a test. |
| "The mapper/attribute is trivial" | Mappers drift silently — that's why every one has `{Entity}DtoMapperTests` per property. Trivial ≠ exempt. |
| "Add the e2e later / in a follow-up MR" | "Later" is exactly how untested surface reached prod before. It lands in THIS branch or the user waives it by name. |
| "Local stack isn't up, so skip the e2e" | This skill doesn't RUN e2e — it requires the test to EXIST. Missing infra is no reason to skip WRITING it. |
| "I'll just note the gap in the MR description" | A note is not a test. STOP and write it, or get a named waiver. |

### 5. Push

```bash
git push -u origin "$BRANCH"
```

Never `--force`. A push to an existing MR's source branch updates that MR automatically — that satisfies "auto-push all changes to this MR".

### 6. Create or reuse the MR

```bash
ME=$(glab api user | jq -r .username)                 # assignee is always the author
case "$REPO" in                                        # reviewer follows the stack
  brokernet-cockpit-ui|bpp-stella-ui|go-stella|*-ui) REVIEWER=chaslauer ;;
  *) REVIEWER=apittrich ;;
esac

IID=$(glab api "/projects/$(printf %s "$PROJ" | sed 's#/#%2F#g')/merge_requests?state=opened&source_branch=${BRANCH}&target_branch=development" \
  | jq -r '.[0].iid // empty')

if [ -n "$IID" ]; then
  echo "Reusing existing MR !${IID} (push updated it)"
else
  # `glab mr create` is unreliable in this environment — create through the API.
  IID=$(glab api --method POST "/projects/$(printf %s "$PROJ" | sed 's#/#%2F#g')/merge_requests" \
    -f source_branch="$BRANCH" -f target_branch=development \
    -f title="$(git log -1 --format=%s)" \
    --raw-field "description=$(git log --format='- %s' origin/development..HEAD)" \
    | jq -r '.iid // empty')
fi

# Set assignee + reviewer explicitly afterwards — on the freshly created MR AND the reused one.
glab mr update "$IID" -R "$PROJ" --assignee "$ME" --reviewer "$REVIEWER"

# Group label work-ap: lists all misc MRs in one place (not on bpp-agent MRs, not on promotions).
LABELS=$(glab api "/projects/$(printf %s "$PROJ" | sed 's#/#%2F#g')/merge_requests/$IID" | jq -r '.labels|join(",")')
case ",$LABELS," in *,bpp-agent,*) ;; *)
  glab api --method PUT "/projects/$(printf %s "$PROJ" | sed 's#/#%2F#g')/merge_requests/$IID" -f add_labels=work-ap >/dev/null ;;
esac
```

All `work-ap` MRs: `https://gitlab.com/groups/lipso/clients/brokernet/-/merge_requests?sort=created_date&state=opened&label_name[]=work-ap&first_page_size=100`

Capture the MR `!iid` + web URL for the final report.

### 6b. Endpoint migration guide — direct push to `main` of `bpp-endpoint-migration-guides`

Only when the branch changes a DTO / API contract (see the repo's `CLAUDE.md` guide rule) or the work
includes a guide. Guides never go into the backend repo: they live in `bpp-endpoint-migration-guides`
(`main` only), folder `<REPO>/`. A guide file sitting in the backend working tree (an old
`endpoint-migration-guides/` path) is moved there, not committed.

**No MR in the guides repo — push straight to `main`** (user, 2026-10-27: avoids the Duo
requested_changes/Bypass round-trip on docs-only changes). A guide for a backend MR that is not merged yet
is still pushed now; its first line says so.

```bash
G=~/Entwicklung/bpp/bpp-endpoint-migration-guides; GPROJ=lipso/clients/brokernet/bpp-endpoint-migration-guides
git -C "$G" fetch -q origin main
N=$(git -C "$G" ls-tree --name-only "origin/main:$REPO" 2>/dev/null | grep -oE '^__[0-9]+' | tr -d _ | sort -n | tail -1)
N=$(( ${N:-0} + 1 ))
W="$G.worktrees/guide-$REPO-$N"; git -C "$G" worktree add --detach "$W" origin/main
# write "$W/$REPO/__${N}_$(date +%F)_<kebab-topic>-migration-guide_[].md" (quote the path: [ ] are glob characters);
# first line "> For $PROJ!$IID (not yet merged)" + blank line while the backend MR is open
git -C "$W" add -- "$REPO/__${N}_"*; git -C "$W" commit -m "docs($REPO): <topic> migration guide (for $PROJ!$IID)"
git -C "$W" push origin HEAD:refs/heads/main      # rejected (main moved) -> fetch, merge origin/main, re-check $N, push again; never --force
git -C "$G" worktree remove "$W"
```

Then add `Endpoint migration guide: https://gitlab.com/$GPROJ/-/blob/main/<path>` to the backend MR
description (URL-encode `[` `]` as `%5B` `%5D`). A later change to the guide is another direct push.

### 7. Unit tests (regression gate)

Run unit tests only — exclude integration suites (they need the local stack and burn bpp-auth logins):

```bash
SLN=$(find . -maxdepth 2 -name '*.sln' | head -1)
dotnet test "$SLN" --filter "Category!=LocalIntegration&Category!=Integration" --nologo
```

If no `.sln`, run each `*.Tests.csproj` with the same `--filter`. Capture pass/fail counts + failing test names.

### 8. Report + ping

- **Green** → ping the user that e2e can start:
  ```
  PushNotification(status="proactive",
    message="<repo> !<iid> ready — unit tests green, start e2e run")
  ```
  Then report the MR URL + test summary in-session.
- **Red** → do NOT signal e2e-ready. Report failing tests in-session and ping:
  ```
  PushNotification(status="proactive",
    message="<repo> !<iid> created but unit tests RED: <n> failed — needs a look")
  ```
  Leave the diagnosis to the user / `bpp-run-integration-tests`; do not edit tests to make them green.

### 9. Qodana watcher

Runs after step 8, on new and reused MRs. **REQUIRED BACKGROUND:** `bpp-fix-qodana-findings` — fetch mechanics, never-fix list, safe/judgment tiers, false-positive classes. Load it; don't re-derive its rules.

- Unit gate (step 7) **red** → classify + comment only, no fixes: a fix can't be validated against a red suite.
- Watcher commits land in this checkout. If the user may already be running e2e from it, say so in the final ping.

**9a — Wait for the qodana job.** Qodana runs **only** in `merge_request_event` pipelines. Pick the pipeline whose `sha` equals local `HEAD`:

```bash
ENC=$(printf %s "$PROJ" | sed 's#/#%2F#g'); SHA=$(git rev-parse HEAD)
# one call ≤ 9 min; run it in the background (run_in_background) and re-launch up to 3× (~30 min total)
for i in $(seq 1 9); do
  PL=$(glab api "projects/$ENC/merge_requests/$IID/pipelines" | jq -r --arg s "$SHA" '[.[]|select(.sha==$s)][0].id // empty')
  [ -n "$PL" ] && JOB=$(glab api "projects/$ENC/pipelines/$PL/jobs?per_page=100" | jq -c '[.[]|select(.name|test("qodana";"i"))][0] // empty')
  [ -n "$PL" ] && [ -z "$JOB" ] && { echo "NO_QODANA_JOB pl=$PL"; break; }
  ST=$(echo "${JOB:-null}" | jq -r '.status // "pending"')
  case "$ST" in success|failed|canceled|skipped|manual) echo "DONE $ST pl=$PL job=$(echo "$JOB" | jq -r .id)"; break;; esac
  sleep 60
done
```

- `NO_QODANA_JOB` (e.g. `bpp-agent`: no MR pipelines; repos without the component) → report "no qodana job in this pipeline", skip the phase.
- `failed`/`canceled` with no report artifact, or still running after ~30 min → report status + job URL, stop the phase.
- Check the job trace for `NuGetCredentialProvider`: if present, the report is contaminated (see `bpp-fix-qodana-findings`) → comment that, fix nothing.

**9b — Fetch the MR report + a baseline.**
- MR report (`JOB_ID` = `job=` from 9a): `glab api "projects/$ENC/jobs/$JOB_ID/artifacts/.qodana/results/gl-code-quality-report.json"`. Entries carry `check_name`, `fingerprint`, `location.path`, `location.lines.begin`.
- Baseline: `development`/`staging`/`main` push pipelines have **no qodana job** (verified 2026-10-20). That makes GitLab's MR code-quality comparison empty, and its `/-/…/codequality_reports.json` route sits behind Cloudflare, unreachable through `glab api`. Use the newest **merged** MR into the target branch that has a successful qodana job: `merge_requests?state=merged&target_branch=development&order_by=merged_at&per_page=5` → its pipelines → qodana job → same artifact path.
- No baseline found → classify by diff hunks alone (third rule below) and say so in the comment.

**9c — Classify** each MR finding, first matching rule wins:

1. `fingerprint` in baseline → **PRE-EXISTING**.
2. Same `check_name` + `path` + `description` in baseline (line moved) → **PRE-EXISTING**.
3. Its line is in a hunk this MR adds or changes (`git diff -U0 origin/development...HEAD -- <path>`) → **NEW**.
4. Otherwise: a file the MR doesn't touch, or the baseline is older than `origin/development` → **PRE-EXISTING**. Exception: a finding this MR provokes away from its own hunks (e.g. a member made unused by a deletion) → **NEW**. Check the diff.

Re-verify every finding against current content by file + text, not line number. Stale entries are counted as "already fixed".

**9d — NEW findings → fix.** The MR caused them, so fixing them is in scope. Still obey the never-fix list and the false-positive verification rules from `bpp-fix-qodana-findings`.
1. Edit only the flagged site(s).
2. Build, then rerun the unit tests covering the touched projects (step-7 filter).
3. Commit: `git add -- <paths>`, read `git diff --cached`, then `git commit -m "fix(qodana): <rule> in <file>"`.
4. **Do not push yet** — the combined round (10e) pushes once per round. Never amend, never force-push.
5. Back to the combined round (10e) for the new HEAD. **Cap: 3 rounds, shared with the Duo watcher**, then report what remains.

**9e — PRE-EXISTING findings → investigate before touching.** Find why each one is still there:

| Check | Means |
|---|---|
| `git log -L<line>,<line>:<path>` / `git blame` | Deliberate commit or MR discussion → keep |
| `qodana.yaml` excludes, `// ReSharper disable`, `// noinspection`, `[SuppressMessage]`, `.editorconfig` severity | Was meant to be suppressed and the suppression is broken → report, don't widen it yourself |
| False-positive / never-fix classes in `bpp-fix-qodana-findings` | Scan artifact or intended → keep |
| Fix needs a bpp-shared change | Out of this repo → keep, name the shared type |
| Fix changes a public API / DTO / endpoint contract | Needs an endpoint migration guide + broader review → keep |
| Generated code (`*.g.cs`, `Migrations/*.Designer.cs`, snapshots) | Never edit → keep |

None of these apply, the fix is local, small and in the safe/verified-judgment tier → **overlooked**. Fix it in this MR as a **separate commit** (`chore(qodana): fix pre-existing <rule> in <file>`), with the same build/test/commit loop as 9d, pushed with the round's single push in 10e (it counts toward the 3-round cap). Everything else is **collected, not fixed**.

**9f — Post ONE MR comment**, after the last iteration:

```bash
glab api --method POST "projects/$ENC/merge_requests/$IID/notes" --raw-field "body=$BODY"
```

`BODY` sections, skipping empty ones:
- New findings fixed: rule, `file:line`, commit sha.
- Pre-existing fixed: same columns.
- Pre-existing NOT auto-fixed, as a table: rule, `file:line`, reason (false-positive class / needs bpp-shared / API change / deliberate (link commit) / generated / out of scope).
- Still open after the cap, plus report/baseline provenance (pipeline ids).

Clean report → still post the one-liner `Qodana: no new findings (pipeline <id>)`. Without it, a silent MR can't be told apart from a watcher that never ran. One line is worth that.

**9g — Ping** `PushNotification(status="proactive", message="<repo> !<iid> qodana: <n> fixed, <m> left — see MR comment")`.

**Safety (whole phase):**
- Never suppress a finding (`qodana.yaml`, inline disable, baseline) to get green. Suppression is a reviewed decision, not a watcher action.
- Touch only the files of the finding being fixed. No drive-by cleanups. Never stage secrets or `appsettings.local.json`.
- Follow the repo's `CLAUDE.md` conventions.
- `bpp-document-analysis` (doci): no local build/test. The pipeline is the proof. Fix NEW findings only, and only from the safe-mechanical tier. The next pipeline (build + unit + qodana) verifies them; a red pipeline stops the loop. Pre-existing findings are comment-only.
- `bpp-agent`: no MR pipelines, so the phase ends at 9a.

### 10. GitLab Duo watcher

Duo (user `GitLabDuo`) reviews **only non-Draft MRs**, and **only once**: the initial review when the MR is opened non-draft or marked ready (auto-requested from `@GitLabDuo`). Later pushes do **not** trigger a new review (observed 2026-10-27: no Duo review of a new head after 50 min). A re-review only happens on request (`mergeRequestReviewerRereview` via GraphQL, costs Duo credits) — do that only when the user asks. Its output per review:
- a non-system note `started [review session N]…` (ignore it);
- inline **DiffNote** threads (resolvable);
- a summary note starting `I finished my review…` or `I left N …` (non-resolvable; can hold points that are not inline);
- a system note `approved this merge request` / `requested changes`.

GitLab is **Premium**: every resolvable thread must be resolved before the MR can merge.

**10a — Draft gate.**
```bash
DRAFT=$(glab api "projects/$ENC/merge_requests/$IID" | jq -r .draft)
```
`true` → skip the Duo phase. Say in the final report: "Duo reviews once the MR is marked ready — re-run `/bpp-create-mr` on this branch then; it reuses the MR and runs the watchers." Do not wait for an undraft.

**10b — Wait for Duo's initial review** (round 1 only). If Duo already posted a summary note on this MR, skip the wait and go to 10c with the window of the version it reviewed. Otherwise anchor on the MR diff version for HEAD, not on wall-clock time. The window is `[T, U)`: `T` = `created_at` of HEAD's version, `U` = `created_at` of the next version (empty while HEAD is the newest). Timestamps are GitLab UTC ISO strings (`…Z`), so string comparison is safe.
```bash
VERS=$(glab api "projects/$ENC/merge_requests/$IID/versions")
T=$(jq -r --arg s "$SHA" '[.[]|select(.head_commit_sha==$s)][0].created_at // empty' <<<"$VERS")
[ -n "$T" ] || { echo "NO_VERSION — $SHA not pushed to the MR yet"; exit 1; }   # empty T would match every note
U=$(jq -r --arg t "$T" '[.[]|select(.created_at>$t)]|sort_by(.created_at)[0].created_at // empty' <<<"$VERS")
WIN='.created_at>$t and ($u=="" or .created_at<$u)'
# ≤ 9 min per call, background, re-launch up to 3× (~25 min total) — same as 9a
for i in $(seq 1 9); do
  NOTES=$(glab api "projects/$ENC/merge_requests/$IID/notes?per_page=100&sort=desc" --paginate)
  DUO="[.[][]|select(.author.username==\"GitLabDuo\" and .system==false and ($WIN))]"
  # done = Duo's summary note for this window: a general (non-DiffNote) note that is not "started [review session"
  S=$(jq -s --arg t "$T" --arg u "$U" "$DUO|map(select(.type!=\"DiffNote\" and (.body|startswith(\"started [review session\")|not)))|length" <<<"$NOTES")
  [ "${S:-0}" -gt 0 ] && { sleep 30; echo "DUO_DONE"; break; }   # inline DiffNotes land 1–2 s after the summary
  sleep 60
done
```
The **summary note** marks the end of a review. Its wording varies (`I finished my review…`, `I left N …`,
`I reviewed the changes since my last review…`, `Two earlier threads need no action…`), so key on the note
type, not the text (verified on bpp-backend !469, 2026-10-27). A summary starting `:warning: Something went
wrong` means the review failed → report "Duo review of <sha> failed" and treat the round as not reviewed.
No summary after ~25 min but DiffNotes in the window → handle them and say "Duo review of <sha> may be
partial (no summary note)". Nothing at all → report "Duo did not review <sha>" and end the Duo phase for
this round.

**10c — Collect the open findings of this review.** Drop system notes ("approved" / "requested changes") and threads that are resolved or already have a reply from someone other than Duo (a re-run must not reply twice):
```bash
glab api "projects/$ENC/merge_requests/$IID/discussions?per_page=100" --paginate | jq -s -c --arg t "$T" --arg u "$U" \
  ".[][]|select(.notes[0].author.username==\"GitLabDuo\" and (.notes[0].system|not)
              and (.notes[0] | $WIN)
              and (.notes[0].resolved != true)
              and ([.notes[1:][]|select(.system|not)|select(.author.username!=\"GitLabDuo\")]|length==0))
   |{id, kind:(if .notes[0].position then \"inline\" else \"summary\" end),
     resolvable:.notes[0].resolvable, path:.notes[0].position.new_path, line:.notes[0].position.new_line, body:.notes[0].body}"
```
- `kind=inline` → a DiffNote with a position: resolvable, one finding.
- `kind=summary` → no position, not resolvable (wording varies, see 10b). Its bullets can hold extra findings. "found nothing to comment on" = clean review.
- Duo sometimes says its diff was truncated, so re-verify each finding against the current code before acting.

**10d — Handle each finding**, first matching row wins:

| Finding | Action | Resolve? |
|---|---|---|
| Code issue in this MR's own code (bug, missing check, dead code/loop, small refactor, stale doc/XML doc) | fix it, reply with what changed + commit sha | **yes** |
| Design, rollout or product question (e.g. "prod rollout risk", "should X be behind a toggle") | no code change; ask the user (AskUserQuestion, concrete options, recommended first). Then fix and resolve, or reply with the user's decision and leave it open | only if fixed |
| Wrong or not applicable | reply with the reason and `file:line` evidence | **no** — the author resolves |
| Point only in the summary note | handle it by the rows above; reply in the summary discussion (not resolvable) | – |

```bash
glab api --method POST "projects/$ENC/merge_requests/$IID/discussions/$DID/notes" --raw-field "body=$REPLY"
glab api --method PUT  "projects/$ENC/merge_requests/$IID/discussions/$DID?resolved=true"   # fixed only
```
Fixes follow 9d's loop: edit only the flagged site, build, unit tests, `git add -- <paths>`, read `git diff --cached`, commit `fix(review): <what> (GitLab Duo)`. **No push here** — 10e pushes once per round; a push mid-round opens a new MR version, which closes HEAD's `[T, U)` window before the review is collected. Reply and resolve after that push, citing the pushed sha.

**10e — Combined round (Qodana + Duo).** Every push re-triggers Qodana; Duo reviews only the first non-draft version:
1. Round 1: wait for 9a (qodana job) **and** 10b (Duo's initial review). Later rounds: wait for 9a only — do not wait for Duo on a new head, and report "Duo reviews only the initial version" instead of "Duo did not review <sha>".
2. Fix everything from both in one batch (separate commits are fine), build + unit tests once, push once. Then post the Duo replies and resolve the fixed threads, citing the pushed sha.
3. New HEAD → next round. **Cap: 3 rounds total.** A round with nothing to fix from either source ends the loop.
4. After the last round: post 9f's Qodana comment, then list every still-unresolved resolvable thread on the MR (any author) — that is what blocks the merge:
   ```bash
   glab api "projects/$ENC/merge_requests/$IID/discussions?per_page=100" --paginate | jq -r \
     '.[]|select(.notes[0].resolvable and (.notes[0].resolved|not))|"\(.id[0:8]) \(.notes[0].author.username) \(.notes[0].position.new_path // "-"): \(.notes[0].body|gsub("\n";" ")|.[0:80])"'
   ```

**10f — Ping** `PushNotification(status="proactive", message="<repo> !<iid> duo: <n> fixed+resolved, <m> open (<k> need your decision)")`.

## Quick Reference

| Step | Command |
|---|---|
| Repo from origin | `git remote get-url origin \| sed -E 's#.*/brokernet/##; s#\.git$##'` |
| New branch | `git switch -c feature/<slug>` |
| Commit | `git add <paths> && git commit -m "<msg>"` (never `appsettings.local.json`) |
| New endpoints in diff | `git diff origin/development...HEAD -- '*Controller.cs' \| grep -E '^\+.*\[Http'` |
| New service methods in diff | `git diff origin/development...HEAD -- '*/Services/Interfaces/*' \| grep '^\+.*Task'` |
| Find a member's coverage | `git grep -n <route-or-method> -- '*Tests*'` |
| Push | `git push -u origin <branch>` |
| Existing MR? | `glab api .../merge_requests?state=opened&source_branch=<b>&target_branch=development` |
| Create MR | `glab api --method POST "/projects/<enc>/merge_requests" -f source_branch=… -f target_branch=development -f title=…` |
| Label | `add_labels=work-ap` on every MR except `bpp-agent` ones |
| Guide (DTO/API change) | `bpp-endpoint-migration-guides`, folder `<repo>/`, direct push to `main`, no MR (step 6b) |
| Set assignee+reviewer (always follow up) | `glab mr update <iid> -R lipso/clients/brokernet/<repo> --assignee <me> --reviewer <apittrich\|chaslauer>` |
| Unit tests | `dotnet test <sln> --filter "Category!=LocalIntegration&Category!=Integration"` |
| Ping | `PushNotification(status="proactive", message="…")` |
| MR pipelines (qodana lives only here) | `glab api "projects/<enc>/merge_requests/<iid>/pipelines"` → pick `sha == HEAD` |
| Qodana report | `glab api "projects/<enc>/jobs/<job>/artifacts/.qodana/results/gl-code-quality-report.json"` |
| Baseline MR | `glab api "projects/<enc>/merge_requests?state=merged&target_branch=development&order_by=merged_at&per_page=5"` |
| MR comment | `glab api --method POST "projects/<enc>/merge_requests/<iid>/notes" --raw-field "body=…"` |
| Draft? (Duo skips drafts) | `glab api "projects/<enc>/merge_requests/<iid>" \| jq .draft` |
| Diff version of HEAD (Duo anchor) | `glab api "projects/<enc>/merge_requests/<iid>/versions"` → `head_commit_sha == HEAD` → `created_at` |
| Duo findings | `…/merge_requests/<iid>/discussions` where `notes[0].author.username == "GitLabDuo"` |
| Reply / resolve a thread | `POST …/discussions/<id>/notes --raw-field body=…` / `PUT …/discussions/<id>?resolved=true` |

## Common Mistakes

- **Creating the MR before checking new-surface coverage** → new endpoints / `I*Service` methods / DTO mappers ship untested. Enumerate the diff's new public surface (step 4) and prove each has a test — or get a named waiver — first.
- **Treating "unit suite green" as coverage** → the suite passes without ever calling a member no test references. Green ≠ covered; only a test that exercises THIS member counts.
- **Skipping e2e coverage because the local stack is down** → this skill only requires the test to EXIST, not to run; write it (per `bpp-add-integration-tests`) and let `bpp-run-integration-tests` run it later.
- **Letting `glab` pick `glab-base`** → MR lands in bpp-shared. Always pin `-R lipso/clients/brokernet/<repo>` from `origin`.
- **MR'ing from a protected branch** → `development→development` is empty / rejected. Auto-create a `feature/*` branch first.
- **Including integration tests in the gate** → they need the local stack and trip bpp-auth's 429; this skill is unit-only (`Category!=LocalIntegration&Category!=Integration`).
- **Using `glab mr create`** → unreliable here, and it drops `--reviewer`/`--assignee` at creation time. Create via `glab api --method POST …/merge_requests`, then always follow up with `glab mr update <iid> --assignee "$ME" --reviewer "$REVIEWER" -R lipso/clients/brokernet/<repo>` (on new and reused MRs).
- **Assigning the MR to the reviewer** → the author keeps the assignee slot (they push the fixes and drive it to merge); the other person goes in `--reviewer` only.
- **Using the backend reviewer on a frontend MR** → Angular repos are reviewed by `chaslauer`, .NET repos by `apittrich`. Derive it from the repo, don't default blindly.
- **Duplicating an MR** → query open MRs for the source branch first; a push already updates an existing one.
- **Committing an endpoint migration guide into the backend repo** → guides live in `bpp-endpoint-migration-guides/<repo>/`; push it straight to `main` there (step 6b) and link it.
- **`--force` push** → never.
- **Editing tests to go green** → out of scope; report red and stop.
- **Pinging e2e-ready when tests are red** → only ping "start e2e" on green.
- **Taking the qodana baseline from a `development` pipeline** → none has a qodana job. Use the newest merged MR's report.
- **Fixing a pre-existing finding without asking why it's still there** → it may be deliberate, a scan artifact, or need a bpp-shared/API change. Run the 9e checks first.
- **Suppressing a finding to make the watcher go green** → never. Fix it, or list it with a reason in the MR comment.
- **Waiting on qodana in one >10 min shell call** → ≤9 min per call, background, re-launch.
- **Waiting for Duo on a Draft MR** → Duo never runs on drafts. Skip the phase and tell the user to re-run after undrafting.
- **Waiting for a Duo review of a later push** → Duo reviews only the initial non-draft version. Collect that review once (anchor on its MR version window), then only Qodana per push.
- **Running Qodana and Duo fix loops separately** → one combined round: Duo's single initial review plus Qodana per push, 3 rounds total.
- **Duo still shows `requested_changes` after all its threads are resolved** → it does not re-review on its own; add label `duo-bypass` and give the user the `duo-bypass` list URL (they click Bypass; there is no API).
- **Resolving a thread that was only answered** → resolve only what was fixed in code. Declined findings and design questions stay open for the author.
- **Fixing a Duo design/rollout point on your own** → ask the user first; it is not a code smell.

## Red Flags — STOP

- A new endpoint / `I*Service` method / `*DtoMapper` / `ValidationAttribute` in the diff has no matching test and no named user waiver → STOP, do not push the MR (write the test or get the waiver).
- Justifying a skipped test with "too simple", "trivial", "e2e later", or "the stack isn't up" → STOP, write the test or get a named waiver.
- Downgrading missing coverage to an MR-description note instead of a test → STOP.
- `origin` is not `lipso/clients/brokernet/*`, or resolves to `bpp-shared` → STOP, ask the user.
- About to create an MR without pinning `-R` → STOP.
- Clean tree with nothing ahead of `origin/development` → STOP, nothing to MR.
- About to `git push --force` or run e2e/integration tests → STOP (e2e is a separate, user-triggered run).
- Watcher about to amend, force-push, add a suppression/exclude, edit generated code, or touch a file the finding isn't in → STOP.
- 3 combined watcher rounds done → STOP fixing, post the comment and the unresolved-thread list.
- About to resolve a thread whose finding was not fixed in code → STOP, reply only.
- About to change code for a Duo design/rollout/product point without the user's answer → STOP, ask.
