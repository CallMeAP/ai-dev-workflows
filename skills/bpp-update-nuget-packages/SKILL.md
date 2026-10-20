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
dotnet list <Solution>.sln package --outdated --source https://api.nuget.org/v3/index.json   # without --source it also queries the GitLab feed and 401s
dotnet list <Solution>.sln package --include-transitive    # for diagnosing NU1107 caps
```

- `--outdated` shows the absolute latest, NOT the latest compatible with your TFM — adopting it can fail restore with **NU1202** (package targets a newer TFM). Check the package's supported frameworks before treating "latest" as the target.
- Bump by editing version attributes, not `dotnet add package` loops (which re-resolves and can reorder ItemGroups).

## Version sources of truth (BPP-specific)

- **BPP.Shared.NET**: version lives ONLY in `BPP.*/Directory.Build.props` → `<BppSharedVersion>`. NEVER edit the per-csproj `PackageReference` — it reads the property. Bumping shared = separate flow (`bpp-bump-shared-version` skill).
- **Local project-ref trap**: `Directory.Build.props` injects a local `bpp-shared` `<ProjectReference>` via an `Exists(...)` condition per developer. When verifying a bump against the real NuGet package, **temporarily neutralize your project-ref condition** — otherwise you build against your local shared checkout and the package path is untested (this hid a real restore failure during the fleet run).
- Everything else: per-csproj `PackageReference` version attributes; grep all `*.csproj` — some repos repeat the same package across projects; keep versions identical repo-wide.

## Hold matrix — do NOT blind-bump these

| Package | Hold at | Why |
|---|---|---|
| Microsoft.AspNetCore.OpenApi + Swashbuckle | OpenApi latest 9.x + Swashbuckle 9.0.6 | Microsoft.OpenApi 2.x **removes `Microsoft.OpenApi.Models`** → breaks SwaggerGen filters (shared's TranslocoEnumSchemaFilter, ConfigureServerUrl) |
| StackExchange.Redis | **2.13.17** (fleet pin) | 3.x breaks `StringSetAsync` (`When` → `Expiration` overload). 2.13.x already adds the Expiration overload — only code compiling `RedisService` (bpp-shared) hits the ambiguity; fix there is a 1-line `When.Always` |
| FluentAssertions | last adopted **pre-8** line (6.12.2 fleet baseline) | **8.x = Xceed commercial license.** Per-repo/user decision, never a mechanical bump (alt: AwesomeAssertions fork). Some repos already ship 8.x — don't downgrade those either |
| MassTransit (+ .RabbitMQ, .EntityFrameworkCore, .TestFramework) | latest **8.x** (8.5.11 on 2026-10-16) | **≥9 commercial** (Massient license, massient.com/license); 8.x is Apache-2.0. Keep all MassTransit packages on the same 8.x version across bpp-shared, bpp-doci and bpp-agent |
| AutoMapper | **do not re-add**; if unavoidable, 14.0.0 (last MIT) | **≥15.0.0 is commercial** (RPL-1.5 or Lucky Penny license; free Community License only below US$5M gross revenue incl. parent group and ≤US$10M outside capital). Removed from backend/doci/shared in 2026 — verified absent on dev/staging/main 2026-10-16 |
| JsonSchema.Net (+ JsonPointer.Net, Json.More.Net) | **8.0.5** (last MIT) — bpp-agent tests are on 9.4.0 (user decision pending) | **≥9.0.0 ships OSMFEULA.txt**: monthly maintenance fee (GitHub Sponsors) for orgs using the NuGet binary in revenue-generating activity; 9.4.x states a US$10,000 annual-revenue threshold. Never bump into it mechanically |
| Moq | 4.x | 4.20.0/4.20.1 had SponsorLink (removed in 4.20.2). The upcoming **v5** adds an Open Source Maintenance Fee EULA — hold on 4.x until reviewed |
| Kreuzberg | 4.x | **5.x (currently prereleases) is Elastic License 2.0**, no longer MIT — needs review before adopting |

License rule generalized: on any **major** bump, check the license didn't flip commercial (FluentAssertions 8, AutoMapper ≥15 [$5M revenue Community License], MassTransit 9 [$1M], JsonSchema.Net 9 [OSMF fee], Moq v5 [OSMF fee], Kreuzberg 5 [ELv2]). "Latest" with a paywall is not an update.

## bpp-shared bumps break bpp-doci and bpp-agent (NU1605)

bpp-doci (bpp-document-analysis) and bpp-agent are usually left out of sweeps, but they pin many of the same packages as
`BPP.Shared.NET` directly. Raising any of those in bpp-shared turns their restore red with **NU1605 (downgrade)** as soon
as the new shared package is bumped there (2026-10-16: dev pipelines + staging MR !332). **When the sweep raises a package
in bpp-shared, raise the overlapping refs in doci + agent in the same run** (only those refs if the repos are otherwise
excluded). A local `dotnet build` of their solutions shows the NU1605 — verify there, then via their pipelines.

## Always take

- **log4net ≥ 3.3.2** — CVE fix (GHSA-4f7c-pmjv-c25w).
- Test infra fleet standard: `Microsoft.NET.Test.Sdk` 18.x line / `NUnit3TestAdapter` 6.x / `coverlet.collector` 10.x — don't "align down" to 17.x based on stale examples in older repos (id-austria/cca lagged; fleet majority is the 18 line).
- Patch/minor bumps of everything not in the hold matrix.
- **MockQueryable.Moq 10.x** (hold lifted 2026-10-16): `BuildMock()`/`BuildMockDbSet()` are now extensions on `IEnumerable<T>`/`ICollection<T>` — drop the `.AsQueryable()` before them (`list.BuildMockDbSet()`). Mechanical, own commit.
- **NUnit 5.x** (fleet decision 2026-10-16): `Assert.ThrowsAsync` / `DoesNotThrowAsync` now return a `Task` (NUnit2059 / CS0029) — make the test `async Task` and `await` the assert. Mechanical, own commit; never hold NUnit back to dodge it.
- **Microsoft.Extensions.ApiDescription.Server**: take the latest (10.x). Build-time only, no package dependencies — it is NOT part of the OpenApi/Swashbuckle hold.

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
