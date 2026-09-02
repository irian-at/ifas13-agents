---
name: sybase-schema-freeze
description: Keine neuen Tabellen/Spalten in Sybase; neue Tabellen nach Postgres — Business-Tabellen aber NICHT nach infra. Sybase-Migration nach Postgres im Lauf von 2027.
metadata: 
  node_type: memory
  type: project
  originSessionId: 29d00419-c8e9-488e-8e21-00dd20901780
  modified: 2026-09-02T10:21:55.665Z
---

Vorgabe (User, 2026-09-02): In der Sybase dürfen **keine neuen Tabellen und keine neuen Spalten**
angelegt werden — weder in der Altsystem- noch in der Neusystem-Sybase. Neue Tabellen kommen nach
Postgres, aber: **Business-Tabellen NICHT nach `infra`** — `infra` ist nur für Job-/Work-Queue-
Infrastruktur. Die Sybase wird im Lauf von 2027 nach Postgres migriert.

**Why:** Die Schemata beider Sybase-Instanzen müssen für den Parallelbetrieb-Diff identisch bleiben
(`DatabaseCompareService`), und die Sybase läuft aus.

**How to apply:** Neue Business-Tabellen nach dem Muster `ifas.ausschuettung_tmp`
(`ifas-persistence-stm`, `database-context.ausschuettung-tmp-db-key` → Postgres): Legacy-Katalogname
(z. B. `kurs`), eigenes Business-Persistence-Modul, eigener Context-Key. Job-Entities bleiben in
`ifas-persistence-infra` (Katalog `infra`). Referenzen zwischen Business-Tabellen und Jobs sind
logische UUIDs, keine DB-FKs (verschiedene DB-Kontexte). Eine Transaktion über neue Postgres-Tabelle
und Sybase-Legacy-Tabelle gibt es nicht (kein XA) — bis zur Migration Klammer-Transaktion wie im
Fondspreise-Konzept. Parallelbetrieb neuer Domänen: Altsystem verarbeitet/persistiert zuerst, seine
Input-/Resultfiles laufen als Diff-Job durchs Neusystem (Muster `IsinAnforderungslisteDiffJob`,
`AusschuettungsMeldungDiffJobSubmissionService`); Außenwirkungen (Mails, MFT) unterdrückt. Siehe
[[gf1-fielddiff-null-vs-zero]] und [[validationsetting-flags-have-two-effects]] für die
Diff-Konfiguration bekannter Abweichungen.
