# Pin IFAS13-239 (duplicate confirm delivery) in JiraIssueRecalculationTest

## Context

Commit `ebda8d704` ("fix(recalc): gate artifact leniency on the legacy return status") made the four
recalc-artifact leniency flags conditional on the legacy return status: a known artifact error may
only be ignored when legacy itself reported success for that meldung (or reported nothing, because
the bundle carries no `_return.csv`). The trigger was a production delivery where the Lieferant sent
the **same confirm file twice** — legacy finalized on delivery #1 and answered delivery #2 with
`CONFIRM_DECLINED`, while the replay saw the identical DB snapshot (`FINAL`, `guelt_bis` null),
raised the same `ERR_STATUS_NM[FINAL, CONFIRMED]`, and — with `statusNmDiffsAsWarning` on — suppressed
it and reported success where legacy declined.

The commit ships unit tests for the gate itself
(`SteuerlicheErmittlungDomainServiceTest`, 8 cases calling `mayIgnoreRecalcIssueErrors` directly).
What is **not** covered is everything downstream and around it:

- that a blocked gate actually yields `CONFIRM_DECLINED` (not `ERROR`) through
  `calculateDeclinedOrErrorStatus`,
- the wiring `_return.csv` → `LieferungStmKey` → `legacyReturnStatusSupplier` → options
  (`RecalculationDomainService.getLegacyStmStatus` has no test at all),
- that the resulting return file matches legacy, i.e. no `STATUS_*` diffs.

The fixture for that end-to-end case is already staged but unreferenced:
`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/issues/IFAS13-239/`
(confirm CSV `STATUS;CONFIRMED;697058`, legacy return `STATUS;CONFIRM_DECLINED;697058`, legacy
`error.log` with `Aktueller Status <FINAL>, CONFIRMED nicht moeglich.`, plus a one-ISIN DB export in
which meldung 697058 is `FIN` with no `gueltBis`). No `@CsvSource` row loads it yet.

Outcome: an `IFAS13-239` row in `JiraIssueRecalculationTest` that fails if the gate is removed.

## Why the test needs widening first

`JiraIssueRecalculationTest` only exposes two of the four `ValidationSetting` flags and hard-codes
`statusNmDiffsAsWarning = false` (`JiraIssueRecalculationTest.java:127-136`). With that flag off,
`hasOnlyKnownRecalcIssueErrors` short-circuits on `known.isEmpty()`
(`SteuerlicheErmittlungDomainService.java:345-347`) and the gate is never reached — the row would
pass with or without the fix. The row must run with the leniency **on**, which is also the real-world
configuration (`RecalculationRestController` and the single UI checkbox set
`ValidationSetting.RECALC_ARTIFACT_DIFFS_AS_WARNING`, all four flags true).

## Step 1 — trim the DB export fixture

`IFAS13-239/fonds-export_20260826_152829.yaml` is 13.17 MB against ~1 MB for the other issue
fixtures, and it is imported into H2 on every run. Byte share:

| entity | entries | size | share |
|---|---|---|---|
| `STEUER_FIELDS_DATA` | 85 154 | 7.03 MB | 53.4 % |
| `STEUER_BEH_DATA` | 17 244 | 2.88 MB | 21.9 % |
| `STEUER_FIELD` | 4 120 | 2.41 MB | 18.3 % |
| `STEUER_BEH_FIELD` | 802 | 0.63 MB | 4.8 % |
| everything else | 435 | 0.22 MB | 1.6 % |

Write a throwaway Python script in the scratchpad (not `sed`) that streams the file, splits on
`^- !<TYPE>` blocks and copies kept blocks **byte-exact**, preserving original order (the importer
depends on it for FK order) and the `# ===== TYPE =====` section comments:

- `STEUER_FIELDS_DATA` / `STEUER_BEH_DATA` — keep only rows whose `stmId` belongs to a
  `STEUER_MELDUNG` of the current Geschäftsjahr (`gjEnde: "2026-09-30"`), which includes 697058.
- `STEUER_FIELD` / `STEUER_BEH_FIELD` — keep only `version: 6` (the version resolved for Stichtag
  2026-08-24; the existing fixtures likewise carry a single version, e.g. IFAS13-204 with 1073
  `STEUER_FIELD` rows).
- everything else — keep unchanged, including all 135 `STEUER_MELDUNG` rows (0.10 MB) and the 6
  `STEUER_MELDUNG_VERSION` rows.

Expected result ≈ 1 MB. Overwrite the file under its current name (`.yaml` is recognised as
`TESTDATA_YAML_FILE` at `SteuerMeldungBundles.java:690`, no `.yaml.txt` rename needed) and re-`git
add` it. Assert in the script that meldung 697058 survives with `status: "FIN"` and no `gueltBis`.

If the trimmed run no longer reproduces (see Step 4), widen in this order: field data for all
meldungen of the same `numWfsKu`, then `STEUER_FIELD` versions 5+6, then all versions.

Also `chmod 644` the six fixture files — they are currently `600`, unlike every other fixture.

## Step 2 — widen the test parameters

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/JiraIssueRecalculationTest.java`

Signature becomes (all four flags, plus the expected return status):

```java
void givenJiraIssue_whenRecalculate_thenExpectGivenNumberOfErrorsAndWarnings(
        String jiraIssue,
        int bmfVersion,
        LocalDate stichtag,
        int expectedNumberOfErrors,
        int expectedNumberOfWarnings,
        boolean vorhandenDiffsAsWarning,
        boolean meldIdNichtMehrGueltigDiffsAsWarning,
        boolean statusNmDiffsAsWarning,
        boolean updOldmDiffsAsWarning,
        String expectedReturnStatus
)
```

Two constraints imposed by the custom test-template provider
(`support-libs/core-test-support/.../MultipleApplicationContextsProvider.java`), which re-implements
`@CsvSource` handling rather than delegating to JUnit:

- **`null` arguments are unresolvable** — `supportsParameter` (`:365-372`) requires
  `args[index] != null`. So the two `@Nullable Boolean` parameters become plain `boolean` (the
  `!= null` branch at `:129-136` is dead code today: every row passes a literal, and
  `new ValidationSetting(false, false, false, false)` equals `ValidationSetting.DEFAULT`).
- **`convertValue` (`:293-317`) has no enum branch** — an `StmStatus` parameter would arrive as a
  `String` and fail `isTypeCompatible`. So the new column is a `String`, with the sentinel `-`
  meaning "status not asserted" (an empty column would become `null` and hit the first constraint).

Build the setting unconditionally:

```java
.validationSetting(new ValidationSetting(
        vorhandenDiffsAsWarning,
        meldIdNichtMehrGueltigDiffsAsWarning,
        statusNmDiffsAsWarning,
        updOldmDiffsAsWarning
))
```

Assertion block:

```java
// then assert error and warning count
assertThat(result.countErrorDiffs()).isEqualTo(expectedNumberOfErrors);
assertThat(result.countWarningDiffs()).isEqualTo(expectedNumberOfWarnings);

if (!NO_RETURN_STATUS_CHECK.equals(expectedReturnStatus)) {
    assertThat(result.steuerMeldungRecalculations()).hasSize(1);
    SteuerMeldung newReturn = result.steuerMeldungRecalculations().getFirst().newReturnSteuerMeldung();
    assertThat(newReturn).isNotNull();
    assertThat(newReturn.getStatus()).isEqualTo(StmStatus.valueOf(expectedReturnStatus));
}
```

(`newReturnSteuerMeldung` is exactly what is written to the recalc return CSV and compared against
the legacy return; `RecalculationDomainServiceTest:93` uses the sibling
`ergebnis().returnSteuerMeldungen()` accessor if that turns out to read better.)

Existing rows gain `,false,false,-`; the new row:

```java
// IFAS13-239: the same confirm file was delivered twice. Legacy finalized meldung 697058 on the
// first delivery and answered the second with CONFIRM_DECLINED. Finalization updates the row in
// place and leaves guelt_bis null, so the replay sees FINAL and raises the same
// ERR_STATUS_NM[FINAL, CONFIRMED] a genuine replay artifact would raise. The leniency flags are all
// on here, so only the failed legacy return status keeps the meldung from reaching a successful
// status - see SteuerlicheErmittlungDomainService#mayIgnoreRecalcIssueErrors.
"IFAS13-239,0,2026-08-24,0,0,true,true,true,true,CONFIRM_DECLINED",
```

Stichtag 2026-08-24 (the Lieferung date), BMF-Version `0` = AUTO (the legacy protocol reports
`Vorgegebene BMF-Version: AUTO`; meldung 697058 is `versionsNr: 6`).

## Step 3 — expected counts

Predicted **0 errors / 0 warnings**:

- the legacy `error.log` line and the new system's `ERR_STATUS_NM` carry identical text and args
  (`ValidationMsgCode.java:36`), so the delta is an `EXACT` match and is filtered out
  (`ValidationDeltaReports.java:161`);
- both return files say `CONFIRM_DECLINED`, and legacy writes no Anmerkung for this decline —
  confirmed against gf2/gf3, whose legacy returns contain bare `STATUS;CONFIRM_DECLINED;<id>` rows
  and whose `GrossfileRecalculationTest` baselines expect 0 status diffs, i.e. the new system
  suppresses the Anmerkung in the same case.

Run it and use the observed numbers. If they are not 0/0, keep the actuals and extend the row
comment with the reason, the way the IFAS13-139 row documents its 7 diffs.

## Step 4 — verification

1. `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=JiraIssueRecalculationTest`
   — all 7 rows green.
2. **Does the row actually pin the fix?** Temporarily neuter the gate in the working tree —
   delete the `legacyReturnStatus` check at `SteuerlicheErmittlungDomainService.java:317-320` — and
   re-run: the IFAS13-239 row must fail (the meldung keeps its tentative `FINAL`, producing
   `STATUS_STATUS` diffs across the three compare directions). Restore with
   `git checkout -- <file>` afterwards. Without this check the row proves nothing.
3. **Is the trimmed export still the right reproduction?** In the failing run of (2), or via the
   protocol logged by the test, confirm the new system raises
   `Aktueller Status <FINAL>, CONFIRMED nicht moeglich.` — **not**
   `Die Meldung mit der Melde-ID <697058> ist nicht vorhanden.`, which is what the earlier TEST-system
   run produced when the export was empty and which would mean the meldung is missing from the
   trimmed fixture.
4. Regression: `mvn test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`
   and `-Dtest=RecalculationDomainServiceTest` — both unchanged (the grossfile baselines run with
   `ValidationSetting.DEFAULT`, so the gate cannot reach them).
5. `git status` — only the intended files: the trimmed export plus the test. The untracked
   `issues/temp/` scratch folder stays out of the commit (it would fit the "do not commit adhoc
   testdata files" block in `.gitignore:812-816`, but that is a separate decision).

## Files

| File | Change |
|---|---|
| `ifas-testing/.../resources/at/oekb/ifas/domain/recalc/issues/IFAS13-239/fonds-export_20260826_152829.yaml` | trimmed from 13.17 MB to ~1 MB |
| `ifas-testing/.../test/java/at/oekb/ifas/domain/stm/recalc/JiraIssueRecalculationTest.java` | four flag columns + expected-return-status column; IFAS13-239 row |

No production code changes.
