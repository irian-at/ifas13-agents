---
name: project_jtds-shared-calendar-race
description: AIOOBE from GregorianCalendar under jTDS = Hibernate's shared static UTC_CALENDAR, not bad data
metadata:
  type: project
---

An `ArrayIndexOutOfBoundsException` out of `BaseCalendar.getCalendarDateFromFixedDate` /
`GregorianCalendar.computeFields` beneath `jtds…Support.timeToZone` is **never** a corrupt DB value:
Hibernate's `TimestampUtcAsJdbcTimestampJdbcType` hands one JVM-wide static `Calendar` to
`getTimestamp(int, Calendar)`, and jTDS converts by *writing into* it. Still unfixed in Hibernate 7.x.

**Why:** the crash is the loud form; the quiet form is a read returning *another thread's* timestamp,
so any "impossible" timestamp on Sybase deserves this suspicion first.

**How to apply:** `at.oekb.ifas.persistence.core.ThreadSafeTimestampUtcJdbcType` +
`…TypeContributor` (ServiceLoader, `ifas-persistence-core`) replace it per persistence unit; look for
the `TIMESTAMP_UTC handled by …` INFO line at EMF startup to confirm it took. Sybase + Postgres get
it (`TimeZoneSupport != NATIVE`), H2 keeps its `OffsetDateTime` descriptor. Only jTDS mutates the
caller's calendar — pgjdbc copies the time zone into its own. Related: [[project_temporal-type-storage-per-dbms]]
