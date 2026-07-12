---
name: bpp-update-nuget-packages
description: Use when updating/bumping NuGet packages in a BPP .NET repo to the latest versions compatible with the repo's CURRENT target framework — phrases like "update nuget packages", "bump all packages", "dotnet outdated", "package upgrade MR", or when hitting NU1107/NU1202/NU1605 restore conflicts during a bump. Packages only — TFM/.NET version upgrades are a separate task.
---

# bpp-update-nuget-packages

## Overview

Playbook for bumping all NuGet packages in a BPP .NET repo to the latest versions **compatible with the repo's current TFM** — distilled from the 2026-07-12 .NET-10 fleet run (12 repos). Core lesson: "latest" is NOT always adoptable — a handful of packages have hard holds (transitive caps, namespace breaks, commercial license flips). Classify before bumping; document every hold in the MR.

Scope: .NET repos only (bpp-mail / bpp-js-report-connector are Maven — different playbook).

## Discovering updates

```bash
dotnet restore <Solution>.sln          # needs GitLab private-feed auth; 401 = env, fix creds first
dotnet list <Solution>.sln package --outdated              # per-project latest columns
dotnet list <Solution>.sln package --include-transitive    # for diagnosing NU1107 caps
```

- `--outdated` shows the absolute latest, NOT the latest compatible with your TFM — adopting it can fail restore with **NU1202** (package targets a newer TFM). Check the package's supported frameworks before treating "latest" as the target.
- Bump by editing version attributes, not `dotnet add package` loops (which re-resolves and can reorder ItemGroups).

## Version sources of truth (BPP-specific)

- **BPP.Shared.NET**: version lives ONLY in `BPP.*/Directory.Build.props` → `<BppSharedVersion>`. NEVER edit the per-csproj `PackageReference` — it reads the property. Bumping shared = separate flow (`bpp-bump-shared-version` skill).
- **Local project-ref trap**: `Directory.Build.props` injects a local `bpp-shared` `<ProjectReference>` via an `Exists(...)` condition per developer. When verifying a bump against the real NuGet package, **temporarily neutralize your project-ref condition** — otherwise you build against your local shared checkout and the package path is untested (this hid a real restore failure during the fleet run).
- Everything else: per-csproj `PackageReference` version attributes; grep all `*.csproj` — some repos repeat the same package across projects; keep versions identical repo-wide.

## Hold matrix — do NOT blind-bump these

Holds marked (†) apply **while the consumed BPP.Shared.NET package still targets net9** — they dissolve after shared ships net10 + consumers bump `BppSharedVersion`.

| Package | Hold at | Why |
|---|---|---|
| EF Core family + Npgsql (†) | latest **9.x** (EF 9.0.17 / Npgsql 9.0.5 / provider 9.0.4 at fleet-run time) | shared's transitive `EFCore.NamingConventions` 9.0.0 caps EF `<10` → **NU1107**; shared bumps it to 10.0.1 on its net10 MR |
| Microsoft.AspNetCore.OpenApi + Swashbuckle (†) | OpenApi latest 9.x + Swashbuckle 9.0.6 | Microsoft.OpenApi 2.x **removes `Microsoft.OpenApi.Models`** → breaks SwaggerGen filters (shared's TranslocoEnumSchemaFilter, ConfigureServerUrl) |
| StackExchange.Redis | **2.13.17** (fleet pin) | 3.x breaks `StringSetAsync` (`When` → `Expiration` overload). 2.13.x already adds the Expiration overload — only code compiling `RedisService` (bpp-shared) hits the ambiguity; fix there is a 1-line `When.Always` |
| FluentAssertions | last adopted **pre-8** line (6.12.2 fleet baseline) | **8.x = Xceed commercial license.** Per-repo/user decision, never a mechanical bump (alt: AwesomeAssertions fork). Some repos already ship 8.x — don't downgrade those either |
| AutoMapper | 15.1.1 (fixes GHSA-rvv3-g6hj-g44x) | **≥16 commercial.** Backend/stella removed AutoMapper entirely — check it still exists before bumping |
| MockQueryable.Moq | 7.0.0 | ≥7.0.2 **moved the `BuildMock` namespace** → compile break unless you also fix usings |

License rule generalized: on any **major** bump, check the license didn't flip commercial (FluentAssertions 8, AutoMapper 16, Moq/SponsorLink history). "Latest" with a paywall is not an update.

## Always take

- **log4net ≥ 3.3.2** — CVE fix (GHSA-4f7c-pmjv-c25w).
- Test infra fleet standard: `Microsoft.NET.Test.Sdk` 18.x line / `NUnit3TestAdapter` 6.x / `coverlet.collector` 10.x — don't "align down" to 17.x based on stale examples in older repos (id-austria/cca lagged; fleet majority is the 18 line).
- Patch/minor bumps of everything not in the hold matrix.

## Restore-error decoder

| Error | Meaning | Fix |
|---|---|---|
| **NU1107** | version conflict via a transitive cap | `--include-transitive` to find the capping package; hold at the cap (see matrix) or bump the capper |
| **NU1202** | package's latest doesn't support your TFM | take the newest version that does |
| **NU1605** | detected package downgrade after a bump | another ref pulls a NEWER transitive — raise your direct ref to match (hit on AutoMapper 15.0.1→15.1.1 adopt) |
| restore **401** | GitLab private feed auth | environment, not the bump — fix NuGet creds, never remove the feed |

## Process

1. Temp worktree off `origin/development` (`git worktree add … -b chore/nuget-bumps`); never switch main checkouts.
2. Bump non-hold packages to latest-compatible; apply hold matrix; keep versions consistent across all csproj in the repo.
3. Verify: `dotnet build` 0 errors + **unit tests** (`--filter "Category!=Integration&Category!=LocalIntegration"` — CI runs bare `dotnet test`, local must exclude the local-stack categories). Neutralize the shared project-ref for one restore/build to prove the package path.
4. MR via `bpp-create-mr` (target `development`, reviewer `apittrich`). One commit per concern is nice-to-have; at minimum separate "mechanical bumps" from "bump requiring code change" (e.g. namespace fixes).
5. MR description MUST list: bumped table (package old→new), **held table (package, held-at, reason)**, any code changes a bump forced.

## Common mistakes

- Bumping `BppSharedVersion` as part of a generic package sweep — it's release-gated (shared must publish first), separate flow.
- Trusting a green local build that resolved shared via the project-ref condition — the NuGet path was never exercised.
- Treating `--outdated`'s "Latest" column as the target without TFM check (NU1202 in CI, not locally, if SDKs differ).
- Mechanically adopting FluentAssertions 8 / AutoMapper 16 — license flips, needs user sign-off.
- Bumping StackExchange.Redis to 3.x in one repo "because it's latest" — breaks fleet consistency; the pin is fleet-wide by decision.
