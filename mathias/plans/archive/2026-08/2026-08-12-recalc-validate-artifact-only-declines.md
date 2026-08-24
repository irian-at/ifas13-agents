# Recalc: let calculated-field validation run for artifact-only declines

## Context

In a recalculation run with `ValidationSetting.RECALC_ARTIFACT_DIFFS_AS_WARNING`, a meldung whose only
error is a replay artifact (`ERR_JAHRESM_VORH`, `ERR_AUSSCHM_VORH`, `ERR_MELDID_NICHT_MEHR_GUELTIG`,
`ERR_STATUS_NM` artifacts, `ERR_UPD_OLDM`) is still declined whenever the legacy return status was not
successful. `SteuerlicheErmittlungDomainService.calcFailedStatus:311-326` gates the leniency on
`legacyReturnStatus == null || legacyReturnStatus.isSuccessfulReturnStatus()`.

That gate creates a chicken-and-egg problem, visible on IE00BD350682 in the EY_2026-07-14_120958
delivery:

- legacy return status is `ERROR`, caused by three `ERR_KONTROLL_LSN_LT_0` errors (negative
  D_Dividenden sums for CA/NL/US) — a **post-calculation** check;
- the new system declines the meldung pre-calculation on `ERR_JAHRESM_VORH` (the artifact);
- `shallPostProcessValidate:219-221` only validates STMs with a successful status, so the
  calculated-field validation never runs and those three errors are never raised;
- they surface as three `[-] NUR IM ALTSYSTEM (FEHLER)` deviations, and the meldung returns
  `NEW_DECLINED` where legacy returned `ERROR`.

Legacy never saw the artifact error at all: it calculated the fields and ran the KONTROLL checks. The
faithful replay is to do the same — ignore the flagged artifact for the status decision, let the
calculated-field validation run, and let a real error found there decide the status.

Intended outcome: with the flag set, IE00BD350682 raises the three `ERR_KONTROLL_LSN_LT_0` errors and
returns `ERROR` (matching legacy); the three only-in-legacy deviations disappear. With the flag unset,
nothing changes.

## Change 1 — drop the legacy-return-status gate

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java`

Rewrite `calcFailedStatus` (303-329) so the flagged artifacts are simply not a failure reason in
recalculation mode:

```java
private @Nullable StmStatusWithAdditionalInfo calcFailedStatus(
        SteuerMeldung inputStm,
        ValidationMsgStore allValidationMsgs,
        SteuerlicheErmittlungRecalcOptions options
) {
    List<ValidationMsg> validationMsgsForThisStm = allValidationMsgs.validationMsgsForEntry(inputStm.getSourceEntry());
    if (options.recalculationMode() && hasOnlyKnownRecalcIssueErrors(options, validationMsgsForThisStm)) {
        // Legacy never saw these replay artifacts, so it calculated the fields and validated them.
        // Report no failure so the STM keeps its successful tentative status and reaches the
        // post-calculation validation; finishProcessing re-decides with those msgs merged in.
        return null;
    }
    return calculateDeclinedOrErrorStatus(inputStm, validationMsgsForThisStm, options);
}
```

Why this is all that is needed — `calcFailedStatus` is called twice, and the same rule gives the right
answer in both passes:

| pass | call site | msgs seen | outcome for an artifact-only decline |
|------|-----------|-----------|--------------------------------------|
| pre-calculation | `handleInputStm:260` | pre-calc only | `null` → tentative `OPEN`/`FINAL`/`DELETED` → passes `shallPostProcessValidate` |
| final | `finishProcessing:434` | pre-calc **+** calculated-field msgs | real error present → `hasOnlyKnownRecalcIssueErrors` false → `ERROR` (`calculateDeclinedOrErrorStatus:696-706` lets a real error win over a declined msg); no real error → `null` → `OPEN` |

`shallPostProcessValidate` is untouched: the tentative status now makes it return true on its own.

Per the decision taken while planning, the no-reproducible-error case resolves to `OPEN`, which
surfaces an honest `OPEN`-vs-legacy-`ERROR` status deviation instead of a decline that matched legacy
for the wrong reason.

## Change 2 — remove the now-dead legacy-status plumbing

Nothing else reads the legacy return status, so delete it rather than leave it wired:

- `SteuerlicheErmittlungDomainService`: `getLegacyReturnStatus` (331-333).
- `SteuerlicheErmittlungRecalcOptions`: the `legacyReturnStatusSupplier` component + its javadoc line,
  and the `DEFAULT` constant's trailing `null`.
- `RecalculationDomainService`: the `legacyReturnStatusSupplier` parameter of `doRecalc` (451), the
  argument in the options constructor (461), the lambda at the call site (150), and
  `getLegacyStmStatus` (367-379) which then has no caller. `getLegacyStmId` / `stmIdProvider` (131)
  stay — they are a separate mechanism.

## Change 3 — documentation

- `ValidationSetting` javadoc (38-42): the "and the legacy return status was successful" precondition
  is gone. State instead that the flagged code no longer blocks the calculated-field validation, so a
  genuine error found there still decides the status.
- `SteuerlicheErmittlungRecalcOptions` javadoc (12-15): same nuance — a successful status is reached
  only if the calculated-field validation finds nothing.

## Change 4 — regression fixture and tests

New fixture pair next to the existing ones in
`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/`, following
`RecalculationDomainServiceTest_GB00B12WJV48.*` (that test asserts the status directly, which is the
assertion that matters here — `JiraIssueRecalculationTest` only asserts diff counts):

- `RecalculationDomainServiceTest_IE00BD350682.zip` containing, all cut down to that one ISIN:
  - `EY_2026-07-14_120958.csv` — its `START…END` block
  - `EY_2026-07-14_120958_return.csv` — its block, keeping `STATUS;ERROR`
  - `error.log` — the file header (`Meldefile` / `Verarbeitungsbeginn` / `Lieferant`) plus its block
    with the three `ERR_KONTROLL_LSN_LT_0` lines (needed for the log delta report)
- `RecalculationDomainServiceTest_IE00BD350682.yaml.txt` — per-ISIN testdata export carrying the
  already-persisted meldung 683903 that makes `ERR_JAHRESM_VORH` fire (produce it the way the other
  issue fixtures are produced, or by filtering the delivery's `_testdata.yaml.txt`; the source data is
  in the gitignored `issues/quick-recalc/` zip).

Two `@TestTemplate` methods in
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/RecalculationDomainServiceTest.java`,
both `compareCalculatedStmWithLegacyReturnStm(true)`, mirroring the GB00B12WJV48 method:

- flag on (`ValidationSetting.RECALC_ARTIFACT_DIFFS_AS_WARNING`): status `ERROR`, the three
  `ERR_KONTROLL_LSN_LT_0` msgs present, no only-in-legacy error log diffs, and the artifact reported as
  a warning;
- flag off (`ValidationSetting.DEFAULT`): status `NEW_DECLINED` and the three errors absent — this is
  the assertion that pins the gating the flag provides.

Fill the exact diff counts from the first run; assert them explicitly like the existing method does.

## Expected side effects

- Production is unaffected: `CalculationDomainService:105` uses `SteuerlicheErmittlungRecalcOptions.DEFAULT`
  (`recalculationMode=false`, all ignore flags false), and only `RecalculationDomainService:454` builds
  non-default options.
- Flag-off recalc runs are unaffected — `hasOnlyKnownRecalcIssueErrors` returns false when no ignore
  predicate is enabled (`352-354`). `GrossfileRecalculationTest` uses `ValidationSetting.DEFAULT`, so its
  baselines should not move; treat any movement there as a bug in the change.
- Meldungen that newly reach the calculated-field validation also get its warnings/infos
  (`INFO_KONTROLL_1`, `INFO_KONTROLL_9`, `INFO_AUSLQST_JA`, …). Legacy ran those checks too, so matches
  are expected — but `infoKontroll1` does not apply the absolute Kontroll tolerance yet, so some new
  only-in-new warnings are plausible.
- Artifact-only declines that end `OPEN` now emit full return records instead of a status-only block
  (`CsvSteuerMeldungenWriter:120` writes full records for `OPEN`), and show status diffs against a
  legacy failed status — the same shape as the IFAS13-139 note in `JiraIssueRecalculationTest`.
  `JiraIssueRecalculationTest` case `IFAS13-204` (`vorhanden=true`) is the one existing case that can
  shift; update its expected counts if it does.

## Verification

1. `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am -DskipTests`
2. `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm` — unit tests, including
   `CalculatedSteuerMeldungValidatorsTest` and `ValidationDeltaReportsUpdOldmTest`.
3. Local end-to-end on the real delivery: in `QuickRecalculationTest`, drop `@Disabled` on
   `givenSingleLieferungData_…` and set `ISIN_FILTER = List.of("IE00BD350682")`, then check
   `ifas-testing/ifas-integration-tests/target/quick-recalc/`:
   - `EY_2026-07-14_120958_return#recalc.csv` → `STATUS;ERROR` (was `STATUS;NEW_DECLINED;;683903;…`)
   - `error#recalc.log` → the three `ERR_KONTROLL_LSN_LT_0` lines
   - `error#diff.txt` → the three `[-] NUR IM ALTSYSTEM (FEHLER)` entries gone; the
     `[+] NUR IM NEUSYSTEM (WARNUNG)` vorhanden entry unchanged
   Revert both edits afterwards.
4. `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest='RecalculationDomainServiceTest,JiraIssueRecalculationTest,GrossfileRecalculationTest'`
   — new tests green, Grossfile baselines unchanged, IFAS13-204 reviewed.
5. `mvn clean install -Pno-proxy` for the forbiddenapis / full-build gate.
