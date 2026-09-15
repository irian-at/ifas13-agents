---
name: feedback_flyway-one-file-per-feature
description: "Flyway scripts belonging to one feature go into a single migration file per tree, not one per table"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: cbe1daac-4228-4eb2-ab07-125e1a82ff3e
  modified: 2026-09-08T09:49:31.042Z
---

All Flyway DDL of one feature belongs in **one** migration file per database tree, not split into
one file per table (user, 2026-09-08).

**Why:** a feature's tables are created and reviewed together; five version numbers for one change
inflate the migration history and make the two trees harder to keep in sync.

**How to apply:** name it after the feature (`V065__fondspreise_sync.sql`), and write the same
version number in both `postgres15/` and `sybase16/`. Where a feature has both new tables and
provisioning of legacy Sybase-owned tables, keep them in that one file and let the header say which
half the Sybase variant omits and why. Two gotchas found while doing it: H2 rejects `timestamptz`
(use `timestamp(6) with time zone`, as V013/V014 do), and a migration only takes effect in tests
after `mvn install -pl ifas-database/ifas-database-flyway` — a `-pl` test run resolves the stale jar
from `~/.m2` and silently passes. Renumbering has the same trap from the other side: `mvn`
copies resources without deleting removed ones, so the old file name survives in `target/classes`
and Flyway aborts with `Found more than one migration with version <n>` until that module is
cleaned. Related: [[project_sybase-char-padding]].
