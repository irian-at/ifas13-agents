# Split ERR_MELDID_FEHLT vs ERR_MELDID_NICHT_MEHR_GUELTIG + bridge legacy in recalc

## Context

Legacy raises a single `ERR_MELDID_FEHLT` for a referenced Melde-ID whenever its active lookup
(`where stm_id = X and guelt_bis is null`) finds nothing — for **both** a truly non-existing stmId
**and** a present-but-ended (`guelt_bis` set, "ungueltig") one. Legacy cannot distinguish them.

The new system now splits these:
- truly missing → `ERR_MELDID_FEHLT` (error, exact-matches legacy)
- present-but-ended → `ERR_MELDID_NICHT_MEHR_GUELTIG` (the "ungueltig" case, to be shown as a
  **warning when only-in-new** during recalc via `meldIdNichtMehrGueltigDiffsAsWarning`)

See [[project_gueltbis-active-meldung-discriminator]].

## Already done in the working tree (verified — do NOT redo)

- `SteuerMeldungStatusValidators.errMeldidFehlt` narrowed to `!inputStmExists` (truly missing);
  `errMeldidNichtMehrGueltig` gated on `inputStmExists && !inputStmIsValid` (ended). The two are now
  mutually exclusive — verified over all reachable states (missing → FEHLT; ended → NICHT_MEHR;
  active → neither; cross-ISIN → neither, handled by `ERR_ISIN_MID`). Call site in
  `SteuerMeldungStatusValidationService:135-147` matches the new signatures.
- New enum `ValidationMsgCode.ERR_MELDID_NICHT_MEHR_GUELTIG` (same text as `ERR_MELDID_FEHLT`).
- `ValidationSetting.meldIdFehltDiffsAsWarning` renamed to `meldIdNichtMehrGueltigDiffsAsWarning`;
  delta wiring (`ValidationDeltaCalculator`, `ValidationDeltaReports`,
  `MSG_CODES_SHOWN_AS_WARNINGS_IF_MELDID_NICHT_MEHR_GUELTIG_FLAG_SET`) updated. The onlyInNew →
  warning path is correct and complete.

## Remaining problem: two-sided divergence in recalc (Timing B)

The recalc delta matches legacy log text (parsed to a `ValidationMsgCodePattern`) against new enum
codes. Two timings occur:

- **Timing A — legacy logged nothing for this record** (Altsystem ended the meldung via a *later*
  delivery). New raises `ERR_MELDID_NICHT_MEHR_GUELTIG` with no legacy counterpart → `onlyInNew` →
  warning. **Handled by the done change.**
- **Timing B — legacy already logged `ERR_MELDID_FEHLT` for this record.** Before the split, new also
  emitted `ERR_MELDID_FEHLT` → clean **exact match**. After the split, new emits
  `ERR_MELDID_NICHT_MEHR_GUELTIG`, which is not in the legacy pattern's `equivalentCodeNames()`
  (`{ERR_MELDID_FEHLT}`) and has no covered-by rule → **no match**: legacy strands in `onlyInLegacy`
  as a hard error (the diff gutted `isShowAsWarningIfOnlyInLegacy` to always-false) and new shows as
  an `onlyInNew` warning. One real event → a false two-sided divergence.

Both timings occur, so Timing B must be handled or it produces stray legacy-side hard errors.

## Fix: add a covered-by rule (mirror the StatusNm precedent)

Do **not** add a `ValidationMsgCodePattern` for the new code (legacy never emits it, and template-
sharing would make legacy `ERR_MELDID_FEHLT` interchangeable with both new codes, masking real
mismatches). Use a directional covered-by rule instead — semantically honest (`COVERED` quality) and
scoped to the same meldung by the per-meldung comparison block.

**New class** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/MeldIdFehltCoveredByNichtMehrGueltig.java`
implementing `CoveredByRule`, modeled exactly on `StatusNmCoveredByStatusNmLieferung`:
- return covered when `legacy.matchedPattern() == ValidationMsgCodePattern.ERR_MELDID_FEHLT`
  **and** `newValidation.getValidationMsgCode() == ValidationMsgCode.ERR_MELDID_NICHT_MEHR_GUELTIG`.
- reason string: legacy's combined "nicht vorhanden" covers the new system's distinct
  "nicht mehr gueltig" (Parallelbetrieb: guelt_bis set by Altsystem).

**Register** it in `CoveredByRules.DEFAULT_RULES` (`CoveredByRules.java:18-24`).

Resulting behavior — exactly the intent:
- Timing B (both present) → `COVERED` match → agreement, no error, no warning.
- Timing A (only new) → `onlyInNew` → warning (covered-by is only consulted when a legacy
  counterpart exists).

## Verification

- Unit test for `MeldIdFehltCoveredByNichtMehrGueltig`: legacy `ERR_MELDID_FEHLT` + new
  `ERR_MELDID_NICHT_MEHR_GUELTIG` → covered; legacy `ERR_MELDID_FEHLT` + new `ERR_MELDID_FEHLT` → not
  covered (exact match handles it); mismatched codes → not covered.
- Delta-level test (cf. `ValidationDeltaReportsStatusNmTest`): Timing B fixture → one `COVERED` pair,
  no `onlyInLegacy`/`onlyInNew`; Timing A fixture → one `onlyInNew` warning when
  `meldIdNichtMehrGueltigDiffsAsWarning` set.
- `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy`.
- Recalc: `JiraIssueRecalculationTest` with a Parallelbetrieb fixture (ended meldung) → no stray
  hard errors for the ended reference.
