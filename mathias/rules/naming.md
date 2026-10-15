---
paths:
  - "**/*"
---

# Naming

Applies to every identifier: classes, records, enums, methods, fields, variables, parameters,
constants, packages, test methods, tables and columns, property keys, URL paths.

## German for Fachbegriffe, English for the rest

A **Fachbegriff** is a business-domain term — the word the Fachbereich, the legacy system or the
Lieferformat spec uses: `SteuerMeldung`, `Ermittlungsvorgabe`, `Stichtag`, `Ausschuettung`,
`Meldefrist`, `Waehrung`, `Kurs`. It stays German, in the spelling the codebase already uses, and is
never translated (`TaxReport`, `DistributionDate`).

Everything else is English: verbs, technical concepts, glue words.

| correct | wrong |
|---|---|
| `findReferenzpreis`, `isHandelswaehrung` | `ermittleReferenzpreis`, `istHandelswaehrung` |
| `PreisKey`, `SkipReason`, `StorageGates` | `PreisSchluessel`, `UebersprungGrund`, `SpeicherGates` |
| `lineNumber`, `countByCode` | `zeilenNummer`, `anzahlNachCode` |
| `whenProcess_thenStichtagStored` | `whenVerarbeite_thenStichtagGespeichert` |

- The verb is always English: `write`, `process`, `compare`, `check` — never `schreibe`,
  `verarbeite`, `vergleiche`, `pruefe`.
- Test for a Fachbegriff: would the Fachbereich say it in German when talking business? Line, key,
  reason, filter, job, version, count, source are technical → English.
- A compound Fachbegriff keeps its German parts (`PreisMeldungZeile`, `GjZeitreihe`); never
  half-translate it.
- The plural follows the noun's language: `zeilen`, `meldungen`, but `versions`, `keys`.
- Umlauts are transliterated: `ae`, `oe`, `ue`, `ss` (`Ausschuettung`, `Waehrung`).
- Legacy codes and constants keep the legacy spelling (`ERR_FRIST_NOSN`, `C_PLAN`, `AIF`).

## Plain, self-explaining words

A name says what the thing is or does, in words a non-native speaker reads without a dictionary.
Pick the everyday word over the sophisticated one:

| use | not |
|---|---|
| `create`, `write` | `materialize` |
| `replace`, `replacedBy` | `supersede`, `supersededBy` |
| `sync`, `match` | `reconcile` |
| `source`, `origin` | `provenance` |
| `import`, `read` | `ingest` |
| `firstNonNull`, `merge` | `coalesce` (outside SQL) |
| `normalized`, `standard` | `canonical` |
| `find`, `determine` | `ascertain` |
| `skip`, `omit` | `elide` |

- Longer and clear beats short and cryptic: `findLatestFinalMeldung`, not `findLfm`.
- No new abbreviations; the established ones stay (`Isin`, `Wkn`, `Stm`, `Kag`, `Gj`, `Msg`, `Dto`).
- Booleans read as a question: `isFinal`, `hasPredecessor`, `canDelete`.

## Tables and entities

New (non-Sybase) tables; inherited Sybase tables keep their legacy names.

- **Entity name = table name**: entity singular CamelCase, table plural snake_case
  (`PreisVersion` ↔ `preis_versions`, `PreisMeldungZeile` ↔ `preis_meldung_zeilen`).
- **Id columns name the referenced entity**: `preis_meldung_zeile_id`, `preis_version_sync_job_id` —
  not `version_id`, not `processed_by`.
- **A domain record mirroring an entity ends in `Data`** (`PreisMeldungZeile` /
  `PreisMeldungZeileData`); no simple class name is shared between a persistence and a domain module.
- **Jobs are named after their Fachbegriff step** (`fristenpruefung_jobs`), else after what they
  produce (`PreisVersionJob` ↔ `preis_version_jobs`, task type `PREIS_VERSION`).

## Scope

- Texts are not identifiers: UI labels, Meldungstexte and Rückmeldung logs keep their language;
  legacy Meldungstexte stay verbatim.
- Existing names stay unless the task is the rename — apply this to new names and to names the task
  changes anyway.
- Naming patterns (plural utility classes, `…Testdata`, `…Assertions`, `…PageController`) live in
  `.claude/rules/java-conventions.md`.

## Why

Mathias wants names a reader understands at first sight, without a translation step: German where
the business talks German, plain English everywhere else. Set 2026-09-02 for method verbs,
widened to all identifiers 2026-10-15.
