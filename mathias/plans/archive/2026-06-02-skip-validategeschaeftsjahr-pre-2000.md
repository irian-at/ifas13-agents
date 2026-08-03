# Skip `validateGeschaeftsjahr` for pre-2000 START-row dates

## Context

`validateGeschaeftsjahr` in `SteuerMeldungDomainValidationService.java` currently has a TODO at lines 383–385 to "skip validations if gjBeginn is before year 2000". Investigation of the legacy CPP code (`Ifas/cprogs2/preise4/c_st_meldung.cpp`) shows:

- During CSV parsing (lines 1231, 1306, 1325, 1340) the CPP emits `ERR_UNG_DATUM` whenever any of the four START-row date fields (`Gj_beginn`, `Gj_ende`, `Meldezeitraum_beginn`, `Meldezeitraum_ende`) parses to a year < 2000.
- A pre-2000 `Gj_beginn` additionally fails `cStmVersion_modul::SetAkt_GjBeginn` (no FMVO version exists), causing the parsing function to `return -1` at line 1259. As a result `CheckStartRow()` (the function holding the GJ structural validations at lines 4480–5056) is never reached.
- So in legacy output, pre-2000 START-row dates produce only `ERR_UNG_DATUM` (+ `ERR_GET_VERSION` for the gjBeginn case). None of the GJ-structural messages (`ERR_GJ_BEG_ENDE`, `ERR_GJB_UNGLEICH*`, `ERR_GJE_*`, `ERR_GJ_MELDE_*`, `ERR_GJ_ZUKUNFT`, `ERR_MELDE_ZUKUNFT`, `ERR_GJ_FE_ZUKUNFT`, `ERR_GJ_BEG_ENDE_GJ`, etc.) appear.

The Java port already emits `ERR_UNG_DATUM` upstream of `validateGeschaeftsjahr`. To minimise legacy-diff while preserving generally useful feedback elsewhere, we will skip the entire `validateGeschaeftsjahr` body when any of the four START-row dates is pre-2000.

## Approach

In `SteuerMeldungDomainValidationService.validateGeschaeftsjahr` (line 344):

1. Keep the four `FieldValueWithPosition<LocalDate>` extractions where they are (lines 351–370).
2. After the extractions but **before** any validation call (i.e. before line 374), insert an early return that fires if any of the four field values is non-null and falls before `LocalDate.of(2000, 1, 1)`.
3. Remove the existing dead TODO block at lines 383–385.
4. Update the Javadoc above the method (lines 328–343) to note the pre-2000 short-circuit behaviour.

Sketch of the new guard (placed before line 374):

```java
if (isBeforeYear2000(stmGjBeginn)
        || isBeforeYear2000(stmGjEnde)
        || isBeforeYear2000(stmMeldezeitraumBeginn)
        || isBeforeYear2000(stmMeldezeitraumEnde)) {
    return List.of();
}
```

With a small private helper in the same class:

```java
private static boolean isBeforeYear2000(FieldValueWithPosition<LocalDate> field) {
    return field.value() != null && field.value().isBefore(LocalDate.of(2000, 1, 1));
}
```

Rationale for using all four fields rather than only `gjBeginn`: CPP emits `ERR_UNG_DATUM` for each of the four independently, and a single pre-2000 outlier among them already makes the date-comparison validations meaningless. Skipping the block uniformly matches the CPP outcome (no `CheckStartRow` messages) and keeps the Java method tidy.

The check is intentionally placed at the top of the method body, not after the CSV-only validators, because in CPP `CheckStartRow()` is never entered at all — meaning even the CSV-only checks would not run.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidationService.java`
  - method `validateGeschaeftsjahr` (line 344)
  - delete current TODO at lines 383–385
  - add helper `isBeforeYear2000` (private static, near `validateGeschaeftsjahr`)

No other production source needs touching. `SteuerMeldungDomainValidators` keeps its existing per-error helpers — we are only changing when they are called from `validateGeschaeftsjahr`.

## Verification

1. **Compile + unit tests** for the affected module:
   ```bash
   mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy
   ```
2. **Targeted assertions** — extend `SteuerMeldungDomainValidationServiceTest` (or whichever existing test exercises `validateGeschaeftsjahr`) with cases:
   - gjBeginn = 1999-12-31 → returns empty list, regardless of other field values
   - gjEnde = 1999-06-30 (gjBeginn = 2000-01-01) → returns empty list
   - meldezeitraumBeginn = 1995-01-01 → returns empty list
   - meldezeitraumEnde = 1990-01-01 → returns empty list
   - all dates ≥ 2000-01-01 → existing validation behaviour unchanged (smoke check with a known-bad case that should still emit `ERR_GJ_BEG_ENDE` etc.)
3. **Integration check** — run `QuickRecalculationTest` (already modified per `git status`) to confirm no regression on the realistic flow.
4. **Manual legacy-diff sanity check** — for a real STM file with a pre-2000 GJ start that previously emitted extra `ERR_GJ_*` messages from the Java port, confirm those messages now disappear and only the upstream `ERR_UNG_DATUM` remains.
