---
name: bpp-connect-local-db
description: Use when user wants the agent to be able to query the local database of a .NET project — phrases like "connect to local db", "look at the db", "check the schema", "what tables exist", or any question that needs DB context. Discovers `appsettings.local.json` under cwd, parses `ConnectionStrings.DefaultConnection`, verifies the connection. Agent then explores the schema on demand via `psql`.
---

# bpp-connect-local-db

## Overview

Project-independent helper for .NET repos: locates `appsettings.local.json` under cwd, parses the connection string, and verifies the agent can reach the local PostgreSQL DB. After connecting, the agent should familiarize itself with the schema **on demand** by issuing targeted `psql` queries — not by pre-dumping everything.

## When to Use

- User asks anything that needs DB context: schema questions, table/column lookups, enum values, FK relationships
- "connect to local db", "check the schema", "what tables exist", "show columns of X"
- Connection is PostgreSQL via `appsettings.local.json`

**Don't use for:**
- Non-Postgres DBs — fail loudly, don't improvise
- Production / remote DBs
- Any write or modify operation (read-only)

## Steps

### 1. Find `appsettings.local.json` under cwd

```bash
find . -name 'appsettings.local.json' \
  -not -path '*/bin/*' -not -path '*/obj/*' \
  -not -path '*/node_modules/*' -not -path '*/.git/*'
```

- **0 matches** → tell user "no `appsettings.local.json` under cwd"; stop.
- **1 match** → use it.
- **≥2 matches** → list them, ask the user which to use. **Never silently pick.**

### 2. Extract `DefaultConnection`

```bash
jq -r '.ConnectionStrings.DefaultConnection' <path>
```

If `null` / missing → tell user; stop.

### 3. Validate Postgres + parse

.NET format: `Host=H;Port=P;Database=D;Username=U;Password=PW` (semicolon-separated, case-insensitive keys).

If the string contains `Server=` or `Data Source=` (SQL Server) or `Server=...;Uid=` (MySQL) → tell user only PostgreSQL is supported; stop.

Required keys: `Host`, `Port`, `Database`, `Username`, `Password`.

### 4. Verify connection

```bash
PGPASSWORD=<pw> psql -h <h> -p <p> -U <u> -d <db> -tAc "SELECT version();"
```

If the query succeeds, report a one-line confirmation: `connected to <db>@<host>:<port> (server <version>)`. Don't dump the schema.

### 5. Explore the schema on demand

After connection is verified, the agent should familiarize itself with the schema **only as needed** to answer the user's actual request. Use targeted queries from the table below — never pre-dump the full DDL.

## Schema Exploration Quick Reference

| Need | Query |
|------|-------|
| List tables | `SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;` |
| List enums | `SELECT typname FROM pg_type WHERE typtype='e' ORDER BY typname;` |
| Enum values | `SELECT unnest(enum_range(NULL::<enum_name>));` |
| Columns of a table | `\d <table_name>` (psql meta) or `SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='<t>' ORDER BY ordinal_position;` |
| FKs of a table | `\d <table_name>` shows them inline |
| All FKs DB-wide | `SELECT conrelid::regclass AS tbl, conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE contype='f';` |
| Indexes of a table | `\d <table_name>` or `SELECT indexname, indexdef FROM pg_indexes WHERE tablename='<t>';` |
| Search tables by name | `SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename ILIKE '%<keyword>%';` |
| Search columns by name | `SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='public' AND column_name ILIKE '%<keyword>%';` |

Run via:
```bash
PGPASSWORD=<pw> psql -h <h> -p <p> -U <u> -d <db> -c "<sql>"
```

## Common Mistakes

- **Silent first-match pick** when multiple `appsettings.local.json` exist → always prompt.
- **Pre-dumping the full DDL** "to be safe" → don't. Query only what's needed for the current task.
- **Inline password on command line** → use `PGPASSWORD=...` env prefix so it's not in shell history.
- **Assuming Postgres** without checking — fail loudly if connection string is SQL Server / MySQL.
- **Issuing write/DDL statements** — this skill is read-only.

## Red Flags

- About to pick first `appsettings.local.json` without asking → STOP, prompt user.
- About to run `pg_dump` or fetch huge result sets preemptively → STOP, query targeted.
- About to write/modify the DB → STOP, this skill is read-only.
- Connection string isn't Postgres → STOP, tell user, don't try to adapt.
