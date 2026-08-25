# Fix `findAllStmIdsByIsin`: WknHist validity predicate uses `IS NULL` instead of the Stichtag range

## Context

The current `QuickRecalculationTest` scenario
(`20260821_092620_LLB_2026-07-01_104516074_update#recalc.zip`, ISIN `AT0000A05766`, UPDATE on
STM-ID 679843) reports one log deviation in
`ifas-integration-tests/target/quick-recalc/info#diff-deviations.txt`:

```
[-] NUR IM ALTSYSTEM (FEHLER)
    ACHTUNG! Der Parameter Anzahl Anteile Zuflusszeitpunkt <35566.2445>
    entspricht nicht dem Parameter <34895.1858> aus der urspruenglichen Meldung
```

Legacy emits `ERR_UNGL_VORHF` as INFO (UPDATE downgrades it, `c_st_meldung.cpp:8613-8632`).
The new system emits **nothing at all** — 0 Fehler, 0 Infos (`statistics#recalc.log`).

### Root cause

`SteuerMeldungRepository.findAllStmIdsByIsin`
(`ifas-database/ifas-persistence-stm/.../SteuerMeldungRepository.java:79-87`) resolves
ISIN → `num_wfs_ku` with

```sql
AND w.datGueltigBis IS NULL
```

The fixture's only `WKN_HIST` row for `AT0000A05766` carries
`datGueltigAb: 2007-04-19`, **`datGueltigBis: 2029-09-15`** — a future end date, which is
normal production data. With the `IS NULL` predicate the join matches nothing, so:

- `getExistingMeldungenByIsin` → empty map
  (`SteuerMeldungStatusValidationService.java:494-506`)
- `existingInputStmForIsin == null` → `errUnglVorh` is never called (guarded at line 191)
  → the missing INFO
- `inputStmExists == true` (via `existsById(679843)`) but
  `inputStmExistForAnotherIsin == true` → `errMeldidFehlt` and
  `errMeldidNichtMehrGueltig` are both suppressed → the bug currently masks itself,
  which is why the error log is empty instead of showing a false error
- `validPersistentInputStm == null` → `errUpdSelbst`, `errStatusNm`, `errUpdOldm`,
  `errVergangenUpd`, `errAusschtAktConf` and the Vorherige-FINAL Fristen lookup are all
  silently skipped

The predicate is an outlier. Every other WknHist join in the codebase uses the Stichtag
range — `InvRepository:29,51,66,82,389`, `Kest98Repository:23`, `WknHistRepository:38`,
and `SteuerMeldungRepository.getIsinByStmId:143`:

```sql
AND wknHist.datGueltigAb <= :stichtag
AND (wknHist.datGueltigBis IS NULL OR :stichtag <= wknHist.datGueltigBis)
```

Legacy does the same (`isnull(dat_gueltig_bis, '3100.01.01') >= <Datum>`,
`m_fplausi.cpp:736,768,799,831`). `c_st_meldung.cpp:8029-8032` joins `wkn_hist` with no
validity filter at all; its `guelt_bis is null` there is `steuer_meldung.guelt_bis`, not
`wkn_hist.dat_gueltig_bis`.

Consequence beyond this scenario: for any fund whose current ISIN row has a non-null
`dat_gueltig_bis`, all DB-comparison validations vanish without a trace — in production too,
not just in recalc. Other fixtures show the same shape
(`RecalculationDomainServiceTest_LU0078115192`, `IFAS13-136`).

## Change

### 1. `ifas-database/ifas-persistence-stm/.../steuermeldung/SteuerMeldungRepository.java`

Give `findAllStmIdsByIsin` a `stichtag` parameter and use the standard validity predicate:

```java
@Query("""
        SELECT DISTINCT m.id FROM SteuerMeldungEntity m
        JOIN at.oekb.ifas.persistence.wkn.WknHist w ON m.numWfsKu = w.numWfsKu
        WHERE w.numWkn = :isin
          AND w.quelle.codQuelle = 'ISIN'
          AND w.datGueltigAb <= :stichtag
          AND (w.datGueltigBis IS NULL OR :stichtag <= w.datGueltigBis)
        ORDER BY m.gjEnde DESC, m.id DESC
        """)
List<Long> findAllStmIdsByIsin(@Param("isin") String isin, @Param("stichtag") LocalDate stichtag);
```

`DISTINCT` is defensive: the caller collects into a map with a duplicate-key merge function
that throws (`SteuerMeldungStatusValidationService#throwOnDuplicate`), and a range predicate
can match more than one history row where `IS NULL` could not.

### 2. `ifas-domain/ifas-domain-stm/.../validation/status/SteuerMeldungStatusValidationService.java`

`getExistingMeldungenByIsin` (line 494) already receives `stichtag` — pass it through. Only
production caller; no other call sites.

### 3. Tests

- `SteuerMeldungStatusValidatorsTest:1576,1613` stub
  `findAllStmIdsByIsin(anyString())` — update to the two-arg signature.
- Add a repository-level test in `ifas-integration-tests` covering a `WknHist` row with a
  **future** `datGueltigBis` (the regression this fixes) alongside the existing
  `datGueltigBis == null` case and an expired row that must not match.

## Verification

1. `mvn clean install -Pno-proxy -pl ifas-database/ifas-persistence-stm,ifas-domain/ifas-domain-stm -am`
2. `mvn test -Pno-proxy -Dtest=SteuerMeldungStatusValidatorsTest -pl ifas-domain/ifas-domain-stm`
3. Re-run `QuickRecalculationTest#givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
   (remove `@Disabled` / run from IDE) and inspect `target/quick-recalc`:
   - `info#diff-deviations.txt` — the `Anzahl Anteile Zuflusszeitpunkt` entry must now be an
     exact match (`Exakte Treffer: 1`, `Nur im Altsystem: 0`).
   - `error#diff-deviations.txt` — expect `ERR_MELDID_NICHT_MEHR_GUELTIG` to surface here,
     because fixture 679843 carries `gueltBis: 2026-08-21T09:26:19.807` (the testdata YAML is
     an export-**after** snapshot of the very Lieferung being replayed). With the test's
     `ValidationSetting.RECALC_ARTIFACT_DIFFS_AS_WARNING` it must be reported as
     **Warnung**, not as Abweichungsfehler (`ValidationDeltaReports:97-105`), and the return
     status must stay `OPEN` (`SteuerlicheErmittlungRecalcOptions.ignoreMeldeIdNichtMehrGueltigErrors`).
   - `recalc-protocol_complete.txt` — `Anzahl Abweichungsfehler in dieser Lieferung: 0`.
4. Full regression: `mvn test -Pno-proxy -Pskip-sybase16-tests` — the previously-hidden
   DB-comparison validations will now fire for fixtures whose ISIN row has a non-null
   `datGueltigBis` (`RecalculationDomainServiceTest_LU0078115192`, `IFAS13-136`); check those
   expectations.

## Out of scope (noted, not fixed here)

`findAllStmIdsByEintrageZeit` (same file, lines 149-164) carries the same
`datGueltigBis IS NULL` predicate, a copy-pasted Javadoc from `findAllStmIdsByIsin`, and a
`:isin` named parameter that the method signature does not bind — it can only fail when
`DatabaseCompareService` executes it. Worth a separate ticket.
