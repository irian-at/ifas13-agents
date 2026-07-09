# Plan: Delete `ValidationMsgGroups`, drive `ValidationMsgLogWriter` from `ValidationMsgStore` directly

## Context

`ValidationMsgStore` was just introduced to own validation messages bucketed by their `SubmissionEntry` (or submission-level when no entry). The remaining adapter, `ValidationMsgGroups`, still re-buckets the same messages by `SteuerMeldung` for log reporting — and that turns out to be redundant. Investigating what the writer actually uses the `SteuerMeldung` for shows it only ever calls `SteuerMeldungPositions.positionOf(sm)`, which is one-line:

```java
// SteuerMeldungPositions.java
public static Position positionOf(SteuerMeldung sm) {
    return sm.getSourceEntry().getPositionInSubmission();
}
```

`sm.getSourceEntry()` returns the same `SubmissionEntry` that the store already keys by. So `entry.getPositionInSubmission()` yields exactly the Position the writer needs — no `CsvMessage → CsvSteuerMeldung` lookup required.

The wrapper case (`ProcessedSteuerMeldung`-style wrappers around a `CsvSteuerMeldung`) is also already handled at the store level: `WrappedSteuerMeldung#getSourceEntry()` delegates to the underlying `CsvMessage`, so wrapper-position messages and CSV-parse messages for the same row land in the same store bucket automatically. The two regression cases in `ValidationMsgGroupsTest` (collapse-into-single-group; sort wrapper-positions by underlying CSV line) survive unchanged under the entry-keyed approach.

Outcome: `ValidationMsgGroups` and its `ValidationMsgGroup` record disappear entirely; `ValidationMsgLogWriter` is driven straight from `ValidationMsgStore` accessors that already exist. No new API on the store.

## Scope

- Touch only the reporting path (`ValidationMsgLogWriter`, `ValidationMsgGroups`, their tests).
- Leave `ValidationMsgStore`'s API unchanged — the existing accessors are sufficient.
- Leave `ValidationMsgGrouping` (in `validation/delta`) alone — unrelated concern (delta calc), not reporting.
- Leave `ValidationMsgs` utility class alone — still used by the writer for `containsErrors(...)`.

## Changes

### 1. Rewrite `ValidationMsgLogWriter.write(...)` to consume the store directly

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgLogWriter.java`

Replace the `ValidationMsgGroups.getMsgGroupBySeverity(...)` call site (currently lines 56–70) with direct iteration over the store:

```java
ValidationMsg.Severity severity = getSeverity(logType);
ValidationMsgStore filtered = validationMsgs.filterBySeverity(severity);
String messagePrefix = getMessagePrefix(logType);

writeFileLevelValidationMsgs(filtered.submissionLevelValidationMsgs(), messagePrefix);

filtered.validationMsgsByEntry().entrySet().stream()
        .sorted(Comparator.comparingInt(e -> entryLineNumber(e.getKey())))
        .forEach(e -> writeEntryValidationMsgs(e.getKey(), e.getValue(), messagePrefix));
```

Rename `writeSteuerMeldungValidationMsgs(SteuerMeldung, ...)` to `writeEntryValidationMsgs(SubmissionEntry entry, List<ValidationMsg> msgs, String prefix)`. Inside it, derive the START-line position from the entry:

```java
Position position = entry.getPositionInSubmission();
wh.writeLine(position.toLogFormat());
// ... rest of the body (containsErrors check, groupByPosition, output) is unchanged.
```

Drop the `@Nullable SteuerMeldung` parameter and the `sm == null` branch — entries are never null as map keys, and there is no longer a lookup that can fail.

Add a private static helper for the sort key, replacing `ValidationMsgGroups.getLineNumber(ValidationMsg)`:

```java
private static int entryLineNumber(SubmissionEntry entry) {
    Position p = entry.getPositionInSubmission();
    if (p instanceof CsvMessagePosition csvPos && csvPos.issueLineNumber() != null) {
        return csvPos.issueLineNumber();
    }
    return Integer.MAX_VALUE;
}
```

Note this sorts by the bucket's start line (`firstLineNr`) rather than today's min-over-messages — for `CsvMessage` entries the two are interchangeable for ordering since CsvMessages don't overlap line ranges, and the existing "sort by underlying CSV line" regression test still passes.

Remove unused imports: `SteuerMeldung`, `SteuerMeldungPositions`, `ValidationMsgGroups` (and the inner record), plus `LinkedHashMap`/`stream.Collectors` if no longer referenced by other methods.

### 2. Delete `ValidationMsgGroups.java`

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroups.java`

Delete the file. All three production helpers fold into the writer:
- `getMsgGroupBySeverity(...)` → inlined into `write(...)`.
- `getLineNumber(ValidationMsg)` → replaced by `entryLineNumber(SubmissionEntry)`.
- `createSteuerMeldungLookupMap(...)` / `resolveSteuerMeldung(...)` → unneeded; the store's per-entry key is already what the writer wants.

### 3. Migrate the regression tests

File: `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroupsTest.java`

The four existing tests assert behaviour that still needs to hold after the refactor:

1. `givenPositionFromCsvSteuerMeldung_whenGetLineNumber_thenReturnsCsvFirstLineNr`
2. `givenPositionFromWrapperAroundCsvSteuerMeldung_whenGetLineNumber_thenResolvesToCsvLine`
3. `givenWrapperAndCsvErrorsForSameRow_whenGetMsgGroupBySeverity_thenCollapseIntoSingleGroup`
4. `givenGroupsWithWrappedAndBarePositions_whenSorted_thenByCsvLine`

Move the file to `ValidationMsgLogWriterTest.java` (in the same package) and reframe assertions against writer output. The wrapper-vs-CSV "collapse" assertion becomes an inspection of the rendered log: both messages appear under one START header, in submission order. The "sorted by CSV line" assertion becomes an inspection of START-header order in the rendered log.

If a writer test already exists in the same package, add the four `given_when_then` cases to it instead of duplicating fixtures. Reuse the existing helpers (`csvSteuerMeldung(int)`, `lieferung(...)`, `TestProcessedSteuerMeldung`) — they are still appropriate.

## Critical files to modify

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgLogWriter.java` — rewrite `write(...)` and the per-entry write helper; add `entryLineNumber(...)`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroups.java` — delete.
- `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroupsTest.java` — rename to `ValidationMsgLogWriterTest.java` (or fold into an existing one) and rewrite assertions against rendered output.

## What stays untouched

- `ValidationMsgStore` (no API additions; `filterBySeverity` + `submissionLevelValidationMsgs` + `validationMsgsByEntry` already cover the writer's needs).
- `SteuerMeldungPositions` (still useful elsewhere — unrelated to this consolidation).
- `ValidationMsgs` (writer still calls `ValidationMsgs.containsErrors(...)`).
- `ValidationMsgGrouping` in `validation/delta` (separate concern).

## Verification

1. Compile the affected module: `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm clean test-compile`.
2. Run the writer + store tests:
   `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test -Dtest='ValidationMsgLogWriterTest,ValidationMsgStoreTest'`.
   Confirm the four migrated regression cases pass against rendered log output.
3. Run the wider domain test suite to catch indirect callers:
   `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test`.
4. Integration smoke: process a sample lieferung that produces both file-level and per-row errors (including wrapper-position messages) and diff the generated `.log` against the pre-change baseline — text output must be byte-identical for any input the old groups class handled.
