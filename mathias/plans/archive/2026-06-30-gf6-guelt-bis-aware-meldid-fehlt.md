# Fix gf6 `UPDATE;649522` → emit `ERR_MELDID_FEHLT` (match legacy)

## Context

The gf6 grossfile recalc deviates: input row `STATUS;UPDATE;649522` (ISIN LU0066902890).
- **Legacy** emits `ERR_MELDID_FEHLT` ("Die Meldung mit der Melde-ID <649522> ist nicht vorhanden").
- **New system** emits `ERR_UPD_OLDM` ("…wurde bereits ein UPDATE geliefert. Aktuelle Melde-ID: <649579>").

This was initially suspected to be a fixture-data problem (missing data to pull from gf7, or stale data to prune). **Both are ruled out.** 649522 is present in gf6's YAML *and* gf7's snapshot, and legacy keeps it on purpose.

**Root cause (confirmed against legacy C++ `c_st_meldung.cpp`):** legacy's `cSt_Meldung::CheckVorhandeneMeldung` does its initial active-meldung lookup with `where stm_id = <id> and guelt_bis is null` (c_st_meldung.cpp:~8032). If no active row is found, it falls to the `else` "Keine ursprüngliche Meldung vorhanden" branch and emits `ERR_MELDID_FEHLT` (~9336). The successor scan that yields `ERR_UPD_OLDM` (~9045) only runs when an *active* predecessor exists. When an OPEN meldung is UPDATEd, `BeendeAlteMeldung` **sets its `guelt_bis`** (does not delete the row). A FINAL predecessor keeps `guelt_bis` null and stays active.

The discriminator is purely `guelt_bis`, not status (OPE/FIN only correlate):

| meldung | status | gueltBis | legacy active? | legacy msg |
|---|---|---|---|---|
| gf6 649522 (UPDATE target) | OPE | **set** | no | `ERR_MELDID_FEHLT` |
| gf4 649571 (UPDATE target) | FIN | null | yes (+successor) | `ERR_UPD_OLDM` |

The new system's `SteuerMeldungStatusValidationService` ignores `guelt_bis`: `getExistingMeldungenByIsin` (via `findAllStmIdsByIsin`) loads the ended 649522, `previousSteuerMeldung = existingMeldungen.get(stmId)` is non-null, and `previousExistsAnywhere` uses raw `existsById` — so it treats the ended row as the active predecessor and runs the `errUpdOldm` path. `gueltBis` isn't even exposed on the domain `SteuerMeldung` model yet (only on `SteuerMeldungEntity`).

**Outcome:** make the new system treat a `gueltBis != null` (ended/"beendet") same-ISIN predecessor as not-active, so `ERR_MELDID_FEHLT` fires and the `ERR_UPD_OLDM` path is skipped — mirroring legacy. gf4 (active FIN) is unaffected.

## Implementation

### 1. Expose `gueltBis` on the domain model
- `ifas-domain-stm/.../meldung/SteuerMeldung.java`: add `FieldName.GUELT_BIS = "_STATUS_GUELT_BIS"` (underscore-prefixed internal/DB field, excluded from `isFormulaField`); add default getter `@Nullable LocalDateTime getGueltBis()` returning `getFieldValue(FieldName.GUELT_BIS, LocalDateTime.class)`. Add `import java.time.LocalDateTime`.
- `ifas-domain-stm/.../meldung/db/DbSteuerMeldungen.java`: add `Map.entry(FieldName.GUELT_BIS, SteuerMeldungEntity::getGueltBis)` to `ENTITY_FIELD_RESOLVERS`. `SteuerMeldungEntity.getGueltBis()` (LocalDateTime, `@Column guelt_bis`, line 194) already exists; lazy entity load + `TypeCoercions` default branch handle `LocalDateTime` with no further change.

### 2. Gate the previous-meldung determination (the fix)
`ifas-domain-stm/.../validation/status/SteuerMeldungStatusValidationService.java`, lines ~96-105 — gate **only** the direct previous-meldung derivation (NOT a map-wide filter):

```
DbSteuerMeldung previousInMap = stmId != null ? existingMeldungen.get(stmId) : null;
boolean active = previousInMap != null && previousInMap.getGueltBis() == null;
DbSteuerMeldung previousSteuerMeldung = active ? previousInMap : null;
boolean previousExistsAnywhere = active
        || (stmId != null && previousInMap == null && stmRepository.existsById(stmId));
```
- `existsById` consulted **only** when stmId is absent from the same-ISIN map (cross-ISIN fallback). For same-ISIN ended 649522 → `active=false`, `previousInMap!=null` → `previousExistsAnywhere=false` → `errMeldidFehlt` fires.
- Keep `resolvePreviousIsinAnyMatch` (line 105) fed by the **raw** `previousInMap`, not the gated value, so `errIsinMid` is unchanged.
- Add a `// why` comment citing legacy `c_st_meldung.cpp` `guelt_bis is null` lookup + else branch.

This skips the whole `if (previousSteuerMeldung != null)` block (errUnglVorh / errUpdSelbst / errStatusNm / errUpdOldm dispatch / errVergangenUpd / errAusschtAktConf) and the Fristen block for the ended row — exactly legacy's `else`-branch behavior.

### 3. Fix the misleading comment
`ifas-domain-stm/.../validation/delta/UpdOldmCoveredByUpdOldmLieferung.java` Javadoc (lines 11-18): qualify "Legacy raises ERR_UPD_OLDM when a UPDATE finds a successor in the DB" → only when the predecessor is still **active** (`guelt_bis null`); an ended predecessor yields `ERR_MELDID_FEHLT`. Comment-only.

### 4. Update gf6 baseline
`ifas-integration-tests/.../recalc/GrossfileRecalculationTest.java` line ~169: gf6 `SummaryExpectation(0,0,0,1,1,0)` → `SummaryExpectation(1,0,0,0,0,0)` (exact match). Reconcile against regenerated `target/grossfile-recalc/gf6-d20260813/error#diff-deviations.txt` (`WRITE_OUTPUT_FILES=true`) rather than guessing if other lines shift.

### 5. (Recommended) focused test
`SteuerMeldungStatusValidationServiceTest`: seed an OPE predecessor with `gueltBis` set + FIN successor referencing it, CSV `STATUS;UPDATE;<id>`; assert result contains `ERR_MELDID_FEHLT` and not `ERR_UPD_OLDM`. Mirror existing base+overlay+csv helper pattern.

### Deferred (not needed for this bug)
Full cross-ISIN-ended fidelity (an `existsByIdAndGueltBisIsNull` repo query replacing the `existsById` fallback) — not exercised by any fixture; leave a comment noting the residual edge case.

## Risks
- **Never** filter the `existingMeldungen` map by gueltBis — `findVorherigeFinalSteuerMeldung` / `findLatestUndeletedSuccessorStmId` traverse ended rows for *other* chains; the gf6 successor (FIN, active) must stay in the map. Gate only the direct predecessor.
- `errIsinMid` must keep the raw same-ISIN hit.
- gf4 (649571 FIN, gueltBis null) must remain `ERR_UPD_OLDM` — verify its baseline is unchanged.
- Input/CSV STMs have no GUELT_BIS field → `getGueltBis()` returns null harmlessly.
- forbiddenapis/java rules: no `var`, no `*.now()`, `@Nullable` on the getter, JUnit5/AssertJ.

## Verification
```
mvn test -Dtest=GrossfileRecalculationTest -Pno-proxy          # gf6 exact match; gf1-gf8 hold
mvn test -Dtest=SteuerMeldungStatusValidationServiceTest -Pno-proxy
mvn test -Dtest=UpdOldmCoveredByUpdOldmLieferungTest -Pno-proxy
mvn -q -Pno-proxy package -pl ifas-domain/ifas-domain-stm -am -DskipTests   # forbiddenapis gate
```
Inspect `target/grossfile-recalc/gf6-d20260813/error#diff-deviations.txt` — the 649522 deviation block should be gone.