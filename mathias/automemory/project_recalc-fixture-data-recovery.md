---
name: recalc-fixture-data-recovery
description: "When a grossfile recalc references a meldung/ISIN missing from sybase-gast, recover it from a LATER grossfile's export-AFTER snapshot before giving up — undoing that grossfile's own mutations."
metadata: 
  node_type: memory
  type: project
  originSessionId: 45d82f12-074f-4f2e-8e02-c1c95739a790
---

# Recovering missing recalc fixture data from a later grossfile

A grossfile recalc test (`GrossfileRecalculationTest`) can show "only-in-new" deviations
("Melde-ID nicht vorhanden", "ISIN nicht registriert") because the setup YAML
(`gfN/<prev>-export-AFTER.yaml.txt`) is missing meldungen/ISINs the CSV references. The source
DB (sybase-gast) loses rows over time; the fixture YAMLs baked into the grossfile zips are the
durable record. **Before treating this as unrecoverable, pull the missing data from a *later*
grossfile's `*-export-AFTER` snapshot** — that snapshot was captured when the rows still existed.

Recovery uses the [[merge-yaml-export-extension]] skill (`--extract` / `--merge`, by stmId or ISIN).

## The non-obvious part: undo the later grossfile's own mutations

A post-gfN snapshot already carries gfN's mutations, so when sourcing pre-gfN state from it you
must reverse two classes:

1. **Meldungen the later grossfile created** (its `OPEN;649NNN` results) — exclude them
   (`--merge --exclude-stm-ids`). Their eintragezeit is the run's wall-clock time, not the logical
   `dYYYYMMDD` date.

2. **OPE predecessors the later grossfile ended/confirmed** — an UPDATE or CONFIRM of an **OPEN**
   meldung makes legacy's `BeendeAlteMeldung` **set its `gueltBis`**. In the post-snapshot these
   look ended; pre-T they were active with `gueltBis` null. Re-source them from an *earlier* fixture
   (`--extract --include-stm-ids`) after excluding them from the later merge.

**A FIN predecessor that was updated needs no re-sourcing** — updating a FINAL meldung does NOT set
its `gueltBis` (it stays a confirmed historical row), so snapshot state == pre-T state. If the fund
was untouched between the source snapshot and the target point (verify across the intervening CSVs),
no time-filtering is needed at all.

This is the data-side mirror of [[project_gueltbis-active-meldung-discriminator]]: the validator is
gueltBis-aware, so an ended predecessor (gueltBis set) reports "nicht vorhanden".
