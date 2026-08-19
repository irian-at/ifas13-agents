# Close the CSV valueType drift: validator keys off the enum

## Context

`CsvIfasValueType` and `CsvIfasValueTypeValidator` both live in `at.oekb.ifas.domain.core.csv` now,
but they describe the same vocabulary twice — the enum as constants, the validator as `String` map
keys — and they have already diverged:

| | contents |
|---|---|
| `CsvIfasValueType` | 14 constants |
| `CsvIfasValueTypeValidator.TYPE_PATTERNS` | 17 keys — the same 14 **plus** `PREIS_MELDEKATEGORIE`, `PREIS_AKTION`, `PREIS_PERIODIZITAET` |
| `AUSSCHUETTUNG_OUTPUT-LIEFERFORMAT_2018-03-19.csv-schema.yml:24` | declares `valueType: TIME` — in **neither** |

An unknown `valueType` throws `IllegalArgumentException("No pattern found for type: …")` at parse
time, so a typo in a schema is a production failure, not a build failure. The `TIME` case is only
harmless because that schema is never passed to `CsvSchemas.loadCsvSchema` — the Ausschüttung output
file is hand-written by `AusschuettungExportDomainService`.

Goal: make the enum the single source of truth, so a schema `valueType` that is not a constant fails
loudly and consistently.

## Step 1 — complete the enum

Add to `CsvIfasValueType`:

- `PREIS_MELDEKATEGORIE`, `PREIS_AKTION`, `PREIS_PERIODIZITAET` — the validator already has their
  patterns
- `TIME` — `FILE_TIME` ("Time of file creation", sibling of `FILE_DATE`) is a real time-of-day field,
  so this is a genuinely missing type rather than a typo. The validator already has the
  `TIME_PATTERN` fragment (`HH:mm[:ss]`) it uses inside `DATE_TIME`; register it as its own pattern.
  `CsvTypeConversions` needs a small `parseLocalTime` to match.

## Step 2 — validator resolves keys through the enum

In `CsvIfasValueTypeValidator`, key `TYPE_PATTERNS` on `CsvIfasValueType` instead of `String`, and
resolve the incoming string once at the entry point. The `String` stays at the API boundary either
way, because `CsvValueTypeValidator.validate(String valueType, …)` is defined in `csv-schema`.

Keep the failure mode explicit: an unresolvable name should still throw with the type name in the
message, so the diagnostic does not get worse.

## Step 3 — the `CsvTypeCoercions` problem

`CsvTypeCoercions` is in `ifas-domain-stm` (it maps to five `ifas-persistence-stm` enums) and its
`switch` over `CsvIfasValueType` is **exhaustive with no default**. Adding four constants therefore
breaks its compile — and adding `PREIS_*` arms there would put Preismeldung back into an STM class,
which is exactly what the module split removed.

**Resolution: give that switch a `default -> throw` and do not name the new constants in it.**
Preismeldung has no write path, so there is nothing to coerce; `TIME` likewise has no writer. This
trades compile-time exhaustiveness for module separation — recover the safety net with a test in
`ifas-domain-stm` that iterates `CsvIfasValueType.values()` and asserts each constant either coerces
or throws the expected "unsupported" error, deriving the expected-unsupported set from the name
(anything `PREIS_*`, plus `TIME`). That keeps a missed *STM* value type failing loudly without
mentioning Preismeldung in production code.

Note `CsvTypeCoercions.VALUE_TYPE_TO_CLASS` will also lack entries for the new constants, so
`getJavaTypeForCsvValueType` throws for them. That is correct and unreachable today (only the STM
writer calls it, and it never sees those types) — worth a one-line comment, not a fix.

`CsvValueFormatters` is in core, so its arms for the new constants are fine: treat `PREIS_*` as text
alongside `TEXT`, and give `TIME` a `LocalTime` arm.

## Step 4 — enforce it repo-wide

`PreismeldungCsvSchemaTest#givenEveryDeclaredValueType_whenValidate_thenPatternIsRegistered` already
does this check for one schema. Generalise it: a test that discovers every `*.csv-schema.yml` on the
classpath, loads it, and asserts every declared `valueType` resolves to an enum constant. That is the
test that would have caught `TIME`, and it is the guard that keeps the enum authoritative.

`at.oekb.ifas.core.io.Resources#findResourcesInClasspathFolder` already exists for the discovery.
Six schemas exist today, spread across `ifas-domain-stm` and `ifas-domain-fondspreise`, so the test
belongs wherever both are visible — `ifas-integration-tests` is the only module that sees both.

## Verification

```bash
mvn -Pno-proxy -o -pl support-libs/core-support,ifas-domain/ifas-domain-core,ifas-domain/ifas-domain-stm,ifas-domain/ifas-domain-fondspreise -am test
mvn -Pno-proxy -Pdev-build -o clean install -DskipTests
```

Baseline to hold: `ifas-domain-core` 291, `ifas-domain-stm` 1265, `ifas-domain-fondspreise` 46,
`core-support` 113 — all passing, full reactor green.

Always pass `-am`: the `xls-support` jar in `~/.m2` is stale and lacks `Workbooks.isBlank(Cell)`, so
`-pl` without it fails to compile `SteuerlicheBehandlungFieldSpecs`.

## Deliberately out of scope

Splitting `CsvTypeCoercions` into a generic half (core) and an STM-enum half (stm). The defaulted
switch plus the guard test in step 3 solves the immediate problem; the split only becomes worthwhile
if Fondspreise gains a write path and actually needs coercion.
