# Plan: Allow EA to appear after E records (anywhere among E/D/Z/ZA/AS), but before D/Z/ZA/AS

## Context

`CsvIfasStructureValidationRules` declares the per-status sequence rule used by `CsvIfasSequenceValidations` to validate the order of CSV records inside a Steuermeldung message. Today the sequence for `NEW`/`NEW_DECLINED` is

```
START, STATUS, EA, E|D|Z|ZA|AS, END
```

which forces `EA` to appear exclusively at position 2 — *immediately* after `STATUS` and *before any* `E`. The German comment block on lines 23–26 already documents the intended rule, which the code does not yet implement:

- `E, D, Z, ZA, AS` are **fully interchangeable** among themselves (any order).
- `EA` must come **before any `D, Z, ZA, AS`**, but may appear before or interspersed with `E` records.

The same shortcoming exists in the placeholder sequence for `OPEN/ERROR/UPDATE/UPDATE_DECLINED/DELETED/FINAL` (`… EA, E, D, STB, END`), and the user-confirmed scope is to fix both blocks.

The pipe-alternative sequence DSL (`A|B|C` = "any of these at this step") cannot express "X must come before Y" while keeping Y interchangeable with everything else: putting a record code in two sequence steps (e.g. `E` in both `EA|E` and `E|D|Z|ZA|AS`) still pins it to one logical position via the validator's "monotonically advancing position" model. The only way to express "EA before D/Z/ZA/AS, otherwise everything is free" is to add a precedence rule alongside the sequence.

## Approach

### 1. Add a data-driven precedence map to `CsvIfasStructureValidationRules`

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasStructureValidationRules.java`

Add a fifth rule shape next to the existing `mandatoryRecords` / `uniqueRecords` / `allowedRecords` / `sequence`:

```java
private Map<String, Set<String>> precedenceConstraints = Map.of();

public CsvIfasStructureValidationRules precedenceConstraints(Map<String, Set<String>> constraints) {
    this.precedenceConstraints = Map.copyOf(constraints);
    return this;
}

public Map<String, Set<String>> getPrecedenceConstraints() {
    return precedenceConstraints; // already immutable copy
}
```

Semantics: each entry `record -> {successors...}` declares "`record` must appear before any of `successors` in the same message". Map shape mirrors the existing `Set<String>`-style rule fields — same style of fluent builder, same immutable-copy getter convention.

In `forStatus(...)`:

- `NEW`, `NEW_DECLINED` block:
  - `sequence("START", "STATUS", "EA|E|D|Z|ZA|AS", "END")` — collapse the data records into one free-order step.
  - `.precedenceConstraints(Map.of("EA", Set.of("D", "Z", "ZA", "AS")))`
- `OPEN`, `ERROR`, `UPDATE`, `UPDATE_DECLINED`, `DELETED`, `FINAL` block:
  - `sequence("START", "STATUS", "EA|E|D|Z|ZA|AS", "STB", "END")` — same merge, `STB` still on its own step.
  - same `.precedenceConstraints(Map.of("EA", Set.of("D", "Z", "ZA", "AS")))`.
- `CONFIRMED` / `DELETE` / `CONFIRM_DECLINED` / `DELETE_DECLINED` block: unchanged (no `EA`/`D`/`Z`/`ZA`/`AS` records allowed, so no precedence rule needed).

Update the German comment block on lines 23–26 to reflect the now-enforced rule (it currently describes intent, not implementation).

### 2. Enforce precedence in `CsvIfasSequenceValidations`

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasSequenceValidations.java`

This class already runs once per record via `CsvIfasValidationContext.trackRecord(...)`, so it's the natural place to add the check.

Add:

- A `Set<String> seenRecordCodes = new HashSet<>()` field tracking which record codes have appeared so far in this message.
- A new private `validatePrecedence(String recordCode, int lineNumber, String lineText)` method.
  - Look up `rules.getPrecedenceConstraints().get(recordCode)` → the set of successor codes this record must appear before.
  - If any successor is already in `seenRecordCodes`, emit a validation error (see §3 for the error code) naming the violating record (`recordCode`) and the offending successor(s).
- Call `validatePrecedence(...)` from `validateRecordSequence(...)` after the existing sequence check (or before — order doesn't matter; both can fire), then add `recordCode` to `seenRecordCodes` at the end (regardless of outcome, so subsequent records see a faithful "what came earlier" picture).

The existing pipe-alternatives sequence logic stays exactly as-is — no change to `findPositionInSequence` / `sequenceStepContainsRecord` / `isRecordOutOfSequence`.

### 3. Add a new `CsvErrorCode` entry

File: `support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvErrorCode.java`

Add one new entry next to `SEQUENCE_VIOLATION`:

```java
PRECEDENCE_VIOLATION("Record ''{0}'' must appear before record ''{1}''"),
```

Parameters: `{0}` = the record that arrived too late (e.g. `EA`), `{1}` = the already-seen successor (e.g. `D`). If multiple successors were seen, report the first one (preserves the "single specific error" style of `SEQUENCE_VIOLATION`).

A new error code (rather than re-using `SEQUENCE_VIOLATION`) keeps the user-facing message accurate and lets test assertions distinguish the two failure modes.

### 4. Tests

Reuse the existing test infrastructure (`trackRecordWithContext`, `createMockRecordSchema`) — no new helpers needed.

**`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasStructureValidationRulesTest.java`**
- Update the existing sequence assertion for `NEW` to the new `["START", "STATUS", "EA|E|D|Z|ZA|AS", "END"]` value.
- Add an assertion that `forStatus(NEW).getPrecedenceConstraints()` equals `Map.of("EA", Set.of("D","Z","ZA","AS"))`.
- Add equivalent assertions for one representative status from the `OPEN/...` block (e.g. `OPEN`), expecting `["START", "STATUS", "EA|E|D|Z|ZA|AS", "STB", "END"]` + same precedence map.

**`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasValidationContextTest.java`** — new given-when-then cases:
- `givenEaBetweenEAndD_whenTrackRecords_thenNoErrors` — `START, STATUS, E, EA, D, END` — no errors.
- `givenInterleavedEAndCountryRecords_whenTrackRecords_thenNoErrors` — `START, STATUS, E, D, E, Z, END` — true interchangeability without `EA` (no precedence trigger).
- `givenEaAfterFirstCountryRecord_whenTrackRecords_thenPrecedenceViolation` — `START, STATUS, E, D, EA, END` — expect exactly one `PRECEDENCE_VIOLATION` with parameters `EA` / `D`.
- `givenCountryRecordBeforeAnyEa_whenTrackRecords_thenNoErrors` — `START, STATUS, D, EA …` is **invalid** (`EA` came after `D`) — covered by the previous case shape; alternatively `START, STATUS, D, Z, END` is fine because no `EA` ever appeared.

Conventions to follow (per `.claude/rules/testing-conventions.md`): given-when-then naming, AssertJ only, JUnit 5.

### 5. Reuse check

Searched for existing precedence / ordering infrastructure before proposing the new field:
- `support-libs/csv-schema` only knows the linear-sequence-with-alternatives model (via `CsvIfasSequenceValidations`); no existing "X before Y" abstraction exists.
- Closest existing pattern is the `Set<String>` rule fields (`mandatoryRecords`, `uniqueRecords`, `allowedRecords`) — the new `precedenceConstraints` follows the same fluent-builder + immutable-copy-getter shape, so no new style is introduced.

## Files to modify

1. `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasStructureValidationRules.java` — new `precedenceConstraints` field/builder/getter; updated `sequence(...)` and new `.precedenceConstraints(...)` for both relevant status blocks; refreshed German comments.
2. `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasSequenceValidations.java` — new `seenRecordCodes` tracker and `validatePrecedence(...)` invoked from `validateRecordSequence(...)`.
3. `support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvErrorCode.java` — new `PRECEDENCE_VIOLATION` entry.
4. `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasStructureValidationRulesTest.java` — updated sequence + new precedence assertions.
5. `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasValidationContextTest.java` — new given-when-then cases.

No new classes. Reuses the existing validator pipeline and rules-object style.

## Verification

```bash
# from repo root
mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test \
    -Dtest='CsvIfasStructureValidationRulesTest,CsvIfasValidationContextTest,CsvIfasValidationTest'
```

Trace one positive (`E, EA, D`) and one negative (`E, D, EA`) case through `CsvIfasSequenceValidations` mentally / under a debugger to confirm the `seenRecordCodes` tracker fires on the right record and reports the right successor.
