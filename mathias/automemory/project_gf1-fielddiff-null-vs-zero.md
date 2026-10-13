---
name: project_gf1-fielddiff-null-vs-zero
description: "GrossfileRecalculationTest locks down calculatedVsOldReturn field diffs and STATUS_* diffs only; gf1's ~11151 newReturnVsOldReturn diffs are benign null-vs-explicit-zero country-vector noise, deliberately excluded."
metadata:
  type: project
---

`GrossfileRecalculationTest` has two lockdowns per grossfile:

- **`FieldDiffExpectation`** counts only `calculatedVsOldReturn` diffs (private
  `countCalculatedVsOldReturnDiffs` streaming `steuerMeldungRecalculations()`), all 8 grossfiles at
  `(0,0)` — "the calculated STM matches the legacy return field-by-field". It never sees STATUS fields
  (`IGNORE__STATUS_...` filter) and stays 0 even for real status divergences: when the new system
  escalates a meldung to ERROR it skips the Ermittlung (`calculatedSteuerMeldung` null → diff null).
- **`StatusDiffExpectation`** counts `STATUS_*` diffs from `newReturnVsOldReturn` only
  (`countStatusReturnDiffs`, `fieldName().startsWith("STATUS")` — `FieldDiff.fieldName()` drops the
  leading underscore of `_STATUS_*`). Baselines gf1=(7,0), gf2=(2,0), gf5=(1,0), rest (0,0).
  gf1 = 3×STATUS_STATUS + 3×STATUS_ANMERKUNG + 1×STATUS_MELDUNGS_ID (recalc sentinel 9999999999 vs
  real id); gf2 = 1+1; gf5 = 1×STATUS_MELDUNGS_ID_REF (NEU=649528 / ALT=n.v., the
  VorherigeFinalStmIdResolver filling a ref legacy had none for).

**Deliberately excluded:** `BundleRecalculationResult.countErrorFieldDiffs()` also sums the
`newReturnVsOldReturn` round-trip, which for gf1 yields ~11151 benign diffs. Two things combine: the
new system drops zero-valued country-vector entries for unreported countries
(`CountryVector.filterZeroValuesForCountries` via `SteuerMeldungPostProcessing.removeUnreportedCountries`)
→ written to the return CSV → reloaded as absent, while legacy wrote explicit `0.0000` per country; and
the `newReturnVsOldReturn` config (`StmDiffConfigs.EXPECTED_OLD_RETURN_FILE_VALUES_VS_ACTUAL_NEW_RETURN_FILE_VALUES`)
has `actualMissingValueEqualsExpectedZero` / `…VectorEntry…` = **false**, whereas the
`calculatedVsOldReturn` config has them **true**. 93 % is 77 meldungen × the same 135-field
`D_/Z_/ZA_/AS_` block. Verified: no new-null diff has a non-zero legacy value.

**Why the tolerance does not fire:** `KnownLegacySystemIssues.tolerateWronglyReportedZeroValueCountryCodes`
(country set populated per STM by `RecalculationDomainService.determineToleratedWronglyReportedZeroCountryVectors`)
guards on both sides being `CountryVector`; after the CSV round-trip the new side is `null`.
`knownOldReturnFileIssue` does handle `null` vs all-zero, but only for the 7 `OLD_RETURN_FILE_ISSUE_FIELDS`.
Targeted fix if the noise ever needs silencing: treat a null new value as an empty CountryVector inside
that guard. Do **not** flip the config flags (would also hide genuinely dropped non-zero values).

**How to apply:** re-baseline only when those config flags change or the return-CSV writer starts
emitting explicit zeros; whether it *should* is a Fachabteilung/format call. Related:
[[project_recalc-historical-fidelity]], [[project_legacy-return-col4-vorherige]].
