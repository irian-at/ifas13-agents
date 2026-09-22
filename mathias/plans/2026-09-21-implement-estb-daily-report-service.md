# Implement EstbDailyReportService

## Context

The daily "Steuerdatenauswertungen" batch (`SteuerdatenAuswertungenJobExecutionService`, legacy
`run_stm.csh <nr>`) runs 3×/day (Lauf 1/2/3, already scheduled via
`SteuerdatenAuswertungenSchedulingConfig`) and executes 3 sub-jobs in order: Fristenprüfung →
Meldefonds-Listen → **EStB Steuerdaten-Meldung Files (cp_03)**. The last one,
`EstbDailyReportService.doEstbDailyReport`, is currently a stub that only logs and returns `null`.//

The goal: write every `SteuerMeldung` that reached **FINAL** status for the day's Stichtag to an
EStB report file, reusing the CSV writer already used for the ISIN Anforderungsliste export
(`CsvSteuerMeldungenWriter.writeEstbReportSteuerMeldungToCsv`). Since the batch runs 3× on the same
calendar day, each run must pick up only the Meldungen that became FINAL since the previous run of
that same day — tracked via the `stmIds` field already added (uncommitted) to `EstbDailyReportJob`.

**Key finding that shapes the design:** `zufluss` (Zuflusszeitpunkt) on `SteuerMeldungEntity` is
`null` while a Meldung is OPEN/CONFIRMED and gets stamped to the processing **Stichtag** exactly
once, in `confirmAsFinalAt` (called from `SteuerMeldungPersistenceService.finalizeSteuerMeldung`),
at the moment the Meldung becomes FINAL. So `zufluss` is not a wall-clock timestamp — it's the
authoritative "which Stichtag does this FINAL Meldung belong to" field. Each of the 3 daily runs
must therefore filter strictly on `zufluss = keyDate` (the job's Stichtag), not a rolling time
window. This also means "not yet picked up since the previous run" reduces to a plain **set
difference** against the stmIds already recorded on that day's earlier `EstbDailyReportJob` rows —
no timestamp cursor, no cross-run race condition to guard against.

Decisions already confirmed with the user:
- Implement file creation + NetApp archive only; leave MFT upload as a TODO (mirrors the sibling
  `MeldefondsService`, which also still has an open MFT TODO today).
- Always produce and archive a bundle for every run, even when zero new Meldungen are found.

## Design

### 1. Flyway migration — finish the uncommitted `stmIds` field

`EstbDailyReportJob.stmIds` (`List<Long>`, column `stm_ids`) was added to the entity but has no
migration yet. Add, following the `StmCalcJob.stmIds` precedent exactly
(`V058__stm_calc_jobs_stm_ids.sql`):

- `ifas-database/ifas-database-flyway/.../postgres15/V068__estb_daily_report_jobs_stm_ids.sql`:
  ```sql
  alter table estb_daily_report_jobs
      add column stm_ids bigint array;
  ```
- `ifas-database/ifas-database-flyway/.../sybase16/V068__estb_daily_report_jobs_stm_ids.sql`:
  ```sql
  -- not required in sybase database
  ```

### 2. New global "FINAL Meldungen for this Stichtag" query

`SteuerMeldungRepository` already has `findFinalStmIdsByIsinAndGueltAbRange` (ISIN-scoped, used by
the ad-hoc ISIN Anforderungsliste export). Add a Stichtag-scoped, non-ISIN-scoped sibling:

```java
/**
 * Finds FINAL stmIds whose Zuflusszeitpunkt (stamped at finalization) equals the given Stichtag.
 * Used by the daily EStB report.
 */
@Query("""
        SELECT m.id FROM SteuerMeldungEntity m
        WHERE m.status.statusCode = 'FIN'
          AND m.zufluss = :stichtag
          AND m.gueltBis IS NULL
        ORDER BY m.id ASC
        """)
List<Long> findFinalStmIdsByZufluss(@Param("stichtag") LocalDate stichtag);
```

`gueltBis IS NULL` keeps the same "active version" convention used everywhere else in this
repository (and documented project-wide: gueltBis discriminates the active row, not status).

### 3. Look up same-day sibling runs

Add to `EstbDailyReportJobRepository`:

```java
List<EstbDailyReportJob> findByKeyDate(LocalDate keyDate);
```

### 4. New domain writer — reuse `CsvSteuerMeldungenWriter`, generalize `IsinAnforderungDomainService`'s per-stmId loop

`IsinAnforderungDomainService.writeSteuerMeldungenForIsin` writes one ISIN's stmIds using a single
known `isin`/`invInfo`. The daily report spans many ISINs, so resolve them per stmId using the
already-existing `SteuerMeldungRepository.getIsinByStmId(stmId, stichtag)` +
`InvRepository.getInvNameKagStVertreterLeiByIsin(isin, stichtag)`.

New class `at.oekb.ifas.domain.stm.estbreport.EstbDailyReportWriter` (`ifas-domain-stm`):

```java
@Service @NullMarked @RequiredArgsConstructor
public class EstbDailyReportWriter {

    private final EntityManager em;
    private final InvRepository invRepository;
    private final SteuerMeldungRepository stmRepository;
    private final ErmittlungsvorgabeProvider ermittlungsvorgabeProvider;

    @Transactional(readOnly = true)
    public int writeSteuerMeldungen(
            List<Long> stmIds, LocalDate stichtag,
            OutputStream standardOut, OutputStream erweitertOut
    ) {
        CsvSteuerMeldungenWriter standardWriter = new CsvSteuerMeldungenWriter(standardOut, false, stichtag);
        CsvSteuerMeldungenWriter erweitertWriter = new CsvSteuerMeldungenWriter(erweitertOut, true, stichtag);
        int count = 0;
        for (Long stmId : stmIds) {
            String isin = stmRepository.getIsinByStmId(stmId, stichtag)
                    .orElseThrow(() -> new IllegalStateException("No ISIN found for stmId " + stmId + " at " + stichtag));
            InvNameKagStVertreterLei invInfo = invRepository.getInvNameKagStVertreterLeiByIsin(isin, stichtag)
                    .orElse(InvNameKagStVertreterLei.EMPTY);
            SteuerMeldung stm = SimpleFieldsOverridingSteuerMeldung.of(
                    EagerDbSteuerMeldung.of(stmRepository, ermittlungsvorgabeProvider, stmId, isin, invInfo),
                    SteuerMeldung.FieldName.END_ISIN, isin,
                    SteuerMeldung.FieldName.END_TIMESTAMP, LocalDateTimes.nowInVienna());
            MDCs.doWith("ISIN", isin, () -> {
                standardWriter.writeEstbReportSteuerMeldungToCsv(stm);
                erweitertWriter.writeEstbReportSteuerMeldungToCsv(stm);
            });
            count++;
            em.clear();
        }
        return count;
    }
}
```

Everything reused here (`CsvSteuerMeldungenWriter`, `EagerDbSteuerMeldung`,
`SimpleFieldsOverridingSteuerMeldung`, `getIsinByStmId`, `getInvNameKagStVertreterLeiByIsin`,
`MDCs.doWith`) already exists — copied verbatim from `IsinAnforderungDomainService`.

### 5. Generify `OrchestrationJobHelper.executeSubJobStep` to carry `stmIds` through

Today `executeSubJobStep` is hard-wired to `@Nullable URI` as the result type, so only the bundle
URI flows from the service call into the persisted job. EStB needs both the URI *and* the stmIds
list persisted. Generify the result type (`ifas-services/ifas-main-service/.../job/OrchestrationJobHelper.java`):

```java
public <J extends Job, R> R executeSubJobStep(
        String label,
        Supplier<Optional<J>> findExisting,
        Predicate<J> isCompleted,
        Function<J, R> extractResult,
        Supplier<R> executeService,
        Consumer<R> persistCompletedJob
) {
    Optional<J> existing = dbCtxHelper.withJobSystemDbContext(findExisting);
    if (existing.isPresent()) {
        J job = existing.get();
        if (!isCompleted.test(job)) {
            throw new IllegalStateException(label + " für diesen Lauf ist noch nicht abgeschlossen: " + job.getId());
        }
        log.info("{} for this run already completed, skipping", label);
        return extractResult.apply(job);
    }
    return dbCtxHelper.doIsolatedTransactional(() -> {
        R serviceResult = executeService.get();
        dbCtxHelper.withJobSystemDbContext(() -> persistCompletedJob.accept(serviceResult));
        return serviceResult;
    });
}
```

Update the two existing call sites trivially (behavior-preserving, `R = URI`):
- `step1Fristenpruefung`: pass `extractResult = FristenpruefungJob::getProtocolFile`
- `step2MeldefondsListen`: pass `extractResult = MeldefondsListenJob::getProtocolFile`

### 6. Result type + factory + service

New `EstbDailyReportResult(@Nullable URI resultBundleFile, List<Long> stmIds)` record in
`ifas-services/ifas-main-service/.../estbreport/`.

Extend `EstbDailyReportJobs.createCompletedEstbDailyReportJob` with a `List<Long> stmIds` parameter
that gets set via `job.setStmIds(stmIds)`.

Implement `EstbDailyReportService.doEstbDailyReport`:

```java
@Service @Slf4j @NullMarked @RequiredArgsConstructor
public class EstbDailyReportService {

    private static final String ESTB_DAILY_REPORT_BUNDLE = "estb.zip";

    private final DatabaseContextHelper dbCtxHelper;
    private final EstbDailyReportJobRepository estbDailyReportJobRepository;
    private final SteuerMeldungRepository stmRepository;
    private final EstbDailyReportWriter estbDailyReportWriter;
    private final Filestore filestore;
    private final ArchiveService archiveService;

    public EstbDailyReportResult doEstbDailyReport(LocalDate keyDate, @Nullable Integer dailyRunNumber) {
        Set<Long> alreadyReported = dbCtxHelper.withJobSystemDbContext(
                        () -> estbDailyReportJobRepository.findByKeyDate(keyDate))
                .stream()
                .flatMap(job -> Optional.ofNullable(job.getStmIds()).stream().flatMap(List::stream))
                .collect(Collectors.toSet());

        List<Long> newStmIds = stmRepository.findFinalStmIdsByZufluss(keyDate).stream()
                .filter(id -> !alreadyReported.contains(id))
                .toList();

        log.info("EStB daily report {} Lauf {}: {} new FINAL Meldungen", keyDate, dailyRunNumber, newStmIds.size());

        URI bundleUri = filestore.store(
                os -> writeBundle(os, newStmIds, keyDate),
                MediaTypes.ZIP_MEDIA_TYPE,
                ESTB_DAILY_REPORT_BUNDLE
        );
        // TODO: Bereitstellung am mft-Server — EStB je File als CSV + Einzel-Zip + ready-Flag hochladen
        archiveService.sendToArchive(bundleUri, ESTB_DAILY_REPORT_BUNDLE, ArchiveType.STEUERDATEN_AUSWERTUNG, keyDate);
        return new EstbDailyReportResult(bundleUri, newStmIds);
    }

    private void writeBundle(OutputStream out, List<Long> stmIds, LocalDate keyDate) {
        try (ZipOutputStream zos = new ZipOutputStream(out)) {
            ByteArrayOutputStream standard = new ByteArrayOutputStream();
            ByteArrayOutputStream erweitert = new ByteArrayOutputStream();
            estbDailyReportWriter.writeSteuerMeldungen(stmIds, keyDate, standard, erweitert);
            writeEntry(zos, "estb_%s_standard.csv".formatted(keyDate), standard.toByteArray());
            writeEntry(zos, "estb_%s_erweitert.csv".formatted(keyDate), erweitert.toByteArray());
        } catch (IOException e) {
            throw new IllegalStateException("Failed to build EStB daily report bundle", e);
        }
    }
}
```

(Exact filename convention inside the zip is a minor detail — follow the `<...>_EStB[...]` naming
the ISIN Anforderungsliste already established if a house style is preferred; not a structural
decision.) This mirrors `MeldefondsService.genAndArchiveMeldefondsListenBundle` for the
Filestore+Archive wiring, and always builds/archives a bundle (per the confirmed "always produce a
file" behavior) even when `newStmIds` is empty.

### 7. Wire into the orchestrator

`SteuerdatenAuswertungenJobExecutionService.step3EstbDailyReport`:

```java
private void step3EstbDailyReport(LocalDate keyDate, int runNumber, @Nullable String createdBy) {
    orchestrationJobHelper.executeSubJobStep(
            "EStB Steuerdaten-Meldung",
            () -> estbDailyReportJobRepository.findByKeyDateAndDailyRunNumber(keyDate, runNumber),
            EstbDailyReportJob::isCompleted,
            job -> new EstbDailyReportResult(job.getResultBundleFile(), job.getStmIds()),
            () -> properties.getEstb().isEnabled()
                    ? estbDailyReportService.doEstbDailyReport(keyDate, runNumber)
                    : new EstbDailyReportResult(null, List.of()),
            result -> estbDailyReportJobRepository.save(
                    EstbDailyReportJobs.createCompletedEstbDailyReportJob(
                            keyDate, runNumber, createdBy, result.resultBundleFile(), result.stmIds())));
}
```

## Files to touch

- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/postgres15/V068__estb_daily_report_jobs_stm_ids.sql` (new)
- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/sybase16/V068__estb_daily_report_jobs_stm_ids.sql` (new, no-op)
- `ifas-database/ifas-persistence-stm/.../steuermeldung/SteuerMeldungRepository.java` — add `findFinalStmIdsByZufluss`
- `ifas-database/ifas-persistence-infra/.../estbreport/EstbDailyReportJobRepository.java` — add `findByKeyDate`
- `ifas-database/ifas-persistence-infra/.../estbreport/EstbDailyReportJobs.java` — add `stmIds` param
- `ifas-domain/ifas-domain-stm/.../estbreport/EstbDailyReportWriter.java` (new)
- `ifas-services/ifas-main-service/.../estbreport/EstbDailyReportResult.java` (new)
- `ifas-services/ifas-main-service/.../estbreport/EstbDailyReportService.java` — implement
- `ifas-services/ifas-main-service/.../job/OrchestrationJobHelper.java` — generify `executeSubJobStep`
- `ifas-services/ifas-main-service/.../steuerdatenauswertungen/SteuerdatenAuswertungenJobExecutionService.java` — update all 3 step methods

## Verification

- New/updated test for `SteuerMeldungRepository.findFinalStmIdsByZufluss` (unit/repository test, H2), confirming it only returns `status = FIN`, matches `zufluss`, and excludes rows with `gueltBis` set.
- New test for `EstbDailyReportService.doEstbDailyReport`: finalize a few STMs for a Stichtag, run once (assert stmIds recorded + CSV rows written), finalize more STMs for the same Stichtag, run again with the same keyDate but next dailyRunNumber (assert only the newly-finalized ones are picked up, previously-reported ones excluded even though they're still FINAL with the same zufluss).
- Run the existing `SteuerdatenAuswertungenJobExecutionServiceTest` to confirm the orchestration still wires correctly after generifying `executeSubJobStep` (both other sub-jobs unaffected).
- `mvn test -Pno-proxy -Pdev-build -pl ifas-database/ifas-persistence-stm,ifas-database/ifas-persistence-infra,ifas-domain/ifas-domain-stm,ifas-services/ifas-main-service -am` to compile+test the touched modules; then a full `mvn test -Pno-proxy -Pdev-build` before considering this done.
- Manually trigger the Lauf via the "Geplante Aufgaben" UI (or `triggerManually`) against `LocalH2OnlyIfasApplication`, run it twice for the same keyDate with different STMs finalized in between, and inspect the archived zip contents both times.
