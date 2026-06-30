---
name: merge-yaml-export-extension
description: Merge a follow-up YAML database export ("extension") back into a primary `FondsYamlExportTool` export when the primary export missed some ISINs. Handles the trickiest part: filtering out STEUER_MELDUNG entries that were created AFTER the snapshot the primary export represents (e.g. created by a later grossfile run), plus their dependent STEUER_FIELDS_DATA / STEUER_BEH_DATA / STEUER_MELDUNG_FILE rows. Use this whenever the user says they "missed ISINs in a YAML export", "exported the DB again for missing ISINs", or asks to merge a `*-extension.yaml.txt` into a `*-export-AFTER.yaml.txt` / similar primary YAML used as test setup data. The companion skill [[find-missing-isins-for-yaml-extension]] produces the ISIN list that drives the re-export feeding into this merge.
---

# Merge YAML Export Extension

`FondsYamlExportTool` produces a YAML file representing the database state for a list of ISINs. If you discover after the fact that some ISINs were missed, you do a second export for just the missing ISINs and merge the result into the original file. This skill captures how.

The merge itself is "append entities from the extension to the original". The hard part is **time-filtering**: the extension is a *current* DB export, so for ISINs the user is interested in it may include STEUER_MELDUNG rows that didn't exist yet at the point in time the original export represents (typically because a later grossfile run created them). Those rows have to be dropped, together with all FIELDS_DATA / BEH_DATA / STEUER_MELDUNG_FILE rows that reference them.

## When to use this skill

- User says they missed ISINs in a YAML export and re-exported the DB for them ("can you merge these in").
- User asks how to merge a `*-extension.yaml.txt` into a `*-export-AFTER.yaml.txt`.
- User asks why a YAML test-setup file is inconsistent after merging a fresh DB extension.

## When NOT to use this skill

- The user is asking how to *produce* a YAML export. That's `FondsYamlExportTool` (see `ifas-dev-tools`).
- The user wants to *change* meldung values in an existing YAML. That's editing, not merging.
- The two YAML files come from different `FondsYamlExportTool` versions with incompatible schemas. Inspect first.

## YAML structure (cheat-sheet)

Produced by `FondsExporter#getDtosForInv()` (`ifas-database/ifas-data-import-export/src/main/java/at/oekb/ifas/importexport/FondsExporter.java`). One `--- !<Data>` document with a top-level `name:` and an `entities:` list. Each entity is `- !<TYPE>` followed by indented fields.

**Per-ISIN export loops** — for a multi-ISIN export, the tool loops once per fund and emits the *full* set of reference data each time. So `LIEFERANT`, `KAG`, `HDP`, `WAEHRUNG`, …, `STEUER_MELDUNG`, `STEUER_FIELDS_DATA`, `STEUER_BEH_DATA` all appear once per exported ISIN. Don't be alarmed by duplicates; `FondsImporter` deduplicates by primary key.

**Tags used (30):**
`LIEFERANT, KAG, HDP, WAEHRUNG, HWA, WP_ART_F, WP_ART_G, KURSBLATT, LEI_STATUS, WKN_DESC, BOERSE, QUELLE, WKN_HIST, KEST98, LIEFER_STATUS_GESAMT, ABSICHT, STATUS_FMV, INV, INV_H, GJ_TYP, GESCHAEFTSJAHR, STM_ERTRAGSTYP, STM_KAPITALRUECKZAHLUNG, STM_W_RABATT_ART, STEUER_MELDUNG_STATUS, STEUER_MELDUNG_VERSION, STEUER_FIELD, STEUER_BEH_FIELD, STEUER_MELDUNG_FILE, STEUER_MELDUNG, STEUER_FIELDS_DATA, STEUER_BEH_DATA`.

**Cross-references that matter for merge filtering:**

| Entity | Key | References |
|---|---|---|
| `STEUER_MELDUNG` | `id` | `fileId`, `confirmFileId` → `STEUER_MELDUNG_FILE.fileId`; `numWfsKu` → fund |
| `STEUER_FIELDS_DATA` | (composite) | `stmId` → `STEUER_MELDUNG.id` |
| `STEUER_BEH_DATA` | (composite) | `stmId` → `STEUER_MELDUNG.id` |
| `STEUER_MELDUNG_FILE` | `fileId` | (root) |
| `GESCHAEFTSJAHR` | (composite) | `stmId` → `STEUER_MELDUNG.id` (may be empty if no meldung yet) |
| `WKN_HIST` | `numWfsHist` | `numWkn` is the ISIN (when `quelle: "ISIN"`); `numWfsKu` is the security id used by `STEUER_MELDUNG` |

**Fund identifier gotcha:** `INV.wfsWkn` and `STEUER_MELDUNG.numWfsKu` are **different** values for the same fund. To map ISIN→meldungen go via `WKN_HIST` (`numWkn` = ISIN, `numWfsKu` = security id used by STEUER_MELDUNG).

## Time-filter rule

The primary YAML represents a point in time T. The extension is a current snapshot. You want to drop any STEUER_MELDUNG with `eintragezeit > T`. Source of truth for T depends on the file name:

- `gfN-d<yyyymmdd>-export-AFTER.yaml.txt` → T is the moment grossfile N finished. Read it from `gfN-d<yyyymmdd>_return.csv` `END;<ISIN>;<timestamp>` lines.
- Otherwise: look at the `name:` field of the original YAML — it usually has a date prefix like `"Fonds Export from 2026-02-25"`.

For each meldung in the extension, compare `eintragezeit` (and `guelt` if you want to be strict) against T. Also drop any `STEUER_MELDUNG_FILE` that the kept meldungen no longer reference.

In practice you usually don't have to time-compare every meldung — the post-T set is small and tied to a specific grossfile. The fastest path is:
1. Identify the **fileId(s)** of the grossfile(s) that ran after T (look at `STEUER_MELDUNG_FILE.filename` and `startzeit`).
2. Drop every meldung with that `fileId`.

## Workflow

0. **Identify the missing ISINs first.** If you don't yet have the extension YAML, run [[find-missing-isins-for-yaml-extension]] to produce the ISIN list, hand it to the user, have them re-export the DB via `FondsYamlExportTool` into `*-yaml-extension.yaml.txt`, then continue here.
1. **Locate both YAML files** and confirm they're from the same `FondsYamlExportTool` schema (same set of entity tags; same field names).
2. **Identify the cutoff T** — see "Time-filter rule".
3. **Run `merge_yaml.py --analyze EXTENSION`** to list each meldung in the extension with its `id`, `numWfsKu`, `eintragezeit`, `fileId`, and the corresponding `STEUER_MELDUNG_FILE.filename` + `startzeit`. This produces a clear table you can scan to decide which IDs to drop.
4. **Compare against the grossfile return CSV** (`gfN-d<yyyymmdd>_return.csv` inside `gfN-d<yyyymmdd>.zip`) to confirm which meldungen each ISIN expects pre-existing vs which were created by the grossfile run. The status column drives this:
   - `FINAL` / `CONFIRMED` — successful, persisted
   - `OPEN` — successful (newly created, awaiting confirmation)
   - `NEW_DECLINED` / `UPDATE_DECLINED` / `CONFIRM_DECLINED` / `ERROR` — rejected, **not persisted by this run** (but the duplicate it conflicted with *is* in the DB)
5. **Dry-run the merge** with `--dry-run` and the chosen exclusion IDs. Verify counts match expectation.
6. **Back up the original** (`cp <orig> /tmp/<orig>.bak`) — these YAMLs are 15–20 MB so version control isn't always practical and the script overwrites in place.
7. **Run the merge** without `--dry-run`. Verify by re-running the analyzer on the merged file or grepping for the excluded IDs.
8. **Rebuild the test zip — CRITICAL.** Most consumers don't read the YAML from the filesystem directly; they read it from a zip fixture (e.g. `gfN-d<yyyymmdd>.zip` in `ifas-integration-tests/.../grossfiles/`). The bundle loader (`SteuerMeldungBundles#bundleTypeOf`, classifies any `*.yaml.txt` as `TESTDATA_YAML_FILE`) imports **every** matching entry, so a stale `*-extension.yaml.txt` left in the zip will *undo* your filter and reintroduce the dropped meldungen. After merging, rebuild the zip from the source directory and **exclude the extension YAML** (its data is already in the primary YAML). See "Rebuilding the test zip" below.
9. **Inform the user about referenced-but-absent meldungs** — e.g. if the return CSV shows `UPDATE_DECLINED <stmId>` but `<stmId>` isn't in the extension (got deleted between snapshot and re-export), the merged file is incomplete for that scenario and the user has to re-create it manually.

## Rebuilding the test zip

The bundle loader treats `*.yaml.txt` as testdata uniformly — there's no "primary vs secondary" distinction. So if both files are in the zip, both get imported and the merged file's filter is silently undone (this is exactly how a missed step in our June-2026 session reintroduced `649584` and caused a spurious `ERR_AUSSCHM_VORH` for `LU0111465547`).

```bash
cd ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/
cp gfN-d<yyyymmdd>.zip /tmp/gfN-d<yyyymmdd>.zip.bak     # backup first
python3 - << 'PY'
import zipfile, os
src_dir = "gfN-d<yyyymmdd>"        # the unzipped fixture directory
out_zip = "gfN-d<yyyymmdd>.zip"
EXCLUDE = {"gf2-yaml-extension.yaml.txt"}   # also exclude any other *-extension.yaml.txt you produced
with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for f in files:
            if f in EXCLUDE:
                continue
            full = os.path.join(root, f)
            arc = os.path.relpath(full, os.path.dirname(src_dir))
            zf.write(full, arc)
PY
```

Sanity check: `python3 -c "import zipfile; print('\n'.join(zipfile.ZipFile('gfN-d<yyyymmdd>.zip').namelist()))"` — confirm only the merged `*-export-AFTER.yaml.txt` (and the CSVs / logs) are present, and the `*-extension.yaml.txt` is gone.

## The script

`merge_yaml.py` (in this skill folder) handles parse → filter → append. It is line-block-based (no full YAML parse — files are 15–20 MB and ordered/duplicated in ways `yaml.safe_load` would lose). Modes:

- `--analyze EXT.yaml.txt` — prints the meldungen table and the file-id table; no writes.
- `--merge --original ORIG.yaml.txt --extension EXT.yaml.txt --exclude-stm-ids 649583,649584 --exclude-file-ids 348758 --new-isins LU...,LU... [--dry-run]` — does the merge. With `--dry-run` it prints counts and writes nothing. Without it, it **overwrites** the original.
- `--prune --original PRIMARY.yaml.txt --exclude-stm-ids 649522,649535,... [--no-cascade] [--dry-run]` — drops the listed STEUER_MELDUNG ids (and their FIELDS_DATA/BEH_DATA) from a primary YAML **in place**. By default it cascades: any successor meldung whose `vorherigeStmId` or `vorherigeFinalStmId` points to a dropped id is also removed (repeated until stable). Use `--no-cascade` only if you want to handle successors manually; the resulting YAML will fail FK validation on import. STEUER_MELDUNG_FILE rows no longer referenced by any kept meldung are dropped automatically.
- `--extract --source SOURCE.yaml.txt --output OUT.yaml.txt [--include-stm-ids 649492,...] [--include-isins AT0000704168,...] [--dry-run]` — carves a minimal extension YAML out of `SOURCE`. Two selection axes (combine freely):
   - `--include-stm-ids`: keep just those STEUER_MELDUNG rows + FIELDS_DATA/BEH_DATA dependents + STEUER_MELDUNG_FILE rows they reference. Use when sybase-gast lost specific stmIds you need.
   - `--include-isins`: keep ALL fund-specific data for those ISINs — WKN_HIST, WKN_DESC, INV, INV_H, KEST98, LIEFER_STATUS_GESAMT, GESCHAEFTSJAHR, every STEUER_MELDUNG for the funds, plus dependents and referenced file rows. Use when the merge target is missing an ISIN entirely ("ISIN nicht fuer eine Steuerdatenmeldung registriert").
   - Reference data (KAG/LIEFERANT/HDP/ABSICHT/BOERSE/WAEHRUNG/...) is NEVER extracted — the merge target is expected to already have it (importer deduplicates).

The `--new-isins` argument extends the `name:` field's ISIN list (so the merged file's header is honest about its contents). Without it, the name is left untouched.

The script is intentionally permissive about the extension's structure: anything that doesn't match a known excluded type/id is passed through verbatim, including comment headers (`# ====== TYPE ======`) and blank lines. This preserves byte-for-byte fidelity for the kept entities.

### When to use `--prune` vs `--merge`'s `--exclude-stm-ids` vs `--extract`

| Scenario | Use |
|---|---|
| Re-exporting the DB picked up post-T meldungen → filter them while appending | `--merge --exclude-stm-ids ...` |
| The merged primary YAML contains meldungen the **legacy** system doesn't have (Altsystem reports "Melde-ID nicht vorhanden") | `--prune --exclude-stm-ids ...` |
| Cleaning the primary YAML without touching an extension | `--prune` |
| A stmId is gone from sybase-gast but still present in a later grossfile's fixture YAML | `--extract --include-stm-ids` (source = later fixture) → `--merge` |
| An ISIN is missing entirely from the fixture YAML (no WKN_HIST → "ISIN nicht registriert") and a later fixture has it | `--extract --include-isins` (source = later fixture) → `--merge` |

## Recovering stmIds from later fixtures

If sybase-gast no longer holds a stmId you need (a `FondsYamlExportTool` re-export returns `entities: []` for it), check whether a **later** grossfile's fixture YAML still has it. Each `gfN+1` fixture's zip contains `gfN-d<yyyymmdd>-export-AFTER.yaml.txt` — the snapshot taken just after `gfN` ran — and these snapshots are durable, unlike the live DB.

Workflow:

1. Confirm absence in sybase-gast (one re-export attempt, verify `entities: []`).
2. Quickly probe each later fixture:

   ```bash
   python3 -c "
   import zipfile
   for z in ['gf4-d20260807.zip','gf5-d20260810.zip','gf6-d20260813.zip','gf7-d20261216.zip','gf8-d20261217.zip']:
       with zipfile.ZipFile(z) as zf:
           name = next(n for n in zf.namelist() if n.endswith('.yaml.txt'))
           data = zf.read(name).decode('utf-8', errors='replace')
       for tid in ['649492','649539','649548','649550']:
           cnt = sum(1 for l in data.split('\n') if l.strip() == 'id: ' + tid)
           print(f'{z} {name} id={tid} hits={cnt}')
   "
   ```

   *(Do NOT use `unzip -p | grep` on this system — it truncates on SIGPIPE and silently returns 0 hits. Use the Python form.)*

3. Unzip the matching fixture's YAML to `/tmp`:

   ```bash
   python3 -c "import zipfile; zipfile.ZipFile('gfN+1-...zip').extract('gfN+1-.../gfN-...-export-AFTER.yaml.txt', '/tmp/')"
   ```

4. Carve out only the wanted stmIds + dependents with `--extract`:

   ```bash
   python3 ~/dev/projects/ifas13-agents/mathias/skills/merge-yaml-export-extension/merge_yaml.py \
     --extract \
     --source /tmp/gfN+1-.../gfN-...-export-AFTER.yaml.txt \
     --include-stm-ids ID,ID,... \
     --output gfN-missing-stms-extension.yaml.txt
   ```

5. Merge it into the primary YAML with the regular `--merge` flow, then rebuild the test zip.

This was the path used to recover gf3's `649492/649539/649548/649550` from `gf4-d20260807.zip` in June 2026 — see `project_gf3-missing-stmids-recovered-from-gf4.md`.

### Gotcha: a post-T snapshot has the current grossfile's *mutations* baked in

When the source is `gfN+1`'s `gfN-...-export-AFTER.yaml.txt` and you're rebuilding **gfN's setup** (pre-gfN state), that snapshot is *post-gfN* — it includes everything gfN did. Two classes must be undone, not just the obvious one:

1. **Meldungen gfN created** (`OPEN;649NNN` rows in `gfN_return.csv`) — drop via `--merge --exclude-stm-ids`. They carry `eintragezeit` at gfN's wall-clock run time (matches `error.log`'s header timestamp, NOT the logical `d<yyyymmdd>`); grep that to confirm the set.
2. **Predecessors gfN *mutated*** — subtler. An **OPE** meldung that gfN successfully UPDATEd or CONFIRMED gets `gueltBis` set (legacy `BeendeAlteMeldung`) and/or `confirmFileId`+`status: FIN`. In the snapshot it looks ended/confirmed; pre-gfN it was active OPE. The `gueltBis`-aware validator then reports it "nicht vorhanden" (see `project_gf6-update-on-ended-meldung-guelt-bis.md`). **Re-source these from a pre-T fixture** (e.g. `gf1-...-export-AFTER`) via `--extract --include-stm-ids`, after excluding them from the post-T merge.

   A **FIN** predecessor that gfN updated is fine as-is — updating a FIN meldung does NOT set its `gueltBis` (it stays a confirmed historical row). Only OPE predecessors successfully updated/confirmed need pre-T re-sourcing. Detect them: `gueltBis` (or `guelt`/`confirmFileId`) stamped at gfN's run time. See `project_gf7-missing-data-recovered-from-gf8.md`.

## Pruning meldungen the legacy system doesn't expect

Sometimes the merged primary YAML contains meldungen that the legacy reference run *doesn't* have (the gross-file's `error.log` will say `Die Meldung mit der Melde-ID <NNN> ist nicht vorhanden` on the **Altsystem** side of the diff for the corresponding Zeile). These have to be removed from the primary YAML so the new system also reports them as missing → exact match.

Steps:

1. From the `<logtype>#diff-deviations.txt` files, collect every `[-] NUR IM ALTSYSTEM (FEHLER)` line containing `Melde-ID <NNN> ist nicht vorhanden`. Those NNN are the ids to prune.
2. Backup: `cp <primary>.yaml.txt /tmp/<primary>.yaml.txt.before-prune`.
3. Dry-run with cascade on (default):

   ```bash
   python3 ~/dev/projects/ifas13-agents/mathias/skills/merge-yaml-export-extension/merge_yaml.py \
     --prune --dry-run \
     --original gfN-d<yyyymmdd>/<primary>.yaml.txt \
     --exclude-stm-ids NNN1,NNN2,...
   ```

4. Inspect the cascade list — it will name every successor meldung that's transitively dropped because its predecessor was removed. These are typically post-T meldungen the legacy DB never had either.
5. Re-run without `--dry-run`. Then rebuild the zip (see "Rebuilding the test zip").

If you skip the cascade (`--no-cascade`), the import will fail with a `fk_vorherige_steuer_meldung2steuer_meldung` violation pointing at one of the pruned ids — exactly the symptom that motivated adding the cascade in the first place.

## Common gotchas

- **The zip fixture loads every `*.yaml.txt` — don't leave the extension in it.** This was the biggest landmine: even with a perfectly filtered merged YAML, the test still sees the dropped meldungen if the extension YAML is also packed in the zip. The symptom is a validator returning an stmId you *thought* you dropped. See "Rebuilding the test zip" above.
- **`STEUER_MELDUNG_FILE` uses `fileId:` not `id:`** as its primary key. A naive regex on `id:` will skip it.
- **`STEUER_MELDUNG_FILE` is often missing from older exports** entirely — the original file may have zero of them while the extension has dozens. That's fine; appending is non-destructive.
- **A `STEUER_MELDUNG_FILE` row can be referenced by both kept and dropped meldungen** (it's a grossfile that processed multiple ISINs). Only drop the file row if *no* kept meldung still references it. The script does this check.
- **`GESCHAEFTSJAHR.stmId` may be empty** for future fiscal years where no meldung has been submitted yet. Don't drop those rows just because they look "incomplete".
- **`name:` field is multi-line wrapped** with YAML's `\<continuation>` syntax. The script extends it by injecting before the closing `]` of the ISIN list. If you hand-edit, preserve the `  \ ` continuation prefix.
- **The CPP file encoding trap doesn't apply here** — YAML exports are UTF-8. But the grossfile return CSV is **ISO-8859-1**; if you read it in Python use `encoding='latin-1'`.

## Verification

After merging *and* rebuilding the zip, the best signal is to run the test that consumes the fixture (`GrossfileRecalculationTest`, `EstbReportTest`, or `QuickRecalculationTest` in `ifas-integration-tests`). If the import phase succeeds and the test reaches the assertion phase, the file is structurally consistent. If the import fails with a foreign-key-like error referencing one of the excluded IDs, you missed a dependent row — re-run the analyzer and check.

If a validator still references one of your supposedly-dropped stmIds after a rerun, the likely cause is that the extension YAML is still in the zip. Verify with:

```bash
python3 -c "import zipfile; print('\n'.join(zipfile.ZipFile('gfN-d<yyyymmdd>.zip').namelist()))"
```

You should see exactly one `*.yaml.txt` (the merged primary). If you see two, the extension is leaking back in — rebuild the zip.

For a debug-level cross-check: set a conditional breakpoint at `SteuerMeldungStatusValidationService.java:146` gated on the ISIN of interest (e.g. `steuerMeldung.getIsin().equals("LU0111465547")`) and inspect the `existingMeldungen` map. It should contain only meldungen for that ISIN and should not contain any stmIds you dropped.

## Example invocation (real session, June 2026)

Primary file `gf1-d20260724-export-AFTER.yaml.txt` was missing 5 ISINs (LU2276928475, LU0136043394, LU0891777665, LU0012190491, LU0111465547). DB extension was exported on 2026-06-24, but gf2 had already run by then and created two new meldungen.

```bash
# 1. Analyze
python3 ~/dev/projects/ifas13-agents/mathias/skills/merge-yaml-export-extension/merge_yaml.py \
  --analyze gf2-yaml-extension.yaml.txt

# 2. Identify post-T meldungen from the analyzer table (IDs 649583, 649584, fileId 348758)

# 3. Merge
python3 ~/dev/projects/ifas13-agents/mathias/skills/merge-yaml-export-extension/merge_yaml.py \
  --merge \
  --original gf1-d20260724-export-AFTER.yaml.txt \
  --extension gf2-yaml-extension.yaml.txt \
  --exclude-stm-ids 649583,649584 \
  --exclude-file-ids 348758 \
  --new-isins LU2276928475,LU0136043394,LU0891777665,LU0012190491,LU0111465547

# 4. Rebuild the test zip WITHOUT the extension YAML. (We initially missed this step
#    and the gf2 test fired ERR_AUSSCHM_VORH for LU0111465547 because the extension's
#    unfiltered 649584 was still being loaded from inside the zip.)
cp gf2-d20260731.zip /tmp/gf2-d20260731.zip.bak
python3 - << 'PY'
import zipfile, os
with zipfile.ZipFile("gf2-d20260731.zip", 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk("gf2-d20260731"):
        for f in files:
            if f == "gf2-yaml-extension.yaml.txt":
                continue
            full = os.path.join(root, f)
            zf.write(full, os.path.relpath(full, "."))
PY
```

Result: `+42` STEUER_MELDUNG, `+82` STEUER_MELDUNG_FILE, `+26139` STEUER_FIELDS_DATA, `+2583` STEUER_BEH_DATA. Dropped `2 / 1 / 2014 / 302` respectively. After also removing the extension from the zip, the spurious `ERR_AUSSCHM_VORH` for `LU0111465547` at Zeile 244 disappears.
