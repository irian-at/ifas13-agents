---
name: project_fondspreise-stufe-split
description: Fondspreise wurde 2026-09-16 in Stufe 1 (auf master) und Stufe 2 (feat/fondspreise-sync) geteilt; master hat inzwischen V067 belegt, die Stufe-2-Migrationen V067-V069 müssen vor dem Merge nachnummeriert werden.
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e72a69b-1a23-469b-a15c-9532e0182340
  modified: 2026-09-17T08:05:00.000Z
---

Am 2026-09-16 wurde die Fondspreise-Arbeit geteilt, weil `tmp_if_last` und der
Kurs-Sync noch im Umbau sind und ihr Schema nicht provisorisch deployt werden sollte:

- **master** trägt Stufe 1: Eingangsprüfung, Inbox `preismeldung_zeilen` (liegt beim
  Job-System, nicht mehr im Fondspreise-Kontext), Rückmeldung im Legacy-Format,
  Parallelbetrieb-Diff und die drei Web-Seiten. Höchste Migration: **V067**
  (`preismeldung_zeilen.job_id` → `jobs`, gesetzt am 2026-09-17).
- **feat/fondspreise-sync** trägt Stufe 2 als *ein* Revert-Commit auf master:
  `preis_herkunft`, `letzte_preise`, `kurs`, `tmp_if_last`, `PreismeldungSyncService`,
  `LetztePreiseService`, `PreismeldungDbDiff`, Sync-Zähler am Job. Migrationen
  **V067-V069** — nirgends deployt, also frei neu zu schneiden.
- `feat/fondspreis` ist der historische Stand vor der Teilung; inhaltlich identisch
  mit `feat/fondspreise-sync`, aber auf dem alten master.

**Vor dem Merge von Stufe 2 nachnummerieren:** master belegt V067 seit 2026-09-17,
die Stufe-2-Migrationen rücken auf V068-V070. Nicht wiederverwenden, was lokal/CI
schon in der `flyway_schema_history` steht — siehe
[[feedback_flyway-one-file-per-feature]].

**Der FK bricht einen Stufe-2-Test:** `PreismeldungSyncServiceTest.seedInboxLines`
legt Inbox-Zeilen unter `UUID.randomUUID()` ohne `jobs`-Zeile an. Beim Rebase auf
master muss der Helper erst einen Job anlegen.

`database-context.fondspreise` heißt jetzt `business-new-introduced`; auf master
belegt ihn vorerst keine Tabelle (die Inbox ist beim Job-System, `tax_code` im
`business`-Kontext). Er bleibt konfiguriert, weil Stufe 2 ihn braucht — siehe
[[project_sybase-schema-freeze]] für die Regel, was nach Postgres darf.
