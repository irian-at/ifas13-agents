# Plan: Use `ValidationMsgStore` end-to-end through `SteuerlicheErmittlungDomainService`

Companion to `dedicated-validation-msgs-container.md` — extends the store
through the calculation/post-validation phase.

## Context

The first refactor introduced `ValidationMsgStore` on the Lieferung and
removed three shuffler sites in `SteuerMeldungLieferungService` +
`ValidationMsgGroups` + `ValidationDeltaCalculator`.
`SteuerlicheErmittlungDomainService` still operated on flat lists:

- flattened the Lieferung's store via `.all()` to pass it around;
- re-scanned that flat list per STM via
  `ValidationMsgs.getRelatedValidationMsgs(stm, all)` (O(N) per STM →
  O(N²) total);
- did the same scan a second time in
  `finishProcessing(stm, mergedValidationMsgs)`;
- returned a flat `List<ValidationMsg>` from `SteuerlicheErmittlungErgebnis`,
  forcing downstream consumers to either re-wrap into a Store
  (`ValidationMsgLogs`) or pass it on as a list
  (`RecalculationDomainService → ValidationDeltaCalculators.compare`).

## Why no messages are lost

`ValidationMsgs.getRelatedValidationMsgs(stm, list)` only ever returned msgs
where both `valMsg.getCorrespondingEntry()` and `stm.getSourceEntry()` were
non-null and equal. Submission-level msgs (entry == null) were never visible
to per-STM processing.

`ValidationMsgStore.validationMsgsForEntry(stm.getSourceEntry())` has the
identical semantics: submission-level msgs sit in
`submissionLevelValidationMsgs`, are not keyed by entry, and a null-entry
lookup returns an empty list. Per-STM processing sees the same set as before.

Calculated msgs use `SteuerMeldungPositions.positionOf(stm)` whose
`getCorrespondingEntry()` returns `stm.getSourceEntry()`. When added to a
store via `store.addAll(calculatedValidationMsgs)` they route to the correct
per-entry bucket; submission-level msgs already in the Lieferung's store stay
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
  │     //   ValidationMsgs.getRelatedValidationMsgs(stm, all)   — O(N) scan
  ├─ calculatedValidationMsgs = calculatedSteuerMeldungValidationService.validate(...)
  ├─ mergedValidationMsgs = new ArrayList<>()
  ├─ mergedValidationMsgs.addAll(lieferung.validationMsgs().all())   // re-flatten
  ├─ mergedValidationMsgs.addAll(calculatedValidationMsgs)
  ├─ processedSteuerMeldungen = processedSteuerMeldungen.map(stm ->
  │     finishProcessing(stm, mergedValidationMsgs))
  │     // inside finishProcessing:
  │     //   ValidationMsgs.getRelatedValidationMsgs(stm, merged)  — second O(N) scan
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
  │     // inside:
  │     //   preCalcMsgs.validationMsgsForEntry(stm.getSourceEntry())   — O(1) lookup
  ├─ calculatedValidationMsgs = calculatedSteuerMeldungValidationService.validate(...)
  ├─ ValidationMsgStore merged = preCalcMsgs.addAll(calculatedValidationMsgs);
  ├─ processedSteuerMeldungen = processedSteuerMeldungen.map(stm ->
  │     finishProcessing(stm, merged))
  │     // inside:
  │     //   merged.validationMsgsForEntry(stm.getSourceEntry())
  └─ new SteuerlicheErmittlungErgebnis.Simple(lieferung, processed, merged)  // Store
```

## Files changed

- `ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java`:
  `handleInputStm` and `finishProcessing` now take `ValidationMsgStore`;
  per-STM lookup uses `validationMsgsForEntry(stm.getSourceEntry())`;
  merged accumulator is built via
  `preCalcMsgs.addAll(calculatedValidationMsgs)`.
- `ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungErgebnis.java`:
  interface accessor and `Simple` record component changed to
  `ValidationMsgStore`.
- `ifas-domain-stm/.../validation/ValidationMsgs.java`:
  `getRelatedValidationMsgs` and `isValidationMsgRelatedToStm` removed (now
  unused). `isSubmissionLevelValidationMsg` and `containsErrors` stay.
- `ifas-domain-stm/.../recalc/RecalculationDomainService.java`:
  `ergebnis.validationMsgs()` → `ergebnis.validationMsgs().all()` at the call
  to `ValidationDeltaCalculators.compare(...)` (which still takes a List).
- `ifas-domain-stm/.../meldung/log/ValidationMsgLogs.java`:
  dropped the `ValidationMsgStore.of(ergebnis.validationMsgs())` wrap.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am test` — green.
2. `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test` — green.
3. New focused test in `ValidationMsgStoreTest`:
   `givenSubmissionLevelMsgAndPerEntryMsg_whenLookupByEntry_thenOnlyPerEntryMsg_butAllStillCarriesBoth`
   pins the no-loss contract: submission-level msgs are invisible per-STM but
   present in `store.all()`.
