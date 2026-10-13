---
name: project_job-counters-vs-protocol
description: Job subtype tables carry only the few counters a list or filter needs; per-item detail goes into the job's protocol file (jobs.protocol_file_ref), decided 2026-10-08 for PreisVersionSyncJob and PreisVersionJob
metadata:
  type: project
---

A job subtype table (`*_jobs`, JOINED child of `jobs`) gets **only the counters something lists, filters
or must commit with the job's data**. Everything per item (which line was skipped for which rule, which
key was written or removed, Zwischenwerte) goes into the job's **protocol**: `jobs.protocol_file_ref`,
written by `JobAutoProtocolAndNotificationService.executeWithProtocol(...)` (no Fachbereich mail unless
decided) and returned from `AbstractJobWorkQueueHandler.executeAsynchronously`, shown by
`fragments/job-detail :: protocolCard`. Sums of other columns and mechanics (rows deleted/inserted) are
not columns. Decided 2026-10-08: `preis_version_sync_jobs` 8 → 5 counters, `preis_version_jobs` 11 → 8
(`zeilen_no_key`, `zeilen_without_effect`, `versions_deleted` dropped in V079, not in a new migration,
because no productive run exists).

**Why:** he looked at the eight sync counters and asked "should this not go to a protocol instead of so
many columns?"; a column is queryable and transactional, a protocol is readable and detailed, and the
house already pairs few counters with a protocol (`ausschuettungs_meldung_batch_jobs`).

**How to apply:** when a new job type gets result columns, ask of each: will a list show it, a filter
use it, or must it commit with the job's writes? Otherwise it is a protocol line. Protocol lines at INFO
or above (DEBUG is not captured); the protocol lives outside the job's transaction, counters inside.
Related: `mathias/rules/fondspreise-naming.md`, [[project_sybase-schema-freeze]].
