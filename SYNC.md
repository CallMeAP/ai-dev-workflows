# Sync rule

These two locations mirror each other's tracked `.md` files:

- **Canonical (source):** `/home/alex/Entwicklung/ai-dev-workflows`
- **Mirror (published):** `/home/alex/Entwicklung/lipso/agentic-coding-knowledge` — since 2026-09-09 the bpp-* skills live in the repo-level
  `skills/<name>/` (de-personalised), NOT under `personal-workflows/apittrich/`. Only personal-only skills
  (`gs-*`, `lipsum-stundenliste`, `sync-my-skills`) remain under `personal-workflows/apittrich/skills/`.

**Rule:** edit in the source. When source `.md` files change, mirror them to
the published copy (source → mirror). Keep both in sync.

**Scope:** tracked `.md` only — top-level `*.md` + `skills/**/*.md`.

**Placeholders (mirror only).** Files under the mirror's repo-level `skills/` carry `{{BPP_ROOT}}`,
`{{BROKERNET_ROOT}}`, `{{DEV_USER}}`, `{{WORKFLOWS_DIR}}`, `{{KNOWLEDGE_DIR}}` instead of absolute paths, and are
rendered per developer by `./install.sh --env personal-workflows/<user>/paths.env skills <name>`. So a sync to the
mirror must **reverse-render** the local literal paths into placeholders, then verify by rendering back with your own
`paths.env` and diffing against the live skill. Never push literal `/home/<you>/...` paths into `skills/` — it breaks
`install.sh` for every other developer. The canonical repo keeps literal paths; only the mirror is templated.

**Mirror changes go on a `docs/*` branch + MR**, matching how the mirror repo ships (`MIRRORS.md`). The standing
auto-push approval below applies to the canonical remote and to pushing the `docs/*` branch — not to merging it.
Exclude `memory/` (gitignored) and non-`.md` files (e.g. `runAgents.sh`).

**Manual convention:** nothing auto-syncs. Any agent or human editing one
side must mirror the change to the other before finishing.

**Auto-push allowed (standing approval):** agents may commit and push synced
changes to BOTH remotes without asking each time —
`github.com/CallMeAP/ai-dev-workflows` (`main`) and
`gitlab.com/lipso/internal/agentic-coding-knowledge` (`main`).
Plain pushes only — never `--force`.
