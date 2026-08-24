# Guard MULTI_ROW_MAP records with an unfilled key column

## Context

`QuickRecalculationTest` crashes on the EY bundle (`20260717_092107_EY_2026-07-17_074545.zip`) with

```
IllegalStateException: Cannot extract value of type ...CountryVector for field Z_Ertragsausgleich_Zinsen_Direktanlage_e
Caused by: ClassCastException: SimpleRecordValue cannot be cast to MapRecordValue
        at CsvSteuerMeldung.extractCountryVectorMapValues(CsvSteuerMeldung.java:181)
```

Trigger is line 53 of the Melde-CSV:

```
Z;Z_Ertragsausgleich_Zinsen_Direktanlage_e;-13377,5;;Y3
```

The LAENDERCODE column (colIdx 3) is empty and `Y3` slid into a 5th column. Legacy rejects the row
twice (`error.log`: *"Ungueltige Anzahl <5> von Parametern in Datensatz <Z>"*, *"Das Pflichtfeld
<Code fuer Land> im Satz <Z> ist nicht befuellt"*) and does not process the Meldung at all
(*"3 von 4 verarbeitet"*).

The new system emits both errors correctly, but then keeps writing the row's value:
`toRecordKeyPath` (`CsvIfasMessageProcessor.java:624`) **drops** the empty key column, so the path
collapses from `[field, Y3]` to `[field]`, and the value loop stores `[field, BETRAG]`. The Meldung's
data map then holds `field -> MapRecordValue{BETRAG -> SimpleRecordValue}` — a country record
**without its country level**. Any later read of the CountryVector casts that `BETRAG` child to
`MapRecordValue` and blows up.

This is a latent bug, not a regression from a recent commit (the dropping behaviour is from Nov 2025,
the cast from Aug–Nov 2025); it was simply never hit because no fixture had an *empty* LAENDERCODE.
The sibling case — LAENDERCODE present but holding a non-country value — was already handled in
`getCountryCodesWithInvalidValue` (`CsvSteuerMeldung.java:110`), and `collidesWithSimpleField`
(`CsvIfasMessageProcessor.java:503`) documents the same ClassCastException family.

Goal: stop the malformed shape at the parser, mirroring legacy ("row not processed"), while keeping
the row addressable for validation messages.

## Change

### `ifas-domain/ifas-domain-stm/.../meldung/csv/CsvIfasMessageProcessor.java`

In `addMultiRowRecordValues`, after `validateKeyColumnValues(...)` and after the existing
`collidesWithSimpleField(...)` guard (so both keep emitting their errors first), skip the value loop
when a key column of the record is unfilled:

```java
CsvColumnSchema unfilledKeyColumn = findUnfilledKeyColumn(recordSchema, record);
if (unfilledKeyColumn != null) {
    // A dropped key column collapses the path: a country record's BETRAG would land directly
    // under the field, where CsvSteuerMeldung.extractCountryVector expects the country level
    // (ClassCastException). Legacy does not process such a row either — c_st_meldung.cpp rejects
    // the whole Meldung. The MISSING_FIELD/MISSING_PARAMETERS errors are already recorded above;
    // only the row position is kept, so validators can still name this line.
    csvMessage.recordRowPosition(
            recordKeyPath,
            CsvMessagePosition.of(
                    csvMessage,
                    recordSchema.getCode(),
                    lineNumber,
                    unfilledKeyColumn.getColIdx(),
                    record,
                    resolveFieldNameForMissingField(record, recordSchema, unfilledKeyColumn)
            )
    );
    return;
}
```

New private helper next to `getKeyValue`, reusing it so "unfilled" means exactly what
`toRecordKeyPath` drops (column absent **or** present but empty):

```java
private @Nullable CsvColumnSchema findUnfilledKeyColumn(CsvRecordSchema recordSchema, CSVRecord record) {
    for (CsvColumnSchema keySchema : recordSchema.getKey()) {
        if (getKeyValue(keySchema, record) == null) {
            return keySchema;
        }
    }
    return null;
}
```

Also extend the `toRecordKeyPath` javadoc ("dropped, not padded") with one line stating that the
caller now skips such a record.

Notes on blast radius:

- Single-key MULTI_ROW_MAP records (E) are unaffected: an unfilled CODE yields an empty path, which
  the existing `recordKeyPath.isEmpty()` guard already returns on. The new guard can therefore only
  fire for the two-key country records (D, Z, ZA, AS) — exactly the rows that today produce data that
  crashes on read. All `key:` columns in all four schema YAMLs are `required: true`, so no legitimate
  partial key exists.
- Same processor parses the return format (`STM_AUSLIEFERFORMAT_2022-04-03`), so legacy return files
  get the same treatment — again only for rows that were unreadable before.

### `rowPositionsByPath` — explicitly preserved

`recordRowPosition` is otherwise only called from `CsvMessage.addMapRecordValue`, so an early return
would drop the row from `rowPositionsByPath` as well and `getPosition(field)` would fall back to the
Meldung's START line. The guard therefore records the row itself — this is what
`CsvMessage.recordRowPosition` is documented for ("a required column that was missing"), and what
`CsvMessageTest.givenFieldWithoutValueButRecordedRow_whenGetPosition_thenReturnsThatRow` locks in.

Recorded path is the collapsed `[field]` (instead of today's `[field, BETRAG]`); both satisfy
`startsWith(field)`, so `getRowPositions(field, null)` / `getPosition(field)` /
`CsvSteuerMeldung.getFieldPositions(field, null)` keep returning line 53. A country-qualified lookup
(`getRowPositions(field, "Y3")`) does not match — correct, the row never named a country.

## Tests

1. `ifas-domain-stm` — `CsvIfasValidationTest`: extend the existing
   `givenCountryRecordsWithEmptyLaendercode_whenValidate_thenMissingFieldNamesCodeFuerLand` fixture
   (`missing_laendercode_validation.csv` already has D/Z/ZA/AS rows with an empty LAENDERCODE) with a
   new test asserting, for `D_Dividenden_Direktanlage_e`:
   - `csvMessage.getRecordValue(field)` is `null` — nothing malformed landed in `data`
   - `csvMessage.getRowPositions(field, null)` still names line 5, and
     `csvMessage.getPosition(field).issueLineNumber()` is 5
   - the 5 `MISSING_FIELD` errors of the existing test are unchanged
2. `ifas-domain-stm` — `SteuerMeldungErmittlungsvorgabeValidatorsTest` (nested class holding the
   misaligned-row cases, `createCsvSteuerMeldungWithCountryVectorEntry` helper): add a case that
   parses a country record with an empty LAENDERCODE and asserts
   `validateInputField(...)` returns normally (no `IllegalStateException`) and the CountryVector reads
   as `null`. Build it through `CsvSteuerMeldungen.loadAndValidateInputFromCsv` (or the existing
   fixture-loading helper) rather than hand-built `RecordKeyPath`s, so the regression is anchored on
   real parsing.

## Verification

```bash
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
  -Dtest='CsvIfasValidationTest,CsvToValidationMsgCodeTest,SteuerMeldungErmittlungsvorgabeValidatorsTest,CsvSteuerMeldungen*Test'
mvn test -Pno-proxy -pl support-libs/csv-schema           # CsvMessageTest (rowPositionsByPath contract)
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm       # whole module, watch for fixtures that relied on the malformed shape
```

End to end: re-run `QuickRecalculationTest#givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
from the IDE (it is `@Disabled`; STICHTAG is already 2026-07-14 for this bundle). Expected:

- no `Cannot extract value of type ...CountryVector` exception
- protocol for LU3152347608 reports the too-many-parameters error and the unfilled "Code fuer Land"
  on line 53, and the Meldung is not accepted — matching legacy's `error.log` / *"3 von 4 verarbeitet"*
- the three other ISINs are unchanged

The `No Inv found for ISIN ... at stichtag 2026-07-14` WARN stays: the bundle ships no testdata YAML,
so no `Inv` rows exist for any of its ISINs. It is caught in
`SteuerMeldungLieferungService.ensureCalculatedGeschaeftsjahre` and only means Geschäftsjahre are not
pre-calculated — out of scope here.

## Not included

`CsvSteuerMeldung.extractCountryVectorMapValues` keeps its hard cast. With the guard in place the
parser can no longer produce a country-record slot without a country level, so the cast is
unreachable from parsing; adding a defensive `instanceof` skip there (mirroring
`getCountryCodesWithInvalidValue`) is a separate, optional hardening step.
