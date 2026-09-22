---
paths:
  - "**/db/migration/**"
---

# One Flyway File Per Feature

All DDL belonging to one feature goes into **one** migration file per database tree — not one file
per table. Name it after the feature (`V065__fondspreise_sync.sql`) and use the **same version
number** in both `postgres15/` and `sybase16/`.

Where a feature has both new tables and provisioning of legacy Sybase-owned tables, keep them in
that one file and let the header say which half the Sybase variant omits, and why.

This is the authoring rule. For what to do when those numbers collide at merge time, see
`flyway-versions-after-merge.md`.

## Two gotchas

- **H2 rejects `timestamptz`.** Use `timestamp(6) with time zone` — the spelling `V010`, `V064`,
  `V065` and `V068` use. H2 runs the PostgreSQL migrations directly in `MODE=PostgreSQL`, so a
  Postgres-only spelling breaks every H2 test. Where the two engines genuinely need different DDL,
  use the `${pg-only}` / `${h2-only}` placeholders (see `V068__jobs_timestamps_with_time_zone.sql`).
- **A migration only takes effect in tests after the module is installed:**
  `mvn -Pno-proxy install -pl ifas-database/ifas-database-flyway`. A `-pl` test run otherwise
  resolves the stale jar from `~/.m2` and silently passes. Renumbering has the mirror-image trap:
  Maven copies resources without deleting removed ones, so the old filename survives in
  `target/classes` and Flyway aborts with `Found more than one migration with version <n>` until
  that module is cleaned.

## Why

A feature's tables are created and reviewed together. Five version numbers for one change inflate
the migration history and make the two trees harder to keep in sync. User requirement, 2026-09-08.
