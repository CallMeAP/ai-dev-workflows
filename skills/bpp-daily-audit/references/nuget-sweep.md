# Phase G — NuGet update sweep

Runs after the report, with its own budget. **Delegates to the `bpp-update-nuget-packages` skill** —
that skill's hold matrix and restore-error decoder are the source of truth. Do not re-derive them
here; read it before acting on a bump.

## Scope

- Discovered repos that are **.NET** (contain a `*.sln`).
- `bpp-mail` and `bpp-js-report-connector` are **Maven** — skipped, with the reason reported.
- Repos with **no local checkout are skipped and reported**: `dotnet restore` needs the authenticated
  GitLab private feed and a working tree.
- Caps: 6 repos per run, 2 MRs per run — a separate budget that never consumes the code-fix MR cap.

## Branch

**`development`, always.** Package updates never target `staging` or `main`; they reach those
branches through the normal `bpp-promote-dev-to-staging` flow. This holds even when the outdated
reference is visible on `staging` or `main`.

## Detection — no model calls

```bash
dotnet restore "$SLN"
dotnet list "$SLN" package --outdated
dotnet list "$SLN" package --vulnerable --include-transitive
```

**`restore` succeeding does not mean the sweep works.** Verified 2026-09-08 on `bpp-backend`:
`dotnet restore` returned exit 0 (satisfiable from cache / existing assets) while
`dotnet list package --outdated` failed with `401 Unauthorized` — the private GitLab feed accepts the
restore but rejects the *version query*. Check each command's exit status separately.

A **401** is a credentials problem, not a finding: report it as a per-repo failure, leave the
ledger's `nuget.<repo>` entry untouched, do not remove the feed. Critically, when `--outdated` 401s
the report must say **the outdated check produced no data** — an empty outdated table is then not
evidence that nothing is outdated, and saying so is mandatory in the Degradations section.

### Transitive vulnerabilities

A `--vulnerable --include-transitive` hit is often **not directly referenced**. Before proposing
anything, establish which it is:

```bash
grep -rn '<PackageName>' --include='*.csproj' --include='*.props' .   # empty => transitive only
dotnet list <proj> package --include-transitive                       # find the parent
```

- **Direct reference** → a normal bump, subject to the hold matrix and the major-version rule.
- **Transitive, and the parent has a newer version that resolves it** → bump the parent, name both
  packages in the MR description.
- **Transitive, and the parent is already at its latest** → **escalate, never auto-MR.** The only
  remedy is a deliberate transitive override (a direct `PackageReference` pinning a fixed version of
  a package the repo does not otherwise reference), which changes the dependency graph and is a
  human decision. Real case 2026-09-08: `AngleSharp 0.17.1` (GHSA-pgww-w46g-26qg, moderate) pulled by
  `HtmlSanitizer 9.0.892`, itself already latest.

## Cadence

| Class | Cadence | Why |
|---|---|---|
| `--vulnerable` hits | **any day**, immediately | a CVE should not wait for Monday |
| routine `--outdated` bumps | **Mondays only** | daily package MRs across ~15 .NET repos is noise; the check still runs daily and the result is reported every day |

## Hard exclusions

1. **`<BppSharedVersion>`** in `BPP.*/Directory.Build.props` — owned by `bpp-bump-shared-version`.
   Never touched here. Also never edit a per-csproj `PackageReference` for `BPP.Shared.NET`; it reads
   the property.
2. **Every package in the hold matrix** — EF Core family + Npgsql, `Microsoft.AspNetCore.OpenApi` +
   Swashbuckle, `StackExchange.Redis`, FluentAssertions, AutoMapper, `MockQueryable.Moq`. A hold that
   *appears* to have dissolved is **reported for a human decision**, never bumped autonomously.
3. **Any major version bump** — reported, never auto-MR'd. Majors flip licences (FluentAssertions 8
   → Xceed commercial, AutoMapper 16 → commercial). "Latest" behind a paywall is not an update.
4. **TFM / .NET version changes** — out of scope entirely.

`--outdated` reports the absolute latest, **not** the latest compatible with the repo's TFM. Adopting
it blindly fails restore with NU1202. Check supported frameworks first.

## Verification before the MR

The local `bpp-shared` `ProjectReference` injected by `Directory.Build.props` via an `Exists(...)`
condition means a local build tests the local checkout, **not** the NuGet package. Temporarily
neutralise that condition for the duration of the check, then restore + build + unit test.

**The neutralisation is never committed.** Verify the working tree is clean of it before pushing.

If verification fails, escalate with the restore error decoded (NU1107 transitive cap, NU1202 TFM,
NU1605 downgrade — see `bpp-update-nuget-packages`) and open no MR.

## MR

| Field | Value |
|---|---|
| Source | `audit/<YYYY-MM-DD>-<repo>-nuget` |
| Target | `development` |
| Draft | no |
| Title | `AUDIT-BOT: NuGet package updates` |
| Label | `audit-bot` |
| Reviewer | `apittrich` |

The description lists every adopted bump **and — mandatory — an honest table of every package
deliberately held, with its reason.** A package-update MR without its held-packages table is not
reviewable; do not open one.

```markdown
### Adopted
| Package | From | To |

### Held (not bumped)
| Package | Held at | Reason |
| StackExchange.Redis | 2.13.17 | 3.x breaks StringSetAsync (When → Expiration overload) |

### Verification
Restore: <ok> · Build: <ok> · Unit tests: <passed | failed | not run>
Verified against the NuGet package (local bpp-shared ProjectReference neutralised for the check).
```
