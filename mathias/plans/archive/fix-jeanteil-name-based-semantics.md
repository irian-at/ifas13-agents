---
name: Fix jeAnteil to be name-based, matching legacy SQL
description: Revert commit bb142ad5's category-based `isJeAnteilField` and Mathias's a69636cc writer gate so that ERTRAEGE/DIVIDENDEN/etc. fields are correctly divided by `anzahlAnteile` for the BETRAG_JE_ANTEIL CSV column. Restore the original name-based predicate from 4fa87f72.
---

# Fix `jeAnteil` to Be Name-Based, Matching Legacy SQL

> **Note (post-review):** the originally-proposed signature `isJeAnteilField(String, boolean isStbField)` has been replaced with the simpler `isJeAnteilField(String definedName)` from commit `4fa87f72`, which detects STB-ness via `definedName.startsWith("StB_")`. See "History and what to revert" below.

## History and what to revert

Two prior commits jointly produced the current bug:

1. **`4fa87f72`** (2025-11-13, Manfred) — completed `jeAnteil` with the legacy SQL rule:
   ```java
   private static final Set<String> EXPLICIT_JE_ANTEIL_FIELD_NAMES = Set.of(
           "KESt_Satz", "Bemessungsgrundlage_Spekulation", "KoeSt_Satz"
   );
   static boolean isJeAnteilField(String definedName) {
       if (definedName.endsWith("_jeAnteil")) return true;
       if (definedName.startsWith("StB_"))   return true;
       return EXPLICIT_JE_ANTEIL_FIELD_NAMES.contains(definedName);
   }
   ```
   This is **identical** to the legacy SQL semantics Mathias confirmed.

2. **`a69636cc`** (2026-02-25, Mathias) — added try/catch + a `jeAnteil()` gate around `getFieldValueErweitert(...)` in the scalar CSV writer to recover from `IllegalStateException` for fields without an erweitert form. The try/catch is still wanted; the `jeAnteil()` gate became a problem because it suppresses the divided per-share value for ERTRAEGE-class fields.

3. **`bb142ad5`** (2026-04-28, Manfred) — refactored `isJeAnteilField` from name-based to `FieldCategory`-based ("Simplify ... Remove redundant `EXPLICIT_JE_ANTEIL_FIELD_NAMES`"). The named-set was *not* redundant — it was the legacy contract. This is the regression that broke the divide path.

The fix is essentially a targeted revert of the predicate change in `bb142ad5` plus removal of the writer gate added in `a69636cc`.

## Context

The new IFAS13 recalc currently emits the per-share column (`BETRAG_JE_ANTEIL`) as the un-divided total for ERTRAEGE / DIVIDENDEN / ZINSEN / ZINSEN_ALTEMISSIONEN / AUSSCHUETTUNGEN_SUBFONDS / STEUERLICHE_BEHANDLUNG fields. Concrete symptom in `QuickRecalculationTest` against the LLB issue:

```
expected (LLB_…_return.csv):       E;Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB;-7665.5897;534;-1.07391729
actual   (LLB_…_return#recalc.csv):E;Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB;-7665.5897;534;-7665.5897
```

The expected per-share value is `-7665.5897 / 7137.9703 ≈ -1.07391729`. The Java code does have a divide path (`ErweitertValuesCalculations.calculateJeAnteilValue:49-55`), but it is gated by `FieldSpec.jeAnteil()`, which today is set true for whole categories via `ExcelErmVorgabeVersionSpecs.isJeAnteilField(FieldCategory)` — so the divide branch is skipped for exactly the categories that need it.

The legacy (Altsystem) rule is name-based, not category-based. From the legacy SQL Mathias provided:

```sql
update steuer_fields set je_anteil = 'J'
  where steuer_name like '%_jeAnteil'
     or isnull(stb_field_id, 0) > 0
    and versions_nr = 6;

update steuer_fields set je_anteil = 'J'
  where steuer_name in ('KESt_Satz', 'Bemessungsgrundlage_Spekulation', 'KoeSt_Satz')
    and versions_nr = 6;
```

Translated:

```
je_anteil = 'J'  ⇔  name ends with "_jeAnteil"
              ∨   it is an STB field (stb_field_id > 0)
              ∨   name ∈ {KESt_Satz, Bemessungsgrundlage_Spekulation, KoeSt_Satz}
```

Everything else is `'N'` and must be divided by `anzahlAnteile` from the START record. The `else` branch in `ErweitertValuesCalculations.calculateJeAnteilValue` already implements that division — only the predicate feeding it is wrong.

The current category-based predicate was introduced by Manfred on 2026-04-28 (`bb142ad5 refactor: replace isJeAnteilField logic to use FieldCategory instead of definedName`). Restoring name-based semantics aligns the new code with the legacy DB definition and fixes the recalc diff.

## Scope

In scope:

- Replace `ExcelErmVorgabeVersionSpecs.isJeAnteilField(FieldCategory)` with a name-based predicate.
- Update the eight `FieldSpec` construction sites that pass `jeAnteil` (`ErtraegeFieldSpecs`, `AusschuettungenFieldSpecs`, `AufwandUndVerlustverteilungFieldSpecs`, `SteuerlicheBehandlungFieldSpecs` ×2, `CountrySpecificFieldSpecs` ×3).
- Decouple `getFieldOutputType`'s STANDARD/EXTENDED decision from `isJeAnteilField` so that ERTRAEGE-class rows still appear in non-erweitert output.
- Drop the `&& fieldSpecByName.jeAnteil()` gate in the scalar CSV writer so `BETRAG_JE_ANTEIL` is filled in erweitert mode for divided fields too.
- Verify against `QuickRecalculationTest` for the LLB issue.

Out of scope:

- Changing the conditional in `ErweitertValuesCalculations.calculateJeAnteilValue`. Its semantics ("`jeAnteil()=true` ⇒ value already per-share, return as-is; else divide") is correct under the legacy interpretation.
- Country-vector writer path (`CsvSteuerMeldungenWriter.java:407-414`) — already gated on `erweitert && countryVectorJeAnteil != null`, not on `jeAnteil()`. No change needed.
- Database `je_anteil` column / Flyway migrations — the new system does not persist this flag the same way; field specs are derived at runtime from the BMF Excel template.
- Renaming `FieldSpec.jeAnteil` or restructuring `FieldCategory`. The flag's *meaning* doesn't change (it still marks "value is already per-share"); only the rule that decides its value changes.

## Approach

### 1. Restore the name-based predicate from 4fa87f72

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmVorgabeVersionSpecs.java:178-184`

Replace:

```java
static boolean isJeAnteilField(FieldCategory fieldCategory) {
    return switch (fieldCategory) {
        case AUFWAND_UND_VERLUST, ERTRAEGE, DIVIDENDEN, ZINSEN, ZINSEN_ALTEMISSIONEN,
             AUSSCHUETTUNGEN_SUBFONDS, STEUERLICHE_BEHANDLUNG -> true;
        default -> false;
    };
}
```

with the original predicate from `4fa87f72`:

```java
private static final Set<String> EXPLICIT_JE_ANTEIL_FIELD_NAMES = Set.of(
        "KESt_Satz",
        "Bemessungsgrundlage_Spekulation",
        "KoeSt_Satz"
);

static boolean isJeAnteilField(String definedName) {
    if (definedName.endsWith("_jeAnteil")) {
        return true;
    }
    if (definedName.startsWith("StB_")) {
        return true;
    }
    return EXPLICIT_JE_ANTEIL_FIELD_NAMES.contains(definedName);
}
```

Notes on this exact form:

- Single string parameter — no extra `isStbField` boolean. STB-ness is detected by the `"StB_"` prefix on the defined name, which is a stable convention enforced throughout the codebase.
- The `EXPLICIT_JE_ANTEIL_FIELD_NAMES` set mirrors the legacy SQL `IN (...)` list verbatim. Promoting these names to `FieldName` constants is a separate cleanup, out of scope.
- This restores `4fa87f72` exactly. We are reverting the predicate part of `bb142ad5`.

### 2. Restore the `ExcelErmVorgabeVersionSpec` interface default

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmVorgabeVersionSpec.java:69-71`

Replace:

```java
default boolean isJeAnteilField(FieldCategory fieldCategory) {
    return ExcelErmVorgabeVersionSpecs.isJeAnteilField(fieldCategory);
}
```

with the original (single-arg) form:

```java
default boolean isJeAnteilField(String definedName) {
    return ExcelErmVorgabeVersionSpecs.isJeAnteilField(definedName);
}
```

V4/V5/V6 versions all rely on this default — none override it (verified during exploration). No subclass changes required.

### 3. Restore the eight `FieldSpec` construction sites to pass `definedName`

This is a pure revert of the eight `bb142ad5` hunks:

| File | Line | Replace `spec.isJeAnteilField(fieldCategory)` with |
|---|---|---|
| `ErtraegeFieldSpecs.java` | 170 | `spec.isJeAnteilField(definedName)` |
| `AusschuettungenFieldSpecs.java` | 122 | `spec.isJeAnteilField(definedName)` |
| `AufwandUndVerlustverteilungFieldSpecs.java` | 138 | `spec.isJeAnteilField(definedName)` |
| `SteuerlicheBehandlungFieldSpecs.java` | 133 | `spec.isJeAnteilField(definedName)` |
| `SteuerlicheBehandlungFieldSpecs.java` | 215 | `spec.isJeAnteilField(definedName)` |
| `CountrySpecificFieldSpecs.java` | 182 | `spec.isJeAnteilField(definedName)` |
| `CountrySpecificFieldSpecs.java` | 245 | `spec.isJeAnteilField(definedName)` |
| `CountrySpecificFieldSpecs.java` | 400 | `spec.isJeAnteilField(definedName)` |

`definedName` is locally available at every call site (`ErtraegeFieldSpecs:60`, etc.). For the StbVector wrapper at `SteuerlicheBehandlungFieldSpecs:215`, the previous version called `spec.isJeAnteilField(definedName)` (verified in the `bb142ad5` diff) — that vector's defined name starts with `StB_` so the predicate returns `true`. Aligned with the legacy `stb_field_id > 0` rule.

### 4. Decouple `getFieldOutputType` from `isJeAnteilField`

`ExcelErmVorgabeVersionSpecs.java:186-208` currently contains:

```java
if (isJeAnteilField(fieldCategory)) {
    return FieldSpec.OutputType.STANDARD;
} else {
    return FieldSpec.OutputType.EXTENDED;
}
```

Pre-`bb142ad5` this conflated two unrelated concerns: "is the value already per-share?" (now name-based) and "should this row appear in non-erweitert output?" (category-based, used by reports other than the recalc-return file). In the new system every recalc-result CSV is written with `erweitert=true`, so STANDARD vs EXTENDED is irrelevant to that path; STANDARD output exists for *other reports* and that capability must be preserved with the wider category-based set introduced in `bb142ad5`.

Replace with a separate, category-based predicate:

```java
if (isStandardOutputCategory(fieldCategory)) {
    return FieldSpec.OutputType.STANDARD;
} else {
    return FieldSpec.OutputType.EXTENDED;
}
```

with helper:

```java
private static boolean isStandardOutputCategory(FieldCategory fieldCategory) {
    return switch (fieldCategory) {
        case ERTRAEGE, DIVIDENDEN, ZINSEN, ZINSEN_ALTEMISSIONEN,
             AUSSCHUETTUNGEN_SUBFONDS, STEUERLICHE_BEHANDLUNG -> true;
        default -> false;
    };
}
```

`AUFWAND_UND_VERLUST` is already short-circuited to `NONE` higher in the same method (`:199-202`), so it doesn't appear here. The set is exactly the one `bb142ad5`'s `isJeAnteilField(FieldCategory)` enumerated minus that one category — net STANDARD output unchanged for the post-`bb142ad5` behaviour Mathias confirmed is needed for non-recalc reports.

This decoupling also lines up cleanly with the conceptual model: `jeAnteil` describes the *value semantics* (already-per-share or not), while `OutputType` describes the *report inclusion policy* — they're independent and should not share a predicate.

### 5. Remove the `jeAnteil()` gate in the scalar writer (revert most of `a69636cc`)

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenWriter.java:282-303`

This drops the predicate gate Mathias added on 2026-02-25 to work around `IllegalStateException` from `getFieldValueErweitert`. With name-based `jeAnteil` in place plus the divide branch in `ErweitertValuesCalculations`, every numeric field now has a meaningful per-share value (either pre-divided or computed), so the gate is no longer needed. The try/catch around `getFieldValueErweitert` is preserved as a safety net — same null-handling as today.

Current:

```java
case "BETRAG_JE_ANTEIL" -> {
    if (!erweitert) {
        lineValues.add("");
    } else {
        try {
            FieldSpec fieldSpecByName = steuerMeldung.getErmittlungsvorgabe()
                    .getFieldSpecByName(definedName);
            if (fieldSpecByName != null && fieldSpecByName.jeAnteil()) {
                BigDecimal fieldValueErweitert = steuerMeldung.getFieldValueErweitert(
                        definedName,
                        BigDecimal.class
                );
                lineValues.add(formatAmount8NK(fieldValueErweitert));
            } else {
                lineValues.add("");
            }
        } catch (IllegalStateException ignored) {
            log.warn("No erweitert field found for {}. Skipping.", definedName);
            lineValues.add("");
        }
    }
}
```

Replace with:

```java
case "BETRAG_JE_ANTEIL" -> {
    if (!erweitert) {
        lineValues.add("");
    } else {
        try {
            BigDecimal fieldValueErweitert = steuerMeldung.getFieldValueErweitert(
                    definedName,
                    BigDecimal.class
            );
            lineValues.add(formatAmount8NK(fieldValueErweitert));
        } catch (IllegalStateException ignored) {
            log.warn("No erweitert field found for {}. Skipping.", definedName);
            lineValues.add("");
        }
    }
}
```

The lookup of `FieldSpec` and the `jeAnteil()` gate are gone. `getFieldValueErweitert` itself returns the right value:

- For `_jeAnteil`-suffixed fields, STB fields, or the three explicit names → `jeAnteil=true` → `ErweitertValuesCalculations` returns the value as-is (already per-share).
- For everything else → `jeAnteil=false` → divides by `anzahlAnteile`.

For SteuerMeldung impls that bypass `ErweitertValuesCalculations` (`CsvSteuerMeldung`, `EagerDbSteuerMeldung`, `LazyDbSteuerMeldung`), nothing changes — they read the per-share value directly from their CSV column / DB column.

### 6. No change required in `ErweitertValuesCalculations`

The conditional at `ErweitertValuesCalculations.java:49-55` (BigDecimal) and `:70-79` (CountryVector) already does the correct thing under the legacy interpretation:

```java
if (fieldSpec.jeAnteil()) {
    return amount;                          // already per-share
} else {
    return amount.divide(anzahlAnteile, IFAS_MATH_CONTEXT);  // divide
}
```

The only reason it produced wrong output today is that `jeAnteil()` was set true for ERTRAEGE category fields. With the new name-based predicate, ERTRAEGE fields like `Ausschuettung_e` will have `jeAnteil()=false` and fall into the divide branch. The `_jeAnteil`-suffixed fields keep `jeAnteil()=true` and are returned as-is, exactly as the legacy SQL prescribes.

### 7. Country-vector path — sanity check, no change

`CsvSteuerMeldungenWriter.java:355-414` reads the per-country per-share values via `getFieldValueErweitert(...)` whenever `erweitert=true`, with no `jeAnteil()` gate. The values come from the same `ErweitertValuesCalculations` for non-CSV/non-DB SteuerMeldung impls, so they will be divided correctly with the new flag. No code change needed; will verify by examining `_return#recalc.csv` country-vector rows after the patch.

## Affected files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmVorgabeVersionSpecs.java` — predicate signature, `EXPLICIT_JE_ANTEIL_FIELD_NAMES`, decoupled `getFieldOutputType`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmVorgabeVersionSpec.java` — interface default signature.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ErtraegeFieldSpecs.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/AusschuettungenFieldSpecs.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/AufwandUndVerlustverteilungFieldSpecs.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/SteuerlicheBehandlungFieldSpecs.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/CountrySpecificFieldSpecs.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungenWriter.java`

No persistence/migration files touched. No test resources renamed.

## Verification

### Unit tests

- `mvn -pl ifas-domain/ifas-domain-stm test -Dtest='*FieldSpec* + *ErweitertValues* + *CsvSteuerMeldungenWriter*' -Pno-proxy`
- Specifically run `ErmittlungsvorgabenTest` (touches KESt_Satz, KoeSt_Satz at lines 119/130) to confirm those fields still resolve.
- `CsvSteuerMeldungenWriterTest` was the test file modified in the original `ErweitertValuesCalculations` introduction commit (`46bd58f6`); re-running it catches regressions in the column-emission contract.

### Integration test

- Run `QuickRecalculationTest.givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem` on the LLB issue resources (`@Disabled` today; un-disable locally).
- Inspect `target/quick-recalc/LLB_2026-05-05_141043750_return#recalc.csv` and confirm:
  - `Ausschuettung_e` row: `…;3568.98;24;0.49999928` (was `…;3568.98;24;3568.98`).
  - `Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB` row: `…;-7665.5897;534;-1.07391729` (was `…;-7665.5897;534;-7665.5897`).
  - For at least one `_jeAnteil` country-vector row (e.g. `Z_Zinsen_erstattbareQuSt_jeAnteil`, if present): BETRAG and BETRAG_JE_ANTEIL match — no double-division.
- Confirm `error#diff-deviations.txt` shrinks (or the relevant deviations disappear).

### Targeted full build

- `mvn -Pno-proxy clean install` after the patch to surface any compile breakages from the signature change.

## Risks and mitigations

- **Risk:** another caller passes `FieldCategory` to `isJeAnteilField` somewhere outside the eight known sites.
  - **Mitigation:** the signature change forces a compile error at every caller. `mvn clean install -Pno-proxy` will fail loudly.
- **Risk:** an STB-related field in the codebase doesn't follow the `StB_` naming convention.
  - **Mitigation:** the `StB_` prefix has been a stable convention since at least the original commit; the predicate originally shipped this way for ~5 months without issue. Worth a quick `grep "StB_"` sweep on test data, but no edits expected.
- **Risk:** dropping the writer's `jeAnteil()` gate emits BETRAG_JE_ANTEIL for fields that previously had no per-share representation, surprising downstream consumers.
  - **Mitigation:** for fields without an erweitert value, `getFieldValueErweitert` returns `null`, which `formatAmount8NK` formats as the empty string — same as today. The `IllegalStateException` catch retains the "skip and warn" behaviour from `a69636cc`.
- **Risk:** the new `isStandardOutputCategory` set drifts from the old `isJeAnteilField(FieldCategory)` set.
  - **Mitigation:** the helper enumerates exactly the same five categories `bb142ad5` had as `true` (ERTRAEGE, DIVIDENDEN, ZINSEN, ZINSEN_ALTEMISSIONEN, AUSSCHUETTUNGEN_SUBFONDS, STEUERLICHE_BEHANDLUNG) minus `AUFWAND_UND_VERLUST` which is already `NONE`. No behaviour change for STANDARD-classified rows in non-erweitert reports.
- **Risk:** the change conflicts with intent behind Manfred's `bb142ad5` (2026-04-28).
  - **Mitigation:** since this is essentially a revert of his own earlier `4fa87f72`, mention both commits in the PR. The legacy SQL Mathias provided is unambiguous, so any disagreement is a discussion to have with reference to the legacy DB definition. Pinging Manfred is friendly but not blocking.

## Rollout

1. Implement steps 1-5 in a single commit (atomic for compile correctness).
2. Run unit + integration tests locally; iterate until LLB recalc matches expected output.
3. Push to a feature branch and open a PR mentioning the legacy SQL as the source of truth.
4. Mention to Manfred in PR description so he can flag any category-based intent that needs a separate accommodation.