# Refactor: validation msgs grouped by scope at the CSV→domain boundary

## Context

The current `fix-acceptance-check-and-preserve-input-meldungen.md` plan patches two bugs around `SteuerMeldungLieferungService`:

- **Issue 1** — the acceptance check at `SteuerMeldungLieferungService.java:110-114` looks only at the three domain validators' output (`perMeldungMsgs`) and never sees per-STM CSV errors like `ERR_SATZ_UNG`, so a malformed CONFIRMED is wrongly accepted.
- **Issue 2** — `DefaultSteuerMeldungLieferung` stores only `Map<LieferungStmKey, SteuerMeldung>`, so two status meldungen with the same business key collapse and the second is lost from the return CSV.

Both bugs share the same root cause: **validation messages and meldungen are flattened into one list / one map at the CSV→domain boundary**, and the scope information (per-file vs per-STM) is then recovered downstream by `instanceof` checks on `position`, by `ownerOf(...)`, and by `ValidationMsgGroups.findSteuerMeldungFor(...)`. Every consumer re-derives the same grouping. The flat shape is also why the acceptance check needs to manually re-attach CSV-derived msgs to a meldung.

This plan replaces that flat shape with a structure that **preserves the natural per-meldung grouping the CSV parser already produces** and **moves CSV→domain mapping into the loader**, so downstream code consumes pre-grouped domain `ValidationMsg`s.

It supersedes the existing patch plan: both bugs disappear as side effects of the new structure.

## End-state data model

Two new domain records replace `CsvSteuerMeldungenWithValidations`. They live in `ifas-domain-stm`, not in `csv-schema`, because they carry domain `ValidationMsg`s (mapping is done at the boundary, see below):

```java
// New: at.oekb.ifas.domain.stm.meldung.LoadedSteuerMeldungen
public record LoadedSteuerMeldungen(
        List<ValidationMsg> fileLevelValidationMsgs,   // file-level scope (CsvFilePosition origin)
        List<LoadedSteuerMeldung> meldungen            // ordered, may have duplicate business keys
) {}

// New: at.oekb.ifas.domain.stm.meldung.LoadedSteuerMeldung
public record LoadedSteuerMeldung(
        CsvSteuerMeldung steuerMeldung,
        List<ValidationMsg> validationMsgs             // CSV-derived msgs already mapped to domain layer
) {}
```

`SteuerMeldungLieferung` carries the same shape after domain validation has run:

```java
public interface SteuerMeldungLieferung {
    List<ValidationMsg> fileLevelValidationMsgs();
    List<ValidatedSteuerMeldung> meldungen();                    // ordered, preserves duplicates (fixes Issue 2)
    Map<LieferungStmKey, SteuerMeldung> steuerMeldungenByKey();  // unchanged, derived; first-wins business-key view
    SteuerMeldungLieferungOrigination origination();
    // ...
}

public record ValidatedSteuerMeldung(
        SteuerMeldung steuerMeldung,
        List<ValidationMsg> validationMsgs   // CSV-derived + status + ermittlungsvorgabe + domain + (later) calculated
) {}
```

A `default List<ValidationMsg> validationMsgs()` on the interface returns the flattened view (`fileLevelValidationMsgs + meldungen.flatMap(...)`) so consumers that genuinely need the flat list keep compiling during migration.

## Mapping timing — at the CSV→domain boundary

Today the CSV→domain mapping (`ValidationMsgMapper.toValidationMsgs(...)`) lives in `SteuerMeldungLieferungService.mapToValidationMsgs(...)` (lines 173-205). It already needs an `Ermittlungsvorgabe`, which is resolved per-message by `CsvSteuerMeldungen.getErmittlungsvorgabe(csvMessage, …)`.

Move the mapping into `CsvSteuerMeldungen.validateAndTransformCsvMessages(...)` (line 119), where the `Ermittlungsvorgabe` is already in hand for each iteration. The loader emits domain `ValidationMsg`s grouped per meldung; file-level CSV msgs (from `csvFile.getValidationMsgs()`) get mapped with a `null` ermittlungsvorgabe and become `fileLevelValidationMsgs`. After this, **nothing downstream of the loader needs to know about `CsvValidationMsg`**.

Justifications for this boundary:

- The loader already iterates per `CsvMessage` and already resolves the per-message `Ermittlungsvorgabe`. Reusing it for the mapping costs nothing.
- `CsvSteuerMeldung implements SteuerMeldung`, so the loader already produces domain types. The validation list should follow suit.
- Pushing mapping earlier eliminates the only reason `SteuerMeldungLieferungService` ever touches `CsvValidationMsg`, `CsvFilePosition`, `CsvMessagePosition`.
- Pushing mapping later (e.g. into each writer) would multiply the call sites and require carrying the Ermittlungsvorgabe further than necessary.

Per **Reuse Before Reimplementing**: `ValidationMsgMapper` is reused as-is; the new code is only the grouping logic in the loader.

## What this kills downstream

The grouped shape eliminates several "re-derive ownership" workarounds:

- `SteuerMeldungLieferungService.ownerOf(...)` (lines 212-221) — no longer needed; ownership is structural.
- `SteuerMeldungLieferungService.deduplicateByStmAndText(...)` (lines 233-245) — collapse becomes per-bucket: dedupe within each `ValidatedSteuerMeldung.validationMsgs()` keyed on `(severity, formattedMessage)`, dedupe within `fileLevelValidationMsgs` keyed on `(lineNumber, severity, formattedMessage)`. Owners are never compared across buckets.
- `ValidationMsgGroups.findSteuerMeldungFor(...)` / `createSteuerMeldungLookupMap(...)` (`ValidationMsgGroups.java:95-128`) — the lookup map disappears; `ValidationMsgLogWriter` walks `lieferung.fileLevelValidationMsgs()` and `lieferung.meldungen()` directly. `getLineNumber(...)` stays as a sort key helper.
- `ValidationMsgs.getRelatedValidationMsgs(stm, allValidationMsgs)` (used at `SteuerlicheErmittlungDomainService.java:156, 324`) — becomes a direct bucket lookup by meldung identity.
- The Issue 1 patch in `SteuerMeldungLieferungService` (the per-`CsvMessage` partition map proposed in the existing plan) is no longer needed — `perMeldungMsgs` is the meldung's own bucket, which already contains CSV-derived msgs.

## Where calculated validations attach

`SteuerlicheErmittlungDomainService` runs `calculatedSteuerMeldungValidationService.validate(...)` (line 107) and today flat-merges the result with `lieferung.validationMsgs()` (lines 114-116). Calculated msgs are always per-meldung (their position is `SteuerMeldungPosition` or a field-position rooted in a meldung), so they should be appended to that meldung's bucket. Approach:

- `calculatedSteuerMeldungValidationService` already produces `List<ValidationMsg>` grouped per processed meldung. Either iterate per meldung and merge into a derived `SteuerMeldungLieferung` view, or change `SteuerlicheErmittlungErgebnis.Simple` to carry a `Map<SteuerMeldung, List<ValidationMsg>> calculatedValidationMsgsByMeldung` and combine on read.
- The flat `mergedValidationMsgs` accumulator (`SteuerlicheErmittlungDomainService.java:114-116`) can stay as a derived view if `RecalculationDomainService` / `ValidationDeltaReports` still want it during migration (see below).

`ProcessedSteuerMeldung` already exposes `getSourceEntry()` returning the original `CsvMessage` (used by `ValidationMsgGroups.findSteuerMeldungFor` today, lines 110-128). That same hook lets us look up the bucket key (the original `SteuerMeldung`/`CsvSteuerMeldung`) for any calculated msg whose position references a `ProcessedSteuerMeldung`.

## Consumers — what changes vs. stays

**Stays (consume flat `validationMsgs()`):**
- `RecalculationDomainService` / `BundleRecalculationResult.ergebnis().validationMsgs()` — the delta comparison against legacy log text doesn't care about grouping. Keep the default flat accessor.
- `ValidationDeltaReports` — operates on pre-grouped reports already; the input is the flat list. Unchanged.
- `RecalculationOutputs.writeReturnCsv` (`RecalculationOutputs.java:352-362`) — reads `ergebnis().returnSteuerMeldungen()`, never touches `validationMsgs()`. Issue 2 is fixed because `returnSteuerMeldungen()` now flows from the ordered `meldungen()` list (see below), not the deduped business-key map.

**Switches to grouped accessors:**
- `ValidationMsgLogWriter` (and via it `ValidationMsgLogs.writeLog(...)`) — file-level header iterates `lieferung.fileLevelValidationMsgs()`; the per-Meldung section iterates `lieferung.meldungen()`. Sort still by min line number.
- `SteuerMeldungLieferungService` per-meldung loop — `perMeldungMsgs` becomes "the meldung's bucket + domain-validator output", acceptance check unchanged in spirit.
- `SteuerlicheErmittlungDomainService` per-meldung processing (lines 156, 324) — `ValidationMsgs.getRelatedValidationMsgs(inputStm, …)` becomes a direct bucket lookup.

## Files to change

The refactor is scoped to two areas; new code is mechanical re-shaping of data already present.

**New files**
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/LoadedSteuerMeldungen.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/LoadedSteuerMeldung.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/ValidatedSteuerMeldung.java`

**Modify**
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvSteuerMeldungen.java` — return `LoadedSteuerMeldungen`; map per-message via `ValidationMsgMapper` inside `validateAndTransformCsvMessages`; map file-level via `ValidationMsgMapper(null)` from `csvFile.getValidationMsgs()`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` — orchestrator now (i) calls loader, (ii) for each `LoadedSteuerMeldung` seeds `perMeldungMsgs` from its CSV-derived list and appends the three domain validators, (iii) builds `SteuerMeldungLieferung` carrying `List<ValidatedSteuerMeldung>` and `List<ValidationMsg> fileLevelValidationMsgs`. Delete `mapToValidationMsgs`, `ownerOf`, `DedupKey`; rewrite `deduplicateByStmAndText` to operate per bucket.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferung.java` — add `fileLevelValidationMsgs()`, `meldungen()` (returning `List<ValidatedSteuerMeldung>`), keep `steuerMeldungenByKey()`. Provide `default List<ValidationMsg> validationMsgs()` that flattens.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/DefaultSteuerMeldungLieferung.java` — store `List<ValidatedSteuerMeldung>` + derive `Map<LieferungStmKey, SteuerMeldung>` via `SteuerMeldungLieferungen.getSteuerMeldungenByKey(...)` (Issue 2 fix). `countSteuerMeldungenWithStatus` iterates the ordered `meldungen()` list.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroups.java` — collapse to a thin sort helper (or delete; `ValidationMsgLogWriter` walks `lieferung.meldungen()` directly).
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgLogWriter.java` — drop `getMsgGroupBySeverity` indirection; iterate the grouped lieferung directly. Sort per-meldung blocks by their min line number using `LoadedSteuerMeldung.steuerMeldung().getCsvMessage().getFirstLineNr()`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java` — attach calculated msgs to their meldung's bucket; replace `ValidationMsgs.getRelatedValidationMsgs` calls (lines 156, 324) with direct bucket lookups; keep a flat `validationMsgs()` accessor on the result for `RecalculationDomainService`'s legacy delta consumer.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungErgebnis.java` (and `Simple` impl) — carry the grouped lieferung; expose flat `validationMsgs()` as a default.

**Probably touch (mechanical call-site updates)**
- Dev tools / tests reading `CsvSteuerMeldungenWithValidations.validationMsgs()`: `CsvExcelToolService`, `ExcelSteuerMeldungRawWriter`, `CsvSteuerMeldungRoundTripTool` — switch to `flattened()` view if they don't care about scope.
- Existing call sites of `lieferung.steuerMeldungenByKey().values().stream()` — same call-site walk described in the existing plan's Issue-2 pattern: choose `meldungen()` (full ordered list) for processing/counting, keep `steuerMeldungenByKey()` for business-key lookups (notably the per-business-key diff index in `RecalculationDomainService.java:151-154`).
- `CsvSteuerMeldungenWithValidations.java` — delete after migration.

## How this fixes the two bugs

- **Issue 1**: `perMeldungMsgs` in the orchestrator now starts from `loadedMeldung.validationMsgs()` (the meldung's CSV-derived domain msgs, already mapped). `ERR_SATZ_UNG` is in there. The acceptance check that reads `perMeldungMsgs` immediately sees the ERROR and refuses to call `acceptedState.accept(steuerMeldung)`. The spurious `ERR_STATUS_NM_LIEFERUNG` on the second meldung disappears. No special-case code; the data shape carries the fact.
- **Issue 2**: `DefaultSteuerMeldungLieferung.meldungen()` returns the ordered input list (with duplicates by business key), the deduped map is derived. `returnSteuerMeldungen()` and downstream output writers iterate the list, so both `STATUS;ERROR;649560` rows appear in `_return#recalc.csv`. The business-key map continues to back `LieferungStmKey` lookups.

The comment update in `ValidationDeltaReports.java:31-44` from the existing plan still applies (the "new-system-stricter-by-design" rationale is wrong once Issue 1 is fixed). `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` membership stays as is; it exists for the covered-by-pairing reason, not for this bug.

## Migration order — two PRs

Each step compiles and tests independently. PR1 already delivers Issue 1; PR2 delivers Issue 2 and the downstream simplification.

**PR1 — loader-side grouping + Issue 1 fix**
1. Add `LoadedSteuerMeldungen` / `LoadedSteuerMeldung` records.
2. Refactor `CsvSteuerMeldungen.internalLoadAndValidateInputSteuerMeldungenFromCsv` to return `LoadedSteuerMeldungen`. Map per-message inside `validateAndTransformCsvMessages` using the already-resolved `Ermittlungsvorgabe`; map file-level from `csvFile.getValidationMsgs()` with `ValidationMsgMapper(null)`. Delete `CsvSteuerMeldungenWithValidations` once the loader no longer references it.
3. Update `SteuerMeldungLieferungService.loadAndValidateSteuerMeldungLieferungFromCsv` to consume the new shape; drop `mapToValidationMsgs` / `ownerOf`. Acceptance check now reads the meldung's bucket (Issue 1 fixed). `deduplicateByStmAndText` becomes per-bucket dedupe. `SteuerMeldungLieferung` still carries only a flat `List<ValidationMsg> validationMsgs()` at this point — the orchestrator flattens before building it, so no downstream change is needed yet.

**PR2 — lieferung-side grouping + Issue 2 fix + downstream simplification**
4. Introduce `ValidatedSteuerMeldung`; widen `SteuerMeldungLieferung` with `fileLevelValidationMsgs()` and `meldungen()` (returning `List<ValidatedSteuerMeldung>`). Provide `default List<ValidationMsg> validationMsgs()` that flattens. Update `DefaultSteuerMeldungLieferung` to store the list + derive the map (Issue 2 fixed).
5. Switch `SteuerlicheErmittlungDomainService` to attach calculated msgs per-meldung; keep the flat accessor on `SteuerlicheErmittlungErgebnis` for `RecalculationDomainService`.
6. Simplify `ValidationMsgLogWriter` / `ValidationMsgGroups` to consume the grouped lieferung directly.
7. Walk `steuerMeldungenByKey().values()` call sites (same pattern as in the superseded plan's Issue 2 migration) and pick `meldungen()` vs `steuerMeldungenByKey()` per intent.

## Cleanup before starting

Archive the superseded patch plan: move `plans/fix-acceptance-check-and-preserve-input-meldungen.md` to `plans/archive/`. Both bugs it describes are now fixed structurally by this plan.

## Verification

- `mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy` — unit tests pass.
- `mvn -pl ifas-testing/ifas-integration-tests test -Dtest=GrossfileRecalculationTest -Pno-proxy` — `gf2-d20260731` baseline shifts: one fewer `[+] NUR IM NEUSYSTEM (WARNUNG)` for `ERR_STATUS_NM_LIEFERUNG` (Issue 1) and `LU0134335420`'s `_return#recalc.csv` regains its second `STATUS;ERROR;649560` row (Issue 2). Update `GrossfileRecalculationTest.baselines()` accordingly.
- Inspect `target/grossfile-recalc/gf2-d20260731/`:
  - `error#diff.txt` row 29 (LU0134335420) — no `[+] NUR IM NEUSYSTEM` for `ERR_STATUS_NM_LIEFERUNG`.
  - `gf2-d20260731_return#recalc.csv` — both `STATUS;ERROR;649560` blocks present.
- Existing integration test `ValidationMsgLogsIntegrationTest` (T07 case) still produces the same `error.log`/`info.log` ordering — verifies that the writer rewrite kept formatting stable.

## Out of scope

- Removing `_LIEFERUNG` codes from `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` — these stay for covered-by-pairing reasons; only the rationale comment changes.
- Whether `LieferungStmKey` should include `stmId`/`status` for status-update meldungen — sidestepped by preserving the ordered list.
- Persisting `ValidationMsg`s to DB — `SteuerMeldungPersistenceService` is stubbed; persistence model is a separate piece of work.
- Aligning `CsvValidationMsg.Severity{INFO,WARN,ERROR}` with `ValidationMsg.Severity{ERROR,INFO,OEKBINFO}` — `ValidationMsgMapper` already handles this asymmetrically; no change.
