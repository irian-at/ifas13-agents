# Implement `IsinAnforderungslisteJobExecutionService`

## Context

The ISIN Anforderungsliste flow already has a submission side
(`IsinAnforderungslisteJobSubmissionService` stores the input `.isin` file in the filestore
and enqueues an `IsinAnforderungslisteJob` with task type `ISIN_ANFORDERUNGSLISTE`), but the
work-queue **handler** that actually processes the job is an unfinished stub:

- `IsinAnforderungslisteJobExecutionService` declares `isinAnforderungDomainService` but never
  injects it, references an undefined `inputBundle`, and never stores a result. It does not compile.

We finish this handler by following the established pattern of `StmCalcJobExecutionService`
(and its ISIN sibling `IsinAnforderungDiffJobExecutionService`): load the job, fetch its input
from the filestore, process it, package the outputs into a result ZIP, and persist the ZIP URI
back onto the job. Job status transitions (PROCESSING/COMPLETED/FAILED) are handled by the base
class `AbstractJobWorkQueueHandler` — no manual status handling needed.

**Out of scope (per user):** archive/journal and MFT delivery. There is no `ArchiveType` value,
MFT endpoint, or result-sender task for ISIN today. Leave a `TODO` noting archiving must be added
later.

## Approach

Model the handler on `IsinAnforderungDiffJobExecutionService` (the closest sibling), simplified
to the non-diff case.

**Do not use `IsinAnforderungslisteService`.** It has zero callers (no production code, no test
references it), is a trivial 2-line wrapper (extract ISIN resource from bundle + call the domain
service), and injects an unused `ErmittlungsvorgabeProvider`. The handler injects
`IsinAnforderungDomainService` directly and does the extraction inline — matching what the
original stub attempted. The staged, unused `IsinAnforderungslisteService` should be deleted.

### 1. New repository — persist the result URI

There is no `IsinAnforderungslisteJobRepository` yet. Create one mirroring
`StmCalcJobRepository` (`ifas-database/.../persistence/infra/calc/StmCalcJobRepository.java:18`):

`ifas-database/ifas-persistence-infra/src/main/java/at/oekb/ifas/persistence/infra/isinanforderung/IsinAnforderungslisteJobRepository.java`

```java
@Repository
public interface IsinAnforderungslisteJobRepository
        extends JpaRepository<IsinAnforderungslisteJob, UUID>,
                JpaSpecificationExecutor<IsinAnforderungslisteJob>,
                JobPagingRepository<IsinAnforderungslisteJob> {

    @Modifying
    @Query("UPDATE IsinAnforderungslisteJob j SET j.resultBundleFile = :resultBundleFile WHERE j.id = :jobId")
    void updateResultBundleFile(@Param("jobId") UUID jobId,
                                @Param("resultBundleFile") URI resultBundleFile);
}
```

The entity already exposes `resultBundleFile` with a `@Setter`
(`IsinAnforderungslisteJob.java:40-43`), so no entity/Flyway change is needed.

### 2. New domain output writer — package the result ZIP

**Output-writing approach — analysis & decision.** Two models exist:

- *StmCalc / `CalculationOutputs`*: regenerates each file's content on the fly from the in-memory
  `BundleCalculationResult`, streaming straight into the zip — no temp files. Works because StmCalc
  holds the whole calc result in heap.
- *ISIN / direct-copy*: `IsinAnforderungResult` carries four **materialized `Resource`** files
  (`estbStandard`, `estbErweitert`, `errorLog`, `infoLog`). The domain service writes them to
  **temp files** (`AutoCleanupTempFiles.withAutoCleanupTempDirectory`), streaming per-STM with
  `em.clear()` between meldungen — it deliberately never holds results in heap. The zip is then
  built by copying those resources via `transferTo` (`IsinAnforderungDiffOutputs.writeResultZip:54-57`).

Result file size is **not** a heap concern in either path: the domain service streams into temp
files (constant heap), and `transferTo` copies temp→zip with an 8 KB buffer (constant heap). Temp
files are ISIN's memory-safe equivalent of StmCalc's in-heap result. The only cost of direct-copy
is temp disk + double IO (write temp, re-read into zip) — negligible next to the DB-heavy processing.

Making ISIN stream straight into the zip like StmCalc would require refactoring
`IsinAnforderungDomainService` to accept an output sink instead of returning materialized
resources — which changes the shared `IsinAnforderungResult` contract and both consumers (plain +
diff). Meaningful scope, negligible payoff now.

**Decision:** implement now with a direct-copy `IsinAnforderungOutputs` util (mirrors the proven
diff path, zero domain churn). Record the streaming-sink unification (apply to the diff path too)
as a follow-up `TODO`.

*Lifecycle note:* `withAutoCleanupTempDirectory` deletes the temp dir only when the returned
`IsinAnforderungResult` is GC-unreachable (`Cleaner`-registered) — **not** on callback return. So
the handler must hold the `result` reference for the entire duration of the zip write (it does),
exactly like the diff path.

The existing `IsinAnforderungDiffOutputs.writeResultZip` cannot be reused directly: it requires an
`IsinAnforderungDiffResult` and emits `#neu` diff filenames plus diff reports. Add a plain writer
using the non-`neu` names from `IsinAnforderungFilenames`
(`standardCsv/erweitertCsv/errorLog/infoLog`):

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/isinanforderung/IsinAnforderungOutputs.java`

```java
@UtilityClass @NullMarked
public class IsinAnforderungOutputs {
    public static void writeResultZip(String isinFilename, IsinAnforderungResult result, OutputStream out) {
        try (ZipOutputStream zos = new ZipOutputStream(out)) {
            writeEntry(zos, IsinAnforderungFilenames.standardCsv(isinFilename), result.estbStandard());
            writeEntry(zos, IsinAnforderungFilenames.erweitertCsv(isinFilename), result.estbErweitert());
            writeEntry(zos, IsinAnforderungFilenames.errorLog(isinFilename), result.errorLog());
            writeEntry(zos, IsinAnforderungFilenames.infoLog(isinFilename), result.infoLog());
        } catch (IOException e) {
            throw new IllegalStateException("Cannot write ISIN Anforderungsliste result to ZIP", e);
        }
    }
    // private writeEntry(zos, name, resource): putNextEntry + resource.getInputStream().transferTo(zos) + closeEntry
    // (same 4-line helper as IsinAnforderungDiffOutputs.writeEntry:169)
}
```

This mirrors the core-4-files block of `IsinAnforderungDiffOutputs.writeResultZip:54-57`.

### 3. Finish the handler

Rewrite `ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/isinanforderung/IsinAnforderungslisteJobExecutionService.java`
following `StmCalcJobExecutionService` structure:

- **Annotations:** keep `@Service @Slf4j @NullMarked`. Keep `@ConditionalOnProperty(workqueue.enabled=true)`
  only if the sibling diff/calc services use it — they do **not**, so drop it for consistency
  (the filestore is injected `@Autowired(required=false)` like the sibling, which is the real guard).
- **Base constructor:** `IsinAnforderungslisteJob` uses `DefaultJobStatus`, so keep the convenience
  `super(jobService, IsinAnforderungslisteJob.WQ_TASK_TYPE)` — no custom status enum (unlike the diff job).
- **Inject:** `JobService jobService`, `IsinAnforderungslisteJobRepository jobRepository`
  (`@SuppressWarnings("SpringJavaInjectionPointsAutowiringInspection")`),
  `@Autowired(required=false) @Nullable Filestore filestore`,
  `IsinAnforderungDomainService isinAnforderungDomainService`,
  `DatabaseContextHelper dbCtxHelper`.
- **`executeAsynchronously(UUID jobId)`:**
  1. Load job + input resource inside `dbCtxHelper.withJobSystemDbContext(...)`, guarding on
     `status == PROCESSING` (mirror `IsinAnforderungDiffJobExecutionService.getJobInfo:153`).
     Return `null` if not found / wrong state.
  2. `SteuerMeldungBundle bundle = SteuerMeldungBundles.bundleOf(inputResource)` — the input is a
     single `.isin` file; `bundleOf` classifies it. (Diff uses `bundlesOf(...).getFirst()` for
     possible nested ZIPs; plain submission stores a single file, so `bundleOf` is correct.)
     `NamedResource isinResource = bundle.getSingleResource(BundleFileType.ISIN_ANFORDERUNGSLISTE_FILE);`
  3. `IsinAnforderungResult result = isinAnforderungDomainService.processIsinListWithCallback(isinResource, job.getKeyDate(), null, true);`
     — `null` visitor (no diff), `true` = skip unsupported versions (matches the current stub intent).
  4. Package + store:
     `String resultFilename = FileNames.getBaseName(job.getInputFilename()) + "#estb-result.zip";`
     `URI uri = filestore().store(out -> IsinAnforderungOutputs.writeResultZip(isinFilename, result, out), MediaTypes.ZIP_MEDIA_TYPE, resultFilename);`
  5. `dbCtxHelper.withJobSystemDbContext(() -> jobRepository.updateResultBundleFile(jobId, uri));`
  6. `// TODO: archive + journal the ISIN Anforderungsliste result (see StmCalcJobExecutionService.scheduleArchiveAndJournal); needs a new ArchiveType.`
     `// TODO: consider streaming result content straight into the zip (StmCalc/CalculationOutputs style) instead of temp-file copy, and unify with IsinAnforderungDiffOutputs.`
  7. `return null;` (no protocol URI).
- Add the private `filestore()` null-guard helper (copy from
  `IsinAnforderungDiffJobExecutionService.filestore():176`).
- Processing runs in the ambient (work-queue-restored) DB context, exactly like
  `StmCalcJobExecutionService` — no explicit `withDatabaseContext` switch (the plain job stores no
  DB context, unlike the diff job's setting JSON).

### Reuse summary (searched `ifas-services`, `ifas-domain-stm`, `ifas-persistence-infra`)

- **Reused:** `IsinAnforderungDomainService.processIsinListWithCallback`,
  `SteuerMeldungBundles.bundleOf` + `SteuerMeldungBundle.getSingleResource`,
  `IsinAnforderungFilenames`, `FileNames.getBaseName`, `MediaTypes.ZIP_MEDIA_TYPE`,
  `Filestore.get/store`, `AbstractJobWorkQueueHandler` status handling, `JobService.getJobById`,
  `DatabaseContextHelper.withJobSystemDbContext`.
- **Net-new (justified):** `IsinAnforderungslisteJobRepository` (none exists; every job type has its
  own — StmCalc, Diff); `IsinAnforderungOutputs.writeResultZip` (the diff writer needs a
  `IsinAnforderungDiffResult` and emits `#neu` diff filenames, so it does not fit the plain case).

## Files

- **New:** `ifas-database/ifas-persistence-infra/.../isinanforderung/IsinAnforderungslisteJobRepository.java`
- **New:** `ifas-domain/ifas-domain-stm/.../isinanforderung/IsinAnforderungOutputs.java`
- **Rewrite:** `ifas-services/ifas-main-service/.../isinanforderung/IsinAnforderungslisteJobExecutionService.java`
- **Delete:** `ifas-services/ifas-main-service/.../isinanforderung/IsinAnforderungslisteService.java`
  (unused wrapper, zero callers — superseded by the handler calling the domain service directly)

## Verification

1. Build the touched modules:
   `mvn clean install -Pno-proxy -pl ifas-database/ifas-persistence-infra,ifas-domain/ifas-domain-stm,ifas-services/ifas-main-service -am`
   (annotation processors regenerate; confirms MapStruct/Lombok wiring and no compile errors).
2. Confirm Spring context wiring: the handler must be discovered as a `WorkQueueHandler` for task
   type `ISIN_ANFORDERUNGSLISTE`. A focused test (or existing work-queue integration test) that
   submits via `IsinAnforderungslisteJobSubmissionService.submit(...)` with a sample `.isin` file
   and asserts the job reaches `COMPLETED` with a non-null `resultBundleFile`, and that the stored
   ZIP contains the four `_EStB.csv` / `_EStB_erweitert.csv` / `_error.log` / `_info.log` entries.
   Reuse test fixtures/patterns from the existing ISIN diff/execution tests if present.
3. Verify the FAILED path: a malformed input should leave the job in FAILED (via base-class
   `onFailure`) with the error message recorded.
