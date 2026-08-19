# Plan: Deduplicate identical `ValidationMsg`s per SteuerMeldung

## Context

The legacy-vs-new comparison report for `Zuflusszeitpunkt_Anteile_Tranche_Anzahl_e` on line 650 shows the same `ERR_PFLICHT_FEHL` text appearing twice in the new system: once as `EXAKTER TREFFER` against the legacy log, and once as `NUR IM NEUSYSTEM (FEHLER)`. Two independent layers both check the same Pflichtfeld:

- **CSV-schema layer** — `STM_LIEFERFORMAT_2022-04-03.csv-schema.yml` marks the field `required: true`; the parser raises `CsvErrorCode.MISSING_FIELD`, mapped to `ERR_PFLICHT_FEHL` in `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgMapper.java:38`.
- **Ermittlungsvorgabe layer** — the same field is declared `Befuellung.MANDATORY`; `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java:204-211` independently emits `ERR_PFLICHT_FEHL` for the same null value.

This is not specific to one field — any field that is both `required: true` and `Befuellung.MANDATORY` produces a redundant pair. Goal: collapse identical user-visible messages **within each SteuerMeldung** so the comparison report (and end-user output) shows each issue exactly once per StM.

### Why per-StM, not per-Lieferung

A Lieferung contains many StMs. If StM_A and StM_B both have the same Pflichtfeld empty, both layers emit `"Das Pflichtfeld <X> im Satz <START> ist nicht befuellt."` for each — and the rendered text is identical across StMs because the template carries only field/record names, no StM identifier. A Lieferung-wide dedup keyed on `formattedMessage` would collapse 4 messages → 1 when the correct answer is 4 → 2 (one per StM). Dedup must therefore be scoped to a single StM's messages.

## Approach

Restructure `SteuerMeldungLieferungService.loadAndValidateSteuerMeldungLieferungFromCsv` (file: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java`) so the per-StM `forEach` (currently line 81–99) builds a per-StM message list, dedupes within it, and only then appends the deduped list to `allValidationMsgs`. CSV-layer messages that belong to a specific StM are partitioned into that StM's group before the loop runs.

### Source of per-StM CSV-layer messages

The pre-loop CSV mapping at line 71–75 produces a flat list across the whole Lieferung. Each `ValidationMsg` carries a `Position`; for CSV-layer messages this is a `CsvMessagePosition` whose `csvMessage()` accessor returns the owning `CsvMessage` (see `support-libs/csv-schema/.../CsvMessagePosition.java:12`). Each `CsvSteuerMeldung` exposes its own `CsvMessage` via `getCsvMessage()`. So we can partition the pre-mapped CSV messages by owning `CsvMessage` (identity comparison) and look up "this StM's CSV messages" inside the loop.

CSV messages whose position is **not** a `CsvMessagePosition` (or whose `csvMessage()` doesn't match any StM in this Lieferung) are file-level: e.g. file-extension errors, sequence violations across records, `ERR_GET_VERSION`. They stay outside the dedup and are added to the final list as-is.

### Why dedup by `(severity, formattedMessage)` within a single StM

`ValidationMsg.equals/hashCode` excludes `position` but uses `(validationMsgCode, arguments)`. The two emit sites pass different Java types for the record type (`ValidationMsgMapper.java:39` passes a `String`; `SteuerMeldungErmittlungsvorgabeValidators.java:208-209` passes a `RecordType` enum), so `Arrays.equals(args1, args2)` returns `false` even when the rendered text is identical. Keying on the rendered `formattedMessage` (populated in `ValidationMsg`'s constructor) sidesteps the type mismatch and matches exactly what the comparison layer and the user already see.

`formattedMessage` alone is sufficient: the `ValidationMsgCode` template is embedded in the message text, so identical text implies the same code. Severity is also part of the key, so a hypothetical pair of same-text/different-severity messages is preserved as a real conflict rather than silently merged.

First occurrence wins, so the CSV-layer message (precise `CsvMessagePosition` with line and column) is retained over the Ermittlungsvorgabe-layer message (fallback `SteuerMeldungPosition` in the missing-Pflichtfeld case, per `SteuerMeldungErmittlungsvorgabeValidators.java:518-521`).

### Implementation sketch

Replace the existing block in `SteuerMeldungLieferungService.loadAndValidateSteuerMeldungLieferungFromCsv` (lines 71–99) with roughly:

```java
List<ValidationMsg> mappedCsvMsgs = mapToValidationMsgs(
        stichtag,
        bmfVersion,
        steuerMeldungenWithValidations.validationMsgs()
);

IdentityHashMap<CsvMessage, List<ValidationMsg>> csvMsgsByStm = new IdentityHashMap<>();
List<ValidationMsg> fileLevelCsvMsgs = new ArrayList<>();
for (ValidationMsg msg : mappedCsvMsgs) {
    CsvMessage owner = ownerOf(msg);
    if (owner != null) {
        csvMsgsByStm.computeIfAbsent(owner, k -> new ArrayList<>()).add(msg);
    } else {
        fileLevelCsvMsgs.add(msg);
    }
}

List<ValidationMsg> allValidationMsgs = new ArrayList<>(fileLevelCsvMsgs);
Set<LieferungStmKey> seenNewMeldungKeys = new HashSet<>();

steuerMeldungenWithValidations.steuerMeldungen().forEach(steuerMeldung -> {
    if (!steuerMeldung.getCsvMessage().hasRecordType(RecordType.START.name())) {
        log.info("Skipping validation for orphan message {}", steuerMeldung.getCsvMessage());
        return;
    }
    ensureCalculatedGeschaeftsjahre(stichtag, steuerMeldung);

    List<ValidationMsg> perStmMsgs = new ArrayList<>();
    perStmMsgs.addAll(csvMsgsByStm.getOrDefault(steuerMeldung.getCsvMessage(), List.of()));
    perStmMsgs.addAll(statusValidationService.validate(steuerMeldung, stichtag, seenNewMeldungKeys, validationSetting));
    perStmMsgs.addAll(ermittlungsvorgabeValidationService.validate(steuerMeldung));
    perStmMsgs.addAll(domainValidationService.validate(steuerMeldung, stichtag, lieferant));

    allValidationMsgs.addAll(deduplicateByText(perStmMsgs));
});
```

Two private static helpers in the same class:

```java
private static @Nullable CsvMessage ownerOf(ValidationMsg msg) {
    return msg.getPosition() instanceof CsvMessagePosition pos ? pos.csvMessage() : null;
}

private static List<ValidationMsg> deduplicateByText(List<ValidationMsg> msgs) {
    LinkedHashMap<String, ValidationMsg> uniqueByText = new LinkedHashMap<>();
    for (ValidationMsg msg : msgs) {
        String key = msg.getSeverity() + "|" + msg.getFormattedMessage();
        uniqueByText.putIfAbsent(key, msg);
    }
    return new ArrayList<>(uniqueByText.values());
}
```

Notes:

- Partitioning uses `IdentityHashMap` because `CsvSteuerMeldung.getCsvMessage()` returns the same `CsvMessage` instance used to build the message at parse time; identity comparison is correct and avoids relying on a `CsvMessage.equals/hashCode` contract.
- For orphan StMs (skipped by the existing guard at line 85), their CSV-layer messages — if any — are intentionally not deduped against validator output (none runs). They remain in `csvMsgsByStm` un-flushed; to avoid silently dropping them, append `csvMsgsByStm.get(steuerMeldung.getCsvMessage())` inside the orphan branch before `return`.
- No external utility needed. Per `reuse-before-reimplementing.md` I checked `support-libs/core-support` and the existing within-file dedup in `SteuerMeldungStatusValidationService` (`LieferungStmKey` dedup at line 233–263) — neither covers message-text dedup; both helpers are small enough to live inline.

### Scope of dedup

Apply within each StM's combined message list (CSV-layer + status + ermittlungsvorgabe + domain). Any pair of messages with identical user-visible text for the *same StM* is redundant. File-level CSV messages and inter-StM messages are not deduped. The existing asymmetric `CoveredByRule`s in `validation/delta/` (e.g. `FieldNotFilledCoveredBySpecificFieldError`, `WaehrungEmptyCoveredByPflichtFehl`) target legacy-vs-new comparison semantics and stay untouched.

## Critical files

- **Modify**: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` — restructure the validate loop, add `ownerOf` and `deduplicateByText` private helpers, add imports for `CsvMessage`, `CsvMessagePosition`, `IdentityHashMap`, `LinkedHashMap`.
- **Read-only references** for understanding:
  - `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsg.java` — `formattedMessage` is final, set in constructor, accessible via `getFormattedMessage()`.
  - `support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvMessagePosition.java:12` — `csvMessage()` accessor on the record.
  - `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldung.java:29` — `csvMessage` field, exposed via `getCsvMessage()`.
  - `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgMapper.java:38` — one emit site.
  - `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java:204-211` — other emit site.

## Tests

Add to `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungServiceTest.java` (or create if absent — check first):

- **Unit test — `deduplicateByText` helper**: two `ValidationMsg` instances with identical formatted text but different `Position` objects → deduped result has one entry, first one (CSV-layer position) preserved.
- **Unit test — non-duplicates preserved**: two `ValidationMsg`s with different `formattedMessage` → both retained, order unchanged.
- **Unit test — different severities not merged**: same text, different `Severity` → both retained.
- **Unit test — `ownerOf` helper**: `CsvMessagePosition` returns its `csvMessage`; `SteuerMeldungPosition` (or other non-CSV position) returns `null`.

Integration tests in `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/`:

- **Single StM, two layers** — CSV with one START record where `Zuflusszeitpunkt_Anteile_Tranche_Anzahl_e` is empty. Call `loadAndValidateSteuerMeldungLieferungFromCsv(...)`; assert exactly one `ValidationMsg` with `formattedMessage = "Das Pflichtfeld <Zuflusszeitpunkt_Anteile_Tranche_Anzahl_e> im Satz <START> ist nicht befuellt."`.
- **Two StMs, same field empty** — CSV with two distinct StMs (different ISINs), both missing the same Pflichtfeld. Assert exactly **two** `ValidationMsg`s with that formatted text (one per StM) — guards against per-Lieferung over-collapsing.
- **File-level msg not deduped against per-StM msg** — construct a case where a file-level CSV msg and a per-StM msg happen to render identical text (rare but possible). Assert both retained.

## Verification

1. Build the affected module: `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am compile`.
2. Run unit tests: `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test`.
3. Run integration tests focused on the CSV validation flow: `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest='SteuerMeldungDomainValidationServiceTest,QuickRecalculationTest' test`.
4. Re-run the legacy-vs-new comparison job against the input that produced the line-650 example and confirm the second `ERR_PFLICHT_FEHL` no longer appears under `NUR IM NEUSYSTEM (FEHLER)`, while the `EXAKTER TREFFER` entry is preserved.
5. Spot-check comparison reports for files containing multiple StMs that all share the same missing Pflichtfeld — confirm each StM still produces exactly one `ERR_PFLICHT_FEHL` (no cross-StM collapse).

## Out of scope

- Refactoring `CsvSteuerMeldungenWithValidations` / `CsvSteuerMeldungen.internalLoadAndValidateInputSteuerMeldungenFromCsv` so that per-StM CSV messages stay attached to their `CsvSteuerMeldung` from the start. Cleaner architecturally (no position-based partition at the call site), but a larger change touching the loader API. Reconsider if a second use case for per-StM CSV msgs appears.
- Removing `required: true` from CSV schema YAMLs or `Befuellung.MANDATORY` from the Ermittlungsvorgabe — both layers still emit independently for cases where the other doesn't fire (e.g. CSV-only fields like `Zuflusszeitpunkt_e` marked `required: false`; DB/Excel-sourced SteuerMeldungen that bypass the CSV layer).
- Reworking the asymmetric `CoveredByRule` deltas — they target legacy-vs-new comparison semantics and remain useful for their own scenarios.
- Logging suppressed duplicates — not needed; the behavior is deterministic and the dedup is exact-text only.
