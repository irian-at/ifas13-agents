# Version-aware field emission in `CsvSteuerMeldungenWriter`

## Context

`CsvSteuerMeldungenWriter` (`ifas-domain-stm/.../meldung/csv/CsvSteuerMeldungenWriter.java`) serializes
`SteuerMeldung` objects to CSV in four modes (`RETURN`, `DELETE`, `CONFIRM`, `ESTB_REPORT`) via
`internalWriteSteuerMeldungenToCsv(list, TypeOfCsv)`. Two use cases exist:

- **Regular return files** (`RETURN`/`DELETE`/`CONFIRM`) — all meldungen in one call share the same
  Ermittlungsvorgabe version. Callers pass the whole list at once (`SteuerMeldungen` facade →
  `CalculationOutputs`/`RecalculationOutputs`, `RecalculationDomainService`, dev tool).
- **ISIN ESTB report** (`ESTB_REPORT`, sole caller `EstbReportDomainService`) — final meldungen may span
  **multiple** versions.

### Current behaviour (analysis result)

1. `internalWriteSteuerMeldungenToCsv` (lines 98–103) calls `validateSameSchemaVersion` **unconditionally**,
   with a stale `// todo - do not validate for ESTB_REPORT` above it. It throws `IllegalArgumentException`
   if any meldung's version differs from the first.
2. The ESTB multi-version case only works today **by accident**: `EstbReportDomainService` writes one
   meldung per call (`writeEstbReportSteuerMeldungenToCsv(List.of(stm))`, lines 242–243), so the validation
   loop never runs. Any batched ESTB call across versions would wrongly throw.
3. The CSV **structure schema is single and stable**: versions 3–6 all map to the same schema file in
   `CsvSteuerMeldungen.getSchemaPath` (lines 365–374). This will remain the design — no per-version schemas.
4. **Multi-row records** (E/D/Z/ZA/AS/STB) are already version-correct per-meldung: `writeMultiRowMultiValueRecord`
   drives off each meldung's own `getErmittlungsvorgabe().getCategoryOutputFields(...)`.
5. **Single-row records** (START/STATUS/END/EA) are schema-driven: `buildSingleRowValues` iterates over *all*
   schema columns and, when a value is empty, falls back to `column.getDefaultValue()` (lines 209–212). This
   ignores whether the field exists in *this* meldung's version. In the current schema the only column with a
   default is the structural `_START_SELBSTNACHWEIS` (`NEIN`), so the observable production impact today is
   nil — but the code is structurally wrong and will misbehave the moment a version-dependent field gets a
   schema default.

### Goal

Make the writer explicitly version-aware per-meldung by honoring `Ermittlungsvorgabe.fieldExists(String)`
(interface line 38), and honor the stale todo by skipping the same-version validation for `ESTB_REPORT`.
This unblocks batched mixed-version ESTB writes and removes the latent default-emission bug, while keeping
the single stable CSV structure. Output for current data stays byte-identical.

## Changes

All edits are in `CsvSteuerMeldungenWriter.java`, in the `internalWriteSteuerMeldungenToCsv` region.

### 1. Skip version validation for ESTB_REPORT

Replace lines 100–101:

```java
if (typeOfCsv != TypeOfCsv.ESTB_REPORT) {
    // ESTB_REPORT batches may legitimately span multiple Ermittlungsvorgabe versions
    validateSameSchemaVersion(steuerMeldungen, version);
}
```

Remove the `// todo`. `version`/`schema` selection is unchanged — since v3–6 share the schema, the schema
picked from `firstMessage` is identical regardless of which meldung leads a mixed batch. Per-meldung
correctness comes from change 2, not schema selection.

### 2. Honor `fieldExists` per-meldung in the single-row builder

In `buildSingleRowValues` (lines 193–216) — which `steuerMeldung` is already passed to, and which backs
START/END/EA (`writeSingleRowRecord`) and STATUS (`writeStatusRecord`) — guard the per-column loop:

```java
for (CsvColumnSchema column : sortedEntries) {
    String fieldName = column.getFieldName();
    // Structural columns (writer-owned, "_"-prefixed: _STATUS_*, _END_*, _START_SELBSTNACHWEIS) never
    // have a FieldSpec; always emit them (and honor their schema default). Business fields ("_e"-suffixed,
    // plus NAME/KAG/SteuerlicherVertreter) are version-dependent: a field the meldung's own
    // Ermittlungsvorgabe does not define must be emitted empty, not defaulted.
    if (!fieldName.startsWith("_") && !steuerMeldung.getErmittlungsvorgabe().fieldExists(fieldName)) {
        values.add("");
        continue;
    }
    String formatted = extractAndFormatSingleRowField(steuerMeldung, fieldName, column.getValueType());
    if (formatted.isEmpty() && column.getDefaultValue() != null) {
        formatted = column.getDefaultValue();
    }
    values.add(formatted);
}
```

**Discriminator rationale.** `fieldExists` alone is not enough: structural CSV columns (`_STATUS_*`,
`_END_*`, `_START_SELBSTNACHWEIS`, FILLER) have no `FieldSpec` so `fieldExists` returns false for them, yet
they must always be written. The `_`-prefix cleanly separates writer-owned structural columns from BMF
business fields — matching the existing convention in `SteuerMeldung.FieldName.isFormulaField` (lines 66–69).
Named-but-structural fields `NAME`/`KAG`/`SteuerlicherVertreter` are real Excel defined names backed by
FieldSpecs in every supported version, so `fieldExists` is true for them and the guard never suppresses them.
`FieldSpec.isFixedNameField()`/`ExcelErmVorgabeVersionSpecs.isFixedName` were rejected — they only match the
`FIX_`-prefix artificial names, which never appear in the CSV schema.

### 3. Multi-row path — no change

Already version-correct per-meldung (see analysis point 4).

### Output semantics

A version-missing field is emitted as an **empty string in its fixed column position, never omitted** — the
single stable schema is parsed positionally by `colIdx`, so omission would corrupt the row. On read,
`CsvIfasMessageProcessor.getOrDefault` keeps the empty (the `_e` business fields carry no schema default), and
`getFieldValue` returns null — round-trip faithful to an old-version meldung that never had the field.

## Reuse

Zero new methods/classes. Reuse `Ermittlungsvorgabe.fieldExists` directly; inline the one-line `_`-prefix
check. `EstbReportCsvDiffWriter.isStandardField`/`isExtendedField` answer a different question (output
category) and stay put.

## Tests

`CsvSteuerMeldungenWriterTest` and `CsvSteuerMeldungenRoundTripTest` use
`FixedNumCodeErmittlungsvorgabe(5, ...)` wrapping the real v5 field set; every field they assert exists in v5,
so existing assertions stay valid (output byte-identical for present fields). Add:

- **`CsvSteuerMeldungenWriterTest`**:
  - Old-version meldung (e.g. `FixedNumCodeErmittlungsvorgabe(4, ...)`) missing a v5/v6-only field → that
    column is empty and not schema-defaulted.
  - `_START_SELBSTNACHWEIS` still emits its `NEIN` default and `_STATUS_*`/`_END_*` still emit values →
    proves the `_`-prefix guard doesn't suppress structural columns.
  - `FieldName.NAME` set → appears in START (non-`_`, FieldSpec-backed field not suppressed).
- **`CsvSteuerMeldungenRoundTripTest`**:
  - `writeEstbReportSteuerMeldungenToCsv(List.of(stmV4, stmV5, stmV6))` does **not** throw
    `IllegalArgumentException` (proves change 1) and each meldung's version-missing fields come out empty
    (proves change 2 across versions in one batch).

## Verification

```bash
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
  -Dtest=CsvSteuerMeldungenWriterTest,CsvSteuerMeldungenRoundTripTest
```

Then the full module build to catch forbidden-apis / annotation-processing regressions:

```bash
mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am
```

## Critical files

- `ifas-domain/ifas-domain-stm/.../meldung/csv/CsvSteuerMeldungenWriter.java` — both changes
- `ifas-domain/ifas-domain-stm/.../vorgabe/Ermittlungsvorgabe.java` — `fieldExists` (reference)
- `ifas-domain/ifas-domain-stm/src/test/.../meldung/csv/CsvSteuerMeldungenWriterTest.java` — new tests
- `ifas-domain/ifas-domain-stm/src/test/.../meldung/csv/CsvSteuerMeldungenRoundTripTest.java` — new test
- `.../resources/.../csv/STM_AUSLIEFERFORMAT_2022-04-03.csv-schema.yml` — reference (confirms
  `_START_SELBSTNACHWEIS` is the sole defaulted column)
