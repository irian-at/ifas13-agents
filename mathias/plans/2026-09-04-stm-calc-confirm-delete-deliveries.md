# Accept confirm and delete deliveries in the STM calculation path

## Context

Uploading a Steuermeldung delivery on **Steuermeldung-Lieferungen** (`/ui/stm-calc`) fails for
confirm files: the job ends `FAILED` with

```
IllegalStateException: No CSV-Melde-File found in input bundle
  at CalculationDomainService.doCalc(CalculationDomainService.java:108)
```

Two observations from the report, only one of which is the cause:

1. **"even a single .csv ends up in a zip"** — real, but not the cause.
   `StmCalcJobSubmissionService.submitCalculation`
   (`ifas-services/ifas-main-service/.../calc/StmCalcJobSubmissionService.java:124-158`) wraps every
   upload with `writeResourceAsZip` and stores it as `<basename>.zip`. The wrapping is unnecessary:
   the *input* side of a bundle is already optional (Change 3), only the *output* side needs a zip.
   The single entry keeps the original filename, so nothing is lost or renamed — it is not why the
   job fails.

2. **The real defect** — the calc path only accepts a Melde-CSV:
   - `SteuerMeldungBundles.determineFileTypeFromFilePath` types bundle entries **by filename
     suffix**, and `*_confirm.csv` matches `CONFIRM_CSV_FILE` at
     `ifas-domain/ifas-domain-stm/.../bundle/SteuerMeldungBundles.java:663` — *before* the generic
     `.csv` branch (`:686`), so the content sniffing in
     `determineActualTypeForUnspecifiedCsvOrTxtFile` (`:853`) that would map a first token `START`
     to `STM_MELDUNG_CSV_FILE` never runs.
   - `CalculationDomainService.doCalc`
     (`ifas-domain/ifas-domain-stm/.../calc/CalculationDomainService.java:94-109`) resolves its
     input **only** as `STM_MELDUNG_CSV_FILE` and otherwise throws.

   The recalc twin already has the fallback chain the calc path lacks:
   `RecalculationDomainService.doRecalc`
   (`ifas-domain/ifas-domain-stm/.../recalc/RecalculationDomainService.java:459-533`) tries
   `STM_MELDUNG_CSV_FILE` → `CONFIRM_CSV_FILE` → `DELETE_CSV_FILE` → `PREFILLED_EXCEL_FILE`.

`processLieferung` itself is content-driven and handles `CONFIRMED` / `DELETE` deliveries fully
(`SteuerlicheErmittlungDomainService.java:456-546`); nothing downstream cares about the filename.
So this is a missing branch in `doCalc`, nothing deeper.

**Scope of the impact:** not only the web UI. `submitCalculation` is the single funnel for *both*
inbound paths — `StmCalcFormPageController:141` (web UI) and `SteuerMeldungRestController:78`
(REST/MFT) — and both end in `calculateBundle`. Every confirm and delete delivery whose filename
carries the `_confirm` / `_delete` suffix fails today, in production as well.

Intended outcome: a confirm or delete delivery uploaded as a single CSV (or arriving zipped) is
processed like any other Lieferung, with output filenames matching legacy; the input artifact is
stored as it was delivered; and the adjacent upload defects found in the same code are fixed for
the calc path.

**Why the bundle stays on the output side.** One delivery produces the return CSV, the generated
confirm and delete CSVs, and the error/info/statistics logs, plus a copy of the input file —
`BundleCalculationResults.STANDARD_CALC_BUNDLE_FILES` together with `getInputFileTypesAndNames`.
That is the legacy per-delivery file set and it is what goes back over MFT. Beyond holding the
files, `BundleCalculationResult.inputBundle()` is what *names* the outputs
(`getOutputFilenameForCorrespondingInputFile` → `getBaseFileNamePrefix`) and what
`CalculationOutputs.write` copies the input from. So `calculateBundle` keeps its bundle parameter;
what changes is only how the input artifact is stored.

## Change 1 — `doCalc` fallback chain (the fix)

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/calc/CalculationDomainService.java`

Replace the single-branch `doCalc` with the same order `doRecalc` uses, minus the Excel branch
(prefilled Excel is a recalc-only input — see `BundleFileType.isStmRecalculationSuitable()`):

1. `STM_MELDUNG_CSV_FILE`
2. `CONFIRM_CSV_FILE`
3. `DELETE_CSV_FILE`
4. otherwise throw

Each branch calls the existing `ermittlungDomainService.processLieferung(...)` with the arguments
already in place at `:96-106` (`ValidationSetting.DEFAULT`,
`SteuerlicheErmittlungRecalcOptions.DEFAULT`, `forcedBmfVersion = null`) — only the resource
changes. Extract the call into a private helper so the three branches don't repeat nine arguments.

Make the terminal message diagnosable — it is what the user reads on a `FAILED` job. Name the
bundle and what it actually held, built from `inputBundle.getBundleName()` and
`inputBundle.getAllFiles().keySet()`:

```
No Melde-, Confirm- or Delete-CSV-File found in input bundle <bundleName> (contains: RETURN_CSV_FILE)
```

## Change 2 — output filename prefix for a confirm/delete-only bundle

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/bundle/SteuerMeldungBundles.java`,
`getBaseFileNamePrefix` (`:825-851`)

With no `STM_MELDUNG_CSV_FILE` in the bundle the method falls through to its `else` branch: it
derives the prefix from the enclosing zip / bundle path and logs
`"Cannot determine the base file prefix for bundle …"`. For a web upload that happens to give the
right answer (the zip is named after the CSV), but a zip delivered under any other name would have
its return file named after the *zip*.

Add `CONFIRM_CSV_FILE` and `DELETE_CSV_FILE` branches **after** the existing
`STM_MELDUNG_CSV_FILE` / `RETURN_CSV_FILE` / `PREFILLED_EXCEL_FILE` branches, so no bundle that
resolves today changes its answer. Each returns `FileNames.getBaseName(...)` of that file — i.e.
the prefix keeps the `_confirm` / `_delete`.

Keeping the suffix is legacy behaviour, not an oversight: `m_st_meldung.cpp:193-194` builds the
return file from `strPFilename` truncated at the **last** `.` (`cAString::TruncateAtChar(char, 0)`,
`c_strings.cpp:1367-1393` — `nFromLeft = 0` scans from the right) plus `_return.csv`. Legacy
therefore answers `X_confirm.csv` with `X_confirm_return.csv`. `BundleCalculationResults` /
`CalculationOutputs` then produce no name collision with the copied-over input file.

Also fix the fallback itself, which Change 3 makes reachable. `SteuerMeldungBundle.ofSingleFile`
(`SteuerMeldungBundle.java:71-73`) passes `""` — not `null` — for `topContainingZipFile`, so a
plain-file bundle takes the `getTopContainingZipFile() != null` branch and
`getBaseName(getLastPathElement(""))` yields an **empty** prefix, naming outputs `_return.csv`.
Have `ofSingleFile` pass `null` (there is no containing zip), which routes the fallback to the
`getBundleName()` branch — the file's own name. Unreachable today because every plain-file bundle
in use carries a Melde-CSV, reachable as soon as a plain confirm CSV is stored unzipped.

## Change 3 — store the input as delivered, don't zip it

`ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/calc/StmCalcJobSubmissionService.java:124-158`

The zip wrapping buys nothing on the input side and costs three things: a `.csv` upload is stored
as a `.zip`, a `.zip` upload is stored as a zip-inside-a-zip under the *identical* name
(`getBaseName("x.zip") + ".zip"`; it still resolves through the nested-zip recursion at
`SteuerMeldungBundles.java:365-377`, but `getBundleBasePath()` then points at the inner zip), and
the stored artifact is no longer what the Lieferant sent.

Store the resource unchanged, normalising only the content type:

```java
URI inputBundleFileUri = filestore.store(
        stmCsvResource,
        FileTypes.isZipFile(stmCsvResource) ? MediaTypes.ZIP_MEDIA_TYPE : MediaTypes.TEXT_CSV_MEDIA_TYPE
);
```

using the existing `Filestore.store(Resource, MimeType)` overload
(`support-libs/core-support/.../filestore/Filestore.java:49-53`), which keeps
`stmCsvResource.getFilename()` as the stored filename. `writeResourceAsZip` and its
`ZipOutputStream` imports then have no callers left and go away.

Nothing downstream has to change:

- `StmCalcJobExecutionService.java:145` already calls `SteuerMeldungBundles.bundleOf(inputResource)`,
  and `createSteuerMeldungBundles` (`SteuerMeldungBundles.java:84-98`) dispatches on
  `FileTypes.isZipFile`, taking `createSingleBundleFromSimpleFile` (`:164-172`) for a plain CSV.
- **Existing rows keep working** — the dispatch reads the *stored* resource, so jobs whose input is
  an old wrapper zip still resolve. No migration, and `StmCalcJob.inputBundleFile` keeps its name.
- Normalising the media type matters because the stored content type is what the executor reads
  back: browsers send `.csv` as anything from `text/plain` to `application/vnd.ms-excel`, and
  `.zip` as `application/zip` or `application/x-zip-compressed`. The CSV *charset* is not taken
  from here — the CSV layer reads `IfasCharsets.IFAS_CSV_CHARSET` — so a bare `text/csv` is right.

Two side effects, both improvements: the `/{id}/input-file` download hands back the exact uploaded
file, since `StmCalcDetailPageController:102-106` copies the stored resource verbatim; and the FMOC
journal description stops reading `Meldefile: ….zip`
(`StmCalcJobExecutionService:118` passes `calcInfo.resource().getFilename()` into `:168-169`).

Note this changes nothing about the reported failure: `determineFileTypeFromFilePath` types a plain
file exactly as it types a zip entry, so `x_confirm.csv` is still `CONFIRM_CSV_FILE`. Change 1
remains the fix.

## Change 4 — reject dead-end CSVs in the form instead of failing as a job

A `*_return.csv` or `preis_*.csv` upload is accepted at the boundary
(`StmCalcFormPageController.isValidCalcFile:220-225` only checks the extension) and fails deep in
the worker as a `FAILED` job.

Add the calc-path counterpart of the existing recalc predicate, next to it in
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/bundle/BundleFileType.java:152-157`:

```java
/** @return true if this file type can be processed as a Steuermeldung-Lieferung. */
public boolean isStmCalculationSuitable() {
    return this == STM_MELDUNG_CSV_FILE
            || this == CONFIRM_CSV_FILE
            || this == DELETE_CSV_FILE
            || this == UNSPECIFIED_CSV_FILE;
}
```

`UNSPECIFIED_CSV_FILE` must pass: the filename-only pass cannot tell a Melde-CSV from a Preis-CSV,
that is decided by content when the bundle is read. So this catches exactly the dead ends the
*filename* already settles — `_return.csv`, `_estb_erweitert.csv`, `preis_*.csv`, `*#recalc.csv`.
Content-level dead ends still fail as a job, now with Change 1's message. The overlap with
`doCalc`'s chain is deliberate: one is a boundary filter that must tolerate the not-yet-sniffed
type, the other an ordered resolution over a read bundle.

In `ifas-web/ifas-web-ui/src/main/java/at/oekb/ifas/web/stm/StmCalcFormPageController.java`, split
the loop at `:112-122` so the two rejections carry different messages — keep the existing
"Ungültiger Dateityp für '%s'. Es sind nur CSV-Dateien (.csv) oder ZIP-Dateien (.zip) erlaubt!" for
a non-CSV/non-ZIP, and add for a classified dead end:

```
'%s' kann nicht als Steuermeldung-Lieferung verarbeitet werden.
Erlaubt sind Melde-CSV-Files sowie *_confirm.csv und *_delete.csv.
```

A `.zip` upload skips the type check — its contents cannot be classified from the name. The
controller already reaches `at.oekb.ifas.domain.stm.*` types transitively via `ifas-main-service`
(cf. `StmRecalcFormPageController`), so no POM change.

## Change 5 — tests

There is currently **no** test for `calculateBundle` at all, and nothing pins the error message.

### New `CalculationDomainServiceTest`

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/calc/CalculationDomainServiceTest.java`

Model it on `StmIdVergabeTest`
(`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/ermittlung/StmIdVergabeTest.java`)
— the worked example for delivery chains, whose harness transfers almost unchanged:

- `@RegisterExtension static Extension extension = TEST_WITH_H2_ONLY`; a chain must be one
  `@TestTemplate`, because `MultiDatabaseExtension` truncates after *each* test method.
- `BasedataCreator.createBasedata()` + `DataImporter.importTestData(fondsstammdaten.yaml, true)`;
  reuse `StmIdVergabeTest`'s `stmidvergabe/` resources rather than adding fixtures.
- Derive each delivery CSV from the `jahresmeldung.csv` template exactly as
  `StmIdVergabeTest.lieferfile(...)` does (CONFIRMED/DELETE keep only START, STATUS and END), but
  name the resource `<base>_confirm.csv` / `<base>_delete.csv` so it takes the new branch, and wrap
  it with `SteuerMeldungBundles.bundleOf(Resource)` — **singular**; `bundlesOf(...).getFirst()`
  lets the temp-dir `Cleaner` delete the unzipped files mid-run.
- Deliver through `calculationDomainService.calculateBundle(bundle, calculationSetting, stmIdProvider)`
  inside `tx.doTransactional`, with a counting `StmIdProvider` lambda for deterministic STM-IDs.

| given | when | then |
|---|---|---|
| NEW Melde-CSV, then `*_confirm.csv` for the returned STM-ID | `calculateBundle` | STATUS record of the Antwortfile is `FINAL;<id>`, row is `FINAL` with `guelt_bis` null |
| NEW Melde-CSV, then `*_delete.csv` | `calculateBundle` | STATUS record `DELETED;<id>`, row `DELETED` with `guelt_bis` set |
| bundle holding only a `*_return.csv` | `calculateBundle` | `IllegalStateException` whose message names the bundle and the type found |

Run the confirm case through **both** input shapes — `bundleOf` on a plain `*_confirm.csv` resource
(the Change 3 shape) and on a one-entry zip holding it (the legacy stored shape) — since that
dispatch is what Change 3 moves.

### Extend `SteuerMeldungBundlesTest`

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/bundle/SteuerMeldungBundlesTest.java`
sits in the same package, so it can call the package-private `getBaseFileNamePrefix` directly:

- confirm-only bundle → prefix `<base>_confirm`, for both a plain-file and a zipped bundle
  (Change 2, and the `ofSingleFile` fallback)
- `determineFileTypeFromFilePath` + `isStmCalculationSuitable` for the Change 4 boundary set:
  accept `x.csv`, `x_confirm.csv`, `x_delete.csv`; reject `x_return.csv`, `preis_x.csv`,
  `x#recalc.csv`

## Verification

```bash
mvn clean install -Pno-proxy -Pdev-build -pl ifas-domain/ifas-domain-stm,ifas-services/ifas-main-service,ifas-web/ifas-web-ui -am
mvn test -Pno-proxy -Dtest=CalculationDomainServiceTest -pl ifas-testing/ifas-integration-tests
mvn test -Pno-proxy -Dtest='SteuerMeldungBundlesTest,StmIdVergabeTest,RecalculationDomainServiceTest' \
    -pl ifas-testing/ifas-integration-tests
```

`SteuerMeldungBundlesTest` and the recalc tests are the regression guard for Change 2 — the
grossfile bundles carry `_confirm.csv` / `_delete.csv` as legacy *output* files for diffing, so
their prefix must keep coming from the Melde-CSV branch.

End to end, against the real app:

1. `LocalH2OnlyIfasApplication` (a headless `java -cp` launch needs
   `-Dspring.devtools.restart.enabled=false`), http://localhost:8080/ifas-uat.
2. On `/ui/stm-calc` upload a Melde-CSV; note the STM-ID in the result bundle's `_return.csv`.
3. Upload that result bundle's generated `<base>_confirm.csv`: the job must reach `COMPLETED`, the
   Steuermeldung must show `FINAL`, and the result bundle must contain `<base>_confirm_return.csv`.
4. On the detail page of both jobs, **Input-Datei** must download the exact `.csv` that was
   uploaded, not a zip (Change 3).
5. Upload a `.zip` and confirm the stored input is that zip, not a zip-in-a-zip (Change 3).
6. Upload a `_return.csv` and confirm the form rejects it inline, with no job created (Change 4).
7. Open a calculation submitted *before* the change and confirm it still opens and its input file
   still downloads — old wrapper zips must keep resolving.
