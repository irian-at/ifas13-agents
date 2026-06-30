---
name: gf3-missing-stmids-recoverable-from-gf4
description: Three stmIds gf3 references (649492, 649539, 649548 + 649550) are absent from sybase-gast but ARE present in gf4-d20260807's fixture YAML — recovered via the new `merge_yaml.py --extract` mode.
metadata:
  type: project
---

# gf3 fixture: stmIds recovered from gf4's YAML

In `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf3-d20260805/`, the gf3 CSV references four pre-existing meldungen via STATUS rows:

- `STATUS;UPDATE;649492` — Zeile 127 (AT0000495973)
- `STATUS;CONFIRMED;649539` — Zeile 41 (LU0136043634)
- `STATUS;UPDATE;649548` — Zeile 60 (IE0007472115)
- `STATUS;UPDATE;649550` — Zeile 65 (IE0007987708)

A `FondsYamlExportTool` run against sybase-gast on 2026-06-25 returned `entities: []` for all four — the source DB no longer has them.

**They are however present in `gf4-d20260807.zip` → `gf4-d20260807/gf3-d20260805-export-AFTER.yaml.txt`** (the post-gf3 snapshot baked into the gf4 test fixture, which was generated when these meldungen still existed). All four show as `status: OPE` with `fileId: 348757` (gf1-d20260724.csv).

## Recovery procedure (already applied for gf3, 2026-06-26)

1. Unzip the source YAML from the later grossfile fixture:
   ```bash
   python3 -c "import zipfile; zipfile.ZipFile('gf4-d20260807.zip').extract('gf4-d20260807/gf3-d20260805-export-AFTER.yaml.txt', '/tmp/')"
   ```
2. Carve out just the wanted stmIds + dependents into a small extension YAML using the new `--extract` mode of [[merge-yaml-export-extension]]:
   ```bash
   python3 ~/dev/projects/ifas13-agents/mathias/skills/merge-yaml-export-extension/merge_yaml.py \
     --extract \
     --source /tmp/gf4-d20260807/gf3-d20260805-export-AFTER.yaml.txt \
     --include-stm-ids 649492,649539,649548,649550 \
     --output gf3-missing-stms-extension.yaml.txt
   ```
3. Merge it into the gf3 primary YAML via the regular `--merge` flow, then rebuild the gf3 zip excluding the extension file.

## Why: future-proofing

**If similar "gf-references-deleted-stmId" deviations appear for gf4-gf8**: try the same recovery path — pull from the *next* grossfile's fixture YAML before giving up. Reach for the unrecoverable-from-DB option only after confirming the stmId is missing from every later fixture too.

## Why the source DB lost them — speculation

Likely a sybase-gast cleanup/rebuild between the time the fixture YAMLs were captured (Feb-Mar 2026) and the re-export attempt (June 2026). The fixture YAMLs are the durable record; sybase-gast is mutable QA state.

Related skill: [[merge-yaml-export-extension]] — the `--extract` mode was added specifically for this recovery scenario; see SKILL.md "Recovering stmIds from later fixtures" section.
