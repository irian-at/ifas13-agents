# Clear stale test resource breaking QuickRecalculationTest

## Context

`QuickRecalculationTest.givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
fails with:

```
java.lang.IllegalArgumentException: SteuerMeldungBundle must have at least one Melde-CSV,
a prefilled Excel file or a Return-CSV file
  at SteuerMeldungBundles.determineBundleFilename(SteuerMeldungBundles.java:126)
  at SteuerMeldungBundles.bundleOf(SteuerMeldungBundles.java:71)
```

even though the input zip does contain a Melde-CSV (`BestFonds31122025-mh.csv`, verified).

Cause: `Resources.findResourcesInClasspathFolder` (`support-libs/core-support/.../io/Resources.java:118`)
resolves `classpath:` — i.e. `target/test-classes`, not `src/test/resources`. Maven/IntelliJ
resource copying is additive and never removes resources deleted from `src`, so the classpath
folder still holds a zip from a previous run:

| Location | Contents |
|---|---|
| `src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-recalc/` | `20260727_070109_BestFonds31122025-mh#recalc.zip`, `.gitkeep` |
| `target/test-classes/at/oekb/ifas/domain/recalc/issues/quick-recalc/` | `20260708_103156_202512_DE000A3DD2R4_JM_1970471#recalc.zip` (stale), `20260727_070109_BestFonds31122025-mh#recalc.zip`, `.gitkeep` |

With `.gitkeep` filtered out, `resources.size() == 2`, so
`QuickRecalculationTest.java:82-86` takes the multi-file branch
`SteuerMeldungBundles.bundleOf(Collection)` — which does **not** unzip. It classifies each
resource by its top-level filename; a `.zip` matches none of unspecified-CSV/TXT,
prefilled-Excel, or `_return.csv`, so `determineBundleFilename` throws at line 126.

Intended outcome: the classpath folder holds only the single current zip, the test takes the
`bundleOf(Resource)` branch, and the zip is unpacked as designed. No source changes.

## Change

Delete the stale zip from the module's build output:

```
ifas-testing/ifas-integration-tests/target/test-classes/at/oekb/ifas/domain/recalc/issues/quick-recalc/20260708_103156_202512_DE000A3DD2R4_JM_1970471#recalc.zip
```

Equivalent alternatives (either is fine, both are slower):
- `mvn clean test-compile -pl ifas-testing/ifas-integration-tests -Pno-proxy`
- IntelliJ: **Build > Rebuild Project**

No files under `src/` are touched. The `STICHTAG` edit already in the working tree
(`2026-08-04` → `2026-07-27`) is unrelated and stays as is.

## Verification

1. Confirm the classpath folder now lists exactly one zip plus `.gitkeep`:
   `ls -la ifas-testing/ifas-integration-tests/target/test-classes/at/oekb/ifas/domain/recalc/issues/quick-recalc/`
2. Re-run the test from the IDE. Note it carries `@Disabled` — run it explicitly by method.
   It must get past `SteuerMeldungBundles.bundleOf` and reach
   `RecalculationTests.writeResultFiles`.
3. Confirm output lands in `ifas-testing/ifas-integration-tests/target/quick-recalc`
   (the test logs the absolute path on completion).

## Note for future runs

Whenever the zip in `src/test/resources/.../quick-recalc/` is swapped, the previous one has to
be removed from `target/test-classes` as well — otherwise this exact failure recurs, with an
error message that points at the CSV contents rather than at the duplicate resource.
