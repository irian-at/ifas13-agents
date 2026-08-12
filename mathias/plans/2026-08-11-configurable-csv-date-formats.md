# Configurable CSV date formats (input + output)

## Context

KAGs deliver Steuermeldung CSVs with varying date notations. The new system currently accepts only
three (`YYYYMMDD`, `YYYY.MM.DD`, `DD.MM.YYYY`) and rejects both dash forms with `ERR_UNG_DATUM`,
even though the legacy C++ app accepted them (`cADatum::GetDatum`, c_datum.cpp:2070, separator set
`. - : / ,`). We are therefore *stricter* than the system we replace.

Goal:
1. **Input** — accept `YYYY.MM.DD`, `YYYYMMDD`, `YYYY-MM-DD`, `DD.MM.YYYY`, `DD-MM-YYYY`.
2. **Output** — all written files (return / confirm / delete, plus the EStB report which shares the
   writer) use `YYYY.MM.DD`, made configurable with that as the default.

Decided up front: output is **always canonicalized** — the delivered notation is never echoed back,
regardless of what the KAG sent.

## Key finding

The input side is almost done already, in the wrong half of the code:

- `CsvTypeConversions.parseLocalDate` (`.../meldung/csv/CsvTypeConversions.java:25`) does
  `date.replace("-", ".")` before dispatching, so **it already parses all five formats**.
- `CsvIfasValueTypeValidator.DATE_PATTERN` (`.../meldung/csv/CsvIfasValueTypeValidator.java:26-30`)
  is the actual gate and rejects dashes — the parser is never reached.

So the input change is confined to the validator regex. `CsvTypeConversions` is deliberately left
alone: it is intentionally the more lenient layer (allows single-digit day/month, like legacy), and
tightening it would break direct callers such as `CsvSteuerMeldungen.getFailsafeLocalDate`.

## Change 1 — single source of truth for the supported formats

New enum `CsvIfasDateFormat` in `at.oekb.ifas.domain.stm.meldung.csv` (`ifas-domain-stm`). One constant
per supported format, each carrying its `DateTimeFormatter` pattern **and** its strict validation
regex, so the validator regex and the output whitelist stop being two hand-maintained lists:

```java
public enum CsvDateFormat {
    YYYYMMDD       ("yyyyMMdd",   YEAR + MONTH + DAY),
    YYYY_DOT_MM_DD ("yyyy.MM.dd", ymd("\\.")),
    YYYY_DASH_MM_DD("yyyy-MM-dd", ymd("-")),
    DD_DOT_MM_YYYY ("dd.MM.yyyy", dmy("\\.")),
    DD_DASH_MM_YYYY("dd-MM-yyyy", dmy("-"));

    // dateFormatter     = ofPattern(pattern)
    // dateTimeFormatter = ofPattern(pattern + " HH:mm:ss")   -> drives _END_TIMESTAMP

    public static final CsvDateFormat DEFAULT_OUTPUT = YYYY_DOT_MM_DD;
    public static String validationRegex();          // "|"-joined alternation, for the validator
    public static CsvDateFormat ofPattern(String p); // config lookup; IAE listing supported patterns
}
```

`YEAR`/`MONTH`/`DAY` move here from `CsvIfasValueTypeValidator` unchanged (still 4-digit year,
zero-padded 2-digit month/day). Building the regex per constant keeps separators consistent within
one value — `2024-04.15` stays invalid, unlike the parser's blanket `-`→`.` replace.

**`CsvIfasValueTypeValidator`** then becomes:

```java
private static final String DATE_PATTERN = "(?:" + CsvDateFormat.validationRegex() + ")";
```

`DATE_TIME` derives from `DATE_PATTERN` already (line 42), so `2024-04-15 10:30` starts working with
no further edit. Make `MONTH`/`DAY` non-capturing (`(?:...)`) while moving them — with five
alternatives the pattern would otherwise carry ten unused capture groups.

## Change 2 — configurable output format

`CsvValueFormatters` currently hardcodes both formatters
(`.../meldung/csv/CsvValueFormatters.java:17-18`). Reached through five layers of static
`@UtilityClass` calls, so the format is threaded as **overloads with the existing signatures
delegating to `CsvDateFormat.DEFAULT_OUTPUT`** — that keeps all ~40 existing call sites (tests, dev
tool, `RecalculationDomainService`) compiling untouched.

| File | Change |
|---|---|
| `.../meldung/csv/CsvValueFormatters.java` | `formatValue(v, type, CsvDateFormat)` / `formatDate(d, fmt)` / `formatDateTime(dt, fmt)`; existing arities delegate with the default |
| `.../meldung/csv/CsvSteuerMeldungenWriter.java` | new `private final CsvDateFormat outputDateFormat`; ctor overloads taking it, existing ctors (42, 46) pass the default; used at `extractAndFormatSingleRowField` (446) |
| `.../meldung/SteuerMeldungen.java` | overloads of `writeSteuerMeldungenToCsv` / `writeDelete…` / `writeConfirm…` (72/79/86) taking the format |
| `.../calc/CalculationOutputs.java` | thread through `writeBundleResultToZip` → `write` → `writeReturnCsv` / `writeDeleteCsv` / `writeConfirmCsv` (86-88, 100-142) |
| `.../recalc/RecalculationOutputs.java` | same through `writeBundleResultToZip` (106) / `write` (284, 293, 302) → the three CSV writers (363-418) |
| `.../isinanforderung/IsinAnforderungDomainService.java` | inject properties, pass to both writers (126-127) — EStB report shares the writer |
| `ifas-services/.../calc/StmCalcJobExecutionService.java` | inject properties; `writeResultToOutputStream` (205) becomes an instance method to reach them |
| `ifas-services/.../recalc/StmRecalcJobExecutionService.java` | inject properties, pass at the `writeBundleResultToZip` call (182) |

New `CsvOutputProperties` in `at.oekb.ifas.domain.stm.meldung.csv`, mirroring
`.../validation/StmValidationProperties.java` (`@Component @ConfigurationProperties @Getter @Setter
@NullMarked` — this project does *not* use `@ConfigurationPropertiesScan`):

```properties
# ========== STM CSV Output ==========
# Date notation for all written CSV files (return, confirm, delete, EStB report). _END_TIMESTAMP
# uses this pattern plus " HH:mm:ss". Must be one of the formats accepted on input, so a written
# return file can be read back (Recalc re-reads it). Altsystem: cADatum::SetFormat(1) = YYYY.MM.DD.
ifas.stm.csv.output.date-format=yyyy.MM.dd
```

Bound as a `String`, resolved via `CsvDateFormat.ofPattern` in a `@PostConstruct` so an unsupported
value fails at startup rather than mid-job. Declared explicitly in
`ifas-applications/ifas-main-application/src/main/resources/application.properties` next to the
existing `ifas.stm.*` block (lines 98-127).

## Behavioural consequences to expect

- `CsvSteuerMeldungenWriter:441-442` echoes back verbatim any value that **failed** CSV type
  validation. Dash dates stop failing, so they stop being echoed and get canonicalized — and the
  `ERR_UNG_DATUM` they produced disappears. Any bundle fixture delivering dash dates will show fewer
  errors and possibly a different STATUS. This moves us *toward* legacy, which accepted them.
- `RecalculationDomainService:427` writes a return CSV and immediately re-reads it. Safe because the
  configurable set is a subset of the accepted input set — enforced by `CsvDateFormat.ofPattern`.
- Out of scope (keep their own hardcoded patterns, per the chosen config scope): error/info/
  statistics logs (`ValidationMsgCode.DEFAULT_DATE_FORMAT_PATTERN`), Meldefonds lists, ISIN list
  entries, Ausschüttung export, `TypeCoercions`.
- Still not supported, and not requested: legacy's `/`, `:`, `,` separators and 2-digit years with
  the 70-pivot (`c_datum.cpp:2260`). Noting the residual gap, not closing it.

## Tests

- `CsvIfasValueTypeValidatorTest` (valid list line 182, invalid line 200): add `2024-12-15` and
  `15-12-2024` as valid; add `2024-04.15` (mixed separators) as invalid; `24-12-15` stays invalid.
- `CsvTypeConversionsTest` (`@ValueSource` lines 18, 70): add `15-04-2024`.
- New `CsvIfasDateFormatTest`: every constant round-trips pattern ↔ regex; `ofPattern` rejects an
  unsupported pattern.
- `CsvValueFormattersTest`: one case per non-default format.
- `CsvSteuerMeldungenWriterTest`: one case building the writer with a non-default format; existing
  assertions at lines 118 (`END;…;\d{4}\.\d{2}\.\d{2} …`) and 146 (`2023.12.31`) stay green because
  the default is unchanged.
- Integration: a Steuermeldung CSV fixture with `YYYY-MM-DD` and `DD-MM-YYYY` dates → import
  produces no `ERR_UNG_DATUM`, and the return file writes `yyyy.MM.dd`.

## Verification

```bash
mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am -DskipTests
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
    -Dtest='CsvIfasDateFormatTest,CsvIfasValueTypeValidatorTest,CsvTypeConversionsTest,CsvValueFormattersTest,CsvSteuerMeldungen*Test'
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Pskip-sybase16-tests
```

Then end-to-end via `LocalH2OnlyIfasApplication` (http://localhost:8080/ifas-uat): upload a bundle
with dash-formatted dates, confirm the error log is clean and the return/confirm/delete files carry
`YYYY.MM.DD`. Re-run with `ifas.stm.csv.output.date-format=dd.MM.yyyy` to confirm the property takes
effect on all three files, and with a bogus value to confirm startup fails fast.
