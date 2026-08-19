# Fix Excel date round-trip NPE in `Workbooks`

## Context

`QuickRecalculationTest` crashes with:

```
NullPointerException: Cannot invoke "java.time.LocalDateTime.toLocalDate()" because the return
value of "org.apache.poi.ss.usermodel.DateUtil.getLocalDateTime(double)" is null
    at at.oekb.ifas.xlssupport.Workbooks.toLocalDate(Workbooks.java:557)
    ...
    at RecalculationDomainService.getPrefilledExcelSteuerMeldungen(RecalculationDomainService.java:546)
```

**This is not caused by a recent commit.** Every line in the failing path dates from 2025-11 … 2026-06;
the only working-tree change is `STICHTAG` 2026-08-04 → 2026-07-27. What changed is the input bundle.

### Root cause

`Workbooks` contains an asymmetric conversion pair — it writes a value it cannot read back:

| Direction | Call | Result for `1899-12-30` |
|---|---|---|
| write | `toExcelNumber` → POI `DateUtil.getExcelDate` | returns the `BAD_DATE` sentinel **`-1.0`** (year < 1900), silently |
| read | `toLocalDate` → POI `DateUtil.getLocalDateTime` | returns **`null`** for `-1.0` (`isValidExcelDate` is `value > -Double.MIN_VALUE`) |

`Workbooks.java:557` dereferences that `null` unconditionally.

Concretely for this bundle: the input CSV carries `GJ_Beginn = GJ_Ende = 18991230`. The recalc wrote a
prefilled Excel for it; sheet *"Erträge"* cells **D22**/**D23** (*Geschäftsjahr Beginn* / *Geschäftsjahr Ende*)
literally contain `<v>-1.0</v>`. The zip in `quick-recalc/` is a *recalc output* bundle, so that
`...#recalc.xlsx` is fed back in as a `PREFILLED_EXCEL_FILE` (deliberate — `SteuerMeldungBundles.java:621-624`),
and reading D23 back blows up.

### Why the fix belongs in `xls-support`, not in the domain

The pre-2000 rule is domain logic, it already lives in the right place
(`CsvSteuerMeldungValidations.validateDate`, `MIN_VALID_YEAR = 2000`), and it already raises the correct
`ERR_UNG_DATUM`. Nothing about it should move into parsing.

The crash is independent of that rule: **any** pre-1900 date, from any workbook, on any code path that
reads a date cell, hits the same NPE. And the whole downstream chain is *already* null-tolerant —
`TypeCoercions.coerce` (`@Nullable`, `@Contract("null,_ -> null")`), `SteuerMeldung.getGjEnde()`
(`@Nullable`), `LieferungStmKey.gjEnde` (`@Nullable`), and `getPrefilledExcelSteuerMeldungen` even has a
skip branch for a null key. `Workbooks.java:557` is the single line that isn't.

## Changes

### 1. `support-libs/xls-support/.../Workbooks.java` — make the pair symmetric

**Read side** (`:556-562`) — return `null` instead of dereferencing POI's `null`:

```java
public static @Nullable LocalDate toLocalDate(double value) {
    LocalDateTime localDateTime = DateUtil.getLocalDateTime(value);
    return localDateTime != null ? localDateTime.toLocalDate() : null;
}

public static @Nullable LocalDateTime toLocalDateTime(double value) {
    return DateUtil.getLocalDateTime(value);
}
```

`toLocalDateTime` already returns POI's value unchanged and could always return `null` — its non-null
signature was simply wrong. `getCellValueAsLocalDateTime` (`:591-593`) needs no change: `Optional.map`
collapses `null` to empty.

**Write side** (`:583-589`, `setCellValue(Cell, Object)`) — never write the sentinel into a cell:

```java
case LocalDate v -> {
    double excelNumber = toExcelNumber(v);
    // POI yields BAD_DATE (-1) for years < 1900, which reads back as no date at all
    if (DateUtil.isValidExcelDate(excelNumber)) {
        cell.setCellValue(excelNumber);
    } else {
        cell.setBlank();
    }
}
```

Blank rather than throwing: `ExcelSteuerMeldungPopulator.writeFieldValueToExcelCell:66-68` wraps every
write failure in an `IllegalStateException`, which would abort the whole recalc on one garbage input
field — wrong trade-off for a tool whose job is to process whatever production delivered. Blank makes
the round-trip honest: unrepresentable date → blank cell → `null` on read.

### 2. `ifas-domain-stm/.../core/TypeCoercions.java` — allow the `LocalDate` case to yield null

`coerceFromNumber` (`:67`) is declared non-null; add `@Nullable` to the return so `:74` can propagate
`null`. `coerce` (`:26`) is already `@Nullable`, so no caller contract changes.

### 3. Check the JSpecify fallout

Only three call sites exist (`grep` verified):
- `TypeCoercions.java:74` — handled by change 2
- `ExcelSteuerMeldungPopulatorTest.java:82` — inside `Optional.map(Workbooks::toLocalDate)`, already safe
- `Literal.java:23` / `DateFunctionOpHandler.java:42` — `toExcelNumber` only, unaffected

## Known consequence (accept, or handle separately)

With GJ_Ende reading back as `null`, the prefilled Excel's key becomes
`LieferungStmKey(LU2561047924, true, null, false)` while the CSV meldung's key is
`(…, 1899-12-30, false)`. They no longer match, so the prefilled Excel gets its own entry in `allKeys`
and shows up as a phantom "prefilled-Excel-only" row in the diff.

This is cosmetic for a meldung that is already `STATUS;ERROR` in both systems. If it turns out to be
noisy, the follow-up is to skip the prefilled-Excel comparison for meldungen that failed validation —
deliberately **not** in scope here.

## Tests

**`support-libs/xls-support/src/test/java/at/oekb/ifas/xlssupport/WorkbooksTest.java`** (extend; currently
one test) — given-when-then naming, AssertJ, per `testing-conventions.md`:

- `givenPre1900Date_whenToExcelNumber_thenReturnsBadDateSentinel` — pins POI's `-1.0` so the premise is
  documented rather than assumed
- `givenBadDateSentinel_whenToLocalDate_thenReturnsNull` — the regression gate for the NPE
- `givenPre1900Date_whenSetCellValue_thenCellIsBlank`
- `givenOrdinaryDate_whenRoundTripped_thenValueIsPreserved` — e.g. `2025-09-14` ↔ `45914.0`, guards
  against the null-safety change masking a real conversion break

## Verification

```bash
mvn test -Pno-proxy -pl support-libs/xls-support
mvn clean install -Pno-proxy -pl support-libs/xls-support,ifas-domain/ifas-domain-stm
```

Then re-run `QuickRecalculationTest.givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
(remove `@Disabled`) against the unchanged bundle
`20260727_123124_189912_LU2561047924_JM_1620155#recalc.zip`. Expected: no NPE, run completes, output in
`ifas-testing/ifas-integration-tests/target/quick-recalc`.

Sanity-check the written prefilled Excel — sheet *"Erträge"* cells D22/D23 must now be blank instead of
`-1.0`:

```bash
python3 -c "
import zipfile,re
x=zipfile.ZipFile('<written>.xlsx')
s=x.read('xl/worksheets/sheet2.xml').decode()
print([c for c in re.findall(r'<c r=\"D2[23]\".*?</c>', s, re.S)])
"
```
