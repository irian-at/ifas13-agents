---
name: project_gueltbis-active-meldung-discriminator
description: "Legacy keys \"active meldung\" off `guelt_bis is null`, NOT status. Before treating an ERR_MELDID_FEHLT recalc deviation as missing fixture data, check whether the referenced meldung is present-but-ended (gueltBis set) — that's a validation bug, not a data problem."
metadata: 
  node_type: memory
  type: project
  originSessionId: 45d82f12-074f-4f2e-8e02-c1c95739a790
---

# `gueltBis` is the "active meldung" discriminator, not status

In legacy C++ (`c_st_meldung.cpp`, `cSt_Meldung::CheckVorhandeneMeldung`), the active-meldung lookup
is `select … where stm_id = X and guelt_bis is null`. The discriminator is **`guelt_bis`, not the
OPE/FIN status** (they only correlate):

- No active row (guelt_bis set) → `ERR_MELDID_FEHLT` ("Melde-ID nicht vorhanden").
- Active row (guelt_bis null) → successor scan → `ERR_UPD_OLDM`.

When an **OPEN** meldung is UPDATEd, `BeendeAlteMeldung` **sets** its `guelt_bis` (it does not delete
the row). A **FINAL** predecessor keeps `guelt_bis` null and stays active.

## Debugging heuristic for `ERR_MELDID_FEHLT` deviations

Before treating an Altsystem `ERR_MELDID_FEHLT` deviation as a fixture-data problem (recover/prune
per [[project_recalc-fixture-data-recovery]] / [[merge-yaml-export-extension]]), **check whether the
referenced meldung is present-but-ended (`gueltBis` set)**. If it is, legacy legitimately has the row
and the deviation is a *validation-behaviour* bug, not missing/extra data. Recovery/prune applies
only when legacy genuinely never had the row.

`SteuerMeldungStatusValidationService.validate()` is now gueltBis-aware: a same-ISIN predecessor
counts as the active `previousSteuerMeldung` only when `getGueltBis() == null` (`gueltBis` is exposed
on `DbSteuerMeldung` only — input/CSV STMs never have it). Do **not** filter the `existingMeldungen`
map map-wide — chain walks (`findVorherigeFinalSteuerMeldung`, successor lookups) still need ended rows.

Related: [[project_recalc-fixture-data-recovery]], [[recalc-historical-fidelity]].
