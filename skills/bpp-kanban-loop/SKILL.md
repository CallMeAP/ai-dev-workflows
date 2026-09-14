---
name: bpp-kanban-loop
description: Use when driving the local BPP kanban board at http://127.0.0.1:7777 as a coordinator loop — phrases like "run the kanban loop", "work the kanban board", "start the board loop", "pick up kanban tickets", "/loop the kanban board". Each tick reads the whole board, reconciles `mr_open` cards against GitLab, computes the claimable set under the repo-mutex / bpp-shared-exclusivity / depends_on / MAX_IN_FLIGHT rules, spawns one implementer agent per selected ticket concurrently, and schedules the next wakeup. Implementer agents open an MR and stop — no agent ever merges.
---

# bpp-kanban-loop

## Overview

**This session is the coordinator.** There is no intermediate "main agent" between the board and the
decision: the loop session reads `http://127.0.0.1:7777/api/tickets`, decides what may start, and
spawns implementer subagents directly. Each implementer claims one ticket, works it in a git worktree,
and ends at **"MR open, reviewer assigned"** — merging is always the user's action. Which reviewer is
repo-dependent; see step 7 of the prompt template.

The loop is driven by `/loop` in a live Claude Code session and re-arms itself with `ScheduleWakeup`.
It is **not a daemon**: when the session ends the loop stops and in-flight agents die with it. That is
survivable by construction — every agent commits to a branch and releases its claim on exit, so
restarting the loop resumes rather than loses work.

**Design rule that shapes everything below: a spawned subagent inherits nothing.** Not this session's
context, not the invariants, not the ticket, not the thread. Anything the spawn prompt does not restate
is unenforced. That is why the prompt template in this skill is long and why it must be pasted whole.

## When to Use

- "run the kanban loop", "work the board", "start the kanban loop"
- `/bpp-kanban-loop` — bare is the normal invocation; it arms its own 5-minute schedule (step 0)
- Resuming after a session ended with tickets still `in_work` or `blocked`

## When NOT to Use

- Working **one** named ticket by hand → read it, do the work, use `bpp-create-mr`. The loop's whole
  value is concurrency + the claim guard; a single ticket needs neither.
- Creating or editing tickets → that is the board UI's job, not the loop's. The one exception the loop
  owns is the `main → development` back-merge follow-up (step 9 of the implementer workflow).
- Merging anything, ever. See invariant 1.

## Step 0 — arm the schedule, exactly once

A bare `/bpp-kanban-loop` is a **single tick**. The loop only recurs because this step schedules it, so
do this first, before probing the board.

**Check for an existing job before creating one.** Call `CronList`. If any job's prompt is already
`/bpp-kanban-loop`, the loop is armed — say so, give its id, and go straight to the prerequisites.

```
CronList()
```

Only if no such job exists:

```
CronCreate(cron="*/5 * * * *", prompt="/bpp-kanban-loop", recurring=true)
```

**Why the list comes first:** this skill is re-entered by its own cron every 5 minutes, so an
unconditional `CronCreate` would add one job per tick — twelve after an hour, each spawning its own
implementers against the same board. The claim guard would reject the duplicate claims, so nothing
would corrupt, but the session would fill with agents that immediately 409 and die. `CronList` is the
whole reason that does not happen. It is also why re-running `/bpp-kanban-loop` by hand is safe.

Report the job id once, when you create it, with the two facts the user needs to control it:

- the schedule is **session-only** — it is in memory, it is not written to disk, and it dies with this
  Claude session (the board's `server.py` does not; see below)
- recurring jobs **auto-expire after 7 days**, firing one last time before they are deleted

**To stop the loop:** `CronDelete(id="<job id>")`. Deleting the job stops the ticking and leaves the
board running, which is the intended resting state — the user can still read threads and answer
blocked cards.

If the user asked for a different cadence, honour it: `Nm` becomes `*/N * * * *` for N that divides 60.
Below 60s is not expressible in cron and is far too fast for a loop that spawns agents.

## Prerequisites — ensure the board is up (once per session, not per tick)

The point of this step is that a bare `bpp-kanban-loop` after a reboot brings everything up. **Ensure,
not check**: if the board is not running, start it.

### 1. Probe first — always

```bash
BOARD=http://127.0.0.1:7777
curl -sS -o /dev/null --max-time 2 "$BOARD/api/tickets" && echo "board already up"
```

Probing before starting is not politeness, it is the whole safety of this step: **two `server.py`
processes on one SQLite file is how you get `database is locked` and a board that silently drops
writes.** Never start a server you have not just proven is absent.

### 2. Not reachable → start it

**If the systemd unit is installed, start it through systemd — never with `nohup`:**

```bash
if systemctl --user list-unit-files bpp-kanban.service >/dev/null 2>&1 \
   && systemctl --user cat bpp-kanban.service >/dev/null 2>&1; then
  systemctl --user start bpp-kanban.service
else
  cd /home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich/kanban
  nohup python3 server.py --db kanban.db --port 7777 >/tmp/kanban-board.log 2>&1 &
fi
```

**Why the branch matters.** The unit carries `Restart=on-failure`. A `nohup` start alongside it gives
you an instance systemd does not know about — and the moment systemd's own copy starts or restarts,
two processes are writing one SQLite file. That is the `database is locked` failure the probe exists
to prevent, arriving by a route the probe cannot see. Ask systemd for the board whenever systemd owns
it.

`nohup … &` for the fallback, never a foreground run — a foreground server blocks the very session
that is supposed to be running the loop.

Under systemd the log is the journal, not `/tmp/kanban-board.log`:
`journalctl --user -u bpp-kanban.service -n 50`.

Then wait for it, bounded. One `curl` with built-in retry, so there is no `sleep` loop and no
open-ended wait:

```bash
curl -sS -o /dev/null --retry 10 --retry-delay 1 --retry-connrefused --retry-max-time 15 \
  "$BOARD/api/tickets" && echo "board started"
```

Proceed only once that answers.

### 3. Still not reachable → stop and report

Report it, point at the log — `journalctl --user -u bpp-kanban.service -n 50` when systemd owns the
board, otherwise `/tmp/kanban-board.log` (the traceback is in there — usually a port clash or a
schema error) — and stop. Do **not** start a second process and do **not** tick against a dead board.

The one case worth naming: **port occupied but the API does not answer.** That is a stop-and-report,
never a retry — something else owns `:7777`, and starting another server would either fail or, worse,
attach a second writer to the database.

```bash
ss -ltnp 'sport = :7777'   # who holds the port, if anyone
```

### 4. glab

```bash
glab auth status >/dev/null 2>&1 && echo "glab OK"
```

### The board outlives the loop — deliberately

Ending the session stops the loop; it does **not** stop `server.py`. That is the design: the user keeps
looking at the board, reading threads and answering blocked cards after the loop is gone. **Never add a
shutdown at the end of a run**, and never kill the server to "clean up" — the next invocation's probe
will find it and simply carry on.

If the board goes away mid-run, that is a different case from a cold start: report
`Board unreachable — is server.py running on :7777?` and **retry once**; if it is still down on the next
tick, stop the loop and tell the user. A loop that keeps ticking against nothing looks alive and is not.

---

## The invariants (§1 of SPEC.md)

These hold everywhere, for the loop and for every agent it spawns. An agent that cannot satisfy one
**stops and asks** rather than working around it. Restate them **verbatim** in every spawn prompt.

1. **An agent never merges an MR and never sets auto-merge.** The pipeline ends at "MR open,
   reviewer assigned". Merging is always the user's action.
2. **No `--force`, no `git branch -D`, no `git reset --hard`, no `git worktree remove --force`,
   no `git stash`, no `git add -A`.** Explicit adds only.
3. **`appsettings.local.json` is never read, printed, grepped, diffed, staged or committed** — in any
   repo, by any agent. Repo-wide searches exclude it.
4. **No secrets in tickets, comments, commits or MR text** — no tokens, credentials, or
   Vermittlernummern.
5. **Never switch a main checkout's branch.** Implementer agents work in git worktrees.
6. **VERA/ARAG PROD is read-only and never called**, including WSDL fetches.
7. **E2E mail recipients are `@go-plattform.at` only.**
8. The board binds **`127.0.0.1` only**. No auth, because nothing off-host can reach it.

---

## Each tick

### 1. Read the whole board in one call

```bash
BOARD=http://127.0.0.1:7777
curl -sS "$BOARD/api/tickets" > /tmp/board.json
```

One call, not one per column. `/api/tickets` returns every ticket with its `comments` inlined, which is
exactly the payload a spawn prompt needs — fetching per-ticket later re-reads what you already have.

### 2. Reconcile `mr_open` against GitLab

For every card in `mr_open`:

```bash
PROJ="lipso/clients/brokernet/<repo>"; ENC=${PROJ//\//%2F}
glab api "projects/$ENC/merge_requests/<mr_iid>" | jq -r .state    # opened | merged | closed
```

- `merged` → `POST /api/tickets/<id>/state {"state":"done"}`, posted by the **loop**, with **no
  `agent_id`** — the claiming agent is long gone, and a `done` that required one could never be posted.
- `opened` → leave it. It is waiting on the user, which is the correct resting place.
- `closed` → **do not mark done.** A closed-unmerged MR means the work was dropped; leave the card in
  `mr_open` and report it in-session so the user decides between reopening and deleting the ticket.

### 2b. Close the MR behind a cancelled card

A `cancelled` card that still carries an `mr_iid` has an open merge request nobody intends to merge.
Close it — leaving it open puts abandoned work in the reviewer's queue for ever:

```bash
glab api --method PUT "projects/$ENC/merge_requests/<mr_iid>" -f state_event=close
```

Then post one `kind:"status"` comment on the card recording that you closed it and why, quoting the
ticket's `cancel_reason`. Do **not** clear `mr_iid` — it is the record of what was attempted.

Two things about cancellation the loop has to expect:

- **The in-flight agent was never told.** A subagent has no inbox, so an agent working a card
  cancelled underneath it will finish and may open an MR *after* the cancellation. That MR shows up
  on the next reconcile; close it the same way. This is not an error, it is the designed race.
- **A cancelled dependency gates its dependents for ever, deliberately.** The work did not happen, so
  satisfying the gate would start the dependent on an abandoned foundation. But the board will not
  tell anyone, so **the loop must**: each tick, report any `open` ticket whose `depends_on` names a
  `cancelled` ticket, because that chain can never be satisfied without the operator editing it.

### 2c. Reclaim the worktree behind a cancelled card — automatically

A cancelled ticket's worktree is dead weight: nobody will resume it, and each one is a full checkout.
Remove it on the same tick that closes its MR. No confirmation, no candidate list.

```bash
REPO_PATH=/home/alex/Entwicklung/bpp/<repo>
WT=$(git -C "$REPO_PATH" worktree list --porcelain \
      | awk -v b="refs/heads/<branch>" '/^worktree /{w=$2} $0=="branch "b{print w}')
[ -n "$WT" ] && git -C "$REPO_PATH" worktree remove "$WT" && git -C "$REPO_PATH" worktree prune
```

**`bpp-cleanup-merged-worktrees` is the wrong tool here and will refuse.** Its entire safety model is
"remove only what is provably merged into `origin/development`". A cancelled ticket's branch is by
definition *not* merged, so it classifies as `KEEP: unmerged, no merged MR` — correctly. Cancellation
is a different justification for removal: the operator abandoned it deliberately. Do not weaken that
skill to cover this case; do it here.

**Never `--force`, and never delete the branch.** Those two rules are what make automatic removal
safe, and they are not negotiable (invariant 2):

- Plain `git worktree remove` **refuses on a dirty worktree**. That refusal is the only backstop
  against deleting uncommitted work, so when it fires, report the path and move on — do not escalate.
  A ticket cancelled mid-flight is exactly the case that can be dirty.
- **Unpushed commits are not at risk.** Removing a worktree does not remove its branch, and the
  commits stay reachable from it. That is precisely why the branch must survive: it is the only thing
  standing between "reclaimed some disk" and "destroyed work the operator might want back".

So the automatic path handles every clean worktree with no human step, and the one case it does not
handle is the one where removing would lose something that exists nowhere else.

Read the MR state from the API, never from `glab mr view` — that command prints prose for humans and
its shape is not a contract. Use `mr view` when *you* want to look at an MR; parse only the `glab api`
call above.

Pin `-R` / the project path on **every** `glab` call. See the `glab-base` trap below.

### 3. Compute the eligible set

The server's `/claim` is the authority — it re-checks all of this inside `BEGIN IMMEDIATE`. But do not
fire claims you already know will 409; a failed claim wastes a spawn. Filter to tickets where **all**
hold:

| Gate | Rule |
|---|---|
| state | `state == 'open'` |
| dependencies | every id in `depends_on` is a ticket in state `done` |
| repo mutex | no other ticket with the **same `repo`** is currently `in_work` with a non-null `claimed_by` |
| bpp-shared | if this ticket's repo is `bpp-shared`, **nothing else may be claimed at all**; and if any claimed ticket is on `bpp-shared`, nothing else may start |
| cap | claimed count `< MAX_IN_FLIGHT` (default 3) |

**Why bpp-shared runs alone:** "different repos, therefore safe" is wrong in this fleet. A `bpp-shared`
change couples to every consumer through the `<BppSharedVersion>` pin in `Directory.Build.props`, so a
consumer branch built while shared is mid-change is built against a version that does not exist yet.

### 3b. Refuse any ticket whose body carries a credential

Before selecting anything, scan each candidate's `body` for credential material. A ticket that
contains one is **never spawned** — invariant 4 is not a thing the agent is asked to honour later, it
is a reason the ticket does not start.

```bash
python3 - <<'PY'
import json, re
for t in json.load(open('/tmp/board.json')):
    if t['state'] != 'open':
        continue
    body = t.get('body', '')
    hits = []
    for label, pat in (
        ('secret/password/token assignment',
         r'(?i)"?(client_?secret|password|passwd|api[_-]?key|token|secret)"?\s*[:=]\s*["\']?\S{8,}'),
        ('private key block', r'BEGIN [A-Z ]*PRIVATE KEY'),
        ('bearer token',      r'Bearer\s+[A-Za-z0-9._~+/-]{20,}'),
        ('gitlab/github PAT', r'\b(glpat-|ghp_|github_pat_)\S{10,}'),
        ('AWS key id',        r'\bAKIA[0-9A-Z]{16}\b'),
        ('connection string', r'(?i)(Server|Host|Data Source)=[^;]+;.*(Password|Pwd)='),
    ):
        n = len(re.findall(pat, body))
        if n:
            hits.append(f"{label} x{n}")
    if hits:
        print(f"REFUSE #{t['id']}: {', '.join(hits)}")
PY
```

**Report shapes and counts, never values.** Do not echo the matched text into the session, a comment,
a log or a commit message — the whole point is that the credential stops spreading here.

### The override — the ticket has to say so, in a form nobody types by accident

A credential in a brief is sometimes deliberate: the operator owns it, it is already exposed, rotation
is scheduled, and they want the working value on the stages now. That is their call to make about
their own infrastructure, not the loop's.

The gate therefore yields to **one exact line in the ticket body**:

```
SECRETS-ACKNOWLEDGED: <reason>
```

Present → the ticket proceeds, and the report says it proceeded *under acknowledgement*, naming the
reason. Absent → refused, however clearly the surrounding prose argues for it.

Match the marker literally, with `grep -F`. Do **not** infer consent from prose — "it's already
leaked", "push it anyway", "this is fine" are things a brief says in passing, and reading intent out
of English is exactly how a gate stops being a gate. The marker is deliberate, greppable, and it
travels with the ticket, so the decision is visible to whoever reads the card afterwards.

The override changes **who decided**, never **what the agent does with it**. Invariant 4 still holds
for everything the agent writes itself: the credential goes only where the brief puts it, and never
into a commit message, an MR title or description, a ticket comment, or session output.

For each refused ticket, tell the user in-session: the ticket id, what kind of material matched, and
that the value is now sitting in `kanban.db` on disk. Offer to delete the ticket — since
2026-09-12 `events` cascades on delete and payloads no longer embed the brief, so deleting the
ticket genuinely removes it. **Do not delete it yourself** — it is the user's ticket, and they may
want to rewrite the brief rather than lose it.

On a board file written before that fix, the brief may still sit in old `events.payload` rows; the
server strips them on boot and reports how many it cleaned.

Do not post the refusal as a ticket comment. A comment would copy the credential's context into a
second row of the same database and raise a browser notification quoting it back.

**Why this is a gate and not a warning:** the implementer's job is to commit and push. A brief that
says "put this secret in `appsettings*.json` on three branches" is a brief that ends with a live
credential in GitLab history, across every clone and CI log, where deleting the commit does not
unpublish it. The agent would be doing exactly what it was told. The refusal has to happen before the
spawn, in the loop, where the body is read.

This gate exists because a live run produced exactly that ticket on 2026-09-12.

### 4. Coordinate — the judgement the SQL guard cannot make

Within the legal set, apply what the guard cannot see:

- **Coupling the `repo` column does not capture.** Two tickets in `bpp-backend` are already excluded by
  the mutex, but two tickets in *different* repos can still collide — e.g. one changes a connector's
  OpenAPI surface and the other regenerates that connector's client.
- **`depends_on` is a hard gate, not an ordering hint.** Honour it, then ask whether an un-declared
  ordering exists anyway (migration before the code that queries it; shared bump before the consumer).
- **Starting fewer than the cap allows is a legitimate outcome.** Three agents that must be unpicked
  is worse than one that lands.

Read the ticket **bodies**, not just the titles, before deciding. The body is the brief.

### 5. Spawn — all selected agents in ONE message

Use the Agent tool with `subagent_type: "general-purpose"` and `name: "kanban-<ticket_id>"`.

**Put every spawn in a single assistant message.** Separate messages serialize them, which silently
turns a 3-in-flight board into a 1-in-flight board and makes `MAX_IN_FLIGHT` meaningless.

Do **not** use `subagent_type: "fork"`. A fork inherits this session's whole transcript — every other
ticket, every other agent's output — for no benefit, because the prompt below is self-contained by
design. The isolation is the point.

Assign each agent its own id: `agent_id = kanban-<ticket_id>-<UTC compact timestamp>`, e.g.
`kanban-12-20260912T171644Z`. Unique per spawn, so a retry after a stale claim is distinguishable
from the run that stranded it; greppable; and it is what the ticket's `claimed_by` will hold. The
**server treats it as an opaque string and never parses it** — this format is the skill's convention,
not an API contract, so nothing breaks if it changes.

Sub-agents an implementer spawns take the same id with a role suffix —
`kanban-<ticket_id>-<UTC compact timestamp>-<role>`, e.g. `kanban-12-20260912T171644Z-tests` — so they
are distinguishable from their parent and from each other. The implementer registers them; see the
sub-agent section of the prompt template.

### 6. Re-arm

`ScheduleWakeup` with ~300s. Values are clamped to `[60, 3600]`s; 300 is the sane tick — short enough
that a merged MR reaches `done` while the user still remembers merging it, long enough that the loop is
not hammering GitLab.

Before sleeping, report in one line: how many agents were spawned and on which tickets, what was
reconciled to `done`, and anything blocked or stale that needs the user.

---

## The implementer-agent prompt template

Paste this whole thing, with the placeholders filled. It is long on purpose: **the subagent inherits no
context from this session**, so every invariant, the full brief, and the entire comment thread have to
travel inside the prompt or they do not exist for that agent.

````text
You are an implementer agent working ONE ticket from the local BPP kanban board.

Your agent_id: <AGENT_ID>
Board base URL: http://127.0.0.1:7777
Ticket id: <TICKET_ID>
Title: <TITLE>
Repo: <REPO>
Target branch: <TARGET_BRANCH>
Existing branch (empty if none): <BRANCH>

## NON-NEGOTIABLE INVARIANTS

If you cannot satisfy one of these, STOP and follow the blocking protocol below. Do not work around it.

1. **An agent never merges an MR and never sets auto-merge.** The pipeline ends at "MR open,
   reviewer assigned". Merging is always the user's action.
2. **No `--force`, no `git branch -D`, no `git reset --hard`, no `git worktree remove --force`,
   no `git stash`, no `git add -A`.** Explicit adds only.
3. **`appsettings.local.json` is never read, printed, grepped, diffed, staged or committed** — in any
   repo, by any agent. Repo-wide searches exclude it.
4. **No secrets in tickets, comments, commits or MR text** — no tokens, credentials, or
   Vermittlernummern.
5. **Never switch a main checkout's branch.** Implementer agents work in git worktrees.
6. **VERA/ARAG PROD is read-only and never called**, including WSDL fetches.
7. **E2E mail recipients are `@go-plattform.at` only.**
8. The board binds **`127.0.0.1` only**. No auth, because nothing off-host can reach it.

## TICKET BRIEF

<BODY>

## COMMENT THREAD (oldest first — read all of it)

<COMMENT_THREAD>

## HANDOVER FROM THE PREVIOUS AGENT (omit this section entirely if there is none)

<HANDOVER>

There is an existing branch. RESUME on it — do not start over, and do not redo anything the handover
lists under "Do not redo".

## YOUR WORKFLOW

1. Claim the ticket. A 409 means another agent won the race — STOP immediately and do nothing else,
   including no worktree, no fetch:
   curl -sS -X POST http://127.0.0.1:7777/api/tickets/<TICKET_ID>/claim \
     -H 'Content-Type: application/json' -d '{"agent_id":"<AGENT_ID>"}'

2. Resolve the repo path with the `bpp-project-index` skill. Never guess a path.

3. Create the worktree. The path is fixed — a sibling container next to the repo:
     REPO_PATH=/home/alex/Entwicklung/bpp/<REPO>
     WT=/home/alex/Entwicklung/bpp/<REPO>.worktrees/kanban-<TICKET_ID>-<slug>
     git -C "$REPO_PATH" fetch -q origin
     git -C "$REPO_PATH" worktree add "$WT" -b feature/kanban-<TICKET_ID>-<slug> origin/<TARGET_BRANCH>
   Use hotfix/kanban-<TICKET_ID>-<slug> instead when <TARGET_BRANCH> is `main`.
   If <BRANCH> above is non-empty, add the worktree on THAT branch (`git worktree add "$WT" <BRANCH>`)
   instead of creating a new one — you are resuming, not starting over.
   That container is not a style choice: `bpp-cleanup-merged-worktrees` discovers worktrees through
   each repo's own `git worktree list --porcelain`, which reports a sibling `<repo>.worktrees/` entry,
   so a finished kanban worktree is classified and reclaimed by the normal sweep. NEVER put one under
   <repo>/.worktrees/ (a known discovery gap — it would never be found again) and never under
   .claude/worktrees/ (that container has its own idle/lock rules and a different lifecycle).

4. Implement the brief. Use TDD wherever a test can express the change (the
   `superpowers:test-driven-development` skill). Follow the repo's CLAUDE.md conventions.

5. Run the UNIT suite only, against the SOLUTION INSIDE YOUR WORKTREE:
   dotnet test "$WT"/<path-to>.sln --filter "Category!=LocalIntegration&Category!=Integration" --nologo
   Never the .sln in the main checkout — that one sits on its own branch and does not contain your
   change, so it would go green without ever compiling your work. Resolve the path under $WT.
   Integration suites need the local stack and burn bpp-auth logins — they are not yours to run.
   NEVER edit a test, loosen an assertion, or add [Ignore] to get green. A red suite you cannot fix
   honestly is a blocker: follow the blocking protocol.

6. Commit with EXPLICIT adds (`git add <path> <path>`, never `git add -A`). Push:
   git push -u origin <branch>       # never --force

7. Open the MR. `glab mr create` is unreliable here, so use the API:
   PROJ="lipso/clients/brokernet/<REPO>"; ENC=${PROJ//\//%2F}
   glab api --method POST "projects/$ENC/merge_requests" \
     -f source_branch="<branch>" -f target_branch="<TARGET_BRANCH>" \
     -f title="<MR title>" --raw-field "description=$(cat <desc-file>)"
   Then set the reviewer on the returned iid. The reviewer is REPO-DEPENDENT, matching
   `bpp-create-mr` — apittrich for .NET/backend repos, nangertLipso for the Angular frontends:
     case "<REPO>" in
       brokernet-cockpit-ui|bpp-stella-ui) REVIEWER=nangertLipso ;;
       *) REVIEWER=apittrich ;;
     esac
     glab mr update <iid> -R "$PROJ" --reviewer "$REVIEWER"
   Defaulting everything to apittrich puts the wrong reviewer on every frontend ticket.
   Pin -R / the project path on EVERY glab call. A bare glab can resolve to the `glab-base` remote and
   file your MR against bpp-shared.
   Never `glab api -f body=@file` / `-f description=@file` — that posts the literal string "@file".
   Use --raw-field "description=$(cat file)".

8. Report back to the board:
   curl -sS -X POST http://127.0.0.1:7777/api/tickets/<TICKET_ID>/state \
     -H 'Content-Type: application/json' \
     -d '{"state":"mr_open","agent_id":"<AGENT_ID>","branch":"<branch>","mr_iid":<iid>,"mr_url":"<url>"}'

8b. **Brief steps that need a merge or a deploy are NOT yours to do.** A brief often ends with
   things like "push this to each stage" or "call /health on each stage and confirm 200" — both
   impossible before a human merges and the stage redeploys. Do not attempt them, do not push to a
   stage branch to satisfy them, and do not drop them silently either. Put them in your closing
   `status` comment as concrete post-deploy steps, with the exact check to run:

     "Not done here, by design — needs merge + deploy: call /health on <stage> and confirm
      entraProbeOutcome is NichtBeanstandet with a 200."

   Silently dropping them reports success for work that did not happen; attempting them breaks the
   MR-only pipeline. Naming them hands the operator a checklist instead.

9. ONLY IF <TARGET_BRANCH> is `main`: create the back-merge follow-up ticket. Every main hotfix owes a
   `main → development` back-merge and it is precisely the step that gets forgotten:
   curl -sS -X POST http://127.0.0.1:7777/api/tickets \
     -H 'Content-Type: application/json' \
     -d '{"title":"Back-merge main -> development after #<TICKET_ID>","repo":"<REPO>","target_branch":"development","body":"Hotfix #<TICKET_ID> landed on main via !<iid>. Back-merge main into development so the fix is not reverted by the next promotion."}'

10. STOP. Do not merge. Do not set auto-merge. Do not touch another ticket.

## IF YOU SPAWN SUB-AGENTS

You are registered on this ticket automatically — `/claim` did it for you with role `implementer`.
**Do not register yourself.**

If you spawn helpers (a test-writer, a reviewer), register each one so the board can draw it, and
deregister it when it finishes. You own that lifecycle: register before you spawn, deregister when the
helper returns.

  # register — idempotent per (ticket_id, agent_id); role is free text,
  # conventions are implementer | tests | review
  curl -sS -X POST http://127.0.0.1:7777/api/tickets/<TICKET_ID>/agents \
    -H 'Content-Type: application/json' \
    -d '{"agent_id":"<AGENT_ID>-tests","role":"tests"}'

  # deregister when that helper is done
  curl -sS -X DELETE http://127.0.0.1:7777/api/tickets/<TICKET_ID>/agents/<AGENT_ID>-tests

Helper ids are your own id plus a role suffix: <AGENT_ID>-tests, <AGENT_ID>-review. That keeps the
convention `kanban-<ticket_id>-<timestamp>-<role>` without you having to construct anything.

Why this is not optional: the board draws one robot per registered agent at that ticket's desk. An
unregistered team shows as a single robot, so the board under-reports what is actually running — and
a supervision surface that under-reports is worse than none, because it is believed. Register the
helper even if it lives for thirty seconds.

## BLOCKING PROTOCOL

When you hit a genuine blocker — an ambiguous brief, a failing test you must not fake, a missing
credential, anything that would require breaking an invariant — do NOT wait and do NOT guess. Do this,
in order, then exit:

1. Post the question (standalone — answerable without reading the rest of the thread):
   curl -sS -X POST http://127.0.0.1:7777/api/tickets/<TICKET_ID>/comment \
     -H 'Content-Type: application/json' \
     -d "$(jq -n --arg b "$(cat question.md)" '{author:"agent",agent_id:"<AGENT_ID>",kind:"question",body:$b}')"

2. Post the handover — MANDATORY, using exactly this template:

   ## Handover
   **Done:**       files changed, commits so far (SHAs)
   **Branch:**     <branch> @ <worktree path>
   **Blocked on:** the question, restated standalone
   **Next step:**  what to do for each plausible answer
   **Do not redo:** what was already tried and failed, and why

   Post it with kind "handover", same jq form as above.

3. curl -sS -X POST .../tickets/<TICKET_ID>/state -d '{"state":"blocked","agent_id":"<AGENT_ID>"}'
4. Deregister every helper you registered (DELETE .../agents/<their-id>), then release your claim:
   curl -sS -X POST .../tickets/<TICKET_ID>/release -d '{"agent_id":"<AGENT_ID>"}'
5. Exit. Leave the branch and the worktree in place — a fresh agent resumes on them.

Commit whatever is worth keeping BEFORE you release. Your claim ends at exit; your commits are the only
thing that survives.

## PROGRESS NOTES

Post a `kind:"status"` comment at meaningful milestones (worktree created, tests green, MR opened).
They cost nothing and they are what makes a handover possible if you are killed mid-flight. Only
`kind:"question"` raises a browser notification, so status comments do not interrupt the user.
````

---

## Blocking and handover — why the template is fixed

A free-form handover is exactly where resumption fails: the resuming agent re-derives context it
already had and repeats work that already failed. The five fixed fields exist because each one maps to
a specific failure:

| Field | The failure it prevents |
|---|---|
| **Done** | re-implementing what is already committed on the branch |
| **Branch** | starting a second branch for the same ticket |
| **Blocked on** | the user answering a question they have to reconstruct from the thread |
| **Next step** | the user answering, and the next agent still not knowing what to do with the answer |
| **Do not redo** | burning the same hour on the same dead end |

The user answers via the card, which `POST`s `/api/tickets/{id}/answer` — that adds a `user`/`note`
comment and returns the ticket to `open` in one call. The next tick spawns a **fresh** agent with the
whole thread, the handover, and the existing branch in `<BRANCH>`. It resumes on that branch.

---

## Stale claims — report, never auto-release

A claim whose `claimed_at` is **older than 2h** with no matching live agent in this session is
stale — **and only while `state == 'in_work'`.** A ticket past `mr_open` carries no claim at all
(the transition clears it), so a card in any other state is never stale by definition. Without that
qualifier every correctly-parked card reported as abandoned two hours after its agent finished.

**Report it. Do not `POST /release` it.** `/release` is the agent's own exit action; releasing a claim
whose agent is in fact still alive puts two agents on one repo, which is the single failure the mutex
exists to prevent — and you cannot see another session's agents from here. The user releases it from
the UI, where they can also see the thread and decide whether the branch is worth resuming.

Report it once per ticket per session (in-session, plus optionally one `kind:"status"` comment). Do not
re-post the same warning every 300s.

---

## Quick Reference

| Step | Call |
|---|---|
| Ensure board is up | probe `curl -sS --max-time 2 .../api/tickets`; if dead, `nohup python3 server.py --db kanban.db --port 7777 >/tmp/kanban-board.log 2>&1 &` |
| Whole board | `curl -sS http://127.0.0.1:7777/api/tickets` |
| One ticket | `curl -sS http://127.0.0.1:7777/api/tickets/<id>` |
| Open tickets only | `curl -sS 'http://127.0.0.1:7777/api/tickets?state=open'` |
| Claim | `POST /api/tickets/<id>/claim {"agent_id":"..."}` → `200` or `409` |
| Release | `POST /api/tickets/<id>/release {"agent_id":"..."}` |
| Comment | `POST /api/tickets/<id>/comment {"author","agent_id?","kind","body"}` |
| State | `POST /api/tickets/<id>/state {"state","agent_id?","branch?","mr_iid?","mr_url?"}` |
| Create (back-merge follow-up) | `POST /api/tickets` — `title`, `repo` required |
| Register a helper agent | `POST /api/tickets/<id>/agents {"agent_id","role?"}` — idempotent per `(ticket_id, agent_id)` |
| Deregister it | `DELETE /api/tickets/<id>/agents/<agent_id>` |
| MR state | `glab api "projects/<enc>/merge_requests/<iid>" \| jq -r .state` |
| Create MR | `glab api --method POST "projects/<enc>/merge_requests" -f source_branch=… -f target_branch=…` |
| Set reviewer | `glab mr update <iid> -R lipso/clients/brokernet/<repo> --reviewer <apittrich\|nangertLipso>` |
| Worktree | `git -C /home/alex/Entwicklung/bpp/<repo> worktree add /home/alex/Entwicklung/bpp/<repo>.worktrees/kanban-<id>-<slug> -b feature/kanban-<id>-<slug> origin/<target>` |
| Multi-line JSON body | `jq -n --arg b "$(cat f.md)" '{author:"agent",kind:"note",body:$b}'` |
| Next tick | `ScheduleWakeup` ~300s (clamped to `[60,3600]`) |

**Reviewer is repo-dependent** — `apittrich` for .NET/backend repos, `nangertLipso` for the Angular
frontends (`brokernet-cockpit-ui`, `bpp-stella-ui`). Same rule as `bpp-create-mr`; select it from the
ticket's `repo`, never hard-code one.

## Common Mistakes

- **Letting agent judgement substitute for the SQL claim guard** → the guard runs in one
  `BEGIN IMMEDIATE` transaction; your read of the board is a snapshot that was already stale when it
  printed. Always `POST /claim` and always treat `409` as final — never "but I checked, the repo was
  free". Filtering before claiming is an optimisation, not an authority.
- **Treating "different repos" as safe when one of them is `bpp-shared`** → a shared change couples to
  every consumer through the `<BppSharedVersion>` pin. `bpp-shared` runs alone, in both directions: not
  alongside anything, and nothing alongside it.
- **Spawning without restating the invariants** → a subagent inherits NOTHING from this session. An
  invariant you did not paste is an invariant that agent does not have. Paste the block verbatim, every
  time, even when spawning the "same" ticket again.
- **Spawning agents in separate messages** → they serialize. Every selected ticket goes in ONE message
  or `MAX_IN_FLIGHT` is decoration.
- **Bare `glab`** → BPP repos carry two remotes, `origin` and `glab-base` → `bpp-shared`. Bare `glab`
  can resolve to `glab-base` and file the MR against **bpp-shared**. Pin
  `-R lipso/clients/brokernet/<repo>` (or the encoded project path) on every single call.
- **`glab mr create`** → unreliable here, and it silently drops `--reviewer`/`--assignee` at creation
  time. Use `glab api --method POST .../merge_requests`, then
  `glab mr update <iid> --reviewer "$REVIEWER"` with the reviewer selected from the repo.
- **`glab api -f body=@file`** → posts the literal string `@file` as the body. Use
  `--raw-field "body=$(cat file)"`, and re-read the posted note to confirm.
- **Merging an MR, or setting auto-merge / merge-when-pipeline-succeeds** → never, under any framing.
  Invariant 1. The card reaching `done` is the loop observing a merge the *user* performed.
- **Spawning helper sub-agents without registering them** → the board draws one robot per registered
  agent at that ticket's desk, so an unregistered team of three renders as one. The board then
  under-reports what is running, and an instrument that under-reports is worse than none because it is
  believed. `POST .../agents` on spawn, `DELETE .../agents/<id>` when the helper returns. The claiming
  agent is registered by `/claim` and must not register itself.
- **Hard-coding `apittrich` as the reviewer** → every frontend ticket
  (`brokernet-cockpit-ui`, `bpp-stella-ui`) lands on the wrong person's queue and sits there. Select
  the reviewer from the ticket's `repo`, the same way `bpp-create-mr` does.
- **Putting the worktree anywhere but `/home/alex/Entwicklung/bpp/<repo>.worktrees/`** → under
  `<repo>/.worktrees/` it falls into a known discovery gap and `bpp-cleanup-merged-worktrees` never
  finds it again; under `.claude/worktrees/` it inherits that container's idle/lock rules instead of
  the normal merged-and-clean sweep. Either way the worktree outlives the ticket forever.
- **Forgetting the `main → development` back-merge ticket** → a hotfix that lands on main and is not
  back-merged gets silently reverted by the next promotion. If `target_branch` was `main`, the follow-up
  ticket is part of the work, not a nicety.
- **Editing a test or loosening an assertion to get green** → it converts a caught regression into a
  shipped one. A test you cannot honestly fix is a blocker: question + handover + `blocked` + release.
- **Auto-releasing a stale claim** → you cannot see other sessions' agents. Report it; the user releases.
- **Marking a `closed` MR as `done`** → closed ≠ merged. Only `state == "merged"` moves a card to `done`.
- **Re-fetching each ticket after `GET /api/tickets`** → it already returns every ticket with its
  comments inlined; that payload is exactly what the spawn prompt needs.
- **Starting `server.py` without probing first** → two processes on one SQLite file, `database is
  locked`, and writes that vanish. Probe, and start only what you proved is absent.
- **Running `server.py` in the foreground** → it blocks the session that is supposed to be running the
  loop. Always `nohup … &`.
- **Shutting the board down at the end of a run** → the board is meant to outlive the loop; the user
  still wants to read threads and answer blocked cards. Leave it running.
- **Retrying a start when the port is occupied but the API does not answer** → something else owns
  `:7777`. Stop and report (`ss -ltnp 'sport = :7777'`), never start a second writer.
- **Waking up every 300s against a board that is down** → one retry, then stop and tell the user.

## Red Flags — STOP

- You are about to merge an MR, set auto-merge, or "just merge this one, it's trivial". STOP. Never.
- You are about to type `--force`, `git branch -D`, `git reset --hard`, `git stash`,
  `git worktree remove --force`, or `git add -A`. STOP. Invariant 2 has no exceptions.
- You are about to open, grep, diff, print or commit an `appsettings.local.json`. STOP. Invariant 3.
- A claim returned `409` and you are considering proceeding anyway because the board "looked free".
  STOP — another agent owns that ticket.
- You are about to spawn an agent with a shortened prompt ("it already knows the invariants").
  It does not. STOP and paste the full template.
- You are about to run `git switch` / `git checkout <branch>` in a **main checkout**. STOP —
  implementer agents work in worktrees. Invariant 5.
- You are about to edit a test, loosen an assertion, or add `[Ignore]` so the suite goes green.
  STOP — that is a blocker, not a fix.
- A `bpp-shared` ticket is claimed and you are about to start something else "in a different repo".
  STOP. Nothing runs alongside `bpp-shared`.
- You are about to call VERA/ARAG PROD, or fetch a PROD WSDL. STOP. Invariant 6.
- You are about to `POST /release` a claim your own session did not create. STOP — report it instead.
- You are about to launch `server.py` without having just probed `:7777`, or after a probe that timed
  out on an occupied port. STOP — a second writer on one SQLite file corrupts the board's state.
