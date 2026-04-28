---
paths:
  - "ifas-database/ifas-database-flyway/**/*.sql"
---

# Flyway Migration Rules

Reference for writing Flyway database migrations in IFAS13.

## Overview

Flyway migrations live in:

```
ifas-database/ifas-database-flyway/src/main/resources/db/migration/
  postgres15/   <- PostgreSQL AND H2 (shared!)
  sybase16/     <- Sybase only
```

This rule covers the `postgres15/` folder. Sybase migrations use different syntax and are handled separately.

## Critical Rule: H2 Compatibility

The `postgres15/` folder is used for **both PostgreSQL and H2** databases. Every migration must use SQL syntax that works on both. H2 is used for fast local development (`SpringBootH2IfasMainApplication`), so a migration that breaks H2 blocks the entire team.

## File Naming

Format: `V###__description_with_underscores.sql`

- Version number is **zero-padded to 3 digits**: `V001`, `V002`, ..., `V013`
- Current latest version: **V016** (next migration is **V017**)
- Description uses **underscores** between words (not hyphens)
- Check existing files before choosing a version number — collisions break Flyway

## SQL Patterns

### Allowed Data Types

| Type | Usage | Example |
|------|-------|---------|
| `UUID` | Primary keys (modern style) | `id UUID PRIMARY KEY` |
| `bigint` | Primary keys (legacy style) | `stm_id bigint not null` |
| `integer` | Counts, small numbers | `attempt_count INTEGER NOT NULL DEFAULT 0` |
| `TEXT` | Strings (unbounded), JSON data | `payload TEXT NOT NULL` |
| `varchar(n)` | Strings (bounded) | `liefer_id varchar(30)` |
| `char(n)` | Fixed-width strings | `ertragstyp char(1)` |
| `numeric(p,s)` | Exact decimals | `anzahl_anteile numeric(23, 8)` |
| `date` | Date without time | `key_date date not null` |
| `timestamp(6)` | Timestamp without timezone | `created_at timestamp(6)` |
| `TIMESTAMP(6) WITH TIME ZONE` | Timestamp with timezone | `created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL` |
| `bytea` | Binary data | `content bytea` |
| `boolean` | Boolean flags | `archived boolean NOT NULL DEFAULT false` |

**Note:** `boolean` is supported by both PostgreSQL and H2, so it can be used for tables that don't need Sybase compatibility.

### Forbidden Types

| Type | Problem | Use Instead |
|------|---------|-------------|
| `JSONB` | Not supported in H2 | `TEXT` |
| `TIMESTAMPTZ` | PostgreSQL shorthand, fails on H2 | `TIMESTAMP(6) WITH TIME ZONE` |
| `SERIAL` / `BIGSERIAL` | Not supported in H2 | `UUID` or application-assigned `bigint` |

### Check Constraints

Use inline `CHECK` constraints for enum-like columns:

```sql
-- TEXT column with CHECK (modern style, from V013)
status TEXT NOT NULL CHECK (status IN ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED', 'CANCELLED'))

-- varchar column with CHECK (legacy style, from V004)
art varchar(10) check (art in ('InvF', 'ImmoInvF', 'AIF', 'ImmoAIF'))

-- char column with CHECK
ertragstyp char(1) not null check (ertragstyp in ('A', 'T', 'V'))
```

### Indexes

**Simple indexes only.** No partial indexes (no `WHERE` clause) — H2 does not support them.

```sql
-- Correct: simple indexes
CREATE INDEX idx_wq_task_type ON work_queue_items (task_type);
CREATE INDEX idx_wq_status ON work_queue_items (status);

-- WRONG: partial index (PostgreSQL-only)
CREATE INDEX idx_wq_pending ON work_queue_items (status) WHERE status = 'PENDING';  -- H2 will fail!
```

### Foreign Keys

Use `ALTER TABLE IF EXISTS` pattern:

```sql
alter table if exists stm_recalc_jobs
    add constraint fk_stm_recalc_jobs_job_id
    foreign key (id)
    references jobs;
```

Naming convention: `FK_<child_table>2<parent_table>` or `fk_<child_table>_<column>`.

### Unique Constraints

Can be inline in `CREATE TABLE`:

```sql
constraint AK_STUER_BEH_ALT_KEY_STEUER_M unique (num_wfs_ku, gj_ende, guelt_ab)
```

### Permissions (Required!)

**Every table** must have a `GRANT` statement for the application user:

```sql
GRANT SELECT, INSERT, UPDATE ON TABLE my_table TO ${app-user};
```

The `${app-user}` placeholder is resolved by Flyway at runtime. Do not hardcode a username.

## Migration Structure Template

Copy this skeleton when creating a new migration:

```sql
-- Brief description of what this migration does
-- Note: Uses H2-compatible syntax (shared with postgres15/)

CREATE TABLE my_table (
    id                  UUID PRIMARY KEY,
    name                TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('ACTIVE', 'INACTIVE')),
    amount              numeric(23, 8),
    key_date            date,
    created_at          TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    updated_at          TIMESTAMP(6) WITH TIME ZONE
);

-- Indexes (simple only, no WHERE clause)
CREATE INDEX idx_my_table_status ON my_table (status);

-- Permissions (required for every table)
GRANT SELECT, INSERT, UPDATE ON TABLE my_table TO ${app-user};

-- Foreign keys (after all referenced tables exist)
-- alter table if exists my_table
--     add constraint fk_my_table_other_id
--     foreign key (other_id)
--     references other_table;
```

## Sybase Considerations

Sybase migrations live in `sybase16/` and use different syntax (e.g., no `CHECK` constraints inline, different timestamp types). This rule does not cover Sybase. If a feature requires Sybase support, write a **separate** migration in `sybase16/` with Sybase-compatible syntax.

Not all features need Sybase migrations — check whether the feature is PostgreSQL-only (e.g., work queue is PostgreSQL-only but still has a Sybase migration for schema parity).

**Always keep Sybase script numbering in sync with PostgreSQL/H2.** When adding a new PostgreSQL/H2 migration (e.g., `V015__my_change.sql`), always create a corresponding Sybase migration file with the same version number. If the change is not applicable to Sybase, create the file with only a comment explaining why:
```sql
-- not required in sybase database
```
This ensures Flyway version numbering stays consistent across all database backends.

## Common Mistakes

1. **Using `JSONB`** — H2 doesn't support it. Use `TEXT` and store JSON as a string.
2. **Using `TIMESTAMPTZ`** — PostgreSQL shorthand. Write out `TIMESTAMP(6) WITH TIME ZONE`.
3. **Using `SERIAL`/`BIGSERIAL`** — Not portable. Use `UUID` primary keys or application-managed sequences.
4. **Partial indexes with `WHERE`** — H2 doesn't support them. Use simple indexes only.
5. **Forgetting `GRANT` statements** — Every table needs `GRANT SELECT, INSERT, UPDATE ON TABLE ... TO ${app-user};`.
6. **Wrong version number** — Check the latest `V###` file before naming. Duplicate versions break Flyway startup.
7. **Not testing with H2** — Always verify by running `SpringBootH2IfasMainApplication` after adding a migration.
8. **Using hyphens in filename** — Use underscores: `V014__my_table.sql`, not `V014__my-table.sql`.
9. **Editing an existing migration** — We are in staging mode. Existing migration scripts are immutable and must never be modified. Always create a new incremental migration script (e.g., `V015__add_column.sql`) for schema changes to existing tables.

## Verification

After writing a new migration:

1. **Run H2 application**: Start `SpringBootH2IfasMainApplication` and confirm it starts without Flyway errors
2. **Check Flyway output**: Look for `Successfully applied N migration(s)` in the startup log
3. **Run tests**: `mvn test -pl ifas-database/ifas-database-flyway -Pno-proxy -Pplatform-arm64`

## Reference Migrations

| Migration | Style | Key Patterns |
|-----------|-------|-------------|
| `V013__work_queue.sql` | Modern | UUID PK, TEXT, CHECK constraints, TIMESTAMP(6) WITH TIME ZONE, indexes, grants |
| `V009__stm_recalc_jobs.sql` | Modern | Foreign keys with ALTER TABLE IF EXISTS, JPA JOINED inheritance, bytea |
| `V004__steuermeldung.sql` | Legacy | bigint PK, varchar checks, numeric precision, composite keys, unique constraints |