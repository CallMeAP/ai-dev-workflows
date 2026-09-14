# bpp-kanban-loop

## Placeholders

**None — and that is deliberate.** This is a *personal* skill: per
[`SYNC.md`](../../SYNC.md), skills under `personal-workflows/apittrich/skills/` keep **literal
absolute paths and real usernames** and are not rendered by `install.sh`. So `/home/alex/...`,
`apittrich`, `lipso/clients/brokernet/*` and `http://127.0.0.1:7777` appear as themselves in
`SKILL.md`, not as `{{BPP_ROOT}}`-style templates.

Consequence: on any other machine, or for any other developer, every one of those paths and the
reviewer name are wrong. Templating it is the job of a move into the shared top-level `/skills`, not
of a find-and-replace here.

## Prerequisites

- **The board** at `http://127.0.0.1:7777` — but you do **not** have to start it yourself. The skill
  probes it and, if it is not answering, starts it with
  `nohup python3 server.py --db kanban.db --port 7777 >/tmp/kanban-board.log 2>&1 &` from
  `/home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich/kanban/`, then
  waits for the API before ticking. So after a reboot the answer is just: invoke `bpp-kanban-loop`.
  If the start fails, the traceback is in `/tmp/kanban-board.log`.
  The board deliberately **outlives** the loop — ending the session stops the loop, not `server.py`.
  See [`../../kanban/README.md`](../../kanban/README.md).
- **`glab` authenticated** (`glab auth status`). Used for two things: reading MR state when
  reconciling `mr_open` cards, and opening MRs from inside implementer agents.
- **The bpp fleet checked out** under `/home/alex/Entwicklung/bpp`. Implementer agents resolve the
  path for a ticket's `repo` through the `bpp-project-index` skill — they never guess one, and a repo
  that is not checked out locally cannot be worked.
- **A live, interactive Claude Code session.** The loop re-arms itself with `ScheduleWakeup`; that
  only exists while the session is alive. There is no daemon mode.
- `curl` and `jq`. `jq` is not optional — it is how multi-line markdown (handovers, MR descriptions)
  gets into JSON without being mangled.

## Repo layout it assumes

- Every BPP repo lives under `/home/alex/Entwicklung/bpp/<repo>` and its GitLab project is
  `lipso/clients/brokernet/<repo>`. The ticket's `repo` column is that bare repo name
  (`bpp-backend`, `bpp-file`, …) and is also the **concurrency key**.
- Each repo carries **two** git remotes: `origin` (the repo) and `glab-base`
  (→ `bpp-shared`). This is why every `glab` call in the skill is pinned with `-R`.
- Implementer agents create **git worktrees**; main checkouts are never switched. Branches are
  `feature/kanban-<id>-<slug>`, or `hotfix/kanban-<id>-<slug>` when the ticket targets `main`.
- Worktrees go in a **sibling container**: `/home/alex/Entwicklung/bpp/<repo>.worktrees/kanban-<id>-<slug>`.
  That is what `bpp-cleanup-merged-worktrees` finds via `git worktree list --porcelain`, so finished
  kanban worktrees are reclaimed by the ordinary sweep — not `<repo>/.worktrees/` (a discovery gap)
  and not `.claude/worktrees/` (separate idle/lock rules).
- `bpp-shared` is the special repo: a change there couples to every consumer through the
  `<BppSharedVersion>` pin, so the board's claim guard runs it alone.

## Shell / OS assumptions

Linux + bash. `${VAR//\//%2F}` (bash parameter expansion, used to URL-encode the project path for
`glab api`) is not POSIX `sh` — run the snippets under bash. Nothing else is exotic: `curl`, `jq`,
`git`, `glab`, `dotnet`.

Verified on this machine 2026-09-12: Python 3.12.3, sqlite3 3.45.1, glab 1.117.0.

## After install

Read the **invariants** section before the first run, then the **implementer-agent prompt template**.
The template is the skill — a spawned subagent inherits nothing from the loop session, so a shortened
prompt is not a shortened prompt, it is an unenforced invariant.

Two things this skill will never do, by design: **merge an MR** (the pipeline ends at "MR open,
reviewer assigned") and **auto-release a stale claim** (it reports; you release from the UI).

## Install

Personal skills are not templated and not rendered by `install.sh`. Copy the directory by hand:

```bash
cp -r /home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich/skills/bpp-kanban-loop \
      /home/alex/.claude/skills/bpp-kanban-loop
```

Invoke it bare: `/bpp-kanban-loop`. It arms its own recurring 5-minute schedule on first use
(`CronCreate`, guarded by a `CronList` check so re-invoking never stacks a second one) and then runs a
tick immediately. Stop it with `CronDelete` on the job id it reports.

The schedule is session-only — in memory, never written to disk, and gone when the Claude session ends.
Recurring jobs also auto-expire after 7 days. The board's `server.py` is unaffected by either: it is a
detached process and keeps running, which is deliberate.

## Verify it works

Read-only — this writes nothing to the board, creates no branch, spawns no agent:

```bash
# 1. board reachable and answering the endpoint the loop actually uses
#    (a non-200 here is fine — the skill starts the board itself; this just tells you which
#     path the next run will take, cold start or already-up)
curl -sS -o /dev/null -w 'tickets: %{http_code}\n' http://127.0.0.1:7777/api/tickets

# 2. the board's view of the world
curl -sS http://127.0.0.1:7777/api/tickets | jq -r '.[] | "\(.id)\t\(.state)\t\(.repo)\t\(.title)"'

# 3. glab authenticated, and pinning -R works against a real project
glab auth status
glab api "projects/lipso%2Fclients%2Fbrokernet%2Fbpp-backend" | jq -r .path_with_namespace

# 4. the fleet is where the skill expects it
ls -d /home/alex/Entwicklung/bpp/bpp-backend
```

Step 1 prints `200` when the board is already up; anything else just means the next run will cold-start
it. Step 3 must print `lipso/clients/brokernet/bpp-backend` — if it prints `bpp-shared`, the `glab-base`
remote won, and every MR this skill opens would land in the wrong repo.

---

*Written by an agent from the SKILL.md content and the kanban SPEC.md, not dictated by the skill's
owner — @apittrich should confirm it.*
