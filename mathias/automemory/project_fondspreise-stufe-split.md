---
name: project_fondspreise-stufe-split
description: Fondspreise wurde 2026-09-16 in Stufe 1 (auf master) und Stufe 2 (feat/fondspreise-sync) geteilt; die drei Stufe-2-Migrationen V067-V069 kollidieren inzwischen alle mit master und müssen vor dem Merge nachnummeriert werden (Stand 2026-09-22: auf V071-V073).
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e72a69b-1a23-469b-a15c-9532e0182340
  modified: 2026-09-22T09:28:53.342Z
---

Am 2026-09-16 wurde die Fondspreise-Arbeit geteilt, weil `tmp_if_last` und der
Kurs-Sync noch im Umbau sind und ihr Schema nicht provisorisch deployt werden sollte:

- **master** trägt Stufe 1: Eingangsprüfung, Inbox `preismeldung_zeilen` (liegt beim
  Job-System, nicht mehr im Fondspreise-Kontext), Rückmeldung im Legacy-Format,
  Parallelbetrieb-Diff und die drei Web-Seiten. Höchste Migration: **V070**
  (`estb_daily_report_jobs.stm_ids`, Stand 2026-09-22) — master ist seit der
  Teilung um V067-V070 gewachsen.
- **feat/fondspreise-sync** trägt Stufe 2 als *ein* Revert-Commit auf master:
  `preis_herkunft`, `letzte_preise`, `kurs`, `tmp_if_last`, `PreismeldungSyncService`,
  `LetztePreiseService`, `PreismeldungDbDiff`, Sync-Zähler am Job. Migrationen
  **V067-V069** — nirgends deployt, also frei neu zu schneiden (siehe unten).
- `feat/fondspreis` ist der historische Stand vor der Teilung; inhaltlich identisch
  mit `feat/fondspreise-sync`, aber auf dem alten master.

**Vor dem Merge von Stufe 2 nachnummerieren — alle drei kollidieren.** Stand
2026-09-22 belegt master V067-V070, und jede Stufe-2-Migration trifft auf einen
anderen master-Inhalt gleicher Nummer:

| Stufe 2 (feat/fondspreise-sync) | kollidiert mit master |
|---|---|
| `V067__fondspreise_sync.sql` | `V067__preismeldung_zeilen__job_fk.sql` |
| `V068__preis_meldung_diff_jobs__sync.sql` | `V068__jobs_timestamps_with_time_zone.sql` |
| `V069__tmp_if_last.sql` | `V069__jobs_parent.sql` |

Ziel daher **V071-V073** (master-Höchststand V070 + 1), Reihenfolge beibehalten,
gleiche Nummer in `postgres15/` und `sybase16/`. Die Zahlen hier altern mit jedem
master-Commit — vor dem Merge den Höchststand neu bestimmen, nach dem Verfahren in
`mathias/rules/flyway-versions-after-merge.md` (prüft auch `origin/stable` und
`origin/production`, nicht nur das lokale master). Nicht wiederverwenden, was
lokal/CI schon in der `flyway_schema_history` steht — siehe
[[feedback_flyway-one-file-per-feature]].

**Der FK bricht einen Stufe-2-Test:** `PreismeldungSyncServiceTest.seedInboxLines`
legt Inbox-Zeilen unter `UUID.randomUUID()` ohne `jobs`-Zeile an. Beim Rebase auf
master muss der Helper erst einen Job anlegen.

`database-context.fondspreise` heißt jetzt `business-new-introduced`; auf master
belegt ihn vorerst keine Tabelle (die Inbox ist beim Job-System, `tax_code` im
`business`-Kontext). Er bleibt konfiguriert, weil Stufe 2 ihn braucht — siehe
[[project_sybase-schema-freeze]] für die Regel, was nach Postgres darf.
