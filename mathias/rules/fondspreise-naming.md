---
paths:
  - "**/fondspreise/**"
  - "**/*Preis*"
  - "**/*preis*"
---

# Fondspreise Naming

Decisions Mathias set for the Fondspreise work (new, non-Sybase tables and the code around them).

- **Entity name = table name.** Entity singular, table plural snake_case with an **English plural**:
  `PreisVersion` ↔ `preis_versions`, `PreisVersionSource` ↔ `preis_version_sources`,
  `PreisMeldungZeile` ↔ `preis_meldung_zeilen`. Never `versionen` — also for fields and collections
  (`List<PreisVersionData> versions`). Inherited Sybase tables (`tax_code`, `kurs`, `tmp_if_last`)
  keep their legacy names.
- **Id columns name the referenced entity**: `created_preis_version_id`, `preis_meldung_zeile_id`,
  `preis_version_sync_job_id` — not `created_version_id`, not `processed_by`. No FK across DB
  contexts (ledger `business-new-introduced` vs jobs `infra`); a `processed_at` stamp sits beside
  the id.
- **A domain record mirroring an entity ends in `Data`**: `PreisMeldungZeile` / `PreisMeldungZeileData`.
  No simple class name is shared between a persistence and a domain module.
- **Spelling `PreisMeldung`** (CamelCase like `SteuerMeldung`, `AusschuettungsMeldung`). *Fondspreise*
  names the feature (modules, `domain.fondspreise`, `persistence.fondspreise`, `service.fondspreise`,
  property prefix `ifas.fondspreise`); *PreisMeldung* names the delivery stage only (CSV, Eingang,
  Rückmeldung, the Inbox entity, the Parallelbetrieb diff job).
- **No "Inbox" in identifiers** — it is only the prose name of `preis_meldung_zeilen`:
  `FilteredPreisMeldungZeile`, `PreisMeldungZeilenFilter`, `getPreisMeldungZeilen`.
- **Technical words are English even in domain type names**; only Fachbegriffe stay German:
  `StorageGates`, `SkipReason`, `PreisKey` — not `SpeicherGates`, `UebersprungGrund`, `PreisSchluessel`.
  `PreisZeitreihe` stays (follows `GjZeitreihe`); constants naming Fachbegriffe (`C_PLAN`, `AIF`) stay.
- **Domain sub-packages group by stage** (`eingang`, `verarbeitung`), not by concept (`historie` was
  rejected).
- **Jobs are named after what they produce** when the step has no Fachbegriff: `PreisVersionJob`
  (`preis_version_jobs`, task type `PREIS_VERSION`), `PreisVersionSyncJob` (`preis_version_sync_jobs`,
  `PREIS_VERSION_SYNC`, named after its source `preis_versions`). Steps with a legacy word keep it
  (`PreisMeldung…` for the Eingang).
- **No "Historie"** anywhere — a row is a version, the history is the reading. The UI says
  **Preisversionen** (right `PREIS_VERSIONEN`, URL `/ui/preis-versionen`).

## Why

He wants to find the table from the entity name and vice versa without a mapping in his head;
decided 2026-10-01 … 2026-10-08 while landing the `preis_versions` ledger and its sync.
