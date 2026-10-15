export const meta = {
  name: 'vera-keyword-audit',
  description: 'Analyze prod VERA catalogs + inventories of all tenants against the VERA mappers, implement into the target worktrees (TDD), adversarial review',
  phases: [
    { title: 'Analyze', detail: 'one agent per mapper area, executes the real mapper code over all tenant data' },
    { title: 'Verify', detail: 'adversarial check of each proposal set' },
    { title: 'Implement', detail: 'keyword worktree and catalog worktree (TDD)' },
    { title: 'Review', detail: 'two lenses per worktree, then fix' },
  ],
}
// args (object, or its JSON string):
//   manifest   REQUIRED  out/manifest.json written by `vera-audit.sh manifest`
//   w153       REQUIRED  worktree that holds the keyword mappers ("keyword MR")
//   branch153  REQUIRED  its branch
//   w154       optional  worktree that holds the catalog lookup ("catalog MR", may be stacked on w153); default = w153
//   branch154  optional  its branch; default = branch153
//   out        REQUIRED  directory for the analysis reports (outside every repo)
//   handover   optional  handover dir of the track; its RESUME.md holds earlier business decisions
//   ticket     optional  Jira key for commit messages, e.g. BRO-1234
const A = typeof args === 'string' ? JSON.parse(args) : (args || {})
for (const k of ['manifest', 'w153', 'branch153', 'out']) if (!A[k]) throw new Error(`missing arg: ${k}`)
const MAN = A.manifest, OUT = A.out
const W153 = A.w153, B153 = A.branch153
const W154 = A.w154 || W153, B154 = A.branch154 || B153
const SAME = W154 === W153
const TICKET = A.ticket ? ` (${A.ticket})` : ''
const DECISIONS = A.handover
  ? `Earlier business decisions of this track: ${A.handover}/RESUME.md (read the UPDATE blocks at its top) and ${A.handover}/reports/*.md if present. They take precedence over your own judgement.`
  : 'No handover given: earlier business decisions are only what the code and its tests already encode.'
const range = b => `origin/${b}..HEAD if origin/${b} exists, else origin/development..HEAD`

const RULES = `
CONTEXT: bpp-vera-connector VERA keyword/mapper audit. Prod VERA data for every BPP tenant with VERA access was collected read-only. Manifest: ${MAN} (JSON list, one entry per tenant: tenant_idx, row, nodes, fingerprint, dir, same_catalog_as_tenant = earlier tenant with the identical catalog or null, contracts {total, returned, skipped, expected, short}). Count distinct catalogs from the fingerprints; do not double-count tenants with same_catalog_as_tenant set. Each dir has catalog.json (all catalog nodes: productId, parentProductId, productName, productNo, productSectionId, productType section|division|bundle|product, isActive), contracts_compact.json (up to 2000 sampled contracts: policyDivisionId -> catalog productId, policyProductId, insuranceInstituteNumber, insuranceInstitute, contractState, policyDivision, productName), doctypes.json (VERA document type names), enum_values.json (value counts of gender, legalForm, maritalStatus, customerType, title, country, vehicleType ...). Entries with contracts.short=true have an incomplete sample: say so wherever it matters.
${DECISIONS}
Code: keyword worktree ${W153} (branch ${B153}) holds the keyword mappers (BPP.VeraConnector.NET/BPP.VeraConnector.NET.Vera/Services/Mappers/Utilities/*: ContractDivisionMapper, InsuranceNameMapper, VeraGenderMapper; document type mapping and other enum maps live elsewhere in BPP.VeraConnector.NET.Vera - find them). Catalog worktree ${W154} (branch ${B154}) holds the catalog lookup: Consts/VeraContractProductTypeConsts.cs (SectionCodeToProductType, SachDivisionCodeToProductType, KnownSachversicherungDivisionCodes) and Services/VeraContractProductTypeService.cs. If a named class does not exist (renamed, moved, not yet merged), find its successor by behaviour and say so; never invent it.
HARD RULES:
- No network calls to VERA, no prod DB, no GitLab/Jira posts, no push. Never touch the main checkout /home/alex/Entwicklung/bpp/bpp-vera-connector.
- No customer data anywhere (code, tests, resources, reports, commit messages): only catalog codes/names, insurer numbers/names, document type names, enum values, counts. No BPP tenant names - refer to tenants as "T<tenant_idx>" in reports and not at all in code (code comments may say e.g. "in 7 von 20 Prod-Katalogen").
- Interactive questions mode is OFF: never ask; pick the recommended option and record it in a "decisions" list (decision, options, choice, why). Business-meaning calls (which ContractProductType a product line belongs to) follow existing conventions in the code and the earlier decisions above; genuinely ambiguous ones get the recommended choice AND are flagged "needs business sign-off".
- Code comments/XML docs/commit messages German (ASCII umlaut style of surrounding code), commit style "fix(contract): ...${TICKET}" with trailer "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>". New commits only, never amend/reset/force; git commit -- <paths>.
- Test only the project: dotnet test BPP.VeraConnector.NET/BPP.VeraConnector.NET.Vera.Tests. Never Integration.Tests. Never skip tests.`

const PROPOSALS = { type: 'object', properties: {
  verdict: { type: 'string' },
  coverage: { type: 'string', description: 'what data was evaluated, counts' },
  changes: { type: 'array', items: { type: 'object', properties: {
    target: { type: 'string', enum: ['keyword', 'catalog', 'none'] }, file: { type: 'string' }, change: { type: 'string' },
    evidence: { type: 'string', description: 'values, counts, tenants (T<idx>)' }, impact_contracts: { type: 'number' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] }, needs_business_signoff: { type: 'boolean' } },
    required: ['target', 'file', 'change', 'evidence', 'confidence', 'needs_business_signoff'] } },
  decisions: { type: 'array', items: { type: 'string' } },
  findings_no_code: { type: 'array', items: { type: 'string' } },
}, required: ['verdict', 'coverage', 'changes', 'decisions', 'findings_no_code'] }

const MAPPERS = [
  { key: 'division-keyword', target: 'keyword', task: `ContractDivisionMapper (keyword fallback). For EVERY catalog node name across all catalogs and for every sampled contract (resolve policyDivisionId to its catalog node name, weight by contract count), EXECUTE the real ContractDivisionMapper.Map (throwaway console/test harness in a scratch dir or a temporary uncommitted test in ${W153}, removed afterwards) and compare with the expected type = what the catalog lookup in ${W154} would give (section code via SectionCodeToProductType, refined under SACH by SachDivisionCodeToProductType, products walk up to their division; read that code to mirror its semantics exactly). Propose keyword additions/reorderings for mismatches, prioritised by affected contracts. Keep existing passing behaviour; check every proposed keyword for false positives against ALL node names.` },
  { key: 'sach-codes', target: 'catalog', task: `Catalog tables in ${W154}. Across all catalogs list: section codes not in SectionCodeToProductType (with node counts and contract counts), SACH division/bundle codes in neither SachDivisionCodeToProductType nor KnownSachversicherungDivisionCodes (with names, tenants, contract counts) - classify each as a refinement (-> other ContractProductType) or known-Sach; codes whose meaning collides across tenants (same code, different line of business) must be flagged; nested divisions. Also evaluate end-to-end: run the real catalog resolution logic (VeraContractProductTypeCatalogUtil / service, via a temporary harness) over every sampled contract per tenant and report the distribution and the null (fallback-to-keyword) rate.` },
  { key: 'insurers', target: 'keyword', task: `InsuranceNameMapper. Collect every (insuranceInstituteNumber, insuranceInstitute) pair with contract counts across all tenants; EXECUTE InsuranceNameMapper.Map(number, name) on each; check against the InsuranceCompany enum (BPP.Shared.NET, find it in ~/.nuget/packages/bpp.shared.net/<version used by the csproj>). Report wrong mappings (number mapped to a different insurer than the VERA name says), keywords that catch a different insurer (substring false positives), Sonstige fallbacks although an enum member exists, and prod numbers that differ from the dictionary's numbers for the same insurer. Propose dictionary/keyword changes; number -> name must be consistent across tenants (check).` },
  { key: 'doctypes', target: 'keyword', task: `Document type mapping (inbound VERA name -> BPP type and outbound BPP type -> VERA candidate names, incl. VeraDocumentApiService.Resolve). Collect all distinct VERA document type names across all tenants (with how many tenants use each). For each, determine the current inbound mapping (execute the code) and whether an outbound candidate exists. Propose added inbound arms and outbound candidates for spellings that recur across tenants, and a guard test (each outbound candidate round-trips inbound) if none exists.` },
  { key: 'gender-enums', target: 'keyword', task: `VeraGenderMapper and the other string/enum maps used for customers/contracts (legalForm/Rechtsform incl. substring checks, maritalStatus, customerType, title, country codes, vehicle type). Use enum_values.json of all tenants (value -> count). Execute each mapper on each observed value; verify case sensitivity and trimming in the code before calling a casing difference a bug. Propose fixes and tests for every observed value that maps wrongly or silently falls back.` },
]

phase('Analyze')
const analyses = await pipeline(MAPPERS,
  m => agent(`${RULES}\nMAPPER AREA: ${m.key} (default target: ${m.target} worktree)\nTASK: ${m.task}\nWrite your full report (tables, no customer data) to ${OUT}/${m.key}.md (mkdir -p). Return the structured proposals.`, { label: `analyze:${m.key}`, phase: 'Analyze', schema: PROPOSALS }),
  (prop, m) => agent(`${RULES}\nAdversarially verify these proposals for ${m.key} (report: ${OUT}/${m.key}.md). For each change: re-run the evidence yourself on the data (execute the mapper where possible), try to find a false positive or regression it would cause across ALL catalogs/inventories in the manifest, and check it does not contradict an earlier business decision (see CONTEXT). Drop or correct changes that fail; keep the rest. Return the corrected proposal set in the same schema (add to decisions what you changed and why).\nPROPOSALS:\n${JSON.stringify(prop)}`, { label: `verify:${m.key}`, phase: 'Verify', schema: PROPOSALS }),
)
// keep the area next to each result before dropping failed ones (indexes shift after filter)
const ok = analyses.map((a, i) => a && { ...a, area: MAPPERS[i].key }).filter(Boolean)
const all = ok.flatMap(a => a.changes.map(c => ({ ...c, area: a.area })))
const forKeyword = all.filter(c => c.target === 'keyword' || (SAME && c.target === 'catalog'))
const forCatalog = SAME ? [] : all.filter(c => c.target === 'catalog')
log(`changes: keyword=${forKeyword.length} catalog=${forCatalog.length}${SAME ? ' (single worktree)' : ''}`)

phase('Implement')
const implPrompt = (name, wt, changes) => `${RULES}\nImplement these verified changes in worktree ${wt} (${name}) with TDD: first add/extend unit tests that fail for the right reason, then change the code. Group into a few coherent commits per mapper area. Do not push. Then run the Vera.Tests project and report exact counts. Reports with evidence are in ${OUT}/*.md.\nCHANGES:\n${JSON.stringify(changes, null, 1)}\nReturn: commits (sha + message), diff stat, test counts, changes not implemented and why.`
const impls = await parallel([
  () => forKeyword.length ? agent(implPrompt('keyword', W153, forKeyword), { label: 'implement:keyword', phase: 'Implement' }) : Promise.resolve('no changes'),
  () => forCatalog.length ? agent(implPrompt('catalog', W154, forCatalog), { label: 'implement:catalog', phase: 'Implement' }) : Promise.resolve('no changes'),
])

phase('Review')
const FIND = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] }, file: { type: 'string' }, summary: { type: 'string' }, evidence: { type: 'string' }, fix: { type: 'string' } },
  required: ['severity', 'file', 'summary', 'evidence', 'fix'] } } }, required: ['findings'] }
const reviewOne = async (name, wt, branch, impl) => {
  if (impl === 'no changes' || !impl) return { name, fix: 'nothing to review' }
  const lenses = [
    'correctness + regressions: re-execute changed mappers over ALL tenant data in the manifest and compare before/after distributions; any value that got worse is a finding',
    'tests, data hygiene and scope: tests assert mechanism, no customer data or tenant names in code/tests/commits, German comments, commit style, only intended files, no TODOs',
  ]
  const rs = await parallel(lenses.map(l => () => agent(`${RULES}\nReview the unpushed commits in ${wt} (git log ${range(branch)}). Implementer report:\n${impl}\nLens: ${l}\nVerified findings only, with evidence. Do not edit files (another reviewer runs concurrently).`, { label: `review:${name}`, phase: 'Review', schema: FIND })))
  const f = rs.filter(Boolean).flatMap(r => r.findings).filter(x => x.severity !== 'nit')
  if (!f.length) return { name, findings: [], fix: 'no fixes needed' }
  const fix = await agent(`${RULES}\nIn ${wt}, verify and fix these review findings with NEW commits (reject false ones with reason); rerun Vera.Tests; report counts and git log --oneline (${range(branch)}).\n${JSON.stringify(f, null, 1)}`, { label: `fix:${name}`, phase: 'Review' })
  return { name, findings: f, fix }
}
const reviews = await parallel([
  () => reviewOne('keyword', W153, B153, impls[0]),
  () => reviewOne('catalog', W154, B154, impls[1]),
])
return {
  verdicts: ok.map(a => ({ area: a.area, verdict: a.verdict, coverage: a.coverage, decisions: a.decisions, findings_no_code: a.findings_no_code, signoff: a.changes.filter(c => c.needs_business_signoff).map(c => c.change) })),
  impls, reviews,
}
