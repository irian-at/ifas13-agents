# Fix spurious in-Lieferung error + return-CSV missing row

## Context

Two related divergences in the gf2-d20260731 grossfile recalc, both surfacing on `LU0134335420` / stmId `649560` (lines 18 and 29 of the input — two status meldungen, CONFIRMED then DELETE on the same stmId):

**Issue 1 — spurious `ERR_STATUS_NM_LIEFERUNG` on the second meldung.**
Both meldungen are wrongly typed (CONFIRMED/DELETE meldungen include data records like `EA`, `E`, `D`, `Z`, `ZA`, `AS` that they are not allowed to have). Legacy declines the first meldung at the CSV-schema layer (`ERR_SATZ_UNG`) and so it never updates its in-memory state; the second meldung therefore reports only the DB-state `ERR_STATUS_NM` (same as legacy did). The new system's acceptance check at `SteuerMeldungLieferungService.java:110-114` inspects only the *per-meldung domain-validator* messages — it never sees the CSV-schema-level `ERR_SATZ_UNG` errors that hang off the meldung's `CsvMessage`. The first CONFIRMED therefore looks "clean" to the acceptance logic, gets recorded in `InLieferungAcceptedState`, and the second DELETE is dispatched to `ERR_STATUS_NM_LIEFERUNG` — a new-only diff that today is auto-downgraded to a warning by `ValidationDeltaReports.MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` with the comment that this is "new-system-stricter-by-design". It isn't — it's a bug.

**Issue 2 — second meldung missing from `_return#recalc.csv`.**
`DefaultSteuerMeldungLieferung` (`DefaultSteuerMeldungLieferung.java:19-25`) is constructed from a `List<SteuerMeldung>` but stored as `Map<LieferungStmKey, SteuerMeldung>` via `SteuerMeldungLieferungen.getSteuerMeldungenByKey(...)`. `LieferungStmKey = (isin, jahresdatenmeldung, gjEnde, selbstnachweis)` — a *business* key with no `status`/`stmId`. Two status-update meldungen for the same fund/year share the same key, so the second is dropped at construction with a `WARN` log. Per-meldung validation still runs (it happens *before* the lieferung is built, on the raw `steuerMeldungenWithValidations.steuerMeldungen()` list at `SteuerMeldungLieferungService.java:88`), which is why both errors appear in `error.log`. But everything downstream — `ergebnis.returnSteuerMeldungen()`, the per-business-key diff in `RecalculationDomainService`, and the return-CSV writer at `RecalculationOutputs.java:352-362` — pulls from the lieferung's deduped map, so the return CSV emits only one of the two `STATUS;ERROR` rows. Legacy preserves both.

The two bugs are independent but both stem from the same input shape (two status meldungen for one stmId in one Lieferung). We fix them independently.

## Issue 1 — Surface per-STM CSV-derived ValidationMsgs in `perMeldungMsgs` (fix timing/loading)

### Diagnosis (refined)

The mapping pipeline already exists and is correct — the bug is purely a **timing/loading** problem at the call site:

- CSV parsing produces `CsvValidationMsg`s; their `position` field already distinguishes per-STM scope (`CsvMessagePosition` or `SteuerMeldungPosition`) from per-file scope (`CsvFilePosition` and the like).
- `SteuerMeldungLieferungService.mapToValidationMsgs(...)` (lines 174-205) **already maps every `CsvValidationMsg` to a `ValidationMsg`** via the existing `ValidationMsgMapper`, including per-STM errors like `ERR_SATZ_UNG`.
- The mapped result is appended to the lieferung-wide `allValidationMsgs` (line 72-76) **before** the per-meldung forEach runs.
- But inside the forEach (lines 88-116), `perMeldungMsgs` is built only from the three domain validators — it does **not** see the per-STM `ValidationMsg`s that already exist for this meldung in `allValidationMsgs`.
- The acceptance check at 110-114 inspects only `perMeldungMsgs`, so it never sees `ERR_SATZ_UNG` and wrongly accepts the meldung.

No new check or helper is needed — we already have:
- The CSV→domain mapping (`ValidationMsgMapper` via `mapToValidationMsgs`).
- A helper that tells us which STM a `ValidationMsg` belongs to: `SteuerMeldungLieferungService.ownerOf(ValidationMsg)` (lines 212-221), returning the meldung's `CsvMessage` for per-STM msgs and `null` for per-file msgs.

### File to modify
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` — restructure lines ~72-116.

### Change

After `mapToValidationMsgs`, split the mapped `ValidationMsg`s into **per-STM** (grouped by the meldung's `CsvMessage`) and **per-file** (no STM). Inside the forEach, seed `perMeldungMsgs` with the meldung's per-STM `ValidationMsg`s. Per-file msgs go directly into `allValidationMsgs`. The acceptance check stays exactly as it is — `perMeldungMsgs` simply becomes the unified per-STM view.

Sketch (names describe shape, not origin: values are `ValidationMsg`s post-mapping):
```java
// Map all CSV msgs once via the existing mapper.
List<ValidationMsg> mappedValidationMsgs = mapToValidationMsgs(
        stichtag, bmfVersion, steuerMeldungenWithValidations.validationMsgs());

// Partition mapped ValidationMsgs by scope.
Map<CsvMessage, List<ValidationMsg>> validationMsgsByCsvMessage = new LinkedHashMap<>();
List<ValidationMsg> fileLevelValidationMsgs = new ArrayList<>();
for (ValidationMsg msg : mappedValidationMsgs) {
    CsvMessage stm = ownerOf(msg);
    if (stm == null) {
        fileLevelValidationMsgs.add(msg);
    } else {
        validationMsgsByCsvMessage.computeIfAbsent(stm, k -> new ArrayList<>()).add(msg);
    }
}

List<ValidationMsg> allValidationMsgs = new ArrayList<>(fileLevelValidationMsgs);

InLieferungAcceptedState acceptedState = new InLieferungAcceptedState();

steuerMeldungenWithValidations.steuerMeldungen().forEach(steuerMeldung -> {
    if (!steuerMeldung.getCsvMessage().hasRecordType(RecordType.START.name())) {
        log.info("Skipping validation for orphan message {}", steuerMeldung.getCsvMessage());
        return;
    }
    ensureCalculatedGeschaeftsjahre(stichtag, steuerMeldung);

    List<ValidationMsg> perMeldungMsgs = new ArrayList<>();
    // seed with this STM's CSV-derived ValidationMsgs (already mapped)
    perMeldungMsgs.addAll(validationMsgsByCsvMessage.getOrDefault(steuerMeldung.getCsvMessage(), List.of()));
    // domain validators
    perMeldungMsgs.addAll(statusValidationService.validate(steuerMeldung, stichtag, acceptedState, validationSetting));
    perMeldungMsgs.addAll(ermittlungsvorgabeValidationService.validate(steuerMeldung));
    perMeldungMsgs.addAll(domainValidationService.validate(steuerMeldung, stichtag, lieferant));

    allValidationMsgs.addAll(perMeldungMsgs);

    // Acceptance check unchanged — perMeldungMsgs is now the unified per-STM view.
    boolean producedError = perMeldungMsgs.stream()
            .anyMatch(msg -> msg.getSeverity() == ValidationMsg.Severity.ERROR);
    if (!producedError) {
        acceptedState.accept(steuerMeldung);
    }
});
```

What's reused (no new code introduced):
- `mapToValidationMsgs(...)` — the same lieferung-wide CSV mapper, just consumed differently.
- `ValidationMsgMapper` — unchanged.
- `ownerOf(ValidationMsg)` (lines 212-221) — already distinguishes per-STM (returns the meldung's `CsvMessage`) from per-file (returns `null`); we drive the partition from it.

What this changes vs. today:
- `allValidationMsgs` accumulation order shifts slightly: per-file msgs first, then per-STM blocks (each block: CSV-derived-for-STM followed by domain). `deduplicateByStmAndText` (lines 233-245) keys on `(owner, severity, formattedMessage)` with first-occurrence-wins, so dedup outcomes for the same STM are stable.
- No double-counting: each mapped CSV-derived `ValidationMsg` lands in `allValidationMsgs` exactly once — via `perMeldungMsgs` for per-STM, directly for per-file.

### Cleanup of the now-incorrect comment

`ValidationDeltaReports.java:31-44` documents `_LIEFERUNG` codes as auto-warning because the new system "declines the first row upstream … new-system-stricter-by-design, not a regression". After this fix the new system declines as well, so the rationale changes: legacy and new now agree on the second row's outcome. Update or remove that note; `ERR_STATUS_NM_LIEFERUNG`, `ERR_UPD_OLDM_LIEFERUNG`, `ERR_JAHRESM_VORH_LIEFERUNG`, `ERR_AUSSCHM_VORH_LIEFERUNG` should likely stay in the always-warning set for other reasons (covered-by pairing), but the justification needs revising. Don't change the set membership in this PR — only the comment.

## Issue 2 — Preserve the input list alongside the map

### Files to modify

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferung.java` — add a `List<SteuerMeldung> steuerMeldungen()` accessor (the ordered, non-deduplicated source-of-truth list).
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/DefaultSteuerMeldungLieferung.java` — record now stores both `List<SteuerMeldung> steuerMeldungen` and `Map<LieferungStmKey, SteuerMeldung> steuerMeldungenByKey`. The map continues to be derived via `SteuerMeldungLieferungen.getSteuerMeldungenByKey(steuerMeldungen)` so its first-wins semantics are preserved for business-key lookups.

### Consumer updates

For each call site that currently does `lieferung.steuerMeldungenByKey().values().stream()`, decide whether it wants the deduped business-key view or the full input list. Convert to `lieferung.steuerMeldungen().stream()` where the full list is correct. Representative call sites:

- `SteuerlicheErmittlungDomainService.java:88, 93` — produces `processedSteuerMeldungen`; should iterate the full list so each input meldung is processed. **Switch to `steuerMeldungen()`.**
- `SteuerMeldungLieferung.java:53` `countSteuerMeldungenWithStatus` — counts by status. **Switch to `steuerMeldungen()`** so duplicate-business-key status updates each count.
- `BundleRecalculationResult` data accessors (e.g., `inputSteuerMeldungen` at `RecalculationDomainService.java:150`, `303`) — these feed the per-business-key diff comparison. **Keep using `steuerMeldungenByKey()`** because the diff index is genuinely per-business-key.
- `RecalculationDomainService.java:151-154` (`returnSteuerMeldungen` map for diff comparison) — Keep map. The diff index is per-business-key.

The return-CSV pipeline already reads `result.ergebnis().returnSteuerMeldungen()` (a `List<ProcessedSteuerMeldung>` from `SteuerlicheErmittlungErgebnis.Simple`) — once Issue 2 is fixed at the lieferung level, this list contains both meldungen and the writer at `CalculationOutputs.java:101` / `RecalculationOutputs.java:352` emits both rows. No writer-side change needed.

### Pattern for migrating call sites

There are many call sites of `steuerMeldungenByKey().values()`. The migration pattern is mechanical and should be done in two passes:

1. Add the new `steuerMeldungen()` accessor; default-implement it on the interface as `List.copyOf(steuerMeldungenByKey().values())` so existing implementations keep compiling.
2. Update `DefaultSteuerMeldungLieferung` to store and return the real input list.
3. Walk every `steuerMeldungenByKey().values()` site and decide list vs. map based on intent (is the caller iterating for processing → list; or doing a business-key lookup → map).

Keep the default-implementation step until all callers are walked, so partial migration is safe.

## Verification

1. `mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy` — unit tests pass.
2. `mvn -pl ifas-testing/ifas-integration-tests test -Dtest=GrossfileRecalculationTest -Pno-proxy` — full grossfile suite. Expect `gf2-d20260731` baseline to shift: one fewer `[+] NUR IM NEUSYSTEM (WARNUNG)` (the spurious `ERR_STATUS_NM_LIEFERUNG` from issue 1 disappears), and the `_return#recalc.csv` for `LU0134335420` regains its second row (issue 2). Update `GrossfileRecalculationTest.baselines()` to match.
3. Manually inspect `target/grossfile-recalc/gf2-d20260731/`:
   - `error#diff.txt` row 29 (LU0134335420): the `[+] NUR IM NEUSYSTEM` for `ERR_STATUS_NM_LIEFERUNG` should be gone.
   - `gf2-d20260731_return#recalc.csv`: should contain both `STATUS;ERROR;649560` blocks like the legacy `_return.csv`.

## Out of scope

- Removing `ERR_STATUS_NM_LIEFERUNG` / `ERR_UPD_OLDM_LIEFERUNG` / `ERR_JAHRESM_VORH_LIEFERUNG` / `ERR_AUSSCHM_VORH_LIEFERUNG` from the always-warning set in `ValidationDeltaReports.java` — those exist for other reasons (covered-by pairing with their DB-existence counterparts) and should not be touched here.
- The bigger question of whether `LieferungStmKey` should include `stmId` / `status` for status-update meldungen. The "preserve list" fix sidesteps the question for the return-CSV case; if downstream lookups need to distinguish CONFIRMED from DELETE for the same business key, that's a separate piece of work.
- Re-evaluating the auto-WARNING downgrade for `_LIEFERUNG` codes once issue 1 is fixed — likely the comment was wrong, but changing the rule is a separate PR.