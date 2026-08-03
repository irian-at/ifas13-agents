# Fix `getLegacyStmId` lookup for STMs with duplicate business keys

## Context

You called out the comment I wrote in `RecalculationDomainService.getLegacyStmId`
(lines 358–376):

```java
// Legacy CSVs typically have at most one entry per business key (seqNr 0).
// If duplicates exist, the first occurrence is used.
SteuerMeldung legacyReturnSteuerMeldung = legacyReturnSteuerMeldungen.get(
        new LieferungStmInstanceKey(businessKey, 0)
);
```

You're right that the comment is wrong, and the lookup behind it is wrong too.

### How the comment came to be

When I refactored the map key from `LieferungStmKey` (business key only) to
`LieferungStmInstanceKey` (business key + sequenceNr), `getLegacyStmId` stopped
compiling — the old `legacyReturnSteuerMeldungen.get(businessKey)` call lost its
type. The narrow fix I picked was to wrap the business key in
`new LieferungStmInstanceKey(businessKey, 0)` and label that as
"essentially equivalent" — that's where the rationalisation about "typically
one entry per business key" came from. It's a guess, not a fact, and it's
contradicted by code right in the same module:
`SteuerMeldungLieferungen.getSteuerMeldungenByInstanceKey`
(ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungen.java:24–30)
explicitly counts and numbers duplicates 0, 1, 2 …, and the new
`SteuerMeldungLieferungenTest` exercises exactly that case.

### Why the lookup is also wrong

`StmIdProvider.determineStmId(SteuerMeldung)` is called from
`SteuerlicheErmittlungDomainService.handleNew` and from
`WorkbookRecalculations.calculateWith…`. Each call passes a single input STM
and asks "what's the legacy STM id for this one?". The provider only has the
business key (`stm.getLieferungKey()`), no sequenceNr. With duplicates present:

- The input lieferung has, say, two STMs sharing one business key → instance
  keys `(K, 0)` and `(K, 1)`.
- The legacy return CSV may also have two entries for `K` → `(K, 0)` and `(K, 1)`,
  each with a different `stmId`.
- For *both* input STMs we currently return the `stmId` from `(K, 0)`. So the
  second input STM picks up the first legacy STM's id — silently and wrongly.

This is actually a regression my refactor introduced. The pre-refactor map was
`Map<LieferungStmKey, SteuerMeldung>` built by repeatedly `put`-ing the same
key, so duplicates collapsed to the *last* CSV row in `LinkedHashMap` value
slot. Now we always pick the *first* — opposite behaviour, and still arbitrary.

## Recommended fix

Make the provider sequence-aware so each input STM gets its own legacy
counterpart, then drop the misleading comment.

1. **Change `StmIdProvider` to take the instance key** alongside the STM
   (`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/StmIdProvider.java`):

   ```java
   @Nullable Long determineStmId(LieferungStmInstanceKey instanceKey, SteuerMeldung inputSteuerMeldung);
   ```

   Update the `NULL_PROVIDER` / `ofStatic` factories accordingly.

2. **Pass the instance key when calling the provider**:
   - `SteuerlicheErmittlungDomainService.internalProcessLieferung` currently
     streams `lieferung.steuerMeldungenByInstanceKey().values()` — switch to
     `entrySet()` so the instance key flows through `handleInputStm` and
     `handleNew` down to `stmIdProvider.determineStmId(...)`.
   - `WorkbookRecalculations.calculateWithLibreOffice` /
     `calculateWithMicrosoftExcel` (currently unused params there, but still on
     the public signature) take the instance key from their callers in
     `RecalculationDomainService.recalculateBundle` (the `for (LieferungStmInstanceKey key : allKeys)` loop already has it).

3. **Simplify `getLegacyStmId`** to a direct instance-key lookup and remove the
   speculative comment:

   ```java
   private @Nullable Long getLegacyStmId(
           @Nullable Map<LieferungStmInstanceKey, SteuerMeldung> legacyReturnSteuerMeldungen,
           LieferungStmInstanceKey instanceKey
   ) {
       if (legacyReturnSteuerMeldungen == null) {
           return null;
       }
       SteuerMeldung legacyReturnSteuerMeldung = legacyReturnSteuerMeldungen.get(instanceKey);
       return legacyReturnSteuerMeldung != null ? legacyReturnSteuerMeldung.getStmId() : null;
   }
   ```

   Update the lambda at line 130 to forward the instance key.

4. **Test**: extend `SteuerMeldungLieferungenTest` (or add a focused test on
   `RecalculationDomainService`) with a lieferung containing two STMs sharing a
   business key, plus a matching legacy return CSV, and assert that
   input-`seq=0` ↔ legacy-`seq=0` and input-`seq=1` ↔ legacy-`seq=1` resolve to
   different stmIds.

### Files touched

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/StmIdProvider.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/workbook/WorkbookRecalculations.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/RecalculationDomainService.java`
- Any other call sites of `StmIdProvider.determineStmId` /
  `WorkbookRecalculations.calculateWith…` (`StmDiffsTest`,
  `CalculationDomainService`) — adjust signatures, most pass
  `StmIdProvider.NULL_PROVIDER` and need only minor edits.

## Verification

- `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test` — runs the unit tests
  in the touched module, including the duplicate-business-key test above.
- `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test
  -Dtest=StmDiffsTest` — exercises the workbook recalc path that calls the
  provider with `NULL_PROVIDER`; ensures the signature change compiles and
  still produces equal diffs.
- Manual sanity: run a recalc bundle that contains a Lieferung CSV with two
  STMs sharing a business key plus the matching legacy return CSV and confirm
  that the recalculated STMs receive distinct legacy stmIds.
