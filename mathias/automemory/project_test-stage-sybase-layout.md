---
name: project_test-stage-sybase-layout
description: TEST-Stage hat zwei Sybase-DBs auf sybtst02 — sybase-gast = IFAS-ALT (ifas,kurs,vwkn, readonly, legacy-business) und sybase-ifasneu = IFAS-NEU (ifas1,kurs1,vwkn1, business, writeable); Catalog1-Naming hängt die „1“ an.
metadata:
  type: project
---

TEST-Stage (User 2026-10-12): beide Sybase-Datenbanken liegen auf demselben Server `sybtst02`.

| db-key | Anzeige | Datenbanken | Kontext (server-deployment) |
|---|---|---|---|
| `sybase-gast` | Sybase IFAS-ALT | `ifas`, `kurs`, `vwkn` — **readonly** | `legacy-business`, `web-ui-default` |
| `sybase-ifasneu` | Sybase IFAS-NEU | `ifas1`, `kurs1`, `vwkn1` | `business` (writeable) |

Das Ledger (`business-new-introduced`) und das Job-System sind `postgres-server`. IFAS-NEU ist eine
Schatten-Kopie der Alt-DB (Voll-Sync, Snapshot-Zeitpunkt T); im Parallelbetrieb werden beide auf
Gleichheit verglichen. Die Entities mappen `@Table(catalog = "kurs")` usw.; `SybaseIfasNeu` wählt per
Default `Catalog1SybaseDboSchemaPhysicalNamingStrategy` (`kurs.dbo.kurs` → `kurs1.dbo.kurs`), überschreibbar
über `OEKB_IFAS_SYBASE_IFASNEU_HIBERNATE_PHYSICAL_NAMING_STRATEGY`. Der `PreisVersionSyncJob` schreibt also
`kurs1..kurs`, nie die Alt-DB.

**Why:** Wer „kurs“ im Deployment sucht, muss wissen, dass die Neusystem-Tabellen `…1` heißen und auf
demselben Server liegen wie das Original — ein Vergleich Alt gegen Neu (D13 für `kurs`) ist dort ein
einfacher Cross-Database-Join `kurs..kurs` gegen `kurs1..kurs`, kein Export nötig.

**How to apply:** Migrations-Stempel (Sync-Plan Abschnitt 7) mit T = Zeitpunkt des Voll-Syncs nach
`kurs1`; danach die Property auf TEST einschalten und `kurs..kurs` gegen `kurs1..kurs` vergleichen.
Siehe [[project_sybase-schema-freeze]], [[project_db-context-blind-spot-in-tests]].
