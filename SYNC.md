# Sync rule

These two locations mirror each other's tracked `.md` files:

- **Canonical (source):** `/home/alex/Entwicklung/ai-dev-workflows`
- **Mirror (published):** `/home/alex/Entwicklung/lipso/agentic-coding-knowledge/personal-workflows/apittrich`

**Rule:** edit in the source. When source `.md` files change, mirror them to
the published copy (source → mirror). Keep both in sync.

**Scope:** tracked `.md` only — top-level `*.md` + `skills/**/*.md`.
Exclude `memory/` (gitignored) and non-`.md` files (e.g. `runAgents.sh`).

**Manual convention:** nothing auto-syncs. Any agent or human editing one
side must mirror the change to the other before finishing.
