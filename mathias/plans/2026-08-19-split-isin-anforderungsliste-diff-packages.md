# Split the ISIN-Anforderungsliste Diff from the production ISIN-Anforderungsliste

## Context

The ISIN Anforderungsliste Diff exists only for the Parallelbetrieb — the phase where the new
system's output is compared against the legacy CPP system. When that phase ends it gets deleted.
Today its classes sit interleaved with the production ISIN-Anforderungsliste classes in the same
packages, separated only by a `Diff` infix in the class name, so "what goes when the parallel run
ends" is not visible in the tree.

The Diff job is to the ISIN Anforderungsliste what the **Recalculation is to the Calculation**:
`calc` / `recalc` are sibling packages in all three layers, and that is the boundary to mirror.
(`recalc.diff` is the field-diff *engine* nested inside recalc — a different thing, and one the ISIN
diff consumes.)

Outcome: the Parallelbetrieb half lives in its own `isinanforderungdiff` package per layer, so a
future deletion is "delete three directories plus three controllers and edit six shared files",
with no dead members left on production classes.

## What makes this cheap

Verified across all layers: **there is not one production→diff reference anywhere.** No production
class imports, names, or calls any `IsinAnforderungDiff*`/`IsinAnforderungslisteDiff*` type. The
diff→production edge is one-way and narrow — exactly six types (`IsinAnforderungResult`,
`IsinAnforderungFilenames`, `IsinAnforderungValidationMsg`, `IsinListEntries`, `IsinListEntry`, and
`IsinAnforderungValidationMsgCode` in tests). So the moves are mechanical; only the three shared
seams below need real design.

The web layer needs no move at all — `web.stm` (production) and `web.testing` (Parallelbetrieb)
already separate the six controllers correctly.

## Target structure

| Layer | Production | Parallelbetrieb |
|---|---|---|
| domain | `domain.stm.isinanforderung` — 12 classes | `domain.stm.isinanforderungdiff` — 10 + 1 new |
| persistence | `persistence.infra.isinanforderung` — 4 | `persistence.infra.isinanforderungdiff` — 4 |
| service | `service.isinanforderung` — 5 | `service.isinanforderungdiff` — 5 |
| web | `web.stm` — 3 controllers *(already)* | `web.testing` — 3 controllers *(already)* |

Sibling packages, mirroring `calc`/`recalc`. `persistence.infra` is flat today, and a sibling keeps
it flat.

## Work

### 1. Moves

**Domain** → `domain.stm.isinanforderungdiff`: the ten `IsinAnforderungDiff*` classes
(`…CsvDiffResult`, `…CsvDiffWriter`, `…DeltaEntry`, `…DeltaReport`, `…DeltaReports`,
`…DeltaReportWriter`, `…LegacyLogEntry`, `…LegacyLogs`, `…Outputs`, `…Result`), plus the two tests
`IsinAnforderungDiffDeltaReportsTest` and `IsinAnforderungDiffLegacyLogsTest`.

**Persistence** → `persistence.infra.isinanforderungdiff`: `IsinAnforderungslisteDiffJob`,
`…DiffJobRepository`, `…DiffJobRepositoryImpl`, `…DiffJobStatus`. Note `multidbctx.repository-packages`
is `at.oekb.ifas.persistence`, so the new package stays inside the scanned prefix — no config change.

**Service** → `service.isinanforderungdiff`: `IsinAnforderungDiffService`,
`IsinAnforderungDiffJob{Execution,Query,Submission}Service`, `IsinAnforderungDiffSetting`, plus
`IsinAnforderungDiffSettingTest`.

No class is renamed. The `Diff` infix stays, matching how `recalc.diff` keeps `StmDiff` / `FieldDiff`.

### 2. The three shared seams

**`IsinAnforderungFilenames`** — move the seven diff-only members to a new
`isinanforderungdiff/IsinAnforderungDiffFilenames`: `NEU_SUFFIX`, `standardCsvNeu`,
`erweitertCsvNeu`, `errorLogNeu`, `infoLogNeu`, `testdataYaml`, and the two private helpers
`appendNeu` / `insertNeuSuffix`. The new class delegates to the production
`IsinAnforderungFilenames` for the base names. Production keeps exactly the four real output names,
which is what its Javadoc already documents. Callers to update: `IsinAnforderungDiffOutputs` (5 call
sites) and `IsinAnforderungDiffTest` (4).

**`IsinAnforderungDomainService` + `IsinAnforderungResult`** — these two are one problem, because
`messages` is computed inside the service and cannot be reconstructed by the diff (the diff can get
*parse* messages from `IsinListParseResult`, but not the ones added during processing). Replace the
nullable `Consumer<SteuerMeldung>` parameter with a single Parallelbetrieb hook that carries both
things the diff needs:

```java
// in the production package, Javadoc-marked Parallelbetrieb-only
public interface IsinAnforderungRunObserver {
    void onSteuerMeldung(SteuerMeldung stm);
    void onMessages(List<IsinAnforderungValidationMsg> messages);
}
```

```java
// production path — no hook, no diff concession in the signature
public IsinAnforderungResult processIsinList(NamedResource isinInput, LocalDate stichtag)

// Parallelbetrieb path only
public IsinAnforderungResult processIsinList(
        NamedResource isinInput, LocalDate stichtag, IsinAnforderungRunObserver observer)
```

`IsinAnforderungResult` then narrows to the four resources production actually reads —
`estbStandard`, `estbErweitert`, `errorLog`, `infoLog`. The other three components go as follows:

- `messages` → delivered through `onMessages`; the diff collects them into `IsinAnforderungDiffResult`.
- `isinInput`, `stichtag` → become components of `IsinAnforderungDiffResult`. Free: the diff service
  already holds both locally, since it passes them into the call.

Why an interface rather than keeping `messages` on the record or adding a carrier record: both
production and diff call sites then return the same clean four-component result, and the entire
leftover is one interface plus one overload plus the two lines that fire it — all deleted with the
diff. Consumers to update: `IsinAnforderungDiffService` (builds the observer),
`IsinAnforderungDiffOutputs` (7 accessor call sites), `IsinAnforderungDiffJobExecutionService`
(`messages()`), `IsinAnforderungDiffTest`.

`IsinAnforderungOutputs` turned out 100% production — it moves nowhere and changes nothing.

### 3. Import-only updates

Six files reference moved types but stay where they are:
`service/parallelbetrieb/ParallelbetriebJobSubmissionService`, `web/system/WorkQueuePageController`,
`web/testing/IsinAnforderungDiff{Form,List,Detail}PageController`, and
`ifas-dev-tools/…/DatabaseSchemaTool` (which hand-lists all three ISIN entity classes — it must keep
compiling). Tests: `JobPagedSearchTest`, `IsinAnforderungDiffTest`. Also fix the stale example in
`job/JobPagingRepository`'s Javadoc, which names `IsinAnforderungslisteDiffJob`.

### 4. `package-info.java` in each of the three new packages

Following the one existing role-labelling precedent, `web/testing/package-info.java`:

```java
/**
 * Parallelbetrieb only: compares the ISIN-Anforderungsliste against the legacy CPP outputs.
 * Deletable once the parallel run ends — production code must never depend on this package.
 */
```

### 5. Two fixes worth taking along

- `IsinAnforderungDiffTest` sits in the `domain.stm.isinanforderung` test package but the class under
  test is the *service* `IsinAnforderungDiffService`. Move it to `service.isinanforderungdiff`, and
  its fixtures `estbreport.zip` / `estbreport-with-error.zip` to the matching resources path. (It is
  `@Disabled`, so it needs a compile check, not a green run.)
- `IsinAnforderungDiffOutputs` duplicates `IsinAnforderungOutputs.writeEntry` verbatim. **Leave the
  duplication.** Normally `reuse-before-reimplementing` would say extract a shared helper, but a
  five-line ZIP helper duplicated across this boundary is the point: production must not grow a
  dependency that exists to serve the diff. Flagging it so it is a decision, not an oversight.

## Not in scope

`ParallelbetriebJobSubmissionService` stays in `service.parallelbetrieb` — it dispatches StmRecalc,
Ausschuettung, Preismeldung and BadInput as well, so it is Parallelbetrieb-wide, not ISIN-specific.
`IsinAnforderungslistenBatchJob` stays on the production side (deprecated stub, but production).
No Flyway change, no table or `JOB_TYPE`/`WQ_TASK_TYPE` change — nothing here touches persisted
identifiers. No module split: `ifas-domain-recalc` was its own module until commit `28c55b3a6` folded
it back in precisely because it sat on top of `ifas-domain-stm` and bought no isolation; the ISIN diff
sits the same way.

Six files will keep naming both halves and cannot be separated — `IfasRight`, `WebUiAuthorization`,
`WorkQueuePageController`, `layout.html`, `job-detail.html`, `work-queue-detail.html`. A future
deletion edits these; it does not delete them.

## Execution note

`.claude/rules/ide-refactoring.md` mandates IDE/MCP tools for moves, but the JetBrains MCP server
exposes only `mcp__idea__rename_refactoring` — there is no move-class tool, and the rule itself
points at the manual IntelliJ *Refactor > Move* for package moves. I will therefore do the moves with
`git mv` plus a mechanical rewrite of the `package` and `import` lines. That still satisfies the
rule's three stated reasons: git tracks the renames (content is unchanged, so similarity detection
holds), references are updated in the same pass, and the full build verifies it. Say the word if you
would rather drive the moves in the IDE yourself — then I take the seam extractions and package-infos
afterwards.

## Verification

```bash
mvn clean install -Pno-proxy -Pdev-build
```

1. **The boundary holds.** After the move, this must print nothing:
   ```bash
   grep -rn "isinanforderungdiff" --include=*.java \
     ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/isinanforderung/ \
     ifas-database/ifas-persistence-infra/src/main/java/at/oekb/ifas/persistence/infra/isinanforderung/ \
     ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/isinanforderung/
   ```
2. **Nothing renamed at the DB or work-queue level** — confirm `git diff` touches no `.sql` file and
   no `JOB_TYPE` / `WQ_TASK_TYPE` literal.
3. **Targeted tests**: `IsinListEntriesTest`, `IsinAnforderungValidationMsgTest`,
   `IsinAnforderungLogWriterTest` (production domain, must be untouched by the seam changes);
   `IsinAnforderungDiffDeltaReportsTest`, `IsinAnforderungDiffLegacyLogsTest`,
   `IsinAnforderungDiffSettingTest` (moved diff tests); `IsinAnforderungslisteJobExecutionServiceTest`
   (production job end-to-end, exercises the new 2-arg `processIsinList`); `JobPagedSearchTest`
   (uses the moved diff entity).
4. **Both UIs still work.** Run `LocalH2OnlyIfasApplication` with
   `-Dspring.devtools.restart.enabled=false` and check that STM → ISIN Anforderungsliste still
   uploads a `.isin` and reaches COMPLETED with its four-entry result ZIP, and that
   Testen → STM ISIN Anforderungsliste Diff still renders its list and form. The diff job itself
   needs a legacy bundle to run, so rendering plus a submitted job is the realistic check.
5. **Spring still finds everything** — no `@ConditionalOnProperty`, `scanBasePackages` or
   `repository-packages` entry names these packages individually, but a clean startup with zero
   `NoSuchBeanDefinitionException` is the proof.
