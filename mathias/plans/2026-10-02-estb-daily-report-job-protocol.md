# EStB daily report: own job protocol

## Context

The EStB daily report job (`EstbDailyReportJob`, sub-job cp_03 of Steuerdatenauswertungen) shows
"(Noch) kein Protokoll verfügbar." on its detail page. The UI is already complete: EStB has no
dedicated page, the generic `job-detail.html` renders `protocolCard(..., true)`, and
`JobDetailModelSupport` loads `job.getProtocolFile()`. The gap is purely backend:

- `EstbDailyReportService.doEstbDailyReport` captures no log output.
- `EstbDailyReportResult` has no protocol component.
- `EstbDailyReportJobs.createCompletedEstbDailyReportJob` never calls `setProtocolFile`.
- `SteuerdatenAuswertungenJobExecutionService.step3EstbDailyReport` therefore persists the job with
  `protocol_file_ref = null`.

The Ausschüttung batch gets its protocol from
`JobAutoProtocolAndNotificationService.executeWithProtocolAndNotifyOnErrorsOrWarnings` →
`AbstractJobWorkQueueHandler.onSuccess`. EStB can't take that path unchanged: it runs inline inside
the orchestrator (not as its own work-queue job), its job entity is created only *after* the service
returns, and the orchestrator already notifies the business department for the whole run — reusing
the notifying method would send a second mail.

The protocol content is also thin: one line (`… {} new FINAL Meldungen`). Legacy
`run_stm_files_<nr>.log` (`m_stm_files.cpp` `DoFiles`/`Finish`) carried the selection start, the
Meldung count, "Files wurden erstellt" and the status.

Scope: EStB only. Meldefonds-Listen has the same gap and stays untouched for now.

No DB migration: `protocol_file_ref` is on the base `jobs` table.

## Reuse search

- Searched for log-capture helpers (`InMemoryLogAppender`, `getFormattedLogLines`) across
  `support-libs`, `ifas-domain`, `ifas-services`, `ifas-web`: the only user is
  `JobAutoProtocolAndNotificationService` (`ifas-services/ifas-main-service/.../service/job/`).
- Its capture (start/stop around the run), file naming (`%s-Protokoll_%s.txt`), charset
  (`IfasCharsets.IFAS_PROTOCOL_CHARSET`) and `filestore.store` are exactly what EStB needs → extend
  that class instead of capturing inside the EStB service.
- `InMemoryLogAppender` instances are independent root appenders filtered by the capturing thread,
  so a nested capture inside the orchestrator's capture works: EStB lines land in both protocols.

## Chunk "Protocol helper" — no behaviour change

`JobAutoProtocolAndNotificationService`:

- `+` `public <T> ResultWithProtocol<T> executeWithProtocol(String jobType, LocalDate keyDate, Level protocolLogLevel, Supplier<T> jobExecution)`
  - same capture as the existing method (start appender, run, stop in `finally`)
  - stores the protocol when the appender is non-empty, else `protocolFile = null`
  - **no** business-department notification (Javadoc: for sub-jobs whose orchestration already
    captures and notifies)
- Extract the shared parts so both methods use them:
  - `startCapture(level, filter)` → `InMemoryLogAppender`
  - `storeProtocol(String jobType, LocalDate keyDate, InMemoryLogAppender)` → `URI` (today's
    file name + `writeProtocol`)
  - `persistProtocolAndNotifyBusinessDepartment` keeps its behaviour and calls `storeProtocol`
- `+` record `ResultWithProtocol<T>(T result, @Nullable URI protocolFile)` in
  `at.oekb.ifas.service.job`, `@NullMarked`.

Existing callers (`SteuerdatenAuswertungen…`, `AusschuettungsMeldungBatch…`,
`FristenpruefungJobExecutionService`, `GeschaeftsjahreCalcHandler`) stay unchanged.

## Chunk "EStB wiring" — the behaviour change

`EstbDailyReportResult`
- add `@Nullable URI protocolFile` as third component; update the Javadoc.

`EstbDailyReportService.doEstbDailyReport`
- inject `JobAutoProtocolAndNotificationService`
- move today's body into a private `createAndArchiveReport(keyDate, dailyRunNumber)` returning
  `(bundleUri, newStmIds)`, and run it via
  `executeWithProtocol(EstbDailyReportJob.JOB_TYPE, keyDate, Level.INFO, …)`
- return `new EstbDailyReportResult(bundleUri, newStmIds, protocolFile)`
- protocol lines (English, like the existing line and the orchestrator's):
  - `EStB daily report {keyDate} Lauf {n}: {x} new FINAL Meldungen ({y} already reported by earlier runs of this Stichtag)`
    — needs the full FINAL count before filtering
  - `EStB bundle {bundleName} written: {standardCsv}, {erweitertCsv}`
  - `EStB bundle {bundleName} scheduled for archiving ({ArchiveType})`
- keep the MFT TODO as is.

`EstbDailyReportJobs.createCompletedEstbDailyReportJob`
- add `@Nullable URI protocolFile` parameter → `job.setProtocolFile(protocolFile)` (same as
  `FristenpruefungJobs.createCompletedFristenpruefungJob`).

`SteuerdatenAuswertungenJobExecutionService.step3EstbDailyReport`
- `extractResult`: also pass `job.getProtocolFile()`
- disabled path: `new EstbDailyReportResult(skipServiceCall(...), List.of(), null)`
- `persistCompletedJob`: pass `result.protocolFile()`
- update the step Javadoc (no longer "currently simulated").

Tests (`ifas-testing/ifas-integration-tests`):
- `EstbDailyReportServiceTest`
  - adapt the `createCompletedEstbDailyReportJob` call (pass `run1.protocolFile()`)
  - assert `run1.protocolFile()` is non-null and its text contains `2 new FINAL Meldungen` and
    `EStB_1.csv`
  - assert run 2's protocol contains `1 new FINAL Meldungen (2 already reported`
  - read via `filestore.get(uri).getContentAsString(IfasCharsets.IFAS_PROTOCOL_CHARSET)`; assert
    against literal strings
- `SteuerdatenAuswertungenJobExecutionServiceTest`
  - main test: EStB job's `getProtocolFile()` is non-null and differs from the orchestrator job's
    protocol
  - resume test (`givenFristenpruefungAndMeldefondsDone_…`): same assertion for the EStB job.

## Not covered

- Meldefonds-Listen protocol (same gap, later).
- Legacy's duration line (`Files - x Minuten y Sekunden`): the transient sub-job carries no
  `startedAt`/`finishedAt` and there's no duration-logging pattern to reuse.
- Protocol on failure: if EStB throws, no sub-job row exists and the protocol is lost — same as
  every caller of the existing method; the orchestrator records the failure.

## Execution

Two chunks, each built, tested and left uncommitted in the working tree; each delegated to an
Opus 5.5 subagent with a self-contained brief, reviewed before the next starts.

## Verification

```bash
mvn -Pno-proxy install -DskipTests -pl ifas-services/ifas-main-service -am
mvn -Pno-proxy test -pl ifas-testing/ifas-integration-tests \
    -Dtest=EstbDailyReportServiceTest,SteuerdatenAuswertungenJobExecutionServiceTest \
    -Pskip-postgres15-tests -Pskip-sybase16-tests
```

Optional UI check: start `LocalH2OnlyIfasApplication` (headless: `-Dspring.devtools.restart.enabled=false`),
trigger a Steuerdatenauswertungen run, open the EStB child job from the run's Teilaufgaben → the
"Protokoll" card shows the three EStB lines.
