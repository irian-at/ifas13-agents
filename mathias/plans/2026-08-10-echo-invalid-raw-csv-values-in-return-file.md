# Echo invalid raw CSV values into the return file (and simplify the writer)

## Context

`CsvSteuerMeldungenWriter.extractAndFormatSingleRowField` was just extended (uncommitted WIP, together with
`SteuerMeldung.getInvalidFieldValue` and `CsvSteuerMeldung.getInvalidFieldValue`) so that a raw value which
failed CSV type validation is echoed back verbatim into the Rückmeldedatei instead of being dropped.

The intent is correct and matches legacy. Verified against the gf1 fixture:

- input `docs/Testdaten Fachabteilung/gf1-d20240726/gf1-d20240726.csv:463` delivers
  `START;LU0111491469;IF;Thes;EUR;01.01.2023;31.12.2023;yes;…` — `yes` fails
  `CsvIfasValueTypeValidator:43` (`JA_NEIN` requires `^(JA|NEIN)$`), so `CsvIfasMessageProcessor:397`
  stores `SimpleRecordValue.invalid(position, "yes")`.
- legacy return `…_return.csv:11039` echoes that row with `yes` intact.
- legacy is *not* echoing the input line verbatim (row 2 of the same file drops `Meldezeitraum_Ende`),
  so it re-serializes per field and passes invalid raw values through. Exactly what the WIP intends.

**But the WIP does not work, and cannot work as written — three defects stack:**

1. **Dead branch.** `sourceEntry instanceof CsvSteuerMeldung` is never true. `CsvSteuerMeldung`
   implements `SteuerMeldung`, not `SubmissionEntry`, and `CsvSteuerMeldung.getSourceEntry()`
   (`CsvSteuerMeldung.java:307`) returns the `CsvMessage`. No `SteuerMeldung` implementation returns a
   `CsvSteuerMeldung` from `getSourceEntry()`. It compiles only because `CsvSteuerMeldung` is non-final,
   so the compiler cannot prove disjointness. Every call currently takes the `else` branch.
2. **Wrapper gap.** Even fixed to `steuerMeldung instanceof CsvSteuerMeldung`, the return path never
   holds a bare `CsvSteuerMeldung`: it is always a 2–4 layer stack
   (`SimpleFieldsOverridingProcessedSteuerMeldung` → … → `JavaCalculatedFieldsSteuerMeldung` →
   `CsvSteuerMeldung`), built in `SteuerlicheErmittlungDomainService`. `WrappedSteuerMeldung`
   delegates `getSourceEntry`, `getFieldValue`, … but **not** `isFieldValueValid` /
   `getInvalidFieldValue`, so the interface defaults (`true` / `throw`) win.
3. **Override bypass.** The valid branch reads `csvSteuerMeldung.getFieldValue(...)` instead of the
   passed `steuerMeldung`. If the instanceof ever matched, every override (STATUS, STM_ID, STM_ID_REF,
   END_TIMESTAMP, calculated StB fields) would be silently replaced by raw Lieferant input.

Also: the behaviour is **completely untested** — `isFieldValueValid`/`getInvalidFieldValue` have zero
hits in any `src/test` tree, and `CsvSteuerMeldungenWriterTest`'s 30 tests all use `MockSteuerMeldung`.

Outcome: one obviously-simpler method that actually works, plus regression tests.

## Approach

The elegant form *is* the working form: the interface already declares exactly the right defaults
(`SteuerMeldung.java:95` `isFieldValueValid` → `true`, `:103` `getInvalidFieldValue` → throws,
documented as "DB/Excel sources have no invalid raw values"). So call them polymorphically and drop the
`instanceof` entirely — which is also how the rest of the codebase already does it
(`SteuerMeldungDomainValidationService.java:203,208`, `SteuerMeldungErmittlungsvorgabeValidators.java:294,558`).

### 1. `CsvSteuerMeldungenWriter.java` (:436-463)

Replace the method body; the `Object value` variable, both nested branches and the
`at.oekb.ifas.core.submission.SubmissionEntry` import (:3, added by the WIP) all go away.

```java
private String extractAndFormatSingleRowField(
        SteuerMeldung steuerMeldung,
        String fieldCode,
        String valueType
) {
    // a raw value that failed CSV type validation is echoed back verbatim (legacy c_st_meldung.cpp)
    if (!steuerMeldung.isFieldValueValid(fieldCode)) {
        return CsvValueFormatters.formatText(steuerMeldung.getInvalidFieldValue(fieldCode));
    }
    CsvIfasValueType csvValueType = CsvIfasValueType.valueOf(valueType);
    Class<?> javaType = CsvTypeCoercions.getJavaTypeForCsvValueType(csvValueType);
    return CsvValueFormatters.formatValue(steuerMeldung.getFieldValue(fieldCode, javaType), csvValueType);
}
```

`formatText` instead of `formatValue(value, TEXT)`: for a `String` the two are identical
(`CsvValueFormatters.java:33`), and `getInvalidFieldValue` returns `String`.

### 2. `WrappedSteuerMeldung.java` — add the two missing delegations

Fixes all 7 wrapper classes at once. Mirrors the existing `getSourceEntry` delegation (:96-99).

```java
@Override
public boolean isFieldValueValid(String fieldName) {
    // an overridden field's value comes from the wrapper, not from the (possibly invalid) raw input
    return useWrappedFieldValueFor(fieldName, false) || getDelegate().isFieldValueValid(fieldName);
}

@Override
public String getInvalidFieldValue(String fieldName) {
    return getDelegate().getInvalidFieldValue(fieldName);
}
```

The `useWrappedFieldValueFor` guard is what keeps defect 3 fixed: an overridden field reports *valid*
so the wrapper's value is emitted, never the raw input. This mirrors the `final getFieldValue`
dispatch at `:32-38`. Plain delegation is then safe for `getInvalidFieldValue`, because the writer only
reaches it when `isFieldValueValid` already returned `false` (i.e. the wrapper does not override).

Not touched: `getCountryCodesWithInvalidValue`. Validation runs on the unwrapped `CsvSteuerMeldung`
(`SteuerMeldungLieferungService.java:90-100` calls `steuerMeldung.getCsvMessage()`), so there is no gap
there and delegating it would change validator output for no reason.

### 3. Tests

- **`MockSteuerMeldung`** (`.../meldung/MockSteuerMeldung.java`): add `withInvalidFieldValue(fieldName,
  rawValue)` to the existing builder, backed by a second map, overriding `isFieldValueValid` /
  `getInvalidFieldValue`. Reuses the harness `CsvSteuerMeldungenWriterTest` already builds on rather
  than hand-rolling `CsvMessage`s.
- **`CsvSteuerMeldungenWriterTest`**: next to `givenSteuerMeldungWithBooleanTrue_…_thenWritesJa` (:164):
  - `givenSteuerMeldungWithInvalidRawValue_whenWriteToCsv_thenEchoesRawValue` — invalid `yes` for
    `FieldName.JAHRESDATEN` → output contains `;yes;`.
  - `givenWrappedSteuerMeldungWithInvalidRawValue_whenWriteToCsv_thenEchoesRawValue` — same meldung
    wrapped in `SimpleFieldsOverridingSteuerMeldung` (covers defect 2).
  - `givenWrappedSteuerMeldungWithOverriddenInvalidField_whenWriteToCsv_thenWritesOverride` — wrapper
    overrides that field → output has the override, not `yes` (covers defect 3).
- **End-to-end through real `CsvSteuerMeldung`**: add a focused test alongside
  `CsvSteuerMeldungenRoundTripTest:46` with its **own new fixture** (a trimmed copy carrying one
  invalid `yes`) — do not edit `CsvSteuerMeldungenTest.csv`, it is shared with `CsvSteuerMeldungenTest`.
  Assert the written START row contains `;yes;`.

Given-when-then naming, AssertJ, `IFAS_CSV_CHARSET` for decoding — as in the existing tests.

## Files

| File | Change |
|---|---|
| `ifas-domain/ifas-domain-stm/.../meldung/csv/CsvSteuerMeldungenWriter.java` | rewrite `extractAndFormatSingleRowField`, drop `SubmissionEntry` import |
| `ifas-domain/ifas-domain-stm/.../meldung/util/WrappedSteuerMeldung.java` | add 2 delegating overrides |
| `ifas-domain/ifas-domain-stm/src/test/.../meldung/MockSteuerMeldung.java` | builder support for invalid raw values |
| `ifas-domain/ifas-domain-stm/src/test/.../meldung/csv/CsvSteuerMeldungenWriterTest.java` | 3 new tests |
| `ifas-domain/ifas-domain-stm/src/test/.../meldung/csv/` (+ resource) | round-trip test + new fixture |

`SteuerMeldung.getInvalidFieldValue` and `CsvSteuerMeldung.getInvalidFieldValue` (the other two WIP
hunks) stay exactly as they are — they are correct.

## Verification

```bash
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
  -Dtest='CsvSteuerMeldungenWriterTest,CsvSteuerMeldungenRoundTripTest,CsvSteuerMeldungenTest'
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm      # full module, catch wrapper-delegation fallout
```

End-to-end against the legacy reference (the tool is already hardcoded to gf1):

```bash
mvn exec:java -Pno-proxy -pl ifas-dev-tools \
  -Dexec.mainClass="at.oekb.ifas.devtools.CsvSteuerMeldungRoundTripTool"
```

Then confirm the `LU0111491469` START row echoes `;yes;` and compare against
`docs/Testdaten Fachabteilung/gf1-d20240726/gf1-d20240726_return.csv:11039`.

**Expected output change:** return-file columns whose raw input failed type validation now carry the
raw text instead of `""` (or the schema `defaultValue` — e.g. `Wiederanlagerabatt_e`, colIdx 13, has
`defaultValue: NEIN`, so today an invalid value there is silently reported as `NEIN`). This shifts bytes
in return files for affected meldungen, so re-check any recalc/grossfile comparison baselines that
include a meldung with invalid raw values (gf1 has at least `LU0111491469`).

## Out of scope

- **Multi-row records** (E / D / Z / ZA / AS / STB): `writeSingleAmountRow` (:264),
  `writeStbVectorRows` (:323), `writeCountryVectorRows` (:363) read typed `BigDecimal` /
  `CountryVector` and never consult `isFieldValueValid`, so invalid raw amounts stay dropped there.
  Deferred by decision; each path would need its own invalid-value branch.
- **DATE format**, observed but unverified as a defect: legacy's return START row writes `01.01.2023`
  (`dd.MM.yyyy`) while `CsvValueFormatters.DATE_FORMATTER` is `yyyy.MM.dd`, and `GJ_Beginn_e` /
  `GJ_Ende_e` (colIdx 5/6) are `valueType: DATE`. Unrelated to this change; worth a separate look.
