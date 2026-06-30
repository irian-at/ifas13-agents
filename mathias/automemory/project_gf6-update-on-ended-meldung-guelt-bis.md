---
name: gf6-update-on-ended-meldung-guelt-bis
description: "gf6 UPDATE;649522 deviation was NOT a fixture-data problem (recover/prune) but a code bug — the new system ignored guelt_bis when deciding if a referenced meldung is \"active\". Fixed by exposing gueltBis on DbSteuerMeldung and gating the previous-meldung lookup."
metadata: 
  node_type: memory
  type: project
  originSessionId: 1a92d115-f60a-4dbd-ae06-4835c251afac
---

# gf6 `UPDATE;649522`: guelt_bis-aware "active meldung" lookup (code fix, not data)

In `GrossfileRecalculationTest`, gf6 line 1 (`STATUS;UPDATE;649522`, ISIN LU0066902890) deviated:
legacy emitted `ERR_MELDID_FEHLT` ("Melde-ID <649522> ist nicht vorhanden"), new system emitted
`ERR_UPD_OLDM` ("…bereits ein UPDATE geliefert. Aktuelle Melde-ID: <649579>").

**It looked like the gf3 "missing stmId" pattern (recover from a later fixture, or prune) — but it was neither.**
649522 IS present in gf6's fixture (and gf7's), and legacy keeps it on purpose.

## The real mechanism (verified in legacy C++ `c_st_meldung.cpp`)

`cSt_Meldung::CheckVorhandeneMeldung` does its initial active-meldung lookup as
`select … where stm_id = X and guelt_bis is null` (~line 8032).
- No active row found (guelt_bis is set) → `else` branch → **`ERR_MELDID_FEHLT`** (~9336).
- Active row found → forward successor scan → **`ERR_UPD_OLDM`** (~9045).

When an **OPEN** meldung is UPDATEd, `BeendeAlteMeldung` **SETS its `guelt_bis`** (does NOT delete the row).
A **FINAL** predecessor keeps `guelt_bis` null and stays active. So the discriminator is `guelt_bis`,
NOT status — OPE/FIN only correlate:

| meldung | status | gueltBis | legacy active? | legacy msg |
|---|---|---|---|---|
| gf6 649522 | OPE | set | no | `ERR_MELDID_FEHLT` |
| gf4 649571 | FIN | null | yes (+successor) | `ERR_UPD_OLDM` |

The new system's `SteuerMeldungStatusValidationService` ignored `guelt_bis`: `getExistingMeldungenByIsin`
(via `findAllStmIdsByIsin`) loads ended rows, `existingMeldungen.get(stmId)` returned the ended 649522,
and `previousExistsAnywhere` used raw `existsById` — so it treated the ended row as the active predecessor
and ran the `ERR_UPD_OLDM` path.

## Fix applied (2026-06-30, on master)

1. Exposed `getGueltBis()` on **`DbSteuerMeldung`** (NOT `SteuerMeldung` — it is DB-only; input/CSV STMs
   never have it). Implemented in `LazyDbSteuerMeldung`, `EagerDbSteuerMeldung`, test `MockDbSteuerMeldung`
   (+ `withGueltBis` builder). Entity already had `SteuerMeldungEntity.guelt_bis` (LocalDateTime).
2. In `SteuerMeldungStatusValidationService.validate(...)`: a same-ISIN predecessor counts as the active
   `previousSteuerMeldung` only when `getGueltBis() == null`; the `existsById` fallback is consulted only
   when the stmId is absent from the same-ISIN map (cross-ISIN). `resolvePreviousIsinAnyMatch` is still fed
   the raw hit so `ERR_ISIN_MID` is unaffected. **Do NOT** filter the `existingMeldungen` map map-wide —
   `findVorherigeFinalSteuerMeldung` / `findLatestUndeletedSuccessorStmId` need ended rows for chain walks.
3. Corrected the Javadoc on `UpdOldmCoveredByUpdOldmLieferung` (it claimed legacy raises ERR_UPD_OLDM for
   any DB successor; really only when the predecessor is still active).
4. gf6 error baseline in `GrossfileRecalculationTest` `(0,0,0,1,1,0)` → `(1,0,0,0,0,0)`.

Verified: gf6 deviations file clean; gf1–gf8 + 552 domain-stm unit tests pass.

## Lesson for future "Melde-ID nicht vorhanden" deviations

Before treating an Altsystem `ERR_MELDID_FEHLT` deviation as a fixture problem (recover/prune per
[[merge-yaml-export-extension]] / [[gf3-missing-stmids-recoverable-from-gf4]]), **check whether the
referenced meldung is present-but-ended (`gueltBis` set)**. If it is, legacy legitimately has the row and
the deviation is a *validation-behaviour* bug, not missing/extra data. The skill's "prune meldungen the
legacy doesn't expect" path applies only when legacy genuinely never had the row.
