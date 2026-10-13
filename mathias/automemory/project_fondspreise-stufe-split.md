---
name: project_fondspreise-stufe-split
description: Fondspreise Stufe 1 liegt auf master; feat/fondspreise-sync wird NICHT gemergt (Steinbruch, V067-V069 entfallen); Stand, Blocker und Pläne stehen in plans/fondspreise/tracker.md.
metadata:
  type: project
---

Seit 2026-09-16 geteilt: **master** trägt Stufe 1 (Eingangsprüfung, Inbox `preis_meldung_zeilen`,
Rückmeldung im Legacy-Format, Parallelbetrieb-Diff, Web-Seiten), seit 2026-09-30 auch `Kurs`/`TmpIfLast`
samt Repositories (`V073__kurs_tmp_if_last.sql`, nur Test-DB-Provisionierung) und seit Oktober das
`preis_versions`-Ledger mit `PreisVersionJob`, `PreisVersionSyncJob` und `PreisMeldungJob`.
**`feat/fondspreise-sync` wird nicht gemergt** (sein Guard-Design ist durch `preis_versions` ersetzt);
seine Migrationen V067-V069 entfallen, der Branch ist Steinbruch (`PreismeldungSyncDecisions`,
`FondspreiseProperties`). `feat/fondspreis` ist der Stand vor der Teilung.

`database-context.fondspreise` heißt `business-new-introduced`; das Ledger ist dort die erste Tabelle
([[project_sybase-schema-freeze]]).

**Why:** alles vor dem 2026-09-30 (Konzept 31.08., Schnitt-1/2-Pläne, Formen, ER, Zeitreihe, Decks)
liegt archiviert unter `mathias/plans/archive/2026-08/` und `2026-09/` — nicht mehr daraus zitieren.

**How to apply:** aktueller Stand, Blocker, Klärungen und Go-live-Backlog (z. B.
`ifas.fondspreise.preis-version-sync.enabled` bleibt aus) stehen in
`mathias/plans/fondspreise/tracker.md`; daneben die verbindlichen Pläne
(`2026-09-30-…-preis-historie-versionen.md`, `2026-10-08-…-preis-version-sync-kurs.md`,
`2026-10-12-…-preis-meldung-job.md`, `2026-10-12-…-preisfile-sammellauf.md`) und die Legacy-Analyse
(`2026-09-30-…-legacy-analyse-und-befunde.md`). Siehe [[project_test-stage-sybase-layout]].

**Stand 2026-10-13:** auch der Preisfile-Sammellauf (`PreisfileJob`, Plan `2026-10-12-fondspreise-preisfile-sammellauf.md`,
Commits `efd1c5fd2`/`f9fbc64fe`/`6f40d81f5`/`50d943850`) ist umgesetzt; beide Läufe per Property aus. Vor dem
Einschalten des Sammellaufs auf TEST: Publikationsstempel von Hand (nur offene Versionen vor dem Snapshot). Der
Sync braucht keinen Migrations-Stempel mehr: seit `da7ca67ec` (Plan `2026-10-13-fondspreise-sync-selbstheilung-sybase-snapshot.md`)
erkennt er einen ersetzten `kurs` an seiner Kanarienzeile (`preis_versions.kurs_guelt`), setzt das Ledger auf
T − Marge und stempelt beim ersten Lauf ohne Kanarie den Backlog selbst — die Neusystem-Sybase wird alle 1–3 Wochen
komplett aus der Alt-DB ersetzt (Team-Diskussion offen, STM-Verlust vorerst akzeptiert). Job-Protokoll-Mails je Job-Typ
an Fachbereich oder System-Support (`notification.jobs.<JobType>.recipients`). Noch kein Plan: Plausi `-P`, T2S,
Fehlmeldung, Kennzahlen.
