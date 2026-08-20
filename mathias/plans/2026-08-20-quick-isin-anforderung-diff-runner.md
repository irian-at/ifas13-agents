# Quick local runner for the ISIN-Anforderungsliste Diff

## Context

`QuickRecalculationTest` gives a zero-ceremony local runner for STM recalc: drop a Lieferung zip into a
gitignored classpath folder, un-`@Disable` the method, run it from the IDE, inspect the loose output files
under `target/quick-recalc`. No assertions, no fixtures to maintain.

The ISIN-Anforderungsliste **Diff** (Parallelbetrieb, split out in `145cfb6da`) has no such runner. Its only
integration test — `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/service/isinanforderungdiff/IsinAnforderungDiffTest.java`
— hardcodes two committed fixture zips (20 MB + 57 MB) and hand-rolls all output writing, duplicating what
`IsinAnforderungDiffOutputs.writeResultZip` already does for the production job. Trying a new ISIN list today
means editing that test.

Goal: the same drop-a-zip-and-run concept for the Diff, and one shared writer so the output file set and its
names are defined in exactly one place.

## Approach

Three code changes plus the input folder. The "shared writer" is the production class
`IsinAnforderungDiffOutputs` — it already knows the complete output set; it just cannot write to a directory yet.

### 1. `IsinAnforderungDiffOutputs`: add a directory writer alongside the zip writer

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/isinanforderungdiff/IsinAnforderungDiffOutputs.java`

Extract the body of `writeResultZip` into a private `writeAllEntries(...)` parameterized by an entry sink, and
add a public `writeResultFiles(...)` that points the sink at a directory:

```java
public static void writeResultZip(String isinFilename, IsinAnforderungDiffResult result,
        boolean includeInputFiles, boolean includeTestdataYaml,
        @Nullable TestdataExporter testdataExporter, OutputStream zipOut) throws IOException

public static void writeResultFiles(String isinFilename, IsinAnforderungDiffResult result,
        boolean includeInputFiles, boolean includeTestdataYaml,
        @Nullable TestdataExporter testdataExporter, Path outputDir)

private static void writeAllEntries(..., Function<String, OutputStreamSupplier> entrySink)
```

`writeResultZip` keeps its signature verbatim so its two callers —
`IsinAnforderungDiffJobExecutionService.executeReport` and, through it, the
`ParallelbetriebJobSubmissionService` routing at `:286`/`:363` — are untouched. `writeResultFiles` does **not**
declare `IOException` (per the project's exception rule and matching `RecalculationTests.writeResultFiles`); it
wraps in `IllegalStateException` naming the output path.

Reuse the existing `at.oekb.ifas.core.io.OutputStreamSupplier` / `OutputStreamConsumer` pair rather than
inventing an interface — this is the same shape `RecalculationOutputs.write(result, typeAndName,
OutputStreamSupplier, testdataExporter)` already uses, which is what makes `RecalculationTests.writeResultFiles`
a thin adapter.

- zip sink: `name -> consumer -> { zos.putNextEntry(new ZipEntry(name)); consumer.accept(zos); zos.closeEntry(); }`
- directory sink: `name -> consumer -> { try (OutputStream os = Files.newOutputStream(outputDir.resolve(name))) { consumer.accept(os); } }`

`OutputStreamSupplier.doWithOutputStream` does not declare `IOException`, so both sinks wrap it.
`writeResultFiles` does `Files.createDirectories(outputDir)` and, like `RecalculationTests.writeResultFiles`,
does **not** clean the directory — a renamed output from an earlier run survives.

The private helpers (`writeEntry`, `writeCsvDiffReport`, `writeLogDeltaReports`, `writeLogDeltaReport`,
`writeInputBundleFiles`, `writeTestdataYamlFile`) keep their logic and take the sink instead of the
`ZipOutputStream`. No change to the file set, the names, or the log lines.

### 2. New `QuickIsinAnforderungDiffTest`

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/service/isinanforderungdiff/QuickIsinAnforderungDiffTest.java`

Modeled directly on `QuickRecalculationTest` — same constant block / `// === Derived paths ===` banner /
`@Disabled @TestTemplate` / class-and-method javadoc naming the exact filesystem paths.

```java
private static final @Nullable LocalDate STICHTAG_OVERRIDE = null;
//private static final LocalDate STICHTAG_OVERRIDE = LocalDate.of(2026, 2, 16);
private static final boolean PERFORM_STM_FIELD_DIFF = true;
private static final boolean INCLUDE_INPUT_FILES = false;   // input CSVs run to 100+ MB
private static final boolean INCLUDE_TESTDATA_YAML = false;

// === Derived paths (no need to touch) ===
private static final String ISSUE_RESOURCE_PATH = "at/oekb/ifas/domain/recalc/issues/quick-isin-diff/";
private static final Path OUTPUT_DIR = Path.of("target/quick-isin-diff");

@RegisterExtension
static Extension extension = TEST_WITH_H2_ONLY;
//static Extension extension = TEST_WITH_POSTGRES_ONLY;

private @Inject IsinAnforderungDiffService isinAnforderungDiffService;
private @Inject BasedataCreator basedataCreator;
private @Inject FondsExporter fondsExporter;
private @Inject SimpleTransactionTemplate tx;
```

One method, `givenIsinAnforderungslisteZips_whenDiff_thenWriteResultsToFilesystem()`:

1. `basedataCreator.createBasedata()` **outside** any transaction (it imports with `transactional = true`).
2. Discover inputs: `Resources.findResourcesInClasspathFolder(ISSUE_RESOURCE_PATH)` filtered by
   `FileTypes::isZipFile` — same filter the multi-Lieferung recalc method uses. Zip-only sidesteps the
   `bundleOf(Collection)` trap (`"must have at least one Melde-CSV…"`, see the stale-test-classes note below),
   since none of the ISIN input file types satisfy `determineBundleFilename`. `log.info` the discovered
   filenames so a leftover in `target/test-classes` is obvious, and fail with a message naming
   `ISSUE_RESOURCE_PATH` when no zip is found — otherwise a forgotten input looks like a green run.
3. Per zip:
   - `SteuerMeldungBundle bundle = SteuerMeldungBundles.bundlesOf(zipResource).getFirst();` — exactly what
     `IsinAnforderungDiffJobExecutionService.executeReport` does. Streams entries to temp files (cleaned via
     `AutoCleanupTempFiles`' `Cleaner` when the bundle is unreachable), so the 100 MB CSVs and the multi-hundred-MB
     testdata YAML never land on the heap.
   - `String isinFilename = bundle.getSingleResource(BundleFileType.ISIN_ANFORDERUNGSLISTE_FILE).getFilename();`
   - Stichtag: `STICHTAG_OVERRIDE`, else the `yyyyMMdd` immediately before `.isin` (regex
     `(\d{4})(\d{2})(\d{2})\.isin`, as in `IsinAnforderungDiffTest.extractStichtag`), else
     `LocalDates.nowInVienna()`. Log which branch won, like `QuickRecalculationTest.resolveStichtag`.
   - `IsinAnforderungDiffResult result = tx.doTransactional(() -> isinAnforderungDiffService.process(bundle,
     stichtag, false, PERFORM_STM_FIELD_DIFF));` — `importBasedata` is `false` because step 1 already did it,
     and `process` needs the surrounding transaction (it imports with `transactional = false` and
     `processIsinList` walks lazy entities). `process` picks the `TESTDATA_YAML_FILE` out of the bundle itself,
     so there is no separate `data-import.yaml.txt` hook to mirror.
   - **Outside** that transaction — same order as the existing test and as the job service —
     `IsinAnforderungDiffOutputs.writeResultFiles(isinFilename, result, INCLUDE_INPUT_FILES,
     INCLUDE_TESTDATA_YAML, this::exportTestdata, OUTPUT_DIR.resolve(FileNames.getBaseName(zipFilename)))`.
     The result's four output resources are temp files and `csvDiff` holds CSV-loaded objects plus
     already-computed `StmDiff`s, so nothing lazy is touched.
   - `exportTestdata` delegates to `fondsExporter.exportFondsByIsin(out, isinList, stichtag, 0, false, true)`,
     copied from `IsinAnforderungDiffJobExecutionService.exportTestdata` — this is how you cut a small fixture
     out of a big database. It reads via `tx.doInIsolatedTransaction`, i.e. committed state only, which is why
     the write happens after the run's transaction commits.
4. Final `log.info("... written to: {}", OUTPUT_DIR.toAbsolutePath())`.

Output per zip: `<isin-basename>_EStB#neu.csv`, `_EStB_erweitert#neu.csv`, `_error#neu.log`, `_info#neu.log`,
`error#diff.txt`, `info#diff.txt`, and `EStB#field-diff.txt` (or `EStB#csv-abgleich.txt` when
`PERFORM_STM_FIELD_DIFF` is off) — names come from `IsinAnforderungDiffFilenames`, unchanged.

Javadoc must state two constraints, both inherited from production rather than invented here:
- The zip must carry a plain `*.yaml.txt` testdata export. `SteuerMeldungBundles.bundlesOf` treats a nested
  `.zip` entry as a separate bundle and throws on a zip/plain-file mixture, so an inner `.yaml.zip` fails in
  the UI job too.
- The H2 schema is truncated per test **method**, not per loop iteration — drop one zip normally; several only
  when their fonds data does not overlap.

### 3. Fold `IsinAnforderungDiffTest` onto the shared writer

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/service/isinanforderungdiff/IsinAnforderungDiffTest.java`

Replace the four `Files.copy` calls plus `writeDiffReport` and `writeCsvDiffReport` (and their now-unused
imports of `IsinAnforderungDiffCsvDiffWriter`, `IsinAnforderungDiffDeltaReport(s)`,
`IsinAnforderungDiffLegacyLogEntry`, `IsinAnforderungDiffLegacyLogs`, `IsinAnforderungResult`,
`IsinAnforderungValidationMsg`, `IsinAnforderungDiffFilenames`) with one
`IsinAnforderungDiffOutputs.writeResultFiles(...)` call — ~90 lines out.

Keep its zip-reading plumbing (`buildBundleFromZip`, `addExportFileFromZip` with the `.yaml.zip` unwrap,
`findEntryName`, `extractStichtag`) untouched: those two committed fixtures are its input contract, and the
`.yaml.zip` branch is capability the new runner deliberately does not carry.

Two behavioural notes, both intended:

- `writeResultFiles` reads the legacy `error.log` / `info.log` from `result.inputBundle()` rather than from the
  `ZipFile` directly. `buildBundleFromZip` already puts both into the bundle as `ERROR_LOG_FILE` /
  `INFO_LOG_FILE`, so the diffs come from the same bytes as before.
- The CSV diff file gets renamed. The test calls `process(bundle, stichtag, true, false)` — i.e.
  `performStmFieldDiff = false` — yet hardcodes the output name `EStB#field-diff.txt`.
  `IsinAnforderungDiffOutputs` picks the name from `csvDiff.fieldDiffPerformed()`, so the file becomes
  `EStB#csv-abgleich.txt`, which is what its content (key comparison only, no field diffs) actually is. Same
  name the UI job produces for that flag combination.

### 4. Input folder + gitignore

Create `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-isin-diff/`
with an empty `.gitkeep`, and add the folder to the `# do not commit adhoc testdata files` block in `.gitignore`
(next to the existing `quick-recalc` line, ~line 813). The folder itself is ignored, so the `.gitkeep` needs
`git add -f` — exactly how `quick-recalc/.gitkeep` is tracked. Output under `target/` is already ignored.

## Files touched

| File | Change |
|---|---|
| `.../domain/stm/isinanforderungdiff/IsinAnforderungDiffOutputs.java` | entry-sink refactor + new `writeResultFiles` |
| `.../service/isinanforderungdiff/QuickIsinAnforderungDiffTest.java` | new |
| `.../service/isinanforderungdiff/IsinAnforderungDiffTest.java` | drop hand-rolled writing |
| `.../resources/at/oekb/ifas/domain/recalc/issues/quick-isin-diff/.gitkeep` | new (force-added) |
| `.gitignore` | one line |

## Conventions to honour

- No `var`; interfaces in signatures; `@NullMarked` + explicit `@Nullable`; `@Slf4j`, never a manual logger.
- Chopped-down argument lists put the closing `)` on its own line.
- The new `writeResultFiles` must not declare `IOException`; wrap it in `IllegalStateException` with the path in
  the message. `writeResultZip`'s existing `throws IOException` stays as it is.
- Test naming `given…_when…_then…`, `@Inject` not `@Autowired`, `@TestTemplate` not `@Test`
  (`MultiDatabaseExtension` is a `TestTemplateInvocationContextProvider`).
- Comments describe the code as it stands — no "used to", no fixture archaeology.

## Verification

1. Compile: `mvn clean install -Pno-proxy -Pdev-build -pl ifas-domain/ifas-domain-stm,ifas-testing/ifas-integration-tests -am -DskipTests`
2. Regression on the shared writer — the production zip path must be unchanged:
   `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=IsinAnforderungDiffSettingTest,IsinAnforderungDiffDeltaReportsTest,IsinAnforderungDiffLegacyLogsTest`
   and `mvn test -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests -pl ifas-testing/ifas-integration-tests`
   to confirm nothing else in the module broke.
3. End-to-end, manual (this is the deliverable). Use the small local fixture, not the committed 20/57 MB ones:
   - copy the untracked `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/estbreport/isin_test_01.zip`
     (1.3 MB: `isin_test_01.isin`, `_EStB.csv`, `_EStB_erweitert.csv`, `_error.log`, `_info.log`,
     `fonds-export_20260527_141334.yaml`) into the new `quick-isin-diff/` folder;
   - its ISIN filename carries no `yyyyMMdd`, so this also exercises the fallback — set `STICHTAG_OVERRIDE` to
     a date the fonds export covers (its name says 2026-05-27) for a meaningful run, and confirm the log line
     says which branch supplied the Stichtag;
   - remove `@Disabled` locally and run from IntelliJ;
   - inspect `target/quick-isin-diff/isin_test_01/`: the four `#neu` files plus `error#diff.txt`,
     `info#diff.txt`, `EStB#field-diff.txt` (field diff on), and log lines reporting the match /
     only-in-legacy / only-in-new and matched / only-in-legacy / only-in-recalc counts;
   - flip `PERFORM_STM_FIELD_DIFF` to `false` and re-run: the CSV report must switch to
     `EStB#csv-abgleich.txt`;
   - cross-check the shared writer against the old hand-rolled one: on the same input, the four `#neu` files
     and the two `#diff.txt` files must be byte-identical to what pre-refactor `IsinAnforderungDiffTest`
     produced (capture a copy of `target/test-output/estbreport/...` before applying change 3);
   - restore `@Disabled` and delete the copied zip before committing.
4. `git status` must show no new tracked file inside `quick-isin-diff/` other than `.gitkeep`.
