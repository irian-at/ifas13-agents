# Tolerate a *missing* new-return country vector against legacy's all-zero vector

## Context

gf1's `newReturnVsOldReturn` comparison reports large blocks of `FEHLER` field diffs of the form

```
AS_Ausschuettungen_Subfonds_jeAnteil: NEU = n.v. / ALT = [DE=0.0000]
```

(e.g. 135 for STM #3 / `LU0292585626`, ~10783 across gf1 — see
`automemory/project_gf1-fielddiff-null-vs-zero.md`).

These are a **representation** difference, not a calculation difference:

1. The new system drops zero-valued country entries for countries not reported in that field's
   category — `SteuerMeldungPostProcessing.removeNonReportedCountriesFromCountryVectors` →
   `CountryVector.filterZeroValuesForCountries` (`CountryVector.java:165`). If *every* entry drops,
   the value becomes an `EmptyCountryVector`, the return CSV writes no `E;…` line at all, and the
   round-trip re-read (`RecalculationDomainService.getReloadedRecalcReturnSteuerMeldungen:419-438`)
   yields **`null`** → rendered `n.v.` (`Deltas.java:74-76`; an `EmptyCountryVector` would render
   `[]`, so `n.v.` is unambiguously null).
2. Legacy wrote `DE=0.0000` because it over-cumulates the "countries to be reported" flags across the
   STMs of one delivery — documented at `RecalculationDomainService.java:318-321`.

`KnownLegacySystemIssues.tolerateWronglyReportedZeroValueCountryCodes` (`:150-175`) exists precisely
for (2) and its country set *is* populated
(`RecalculationDomainService.determineToleratedWronglyReportedZeroCountryVectors:322-339` — each STM
gets the countries cumulated from the **preceding** STMs of the legacy return file). But it is
unreachable for this case because of its own guard:

```java
if (legacyReturnValue instanceof CountryVector<?> legacyReturnCv
        && newReturnValue instanceof CountryVector<?> newReturnCv) {
```

`newReturnValue` is `null` after the round-trip → guard fails → falls through to
`FieldDiffSeverity.ERROR`. The tolerance therefore only ever helps when the new vector still exists
and merely lacks *some* of legacy's zero countries.

**Goal:** treat a missing new-return value as an empty country vector inside that guard, so the
existing zero-and-tolerated-country checks can do their job.

### Non-goals

- Do **not** flip `actualMissingValueEqualsExpectedZero` /
  `actualMissingVectorEntryEqualsExpectedZeroVectorEntry` on
  `StmDiffConfigs.EXPECTED_OLD_RETURN_FILE_VALUES_VS_ACTUAL_NEW_RETURN_FILE_VALUES` — that config is
  deliberately strict ("strict comparing of empty vs. all-zero country vectors", `:91-96`) and
  flipping it would also hide genuine cases where the new system dropped a **non-zero** value.
- Do not touch the reciprocal "legacy missing / new has values" direction (the ~368
  `oldReturnVsNewReturn` diffs). Different case, different judgement.
- Do not change what the return CSV writer emits. Whether the new system should write explicit zeros
  like legacy is a Fachabteilung/format question.

## Change

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/diff/KnownLegacySystemIssues.java`

Replace the `newReturnValue instanceof …` half of the guard (`:158-163`) with a normalised
country-code set:

```java
    public static FieldDiffSeverity tolerateWronglyReportedZeroValueCountryCodes(
            FieldSpec fieldSpec,
            @Nullable Object legacyReturnValue,
            @Nullable Object newReturnValue,
            @Nullable Set<String> possiblyWronglyReportedCountryCodes
    ) {
        if (possiblyWronglyReportedCountryCodes != null) {
            if (CountryVector.class.isAssignableFrom(fieldSpec.javaType())) {
                // new return CSV omits zero country entries, so an all-zero vector disappears from the
                // file entirely and reads back as missing — equivalent to an empty vector here
                if (legacyReturnValue instanceof CountryVector<?> legacyReturnCv
                        && (newReturnValue == null || newReturnValue instanceof CountryVector<?>)) {
                    Set<String> newReturnCountryCodes = newReturnValue instanceof CountryVector<?> newReturnCv
                            ? newReturnCv.getCountryCodes().collect(Collectors.toSet())
                            : Set.of();
                    // determine all CC in legacyReturnCv but not in the new return
                    Set<String> diffCountryCodes = legacyReturnCv.getCountryCodes().collect(Collectors.toCollection(
                            HashSet::new));
                    diffCountryCodes.removeAll(newReturnCountryCodes);
                    // are all remaining CC values in legacyReturnCv zero?
                    if (diffCountryCodes.stream().allMatch(cc -> Numbers.isZero(legacyReturnCv.getValue(cc)))) {
                        // are all CC values in legacyReturnCv possibly wrongly reported CCs?
                        if (possiblyWronglyReportedCountryCodes.containsAll(diffCountryCodes)) {
                            return FieldDiffSeverity.WARNING;
                        }
                    }
                }
            }
        }
        return FieldDiffSeverity.ERROR;
    }
```

Only two things change: the second half of the guard, and `diffCountryCodes.removeAll(...)` now takes
the normalised set. The zero check and the tolerated-country check are untouched — a legacy value that
is **non-zero** still fails `allMatch(Numbers.isZero)` and stays `ERROR`, which is what keeps this
safe.

Add `@Nullable` to the two value parameters: `FieldDiffSeverityCalculator` already declares
`@Nullable Object expectedValue` / `@Nullable Object actualValue` (`FieldDiffSeverityCalculator.java:13-19`),
so nulls were always contractually possible — the signature just didn't say so. `@Nullable` is
already imported in the file. (The class itself is not `@NullMarked`; leaving that as-is keeps the
diff to the point.)

No other call site exists — `RecalculationDiffs.java:82-90` and `:120-128` are the only two, and both
already pass values that can be null.

## Why this reaches the diffs at all

- `StmDiffs.calcDiffs:114-126` calls `config.diffSeverityCalculator().determineSeverity(...)` for
  **every** non-equal field, nulls included. The severity calculator is not skipped for missing values.
- `FieldDiffSeverityCalculator.combineWith` returns the **lowest** severity, and
  `enum FieldDiffSeverity { WARNING, ERROR }` puts `WARNING` first — so a `WARNING` from this lambda
  wins over the `ERROR` from `KNOWN_OLD_RETURN_FILE_ISSUES` et al.

## Expected effect on existing baselines: none

- `GrossfileRecalculationTest.assertFieldDiffs` counts only `calculatedVsOldReturn` (`:132-142`),
  which does not use this lambda → all 8 grossfiles stay `FieldDiffExpectation(0, 0)`.
- `assertStatusDiffs` counts `newReturnVsOldReturn` diffs whose field name starts with `STATUS`
  (`:148-168`). `STATUS_*` fields are not country vectors, so
  `CountryVector.class.isAssignableFrom(fieldSpec.javaType())` is `false` and their severity is
  untouched → gf1 stays `(7, 0)`.
- `RecalculationDomainServiceTest:96-97` asserts `countErrorFieldDiffs() == 4` /
  `countWarningFieldDiffs() == 0` for `GB00B12WJV48`. That STM has status `ERROR`, so
  `newReturnVsOldReturnDiff` takes the `status != OPEN` branch (`RecalculationDiffs.java:65-77`) which
  uses `ONlY_STATUS_FIELDS` **without** the lambda → unaffected. Run it to confirm.

What *does* change is the protocol: the affected diffs move from `FEHLER` to `WARNUNG`, so
`recalc-protocol_only_error_and_warning_details.txt` lists them under the warning heading and
`BundleRecalculationResult.countErrorFieldDiffs()` drops sharply (that aggregate is not asserted for
the grossfiles — see the comment at `GrossfileRecalculationTest.java:122-125`).

Note this is a *partial* reduction, not a guarantee of zero: a field only flips if **all** of its
legacy-only country codes are in that STM's tolerated set (the countries reported by preceding STMs).
A legacy zero for a country nobody reported earlier in the file stays `FEHLER` — correctly, since it
is then not explained by the cumulation bug.

## Test

New unit test (no Spring, no DB):
`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/recalc/diff/KnownLegacySystemIssuesTest.java`

The method is `public static`, so it can be called directly. Get a real `FieldSpec` the way other unit
tests in this module do — `Ermittlungsvorgaben.getErmittlungsvorgabe(6)` (Excel-backed, static; cf.
`SteuerMeldungErmittlungsvorgabeValidatorsTest.java:39`) then
`getFieldSpecByName("AS_Ausschuettungen_Subfonds_jeAnteil")` — rather than hand-building the 25-component
record. Vectors via `new DefaultCountryVector<>(BigDecimal.class, Map.of(...))` /
`new EmptyCountryVector<>(BigDecimal.class)`.

Cases (given-when-then names, AssertJ):

| case | legacy | new | tolerated CCs | expected |
|---|---|---|---|---|
| the fix | `[DE=0.0000]` | `null` | `{DE}` | `WARNING` |
| regression guard | `[DE=1234.5679]` | `null` | `{DE}` | `ERROR` |
| untolerated country | `[DE=0.0000]` | `null` | `{FR}` | `ERROR` |
| mixed vector, zero-only gap | `[DE=0.0000, FR=1234.5679]` | `[FR=1234.5679]` | `{DE}` | `WARNING` (pre-existing behaviour, must not regress) |
| no tolerated set | `[DE=0.0000]` | `null` | `null` | `ERROR` |
| non-vector field | any scalar field spec | `null` | `{DE}` | `ERROR` |

## Verification

```bash
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=KnownLegacySystemIssuesTest
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=RecalculationDomainServiceTest
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest
```

Then inspect
`ifas-testing/ifas-integration-tests/target/grossfile-recalc/gf1-d20260724/recalc-protocol_only_error_and_warning_details.txt`
for STM #3 / `LU0292585626`: the `AS_*` block should appear under `WARNUNG` instead of
`135 Differenzen der Kategorie 'FEHLER'`. All six `GrossfileRecalculationTest` baseline counters must
be unchanged for every grossfile.
