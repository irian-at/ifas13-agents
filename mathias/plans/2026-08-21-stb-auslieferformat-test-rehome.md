# Re-home STB test coverage onto the Auslieferformat

## Context

The `STB` (Steuerliche Behandlung) record was removed from
`STM_LIEFERFORMAT_2022-04-03.csv-schema.yml` in the working tree, because STB is a *calculated*
result and only ever appears in the Auslieferformat (the return file), never in a Lieferant
delivery. The domain already agrees with that reading: `StmStatusValidationRules:34-36` excludes
`FieldCategory.STEUERLICHE_BEHANDLUNG` from validation for the `NEW`/`NEW_DECLINED` input
statuses, `SteuerMeldungErmittlungsvorgabeValidators:83` notes "STB Vectors are calculated and do
not need validation", and `CsvIfasStructureValidationRules:36` already forbids `STB` for
`NEW`/`UPDATE`.

Three test fixtures, however, are Lieferformat *input* files that carry two `STB;` rows. Since
`CsvIfasMessageProcessor.getRecordSchemaOrHandleError` (line 124) resolves the record schema before
any structure rule runs, those rows now produce `UNKNOWN_RECORD_TYPE` and are dropped, which breaks:

- `CsvSteuerMeldungenRoundTripTest.givenCsvFileWithDashDates_whenLoad_thenParsedWithoutValidationErrors:146`
  — `assertThat(loaded.validationMsgs()).isEmpty()` now sees 2 × `UNKNOWN_RECORD_TYPE`.
- `CsvSteuerMeldungenTest.givenStmFile_whenLoad_thenSuccess:137` — `getFieldValue("StB_…",
  StbVector.class)` returns `null`, so the `getAmount(...)` call NPEs.

**Reading the Auslieferformat needs no production change.** It is already wired end to end:
`CsvSteuerMeldungen.loadReturnFromCsv:62` → `CsvSchemaType.STM_AUSLIEFERFORMAT` →
`CsvIfasSchemas.getAuslieferformatSchema:30`, and `CsvSteuerMeldung.extractStbVector:131` already
handles the Auslieferformat-only `CODE_NUM` and `*_NK8` columns (its Javadoc at lines 121-129
documents exactly that map shape). The intended outcome is therefore purely fixture and test
re-homing: input fixtures become STB-free, and STB coverage moves onto a real Auslieferformat
fixture read through `loadReturnFromCsv`.

## Changes

### 1. Strip STB from the Lieferformat fixtures

Delete the two `STB;` lines (lines 57-58 in each) from:

- `ifas-domain/ifas-domain-stm/src/test/resources/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenTest.csv`
- `.../csv/CsvSteuerMeldungenDashDatesTest.csv`
- `.../csv/CsvSteuerMeldungenInvalidValueTest.csv`
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidationsTest_01.csv`
  (`STATUS;NEW` — its STB rows were already structurally disallowed by
  `CsvIfasStructureValidationRules:36`; the test only logs, so it does not currently fail, but the
  fixture is now also schema-invalid)

Change nothing else in these files — in particular leave `STATUS;OPEN` alone, since
`CsvSteuerMeldungenTest:81` asserts `StmStatus.OPEN`.

### 2. New Auslieferformat fixture

`ifas-domain/ifas-domain-stm/src/test/resources/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenAuslieferformatTest.csv`

Shape it like a real return file, i.e. like what `CsvSteuerMeldungenWriter` emits with
`erweitert = true`:

- `START` / `STATUS;OPEN` / `EA` / `END` as in `CsvSteuerMeldungenTest.csv` (the two schemas are
  identical for those records).
- `E` rows extended to `E;<CODE>;<BETRAG>;<CODE_NUM>;<BETRAG_JE_ANTEIL>`; `D`/`Z` rows extended to
  `<record>;<CODE>;<BETRAG>;<LAENDERCODE>;<CODE_NUM>;<BETRAG_JE_ANTEIL>` — the Auslieferformat-only
  columns (`STM_AUSLIEFERFORMAT_2022-04-03.csv-schema.yml`, `colIdx 3/4` for `E`, `colIdx 4/5` for
  `D`/`Z`/`ZA`/`AS`).
- `STB` rows in both writer shapes, so the reader's leniency for the optional trailing columns is
  covered:
  - one 9-column row: `CODE` + 6 scale-4 amounts + `CODE_NUM` (non-`erweitert` output, see
    `CsvSteuerMeldungenWriter.writeStbVectorRows:311`)
  - one 15-column row: the same plus the 6 `*_NK8` scale-8 amounts (`erweitert` output)
- Reuse the existing STB field names `StB_KESt_Ertraege_Immobilienfonds` and
  `StB_AnrechenbarePersonensteuerausl_Immobilienertraege`, and keep the existing values so the
  assertions move over verbatim. Per `testing-conventions.md` prefer distinct digits for the new
  `_NK8` and `BETRAG_JE_ANTEIL` values.
- Keep at least one `.`-decimal and one `,`-decimal amount, mirroring the current fixture's mix.
- ISO-8859-1 (`IfasCharsets.IFAS_CSV_CHARSET`) — the content is ASCII, so this only matters if a
  non-ASCII fund name is copied over.

### 3. Move the STB assertions

`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenTest.java`

- Remove the two `StbVector` blocks (lines 133-155) from `givenStmFile_whenLoad_thenSuccess`.
- Add `givenAuslieferformatFile_whenLoadReturn_thenStbVectorsParsed`, which loads the new fixture
  via `CsvSteuerMeldungen.loadReturnFromCsv(resource, MOCK_STEUER_MELDUNG_DEFINITION_PROVIDER,
  LocalDates.nowInVienna(), null, false)` and re-asserts the moved STB values with the existing
  `ofDefaultScale` helper. Also assert that a `CODE_NUM`-carrying `E` row and a `D` row still
  resolve (`getFieldValue(..., BigDecimal.class)` / `CountryVector.class`), which is what proves the
  extra Auslieferformat columns do not disturb the reader.
- `loadReturnFromCsv` does not surface validations, but the `CsvFile` is reachable —
  `meldung.getCsvMessage().getCsvFile().getValidationMsgs()` plus
  `meldung.getCsvMessage().getValidationMsgs()` — so assert both are empty rather than adding a
  production entry point.

### 4. Re-enable the round trip against the Auslieferformat

`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenRoundTripTest.java`

- Drop the `@Disabled` and the `org.junit.jupiter.api.Disabled` import added in the working tree.
- Re-seed `givenCsvFile_whenReadWriteRead_thenDataMatchesOriginal` from the new Auslieferformat
  fixture via `loadReturnFromCsv`, so both legs of the trip use the same format:
  `loadReturnFromCsv` → `new CsvSteuerMeldungenWriter(out, STICHTAG).writeReturnSteuerMeldungenToCsv`
  → `loadReturnFromCsv`. That makes `assertStbFields` (line 322) meaningful again and lets the
  `//todo` at line 63 go.
- Note two behaviours the write leg depends on: `internalWriteSteuerMeldungenToCsv:104` only writes
  a *full* meldung when `getStatus() == OPEN` (hence `STATUS;OPEN` in the fixture), and the
  two-arg `CsvSteuerMeldungenWriter` constructor sets `erweitert = true`, so it emits the 15-column
  STB rows. Field enumeration comes from the `Ermittlungsvorgabe`, and this test's
  `FixedNumCodeErmittlungsvorgabe(5, 99999)` wraps the real v5 vorgabe, so the `StB_*` names must
  exist there — confirm when running, and fall back to a name that does if either is absent.
- `assertStartRecordFields:199-201` pins `LU2023678449` / `Art.InvF` / `Ertragstyp.T`, so keep the
  new fixture's `START` record on those values.
- The other three tests in this class keep using the Lieferformat fixtures and are unaffected once
  the STB rows are gone.

## Explicitly not changed

- `CsvIfasStructureValidationRules:57-58` keeps `STB` allowed (and in sequence) for
  `OPEN`/`ERROR`/`DELETED`/`FINAL`. The structure rules are schema-independent and run on both read
  paths, so those entries are exactly what an Auslieferformat read needs — they are not stale.
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenRoundTripTest.csv`
  is referenced by no Java file (an orphaned copy). Left alone; deleting it is a separate call.
- All `*_return.csv` fixtures under `ifas-testing/ifas-test-data/.../stm/`,
  `.../recalc/issues/IFAS13-134`, `IFAS13-144` and `docs/Testdaten Fachabteilung/` already go
  through `loadReturnFromCsv`, so they are unaffected.

## Verification

```bash
# the two originally failing tests plus the whole csv package
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
  -Dtest='CsvSteuerMeldungenTest,CsvSteuerMeldungenRoundTripTest,CsvIfasValidationTest,CsvIfasStructureValidationRulesTest,CsvSteuerMeldungRecordWriterTest'

# full module, then the integration test whose fixture was touched
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests \
  -Dtest='SteuerMeldungErmittlungsvorgabeValidationServiceTest' -Pskip-postgres15-tests -Pskip-sybase16-tests
```

Expected: `givenCsvFileWithDashDates_whenLoad_thenParsedWithoutValidationErrors` goes back to an
empty `validationMsgs()`, `givenStmFile_whenLoad_thenSuccess` passes with the STB block removed, the
new Auslieferformat test asserts the same STB amounts through `loadReturnFromCsv`, and the
un-`@Disabled` round trip passes including `assertStbFields`.

Since STB parsing is exercised in the recalc/diff paths too, finish with the broader STM suites
(`mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Pskip-postgres15-tests
-Pskip-sybase16-tests`) to confirm no return-file reader regressed.
