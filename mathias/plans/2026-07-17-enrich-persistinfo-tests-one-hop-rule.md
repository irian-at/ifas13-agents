# Plan: Enrich persistInfo in the persistence-service tests to match the fixed one-hop rule

## Context

The persist (NEW/UPDATE) path resolves `vorherigeFinal` with a **one-hop rule** (no chain walk),
now fixed in `SteuerlicheErmittlungDomainService.finishProcessingOpen` (lines 567–571):

```java
vorherigeFinalStmId = isFinal(ref) ? ref.id : ref.vorherigeFinal   // ref = the referenced (updated) STM
```

i.e. **if the referenced row is FINAL, its own id is the previous-final; otherwise copy the
referenced row's own `vorherigeFinal` forward.** Maintained at every insert, this keeps
`vorherige_final_stm_id` always correct with a single hop.

`SteuerMeldungPersistenceServiceTest` drives `persistSteuerMeldung` / `finalizeSteuerMeldung`
**directly** with a hand-built `SteuerMeldungPersistInfo`. Today the `persistInfoFor(...)` helper
passes `null, null` for the two predecessor ids, so UPDATE rows get no predecessor linkage and the
predecessor is never closed → the tests fail. The implementation is correct; **only the tests need
the correct `persistInfo` values** (the values the fixed rule would produce for each test's chain).

Scope of this plan: the persistence-service test only. `JiraIssueRecalculationTest` is a separate,
non-`persistInfo` failure — see "Out of scope" below.

## File

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungPersistenceServiceTest.java`

### Step 1 — add an id-carrying `persistInfoFor` overload
Keep the existing 3-arg helper delegating with `null, null`; add:

```java
private SteuerMeldungPersistInfo persistInfoFor(
        StmStatus inputStatus, SteuerMeldungFile file, String lieferantId,
        @Nullable Long vorherigeStmId, @Nullable Long vorherigeFinalStmId) {
    return new SteuerMeldungPersistInfo(
            OffsetDateTimes.now(), LocalDates.nowInVienna(), inputStatus, file.getFileId(), lieferantId,
            vorherigeStmId, vorherigeFinalStmId);
}
```
(`@Nullable` already imported.) NEW / CONFIRMED / DELETE persists keep the 3-arg form
(`null, null`) — finalize/delete resolve their own ancestor; NEW has none.

### Step 2 — supply the correct ids at each UPDATE persist

Values follow the fixed rule against each test's chain. `vorherigeStmId` = the referenced
(updated) STM; `vorherigeFinalStmId` = `isFinal(ref) ? ref : ref.vorherigeFinal`.

| Test / step | UPDATE refs | ref status | pass `(vorherigeStmId, vorherigeFinalStmId)` | why |
|---|---|---|---|---|
| `givenStmPersistedAsNew_whenPersistedAgainAsUpdate` | row 1 | OPE (NEW) | `(1L, null)` | ref OPEN, row 1 has no `vorherigeFinal` |
| `givenStmTimeline...` t3 (row 200 refs 100) | row 100 | **FIN** | `(100L, 100L)` | ref is FINAL → link to ref (100) |
| `givenStmTimeline...` t4 (row 300 refs 200) | row 200 | OPE | `(200L, 100L)` | ref OPEN; row 200's own `vorherigeFinal` = 100 (set at t3) |
| `givenFinalPredecessorWithDifferentSelbstnachweis` (row 2 refs 1) | row 1 | **FIN** | `(1L, 1L)` | ref is FINAL → link to ref (1) |

Predecessor-close side effects (already asserted, now satisfied because `vorherigeStmId` is set):
`closeIfOpen` fires only for the OPE predecessor (row 1 in `givenStmPersistedAsNew`; row 200 at t4);
FIN predecessors (100 at t3, row 1 in `givenFinalPredecessor`) are left active — matches existing
assertions.

### Step 3 — one assertion flip + comment updates in `givenStmTimeline...`

The fix makes an UPDATE-of-FINAL record the FIN link **at insert** (no longer deferred to confirm):

- **t3 (row 200, ~line 341):** change `.hasNoVorherigeFinalStm()` → `.hasVorherigeFinalStm(v -> v.hasId(100L))`.
- **t3 comments (~lines 331, 337):** replace "Predecessor is FIN; walker skips it → NULL at insert" /
  "writes vorherigeFinalStm NULL at INSERT (backfilled at finalize)" with: ref 100 is FINAL → row 200
  gets `vorherigeFinalStm = 100` at insert.
- **t4 comments (~lines 351, 358):** replace "walker steps 200 → 100 (FIN)" / "chain walk at insert"
  wording with: row 200's own `vorherigeFinal` (100) is copied forward at insert.
- **t4 assertion (line 362) `.hasVorherigeFinalStm(100)` stays** — still correct, different mechanism.
- **t5** unchanged — finalize's own walk re-computes the same 100; row 100 closed at confirm.

No changes to `givenNewSteuerMeldung...`, `givenWrongInputStatus...`, `givenPersistedStm_whenDeleted`,
`givenPersistedStm_whenFinalized` (no predecessor linkage).

## Out of scope (separate remaining failure — decide separately)

`JiraIssueRecalculationTest` case `[4]` (`IFAS13-139, ...,false,true`) still fails with
`EntityNotFoundException` on `getById(651853)`. This is **not** a `persistInfo` case — it runs through
`recalculateBundle` → `finishProcessingFinal` (unchanged by the fix), and 651853 was dropped from the
per-ISIN test export. It needs its own decision (add 651853 to the IFAS13-139 testdata YAML per the
test's TODO comment, or remove the incompatible `,true` case). Not addressed by this plan.

## Optional (not required for green)

`SteuerMeldungPersistenceServiceMultiDbCtxTest.givenUpdateWithFinalAncestor...` already passes
`(200L, 100L)` and is green, but its seed sets row 200 with `vorherigeStm=100` and **no**
`vorherigeFinal`, so `(200L, 100L)` no longer mirrors what the fixed rule would resolve for that seed
(it would yield `null`). For faithfulness, seed row 200 with `vorherigeFinal=100` (extend
`seedExistingStmInBothDbs`) or leave as a dumb-writer test. The `...ChainWalked...` method name is now
a misnomer. Leave unless you want it corrected.

## Verification

1. Apply the edits above.
2. Run the class on H2 (fast, no containers), rebuilding the reactor with `-am`:
   ```bash
   mvn -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests \
       -pl ifas-testing/ifas-integration-tests -am -Dsurefire.failIfNoSpecifiedTests=false \
       -Dtest='SteuerMeldungPersistenceServiceTest' test
   ```
   Expect 7/7 (note: use `-am` so the fixed main module is in the reactor — without it stale artifacts were used before).
3. Full H2 regression to catch anything on the processing path:
   ```bash
   mvn -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests \
       -pl ifas-testing/ifas-integration-tests -am -Dsurefire.failIfNoSpecifiedTests=false test
   ```
   (Expect `JiraIssueRecalculationTest[4]` still red until the separate decision above is made.)
