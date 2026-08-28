# Strip the quick-recalc scenario down to ISIN LU0566480462

## Context

`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-recalc/`
holds the legacy Lieferung `20260824_111113_pwc_20260824_10619_confirm.zip`, which covers **60
funds** — too large to reproduce locally, and the DB export needed to seed H2 would scale with it.

The scenario is worth keeping: for all 60 meldungen legacy reports
`Aktueller Status <FINAL>, CONFIRMED nicht moeglich.` while the new system reported
`Die Meldung mit der Melde-ID <…> ist nicht vorhanden.` (cf.
`[[project_gueltbis-active-meldung-discriminator]]`). That earlier run was on TEST, where the data
was missing, so the deviation still has to be reproduced locally against a real export.

Goal: reduce the Lieferung to the single fund **LU0566480462** / Melde-ID **697058** and repackage it,
together with the one-fund DB export, as **one zip** that `QuickRecalculationTest` loads directly.

The export `fonds-export_20260826_152829.zip` (13.8 MB yaml, `ISINs = [LU0566480462]`) contains
meldung 697058 with `status: "FIN"`, `versionsNr: 6` and no `gueltBis` — active and FINAL, the state
legacy rejected the CONFIRMED against.

## Why a single zip

`QuickRecalculationTest` (`.../src/test/java/at/oekb/ifas/domain/stm/recalc/QuickRecalculationTest.java:93-101`)
loads `quick-recalc/` via `Resources.findResourcesInClasspathFolder`
(`support-libs/core-support/.../core/io/Resources.java:118`), which globs `classpath:<folder>/*` —
**one level only, and directories come back as resources**. Exactly one resource takes the
`bundleOf(Resource)` branch (zip unzipped, flat entries → one bundle); anything else falls into
`bundleOf(Collection)`.

The folder currently holds four entries (three zips, one subdirectory, `.gitkeep`), so the test would
take the collection branch and `SteuerMeldungBundles.determineBundleFilename` throws
`must have at least one Melde-CSV, a prefilled Excel file or a Return-CSV file`. Same trap as
`[[project_quick-recalc-stale-test-classes]]`, one directory up.

A single zip also gets the Stichtag right for free: `resolveStichtag`
(`QuickRecalculationTest.java:189-206`) derives it from the filename only when there is exactly one
zip matching `(\d{8})\D.*`. Keeping the archive's own name yields **Stichtag 2026-08-24**, matching
the Lieferung. **No source change needed**; `STICHTAG_OVERRIDE` stays `null`.

Two constraints on the zip content:

- **Entries must stay flat.** A `/` in an entry name switches the reader to
  `MULTIPLE_BUNDLES_IN_SUB_DIRECTORIES` (`SteuerMeldungBundles.java:336-347`).
- **No nested zip.** A `.zip` entry switches to `MULTIPLE_BUNDLES_IN_NESTED_ZIP_FILES`, and mixing it
  with plain files throws `contains a mixture of zip files and plain files or directories`. So the
  fonds-export goes in as the **extracted yaml**, not as `fonds-export_….zip`.

## What is in the bundle

`SteuerMeldungBundles.determineFileTypeFromFilePath`
(`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/bundle/SteuerMeldungBundles.java:585`)
classifies purely by filename. The Lieferung archive holds exactly the five input files:

| File | Type | Role |
|---|---|---|
| `pwc_20260824_10619_confirm.csv` | `CONFIRM_CSV_FILE` | the Melde-CSV that drives the recalc |
| `pwc_20260824_10619_confirm_return.csv` | `RETURN_CSV_FILE` | legacy return: legacy `stmId` + `StmStatus` |
| `error.log` | `ERROR_LOG_FILE` | parsed by `LegacyLogParsers.parseErrorLog`, drives `error#diff.txt` |
| `info.log` | `INFO_LOG_FILE` | same for `info#diff.txt` |
| `statistics.log` | `STATISTICS_LOG_FILE` | never parsed — copied through only |

`.yaml` maps to `TESTDATA_YAML_FILE`, which is `inputFile = true` (`BundleFileType.java:42`), so it
survives the bundle read and is imported by `RecalculationDomainService.importTestdata`. No
`.yaml.txt` rename needed.

The leftover `recalc-protocol_only_error_details{,.zip}` from the TEST run is pure output —
`*#recalc.*`, `*#diff.txt`, 4× `recalc-protocol_*.txt` — regenerated into `target/quick-recalc` on
every run. It gets archived, not carried along.

## Steps

### 0. Rename this plan file

`mv` to `~/dev/projects/ifas13-agents/mathias/plans/2026-08-26-quick-recalc-strip-to-lu0566480462.md`
(per `[[feedback_plan-file-naming]]`).

### 1. Archive the untouched originals

```
mkdir -p .../recalc/issues/_incoming/
mv .../quick-recalc/20260824_111113_pwc_20260824_10619_confirm.zip .../issues/_incoming/
mv .../quick-recalc/fonds-export_20260826_152829.zip               .../issues/_incoming/
mv .../quick-recalc/recalc-protocol_only_error_details.zip         .../issues/_incoming/
rm -rf .../quick-recalc/recalc-protocol_only_error_details/
```

`issues/_incoming/` is already gitignored (`.gitignore:815`), so the full 60-fund Lieferung, the raw
export and the TEST run's protocol stay recoverable without polluting `git status` or the classpath
folder. The unzipped subdirectory is redundant with the archived protocol zip (verified
byte-identical) and is dropped.

### 2. Build the stripped bundle

One throwaway Python script in the scratchpad — not `sed`/`grep`, because the two CSVs are **CRLF**
while the logs are **LF** and the rewrite must be byte-exact. Read the archived Lieferung zip and the
archived export zip, filter on `START;<isin>;` … `END;<isin>;` blocks so the script stays re-runnable
for another ISIN, and write straight into the new
`quick-recalc/20260824_111113_pwc_20260824_10619_confirm.zip` (flat entries, `ZIP_DEFLATED`).

All five input files are pure ASCII, so no encoding trap — cf.
`[[feedback_only-change-what-was-asked]]`.

**`pwc_20260824_10619_confirm.csv`** — the one 3-line block, CRLF:

```
START;LU0566480462;InvF;A;EUR;01.10.2025;30.09.2026;NEIN;01.07.2026;31.07.2026;57529.3930;;LU;NEIN;JA;JA;;NEIN;JA;57529.3930;
STATUS;CONFIRMED;697058
END;LU0566480462;2026.08.24 10:51:09
```

**`pwc_20260824_10619_confirm_return.csv`** — same block, CRLF, status `CONFIRM_DECLINED`,
timestamp `2026.08.24 11:11:09`.

**`error.log`** — 6 header lines + the single `Zeile-Nr: 1` block, LF, no trailing blank line
(matches how the original's last block ends):

```
--------------------------------------------------------------------------------
     Meldefile           : pwc_20260824_10619_confirm.csv
     Verarbeitungsbeginn : 2026.08.24 11:11:08
     Lieferant           : af_pwc
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
Zeile-Nr: 1 | START;LU0566480462;InvF;A;EUR;01.10.2025;30.09.2026;NEIN;01.07.2026;31.07.2026;57529.3930;;LU;NEIN;JA;JA;;NEIN;JA;57529.3930;
--> Steuerdaten-Meldung wird NICHT VERARBEITET:
  ERROR! Aktueller Status <FINAL>, CONFIRMED nicht moeglich.
```

LU0566480462 is the *first* block in the original, so `Zeile-Nr: 1` needs no renumbering — assert
that in the script rather than assuming it, so a future ISIN swap fails loudly instead of writing a
wrong line number.

**`info.log`** — unchanged (header only, no per-ISIN content).

**`statistics.log`** — counters corrected, column alignment preserved:

```
     Zeilen              :     3
     Gemeldete ISINs     :     1
     Fehler              :     1
     CONFIRMED           :     0 von 1 verarbeitet
```

**`fonds-export_20260826_152829.yaml`** — the 13.8 MB export, extracted from its zip and added under
its own name.

Afterwards `quick-recalc/` holds exactly `.gitkeep` + the one zip. No Java changes anywhere;
`QuickRecalculationTest.java` is left untouched.

## Verification

1. `git status` must stay clean — everything under `quick-recalc/` and `issues/_incoming/` is
   gitignored, and no source file is edited.
2. Byte-check the new zip: 6 flat entries, no `/` in any name, no nested `.zip`; CRLF on both CSVs,
   LF on the three logs; 3 / 3 / 10 / 5 / 11 lines respectively; ASCII only in the five inputs.
3. Trace the load on paper: flat entries → `SINGLE_BUNDLE`, `determineBundleFilename` →
   `pwc_20260824_10619_confirm` via the `_return.csv` branch, filename prefix `20260824` → Stichtag
   2026-08-24.
4. Run it: `QuickRecalculationTest#givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
   is `@Disabled`, so start it from IntelliJ (H2 only, `TEST_WITH_H2_ONLY`). Expect
   `Using Stichtag 2026-08-24 from filename prefix` in the log and output in
   `ifas-testing/ifas-integration-tests/target/quick-recalc`.
5. Inspect `target/quick-recalc/error#diff.txt`: exactly one pair instead of the 120 log deviations
   of the 60-fund TEST run — legacy `Aktueller Status <FINAL>, CONFIRMED nicht moeglich.` against
   whatever the new system produces for Melde-ID 697058 now that the meldung is actually seeded.
   That single pair is the deviation to debug next.

## Note on the export's key date

The export was taken with **key date 2026-08-26** while the Lieferung's Stichtag is **2026-08-24**.
Meldung 697058 carries `gueltAb: 2026-08-24T11:01:12.05` and no `gueltBis`, so it is visible at both
dates and the two-day gap does not hide it. Worth remembering only if a later recalc turns up a
version that did not yet exist on the 24th.
