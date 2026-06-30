---
name: project_gf8-recovery-and-sn-frist-gap
description: "gf8 error deviations — 2 were missing-data (recovered from gf2/gf5 fixtures), 2 are a real SN-during-Frist code gap, not data."
metadata: 
  node_type: memory
  type: project
  originSessionId: c31b68f8-c529-4ed7-bc0b-e329eb15c8c3
---

gf8's setup YAML is `gf7-d20261216-export-AFTER.yaml.txt` (state after gf7 = before gf8). Its 4 error deviations split into two distinct classes — only one is fixable by the merge skill:

**Missing data (fixed 2026-06-30 via [[merge-yaml-export-extension]] `--extract --include-isins`):**
- Z6 `LU0145634076` (UPDATE 649566) and Z32 `LU0125743475` (CONFIRMED 649594) — ISINs + meldungen absent from gf7-AFTER (sybase-gast lost them). New system reported "Melde-ID nicht vorhanden" + "ISIN nicht registriert" instead of legacy's Frist errors.
- Recovered: 649566 (`FIN`) from gf3-zip's `gf2-AFTER`; 649537 (`FIN`) + 649594 (`OPE`, prev 649537) from gf6-zip's `gf5-AFTER`. Both funds were untouched by gf3–gf7 (verified via all gfN CSVs), so post-gf2/post-gf5 state == post-gf7 state — **no time-filter exclusions needed**. No `gueltBis` on any, so nothing to re-source pre-T (unlike [[project_gf7-missing-data-recovered-from-gf8]]).
- Result: error summary `(3,0,0,4,4,0)` → `(5,0,0,2,0,0)`; baseline in `GrossfileRecalculationTest.baselines()` updated to match.

**SN-during-Frist code gap (NOT data, still open):**
- Z13 `LU0390864923` (UPDATE 649600) and Z27 `LU0396332305` (UPDATE 649602) — all referenced meldungen present in YAML; LU0423950210 (same scenario but SN=NEIN) matches exactly.
- Both submit `Selbstnachweis=JA` (START field after country=`LU`) against an original meldung that was `NEIN` (info.log: "Parameter Selbstnachweis <JA> entspricht nicht dem Parameter <NEIN>"). Legacy raises ERR "...kann daher nicht als Selbstnachweis Meldung abgegeben werden" because the update lands inside the Melde-/Korrekturfrist; the new system did **not** raise it.

**FIXED 2026-06-30** (ERR_SN_INMELDEFRIST for UPDATE on OPE without FINAL): root cause was in `SteuerMeldungStatusValidationService.validate()` — for UPDATE it fed `errSnInmeldefrist` the deadline from `korrekturfristAsLastChance(...)`, which returns null when there's no FINAL ancestor, so the validator's `if (lastChance == null) return;` guard suppressed the error. Legacy: UPDATE on a FINAL uses the Korrekturfrist (Dec 15 of FINAL Zufluss year, `c_st_meldung.cpp:9085`); UPDATE on an OPE with no prior FINAL falls into `CheckLieferfristen()` and uses the regular **Meldefrist** = `gjEnde + 7M` (`c_st_meldung.cpp:9603`, condition `(daDatum-7M) <= gjEnde` ⟺ `stichtag <= gjEnde+7M`). Fix: when `korrekturfristAsLastChance` is null, fall back to the Meldefrist. Extracted `SteuerMeldungFristenValidators.meldefristAsLastChance(stm)` = `gjEnde.plus(LAST_CHANCE_GRACE_PERIOD=7M)` and reused it for BOTH this fallback and the existing `errFristNosn` deadline (was inline at the same spot). gf8 error baseline → `(7,0,0,0,0,0)`. The validator function itself was already correct; only the caller's deadline selection was wrong.
