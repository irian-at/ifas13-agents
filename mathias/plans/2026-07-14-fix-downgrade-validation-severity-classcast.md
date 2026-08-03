# Fix `downgradeValidationMsgSeverity` — ClassCastException

## Context

`SteuerMeldungLieferungService.downgradeValidationMsgSeverity` (lines 187-195) is meant to
soften an `ERR_UNG_NUMMER` (invalid number) into an `INFO` when the offending field is a
meldestelle-only field (currently just `STM_ID_REF`). The intent: legacy tolerated a
non-numeric/date value in the numeric "Melde-ID vorherige Meldung" field, so the new system
shouldn't hard-error on it.

The method never works as intended. It contains a runtime type bug that makes it throw
instead of downgrade.

## The bug

```java
String fieldName = (String) mappedValidationMsg.getArguments()[0];   // line 189
if (MELDESTELLE_ONLY_FIELDS.contains(fieldName)) { ... }
```

`arguments[0]` of an `ERR_UNG_NUMMER` message is a **`FieldName`**, not a `String`. This is
set in `ValidationMsgMapper.mapValueTypeError` (`case "NUMBER"`, line 131-138: first arg is
`fieldName`, the result of `resolveFieldName(...)` which returns `FieldName`). Confirmed by
`CsvToValidationMsgCodeTest` line 526, which builds the message with
`FieldName.of(SteuerMeldung.FieldName.KUPONNUMMER)` as arg[0].

Consequences:
- `(String) <FieldName>` throws **`ClassCastException`** at load time for every
  `ERR_UNG_NUMMER` message whose field arg is non-null — which is the normal case. This
  aborts the whole `loadAndValidateSteuerMeldungLieferungFromCsv` run.
- The only non-crashing path is when arg[0] is `null` (a `FieldName` couldn't be resolved),
  in which case `contains(null)` is `false` and nothing is downgraded. So the intended
  downgrade branch is unreachable.
- Even without the cast, `MELDESTELLE_ONLY_FIELDS` is a `List<String>` of *defined names*
  (`STM_ID_REF = "_STATUS_MELDUNGS_ID_REF"`), so it can only match a `FieldName` by its
  `definedName()`, not the object itself.

## The fix (reuse existing pattern)

`ValidationDeltaReports.matchesCodeFieldWarningRule` (lines 198-206) already does this
comparison correctly for the identical `(ERR_UNG_NUMMER, arg 0, STM_ID_REF)` rule:

```java
args[rule.fieldArgIndex()] instanceof FieldName fieldName
        && rule.fieldDefinedName().equals(fieldName.definedName())
```

Apply the same shape in `downgradeValidationMsgSeverity`
(`ifas-domain/ifas-domain-stm/.../meldung/SteuerMeldungLieferungService.java`):

```java
private @NonNull ValidationMsg downgradeValidationMsgSeverity(ValidationMsg mappedValidationMsg) {
    if (mappedValidationMsg.getValidationMsgCode() == ValidationMsgCode.ERR_UNG_NUMMER
            && mappedValidationMsg.getArguments()[0] instanceof FieldName fieldName
            && MELDESTELLE_ONLY_FIELDS.contains(fieldName.definedName())) {
        return mappedValidationMsg.withSeverity(ValidationMsg.Severity.INFO);
    }
    return mappedValidationMsg;
}
```

Requires importing `at.oekb.ifas.domain.stm.validation.FieldName` (the package `...validation.*`
is already imported at line 11, so no new import needed).

### Minor cleanups (optional, same file)
- `MELDESTELLE_ONLY_FIELDS` (line 50) is a package-private mutable instance field — make it
  `private static final`.

## Note on duplication (no action required, worth flagging)
The `(ERR_UNG_NUMMER, 0, STM_ID_REF)` downgrade intent now lives in two places:
`downgradeValidationMsgSeverity` (load-time severity) and
`ValidationDeltaReports.CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW`
(delta-report classification). They serve different pipelines so consolidation isn't required,
but if a second meldestelle-only field is ever added, both lists must be updated.

## Verification
- Add/extend a unit test in `CsvToValidationMsgCodeTest` (or a focused
  `SteuerMeldungLieferungService` test): feed a CSV whose `_STATUS_MELDUNGS_ID_REF` holds a
  non-numeric value, assert the resulting message is `ERR_UNG_NUMMER` with severity `INFO`
  (not `ERROR`) and that loading does **not** throw.
- Add a negative case: an `ERR_UNG_NUMMER` on a normal numeric field (e.g. `KUPONNUMMER`)
  stays `ERROR`.
- Run: `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=CsvToValidationMsgCodeTest`
