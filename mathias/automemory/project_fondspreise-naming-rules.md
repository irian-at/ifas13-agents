---
name: fondspreise-naming-rules
description: "Naming rules Mathias set on 2026-10-01 for new (non-Sybase) tables, entities, id references and domain records in the Fondspreise work; English plural \"versions\", never \"versionen\"."
metadata:
  node_type: memory
  type: project
  originSessionId: 387e3d2c-8336-466c-adf5-16dc3c0c3429
  modified: 2026-10-08T00:00:00.000Z
---

Set 2026-10-01 while landing the `preis_versions` ledger (commit `b137e7724`):

- **Entity name = table name** for every table the new system introduces: entity singular, table
  plural snake_case with an **English plural** — `PreisVersion` ↔ `preis_versions`,
  `PreisVersionSource` ↔ `preis_version_sources`, like `PreisMeldungZeile` ↔ `preis_meldung_zeilen`,
  `Job` ↔ `jobs`. Never `preis_versionen`; "versions, not versionen" also holds for field and
  collection names (`List<PreisVersionDaten> versions`).
- **Id references spell out their target type**: `created_preis_version_id`, `preis_meldung_zeile_id`,
  not `created_version_id`.
- **Domain record mirroring an entity gets the English `Data` suffix** (changed 2026-10-01 from `Daten`):
  `PreisMeldungZeile` (entity) / `PreisMeldungZeileData` (record), `PreisVersion` / `PreisVersionData`. No
  simple class name is shared between a persistence and a domain module.
- Inherited Sybase tables (`tax_code`, `kurs`, `tmp_if_last`) keep their legacy names.
- **No "Inbox" in class names** (too generic; it is the prose name of the table `preismeldung_zeilen`):
  the fold's input line is `FilteredPreisMeldungZeile`, the filter `PreisMeldungZeilenFilter`; this also
  covers identifiers (`getPreisMeldungZeilen`, not `getInboxZeilen`).
- **Spelling `PreisMeldung`, CamelCase like `SteuerMeldung` and `AusschuettungsMeldung`** (decided 2026-10-01;
  the feature had started with one-word `Preismeldung`). *Fondspreise* names the feature: modules, the
  `domain.fondspreise`, `persistence.fondspreise`, `persistence.infra.fondspreise`, `service.fondspreise`
  and `testdata.fondspreise` packages, the `ifas.fondspreise` property prefix. *PreisMeldung* names the
  delivery stage only (CSV, Eingang, Rückmeldung, the Inbox entity, the Parallelbetrieb diff job).
- **Technical words are English even in domain type names**; only Fachbegriffe stay German:
  `StorageGates` and `SkipReason`, not `SpeicherGates` and `UebersprungGrund` (corrected 2026-10-01 after
  a first version had slipped through review). Constants naming Fachbegriffe (`C_PLAN`, `AIF`) stay.
  Plan-coined terms count as technical: `PreisKey`, not `PreisSchluessel`. `PreisZeitreihe` stays because
  `GjZeitreihe` set that pattern (Zeitreihe is accepted vocabulary here).
- **Domain sub-packages group by stage**, like `eingang`: the processing-run types live in
  `at.oekb.ifas.domain.fondspreise.verarbeitung`; a concept package such as `historie` was rejected.
- **Jobs are named after what they produce when the step has no Fachbegriff** (2026-10-06): the
  run that folds lines into `preis_versions` is `PreisVersionJob` (table `preis_version_jobs`, task
  type `PREIS_VERSION`), not `PreisVerarbeitungJob` — "Verarbeitung" is the umbrella for the whole
  stage 2 including the later Sybase write and names no step. Steps with a legacy word keep it:
  Eingang (`PreisMeldung…`). The Inbox claim column follows the id rule: `preis_version_job_id`
  (renamed from `processing_job_id` in V076).
- **The `kurs` writer is `PreisVersionSyncJob`** (2026-10-08; table `preis_version_sync_jobs`, task type
  `PREIS_VERSION_SYNC`), named after its source so it covers `tmp_if_last` later — not "Einspielung" as
  noted earlier. Its stamp on `preis_versions` is `processed_at` / `preis_version_sync_job_id`: the id column follows
  the id rule (he first planned `processed_by` as an exception, then checked the house precedent on
  2026-10-08 and went back to the rule; V076 had renamed the Inbox claim for the same reason). No FK: the
  ledger and the jobs are different DB contexts (`h2-db1` vs `h2-infra-db` in local-h2-only). `processed`,
  not `synced`, because skipped rows carry the stamp too.

**Why:** he wants to find the table from the entity name and vice versa without a mapping in his
head; "Historie" was rejected as a table name because a row is a version, the history is the reading.
Since 2026-10-08 "Historie" is gone from the UI too: page title and menu item say **Preisversionen**
(the right stays `PREIS_VERSIONEN`, the URL `/ui/preis-versionen`); no Historie in labels, template
parameters or comments.

**How to apply:** when a chunk adds a table, derive the table name from the entity name with an
English plural, and name id columns after the referenced entity. See also
[[chunked-implementation-via-opus-subagents]] and [[fondspreise-stufe-split]].
