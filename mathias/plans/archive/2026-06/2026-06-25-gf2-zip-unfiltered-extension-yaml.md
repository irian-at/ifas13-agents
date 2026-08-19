# Root cause: `gf2-d20260731.zip` contains the unfiltered extension YAML in addition to the merged primary YAML

## Context

User reported `[+] NUR IM NEUSYSTEM` deviation at gf2 Zeile 244 ("ACHTUNG! Ausschuettungsmeldung bereits vorhanden.") for `LU0111465547`. Debugging showed `findExistingMeldungStmIdByGjEndeAndJahresMeldung` returning **649584** when processing LU0111465547 — even though we explicitly dropped 649584 from the merged YAML.

## Root cause

`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf2-d20260731.zip` contains both:

- `gf2-d20260731/gf1-d20260724-export-AFTER.yaml.txt` — the merged YAML (649584 dropped)
- `gf2-d20260731/gf2-yaml-extension.yaml.txt` — the unfiltered extension (still has 649584)

`SteuerMeldungBundles#bundleTypeOf` (`SteuerMeldungBundles.java:648`) classifies anything ending in `.yaml.txt` as `TESTDATA_YAML_FILE`. The bundle then imports every `TESTDATA_YAML_FILE` entry. Because the extension YAML still contains `649584` (numWfsKu=43659, gjEnde=2025-12-31, jahresdatenmeldung=false, status=OPE), it gets imported into the DB, satisfies the `errAusschmVorh` predicate exactly, and IFAS13 fires `ERR_AUSSCHM_VORH` for LU0111465547.

Note: the validator method `findExistingMeldungStmIdByGjEndeAndJahresMeldung` and the lookup chain `getExistingMeldungenByIsin` → `findAllStmIdsByIsin` are all correct. The bug is purely in the test fixture: two YAMLs in one zip, the second one undoes the filter applied to the first.

## Fix

Rebuild `gf2-d20260731.zip` from the directory `gf2-d20260731/`, excluding `gf2-yaml-extension.yaml.txt`. The extension YAML's data is already merged into `gf1-d20260724-export-AFTER.yaml.txt`, so keeping it in the zip is both redundant and harmful.

```bash
cd ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/
# Backup the current zip
cp gf2-d20260731.zip /tmp/gf2-d20260731.zip.bak
# Rebuild without the extension YAML
python3 - << 'PY'
import zipfile, os, shutil
src_dir = "gf2-d20260731"
out_zip = "gf2-d20260731.zip"
with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for f in files:
            if f == "gf2-yaml-extension.yaml.txt":
                continue  # already merged into the primary YAML
            full = os.path.join(root, f)
            arc = os.path.relpath(full, os.path.dirname(src_dir))
            zf.write(full, arc)
PY
```

## Verification

1. Re-run `GrossfileRecalculationTest#givenGrossfile_whenRecalculate_thenMatchValidationDeltaBaseline` for gf2.
2. Inspect `target/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt` (or the corresponding info/oekbinfo file — `ERR_AUSSCHM_VORH` has severity INFO + OEKBINFO, not ERROR). The Zeile 244 / LU0111465547 deviation should be gone.
3. If you want a debug-level sanity check first: set a conditional breakpoint at `SteuerMeldungStatusValidationService.java:146` gated on `steuerMeldung.getIsin().equals("LU0111465547")` and verify that `findExistingMeldungStmIdByGjEndeAndJahresMeldung` now returns `null` (since the DB no longer has 649584).
4. Recompute baselines if the deviation count drops — `gf2-d20260731` baseline in `GrossfileRecalculationTest.java:152-155` is `new SummaryExpectation(...)` with hard-coded counts that may need adjustment.

## Why this happened — process note for the merge skill

The `merge-yaml-export-extension` skill currently documents the YAML merge but doesn't mention that the test fixture is a zip containing the YAML, and that re-bundling the zip is part of the workflow. Recommend adding a final step to the skill's "Workflow" section: "After merging, rebuild any test zip that bundles the YAML so the unfiltered extension is not also packed alongside the merged primary." I'll add this as a follow-up.

## Critical files

- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf2-d20260731.zip` — the broken fixture (contains both YAMLs)
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf2-d20260731/` — the source directory with both YAMLs
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/bundle/SteuerMeldungBundles.java:648` — `.yaml.txt` → `TESTDATA_YAML_FILE` classifier
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java:146` — conditional breakpoint anchor for verification

## Recommended action sequence

1. **Rebuild the zip** (the bash/python snippet above), keeping a backup at `/tmp/gf2-d20260731.zip.bak`.
2. **Re-run the recalc test** locally to confirm the Zeile-244 deviation is gone.
3. **Recompute the gf2 baseline** in `GrossfileRecalculationTest.java:152-155` from the regenerated `error#diff-deviations.txt` / `info#diff-deviations.txt` / `oekbinfo#diff-deviations.txt`.
4. **Update `merge-yaml-export-extension` skill** to mention the zip-rebuild step.
