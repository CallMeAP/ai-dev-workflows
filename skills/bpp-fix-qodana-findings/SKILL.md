---
name: bpp-fix-qodana-findings
description: Use when fetching or fixing Qodana code-smell findings in BPP repos — phrases like "fix qodana findings", "qodana code smells", "fetch qodana results", "qodana cleanup MR", "refresh qodana report", "qodana probe MR", "stale qodana report". Fetches gl-code-quality-report.json from MR pipelines, classifies findings into fix/skip tiers (incl. the known false-positive classes from the unresolved bpp-shared NuGet), and produces per-repo fix MRs with an honest skipped-findings table.
---

# bpp-fix-qodana-findings

## Overview

Playbook for turning Qodana MR-pipeline findings into reviewable fix MRs across the BPP fleet — distilled from the 2026-07-12 12-repo fleet run (11 MRs, ~250 real fixes, ~600 confirmed false positives). The core lesson: **a large share of BPP Qodana findings are scan artifacts, not code debt.** Classify first, fix second, and always ship the skipped-findings table so reviewers see what was deliberately left.

## Fetching results

Latest MR pipeline's qodana report per repo (no artifact-zip download needed — direct file endpoint):

```bash
pid="brokernet%2F<repo>"
pl=$(glab api "projects/$pid/pipelines?source=merge_request_event&per_page=1" | jq -r '.[0].id')
jid=$(glab api "projects/$pid/pipelines/$pl/jobs?per_page=50" | jq -r '[.[] | select(.name|test("qodana";"i"))][0].id')
glab api "projects/$pid/jobs/$jid/artifacts/.qodana/results/gl-code-quality-report.json" > qodana_<repo>.json
# entries: {description, check_name, severity, location:{path, lines:{begin}}}
jq -r 'group_by(.check_name)|map({c:.[0].check_name,n:length})|sort_by(-.n)[]|"\(.n)x \(.c)"' qodana_<repo>.json
```

Prerequisites per repo: qodana component include in `.gitlab-ci.yml` (mirror push/vera: `component: …/ci-components/qodana@~latest`, inputs `stage: "tests"`, `qodana_image: "jetbrains/qodana-dotnet:2025.3"`) **and a project-level `QODANA_TOKEN` CI variable** — without it the job dies with "License request: failed to get proper response from Qodana Cloud" (per-project tokens; do NOT reuse another repo's token, results would land in the wrong Qodana Cloud project).

## The stale-report trap — never fix from a fetched report directly

Qodana runs **only on `merge_request_event` pipelines**. Development branches have **no qodana job**, so a fetched report reflects the state of *that MR branch*, not development. Once fix MRs merge, their reports go **stale** and keep re-listing findings you already fixed (2026-07-16 run: three repos' entire "safe tier" was already fixed on dev).

**Rule: a fetched report is never "recent enough" — it is pinned to its MR branch. Re-verify EVERY candidate against `origin/development` by file+content (not line number) before touching it, for every repo regardless of size.** A finding that no longer matches dev content is counted "already-fixed", never re-fixed. No exception for "the report looks recent", "small repo", or "obviously still applies".

### Fresh-report probe MR

To force a qodana run against current development, per repo:

1. Branch `chore/qodana-refresh-<date>` off development **via the GitLab API** (create-branch endpoint) — never switch a shared local checkout's branch, and never rely on a local-checkout branch to trigger the scan.
2. Append ONE trivial line to `README.md`/`PROJECT.md`: `<!-- qodana refresh probe <date> -->`. The qodana ci-component has **no `rules:changes` gating** (verified 2026-07-16), so a docs-only touch triggers the scan in every repo.
3. Open a **Draft** MR targeting development; set the reviewer with a separate `glab mr update <iid> --reviewer apittrich` (creation-time `reviewer_ids` are silently dropped).
4. Poll the pipeline with a **bounded bash sleep-loop inside a single Bash call** — never "wait" across turns (waiting agents go idle instead of polling).
5. The probe MR **becomes the fix MR**: push the classified fixes onto the same branch, **remove the probe marker line first** (README/PROJECT.md must end byte-identical to development), then un-draft it — or **close** it if the fresh report is clean.

No-report repos (probe is pointless — record + skip): `bpp-shared-template` (no `QODANA_TOKEN`), `bpp-agent` (scaffold, no MR pipelines).

## THE dominant false-positive class: unresolved bpp-shared

The qodana CI component analyzes **without restoring the private BPP.Shared.NET NuGet** (no GitLab-registry auth in the scan context — the job log shows `SEVERE - NuGetCredentialProvider`, the credential provider failing to auth to the registry). Every finding whose symbol lives in bpp-shared mis-resolves. Confirmed contaminated classes (verified independently in auth, cheggnet, file, vera):

| Check | Symptom | Danger if "fixed" |
|---|---|---|
| `CSharpWarnings__CS1574/1584/1581/1580` | cref → shared type "unresolvable" (even fully-qualified — that's the tell) | Degrading valid `<see cref>` links to `<c>` |
| `InvalidXmlDocComment` | mostly the same crefs; occasionally a REAL orphaned doc comment | Check the **description**, not the check name: "Cannot resolve symbol '<shared type>'" = artifact; anything else = inspect |
| `RedundantNameQualifier` | qualifier "redundant" only because shared ns invisible | Removal can **break compilation** (qualifier disambiguates same-named local vs shared enums — cheggnet had 11 such) |
| `NUnit1003` (blocker!) | `[TestCase]` args containing shared **enum members** → analyzer miscounts arity ("got 0") | "Fixing" breaks passing tests (vera had 265, file 30 — ALL false) |
| `InheritdocInvalidUsage` | inheritdoc → shared interface | Pointless rewrites |
| `RedundantCast` (subset) | numeric casts on shared DTO properties flagged "redundant" (e.g. `(float)` on `double?`/`decimal?` sources) because the property type was unresolved | Removal **breaks compile** — backend had 177 such; verify the source type locally before removing any cast involving shared types |
| nullability-contract checks (`ConditionalAccessQualifier…`, `NullCoalescing…AccordingToAPIContract`) | contracts of shared APIs unknown to scanner | Behavioral edits on wrong premises |

**Verification rule before touching ANY of these:** confirm the referenced symbol genuinely fails (typo/renamed/moved) — if it's a correct reference to a bpp-shared/cross-assembly type, skip as "scan artifact" and count it. For NUnit1003: actual-arg-count vs method-param-count; matching arity + shared-typed args = artifact.

**Root fix (preferred over per-repo skips):** teach the ci-components qodana template a restore bootstrap (`dotnet restore` with `CI_JOB_TOKEN` against the GitLab NuGet registry) — then re-scan; the artifact classes disappear honestly. Remember: ci-components changes only propagate via **release tags** (`@~latest` = latest tag, NOT development HEAD). **Until that bootstrap lands, this whole resolver-driven family (CS1574, NUnit1003, `…AccordingToAPIContract`, `RedundantNameQualifier`) is skip-by-default** — treat the `NuGetCredentialProvider` job-log line as proof the class is a scan artifact, not code debt.

## Never fix

- `RedundantUsingDirective` — hard-skip class. Still **NOT fixed in Qodana 2025.3** (build QDNET-253.31810, image `jetbrains/qodana-dotnet:2025.3`); [QD-13872](https://youtrack.jetbrains.com/issue/QD-13872) was closed **"Incomplete"** with no fix version. Every sampled flagged `using` was actually required (extension methods / attributes / shared namespaces). User directive: never touch using directives based on Qodana.
- `UnusedAutoPropertyAccessor.Global` / `Unused*` on DTOs/entities — consumed by other repos, JSON/EF serialization, reflection. In bpp-shared these are false positives BY DESIGN (consumers live in other repos). Suppress via qodana.yaml instead.
- `EntityFramework.ModelValidation.UnlimitedStringLength` — real, but = MaxLength decisions + DB migrations → separate ticket, never a smell-sweep edit.
- Generated code (`*.g.cs`, EF `Migrations/*.Designer.cs`, model snapshots) — exclude via config, never edit.
- Intent-preserving "redundancies": documented no-op `default:` switch sections, explicit switch arms that document a mapping table. Includes `PatternIsRedundant` on `X or Y or _ =>` mapper arms — the explicit enum values ARE the documented mapping table; never "simplify" a production mapper (vera ×5).

## Safe-mechanical tier (fix these)

`RedundantDefaultMemberInitializer`, `RedundantCast` (verify overload/numeric semantics per site), `RedundantExtendsListEntry`, `RedundantAnonymousTypePropertyName`, `RedundantArgumentDefaultValue` (skip when the explicit arg IS the test subject — e.g. an explicit `claimStatus`/`role` param the test exists to exercise), `RedundantAssignment`, `RedundantExplicitArrayCreation`, `NUnit1033` (`TestContext.WriteLine` → `TestContext.Out.WriteLine`), `UsingStatementResourceInitialization` (split prop-init out of `using var`), genuinely-broken XML docs (orphaned `<param>`, `typeparam "T?"`, doc comment orphaned by mis-nested `#region`), `RedundantNameQualifier` ONLY for BCL/local namespaces after verifying: matching `using` exists AND bare name is unambiguous repo-wide.

`NonReadonlyMemberInGetHashCode` in test-data records — fix by making the props **init-only** (and refactoring any post-construction mutations onto the constructor/initializer), NOT by suppressing the inspection.

Compile-required `RedundantCast` / `RedundantExtendsListEntry` sites — these are NOT redundant, skip them:
- Vendored MockQueryable `TestAsyncQueryProvider` boilerplate — both the `RedundantExtendsListEntry` and the `(TResult)Invoke()` `RedundantCast` are required to compile.
- `(Guid?)null` (and sibling nullable-value) ternary branches — the cast sets the branch type; removing it breaks the ternary.

Caveat on `RedundantSuppressNullableWarningExpression`: `!` is compile-time-only and the fleet has no TreatWarningsAsErrors — but **verify EVERY instance and expect most to be false positives**; removing the `!` reintroduces a REAL CS8602 wherever ReSharper sees a narrowing Roslyn does not. Two proven trap shapes: (a) FluentAssertions runtime narrowing — `.NotBeNull()` / `.BeOfType()` (stella ×7, ALL false); (b) control-flow narrowing — else-branch / `isNewEntity`-style guards (backend `CustomerLegalSettingsService`). Only remove where an adjacent unsuppressed usage proves the value is non-null at that site.

`PartialTypeWithSinglePart`: drop `partial` only after repo-wide grep **including generated code** confirms no second part.

## Config hygiene (qodana.yaml)

- `exclude:` with `name: All` + `paths:` — **paths are prefix-based (NOT `**` globs) and relative to the PROJECT ROOT (repo root), NOT the solution dir (SRCROOT).** A path rooted at SRCROOT silently matches nothing — doci's migrations exclude leaked 762 generated CS8669 for months because of exactly this. `**/DbMigratorLegacy/**` also matches nothing; use `BPP.Shared.NET.DbMigratorLegacy` style repo-root-relative prefixes. **Verify an exclude actually works by confirming the class disappears from the NEXT report** — never assume a path took effect.
- Wire the file via the CI component input `qodana_options: "--config=qodana.yaml"` (mirror bpp-shared/bpp-doci MRs).
- Legit exclusions: legacy migrator trees, EF migration designer files, generated clients. Suppressing an inspection (e.g. UnusedAutoPropertyAccessor in shared) is legit when the false-positive cause is documented in the MR.

## Process rules

- Temp worktree per repo (`git worktree add … -b chore/qodana-fixes origin/development`); never switch main checkouts. When using the probe flow, add the worktree on the already-pushed remote `chore/qodana-refresh-<date>` branch instead — the fixes land there and un-draft that MR (do not open a second branch).
- If AutoMapper-removal/other big refactor MRs are open in the repo: **stack** the fix MR on that chain (backend: base+target the top branch, note auto-retarget) or defer (stella) — findings were scanned on development, so locate by file+content, not line numbers, and count "drift-skipped".
- One commit per check-type. MR reviewer `apittrich`, target `development`.
- Java repos, wrong analyzer trap: a Java repo whose CI passes `qodana_image: jetbrains/qodana-dotnet:*` reports **0 findings = fake-clean** (nothing analyzed). Use `jetbrains/qodana-jvm:*`. Verify the image matches the language before trusting a clean report.
- Java toolchain trap on this box: `/usr/lib/jvm/java-21-openjdk-amd64` is JRE-ONLY (`mvn -version` claims 21, compile fails "release version 21 not supported") — use a full Temurin JDK 21 (scratchpad tarball).
- Java image builds: ci-components `build-java-image` default Dockerfile hardcodes JDK 17 (no input until the jdk_version input ships + a release tag is cut).
- Java repos (bpp-mail, bpp-js-report): `VulnerableLibrariesLocal` → prefer ONE Spring Boot parent patch-bump (BOM covers most CVEs) + explicit overrides for stragglers; `JvmTaintAnalysis` on PDF/attachment endpoints = usually false positive (attachment disposition ≠ HTML render) — assess per endpoint in the MR description, don't rewrite code.
- Verification mode is the user's call: local build+unit tests OR pipeline-only ("don't build locally") — in pipeline-only mode be MORE conservative (that's when the blind-mass-edit ban matters most; a 400-edit Redundant* bulk pass belongs to a cleanupcode+build task, not a no-build sweep).
- Local-restore-blocked repos (e.g. doci — no local project-ref override + NuGet 401 on restore): ship **config-only** changes and **defer code batches explicitly as build-blocked**; never push code edits you could not build/verify locally.
- glab traps: `glab mr create`/`view` broken → `glab api POST /projects/brokernet%2F<repo>/merge_requests`; reviewer via `glab mr update <iid> --reviewer apittrich -R brokernet/<repo>`; MR description from a /tmp file fails (sandbox + HTTP 415) → inline `-f description="$(cat file)"`.

## Deliverable shape (per MR description)

1. Fixed table: check_name → count (one commit each).
2. Skipped table: check_name → count → reason (QD-13872 / scan artifact "Cannot resolve symbol" / serialization false positive / judgment tier / drift).
3. Config changes with per-exclusion finding counts + justification.
4. Follow-up list (EF MaxLength ticket, bulk Redundant* cleanupcode pass, ci-components restore fix).
