# Unify within-lieferung duplicate detection across all StM statuses

## Context

`SteuerMeldungStatusValidationService` currently has two parallel within-lieferung dedup
mechanisms — `Set<LieferungStmKey> seenNewMeldungKeys` for NEW and `Set<Long>
seenStmIdsWithStatus` for CONFIRMED/DELETE — plus UPDATE is not covered at all. Legacy
fires `ERR_STATUS_NM` / `ERR_UPD_OLDM` / `ERR_JAHRESM_VORH` in equivalent situations because
its in-memory state flips after each row; IFAS13 reads a one-shot DB snapshot and misses the
within-file repetitions. Entry 1 (already shipped) added the CONFIRMED/DELETE half. This plan
collapses both mechanisms into one and adds UPDATE, with the invariant: **each ISIN may appear
at most once per lieferung; the first row is accepted, every subsequent row for the same ISIN
errors out**. Error codes mirror legacy's emission per status so the delta calculator can match
them via covered-by rules.

Scope: tracking and validator wiring only. No changes to recalc/calculation paths, no schema
changes, no behaviour change for cases where ISIN is null (those bypass dedup, same as today).

## Design

### Tracking

Replace the two existing sets with a single `Set<String> seenIsins` initialised once per
lieferung in `SteuerMeldungLieferungService`. Each call to
`SteuerMeldungStatusValidationService.validate(…)` consults `seenIsins.add(isin)`; a `false`
return means the ISIN was already seen → emit the appropriate `_LIEFERUNG` error code and
return (the entry is still added to the set on the first sighting, so only the second-and-later
occurrences are flagged).

Skip dedup when `steuerMeldung.getIsin() == null` — the missing-ISIN scenario is already
covered by upstream CSV validation.

### Error-code dispatch (mirror legacy per status)

| Current status                       | Emit                                         | Legacy emits (covered-by source) |
|--------------------------------------|----------------------------------------------|----------------------------------|
| NEW + Jahresdatenmeldung=true        | `ERR_JAHRESM_VORH_LIEFERUNG` (existing)      | `ERR_JAHRESM_VORH`               |
| NEW + Jahresdatenmeldung=false       | `ERR_AUSSCHM_VORH_LIEFERUNG` (existing)      | `ERR_AUSSCHM_VORH`               |
| UPDATE                               | `ERR_UPD_OLDM_LIEFERUNG` (**new**)           | `ERR_UPD_OLDM`                   |
| CONFIRMED, DELETE                    | `ERR_STATUS_NM_LIEFERUNG` (existing)         | `ERR_STATUS_NM`                  |

Existing covered-by rules (`VorhCoveredByVorhLieferung`, `StatusNmCoveredByStatusNmLieferung`)
already bridge three of the four; add one new rule for the UPDATE case.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java`
  - Replace `Set<LieferungStmKey> seenNewMeldungKeys` and `Set<Long> seenStmIdsWithStatus`
    parameters in the public `validate(…)` overload with a single `Set<String> seenIsins`.
  - Collapse `validateWithinFileNewDuplicates` + `validateWithinFileStatusTransitions` into one
    `validateWithinFileIsinDuplicate(validationMsgs, steuerMeldung, seenIsins)` that does the
    `add()` check once and dispatches by status to the appropriate `_LIEFERUNG` validator.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidators.java`
  - Drop the existing CONFIRMED/DELETE status guard inside `errStatusNmLieferung` if it stays
    keyed on `duplicateInLieferung`; the dispatch happens in the service. Simplest path: keep
    the validators as-is and let the service decide which to call.
  - Add `errUpdOldmLieferung(validationMsgs, steuerMeldung, boolean duplicateInLieferung)`
    mirroring `errStatusNmLieferung`. Emits `ERR_UPD_OLDM_LIEFERUNG` with the stmId argument.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgCode.java`
  - Add `ERR_UPD_OLDM_LIEFERUNG("Zur Melde-ID <{0}> wurde in dieser Lieferung bereits ein UPDATE geliefert.", true)`
    next to `ERR_STATUS_NM_LIEFERUNG`.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgCodePattern.java`
  - Add the matching regex entry.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/UpdOldmCoveredByUpdOldmLieferung.java` (**new**)
  - Mirror `StatusNmCoveredByStatusNmLieferung`. Maps legacy `ERR_UPD_OLDM` → new
    `ERR_UPD_OLDM_LIEFERUNG`.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/CoveredByRules.java`
  - Register the new rule in `DEFAULT_RULES`.

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java`
  - Replace the two `Set` initialisations with `Set<String> seenIsins = new HashSet<>();` and
    update the call to `statusValidationService.validate(…)` to pass it.

## Reuse / patterns followed

- The dispatch-on-status pattern mirrors the existing `validateWithinFileNewDuplicates` (split
  by `jahresdatenmeldung` flag into `errJahresmVorhLieferung` vs `errAusschmVorhLieferung`).
- Covered-by rule structure copies `StatusNmCoveredByStatusNmLieferung` (introduced earlier in
  this session). `CoveredByRules.DEFAULT_RULES` already aggregates per-code mapping rules.
- `LieferungStmKey` is left untouched — it is used heavily by recalc
  (`RecalculationDomainService`, `SteuerMeldungLieferungen.getSteuerMeldungenByKey`,
  `RecalculationOutputs`) and should not be repurposed for validation dedup.

## Tests

Unit:

- `SteuerMeldungStatusValidatorsTest` — add `ErrUpdOldmLieferungTests` `@Nested` block analogous
  to `ErrStatusNmLieferungTests`: duplicate UPDATE → error, first UPDATE → no error, non-UPDATE
  status with `duplicateInLieferung=true` → no error.
- `UpdOldmCoveredByUpdOldmLieferungTest` — mirror `StatusNmCoveredByStatusNmLieferungTest` (4
  cases: positive match, wrong legacy pattern, wrong new code, rule name).

Behavioural (service-level, optional but recommended):

- `SteuerMeldungStatusValidationServiceTest` — add scenarios covering: two NEW Jahresmeldungen
  for the same isin → second errors with `ERR_JAHRESM_VORH_LIEFERUNG`; two UPDATEs on the same
  stmId/isin → second errors with `ERR_UPD_OLDM_LIEFERUNG`; CONFIRMED then DELETE on same
  stmId/isin → second errors with `ERR_STATUS_NM_LIEFERUNG`; NEW + UPDATE on same isin →
  second errors (status-appropriate code).

## Verification

1. `mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy` — full module suite must remain green
   (1109 tests baseline from the previous turn).
2. Re-run the grossfile recalc test that produced the gf2 evidence:
   `mvn -pl ifas-testing/ifas-integration-tests test -Pno-proxy -Dtest=GrossfileRecalculationTest#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem`
   (re-enable temporarily — `@Disabled` by default). Inspect
   `target/test-output/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt`:
     - Entries 1 (Z113 CONFIRMED dup) and 3 (Z134 DELETE-after-CONFIRMED) should turn into
       exact matches.
     - No new `[+] NUR IM NEUSYSTEM` entries should appear on rows that previously matched
       exactly (regression check via `diff` against the prior file).
3. Confirm the `declined=true` flag on the new code propagates so the duplicate row is rejected
   (not silently accepted with a warning).

## Out of scope

- Entries 2, 4, 5 of `gf2-nur-im-altsystem-analysis.md` (cross-ISIN lookup blind spot,
  test-data drift). Tracked separately.
- `LieferungStmKey` shape changes — explicitly off-limits because of recalc dependencies.
- Any new ValidationMsgCode beyond `ERR_UPD_OLDM_LIEFERUNG`.
