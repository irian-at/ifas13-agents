# Plan: Produce `ERR_UNG_LAND` for misaligned country-vector rows whose `BETRAG` is invalid

## Context

When a country-vector row (D / Z / ZA / AS / E) has misaligned parameters such as

```
D;D_Dividenden_Subfonds_e;5,123456;5,123456;DE
```

the parser correctly emits `ERR_ANZ_PARAM`. But `ERR_UNG_LAND` does **not** fire,
even though the value parked at the LAENDERCODE position (`5,123456`) is not a
valid country code.

Confirmed cause: `CsvSteuerMeldung.extractCountryVectorMapValues`
(`ifas-domain-stm/.../meldung/csv/CsvSteuerMeldung.java:134-173`) does
`continue` whenever the nested `BETRAG` `SimpleRecordValue` is invalid. In the
example, BETRAG = `"5,123456"` fails AMOUNT validation (too many decimals), so
its country-key wrapper is dropped, `result.isEmpty()` is true, and the
extractor returns `null`. Downstream:

```java
CountryVector cv = steuerMeldung.getFieldValue(fieldSpec.definedName(), CountryVector.class);
if (cv != null) {            // silently no-ops when cv is null
    cv.getCountryCodes().forEach(...);  // ERR_UNG_LAND lives here
}
```
(`SteuerMeldungErmittlungsvorgabeValidators.validateCountryVectorInputField`,
lines 117-141.)

## Approach

Don't change the `CountryVector` contract or the extractor. Instead, in
`validateCountryVectorInputField`, **always** check the raw country-key set
against `Ermittlungsvorgabe.getCountrySpec` for `ERR_UNG_LAND`, independently
of whether the `CountryVector` extraction succeeded. The "further validation"
that today lives inside the `if (countrySpec != null)` branch continues to run
only against the validated `CountryVector` (since it needs the numeric amounts
anyway).

In effect:

```java
List<String> rawCountryCodes = steuerMeldung.getRawCountryCodes(fieldSpec.definedName());
for (String code : rawCountryCodes) {
    if (ermittlungsvorgabe.getCountrySpec(code) == null) {
        validationMsgs.add(new ValidationMsg(..., ERR_UNG_LAND, ..., code, recordType));
    }
}
if (cv != null) {
    cv.getCountryCodes().forEach(countryCode -> {
        CountrySpec countrySpec = ermittlungsvorgabe.getCountrySpec((String) countryCode);
        if (countrySpec != null) {
            // existing per-country deep validation
        }
    });
}
```

The two loops are deduplicated by construction: the `ERR_UNG_LAND` block uses
raw keys, the deep-validation block runs only when `getCountrySpec` returned
non-null. No country code can produce both `ERR_UNG_LAND` and the
deep-validation messages.

## Why this is safer than mutating the extractor

The earlier draft proposed making `extractCountryVectorMapValues` retain
invalid entries with a sentinel amount. That would change the public contract
of `CountryVector` ("every key has a valid amount associated") and force a
full audit of every consumer in `ifas-domain-stm`, `ifas-domain-recalc`, and
`ifas-services`. Mathias's suggestion avoids all of that — `CountryVector`
keeps its existing contract, only the validator learns to look at raw keys.

## Exposing the raw country keys

`SteuerMeldung` is an interface; `CsvSteuerMeldung` is the CSV-backed
implementation. The current interface only exposes `getFieldValue(...)`, which
returns the already-coerced `CountryVector`. We need a new method that
returns the unfiltered outer keys of the `MapRecordValue` for a given field.

**Reuse check (per
`ifas13-agents/mathias/rules/reuse-before-reimplementing.md`):**
- Searched `CsvSteuerMeldung`, `SteuerMeldung`, and the `csv-schema` module
  for any existing accessor that exposes raw map keys. There is none.
  `CsvMessage.getRecordValue(...)` exists but is a CSV-layer concern that
  shouldn't leak through the domain interface. The closest existing pattern
  is `isFieldValueValid(String fieldName)` on `SteuerMeldung` (used at
  `CsvSteuerMeldung.java:235-241`), which already crosses the same
  abstraction boundary in a similarly narrow way — so adding a peer method
  here is consistent with existing patterns.
- No country-key-listing helper exists on `MapRecordValue` either; we can use
  `mapRecordValue.getValueMap().keySet()` directly.

**Proposed signature** on `SteuerMeldung`:

```java
/**
 * Returns the raw country-code keys present in the underlying record for the
 * given country-vector field, including entries whose value failed CSV-level
 * validation. Used by validators that want to flag invalid country codes
 * independently of the validity of their associated amounts.
 *
 * Returns an empty list if the field has no country-vector data.
 */
List<String> getRawCountryCodes(String fieldName);
```

`CsvSteuerMeldung` implementation:

```java
@Override
public List<String> getRawCountryCodes(String fieldName) {
    String actualFieldName = fieldName.endsWith(JE_ANTEIL_SUFFIX)
            ? fieldName.substring(0, fieldName.length() - JE_ANTEIL_SUFFIX.length())
            : fieldName;
    RecordValue recordValue = csvMessage.getRecordValue(actualFieldName);
    if (!(recordValue instanceof MapRecordValue mapRecordValue)) {
        return List.of();
    }
    return List.copyOf(mapRecordValue.getValueMap().keySet());
}
```

Other `SteuerMeldung` implementations (database-backed etc.) can default to
`List.of()` — they don't carry CSV-parse-failure context, so their country
vectors already match the country keys exactly.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldung.java`
  — add `List<String> getRawCountryCodes(String fieldName)` with a default
  empty-list implementation if the interface allows defaults (or add to all
  implementations otherwise).
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldung.java`
  — implement `getRawCountryCodes` using the existing `csvMessage` field and
  the `JE_ANTEIL_SUFFIX` logic already present in
  `extractCountryVectorMapValues`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java`
  — refactor `validateCountryVectorInputField` so that the `ERR_UNG_LAND`
  check uses `getRawCountryCodes`, and the deeper per-country validation
  continues to use `cv.getCountryCodes()` under the `if (cv != null)` branch.

## Verification

1. New unit test in
   `ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidatorsTest.java`:
   build a `SteuerMeldung` whose underlying CSV has a D row like the example
   above (BETRAG invalid, country code `"5,123456"`), invoke
   `validateCountryVectorInputField`, assert that the result contains
   `ERR_UNG_LAND` with `countryCode="5,123456"` and `recordType="D"`.
2. New integration test exercising the full pipeline through
   `CsvIfasMessageProcessor` for the misaligned row — asserts that both
   `ERR_ANZ_PARAM` and `ERR_UNG_LAND` end up on the message.
3. Existing tests must remain green:
   - the three `…WithForbiddenCountry…` cases in
     `SteuerMeldungErmittlungsvorgabeValidatorsTest` (lines 416-494)
   - `CsvIfasValidationTest.givenTooManyParameters_whenValidate_thenTooManyParametersErrors`
   - `CsvToValidationMsgCodeTest.ErrAnzParamTests`
4. `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm`
5. Optional manual smoke via `LocalH2OnlyIfasApplication`: upload a CSV with
   the misaligned D row and inspect the message-level validation output.
