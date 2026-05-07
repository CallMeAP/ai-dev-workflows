# Project Index (personal, gitignored)

Quick path lookup for all BPP and legacy Brokernet projects on this machine.
**How to use:** `grep -i <keyword> PROJECT_INDEX.md` — find the project, jump to the path.

Roots:
- BPP: `/home/alex/Entwicklung/bpp/`
- Brokernet (legacy): `/home/alex/Entwicklung/brokernet/`

---

## BPP / .NET

| Project | Path | Purpose |
|---|---|---|
| bpp-auth | `bpp/bpp-auth/BPP.Auth.NET` | Central auth microservice — validates JWTs from Brokernet & Firebase |
| bpp-backend | `bpp/bpp-backend/BPP.Backend.NET` | Main backend for the cockpit-ui (this repo) |
| bpp-chat | `bpp/bpp-chat/BPP.Chat.NET` | Chat microservice |
| bpp-document-analysis | `bpp/bpp-document-analysis/BPP.Document.Analysis.NET` | Sovereign document intelligence (OCR, semantic search, LLM extraction for AT insurance docs) |
| bpp-file | `bpp/bpp-file/BPP.File.NET` | Central file-handling microservice |
| bpp-push | `bpp/bpp-push/BPP.Push.NET` | Real-time push notifications (SignalR + FCM) |
| bpp-shared | `bpp/bpp-shared/BPP.Shared.NET` | Shared library — EF Core entities, enums, repos, services, middleware (PostgreSQL Code-First) |
| bpp-shared-template | `bpp/bpp-shared-template/BPP.Shared.Template.NET` | Project scaffolding template |
| bpp-stella | `bpp/bpp-stella/BPP.Stella.NET` | Backend for the Stella customer portal |
| bpp-vera-connector | `bpp/bpp-vera-connector/BPP.VeraConnector.NET` | VERA insurance system connector / sync |

## BPP / Java (Spring Boot)

| Project | Path | Purpose |
|---|---|---|
| bpp-js-report-connector | `bpp/bpp-js-report-connector` | JsReport (PDF generation) connector |
| bpp-mail | `bpp/bpp-mail` | Templated email service (Thymeleaf) — Beratungsprotokolle, notifications, broker/customer mails |

## BPP / Infrastructure

| Project | Path | Purpose |
|---|---|---|
| infra | `bpp/infra` | Shared infra config (deployment, k8s, docker, etc.) |

---

## Brokernet (legacy) / brokernet-backend submodules

Root: `brokernet/brokernet-backend/` — Java multi-module Maven (Spring Boot). Swagger: `localhost:8080/swagger-ui/index.html`.

| Module | Path | Purpose |
|---|---|---|
| backend-app | `brokernet/brokernet-backend/backend-app` | Main application entry / orchestration |
| backend-auth | `brokernet/brokernet-backend/backend-auth` | Authentication & JWT issuance |
| backend-backoffice | `brokernet/brokernet-backend/backend-backoffice` | Backoffice features |
| backend-callidus | `brokernet/brokernet-backend/backend-callidus` | Callidus (insurance pricing/comparison) integration |
| backend-chat | `brokernet/brokernet-backend/backend-chat` | Chat module |
| backend-claim | `brokernet/brokernet-backend/backend-claim` | Schadensmeldungen (claims management) |
| backend-customer | `brokernet/brokernet-backend/backend-customer` | Customer (Kunden) management |
| backend-db | `brokernet/brokernet-backend/backend-db` | Database migrations / persistence layer |
| backend-document | `brokernet/brokernet-backend/backend-document` | Document handling |
| backend-export | `brokernet/brokernet-backend/backend-export` | Data export |
| backend-firebase | `brokernet/brokernet-backend/backend-firebase` | Firebase integration |
| backend-go | `brokernet/brokernet-backend/backend-go` | Go-User module |
| backend-hva | `brokernet/brokernet-backend/backend-hva` | HVA (Hauptverband) integration |
| backend-jahresgespraech | `brokernet/brokernet-backend/backend-jahresgespraech` | Jahresgespräch (annual review) features |
| backend-jsreport | `brokernet/brokernet-backend/backend-jsreport` | JsReport (PDF) connector |
| backend-mail | `brokernet/brokernet-backend/backend-mail` | Email sending |
| backend-maintenance | `brokernet/brokernet-backend/backend-maintenance` | Maintenance / housekeeping jobs |
| backend-minio | `brokernet/brokernet-backend/backend-minio` | MinIO object storage integration |
| backend-news | `brokernet/brokernet-backend/backend-news` | News / announcements |
| backend-onboarding | `brokernet/brokernet-backend/backend-onboarding` | Onboarding flows |
| backend-polizzierung | `brokernet/brokernet-backend/backend-polizzierung` | Polizzierung (policy issuance) |
| backend-push | `brokernet/brokernet-backend/backend-push` | Push notifications |
| backend-redis | `brokernet/brokernet-backend/backend-redis` | Redis cache integration |
| backend-servo | `brokernet/brokernet-backend/backend-servo` | Servo product line |
| backend-shared | `brokernet/brokernet-backend/backend-shared` | Shared utilities / common code |
| backend-sign | `brokernet/brokernet-backend/backend-sign` | Digital signatures (VariasSign etc.) |
| backend-stella | `brokernet/brokernet-backend/backend-stella` | Stella customer portal (legacy backend) |
| backend-sva | `brokernet/brokernet-backend/backend-sva` | SVA integration |
| backend-testing | `brokernet/brokernet-backend/backend-testing` | Test utilities / fixtures |
| backend-tracking | `brokernet/brokernet-backend/backend-tracking` | Analytics / event tracking |
| backend-user | `brokernet/brokernet-backend/backend-user` | User management |
| backend-websocket | `brokernet/brokernet-backend/backend-websocket` | WebSocket support |

## Brokernet (legacy) / Connectors

| Project | Path | Purpose |
|---|---|---|
| brokernet-vera-connector | `brokernet/brokernet-vera-connector` | Legacy VERA connector (Java/Spring Boot). Swagger: `localhost:9000/swagger-ui/index.html` |
