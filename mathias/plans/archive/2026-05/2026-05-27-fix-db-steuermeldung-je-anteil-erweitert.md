# Fix: DB-backed EStB report writes totals instead of "je Anteil" values

## Context — why this happens

In the erweitert EStB CSV, the last column of each value record is the **Betrag je Anteil** (amount per
share). It must equal `Betrag / Anzahl Anteile`. The new system instead writes the *total* amount:

```
neu:  E;Verlustvortrag_e;98881.89;71;98881.89          (wrong — total repeated at 8 NK)
alt:  E;Verlustvortrag_e;98881.89;71;29.11386371        (correct — 98881.89 / 3396.37)
```

The writer (`CsvSteuerMeldungenWriter.addColumnValueToLine`, case `"BETRAG_JE_ANTEIL"`, and the
country-vector / StB-vector paths) asks the meldung for the per-share value via
`steuerMeldung.getFieldValueErweitert(definedName, …)`. That contract is "return the erweitert
(per-share / 8-NK) value." Most implementations honor it:

- `ExcelSteuerMeldung` → `ErweitertValuesCalculations.calculateErweitertValue(this, …)`
- `AbstractFieldsOverridingSteuerMeldung` / `WrappedSteuerMeldung` → delegate to the same utility
- `CsvSteuerMeldung` → reads the pre-computed `_jeAnteil` / NK8 columns from the CSV

**Root cause:** the two DB-backed implementations short-circuit it and return the raw total:

- `EagerDbSteuerMeldung.getFieldValueErweitert` (`…/meldung/db/EagerDbSteuerMeldung.java:251`)
- `LazyDbSteuerMeldung.getFieldValueErweitert` (`…/meldung/db/LazyDbSteuerMeldung.java:261`)

both do `return getFieldValue(fieldName, type);`. The DB stores only totals, so no division ever
happens. `EstbReportService` builds an `EagerDbSteuerMeldung` for export, so the EStB output gets the
total in the je-Anteil column.

The correct logic already exists in
`…/domain/stm/ermittlung/ErweitertValuesCalculations.java`:
`calculateErweitertValue` → for `BigDecimal` and `CountryVector` it divides by
`steuerMeldung.getAnzahlAnteile()` unless `FieldSpec.jeAnteil()` is already true; for `StbVector` it
returns the raw value (scale-8 handled downstream). `getAnzahlAnteile()` (default in `SteuerMeldung`,
reads `Anteile_Tranche_Anzahl_e`) resolves correctly on the DB meldungen — `EagerDbSteuerMeldung` maps
`ANTEILE_TRANCHE_ANZAHL` to `SteuerMeldungEntity::getAnzahlAnteile`.

## Change

Make the DB-backed meldungen compute erweitert values like the other implementations, by reusing the
existing `ErweitertValuesCalculations`. Preferred (DRY) form — add a single default in the shared
interface and drop the two broken overrides:

In `…/meldung/db/DbSteuerMeldung.java` add:

```java
@Override
default <T> @Nullable T getFieldValueErweitert(String fieldName, Class<T> type) {
    return ErweitertValuesCalculations.calculateErweitertValue(this, fieldName, type);
}
```

Then **remove** the overriding `getFieldValueErweitert` methods from `EagerDbSteuerMeldung` (`:251-253`)
and `LazyDbSteuerMeldung` (`:261-263`) so they inherit the correct default.

(Equivalent alternative if a shared default is undesirable: replace the body of each of the two override
methods with the same `ErweitertValuesCalculations.calculateErweitertValue(this, fieldName, type)`
call. Same behavior, just not DRY.)

### Scope of the fix

This corrects the je-Anteil column for **all** erweitert value records sourced from the DB, not just
scalar "E" records: the country-vector records (`D`, `Z`, `ZA`, `AS`) compute their per-country
je-Anteil via `getFieldValueErweitert(…, CountryVector.class)` and were equally wrong. `StbVector`
("STB") behavior is unchanged (the utility returns the raw value, exactly as today), so no regression
there.

## Verification

1. Build: `mvn -q -pl ifas-domain/ifas-domain-stm compile -Pno-proxy`.
2. Re-run the EStB integration test (`EstbReportTest`, currently `@Disabled`, already pointed at
   `isin_test_01.zip`) and inspect
   `target/test-output/estbreport/isin_test_01/isin_test_01_EStB_erweitert#neu.csv`:
   - `E;Verlustvortrag_e;98881.89;71;…` last column must now be `29.11386371` (≈ `98881.89 / AnzahlAnteile`), not `98881.89`.
   - Spot-check a `D`/`Z` record: last column should be `Betrag / AnzahlAnteile`, not the raw total.
   - The `EStB#field-diff.txt` "Erweitert" section should lose the je-Anteil mismatches.
3. Confirm the **standard** file is unaffected (je-Anteil column stays empty there — `!erweitert` branch).
4. Quick unit-level check (optional): a focused test that builds an `EagerDbSteuerMeldung` with a known
   `Anteile_Tranche_Anzahl_e` and asserts `getFieldValueErweitert("Verlustvortrag_e", BigDecimal.class)`
   equals `total / anzahlAnteile`. Mirror the existing setup in
   `…/test/…/meldung/csv/CsvSteuerMeldungenWriterTest.java` (which already sets `ANTEILE_TRANCHE_ANZAHL`).

## Notes

- Reuses existing `ErweitertValuesCalculations` — no new calculation code (per the reuse rule). Searched
  `getFieldValueErweitert` implementations: only the two DB classes are broken; `Excel`/`Csv`/wrapper
  types are already correct.
- If `AnzahlAnteile` is null/zero for some meldung, `ErweitertValuesCalculations` throws
  `IllegalStateException`, which the writer's `BETRAG_JE_ANTEIL` branch already catches and turns into an
  empty column (existing behavior) — so the change degrades gracefully for bad data.
