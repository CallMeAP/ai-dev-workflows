# Sync rule

These two locations mirror each other's tracked skill content — `.md` plus the support files a skill invokes (see **Scope**):

- **Canonical (source):** `/home/alex/Entwicklung/ai-dev-workflows`
- **Mirror (published):** `/home/alex/Entwicklung/lipso/agentic-coding-knowledge` — the bpp-* skills live in
  `bpp/skills/<name>/` (de-personalised), NOT under `personal-workflows/apittrich/` and NOT in a repo-level
  `skills/`, which does not exist there. `install.sh` renders from `$here/bpp/skills/$s` and is the authority —
  confirm the path from it rather than from this file. (Corrected 2026-09-22: this said "repo-level `skills/`",
  which has zero tracked files; writing there puts a skill where `install.sh` never looks.) Only personal-only skills
  (`gs-*`, `lipsum-stundenliste`, `sync-my-skills`) remain under `personal-workflows/apittrich/skills/`.

**Rule:** edit in the source. When source files in scope change, mirror them to
the published copy (source → mirror). Keep both in sync.

**Scope:** top-level `*.md` + the **whole** of `skills/**` — `SKILL.md`, reference `.md`, and the
support files a skill actually invokes (`.sh`, `.py`, …). `.md`-only was the rule until 2026-09-11 and
it shipped broken skills: `lipsum-stundenliste` reached the mirror without `make_stundenliste.py`, so
its documented `python3 …/make_stundenliste.py` failed with "No such file or directory". A skill is
mirrored complete or not at all.

Still excluded from the **skills** sync: top-level `runAgents.sh` and large binary fixtures — those are not
invoked from the skill directory.

`memory/` is **not** excluded from the mirror: it is gitignored in the canonical repo, but the mirror tracks it
under `personal-workflows/<user>/memory/` (260 files as of 2026-09-22), and SYNC.md previously claimed the
opposite. Memory files are edited in place in both locations, not copied by the skills sync.

**Support files obey the placeholder rule too.** A `.sh`/`.py` under the mirror's shared `bpp/skills/`
carries `{{...}}` exactly like the `.md` does (`start_local_stack.sh` ships `ROOT="{{BPP_ROOT}}"`), and
`install.sh` renders it and preserves the executable bit. Under `personal-workflows/` support files stay
literal, like their `SKILL.md`. **Secret-scan every support file before staging** — executables are
where a stray token would land.

**Placeholders (mirror only).** Files under the mirror's `bpp/skills/` carry `{{BPP_ROOT}}`,
`{{BROKERNET_ROOT}}`, `{{DEV_USER}}`, `{{WORKFLOWS_DIR}}`, `{{KNOWLEDGE_DIR}}` instead of absolute paths, and are
rendered per developer by `./install.sh --env personal-workflows/<user>/paths.env skills <name>`. So a sync to the
mirror must **reverse-render** the local literal paths into placeholders, then verify by rendering back with your own
`paths.env` and diffing against the live skill. Never push literal `/home/<you>/...` paths into `bpp/skills/` — it breaks
`install.sh` for every other developer. The canonical repo keeps literal paths; only the mirror is templated.

**Mirror changes go on a `docs/*` branch + MR**, matching how the mirror repo ships (`MIRRORS.md`). The standing
auto-push approval below applies to the canonical remote and to pushing the `docs/*` branch — not to merging it.
See **Scope** above for what is excluded.

**Manual convention:** nothing auto-syncs. Any agent or human editing one
side must mirror the change to the other before finishing.

**Auto-push allowed (standing approval):** agents may commit and push synced
changes to BOTH remotes without asking each time —
`github.com/CallMeAP/ai-dev-workflows` (`main`) and
`gitlab.com/lipso/internal/agentic-coding-knowledge` (`main`).
Plain pushes only — never `--force`.
