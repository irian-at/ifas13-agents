# Plan: Adapt tests to the direct-`vorherigeFinal` persist design

## Context

The uncommitted refactor moved predecessor / FIN-ancestor resolution out of
`SteuerMeldungPersistenceService` and into the caller
(`SteuerlicheErmittlungDomainService`), passing the two ids through
`SteuerMeldungPersistInfo`. **The implementation is correct and stays as-is** — confirmed by
the user. Key rule: **no chain walking in the persist (NEW/UPDATE) path** — the caller reads
only the *direct* `vorherigeFinal` of the referenced STM (`getById(refId).getVorherigeFinalStm()`,
null if none) and hands it over.

The test suite lags behind this design and must be adapted. 5 test executions fail (H2 run):
- `SteuerMeldungPersistenceServiceTest.givenStmPersistedAsNew_whenPersistedAgainAsUpdate` (timing)
- `SteuerMeldungPersistenceServiceTest.givenStmTimeline_whenFinalizedAndUpdated_thenVorherigeFinalStmIdMatrixHolds` (NPE)
- `JiraIssueRecalculationTest` case `[4]` (IFAS13-139, `meldIdFehltDiffsAsWarning=true`) — `EntityNotFoundException`

Do **not** touch production code. Adapt tests only.

## Current semantics (verified)

- **NEW/UPDATE persist** (`persistSteuerMeldung`): sets `vorherigeStm` / `vorherigeFinalStm`
  *directly* from `persistInfo.vorherigeStmId()` / `persistInfo.vorherigeFinalStmId()`. Closes an
  **OPE** predecessor at insert via `closeIfOpen` (a FIN predecessor is left active).
- **CONFIRM/finalize** (`finalizeSteuerMeldung`): **ignores** the persistInfo predecessor fields and
  does its **own chain walk** (`vorherigeFinalStmIdResolver.findFinalAncestorId(existingInfo.getVorherigeStmId())`),
  backfilling `vorherigeFinalStm` via `confirmAsFinalAt(...)`. Unchanged by the refactor.
- `vorherigeStm` is **only ever written at NEW/UPDATE insert**; finalize/delete never touch it.
  Consequence: for the later finalize chain-walk to find anything, `vorherigeStmId` **must** be
  supplied in the persistInfo at the UPDATE persist.
- `SteuerMeldungEntityAssertions.hasVorherigeFinalStm(v -> v.hasId(x))` **NPEs when the actual is
  null** (that is the timeline NPE). Use `hasNoVorherigeFinalStm()` when null is expected.
- The `SteuerMeldungPersistenceServiceTest` calls the persist service **directly**, so it is a
  "dumb writer" test: whatever ids we pass in persistInfo are exactly what the row gets. The
  multidbctx test already passes explicit ids (`200L, 100L`) — same pattern.

## Changes

### 1. `SteuerMeldungPersistenceServiceTest`
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungPersistenceServiceTest.java`

Add an id-carrying overload of the `persistInfoFor` helper (keep the existing 3-arg one delegating
to it with `null, null`):

```java
private SteuerMeldungPersistInfo persistInfoFor(
        StmStatus inputStatus, SteuerMeldungFile file, String lieferantId,
        @Nullable Long vorherigeStmId, @Nullable Long vorherigeFinalStmId) { ... }
```
(`@Nullable` is already imported.)

Supply predecessor ids at each UPDATE persist (values = what the real caller would resolve from the
*direct* field, given the chain each test builds):

| Test | UPDATE persist | pass `(vorherigeStmId, vorherigeFinalStmId)` | assertion change |
|---|---|---|---|
| `givenStmPersistedAsNew_whenPersistedAgainAsUpdate` | row 2 refs row 1 (NEW/OPE) | `(1L, null)` | none — `hasVorherigeStm(1)`, `hasNoVorherigeFinalStm`, row 1 closed all hold |
| `givenStmTimeline...` t3 | row 200 refs 100 (FIN); direct field of 100 is null | `(100L, null)` | none — already `hasNoVorherigeFinalStm` |
| `givenStmTimeline...` t4 | row 300 refs 200 (OPE); direct field of 200 is null | `(200L, null)` | **t4 insert-time assertion — see Decision A** |
| `givenFinalPredecessorWithDifferentSelbstnachweis` | row 2 refs row 1 (FIN); direct field of 1 is null | `(1L, null)` | none — `hasVorherigeStm(1)` / `hasVorherigeFinalStm(1)` are checked **after confirm**, backfilled by finalize's walk |

NEW / CONFIRMED / DELETE persists keep the 3-arg `persistInfoFor` (`null, null`) — finalize/delete
resolve their own ancestor; NEW has none.

**Decision A (confirm tomorrow) — timeline t4 insert-time `vorherigeFinalStm`:**
Because persist no longer chain-walks and row 200's own `vorherigeFinal` is null, row 300 gets
`vorherigeFinalStm = null` at the t4 insert; the FIN ancestor 100 is backfilled only at the t5
confirm (finalize walks 300→200→100).
- **Recommended:** pass `(200L, null)` at t4; change the t4 insert assertion
  `hasVorherigeFinalStm(v -> v.hasId(100L))` → `hasNoVorherigeFinalStm()`; update the t4 comment
  (no longer "chain walk finds 100 at insert" → "direct field of OPEN 200 is null at insert;
  backfilled at confirm"). The t5 assertion `hasVorherigeFinalStm(100)` stays and now documents the
  finalize backfill. This is faithful to "no chain resolving in persist".
- Alternative (if the user prefers to keep the current t4 assertion): pass `(200L, 100L)` — but this
  re-introduces the chain-walk *result* the persist no longer produces in the real flow. Not
  recommended.

### 2. `JiraIssueRecalculationTest` — see Decision B
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/JiraIssueRecalculationTest.java`
(+ possibly `.../resources/at/oekb/ifas/domain/recalc/issues/IFAS13-139/IFAS13_139_Test-testdata.yml.txt`)

Only case `[4]` fails: `"IFAS13-139,5,2026-02-26,0,1,false,true"`. With `meldIdFehltDiffsAsWarning=true`
the CONFIRM is not declined, reaches `finishProcessingFinal`, and calls `getById(651853)` on an STM
that the per-ISIN export dropped (651853 lives under a different ISIN) → `EntityNotFoundException`.
Case `[3]` (`...,5,0,false,false`) passes: it is declined by ERR_MELDID_FEHLT *before* `getById`.

**Decision B (confirm tomorrow) — how to adapt IFAS13-139:**
- **Option A — add stmId 651853 to the IFAS13-139 testdata YAML** (matches the test's own TODO
  comment "We can fix by manually adding testdata for stmId 651853"). Makes the confirmed STM
  resolvable. Consequence: ERR_MELDID_FEHLT then fires for *neither* case, so **both** IFAS13-139
  rows change counts (`[3]` 5,0 → likely 0,0) and the `,true` row becomes redundant (remove it).
  Requires authoring an entry with FK-valid `fileId`/`confirmFileId`/`vertreter`/`kag` and re-running
  to capture the exact new counts. Erases the cross-ISIN-drop documentation.
- **Option B (lower risk) — remove only the incompatible `,true` row.** Keep `[3]` (still passes,
  documents the ERR_MELDID_FEHLT / cross-ISIN-drop artifact). Rationale: the getById design cannot
  confirm a meldung absent from the DB, so the "downgrade meldIdFehlt to warning then confirm anyway"
  scenario no longer exists. Trivial, no data authoring; loses the meldIdFehlt-as-warning coverage.

Recommendation: decide at verification. Option B is the minimal, safe adaptation; Option A honors the
author's written intent but is a larger, count-shifting change.

### 3. Out of scope / note only
- `SteuerMeldungPersistenceServiceMultiDbCtxTest` already passes explicit ids and is green; its method
  name `...thenChainWalkedFromReadDbAndWritesGoToWriteDbOnly` is now a slight misnomer (persist no
  longer walks). Optional rename only — not required to make tests pass. Leave unless asked.
- `QuickRecalculationTest` — `@Disabled`; the STICHTAG edit in the diff does not affect the suite.

## Verification (tomorrow)

1. Decide A and B above.
2. Apply the test edits.
3. Build the changed modules into the reactor and run the two classes on H2 (fast, no containers):
   ```bash
   mvn -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests \
       -pl ifas-testing/ifas-integration-tests -am -Dsurefire.failIfNoSpecifiedTests=false \
       -Dtest='SteuerMeldungPersistenceServiceTest,JiraIssueRecalculationTest' test
   ```
   Expect `SteuerMeldungPersistenceServiceTest` 7/7 and `JiraIssueRecalculationTest` green.
   NOTE: run test classes **with `-am`** so the (unchanged) main modules are in the reactor;
   without it, stale artifacts were used last time and masked results.
4. Full regression on H2 to catch anything on the processing path:
   ```bash
   mvn -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests \
       -pl ifas-testing/ifas-integration-tests -am -Dsurefire.failIfNoSpecifiedTests=false test
   ```
5. If Postgres/Sybase containers are available, re-run without the skip profiles (logic is pure
   JPA/HQL and DB-agnostic, so H2 is representative).

## Doc edits already in the tree (keep — from the earlier "docs in sync" task)
- `SteuerMeldungPersistInfo` javadoc: added the `vorherigeStmId` / `vorherigeFinalStmId` paragraph.
- `SteuerMeldungPersistenceService.persistSteuerMeldung` comment: "predecessor ids arrive pre-resolved
  on persistInfo" (the removed `resolvePredecessorInfo` chain walk). Both remain accurate under the
  current implementation.
