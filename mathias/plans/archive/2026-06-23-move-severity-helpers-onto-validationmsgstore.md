# Plan: Move severity helpers onto `ValidationMsgStore`, drop wasteful `filterBySeverity` round-trip

## Context

The Lieferung interface currently exposes three default helpers:

```java
default List<ValidationMsg> errorValidationMsgs() {
    return validationMsgs().filterBySeverity(ValidationMsg.Severity.ERROR).all();
}
default List<ValidationMsg> infoValidationMsgs() { /* same shape */ }
default List<ValidationMsg> oekbInfoValidationMsgs() { /* same shape */ }
```

Each one builds a transient `ValidationMsgStore` (allocating new buckets) just
to immediately flatten it via `.all()`. That's pure waste.

Of the three, only `errorValidationMsgs()` has a caller —
`SteuerlicheErmittlungDomainService.hasAnyFatalSubmissionLevelError`. The
other two have zero callers.

## Proposed change

Move the severity views onto `ValidationMsgStore` (which is where the data
lives anyway) and implement each as a one-line stream filter — no transient
Store:

```java
// in ValidationMsgStore
public List<ValidationMsg> errorValidationMsgs() {
    return stream().filter(ValidationMsg::isError).toList();
}
public List<ValidationMsg> infoValidationMsgs() {
    return stream().filter(ValidationMsg::isInfo).toList();
}
public List<ValidationMsg> oekbInfoValidationMsgs() {
    return stream().filter(ValidationMsg::isOekbInfo).toList();
}
```

Remove the three defaults from `SteuerMeldungLieferung`. Update the single
caller:

```java
static boolean hasAnyFatalSubmissionLevelError(SteuerMeldungLieferung lieferung) {
    return lieferung.validationMsgs().errorValidationMsgs().stream()
            .anyMatch(msg -> FATAL_SUBMISSION_LEVEL_CODES.contains(msg.getValidationMsgCode()));
}
```

`filterBySeverity(Severity) → ValidationMsgStore` stays — its real callers
(`ValidationDeltaCalculator.compare`, `ValidationMsgGroups.getMsgGroupBySeverity`)
genuinely need owner-aware filtering and consume the resulting Store's
`submissionLevelValidationMsgs()` and `validationMsgsByEntry()` directly.

## Files to change

- `ifas-domain-stm/.../validation/ValidationMsgStore.java` — add three
  `errorValidationMsgs() / infoValidationMsgs() / oekbInfoValidationMsgs()`
  methods, each a one-line stream filter.
- `ifas-domain-stm/.../meldung/SteuerMeldungLieferung.java` — delete the three
  default helpers (and `ValidationMsg` import becomes unused).
- `ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java`
  — `hasAnyFatalSubmissionLevelError` uses
  `lieferung.validationMsgs().errorValidationMsgs().stream()...`.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am test` — green.
2. `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test` — green.
3. The existing `SteuerlicheErmittlungDomainServiceTest` cases for
   `hasAnyFatalSubmissionLevelError` already pin the behavior we care about
   (file-level ERROR triggers true; info-only / per-meldung / orphan don't).

---

# Previous plan: Use `ValidationMsgStore` end-to-end through `SteuerlicheErmittlungDomainService`

## Context

The first refactor (`dedicated-validation-msgs-container.md`) introduced
`ValidationMsgStore` on the Lieferung and removed three shuffler sites in
`SteuerMeldungLieferungService` + `ValidationMsgGroups` +
`ValidationDeltaCalculator`. `SteuerlicheErmittlungDomainService` still
operates on flat lists:

- it flattens the Lieferung's store via `.all()` so it can be passed around;
- it re-scans that flat list per STM via
  `ValidationMsgs.getRelatedValidationMsgs(stm, all)` (an O(N) filter for each
  of N meldungen, i.e. O(N²) total);
- it does the same thing a second time after post-calculation validation, in
  `finishProcessing(stm, mergedValidationMsgs)`;
- it returns a flat `List<ValidationMsg>` from
  `SteuerlicheErmittlungErgebnis`, which downstream consumers either re-wrap
  into a Store (`ValidationMsgLogs`) or hand on as a list
  (`RecalculationDomainService → ValidationDeltaCalculators.compare`).

The goal is to thread the store through the service without losing any
messages.

## Why no messages are lost

`ValidationMsgs.getRelatedValidationMsgs(stm, list)` only ever returns msgs
where both `valMsg.getCorrespondingEntry()` and `stm.getSourceEntry()` are
non-null and equal. Submission-level msgs (entry == null) are never visible to
per-STM processing today.

`ValidationMsgStore.validationMsgsForEntry(stm.getSourceEntry())` has the
identical semantics: submission-level msgs sit in
`submissionLevelValidationMsgs`, are not keyed by entry, and a null-entry
lookup returns an empty list. So per-STM processing sees exactly the same set
of msgs as today.

Calculated msgs use `SteuerMeldungPositions.positionOf(stm)` whose
`getCorrespondingEntry()` returns `stm.getSourceEntry()`. When added to a store
via `store.addAll(calculatedValidationMsgs)`, they route to the correct
per-entry bucket. Submission-level msgs already in the Lieferung's store stay
in the submission-level bucket. The final Ergebnis store still carries them,
and `store.all()` is the exact same set as the old `mergedValidationMsgs`.

## Before / after

### Before
```
internalProcessLieferung(lieferung, …)
  ├─ hasAnyFatalSubmissionLevelError(lieferung)   // unchanged
  ├─ processedSteuerMeldungen = lieferung.steuerMeldungen.map(stm ->
  │     handleInputStm(stm,
  │         lieferung.validationMsgs().all(),       // flatten
  │         …))
  │     // inside handleInputStm:
  │     //   validationMsgsForThisStm = ValidationMsgs.getRelatedValidationMsgs(stm, all)
  │     //   (O(N) scan, repeated for each STM)
  ├─ calculatedValidationMsgs = calculatedSteuerMeldungValidationService.validate(...)
  ├─ mergedValidationMsgs = new ArrayList<>()
  ├─ mergedValidationMsgs.addAll(lieferung.validationMsgs().all())   // re-flatten
  ├─ mergedValidationMsgs.addAll(calculatedValidationMsgs)
  ├─ processedSteuerMeldungen = processedSteuerMeldungen.map(stm ->
  │     finishProcessing(stm, mergedValidationMsgs))
  │     // inside finishProcessing:
  │     //   validationMsgsForThisStm = ValidationMsgs.getRelatedValidationMsgs(stm, merged)
  │     //   (second O(N) scan)
  └─ new SteuerlicheErmittlungErgebnis.Simple(lieferung, processed,
                                              mergedValidationMsgs)  // flat List
```

### After
```
internalProcessLieferung(lieferung, …)
  ├─ hasAnyFatalSubmissionLevelError(lieferung)   // unchanged
  ├─ ValidationMsgStore preCalcMsgs = lieferung.validationMsgs();
  ├─ processedSteuerMeldungen = lieferung.steuerMeldungen.map(stm ->
  │     handleInputStm(stm, preCalcMsgs, …))
  │     // inside handleInputStm:
  │     //   validationMsgsForThisStm = preCalcMsgs.validationMsgsForEntry(stm.getSourceEntry())
  │     //   (O(1) lookup)
  ├─ calculatedValidationMsgs = calculatedSteuerMeldungValidationService.validate(...)
  ├─ ValidationMsgStore merged = preCalcMsgs.addAll(calculatedValidationMsgs);
  ├─ processedSteuerMeldungen = processedSteuerMeldungen.map(stm ->
  │     finishProcessing(stm, merged))
  │     // inside finishProcessing:
  │     //   validationMsgsForThisStm = merged.validationMsgsForEntry(stm.getSourceEntry())
  └─ new SteuerlicheErmittlungErgebnis.Simple(lieferung, processed, merged)  // Store
```

## Files to change

- **`ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java`**
  - `handleInputStm(SteuerMeldung, List<ValidationMsg>, …)` →
    `handleInputStm(SteuerMeldung, ValidationMsgStore, …)`; inside, replace the
    `getRelatedValidationMsgs(...)` call with
    `store.validationMsgsForEntry(stm.getSourceEntry())`.
  - `finishProcessing(ProcessedSteuerMeldung, List<ValidationMsg>)` →
    `finishProcessing(ProcessedSteuerMeldung, ValidationMsgStore)` with the
    same lookup change.
  - The `mergedValidationMsgs` accumulator becomes
    `ValidationMsgStore merged = lieferung.validationMsgs().addAll(calculatedValidationMsgs)`.
- **`ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungErgebnis.java`**
  - Interface accessor and `Simple` record component change from
    `List<ValidationMsg>` to `ValidationMsgStore`.
- **`ifas-domain-stm/.../validation/ValidationMsgs.java`**
  - `getRelatedValidationMsgs(stm, list)` and `isValidationMsgRelatedToStm` are
    now unused — remove. `isSubmissionLevelValidationMsg` and `containsErrors`
    stay (still in use; the latter in `ValidationMsgLogWriter`).
- **`ifas-domain-stm/.../recalc/RecalculationDomainService.java`** (line ~276)
  - `List<ValidationMsg> allValidationMsgs = ergebnis.validationMsgs();` →
    `List<ValidationMsg> allValidationMsgs = ergebnis.validationMsgs().all();`
    (the downstream `ValidationDeltaCalculators.compare(...)` still takes
    `List<ValidationMsg>`).
- **`ifas-domain-stm/.../meldung/log/ValidationMsgLogs.java`** (line 32)
  - Drop the `ValidationMsgStore.of(ergebnis.validationMsgs())` wrap; pass
    `ergebnis.validationMsgs()` directly.

## Reuse — what was searched and what was found

- `ValidationMsgStore.validationMsgsForEntry(SubmissionEntry)` already provides
  the per-entry lookup we need — no new helper.
- `SteuerMeldungPositions.positionOf(stm)` is the existing way to derive a
  Position from a SteuerMeldung; it returns `stm.getSourceEntry().getPositionInSubmission()`
  so calculated msgs route into the right bucket via `getCorrespondingEntry()`
  automatically.
- `ValidationMsgs.containsErrors(List)` stays — still called by
  `ValidationMsgLogWriter.writeSteuerMeldungValidationMsgs`.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am test` — must stay green.
2. `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test` — must stay
   green. Of particular interest:
   `ValidationDeltaCalculatorIntegrationTest`,
   `ValidationMsgLogsIntegrationTest`,
   `SteuerMeldungErmittlungsvorgabeValidationServiceTest`.
3. Add a focused unit test asserting that for a Lieferung with both a
   submission-level error (e.g. `ERR_OHNE_START` at file level) and a
   meldung-level error on one STM:
   - per-STM processing only sees the meldung-level error (same as today),
   - the Ergebnis store's `.all()` contains both — i.e. no msgs lost.
4. Spot-check end-to-end on `LocalH2OnlyIfasApplication`: process a CSV that
   exercises both pre-calculation and post-calculation validators; verify
   `error.log` / `info.log` output is byte-identical to before.
