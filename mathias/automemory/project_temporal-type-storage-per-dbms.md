---
name: project_temporal-type-storage-per-dbms
description: How OffsetDateTime/LocalDateTime/ZonedDateTime actually round-trip per DBMS; offset types store UTC on Sybase+Postgres, Vienna on H2.
metadata:
  type: project
---

All three types round-trip to the **same `Instant`** on H2, PostgreSQL and Sybase — but only
via `toInstant()`, and only if a `LocalDateTime` is re-anchored in `Europe/Vienna`. Measured
2026-08-31 by `TemporalTypeRoundtripTest` (`at.oekb.ifas.persistence.temporal`, in
ifas-integration-tests).

Stored wall clock for instant `2024-07-15T12:34:56Z` (Vienna 14:34:56 +02:00):

| DBMS | `getTimeZoneSupport()` | ts_offset / ts_zoned | ts_local |
|---|---|---|---|
| H2 | `NATIVE` | 14:34:56 (Vienna) | 14:34:56 |
| PostgreSQL | `NORMALIZE` | 12:34:56 (**UTC**) | 14:34:56 |
| Sybase ASE | `NONE` (base `Dialect` default) | 12:34:56 (**UTC**) | 14:34:56 |

Consequences that bite:
- On Sybase and Postgres an `OffsetDateTime` comes back with offset **Z**, not the written
  `+02:00` — `equals()` fails, `toInstant()` succeeds. On H2 the offset is preserved.
- The *same* instant is stored as **two different wall clocks** depending on the Java type used
  to write it. Do not compare a `LocalDateTime` column against an `OffsetDateTime` column in
  raw SQL, and expect legacy/CPP readers to see UTC in offset-typed columns.
- Sybase `datetime` truncated `.123456789` to `.123`; Postgres/H2 kept microseconds. The
  existing 4 ms `OffsetDateTimeAssertions.DEFAULT_DURATION_OFFSET` covers the 1/300 s quantum.

`hibernate.timezone.default_storage` is unset project-wide, so these per-dialect defaults apply.
`hibernate.jdbc.time_zone=Europe/Vienna` is set at all 18 JPA config sites, prod and test alike.

Note `ZonedDateTime` appears in no entity — removed in commit `36575b4ab`; it behaves exactly
like `OffsetDateTime` here, so nothing is lost by that choice.

See [[project_sybase-testcontainer-credentials]].
