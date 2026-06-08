---
name: bpp-check-translation-keys
description: Use when translation/i18n keys added in brokernet-cockpit-ui are missing or not "nachgezogen" in bpp-backend — phrases like "check translation keys", "find missing i18n keys", "which transloco keys are missing in de.json/en.json", "are cockpit-ui keys synced to backend", "missing translations", untranslated keys rendering as raw strings.
---

# BPP: Check cockpit-ui translation keys against bpp-backend

## Overview

`brokernet-cockpit-ui` has **no local translation files** — at runtime Transloco fetches them from bpp-backend (`environment.bppBackend + '/i18n/{lang}.json'`). So the served files **`BPP.Backend.NET.App/wwwroot/i18n/de.json` + `en.json`** are the single source of truth. When a dev adds a `… | transloco` key in the UI but forgets to add it to those JSONs, the user sees the raw key string.

This skill extracts every statically-referenced transloco key from cockpit-ui and reports the ones absent from the backend de/en files. **Read-only, report-only** — it never edits any file or switches any branch.

## When to Use

- Translations render as raw keys (`customerSign.signHere`) in the cockpit UI.
- After a cockpit-ui feature merge, to confirm its keys were carried into bpp-backend.
- Periodic drift check between German and English (`de.json` vs `en.json`).

## How to Use

```bash
./check-i18n-keys.sh
```

Override clone locations if needed:
```bash
UI_REPO=/path/to/brokernet-cockpit-ui BE_REPO=/path/to/bpp-backend ./check-i18n-keys.sh
```

Resolve repo paths via `bpp-project-index` if unsure (`brokernet-cockpit-ui`, `bpp-backend`).

## What it does

- Compares **`origin/development` → `origin/development`** for both repos (after `git fetch`). Reads via `git grep <ref>` and `git show <ref>:file` — no checkout, no clean-tree requirement, both working trees untouched.
- Extracts referenced keys from cockpit-ui: template `'x.y' | transloco` pipes **and** TS `translate()/selectTranslate()/selectTranslateObject()/translateObject()` string literals.
- Diffs against the flat dotted-key sets in `de.json` and `en.json`.

## Output buckets

| Bucket | Meaning |
|--------|---------|
| **MISSING in BOTH de+en** | New key never added to the backend — fix first. |
| **MISSING in EN only** | German added, English not *nachgezogen* (the common drift). |
| **MISSING in DE only** | Rare; usually a typo or EN-first key. |
| **UNRESOLVABLE / dynamic** | Listed with file:line, **never** counted as missing — must be eyeballed. |

Each missing key prints the first cockpit-ui `file:line` that references it. Fixing = add the key + real translation text to the backend JSON(s); this skill does not write them.

## Limitations (state these, don't imply full coverage)

- **Dynamic keys are blind spots:** `'prefix.' + var`, `titleKey() | transloco`, ternaries, and `selectTranslateObject('primeng')` subtree loads can't be resolved statically — they land in the dynamic bucket for manual review.
- **Component `@Input` key-strings** (a key passed to a child component prop, not via a transloco marker) are not detected.
- A key in the "missing" list that is actually loaded dynamically is a false positive — verify against the dynamic bucket before assuming a real gap.

## Common mistakes

- Diffing two JSON files — wrong: cockpit-ui has no JSON to diff; keys live in `.html`/`.ts` source.
- Running against a feature branch — the skill pins both sides to `origin/development` on purpose.
- Treating the dynamic count as "also missing" — it is explicitly excluded from the missing totals.
