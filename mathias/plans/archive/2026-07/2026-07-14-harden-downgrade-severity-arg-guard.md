# Harden `downgradeValidationMsgSeverity` + fix annotation divergence

## Context
During code review of the local diff, two issues surfaced in
`SteuerMeldungLieferungService.downgradeValidationMsgSeverity` (added in this WIP change):

1. It indexes `getArguments()[0]` without a length guard. Safe today because
   `ERR_UNG_NUMMER` always carries 3 args, but the sibling it claims to mirror
   (`ValidationDeltaReports#matchesCodeFieldWarningRule`) guards `fieldArgIndex < args.length`.
   The user wants the guard so a future/edge message can't throw `ArrayIndexOutOfBoundsException`.
2. The new method introduced JSpecify `@NonNull` (import line 19) into a class that otherwise
   uses Jakarta `@Nonnull` (lines 117, 163) — a two-library divergence for the same concept.

## Changes — `SteuerMeldungLieferungService.java`

### 1. Add the arguments length guard (line ~188)
Hoist `getArguments()` into a local and check length before indexing:

```java
private ValidationMsg downgradeValidationMsgSeverity(ValidationMsg mappedValidationMsg) {
    Object[] arguments = mappedValidationMsg.getArguments();
    // ERR_UNG_NUMMER carries the field as a FieldName at arg[0] (see ValidationMsgMapper#mapValueTypeError),
    // so match on its definedName, not the object. Mirrors ValidationDeltaReports#matchesCodeFieldWarningRule.
    if (mappedValidationMsg.getValidationMsgCode() == ValidationMsgCode.ERR_UNG_NUMMER
            && arguments.length > 0
            && arguments[0] instanceof FieldName fieldName
            && MELDESTELLE_ONLY_FIELDS.contains(fieldName.definedName())) {
        return mappedValidationMsg.withSeverity(ValidationMsg.Severity.INFO);
    }
    return mappedValidationMsg;
}
```

### 2. Resolve the annotation divergence
Remove the redundant JSpecify annotation from the private helper and its now-unused import:
- Delete `import org.jspecify.annotations.NonNull;` (line 19)
- Change the method signature `private @NonNull ValidationMsg ...` → `private ValidationMsg ...`

Rationale: it's a private helper whose non-null return is self-evident and unenforced (class is
not `@NullMarked`); dropping it avoids adding a second nullability library to the file. The
existing Jakarta `@Nonnull` usages are left untouched (out of scope).

## Verification
- `mvn clean install -pl ifas-domain/ifas-domain-stm -am -Pno-proxy` (compiles; no unused-import warning)
- `mvn test -Dtest=CsvToValidationMsgCodeTest -Pno-proxy` — existing mapper tests still pass
- Behavior unchanged for real `ERR_UNG_NUMMER` messages; guard only affects hypothetical arg-less messages
