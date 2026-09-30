---
name: project_fondspreise-stufe-split
description: Fondspreise Stufe 1 liegt auf master; Stufe 2 (feat/fondspreise-sync) wird seit 2026-09-24 NICHT gemergt, sondern ist Steinbruch für den neuen preis_historie-Plan — ihre Migrationen V067-V069 entfallen.
metadata: 
  node_type: memory
  type: project
  originSessionId: 5e72a69b-1a23-469b-a15c-9532e0182340
  modified: 2026-09-30T15:24:37.033Z
---

Am 2026-09-16 wurde die Fondspreise-Arbeit geteilt:

- **master** trägt Stufe 1: Eingangsprüfung, Inbox `preismeldung_zeilen` (beim
  Job-System), Rückmeldung im Legacy-Format, Parallelbetrieb-Diff, drei Web-Seiten.
- **feat/fondspreise-sync** trägt Stufe 2 als *ein* Revert-Commit: `preis_herkunft`,
  `letzte_preise`, `kurs`, `tmp_if_last`, `PreismeldungSyncService`,
  `LetztePreiseService`, `PreismeldungDbDiff`. Migrationen V067-V069, nie deployt.
- `feat/fondspreis` ist der historische Stand vor der Teilung.

**Seit 2026-09-24: der Branch wird nicht gemergt.** Das Guard-Design (Klammer-
Transaktionen, zwei Guard-Tabellen) ist durch `preis_historie` ersetzt.
**Verbindlicher Plan seit 2026-09-30:**
`mathias/plans/fondspreise/2026-09-30-fondspreise-preis-historie-versionen.md` —
Versionszeilen (`created_at`/`invalidated_at`/`deleted`, Position `empfangen_at`+`zeilen_nr`),
Claim je Lauf statt Guard, `preis_historie_source` (eine Zeile je wirksamer Inbox-Zeile,
`operation` + beide Versions-IDs, beim Job-System mit Cascade), kein Wertvergleich, Wiederholung
fügt nur hinzu; Sybase-Ableitung als Folgejob, nicht im Plan. Alle Befunde zum Altsystem, die Datenlage, Fachabteilungs-Aussagen und die Klärungen A–P stehen
seit 2026-09-30 in `mathias/plans/fondspreise/2026-09-30-fondspreise-legacy-analyse-und-befunde.md`
(Digest; Basis bleibt `docs/Fondspreise/fondspreise-legacy-analyse.md`). Konzept (31.08.),
Schnitt-1/2-Pläne, Formen, ER, Zeitreihe + Review, Tagesablauf-Decks und das Fragen-File liegen
**archiviert** unter `mathias/plans/archive/2026-08/` und `2026-09/` — nicht mehr daraus zitieren;
`plans/fondspreise/` hält nur Plan, Analyse, `tracker.md` und das SQL-File. Der Branch dient als Steinbruch (übernommen werden u. a.
`PreismeldungSyncDecisions`, `FondspreiseProperties`; Tabelle im Plan, Abschnitt 5). **`Kurs`/`TmpIfLast` samt Repositories
sind seit 2026-09-30 auf master** (`5d22c157c`, DDL als `V073__kurs_tmp_if_last.sql` in beiden
Bäumen, nur Test-DB-Provisionierung); die Ableitung nach `kurs`/`tmp_if_last` fehlt weiterhin.
Die frühere Nachnummerierung V067-V069 → V071+ ist damit hinfällig; neue DDL kommt als
**eine** neue Migration (Plan, Chunk 3), Nummer nach
`mathias/rules/flyway-versions-after-merge.md` bestimmen — siehe
[[feedback_flyway-one-file-per-feature]].

`database-context.fondspreise` heißt `business-new-introduced`; `preis_historie` wird
dort die erste Tabelle sein — siehe [[project_sybase-schema-freeze]].
