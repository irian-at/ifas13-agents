# Within-file duplicate: 2nd meldung silently dropped from processing pipeline

## Context

User reports: when two NEW Jahres-/Ausschüttungsmeldungen share the same
`LieferungStmKey` (ISIN + Jahresdatenmeldung + GjEnde) inside one CSV file,
the within-file duplicate logic adds `ERR_JAHRESM_VORH_LIEFERUNG` /
`ERR_AUSSCHM_VORH_LIEFERUNG` correctly — but one meldung ends up in a failed
status and the other is **not in `OPEN`** either, although exactly one of them
should be `OPEN` (successful) and the other failed.

Investigation confirmed the cause is **not** the `errJahresmVorh` /
`errAusschmVorh` DB-existence check; it's a deeper structural problem in how
the lieferung carries meldungen into downstream processing.

## Root cause

`SteuerMeldungLieferungen.getSteuerMeldungenByKey()`
(`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungen.java:21-34`)
silently drops 2nd-and-later occurrences when two meldungen share the same
`LieferungStmKey`:

```java
if (map.containsKey(lieferungKey)) {
    log.warn("Duplicate key: {}", steuerMeldung.getLieferungKey());   // ← dropped
} else {
    map.put(lieferungKey, steuerMeldung);
}
```

Downstream, `SteuerlicheErmittlungDomainService.processSteuerMeldungLieferung`
iterates that map (`SteuerlicheErmittlungDomainService.java:86, 91`):

```java
processedSteuerMeldungen = lieferung.steuerMeldungenByKey().values().stream()
        .map(stm -> handleInputStm(...))
        ...
```

So the 2nd meldung never enters `handleInputStm`/`finishProcessing` and never
receives a final status.

Meanwhile `validateWithinFileDuplicates`
(`SteuerMeldungStatusValidationService.java:249-262`) iterates the *list* of
meldungen (from `SteuerMeldungLieferungService.processCsv:81`), so it
correctly attaches `ERR_JAHRESM_VORH_LIEFERUNG` to the 2nd meldung's
`SteuerMeldungPosition`. That validation message ends up in
`lieferung.validationMsgs()` — but unattached to any meldung the pipeline
actually consumes.

### Symptom mapping

| Scenario                           | 1st meldung               | 2nd meldung                                |
|------------------------------------|---------------------------|--------------------------------------------|
| Fresh DB, two CSV dups             | processed → `OPEN`        | dropped from map → no final status         |
| DB pre-existing match + CSV dups   | gets `ERR_JAHRESM_VORH` → `NEW_DECLINED` (user sees "ERROR") | dropped from map → no final status (user sees "not OPEN") |

The drop-from-map predates the `_LIEFERUNG` codes and has been masking
within-file dups all along; the new codes simply made the inconsistency
visible (validator says "this is a dup", but the meldung that triggered it
is no longer in the map).

## Why `LieferungStmKey` must not be changed

Considered: add `messageNr` (or `sourceEntry`) to `LieferungStmKey` so the
keys become unique per meldung. **Rejected** — `LieferungStmKey` is the
*business key* and two callers depend on that semantic:

1. `validateWithinFileDuplicates` uses `seenNewMeldungKeys.add(key)` to detect
   meldungen that share the business key. Per-meldung-unique keys would make
   every `add()` return `true`, so `ERR_JAHRESM_VORH_LIEFERUNG` would never
   fire.
2. `SteuerMeldungStatusValidationService.findExistingMeldungStmIdByGjEndeAndJahresMeldung`
   compares incoming meldungen against DB rows by business key.

The bug is not the key — it's that `getSteuerMeldungenByKey()` reuses the
business key as a storage-uniqueness key.

## Recommended fix (option 2 from the discussion)

Stop iterating meldungen through the keyed map in the processing pipeline.

1. Add a `List<SteuerMeldung> steuerMeldungen()` accessor on
   `SteuerMeldungLieferung`
   (`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferung.java`)
   exposing every meldung in CSV order (no deduplication).
2. Have `DefaultSteuerMeldungLieferung` retain the raw list it already
   receives in its builder
   (`DefaultSteuerMeldungLieferung.java:19-24`) rather than only storing the
   collapsed `Map`.
3. Change `SteuerlicheErmittlungDomainService.processSteuerMeldungLieferung`
   (`SteuerlicheErmittlungDomainService.java:86, 91`) to iterate
   `lieferung.steuerMeldungen()` instead of
   `lieferung.steuerMeldungenByKey().values()`.
4. Keep `steuerMeldungenByKey()` for callers that legitimately want
   first-per-key lookup (must audit those callers — grep `steuerMeldungenByKey`
   to find them; only the processing iteration is known to need every
   meldung).
5. Drop the `log.warn("Duplicate key: ...")` in
   `SteuerMeldungLieferungen.getSteuerMeldungenByKey` once we've confirmed
   the within-file dup logic in `validateWithinFileDuplicates` is the only
   thing that should report the duplicate.

After the fix, the 2nd meldung reaches `finishProcessing`, picks up
`ERR_JAHRESM_VORH_LIEFERUNG` (declined=true →
`SteuerlicheErmittlungDomainService.calculateSpecialErrorStatus:355-372`),
and ends as `NEW_DECLINED`. The 1st stays `OPEN` (fresh-DB case) or becomes
`NEW_DECLINED` via `ERR_JAHRESM_VORH` (DB-match case) — both correct.

## Verification

New integration test under
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/status/WithinFileDuplicateStatusValidationTest.java`
(multi-DB via `IntegrationTestApplication.MULTI_DB_EXTENSION` per
`testing-conventions.md`) covering:

- **Case A — fresh DB**: persist nothing. CSV has two NEW Jahresmeldungen
  with the same `(ISIN, gjEnde, jahresmeldung=true)`. After full pipeline:
  - 1st meldung: status `OPEN`, no `ERR_JAHRESM_VORH*`.
  - 2nd meldung: status `NEW_DECLINED`, carries `ERR_JAHRESM_VORH_LIEFERUNG`.
  - **Both meldungen present** in the processed output (regression guard
    against the silent drop).

- **Case B — DB-existing match**: pre-persist a `DbSteuerMeldung` matching
  the CSV's key. Same CSV. Expected:
  - 1st: `NEW_DECLINED`, `ERR_JAHRESM_VORH`.
  - 2nd: `NEW_DECLINED`, both `ERR_JAHRESM_VORH` and `ERR_JAHRESM_VORH_LIEFERUNG`.

Manual check after fix: rerun the recalc scenario that surfaced the report
and confirm the second meldung is now visible in the output with
`NEW_DECLINED` status and the `ERR_JAHRESM_VORH_LIEFERUNG` code.

Run:
```
mvn -pl ifas-testing/ifas-integration-tests test \
    -Dtest=WithinFileDuplicateStatusValidationTest -Pno-proxy
```

## Files to touch

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferung.java` — add `steuerMeldungen()` accessor.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/DefaultSteuerMeldungLieferung.java` — carry the raw list.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungen.java` — remove the silent-drop warning once the pipeline uses the list.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java` — iterate the list instead of the map (lines 86, 91).
- (audit) any other caller of `steuerMeldungenByKey()` that should switch to the list — grep first.
- New: `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/status/WithinFileDuplicateStatusValidationTest.java`.

## What was already done in this session

- Investigated `SteuerMeldungStatusValidationService`, `SteuerMeldungStatusValidators`, `SteuerlicheErmittlungDomainService`, `SteuerMeldungLieferungen`, `LieferungStmKey`, `CsvMessage` equality.
- Initial hypothesis was the DB-existence check firing on both dups; deeper trace showed the map-drop is the structural cause. DB-existence is still a contributing factor in recalc-against-existing-data scenarios but it isn't required to reproduce the symptom.
- Ruled out `LieferungStmKey` redesign (would break within-file dup detection itself).
