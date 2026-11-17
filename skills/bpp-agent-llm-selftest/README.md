# bpp-agent-llm-selftest

Live LLM self-test of bpp-agent on a separately booted demo stack: pre-flight, suites (read, write, garbage, injection, latency,
model-switch, ui, mail-loop, dashboard, rules), hard checks, a blind judge, one report, a fix stage.

## Placeholders

- `/home/alex/Entwicklung/bpp` is the BPP root (`{{BPP_ROOT}}` in the shared mirror). Every other machine path is written with
  `$HOME` / `~` or comes from the env file.
- No user name, e-mail address or secret is in the skill. The developer login (`SELFTEST_LOGIN_EMAIL`), the owner GoUser id and the
  puppeteer-core path go into each developer's own `selftest.env`, outside every repo.

## Prerequisites

- A running bpp-agent demo stack per bpp-agent `docs/local-demo-stack.md`: services on 62xx, own demo DB (`bpp_agent_demo*`,
  a `pg_dump` copy of local `bpp`), private RabbitMQ (7272/7273), connector with the synthetic test-mail form, Cockpit on its own port.
  `$DEMO_HOME` holds `start.sh`, `stop.sh`, `rabbit-start.sh`, `pg-password.local` (mode 600).
- Codex (ChatGPT) linked on the demo agent for the developer GoUser; the Codex CLI logged in on the same account (quota snapshot).
- Tools: bash 4+, `curl`, `jq`, `psql`, `ss`, `python3`, `node` 18+, user `systemd` (latency), Chromium + a `puppeteer-core` install
  (ui), the Cockpit worktree's `node_modules` (`ws`, `openapi-generator-cli` for the client regen).
- Linux only (uses `ss`, `/proc`, `systemd-run --user`, `setsid` in the stack scripts).

## Layout

- `SKILL.md`: the procedure. `stack-setup.md`: demo stack boot, DB copy, mail loop, build switch. `selftest.env.example`: the env file template.
- `scripts/`: `lib.sh` (env, refusals, psql, quota guard, login), `preflight.sh`, `codex-usage.sh`, `run-round.sh`, `chat-case.mjs`,
  `mail-case.sh`, `score.py`, `report.py`, `latency-run.sh`, `latency-resume.sh`, `latency.mjs`, `latency-analyze.py`,
  `model-switch.sh`, `injection-note.sh`, `dashboard-truth.sh`, `custscope-truth.sh`, `as-backoffice.sh`, `quota-guard.sh`,
  `ui/lib.cjs`, `ui/live.cjs`.
- `seeds/`: demo-DB fixtures for the repo fixture sets (`custscope-gen.py`, `custscope-truth.sql`, `dashboard-seed.sql`,
  `*-unseed.sql`); synthetic people, `example.invalid` addresses, guarded to `bpp_agent_demo_*`.
- `cases/`: `read`, `write`, `garbage`, `injection`, `mail-loop`, `model-switch` case sets (German prompts, demo-copy customers
  Stadlmayr, Edelsbacher, Feldhofner, Zehetgruber; `{{RUN}}` is replaced by the run id).

## Install by hand

Copy the folder to `~/.claude/skills/bpp-agent-llm-selftest/` (the mirror's `install.sh` renders `{{BPP_ROOT}}`), then
`cp selftest.env.example $DEMO_HOME/selftest.env` and fill the empty values.

## Verify

```bash
SELFTEST_ENV=$DEMO_HOME/selftest.env bash ~/.claude/skills/bpp-agent-llm-selftest/scripts/preflight.sh --no-login
```

Expected: one PASS/FAIL/WARN/SKIP/INFO line per check and `PREFLIGHT OK` on a healthy stack. It makes no LLM call and writes nothing.
