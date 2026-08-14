# STATUS diffs in `calculatedVsOldReturn` — accepted, baselines adopted

## Context

Four recalculation tests failed on `master`:

```
GrossfileRecalculationTest  [gf1-d20260724] StmDiff: Feld-Fehler  expected: 0 but was: 7
GrossfileRecalculationTest  [gf2-d20260731] StmDiff: Feld-Fehler  expected: 0 but was: 2
GrossfileRecalculationTest  [gf5-d20260810] StmDiff: Feld-Fehler  expected: 0 but was: 1
JiraIssueRecalculationTest  IFAS13-139                            expected: 5 but was: 7
```

`6b0fc0c31` removed the `.filter(stm -> stm instanceof CalculatedSteuerMeldung)` from
`calculatedSteuerMeldungen` (`RecalculationDomainService.java:156`). A meldung the new system
declines is no longer filtered out, so `calculatedSteuerMeldung` is non-null for it and
`RecalculationDiffs.calculatedVsReturnFileDiff:25-35` reaches its non-OPEN branch, comparing the four
STATUS fields with `ONlY_STATUS_FIELDS` / `ALWAYS_ERROR_SEVERITY`. Previously that branch was
unreachable for these meldungen and the method returned `null`.

Every new diff is a `STATUS_*` field; no value field is involved. Verified in
`target/grossfile-recalc/*/recalc-protocol_only_error_details.txt` — gf1 = 2+2+2+1 (`STATUS_STATUS`
vs `NEW_DECLINED` ×3, one `STATUS_MELDUNGS_ID`), gf2 = 2, gf5 = 1 (`STATUS_MELDUNGS_ID_REF`).

Unrelated to the `CsvSchemaType` Lieferformat scoping landed the same day (`676135bf9`): the `STATUS`
record is `SINGLE_ROW_MAP` (`CsvIfasMessageProcessor.java:211`) and never reaches the guard in
`addMultiRowRecordValues` (`:218`).

## Decision

The wider STM coverage from `6b0fc0c31` is intended, and reporting the status mismatch from the
calculated-vs-legacy-return slot as well is correct behaviour. **No production code changes.** The
test baselines were adopted to the new counts.

## Changes (landed)

`ea03920fc` — `GrossfileRecalculationTest.java:204,209,224`, `FieldDiffExpectation` per dataset:

| dataset | field diffs | status diffs (unchanged) |
|---|---|---|
| gf1-d20260724 | `(0, 0)` → `(7, 0)` | `(7, 0)` |
| gf2-d20260731 | `(0, 0)` → `(2, 0)` | `(2, 0)` |
| gf5-d20260810 | `(0, 0)` → `(1, 0)` | `(1, 0)` |

gf3/4/6/7/8 stay `(0, 0)` — no non-OPEN legacy return STM.

`7011df49f` — `JiraIssueRecalculationTest.java:82`, IFAS13-139 expected errors `5` → `7`, plus the
comment above it corrected: the legacy return STM is `FINAL`, so `STATUS_STATUS` and
`STATUS_ANMERKUNG` differ in **all three** compare directions (6) rather than two (4), + the
`ERR_MELDID_FEHLT` log entry only in the new system (1).

## Consequence to be aware of

For a non-OPEN legacy return STM the three slots now report the same mismatch three times — the field
diff and status diff baselines for gf1/gf2/gf5 are identical numbers by construction, and the recalc
protocol prints each mismatch in three blocks:

```
'Neu gerechnete Ergebnisse gegen Altsystem-Return'   STATUS_MELDUNGS_ID_REF: NEU = 649528 / ALT = n.v.
'Neusystem-Return gegen Altsystem-Return'            STATUS_MELDUNGS_ID_REF: NEU = 649528 / ALT = n.v.
'Altsystem-Return gegen Neusystem-Return'            STATUS_MELDUNGS_ID_REF: ALT = n.v. / NEU = 649528
```

So `assertFieldDiffs` (`GrossfileRecalculationTest:126-136`) no longer measures only value
comparisons, despite its comment at `:122-125`. A future value regression on a dataset with declined
meldungen shows up as a delta on top of the status count, not against 0.

`RecalculationDiffs.calculatedVsReturnFileDiff:25-35` remains the only calculated-vs-X builder that
returns a diff instead of `null` when the comparison is meaningless — `calculatedVsWorkbookDiff:47-53`
and `oldReturnVsWorkbookDiff:141-147` return `null`.

## Verification

```bash
mvn -o -q -DskipTests install -pl support-libs/log-support        # HEAD needs MDCs (5891ddd23)
mvn -o -q -DskipTests install -pl ifas-domain/ifas-domain-stm
mvn -o -Pskip-sybase16-tests -pl ifas-testing/ifas-integration-tests test
```

`ifas-domain-stm` 1306 pass; `ifas-integration-tests` 633 pass / 6 skipped (all pre-existing
`@Disabled`, incl. `RecalculationDomainServiceTest.givenOldReturnCsvWithStatusDeclined_whenRecalc_expectNewReturnDeclined`
— the one test that targets this path directly).

Do not use `-am` on `ifas-domain-stm`: it drags in `ifas-libreoffice-recalc-server-container`, whose
podman build fails locally. Sybase testcontainers also fail to start locally
(`Container startup failed for image datagrip/sybase:16.0`), hence `-Pskip-sybase16-tests`.
`-Pno-proxy` does not exist in this reactor — build offline with `-o`.

## Rejected alternative

Returning `null` from the non-OPEN branch of `calculatedVsReturnFileDiff` (aligning it with
`calculatedVsWorkbookDiff`). Implemented and fully verified: all four expectations passed at their
original committed values with no baseline edits, and the duplicate protocol block disappeared while
the two return-vs-return blocks kept the information. Rejected because the calculated-vs-legacy-return
status comparison is wanted as `6b0fc0c31` left it.