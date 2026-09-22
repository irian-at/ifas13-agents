---
name: project_zufluss-is-the-final-stichtag
description: "To select the Meldungen that became FINAL for a given Stichtag, filter on `zufluss`, not on a gueltAb/guelt/eintragezeit time window. Finalization stamps zufluss with the Stichtag; gueltAb is also re-stamped then, which makes it look usable but is a wall clock, not the business date."
metadata: 
  node_type: memory
  type: project
  originSessionId: 62e81758-8968-4196-b624-c47740e10955
  modified: 2026-09-22T09:11:56.118Z
---

# `zufluss` is the Stichtag a FINAL Meldung belongs to

`SteuerMeldungEntity.confirmAsFinalAt` (in-place CONFIRMED → FINAL, from
`SteuerMeldungPersistenceService.finalizeSteuerMeldung`) stamps **`zufluss` with the processing
Stichtag**. It is `null` while the Meldung is OPEN/CONFIRMED, so a non-null `zufluss` *is* the
"which Stichtag did this become FINAL for" marker.

**Why:** the same call also re-stamps `gueltAb` (to the confirm's `receivedAt`), which makes a
`gueltAb` range look like a usable "became FINAL since X" filter — it is not. `gueltAb` is a wall
clock, so a window over it drifts against the business date, and a late-committing finalize
transaction whose `receivedAt` was captured earlier can fall behind an already-advanced cursor and
be skipped forever. `eintragezeit` is worse: it is the row's original creation time and is never
touched by finalization. Mathias corrected exactly this design (2026-09-21, EstbDailyReportService).

**How to apply:** for anything that reports "the Meldungen of Stichtag D", filter
`status.statusCode = 'FIN' AND zufluss = :stichtag AND gueltBis IS NULL` — an equality on the
business date, no time window. Scope each daily run to its own `keyDate` rather than a rolling
range. When several runs share a Stichtag, de-duplicate by remembering the ids already reported
(`EstbDailyReportJob.stmIds`), not by advancing a timestamp.

The `gueltBis IS NULL` part is the usual active-version rule, see
[[project_gueltbis-active-meldung-discriminator]].
