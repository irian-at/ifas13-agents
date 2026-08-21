---
name: project_stb-auslieferformat-only
description: STB is an Auslieferformat-only record; the STB entries in CsvIfasStructureValidationRules for OPEN/ERROR/DELETED/FINAL are NOT stale after that schema change.
metadata:
  type: project
---

The `STB` (Steuerliche Behandlung) record exists only in `STM_AUSLIEFERFORMAT_*.csv-schema.yml`,
never in the Lieferformat — STB is calculated, not delivered. Removed from the Lieferformat schema
on 2026-08-21.

Two independent axes decide whether an `STB;` row is legal, and it is easy to mistake one for the
other:

- **Schema type** (`CsvSchemaType`, chosen by the entry point: `loadAndValidateInputFromCsv` →
  Lieferformat, `loadReturnFromCsv` → Auslieferformat). Resolved first, in
  `CsvIfasMessageProcessor.getRecordSchemaOrHandleError`, so an unknown record yields
  `UNKNOWN_RECORD_TYPE` *before* any structure rule runs.
- **StmStatus** (`CsvIfasStructureValidationRules.forStatus`), which is schema-independent and
  applies to both read paths.

**Why:** `CsvIfasStructureValidationRules` still lists `STB` in `allowedRecords`/`sequence` for
`OPEN`/`ERROR`/`DELETED`/`FINAL`. That looks inconsistent with the Lieferformat no longer defining
STB, but it is correct — those are exactly the statuses a return file carries, and the same rules
run on the Auslieferformat path. Deleting them would break return-file reads.

**How to apply:** Don't "clean up" the STB entries in `CsvIfasStructureValidationRules:57-58`.
A fixture with `STB;` rows belongs to the Auslieferformat; read it via `loadReturnFromCsv`, not
`internalLoadAndValidateInputSteuerMeldungenFromCsv`. See
[[project_recalc-historical-fidelity]] for the same "don't tidy a deliberate gate" pattern.
