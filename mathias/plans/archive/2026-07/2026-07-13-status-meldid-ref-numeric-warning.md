# Mark STATUS "Melde-ID vorherige Meldung" numeric-invalid as warning when only-in-new

## Context

In the legacy-vs-new recalc delta report, a deviation shows up as `NUR IM NEUSYSTEM (FEHLER)`:

```
Zeile-Nr: 39 | STATUS;UPDATE;649565;03.08.2026
ERROR! Das numerische Feld <Melde-ID vorherige Meldung> im Satz <STATUS> hat den ungueltigen Wert <03.08.2026>.
```

Column 3 of the `STATUS` record (`_STATUS_MELDUNGS_ID_REF` → display name "Melde-ID vorherige Meldung") is typed `NUMBER`, but the delivery carries a **date** (`03.08.2026`) there. The new system's CSV value-type validator rejects it (`^[+-]?\d+$`) and `ValidationMsgMapper.mapValueTypeError` maps it to `ERR_UNG_NUMMER` / `Severity.ERROR`. Legacy tolerated this field and emitted nothing, so it lands as a new-only **error** in the delta report.

This is new-system-stricter-by-design for this specific field, not a regression. We want it classified as a **warning** when it appears only in the new system, so it stops counting as a hard deviation in the recalc baselines.

**Decisions (confirmed with user):**
- **Scope:** field-specific — only `ERR_UNG_NUMMER` on the `_STATUS_MELDUNGS_ID_REF` field. Do *not* downgrade every `ERR_UNG_NUMMER` (that would silence numeric strictness gaps on other fields).
- **Trigger:** unconditional (always) — no new `ValidationSetting` opt-in flag.
- **Shape:** build a **reusable (code, field) rule set**, not a one-off predicate. Adding a future case = one more entry in the set.

## Change

All in the only-in-new classification path; the summary counts (`calculateSummary`) reuse the same predicate, so they stay consistent automatically.

### `ValidationDeltaReports.java`
(`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaReports.java`)

A field-specific rule cannot be expressed in the existing code-only `Set<ValidationMsgCode>` (those match code only, field-agnostic). Introduce a small **(code, field)** rule type and a set of such rules — the reusable instrument — alongside the existing `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW`:

The rule carries a **code, field-argument-index, and field** — the index because the field's
position in the arguments is code-specific (`ERR_UNG_NUMMER` at `{0}`, but `_L` variants at
`{0},{1}` and `ERR_STATUS_UNGUE` not at `{0}`).

```java
/**
 * (code, field) rules always shown as warnings when only in the new system, for cases where
 * the new system is stricter on a specific field than legacy. The field's argument index is
 * code-specific, so each rule states its own index.
 */
private static final Set<CodeAndField> CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW = Set.of(
        // date in the numeric STATUS ref field (Melde-ID vorherige Meldung), which legacy tolerated
        new CodeAndField(ERR_UNG_NUMMER, 0, SteuerMeldung.FieldName.STM_ID_REF)
);

private record CodeAndField(ValidationMsgCode code, int fieldArgIndex, String fieldDefinedName) {}
```

Call it from `isShowAsWarningIfOnlyInNew` (line 167-174), after the existing code-set check:

```java
if (matchesCodeFieldWarningRule(msg)) {
    return true;
}
```

Helper — each rule tests its own field-argument index:

```java
private static boolean matchesCodeFieldWarningRule(ValidationMsg msg) {
    ValidationMsgCode code = msg.getValidationMsgCode();
    Object[] args = msg.getArguments();
    return CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW.stream().anyMatch(rule ->
            rule.code() == code
                    && rule.fieldArgIndex() < args.length
                    && args[rule.fieldArgIndex()] instanceof FieldName fieldName
                    && rule.fieldDefinedName().equals(fieldName.definedName()));
}
```

Add imports: `at.oekb.ifas.domain.stm.meldung.SteuerMeldung` and `at.oekb.ifas.domain.stm.validation.FieldName` (`ERR_UNG_NUMMER` is already covered by the existing `import static ...ValidationMsgCode.*`).

Only the only-in-new side changes. The only-in-legacy predicate (`isShowAsWarningIfOnlyInLegacy`) is untouched: this deviation is new-only by nature (legacy never emits it), so there is no legacy pattern to mirror.

### Key facts relied on (verified)
- `ValidationMsgMapper.mapValueTypeError` (`ValidationMsgMapper.java:134-141`): `NUMBER` value-type errors → `ERR_UNG_NUMMER`, args `[FieldName, recordType, value]`.
- `FieldName.definedName()` returns the raw field key; `SteuerMeldung.FieldName.STM_ID_REF == "_STATUS_MELDUNGS_ID_REF"` (`SteuerMeldung.java:49`); display name mapped in `FieldNameResolver.java:22`.
- `ERR_UNG_NUMMER` and `ERR_NOT_NUMMER` share the same message text but only `ERR_UNG_NUMMER` is emitted by the value-type path — targeting `ERR_UNG_NUMMER` is correct and precise.

## Test

Add a unit test in `ValidationDeltaReportWriterDeviationsOnlyTest`
(`ifas-domain/ifas-domain-stm/src/test/java/.../delta/ValidationDeltaReportWriterDeviationsOnlyTest.java`) following the existing `newMsg(...)` / `writeDeviationsOnly(...)` helpers:

- Build a new-only `ValidationMsg` with `ERR_UNG_NUMMER` and `arguments = [FieldName.of("_STATUS_MELDUNGS_ID_REF"), "STATUS", "03.08.2026"]`.
- Assert it renders under `NUR IM NEUSYSTEM (WARNUNG)` (not `(FEHLER)`), and that a control `ERR_UNG_NUMMER` on a *different* field (e.g. an amount field) still renders as `(FEHLER)` — locking in the field-specific scope.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test -Dtest=ValidationDeltaReportWriterDeviationsOnlyTest` — module builds, 10 tests pass (incl. the 2 new). **Done.**
2. `GrossfileRecalculationTest` baselines: the example line (`AT0000673603` / `STATUS;UPDATE;649565;03.08.2026`) is **not** present in any tracked grossfile (`gf1`–`gf8`) or the quick-recalc fixture — verified by unzip+grep. So no baseline count shifts and no `SummaryExpectation` needs updating. If a future fixture does contain such a case, its expected record moves one count from `onlyInNewError` to `onlyInNewWarning`.
