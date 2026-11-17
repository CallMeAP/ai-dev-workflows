# Demo stack setup and switching (bpp-agent-llm-selftest)

Follow bpp-agent `docs/local-demo-stack.md` (read it with `git -C /home/alex/Entwicklung/bpp/bpp-agent show origin/development:docs/local-demo-stack.md`)
and the stack's own scripts in `$DEMO_HOME`:

- Start order after a reboot: `rabbit-start.sh` (private RabbitMQ, AMQP 7272, mgmt 7273, own vhost, dummy login), then
  `start.sh` (auth file backend push connector agent; `start.sh agent` for one). `stop.sh [service]` stops by process group.
  `build.sh` rebuilds against the bpp-shared worktree (project reference via the `.targets` file), then restart.
- Demo DB missing: `pg_dump -Fc` of local `bpp` (read-only), `createdb <demo>`, `pg_restore --no-owner`, DbMigrator from the
  bpp-shared worktree with `ASPNETCORE_ENVIRONMENT` unset, then the copy's safety steps: `is_claim_auto_synced_to_vera=false`,
  `go_user_external_services_links.is_claim_auto_synced_to_cca=false`, bpp-shared `scripts/ki-assistent-backfill.sql`. Never write local `bpp`.
- Mail loop: connector with `ExternalMailSync__Enabled=false ExternalMailSyntheticMail__Enabled=true BppAgentConnector__BaseUrl=<agent>`;
  agent with `Mail__Enabled=true Mail__ProcessingEnabled=true Mail__DevSubjectPrefix=mp- Mail__EnabledOwnerGoUserIds__0=<owner>` and the
  RabbitMQ port/vhost; the owner's link row needs `is_external_mail_sync_enabled=true` so the synthetic form accepts mails
  (form check: `GET $CONNECTOR_URL/api/external-mail-dashboard-synthetic-mail/context` -> `canCreate`).
- Switching the agent to another build: check out the ref in the agent worktree (detached), `build.sh`, `stop.sh agent`,
  `start.sh agent`, re-run pre-flight (SHA, catalog, migrations).
- **13 h timers:** while `systemctl --user list-timers 'selftest-latency-*'` lists units, do not stop or switch the agent and do
  not drop the DB; the resumes need the same sessions.
