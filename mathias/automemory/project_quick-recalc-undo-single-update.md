---
name: project_quick-recalc-undo-single-update
description: "To test whether an UPDATE would have been accepted/rejected using a quick-recalc yaml that's a post-processing export, strip the successor STM it created (+ child rows) and revert the predecessor's guelt/gueltBis to reproduce the pre-update DB state."
metadata: 
  node_type: memory
  type: project
  originSessionId: 1b89b7f7-7c02-49da-a202-ca702a59c468
  modified: 2026-09-21T13:51:02.351Z
---

A `quick-recalc` fonds-export yaml is often an **export-AFTER** snapshot: taken once a suspect
UPDATE has already run and mutated the DB. Replaying the same input CSV against that snapshot
doesn't test the original question — the targeted stmId is now superseded (`gueltBis` set), so
you get `ERR_MELDID_NICHT_MEHR_GUELTIG` instead of the Fristen/status outcome you actually wanted
to check.

**Undo recipe** (single-STM version of [[project_recalc-fixture-data-recovery]]'s grossfile pattern):

1. Remove the `STEUER_MELDUNG` block(s) the update created — the direct successor
   (`vorherigeStmId` = the target) and anything chained further off it (e.g. a later DELETE of
   that successor).
2. Remove their child rows too — `STEUER_FIELDS_DATA` / `STEUER_BEH_DATA` / `GESCHAEFTSJAHR`
   blocks matched by `stmId:`, not just the parent `STEUER_MELDUNG` blocks. These vastly
   outnumber the parent rows (hundreds each) and are scattered through the file, not colocated.
3. On the predecessor: **drop `gueltBis` entirely** (null = active again) and **revert `guelt`**
   back to the predecessor's own `eintragezeit`/`gueltAb` value — `SteuerMeldungRepository
   .closeIfOpen` only ever touches `guelt` + `gueltBis`, setting both to the same `now`, so the
   pre-close `guelt` always equals the row's own creation timestamp.

A plain `awk`/Python block-splitter on `^- !<TYPE>` boundaries handles this fine even on a
500k-line yaml — no need for a real YAML parser. Verify counts: removed child-row count should be
an exact multiple of the removed parent count (e.g. 573 fields-per-STM × 2 removed STMs = 1146,
plus the 2 parent blocks = 1148 total).

The auxiliary `_confirm.csv`/`_delete.csv`/`_return.csv` files that often sit alongside the main
input CSV in a legacy-style result zip are safe to leave untouched: `RecalculationDomainService
.doRecalc` only picks ONE input per bundle, preferring the plain Melde-CSV
(`STM_MELDUNG_CSV_FILE`) over confirm/delete/prefilled-Excel — the return file is only read
separately for delta comparison. They aren't replayed as a chain.

Related: [[project_recalc-fixture-data-recovery]], [[project_gueltbis-active-meldung-discriminator]],
[[project_quick-recalc-stale-test-classes]].
