# Revisit gf-diff solution: per-ISIN dedup is wrong — switch to sequential overlay with first-valid-wins

## Context

The within-Lieferung duplicate detection introduced in commit `6da611a9` ("feat: add new within-file duplicate validation rules and tests") enforces an invariant that is too coarse:

> *"Invariant: each ISIN appears at most once per lieferung. The first row for an ISIN is accepted; every subsequent row for the same ISIN is rejected."*
> — `SteuerMeldungStatusValidationService.java:247-248`

That invariant does not match legal Lieferung shapes. A single Lieferung can legitimately carry **multiple Meldungen for the same ISIN** with different Meldungsart combinations:

- Ausschüttungsmeldung (`jahresdatenmeldung=false`)
- Jahresmeldung (`jahresdatenmeldung=true`)
- Selbstnachweis-Jahresmeldung (`jahresdatenmeldung=true`, `selbstnachweis=true`)

All three should coexist. The current code spuriously flags the second and third as within-file duplicates and emits `ERR_*_VORH_LIEFERUNG` / `ERR_STATUS_NM_LIEFERUNG` / `ERR_UPD_OLDM_LIEFERUNG` against them.

The correct domain rule, as confirmed by the user, is:

> **For Meldungen sharing the same business key within one Lieferung, the first Meldung that does not produce a validation error is accepted; subsequent Meldungen targeting the same key see the post-acceptance state.**

Business key here is **per intent**:

| Validator family                              | Business key                                                              |
|-----------------------------------------------|---------------------------------------------------------------------------|
| NEW (Jahres/Ausschüttungs) dup check          | `(ISIN, jahresdatenmeldung, gjEnde, selbstnachweis)`                      |
| State transition (CONFIRMED, DELETE, UPDATE)  | `stmId`                                                                   |

This subsumes the gf2 analysis Entries 1 & 3 (duplicate `CONFIRMED 649534` / `DELETE 649542` on the same stmId) — the second CONFIRMED/DELETE will fail naturally because the overlay-updated previous-status is FINAL, not OPEN.

It also fixes the over-firing of `_LIEFERUNG` codes for the legitimate-coexistence cases.

The uncommitted `LeiUnglVorhExpectedLegacyOnly` work (Entry 2, LEI suppression) is **out of scope** for this revisit — it addresses a separate architectural divergence and stays as-is.

## Approach: sequential validation with `InLieferungAcceptedState`

Replace the per-ISIN flag-and-reject with a sequential pass that maintains a mutable `InLieferungAcceptedState` layered on top of the DB snapshot. The name encodes the rule: only meldungen that have been *accepted* (no validation errors) earlier *in this Lieferung* contribute to the state subsequent meldungen are validated against.

The existing `_LIEFERUNG` error codes are kept. They give the user a meaningful diagnostic distinction — "this NEW conflicts with another NEW in the same file" reads very differently from "this NEW conflicts with what's already in the database". The state class makes the *source* of the conflict (in-Lieferung vs DB) explicit, and the validators pick the matching code from that source.

### Data shape

A new class in `validation/status/`. Three fields, each tracking one kind of acceptance; all field names lead with what was *accepted*, not with how the storage works:

```java
@NullMarked
final class InLieferungAcceptedState {

    // stmId -> the status the stmId now has after an accepted CONFIRMED or DELETE
    // earlier in this Lieferung (CONFIRMED -> FINAL, DELETE -> DELETED).
    // Subsequent CONFIRMED/DELETE on the same stmId read this as their effective
    // previousStatus and trip ERR_STATUS_NM_LIEFERUNG.
    private final Map<Long, StmStatus> statusAfterAcceptedTransition = new HashMap<>();

    // stmIds for which an UPDATE has already been accepted in this Lieferung.
    // Only one successful UPDATE per stmId is possible per Lieferung — the accepted
    // UPDATE creates a successor, so any further UPDATE on the same stmId must
    // trip ERR_UPD_OLDM_LIEFERUNG. The would-be successor's stmId is assigned
    // later by persistence and is not needed by any validator; a Set suffices.
    private final Set<Long> stmIdsWithAcceptedUpdate = new HashSet<>();

    // Business keys of NEW meldungen that have been accepted in this Lieferung.
    // A second NEW with the same business key must trip
    // ERR_JAHRESM_VORH_LIEFERUNG / ERR_AUSSCHM_VORH_LIEFERUNG.
    private final Map<NewMeldungKey, Long> stmIdsOfAcceptedNew = new HashMap<>();

    StmStatus effectivePreviousStatus(Long stmId, StmStatus dbStatus) { ... }
    boolean wasUpdatedInLieferung(Long stmId) { ... }
    boolean hasAcceptedNew(NewMeldungKey key) { ... }

    void accept(SteuerMeldung meldung) { ... }   // updates exactly one field per call
}

record NewMeldungKey(@Nullable String isin,
                    @Nullable Boolean jahresdatenmeldung,
                    @Nullable LocalDate gjEnde,
                    @Nullable Boolean selbstnachweis) { }
```

`accept(meldung)` dispatches by the accepted meldung's status:

| Accepted meldung status | Effect on `InLieferungAcceptedState`                                       |
|-------------------------|----------------------------------------------------------------------------|
| NEW                     | `stmIdsOfAcceptedNew.put(newMeldungKey(meldung), meldung.stmId())`         |
| CONFIRMED               | `statusAfterAcceptedTransition.put(stmId, FINAL)`                          |
| DELETE                  | `statusAfterAcceptedTransition.put(stmId, DELETED)`                        |
| UPDATE                  | `stmIdsWithAcceptedUpdate.add(stmId)`                                      |

`NewMeldungKey` deliberately differs from `LieferungStmKey` (which is `(isin, jahresdatenmeldung, gjEnde)`) by including `selbstnachweis`. Per user direction, Selbstnachweis is a separate coexistence dimension. We do **not** repurpose `LieferungStmKey` because two existing callers depend on the current shape (see archived plan `within-file-duplicate-meldung-dropped.md` for the rationale).

### Pipeline change

In `SteuerMeldungLieferungService` (currently iterates the meldung list and calls `statusValidationService.validate(steuerMeldung, stichtag, seenIsins, ...)` per meldung):

1. Construct a single `InLieferungAcceptedState` per Lieferung.
2. For each meldung **in CSV order**:
   a. Run status / Ermittlungsvorgabe / domain validation as today — but the status validator receives `InLieferungAcceptedState` so its previous-meldung view is overlay-adjusted.
   b. Collect `validationMsgs` for this meldung.
   c. If `validationMsgs.stream().noneMatch(m -> m.getSeverity() == ERROR)` (Info/Warnings do not block) → `acceptedState.accept(steuerMeldung)`.
   d. Otherwise: leave `acceptedState` untouched. The meldung is rejected for acceptance purposes; its errors are still reported.

The "no ERROR" criterion is the operational definition of "produces no validation error" for the accept rule. INFO/WARN do not block acceptance — those exist for diagnostic purposes (e.g. `errUnglVorh` downgraded to INFO on UPDATE in legacy).

### Validator integration — distinguish source, pick the matching code

Each previous-state lookup gains a precedence: check `InLieferungAcceptedState` first; on hit, fire the `_LIEFERUNG` variant. On miss, fall back to the DB-snapshot lookup; on hit there, fire the plain code.

- `errStatusNm` (`SteuerMeldungStatusValidators.java:170-193`) — currently reads `previousSteuerMeldung.getStatus()`. Change to:
  - If `acceptedState.statusAfterAcceptedTransition` has an entry for the stmId → that entry's status is the conflict source → emit `ERR_STATUS_NM_LIEFERUNG`.
  - Otherwise, if `dbStatus != OPEN` and the delivered status is CONFIRMED/DELETE → emit plain `ERR_STATUS_NM`.

- `errJahresmVorh` / `errAusschmVorh` (called from `SteuerMeldungStatusValidationService.java:116-132`) — currently fires when `existingSteuerMeldungStmId != null` (DB-only). Change to:
  - If `acceptedState.hasAcceptedNew(newMeldungKey(steuerMeldung))` → emit `ERR_JAHRESM_VORH_LIEFERUNG` / `ERR_AUSSCHM_VORH_LIEFERUNG`.
  - Otherwise, if the DB lookup `findExistingMeldungStmIdByGjEndeAndJahresMeldung` returns non-null → emit plain `ERR_JAHRESM_VORH` / `ERR_AUSSCHM_VORH`.

- `errUpdOldm` (`SteuerMeldungStatusValidators.java:247-261`) — currently fires when `findLatestUndeletedSuccessorStmId` returns a successor. Change to:
  - If `acceptedState.wasUpdatedInLieferung(stmId)` → emit `ERR_UPD_OLDM_LIEFERUNG`.
  - Otherwise, on a DB successor → emit plain `ERR_UPD_OLDM`.

This keeps the legacy `CoveredByRule` mapping intact: legacy raises plain `ERR_*` in both situations; the new system either raises plain `ERR_*` (DB source) — exact match against legacy — or `ERR_*_LIEFERUNG` (in-Lieferung source) — bridged via the existing `CoveredByRule`s. No delta-machinery changes needed.

### What gets removed (and what stays)

Remove:

- `validateWithinFileIsinDuplicate` in `SteuerMeldungStatusValidationService.java:282-298` and the `seenIsins`-based `validate(...)` overload at line 254. Their job — emitting `_LIEFERUNG` codes — moves into the validators themselves, gated by `InLieferungAcceptedState` instead of by the too-coarse per-ISIN set.
- The `seenIsins: Set<String>` parameter threaded from the caller. Replaced by `InLieferungAcceptedState`.

Keep (no changes beyond invocation site):

- `ERR_JAHRESM_VORH_LIEFERUNG`, `ERR_AUSSCHM_VORH_LIEFERUNG`, `ERR_STATUS_NM_LIEFERUNG`, `ERR_UPD_OLDM_LIEFERUNG` enum values.
- `errStatusNmLieferung`, `errJahresmVorhLieferung`, `errAusschmVorhLieferung`, `errUpdOldmLieferung` validator methods — they're now called from the main validator path when `InLieferungAcceptedState` reports a hit, not from a blanket "ISIN seen before" branch.
- The `CoveredByRule`s mapping legacy plain codes ↔ new `_LIEFERUNG` codes.
- `ValidationMsgCodePattern` entries for the `_LIEFERUNG` codes.

### Files to modify

Primary:

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/InLieferungAcceptedState.java` — **new**, see shape above.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/NewMeldungKey.java` — **new** record.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java` — thread `InLieferungAcceptedState` through the `validate(...)` entry points; drop the `seenIsins`-based overload and `validateWithinFileIsinDuplicate`; route `errStatusNm` / `errStatusNmLieferung` (and the NEW / UPDATE pairs) via overlay-first, DB-fallback precedence.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidators.java` — the four pairs (plain + `_LIEFERUNG`) stay; the dispatch moves into their callers in the service.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` — drive the sequential pass; construct one `InLieferungAcceptedState` per Lieferung; pass it to the status validator; call `acceptedState.accept(...)` only when the meldung produced no ERROR-severity message.

Unchanged (intentionally):

- `ValidationMsgCode.java` — `_LIEFERUNG` enum values stay.
- `ValidationMsgCodePattern.java` — `_LIEFERUNG` regex entries stay.
- `validation/delta/CoveredByRules.java` and the per-code `*CoveredBy*Lieferung` rule classes — keep; legacy plain codes still need to be bridged to the new `_LIEFERUNG` codes for the in-Lieferung-source case.

Reuse search (per `reuse-before-reimplementing.md`):

- `findExistingMeldungStmIdByGjEndeAndJahresMeldung` already does the DB-side business-key lookup; the new overlay path is a sibling check, not a parallel implementation — call both.
- `Map<Long, DbSteuerMeldung> existingMeldungen` from `getExistingMeldungenByIsin` stays as the DB-side view. `InLieferungAcceptedState` is the per-Lieferung companion. Composition, not replacement.
- `seenNewMeldungKeys` (the design abandoned in the archived plan) is not resurrected. `InLieferungAcceptedState.stmIdsOfAcceptedNew` plays a similar role but is keyed by `NewMeldungKey` (with `selbstnachweis`) and is updated only on successful acceptance.

### Tests

Add or extend in `ifas-testing/ifas-integration-tests`:

- New: `WithinLieferungCoexistenceStatusValidationTest` — one CSV with three NEW meldungen for the same ISIN (Ausschüttungsmeldung, Jahresmeldung, Selbstnachweis-Jahresmeldung). Asserts that none emits a `_LIEFERUNG` / `_VORH` error — all three are accepted because their `NewMeldungKey` values differ on `jahresdatenmeldung` and/or `selbstnachweis`.
- New: `WithinLieferungStateTransitionTest` — covers Entries 1 & 3. Two CONFIRMED on the same stmId → second emits `ERR_STATUS_NM_LIEFERUNG` (in-Lieferung source). One CONFIRMED followed by one DELETE on the same stmId → DELETE emits `ERR_STATUS_NM_LIEFERUNG`.
- Extend `WithinFileDuplicateStatusValidationTest` (already exists per the archived plan) — assertions stay on the `_LIEFERUNG` codes, but expectations shift to reflect that the new logic distinguishes in-Lieferung source (fires `_LIEFERUNG`) from DB source (fires plain) per the validator-integration rules above.
- Regression: `GrossfileRecalculationTest` baselines for `gf1-d20260724` and `gf2-d20260731` need updating. Expectation: in gf2, `coveredMatch` count increases by 2 (Entries 1 & 3 — the new `ERR_STATUS_NM_LIEFERUNG` emissions are bridged to legacy's `ERR_STATUS_NM` via the existing `CoveredByRule`); `onlyInLegacy` drops by 2. `onlyInNewError` must not increase. The LEI `LegacyOnlyExpectedRule` continues to fire unchanged.

Both new tests use `IntegrationTestApplication.MULTI_DB_EXTENSION` per `testing-conventions.md`.

### Verification

1. Unit and module tests:
   ```
   mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy
   ```
2. Integration tests for the new scenarios:
   ```
   mvn -pl ifas-testing/ifas-integration-tests test -Pno-proxy \
     -Dtest='WithinLieferungCoexistenceStatusValidationTest,WithinLieferungStateTransitionTest,WithinFileDuplicateStatusValidationTest'
   ```
3. Grossfile regression — re-enable the `@Disabled` writer test, regenerate the diff files, and compare against the prior `error#diff-deviations.txt`:
   ```
   mvn -pl ifas-testing/ifas-integration-tests test -Pno-proxy \
     -Dtest='GrossfileRecalculationTest#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem'
   ```
   Confirm: gf2 Entries 1 & 3 (Z113 CONFIRMED, Z134 DELETE) move from `[-] NUR IM ALTSYSTEM` into the covered-match group (legacy plain `ERR_STATUS_NM` ↔ new `ERR_STATUS_NM_LIEFERUNG` via the existing `CoveredByRule`). No new `[+] NUR IM NEUSYSTEM` appears anywhere. The LEI entry (Entry 2) stays a `[-] NUR IM ALTSYSTEM (WARNING)` thanks to `LeiUnglVorhExpectedLegacyOnly`.
4. Update baselines in `GrossfileRecalculationTest` to reflect the new covered-match counts.

### Out of scope (do not bundle)

- `LeiUnglVorhExpectedLegacyOnly` and the `LegacyOnlyExpectedRule` machinery (Entry 2). Stays as-is; this revisit is orthogonal.
- Entry 4 (`ERR_JAHRESM_VORH` for `LU0136043394`) and Entry 5 (`ERR_GJE_BEENDET` for `LU0891777665`) — test-data drift per the gf2 analysis. Address separately.
- The `errGjeBeendet` boundary-semantics sanity check flagged at the end of Entry 5 — separate ticket.
