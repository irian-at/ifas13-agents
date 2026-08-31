# CSV schema + read path for the Preismeldung (PREISMELDUNG_LIEFERFORMAT_2026-04)

## Context

`ifas-domain-stm/src/main/resources/at/oekb/ifas/domain/fondspreise/csv/PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml`
exists as a staged, **0-byte placeholder**. IFAS13 already *routes* Preismeldung files —
`IfasCsvMeldeFileType.PREIS_MELDEFILE`, auto-detection in `IfasCsvMeldeFileTypes`,
`BundleFileType.PREIS_MELDUNG_CSV_FILE`, `SteuerMeldungBundles.hasOnlyPreisMeldungFiles()`,
`ArchiveType.FONDSPREISE` — but nothing can *parse* one: `PreisMeldungDiffJobSubmissionService`
is a deliberate stub filing a `BadInputJob` ("PreisMeldungDiffJob not yet supported"), and there
are no entities, migrations or UI for prices. Fondspreise still runs in the legacy system
(`docs/Technische Konzepte/ifas13-jobs.md`).

This change fills the placeholder and gives the format a working read path, modelled on the
existing flat-CSV precedent (`Ausschuettung`) rather than on the record-marker STM processor.
Source spec: `docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf` — "Beschreibung Format
Preismeldung (inkl. LMT- & Solvabilität)", Version 3.0. It supersedes
`docs/Fondspreise/Preismeldung_ISINs_2025.pdf` (8 columns, codes R/E/Z/S/S2/S3) by adding the LMT
columns 9 + 10, the LMT codes L1/L2/L3 and the `I` (Inaktivierung) action.

Not in scope: persistence, the diff job, and `docs/Fondspreise/2025_Funddata_Provision.xlsx`
(that describes the *outbound* `preis.csv`/`solva.csv` delivery, a different format with a leading
identifier column).

## The format

`Preis_<absender>_<YYYYMMDD>_<HHMMSS>.csv`, semicolon-separated, **no header row and no
record-type marker column** — every line is one complete Preismeldung with up to 10 fields.
Numbers accept dot *or* comma as decimal separator, no thousands separator; percentages are plain
percent numbers (10% → `10`).

| Col | Field | Mandatory | Format |
|-----|-------|-----------|--------|
| 1 | Datum (Preisdatum / gültig ab) | X | `YYYYMMDD` or `YYYY.MM.DD`, may be past, not future |
| 2 | Währung | X | STRING(3), ISO 4217 |
| 3 | ISIN | X | STRING(12) |
| 4 | Meldekategorie | X | STRING(2): `R E Z S S2 S3 L1 L2 L3` |
| 5 | Wertebefüllung | X | numeric, up to 8 decimals |
| 6 | Aktion | – | `N` (default, new/update), `D` (delete), `I` (Inaktivierung L2) |
| 7 | Fondsbezeichnung | – | STRING(45) |
| 8 | Periodizität des Fondshandels | X if not `D` | `D` (default) `W M2 M Q S A` |
| 9 | LMT Prozentkennzeichen | – | `J` = Prozentzahl, `N` = Geldwert (default); only L1 & L3 |
| 10 | LMT Stichtag Verlängerung Rückgabefrist | X if L2 and Anzahl Tage = 0 | date, same notations; only L2 |

Meldekategorie code table and what column 5 means for each:

| Code | Bedeutung | col 5 |
|------|-----------|-------|
| `R` | Errechneter Wert | Preis |
| `E` | Ausgabepreis | Preis |
| `Z` | Rücknahmepreis | Preis |
| `S` | Solvabilität I | Wert |
| `S2` | Solvabilität II (Basel II, Standardansatz) | Wert |
| `S3` | Solvabilität II.1 (Basel II, vereinfachter IRB) | Wert |
| `L1` | LMT – Rücknahmebeschränkung | Quote (Prozentzahl if col 9 = `J`, else Geldwert) |
| `L2` | LMT – Verlängerung der Rückgabefrist | Anzahl Tage (`0` ⇒ col 10 carries the Stichtag) |
| `L3` | LMT – Rückgabegebühr | Gebühr (Prozentzahl if col 9 = `J`, else Geldwert) |

Cross-field rules from the LMT section (§4.2 + Anhang) — none of these are expressible in the
schema model, so they go into a validations class:

1. `L2` with a Stichtag: col 5 must be `0` (for activation *and* inactivation).
2. `L2` + col 5 = `0` + col 6 ≠ `I` ⇒ col 10 **must** be filled.
3. `L2` + col 6 = `I` ⇒ col 5 must be `0` **and** col 10 must be empty.
4. Col 6 = `I` is only valid for `L2`.
5. `L1`/`L3` must not report `0` in col 5 and must not report inactivations.
6. Col 9 is only meaningful for `L1`/`L3`; col 10 only for `L2`.
7. Deletions (col 6 = `D`) must repeat the originally delivered values — cross-delivery, not
   checkable at parse time. Documented only.

Spec caveat that shapes the design: *"Eine inhaltliche Plausibilisierung der Meldungen wird nicht
vorgenommen."*

## Decisions

- **fieldName convention**: spec-derived UPPER_SNAKE (`DATUM`, `WAEHRUNG`, `ISIN`,
  `MELDEKATEGORIE`, `WERT`, `AKTION`, `FONDSBEZEICHNUNG`, `PERIODIZITAET`,
  `LMT_PROZENTKENNZEICHEN`, `LMT_STICHTAG`).
- **Conditionally mandatory columns 8 and 10**: `required: false` plus a German YAML comment
  stating the real rule — the same way `STM_LIEFERFORMAT`'s EA record documents it. Column 8 also
  carries `defaultValue: D`. Enforcement lives in `CsvPreismeldungValidations`.
- **No ISIN checksum validation.** The spec forbids content plausibilisation, and the PDF's own
  examples use ISINs that fail the checksum (`AT0000123450` computes to check digit 7, and the LMT
  examples use 9-character stubs like `AT0000002`). Column 3 stays `TEXT` + `required: true`.
  Cloning `CsvAusschuettungenMessageProcessor`'s behaviour here would be worse still — it *skips
  the whole line* on an ISIN failure. If OeKB later wants structural (not checksum) enforcement,
  the upgrade is a new `ISIN` valueType with `^[A-Z]{2}[A-Z0-9]{9}[0-9]$`.
- **`colIdx` is 1-based over the whole raw row** (`colIdx: 1` = `record.get(0)`), matching the
  flat Ausschuettung processor and the PDF's own column numbering. Stated once in a class comment
  and applied consistently in *both* the bounds check and the accessor.

## Work

### 1. The schema file

Fill `ifas-domain/ifas-domain-stm/src/main/resources/at/oekb/ifas/domain/fondspreise/csv/PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml`.

Single record type, synthetic `code: PREISMELDUNG` (never appears in the file), **no `section`**
(a `section: START` would demand message framing), `SINGLE_ROW_MAP` + `SINGLE_VALUE`, `entries`
`colIdx: 1..10`. Only the keys `colIdx`, `fieldName`, `mapCode`, `desc`, `valueType`, `required`,
`defaultValue` are permitted — the loader is a plain Jackson `ObjectMapper`, so any invented key
(`maxLength`, `codes`, …) fails the load with `UnrecognizedPropertyException`.

```yaml
name: PREISMELDUNG_LIEFERFORMAT_2026-04
version: 2026-04
description: Lieferformat Preismeldung (inkl. LMT & Solvabilität), Version 3.0
recordTypes:
  #------------------------------------------------ PREISMELDUNG
  # Flaches Format: jede Zeile ist eine vollständige Meldung, es gibt keine Satzart-Spalte.
  # Der Code PREISMELDUNG ist synthetisch und kommt in der Datei nicht vor.
  - code: PREISMELDUNG
    description: Preis-, Solvabilitäts- oder LMT-Meldung je ISIN
    recordMapping: SINGLE_ROW_MAP
    valueMapping: SINGLE_VALUE
    entries:
      - colIdx: 1
        fieldName: DATUM
        desc: Preisdatum / Gültig ab   # darf in der Vergangenheit, nicht in der Zukunft liegen
        valueType: DATE
        required: true
      - colIdx: 2
        fieldName: WAEHRUNG
        desc: Währungscode (ISO 4217)
        valueType: TEXT
        required: true
      - colIdx: 3
        fieldName: ISIN
        desc: ISIN
        valueType: TEXT
        required: true
      - colIdx: 4
        fieldName: MELDEKATEGORIE
        desc: Meldekategorie Preis / Solvabilität / LMT
        valueType: PREIS_MELDEKATEGORIE
        required: true
      - colIdx: 5
        fieldName: WERT
        desc: Wertebefüllung - Preis, Solvabilität, Quote, Anzahl Tage oder Rücknahmegebühr
        valueType: AMOUNT_NK8
        required: true
      - colIdx: 6
        fieldName: AKTION
        desc: Aktion - N (New/Update), D (Delete), I (Inaktivierung L2)
        valueType: PREIS_AKTION
        defaultValue: N
      - colIdx: 7
        fieldName: FONDSBEZEICHNUNG
        desc: Fondsbezeichnung
        valueType: TEXT
      - colIdx: 8
        fieldName: PERIODIZITAET
        desc: Periodizität des Fondshandels
        valueType: PREIS_PERIODIZITAET
        required: false # Pflichtfeld nur falls 'D' (täglich) nicht zutreffend
        defaultValue: D
      - colIdx: 9
        fieldName: LMT_PROZENTKENNZEICHEN
        desc: LMT Prozentkennzeichen - J (Prozentzahl), N (Geldwert)
        valueType: J_N
        required: false # nur relevant für die Wertebefüllung bei L1 und L3
        defaultValue: N
      - colIdx: 10
        fieldName: LMT_STICHTAG
        desc: LMT Stichtag für Verlängerung Rückgabefrist
        valueType: DATE
        required: false # Pflichtfeld nur bei L2 und Anzahl Tage = 0; sonst nicht zu befüllen
```

`AMOUNT_NK8` (`^[+-]?\d+(?:[.,]\d{1,8})?$`) already encodes "up to 8 decimals, dot or comma".
`DATE` already accepts both required notations — the alternation lives in
`ifas-domain-stm/.../meldung/csv/CsvIfasDateFormat.java` and is applied per value, so `20260105`
and `2026.01.05` may be mixed within one file (both appear in the PDF's examples).
`STRING(3)`/`STRING(12)`/`STRING(45)` cannot be expressed — `CsvColumnSchema` has no length
attribute — so those stay documentation in `desc`.

### 2. Three new value types

`valueType` is a free-form String resolved against `TYPE_PATTERNS`; an unknown one throws
`IllegalArgumentException("No pattern found for type: …")` at parse time.

| New type | Regex | Column |
|----------|-------|--------|
| `PREIS_MELDEKATEGORIE` | `^(R\|E\|Z\|S\|S2\|S3\|L1\|L2\|L3)$` | 4 |
| `PREIS_AKTION` | `^(N\|D\|I)$` | 6 |
| `PREIS_PERIODIZITAET` | `^(D\|W\|M2\|M\|Q\|S\|A)$` | 8 |

The `PREIS_` prefix avoids colliding with the existing `ART` and keeps `AKTION` unambiguous.
Files to edit, all under `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/`:

1. `domain/stm/meldung/csv/CsvIfasValueTypeValidator.java` — three `patterns.put(...)` lines in
   `createPatternMap()`. **Required** (this is the read path).
2. `domain/stm/meldung/csv/CsvIfasValueType.java` — add the three constants. Strictly optional
   (the enum drives only the write side, and Preismeldung has no write path), but add them anyway:
   `AUSSCHUETTUNG_OUTPUT-LIEFERFORMAT_2018-03-19.csv-schema.yml` already declares a phantom
   `valueType: TIME` that exists in neither the enum nor the pattern map, and that divergence is a
   trap worth not repeating.
3. `domain/stm/meldung/csv/CsvTypeCoercions.java` — `VALUE_TYPE_TO_CLASS` entries mapping all
   three to `String.class`, plus `case`s in the `coerce` switch returning `stringValue`. The
   switch is exhaustive over the enum, so step 2 makes these compile errors if forgotten. Do
   **not** add reverse `CLASS_TO_VALUE_TYPE` entries — `String.class` is already mapped to `TEXT`.
4. `domain/stm/meldung/csv/CsvValueFormatters.java` — `case`s emitting the string as-is (also an
   exhaustive switch).
5. `domain/stm/validation/ValidationMsgMapper.java` — add the three names to the existing
   `case "JA_NEIN", "J_N", "W_RABATT_ART", "KAPITAL_RUECKZAHLUNG", "ART", "ERTRAGSTYP" -> …
   ERR_UNG_CODE` group in `mapValueTypeError`. Defensive: Preismeldung messages do not flow
   through this mapper today, and its `case null, default` arm throws.

### 3. `CsvPreismeldungMessageProcessor`

New package `at.oekb.ifas.domain.fondspreise.csv` in `ifas-domain-stm`, matching the already
staged resource path. Model on
`ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ausschuettung/csv/CsvAusschuettungenMessageProcessor.java`
— one CSV line = one `CsvMessage`, record-type code supplied as a constant
(`RECORD_TYPE = "PREISMELDUNG"`), never read from the row.

Same `CSVFormat` and charset as the Ausschuettung processor: `;` delimiter,
`setIgnoreSurroundingSpaces(true)`, `setIgnoreEmptyLines(true)`, `setTrim(true)`, charset
`IfasCharsets.IFAS_CSV_CHARSET` (windows-1252).

**Three deviations from the precedent — all deliberate, do not copy its versions:**

- *Bounds check.* `validateRecordHasRequiredColumns` there uses
  `columnSchema.getColIdx() >= csvRecord.size()` (the STM 0-based convention) while every accessor
  uses `colIdx - 1` — a false `MISSING_FIELD` on the last declared column even when present.
  Correct form is `columnSchema.getColIdx() - 1 >= csvRecord.size()`; it is also redundant with
  the guard inside `addSingleRowRecordValues`, so fold it into that single guard.
- *Too many parameters.* `handleTooManyParams` there reads
  `this.csvFile.getMessages().getLast()`, but the message is appended only *after*
  `processRecordValues` — a `NoSuchElementException` when the **first** line is over-long. Pass the
  current `CsvMessage` in explicitly. And only report `TOO_MANY_PARAMETERS` when a field beyond
  column 10 is **non-empty**: the PDF's LMT examples all carry a trailing `;`, so an 11-field row
  with an empty 11th field is normal input, not an error
  (`2026.01.31;EUR;AT0000002;L2;0;;;;;2026.02.10;`). Keep the argument order
  `(recordSize, recordSchema.getCode())` — it reads oddly against the template
  (`"Too many parameters for record type: ''{0}''"`), but both existing processors pass it that way
  and `ValidationMsgMapper`'s `ERR_ANZ_PARAM` case consumes `arguments()[0]`/`[1]` in that order.
  Do not "fix" it here.
- *`defaultValue`.* The Ausschuettung processor ignores defaults entirely; `CsvIfasMessageProcessor`
  applies them only for present-but-empty cells and only *after* validation. Here, substitute the
  default *before* validation, so `defaultValue: D` on column 8 both satisfies the code-list check
  and is what gets stored. Columns 8 and 9 are `required: false`, so there is no `MISSING_FIELD`
  interaction to preserve.

Note also that `CsvValueFormatters.formatValue` and `CsvTypeCoercions.coerce` switch exhaustively
over `CsvIfasValueType` with no `default` arm — verified — so step 2's enum constants force those
edits at compile time. The three new types join the `String` handling
(`value instanceof String s ? formatText(s) : value.toString()`).

Keep the rest of the precedent's shape: `CsvMessagePosition.of(...)` for positions,
`csvMessage.addSimpleRecordValue(fieldName, SimpleRecordValue.of(position, value))`,
`DUPLICATE_VALUE` on a non-null return, `MISSING_FIELD` via the validator for present-but-empty
required cells. Reject anything other than `SINGLE_ROW_MAP` with
`UnsupportedOperationException`. No ISIN check (see Decisions).

### 4. `PreismeldungField` + `CsvPreismeldungValidations`

Add a `PreismeldungField` enum in the same package holding the ten fieldNames, mirroring the nested
`Ausschuettung.Field` enum — so the YAML fieldNames have exactly one Java counterpart instead of
string literals scattered across the processor and the validations. A standalone enum rather than a
nested one, since there is no `Preismeldung` domain object yet.

`CsvPreismeldungValidations`: `@UtilityClass`, `validate(CsvMessage) -> List<CsvValidationMsg>`,
called from the processor once the column values are in — the same hook as
`CsvAusschuettungenValidations.validate(csvMessage)`. Read values via
`CsvMessage.getValidSimpleRecordValueString(fieldName)` and positions via
`CsvMessage.getPosition(fieldName)`.

**Contain only the cross-field rules.** `CsvAusschuettungenValidations` is a bad model here in one
specific way: it *re-validates* required fields, date formats and amount formats that the schema
and `CsvIfasValueTypeValidator` already cover, so those cells get two validation messages — and its
hand-rolled regexes have drifted from the real ones (its amount pattern rejects negatives; its date
pattern omits `dd-MM-yyyy`, which `CsvIfasDateFormat` accepts). It also carries a dead private
`isNumeric`. Take its *structure*, not its content.

Rules 1–6 above, keyed off `MELDEKATEGORIE`, `WERT`, `AKTION` and `LMT_STICHTAG`. Codes:

- Rule 2 (Stichtag missing for `L2` + `WERT` = 0 + `AKTION` ≠ `I`) reuses the existing
  `CsvErrorCode.MISSING_FIELD` with fieldName `LMT_STICHTAG` — exactly its semantics.
- Rules 3 and 6 ("must not be filled") and rules 1, 4, 5 ("this value is not allowed in this
  combination") have no fitting constant. `FIELD_ONLY_ALLOWED_IN_RECORD` is about record types,
  not value conditions. Add two constants to
  `support-libs/csv-schema/.../CsvErrorCode.java`, following its `MessageFormat` template style:
  - `CONDITIONAL_FIELD_NOT_ALLOWED` — field `{0}` must not be filled when `{1}` = `{2}`
  - `CONDITIONAL_VALUE_NOT_ALLOWED` — value `{1}` in field `{0}` is not allowed when `{2}` = `{3}`

  Do **not** add `ValidationMsgMapper` cases for these yet: that mapper translates to legacy
  Altsystem `ValidationMsgCode`s for the STM pipeline, and Preismeldung has no such pipeline. Note
  it as the follow-up for whoever implements `PreisMeldungDiffJobSubmissionService`.

Rule 7 (deletions repeat the original values) is cross-delivery and cannot be checked here — a
comment in the class, nothing more.

### 5. `CsvPreismeldungen` facade

Same package. Holds the schema path constant and a cached load, following
`ifas-domain-stm/.../meldung/csv/CsvSteuerMeldungen.java` (a `ConcurrentHashMap` schema cache) —
**not** `AusschuettungCsvProcessor`, which reloads and re-parses the YAML on every single call.
Exposes the schema plus a `loadAndProcess(NamedContentTypeResource, String filename)` that builds
the processor with `CsvIfasValueTypeValidator.INSTANCE` and `CsvIfasFilenameValidator.INSTANCE`
and delegates to `CsvMessages.loadMessagesFromResource`.

`CsvSchemaType` is a closed STM-only enum (`STM_LIEFERFORMAT`, `STM_AUSLIEFERFORMAT`) hard-wired
into `CsvIfasMessageProcessor`'s constructor — do not extend it.

`CsvIfasFilenameValidator` accepts `Preis_OEKB_20260416_145023.csv` as-is (extension `csv`, stem
`^[A-Za-z0-9._-]+$`). The spec's `Preis_<absender>_<YYYYMMDD>_<HHMMSS>` shape is not enforced;
`SteuerMeldungBundles` already keys off `preis_*.csv|.txt`.

### 6. Tests

New `CsvPreismeldungTest` (+ `CsvPreismeldungValidationsTest`) under
`ifas-domain-stm/src/test/java/at/oekb/ifas/domain/fondspreise/csv/`, given-when-then names,
AssertJ, JUnit 5, following the helper style of
`ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvTests.java`.

Fixture CSVs in `ifas-domain-stm/src/test/resources/at/oekb/ifas/domain/fondspreise/csv/`, taken
verbatim from the PDF's §7 and Anhang examples except that the illustrative 9-character ISINs are
replaced with real 12-character ones:

| Fixture | Asserts |
|---------|---------|
| `preismeldung_valid.csv` — the seven §7 New/Update rows + the two Delete rows | no validation messages; one `CsvMessage` per line; values land under the expected fieldNames; `20260105` and `2026.01.05` both parse |
| `preismeldung_lmt.csv` — the eight Anhang rows (11 fields each, trailing `;`) | no validation messages — in particular **no** `TOO_MANY_PARAMETERS` for the trailing empty field |
| `preismeldung_defaults.csv` — rows with columns 6, 8, 9 empty | `AKTION` = `N`, `PERIODIZITAET` = `D`, `LMT_PROZENTKENNZEICHEN` = `N` |
| `preismeldung_missing_required.csv` — rows with columns 1–5 empty or absent | `MISSING_FIELD` per required column; short rows do not produce spurious messages for the *last* column (the regression guard for the corrected bounds check) |
| `preismeldung_invalid_codes.csv` — `X` as Meldekategorie (the legacy-only code), `Q` as Aktion, `M3` as Periodizität, `Y` as Prozentkennzeichen, `1.234,56` as Wert, `2026-04.15` as Datum | `VALUE_TYPE_VALIDATION` per cell |
| `preismeldung_lmt_invalid.csv` — L2 with Wert ≠ 0 *and* a Stichtag; L2 with Wert = 0 and no Stichtag; Aktion `I` on an `L1`; `0` as Wert for `L3`; column 9 filled on an `S2`; column 10 filled on an `R` | the `CONDITIONAL_*` / `MISSING_FIELD` message expected per rule |
| `preismeldung_too_many.csv` — a **first** line with a non-empty 11th field | one `TOO_MANY_PARAMETERS` and no exception (the regression guard for the corrected `handleTooManyParams`) |

Also add a plain "does it load" test (`CsvSchemas.loadCsvSchema(new ClassPathResource(...))`
succeeds, record type `PREISMELDUNG` present, 10 entries) — there is no repo-wide test that parses
every `*.csv-schema.yml`, so a malformed schema would otherwise surface only at first runtime use.

## Verification

```bash
mvn clean install -Pno-proxy -pl support-libs/csv-schema -am
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest='CsvPreismeldung*'
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm          # no regressions in the STM CSV tests
mvn clean install -Pno-proxy -Pdev-build                     # full build, forbiddenapis included
```

`-Pdev-build` is needed for the modules depending on the OeKB auth libs; `-Pno-proxy` always.
`forbiddenapis` runs in the `package` phase, so the full build is what proves the no-`now()`,
no-`System.out`, JUnit-5-only rules.

End-to-end sanity beyond the unit tests: `IfasCsvMeldeFileTypes.determineIfasCsvOrTxtFileTypeByFirstLine`
already classifies a file whose first token matches `\d{8}` or `\d{4}\.\d{2}\.\d{2}` as
`PREIS_MELDEFILE`, so dropping a fixture through the upload path reaches
`PreisMeldungDiffJobSubmissionService` — still a stub, so confirm classification and parsing, not
processing. Worth noting while there: that detection accepts only the two spec notations, while
the `DATE` valueType accepts five (`yyyy-MM-dd`, `dd.MM.yyyy`, `dd-MM-yyyy` too) — a file using one
of the extra three parses fine but is not auto-detected as a Preismeldung. Leave as is; flag it.

## Assumptions worth confirming

- No ISIN validation (see Decisions) — driven by the spec's "keine inhaltliche Plausibilisierung"
  and by its own examples failing the checksum.
- "Nicht in der Zukunft" for column 1 is **not** enforced. It needs `LocalDates.now()` and is a
  content check, not a format one; `CsvSteuerMeldungValidations` keeps its analogous
  `MIN_VALID_YEAR` rule outside the value type for the same reason.
- The legacy `X` Meldekategorie (`Kurs/tabledefs/v_preiscode.cr` allows `E R S S2 S3 X Z`) is
  absent from the 2026 spec and is therefore rejected. Likewise the legacy `I` = *Unregelmäßig*
  interval (`ins_liefer_intervalle.cr`) is not a valid Periodizität here — note the collision:
  `I` means "irregular" in the legacy interval table but "Inaktivierung" in the new Aktion column.
- The version is recorded as `2026-04` (from the file name) although the PDF states "anwendbar für
  Meldungen ab dem [Information folgt gesondert | Konkretes Datum tbd]" — the effective date is
  still open, so no date-gated behaviour is introduced.
