---
name: gf7-missing-data-recovered-from-gf8
description: "gf7-d20261216 fixture (gf6-...-export-AFTER.yaml.txt) was missing all 20 of gf7's ISINs + 11 predecessor meldungen; recovered from gf8's gf7-...-export-AFTER snapshot, but OPE predecessors that gf7 mutated had to be sourced pre-T from gf1-...-export-AFTER."
metadata: 
  node_type: memory
  type: project
  originSessionId: 14f05209-43c6-49fa-a8ae-4e4e815924d0
---

# gf7 missing data: recover 20 ISINs + 11 predecessors from gf8 snapshot

The gf7 setup fixture `gf7-d20261216/gf6-d20260813-export-AFTER.yaml.txt` held only 2 ISINs, so gf7's
`GrossfileRecalculationTest` diff showed 32 only-in-new errors (20 "ISIN nicht registriert" + 11
"Melde-ID nicht vorhanden" + 1 parse) and 7 only-in-legacy. **No DB export was needed** — everything was
recoverable in-repo from `gf8-d20261217/gf7-d20261216-export-AFTER.yaml.txt` (the durable post-gf7
snapshot, exported for exactly gf7's 20 ISINs). See [[merge-yaml-export-extension]] / [[gf3-missing-stmids-recovered-from-gf4]].

## What was excluded / re-sourced (the non-obvious part)

The gf8 snapshot is **post-gf7**, so it carried gf7's own mutations. Two classes had to be undone:

1. **9 meldungen gf7 created** (`OPEN;649NNN` results in `gf7_return.csv`): 649596–649604 — excluded via
   `--merge --exclude-stm-ids`. They carry eintragezeit at the gf7 run time `2026-03-02T15:08:3x` (the
   actual wall-clock, NOT the logical `d20261216`); the run time matches `error.log`'s header timestamp.

2. **3 OPE predecessors gf7 mutated** — 649576 (CONFIRMED→FIN, got `confirmFileId`+bumped guelt) and
   **649574/649575 (UPDATEd→ created 649603/649604, so legacy's `BeendeAlteMeldung` set their `gueltBis`)**.
   In the post-gf7 snapshot these look ended/confirmed; pre-gf7 they were active OPE with `gueltBis` null.
   Re-sourced all three from the pre-T fixture `gf2-d20260731/gf1-d20260724-export-AFTER.yaml.txt` via
   `--extract --include-stm-ids 649574,649575,649576`, after excluding them from the gf8 merge.

A FIN predecessor that gf7 updated (649523 → 649599) was **fine as-is**: updating a FIN meldung does NOT
set gueltBis on it (stays a confirmed historical row), so its snapshot state == pre-T state. Only OPE
predecessors that were successfully updated/confirmed needed pre-T sourcing. This is the data-side mirror
of the code fix in [[gf6-update-on-ended-meldung-guelt-bis]]: the validator is gueltBis-aware, so an
ended predecessor (gueltBis set) reports "nicht vorhanden".

## Result

error `(7,0,0,7,32,0)`→`(13,0,0,1,1,0)`, info `(4,0,0,4,0,0)`→`(7,0,0,1,1,0)`, oekbinfo `(0,0,0,1,0,0)`→`(1,0,0,0,0,0)`.
The lone remaining error+info deviation is a **CSV-parse discrepancy unrelated to data**:
`STATUS;UPDATE;649565;03.08.2026` (Zeile 38/39) — legacy treats the 4th field as "Melde-ID vorherige
Meldung", warns it's Meldestelle-only and *ignores* it then proceeds (→ Selbstnachweis error downstream);
the new system parses it as numeric and hard-errors ("ungueltigen Wert <03.08.2026>"). All 8 grossfiles green.
