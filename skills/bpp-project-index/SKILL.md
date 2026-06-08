---
name: bpp-project-index
description: Use when user mentions any BPP project (bpp-backend, bpp-auth, bpp-shared, bpp-stella, bpp-chat, bpp-file, bpp-push, bpp-mail, bpp-document-analysis, bpp-vera-connector, bpp-js-report-connector), a frontend (brokernet-cockpit-ui, brokernet-app / go-stella), or legacy Brokernet (old-brokernet, brokernet-backend, backend-* modules like backend-claim/customer/servo/polizzierung), or asks for the path/location of a BPP/Brokernet repo or module on this machine.
---

# BPP / Brokernet Project Index

## Overview

Path lookup reference for all BPP (.NET + Java) backends, the current frontends (brokernet-cockpit-ui, brokernet-app / go-stella), and legacy Brokernet (Java/Maven) projects on this machine. Read the index whenever a project name is mentioned to resolve its path and purpose before exploring or editing code.

## When to Use

- User names a BPP repo (`bpp-*`), a frontend (`brokernet-cockpit-ui`, `brokernet-app` / go-stella), or a Brokernet module (`backend-*`, `brokernet-*`).
- User asks "where is X", "what is Y", "path to Z" for BPP/Brokernet code or the cockpit/Stella frontends.
- Cross-project work needing to locate a sibling repo (e.g. `bpp-shared` from `bpp-backend`).
- Parity audits between new BPP .NET services and legacy Brokernet Java modules.

## How to Use

1. Read `/home/alex/Entwicklung/bpp/bpp-backend/dev/apittrich/project_index.md`.
2. Resolve the project name → absolute path under `/home/alex/Entwicklung/bpp/` or `/home/alex/Entwicklung/brokernet/`.
3. Use that path for subsequent file reads, greps, or `cd` operations.

## Notes

- File is gitignored (personal index), maintained by user — treat as source of truth.
- If a mentioned project is missing from the index, tell the user; do not guess paths.
- Two filesystem roots: `bpp/` (new backends) and `brokernet/` (legacy backends + the current `brokernet-cockpit-ui` / `brokernet-app` frontends — these are active, not legacy).
