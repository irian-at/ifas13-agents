# Plan: make `ValidationMsgStore` mutable, drop `merge`, drop `perMeldungMsgs`, take store directly in delta calc

## Context

`ValidationMsgStore` is a brand-new (uncommitted) owner-aware container. Today it is fully immutable — every `add`/`addAll`/`merge` deep-copies the bucket map. The construction loops in `SteuerMeldungLieferungService` reassign `validationMsgs = validationMsgs.addAll(...)` on every step, giving O(N²) build cost.

That immutability isn't earning its keep:
- The pipeline is single-threaded — no thread-safety pay-off.
- No caller shares a store with sibling readers expecting independent snapshots; every existing pattern is build-once → attach → read.
- The reassignment idiom is a footgun (forgetting to reassign silently loses data).

Three other smells were uncovered while reviewing call sites:
1. `SteuerMeldungLieferungService` uses a per-iteration `ArrayList<ValidationMsg> perMeldungMsgs` solely so the `producedError` check can ask "did *this* Meldung emit any ERROR?". An Explore pass confirmed the three per-Meldung validators (`SteuerMeldungStatusValidationService`, `SteuerMeldungErmittlungsvorgabeValidationService`, `SteuerMeldungDomainValidationService`) only emit entry-scoped messages bound to the Meldung's `CsvMessage` — never submission-level. So the store can answer this directly via a per-entry lookup.
2. `ValidationDeltaCalculator.compare(...)` takes `List<ValidationMsg>` and immediately calls `ValidationMsgStore.of(newValidationMsgs)` to re-wrap it (line 41). The caller in `RecalculationDomainService` (line 277) does `ergebnis.validationMsgs().all()` to flatten the store *just so it can be re-wrapped*. The bucketing only round-trips because every msg carries its position — pure waste.
3. `merge` has exactly one caller, `crossSeverityStore` (line 101), which can be rewritten in 5 lines without it.

Goal: flip `ValidationMsgStore` to mutable for appends (`add`/`addAll`); keep derivation operations (`filterBySeverity`, `deduplicate`) returning new instances; delete `merge`; rewrite the construction loop to drop `perMeldungMsgs` and the reassignment idiom; change `ValidationDeltaCalculator.compare` to accept a `ValidationMsgStore` directly.

## Design — `ValidationMsgStore`

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgStore.java`

**Mutating ops** (mutate `this`, return `this` for chaining):
- `add(ValidationMsg msg)` — same null-owner routing as current lines 65–70.
- `addAll(Collection<ValidationMsg> msgs)` — short-circuit on empty, else loop into `add`.

**Removed**:
- `merge(ValidationMsgStore other)` — no replacement; sole caller rewritten (see below).

**Derivation ops** (return *new* store — semantics unchanged from today):
- `filterBySeverity(Severity severity)`
- `deduplicate()`
- `copy()` — **new**: deep-copy of buckets, for the one alias site that needs a snapshot (see `SteuerlicheErmittlungDomainService` below).

**Read ops** (unchanged signatures):
- `submissionLevelValidationMsgs()`, `validationMsgsByEntry()`, `validationMsgsForEntry(entry)`, `entriesWithSeverity(severity)`, `all()`, `stream()`, `count`, `errorValidationMsgs`, `infoValidationMsgs`, `oekbInfoValidationMsgs`, `isEmpty`.
- Add `hasErrorForEntry(SubmissionEntry entry)` — O(M) over that entry's bucket only; `false` if absent.

**Accessor immutability**: `submissionLevelValidationMsgs()` and `validationMsgsByEntry()` return `Collections.unmodifiableList` / `unmodifiableMap` views over live internals — readers can't mutate by accident, but we don't pay a copy on every read. Matches the build-once → read-many lifecycle.

**Factories**:
- Keep `empty()` (used by `RecalculationDomainService`) — returns a fresh empty mutable store (not a shared singleton).
- Keep `of(Collection<ValidationMsg>)` for the test ergonomics.

## Call-site changes

### 1. `SteuerMeldungLieferungService.loadAndValidateSteuerMeldungLieferungFromCsv`

Drop `perMeldungMsgs` and the reassignment:

```
ValidationMsgStore validationMsgs = mapToValidationMsgStore(stichtag, bmfVersion,
        steuerMeldungenWithValidations.validationMsgs());

Set<SubmissionEntry> entriesWithUpstreamError = validationMsgs.entriesWithSeverity(Severity.ERROR);
InLieferungAcceptedState acceptedState = new InLieferungAcceptedState();

for (CsvSteuerMeldung steuerMeldung : steuerMeldungenWithValidations.steuerMeldungen()) {
    if (!steuerMeldung.getCsvMessage().hasRecordType(RecordType.START.name())) {
        log.info("Skipping validation for orphan message {}", steuerMeldung.getCsvMessage());
        continue;
    }
    ensureCalculatedGeschaeftsjahre(stichtag, steuerMeldung);

    validationMsgs.addAll(statusValidationService.validate(steuerMeldung, stichtag, acceptedState, validationSetting));
    validationMsgs.addAll(ermittlungsvorgabeValidationService.validate(steuerMeldung));
    validationMsgs.addAll(domainValidationService.validate(steuerMeldung, stichtag, lieferant));

    boolean producedError = entriesWithUpstreamError.contains(steuerMeldung.getCsvMessage())
            || validationMsgs.hasErrorForEntry(steuerMeldung.getCsvMessage());
    if (!producedError) {
        acceptedState.accept(steuerMeldung);
    }
}

return buildSteuerMeldungLieferung(..., validationMsgs.deduplicate());
```

`entriesWithUpstreamError` is captured into a separate `Set` before the loop, so later mutations of the store don't change its membership.

### 2. `SteuerMeldungLieferungService.mapToValidationMsgStore`

Replace `store = store.addAll(...)` with `store.addAll(...)`:

```
ValidationMsgStore store = ValidationMsgStore.empty();
for (CsvValidationMsg csvValidationMsg : csvValidationMsgs) {
    Position position = csvValidationMsg.position();
    Ermittlungsvorgabe ermittlungsvorgabe = (position instanceof CsvMessagePosition csvMessagePosition)
            ? ermittlungsvorgabeFor(csvMessagePosition.csvMessage(), stichtag, bmfVersion)
            : null;
    store.addAll(new ValidationMsgMapper(ermittlungsvorgabe).toValidationMsgs(csvValidationMsg));
}
return store;
```

### 3. `SteuerlicheErmittlungDomainService:115` — aliasing fix

Today:
```
ValidationMsgStore mergedValidationMsgs = preCalcMsgs.addAll(calculatedValidationMsgs);
```
With mutable `addAll`, that would silently mutate `lieferung.validationMsgs()` via aliasing. Fix by snapshotting first:
```
ValidationMsgStore mergedValidationMsgs = preCalcMsgs.copy();
mergedValidationMsgs.addAll(calculatedValidationMsgs);
```
This is the *one* place a snapshot is explicitly wanted. `copy()` makes the intent obvious.

### 4. `ValidationDeltaCalculator.compare` — take the store directly

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaCalculator.java`

Change the signature from `List<ValidationMsg> newValidationMsgs` to `ValidationMsgStore allMsgs`. Drop the `ValidationMsgStore.of(newValidationMsgs)` re-wrap on line 41. The rest of the method already operates on the store.

### 5. `ValidationDeltaCalculator.crossSeverityStore` — drop `merge`

Replace the merge-loop (current lines 97–105) with a direct iterate-and-add:

```
private static ValidationMsgStore crossSeverityStore(ValidationMsgStore allMsgs, ValidationMsg.Severity excluded) {
    ValidationMsgStore result = ValidationMsgStore.empty();
    for (ValidationMsg msg : allMsgs.all()) {
        if (msg.getSeverity() != excluded) {
            result.add(msg);
        }
    }
    return result;
}
```

Same O(N) traversal as today, but one pass instead of one per severity, and no `merge`.

### 6. `ValidationDeltaCalculators` (facade)

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaCalculators.java`

Update facade signature to match `ValidationDeltaCalculator.compare` (`ValidationMsgStore` instead of `List<ValidationMsg>`).

### 7. `RecalculationDomainService:277-294`

Drop the local `allValidationMsgs` flatten:
```
SteuerMeldungLieferungOrigination origination = ergebnis.lieferung().origination();
ValidationSetting validationSetting = recalculationSetting.validationSetting();

errorLogDeltaReport = inputBundle.getOptionalSingleResource(BundleFileType.ERROR_LOG_FILE)
        .map(LegacyLogParsers::parseErrorLog)
        .map(f -> ValidationDeltaCalculators.compare(f, ergebnis.validationMsgs(), origination, validationSetting))
        .orElse(null);
// same for infoLogDeltaReport, oekbInfoLogDeltaReport
```

### 8. Tests

- `ValidationMsgStoreTest` (new in this diff): rewrite for mutation semantics — `add`/`addAll` return `this` and mutate; remove `merge` cases; add cases for `hasErrorForEntry` (ERROR present, only INFO present, entry absent) and `copy()` (mutations on the copy do not affect the original).
- `ValidationDeltaCalculatorIntegrationTest`: change call sites at lines 102–103 and 125–126 to pass `newLieferung.validationMsgs()` directly instead of `.all()`.
- `SteuerlicheErmittlungDomainServiceTest`: add assertion that `lieferung.validationMsgs()` is structurally unchanged before/after `internalProcessLieferung` — guards the aliasing fix from regressing.
- `ValidationMsgGroupsTest`, `ValidationMsgLogsTest`: only touch if any test was constructing a store via `merge` (unlikely — they should be read-only).
- No `SteuerMeldungLieferungServiceTest` to update (deleted in this diff per `git status`). Integration coverage runs through `EstbReportTest`.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am test` — store unit tests, ermittlung tests, group/log writer tests.
2. `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests -am test -Dtest=EstbReportTest -Dtest=ValidationDeltaCalculatorIntegrationTest` — full pipeline + delta calc.
3. Behavioural sanity: within-Lieferung duplicate detection still trips `ERR_STATUS_NM_LIEFERUNG` and `ERR_JAHRESM_VORH_LIEFERUNG` exactly as before. Grossfile baselines must not move.
4. Spot-check that `errorLogDeltaReport` / `infoLogDeltaReport` / `oekbInfoLogDeltaReport` counts (exact/divergent/covered/onlyLegacy/onlyNew) are byte-identical to a pre-refactor baseline.

## Non-goals

- No changes to `ValidationMsg`, `ValidationMsgMapper`, or any validator service.
- No Builder type — the mutable store is the builder.
- No defensive copy-on-read; readers see `Collections.unmodifiableX` views.
- No new generalized filter API (`filterByPredicate`, etc.) — out of scope.
