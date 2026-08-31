---
name: project_sybase-testcontainer-credentials
description: Repo-root .env supplies the 4 Sybase testcontainer keys (now present locally); .idea enables skip-sybase16-tests so the IDE silently drops Sybase; jTDS product name is exactly "ASE".
metadata:
  type: project
---

`SybaseTestcontainer` reads `SYBASE_TESTCONTAINER_USER` / `_PASSWORD` / `_SA_USER` /
`_SA_PASSWORD` from the Spring `Environment`, fed by a **repo-root `.env`** via
`springboot3-dotenv` (`springdotenv.directory=../..`). Those four keys are the only env vars
`ifas-testing` reads.

**A repo-root `.env` now exists locally** (created 2026-08-31, gitignored at `.gitignore:749`)
holding the public `datagrip/sybase:16.0` defaults, which are hardcoded in the image's own
`/entrypoint.sh` — not OeKB secrets. So Sybase testcontainer runs work with no extra flags. If
that file goes missing the symptom is misleading: `withUsername(null)` beats the container
default and the run dies with `Container is started, but cannot be accessed` plus an NPE, which
reads as a container problem rather than a credential one.

**Sybase is still skipped in the IDE**: `.idea/misc.xml` lists `skip-sybase16-tests` under
`enabledProfiles`, which sets `ignore-test-dbms-sybase-testcontainer=true`.
`MultiDatabaseExtension.isIgnored` then filters the profile out of the map *before any invocation
is generated*, so a `TEST_WITH_ALL_DATABASE_SYSTEMS` test silently yields 8 invocations instead
of 12 with `Skipped: 0` — the only trace is one INFO line "Ignoring tests for profile". Run
Sybase from the CLI without that profile, or from the IDE's JUnit runner (surefire is not
involved there, so the property is never set).

Two related gotchas:
- **jTDS reports `getDatabaseProductName()` as exactly `"ASE"`** (version `16.2`, driver name
  "jTDS Type 4 JDBC Driver for MS SQL Server and Sybase"). Not "Adaptive Server Enterprise" —
  substring matching on that fails silently and you fall through to the wrong DDL branch.
- The `postgres:15` testcontainer has **no `withReuse`** and a default 60 s log-wait, so it
  cold-starts every JVM and times out on this machine when three contexts are in one run. Sybase
  uses `withReuse(true)`, so it survives across runs. Verify the three DBMS in split runs
  (`-Pskip-postgres15-tests` / `-Pskip-sybase16-tests`) when the all-three run flakes.

See [[project_temporal-type-storage-per-dbms]].
