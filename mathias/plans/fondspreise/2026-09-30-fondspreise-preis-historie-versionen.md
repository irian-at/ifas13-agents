# Fondspreise — `preis_versions`: Versionen je Preisschlüssel, Verarbeitung aus der Inbox

Stand 2026-09-30. Ergebnis der Diskussion vom 30.09. Dieses Dokument ist die **verbindliche
Fassung** des Preis-Ledgers und ersetzt alle früheren Entwürfe dazu (Abschnitt 9). Was hier nicht
steht, ist nicht entschieden.

**Scope:** korrekte, vollständige Daten in `preis_versions` samt Herkunft. Die Ableitung nach
`kurs` und `tmp_if_last` ist **nicht** Teil dieses Plans; sie wird ein eigener Folgejob nach dem
Ledger-Commit (Abschnitt 7). Die Entities `Kurs`/`TmpIfLast` liegen seit `5d22c157c` (V073) auf
`master` und bleiben bis dahin ungenutzt.

**Umsetzung in Chunks** (Abschnitt 8): jeder Chunk ist ein eigener Commit auf `master`, baut, hat
seine Tests und verbessert den Stand, ohne auf den nächsten zu warten.

**Namen** (Nachtrag 2026-10-15): Spalten- und Indexnamen folgen dem Stand nach V084 (`2a007ec34`), Java-Namen der
Namensbereinigung vom selben Tag. V075 legte sie als `offen`, `preis_datum`, `empfangen_at`, `eingang_abgeschlossen_at`,
`ux_preis_versions_offen` und `ix_preis_versions_schluessel` an.

---

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Schlüssel** | (`isin`, `preisdatum`, `waehrung`, `meldekategorie`) — ein Preis eines Fonds zu einem Stichtag in einer Währung und Kategorie. `meldekategorie` nur `R`, `E`, `Z`, `S`, `S2`, `S3`; LMT erreicht das Ledger nie |
| **Version** | eine Zeile in `preis_versions`: ein Zustand, den IFAS für einen Schlüssel gehalten hat, mit Beginn und (falls beendet) Ende |
| **offene Version** | die Version eines Schlüssels mit `invalidated_at is null`; höchstens eine je Schlüssel |
| **N / D** | die Aktion einer Inbox-Zeile: liefern bzw. aktualisieren (`N`) oder zurückziehen (`D`) |
| **Lauf** | eine Ausführung des `PreisVersionJob`, der Inbox-Zeilen zu Versionen faltet |
| **Position** | (`received_at`, `zeilen_nr`) einer Zeile: Ankunft der Lieferung nach der DB-Uhr, dann physische Zeilennummer im File. Die Ordnung der Faltung |
| **Cursor** | die Position, die die offene Version eines Schlüssels trägt — die Position der Zeile, die sie erzeugt hat |
| **Claim** | die bedingte Zuweisung noch nicht verarbeiteter Inbox-Zeilen an einen Lauf (`preis_version_job_id`) |
| **wirksame Zeile** | eine Inbox-Zeile, die in einem Lauf eine Version erzeugt oder beendet hat |
| **Kontexte** | `job-system` (Jobs, Inbox, `preis_version_sources`) und `business-new-introduced` (`preis_versions`); im Deployment beide `postgres-server` |

---

## 1. Entscheidungen

| Thema | Entscheidung |
|---|---|
| **Rollen der Tabellen** | Die **Inbox** `preis_meldung_zeilen` ist das Operation-Log: jede angenommene Zeile, wie geliefert, write-once je Job, für Support-Fälle durchsuchbar. `preis_versions` hält **nur Operationen, die die Zeitreihe eines Schlüssels verändert haben** — eine Zeile je Version. `preis_version_sources` verbindet beide: eine Zeile je wirksamer Inbox-Zeile mit ihrer Operation |
| **Form der Version** | Versionszeile mit Beginn (`created_at`) und Ende (`invalidated_at`); das Ende trägt die Art als Flag (`deleted`). **Keine D-Zeile**, keine Ereignis-Tabelle, keine Ist-Tabelle. Eine Löschung beendet die offene Version mit `deleted = true`; danach hat der Schlüssel keine offene Version, bis ein neues `N` eine öffnet |
| **Kein Wertvergleich** | Jede wirksame `N`-Zeile erzeugt eine neue Version, auch bei gleichem Wert. Eine identische Nachlieferung ist damit im Ledger sichtbar. Zwischenwerte, die **innerhalb eines Laufs** von einer späteren Zeile desselben Schlüssels überholt werden, erzeugen keine Version — sie stehen nur in der Inbox |
| **Faltung je Lauf und Schlüssel** | Die nach Position **letzte** Zeile des Schlüssels im Lauf entscheidet; sie gilt nur, wenn ihre Position **nach dem Cursor** liegt. `N` beendet die offene Version (`deleted = false`) und öffnet eine neue; `D` beendet sie mit `deleted = true`; `D` ohne offene Version ist ein No-op. Ein Lauf schreibt je Schlüssel höchstens eine neue Version |
| **Ankunftsordnung** | Gilt **über Läufe hinweg**: die Position steht auf jeder Version (`received_at`, `zeilen_nr`). Eine spät verarbeitete ältere Zeile verdrängt keine jüngere. Innerhalb eines Jobs gewinnt die höhere Zeilennummer (Legacy: „letzte Zeile gewinnt“ in `tmp_if_kurs`) |
| **Wiederholungen** | Eine Wiederholung erbt `received_at` des Originals. Ihre Zeilen tragen dieselben Positionen wie die des Originals: was das Original schon geschrieben hat, wird nicht doppelt geschrieben (Position nicht nach dem Cursor); was das Original abgelehnt und die Wiederholung angenommen hat, gilt nach Ankunftsordnung. **Eine Wiederholung fügt nur hinzu, nimmt nie zurück**: eine Version, deren Zeile die Wiederholung jetzt ablehnt, bleibt offen. Sichtbar in der Inbox der Wiederholung (Zeile fehlt) und an der Version (Position zeigt auf das Original). Keine Verdrängungslogik im Lauf |
| **Nebenläufigkeit** | **Claim**: ein Lauf weist sich in **eigener Transaktion** alle Inbox-Zeilen mit `preis_version_job_id is null` zu, deren Eingang abgeschlossen ist (ein bedingtes Update mit Subquery auf den Marker), committet, und liest dann zurück, was er tatsächlich bekommen hat. Ein paralleler Lauf findet nichts. Keine Sperren, kein Guard |
| **Transaktion des Laufs** | Versionen (`business-new-introduced`) und Quellzeilen (`job-system`) in **einer** synchronisierten Transaktion. Im Deployment und in beiden lokalen Postgres-Profilen lösen beide Kontexte auf denselben db-key auf → ein Commit. Nur der H2-only-Launcher trennt sie (Abschnitt 3.7) |
| **Zeitstempel** | `created_at` = DB-Uhr des Kontexts `business-new-introduced` als erste Anweisung der Schreibtransaktion, **ein Wert für alle Versionen des Laufs**; `invalidated_at` der beendeten Version = derselbe Wert. `received_at` am Job = DB-Uhr des Job-Kontexts bei der Einreichung |
| **Herkunft** | `preis_version_sources`: **eine Zeile je wirksamer Inbox-Zeile** mit `operation` (`NEW`, `UPDATE`, `DELETE`) und beiden Versions-IDs (`created_preis_version_id`, `ended_preis_version_id`, je nullable). Liegt **neben der Inbox** im `job-system`, FK auf die Inbox-Zeile **mit Cascade**; die Versions-IDs sind logische Referenzen. `preis_versions` selbst referenziert weder Job noch Inbox — Housekeeping der Jobs berührt das Ledger nie |
| **Identitäten** | Inbox-Zeile und Version bekommen je eine `id uuid`. Auf der Version zusätzlich die Position (`received_at`, `zeilen_nr`), die nach dem Aufräumen der Inbox noch Job (über `received_at`) und physische Zeile im archivierten File benennt |
| **Benennung** (User 2026-10-01) | Neue Tabellen heißen wie ihre Entity: Entity singular, Tabelle Plural in snake_case — `PreisVersion` ↔ `preis_versions`, `PreisVersionSource` ↔ `preis_version_sources` (Muster `PreisMeldungZeile` ↔ `preis_meldung_zeilen`). Id-Referenzen nennen den Zieltyp (`created_preis_version_id`, `preis_meldung_zeile_id`). Das Domänen-Record heißt `PreisVersionData` (Abschnitt 5) |
| **Stammdaten** | Stand **zum Stichtag** (`findFonds(isin, preisdatum)`), `num_wfs_ku` auf jeder Version. Filter je Zeile wie bisher: LMT und Aktion `I` (kein Schlüssel), unbekannte ISIN, TEST-ISIN, C-Plan/AIF/Liquidation bei Gate „aus“ — übersprungen, auch ein `D`. Übersprungene Zeilen werden mit Grund geloggt, nicht gespeichert |
| **Währung** | Prüfung am **Eingang** (`ERR_CURRENCY04` über `tax_code.isinwaehrung = J` für `R/E/Z/S/S2/S3`, nur im Neusystem). Der Lauf kennt keine Währungsregel; bis das Flag an ist, erreichen Fremdwährungspreise das Ledger auf ihrem eigenen Schlüssel (Tracker, Todo „Währungsprüfung“) |
| **Veto** | entfällt (Klärung E3) |
| **Manuelle Eingriffe** | keine. Korrektur nur über neue Lieferung oder Wiederholung |
| **Aufbewahrung** | Produktive Preismeldungs-Jobs werden nie gelöscht. Inbox-Zeilen werden nach einem Fenster gelöscht (Tracker, Todo „Aufräumregel“); ihre Quellzeilen gehen per Cascade mit, die Versionen bleiben |
| **Sybase-Ableitung** | **Folgejob** nach dem Ledger-Commit, eigener Job, eigener Retry; nicht in diesem Plan (Abschnitt 7) |
| **Partitionierung** | später, nach `preisdatum`; jetzt nur vorbereitet (Abschnitt 7) |

---

## 2. Die Tabellen

### 2.1 `preis_meldung_zeilen` — Änderungen an der Inbox

Bestand: V061/V067 (`job_id`, `zeilen_nr`, `isin`, `preisdatum`, `waehrung`, `meldekategorie`,
`aktion`, `wert` als Text, `fondsbezeichnung`, LMT-Spalten; PK (`job_id`, `zeilen_nr`); FK auf
`jobs` ohne Cascade). Kontext `job-system`, Modul `ifas-persistence-infra`.

| Änderung | Warum |
|---|---|
| `id uuid not null`, **neuer PK**; (`job_id`, `zeilen_nr`) wird Unique-Constraint | einspaltige Identität für `preis_version_sources`. Kein Bestand: es existiert noch kein Diff-Job (geprüft 2026-10-01), die Inbox ist leer — V075 legt sie neu an; **kein Backfill**, keine Aufräum-Statements |
| `preis_version_job_id uuid null` + Index | der Claim (Abschnitt 3.2). Logische Referenz auf den `PreisVersionJob`; kein FK, damit ein gelöschter Testlauf keine Zeilen sperrt |
| `received_at timestamp(6) with time zone not null` | Position, Teil 1, **auf der Zeile** (User 2026-10-01): der Eingang kopiert `received_at` des Jobs auf jede Zeile. Die Position ist damit auf der Zeile vollständig, der Lauf braucht keinen Join auf eine Job-Tabelle; Zeilen einer Wiederholung tragen den Wert des Originals |
| Index (`isin`, `preisdatum`) | „Zeilen eines Schlüssels“ für Support-Abfragen; der Lauf selbst liest über `preis_version_job_id` |

Verhalten, das der Lauf voraussetzt:

- **Nur angenommene Zeilen.** Abgelehnte stehen in der Rückmeldung.
- **Write-once je Job** (Review B7, unverändert nötig): die Eingangsstufe schreibt Zeilen, Marker
  `eingang_completed_at`, Result-Referenz und Zähler in **einer** `job-system`-Transaktion;
  ein Retry mit gesetztem Marker wertet nicht neu aus und fasst die Zeilen nicht an. Wichtiger als
  zuvor: ein Retry, der schon **geclaimte** Zeilen ersetzte, hinterließe ungeclaimte Kopien, und
  ohne Wertvergleich würden daraus doppelte Versionen. Neu auswerten heißt Wiederholung (neuer Job).
- **Nie ein Update** außer dem Claim.

### 2.2 Spalten am Job (`preis_meldung_diff_jobs`, später ebenso der produktive Job)

Jeder Jobtyp führt seine Spalten selbst (Muster Ausschüttung), `timestamp(6) with time zone`:

| Spalte | Null | Bedeutung |
|---|---|---|
| `received_at` | nein | Ankunft der Lieferung bei IFAS nach der DB-Uhr des Job-Kontexts, gesetzt bei der Einreichung über `DatabaseContextHelper.currentDbTime()` (neu, neben `getCurrentDbUser()`, `DatabaseContextHelper:76`). **Erste Komponente der Position**; der Eingang kopiert den Wert auf jede Inbox-Zeile (2.1). Eine Wiederholung erbt den Wert des Originals. Kein Bestand (noch kein Diff-Job vorhanden, geprüft 2026-10-01); `not null` ohne Default lässt V075 auf einer nicht leeren Tabelle scheitern statt zu löschen |
| `eingang_completed_at` | ja | der Eingang ist bis zum Ende gelaufen, die angenommenen Zeilen stehen endgültig in der Inbox (write-once-Marker). Kein Bestand (s. o.) |

`verarbeitet_am` aus dem 09-24-Plan **entfällt**: der Claim je Zeile sagt, welcher Lauf sie
verarbeitet hat.

### 2.3 `preis_versions` — neu

Kontext `business-new-introduced`, Modul `ifas-persistence-fondspreise`.

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `id` | `uuid` | nein | PK |
| `isin` | `varchar(12)` | nein | Schlüsselteil, wie geliefert |
| `preisdatum` | `date` | nein | Schlüsselteil; der Stichtag als Punkt. Kein Intervall: `kurs`/`tmp_if_last` sind punktbasiert, Fill-forward ist eine Leseregel je Leser |
| `waehrung` | `varchar(3)` | nein | Schlüsselteil; Lieferwährung |
| `meldekategorie` | `varchar(2)` | nein | Schlüsselteil; `R`, `E`, `Z`, `S`, `S2`, `S3` |
| `wert` | `numeric` | nein | der Preis; **ohne Präzision und Skala** (`max_nk` ist für diese Codes null, jede feste Skala rundete still); einmal an der Grenze Inbox → Domäne geparst |
| `num_wfs_ku` | `bigint` | nein | Fonds zum Stichtag aufgelöst; Schlüssel von `kurs` |
| `created_at` | `timestamp(6) with time zone` | nein | seit wann IFAS diese Version hält; DB-Uhr, ein Wert je Lauf |
| `invalidated_at` | `timestamp(6) with time zone` | ja | `null` = offen; sonst der `created_at` des Laufs, der sie beendet hat |
| `deleted` | `boolean` | nein | `true` nur mit `invalidated_at`: beendet durch `D`. `false` = offen oder durch ein neueres `N` ersetzt |
| `open` | `boolean` | ja | `true` genau dann, wenn `invalidated_at is null`, sonst `null`. Träger des Unique-Index (siehe unten) |
| `received_at` | `timestamp(6) with time zone` | nein | Position, Teil 1: `received_at` der erzeugenden Zeile (vom Job kopiert) |
| `zeilen_nr` | `integer` | nein | Position, Teil 2: physische Zeilennummer der erzeugenden Zeile |

Indizes und Constraints:

- `ux_preis_versions_open` (`isin`, `preisdatum`, `waehrung`, `meldekategorie`, `open`) —
  höchstens eine offene Version je Schlüssel. H2 kennt keine partiellen Indizes
  (`V035__jobs_daily_run_number.sql:16-25`); NULL-Werte sind in Unique-Indizes auf Postgres und H2
  verschieden, daher die Markierungsspalte statt `where invalidated_at is null`.
- `ix_preis_versions_key` (`isin`, `preisdatum`, `waehrung`, `meldekategorie`, `created_at`)
  — Kette eines Schlüssels, Zustand zu T, Preisreihe eines Fonds.
- Check: `open = true` ⇔ `invalidated_at is null`; `deleted = true` ⇒ `invalidated_at is not null`.
- Kein FK, keine Referenz auf Jobs oder Inbox.

**Invarianten je Schlüssel** (Konstruktor der Domänen-Zeitreihe, Chunk 1):

- geordnet nach `created_at`, dann `received_at`, `zeilen_nr`;
- lückenlos: `invalidated_at` einer Version = `created_at` der nächsten, **außer** nach einer
  Löschung — dort ist die Kette unterbrochen, bis ein `N` neu öffnet;
- höchstens eine offene Version, und sie ist die letzte;
- Positionen streng steigend **innerhalb eines lückenlosen Abschnitts** der Kette (Ankunftsordnung).
  Über einen Bruch nach `deleted` hinweg darf die Position fallen: 3.4 Punkt 2 lässt eine späte
  ältere `N`-Zeile nach einem `D` neu öffnen (präzisiert 2026-10-01, Chunk 1; `PreisZeitreihe`
  prüft es so).

**Nicht in der Tabelle**, absichtlich: Fondsbezeichnung und Lieferant (Abschnitt 7), ein Grund
oder „beendet durch“ (steht in `preis_version_sources`), Zeilen für Tage ohne Lieferung, No-op-Zeilen,
übersprungene Zeilen, Zwischenwerte innerhalb eines Laufs.

Abfragen:

| Frage | Prädikat |
|---|---|
| aktueller Preis eines Schlüssels | `open = true` |
| zurückgezogen vs. nie geliefert | letzte Version des Schlüssels hat `deleted = true` vs. keine Version |
| Stand zu T | `created_at <= T` und (`invalidated_at is null` oder `invalidated_at > T`) |
| Preisreihe eines Fonds, Stand jetzt | `isin`, `open = true`, order by `preisdatum` |
| Historie eines Fonds für die Fachabteilung | alle Versionen der ISIN, order by `preisdatum`, `created_at` |
| welche Zeile hat diese Version erzeugt / beendet | `preis_version_sources` über `created_preis_version_id` / `ended_preis_version_id` |

### 2.4 `preis_version_sources` — neu

Kontext `job-system`, Modul `ifas-persistence-infra`, neben der Inbox.

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `preis_meldung_zeile_id` | `uuid` | nein | PK; FK auf `preis_meldung_zeilen(id)` **on delete cascade**. Eine Zeile kommt höchstens einmal vor |
| `operation` | `varchar(6)` | nein | `NEW`: Version geöffnet, keine beendet. `UPDATE`: eine beendet, eine geöffnet. `DELETE`: eine beendet (`deleted = true`), keine geöffnet |
| `created_preis_version_id` | `uuid` | ja | die geöffnete Version; gesetzt bei `NEW` und `UPDATE` |
| `ended_preis_version_id` | `uuid` | ja | die beendete Version; gesetzt bei `UPDATE` und `DELETE` |

Indizes auf `created_preis_version_id` und `ended_preis_version_id` (Lookup „wer hat Version X berührt“).
Die Versions-IDs sind logische Referenzen in den anderen Kontext. Geschrieben in derselben
synchronisierten Transaktion wie die Versionen, nie geändert. Zeilen ohne Wirkung haben keine
Quellzeile.

Beispiel: J1/3 liefert 101.2 und öffnet A; J2/7 liefert 101.3, beendet A, öffnet B; J3/9 ist ein
`D` und beendet B:

```
preis_meldung_zeile_id  operation  created_preis_version_id  ended_preis_version_id
J1/3                   NEW        A                   -
J2/7                   UPDATE     B                   A
J3/9                   DELETE     -                   B
```

### 2.5 Beispiel — ein Fonds, eine Woche, alle Regeln

Fonds `AT0000A00001`, EUR, `num_wfs_ku` 4711, nur `R`. Jobs J0–J7, Läufe L1–L6 mit ihrem
`created_at` (Wochentag + Uhrzeit; Do = 17.9.). Positionen als (Ankunft, Zeile).

```
Ankunft     Job  Zeile  Lieferung                       Lauf     Wirkung
Do 08:00    J0   3      N 17.9. 100.90                  L1 08:10 V0 öffnen (NEW)
Fr 08:05    J1   3      N 18.9. 101.20                  —        (kein Lauf vor J2)
Fr 08:07    J2   3      N 18.9. 101.30                  L2 08:15 V1 = 101.30 öffnen (NEW); J1/3 ist Zwischenwert, keine Version
Fr 10:05    J3   3      N 18.9. 101.35                  L3 10:15 V1 beenden, V2 öffnen (UPDATE)
Fr 15:05    J4   3      D 18.9.                         L4 15:15 V2 beenden, deleted (DELETE)
Sa, So      —    —      keine Lieferung                 —        nichts
Mo 08:10    J5   3      N 21.9. 101.90                  L5 08:20 V3 öffnen (NEW)
            J5   4      N 18.9. 101.30 (Nachlieferung)  L5       V4 öffnen (NEW; 18.9. hatte keine offene Version)
Mo 09:00    J6   3      N 21.9. 101.90 (identisch)      L6 09:10 V3 beenden, V5 öffnen (UPDATE) — kein Wertvergleich
Mo 09:02    J7   3      N 18.9. 101.20 (langsamer       L6       ignoriert: Position (Mo 09:02, 3)? nein —
                        Eingang eines Fr-Files,                  J7 erbt nichts, ist ein eigener Job; Beispiel s. u.
                        received_at Fr 08:06)
```

Der letzte Fall präzisiert: J7 ist eine Lieferung mit `received_at` **Fr 08:06** (Einreichung
Freitag), deren Eingang erst Montag abgeschlossen wurde. Sie wird von L6 geclaimt. Position
(Fr 08:06, 3) liegt **vor** dem Cursor von V4 (Mo 08:10, 4) → ignoriert, keine Version, keine
Quellzeile. Legacy hätte sie eingespielt.

`preis_versions` danach (`—` = null):

```
id  preisdatum   wert    created_at  invalidated_at  deleted  open   received_at   zeilen_nr
V0  2026-09-17   100.90  Do 08:10    —               false    true   Do 08:00      3
V1  2026-09-18   101.30  Fr 08:15    Fr 10:15        false    —      Fr 08:07      3
V2  2026-09-18   101.35  Fr 10:15    Fr 15:15        true     —      Fr 10:05      3
V4  2026-09-18   101.30  Mo 08:20    —               false    true   Mo 08:10      4
V3  2026-09-21   101.90  Mo 08:20    Mo 09:10        false    —      Mo 08:10      3
V5  2026-09-21   101.90  Mo 09:10    —               false    true   Mo 09:00      3
```

`preis_version_sources` danach:

```
zeile  operation  created  ended
J0/3   NEW        V0       -
J2/3   NEW        V1       -
J3/3   UPDATE     V2       V1
J4/3   DELETE     -        V2
J5/3   NEW        V3       -
J5/4   NEW        V4       -
J6/3   UPDATE     V5       V3
```

Ohne Zeile: J1/3 (Zwischenwert in L2), J7/3 (vor dem Cursor). Beide stehen in der Inbox mit
`preis_version_job_id` = L2 bzw. L6.

Was man sieht: Sa/So kommen nirgends vor; die Kette des 18.9. ist nach V2 unterbrochen und beginnt
mit V4 neu; V3 und V5 tragen denselben Wert und sind zwei Versionen; V3/V4 teilen `created_at`
(ein Lauf, ein Wert); die Positionen steigen je Schlüssel streng.

---

## 3. Der Verarbeitungs-Lauf

### 3.1 Auslöser

**Annahme (zu bestätigen):** der Eingang reicht nach seiner Inbox-Transaktion einen
`PreisVersionJob` als Folgejob ein (Parent-Link `jobs.parent_id`, V069; Muster `JobService:104`).
Im Parallelbetrieb ist das der `PreisMeldungDiffJob`, später der produktive Preismeldungs-Job.
Überlappende Läufe sind durch den Claim harmlos: der zweite findet nichts. Ein periodischer Lauf ist
nicht nötig; ein manueller Anstoß aus der UI (für liegengebliebene Zeilen) kann später dazukommen.

**Diff-Job-Zeilen speisen das Ledger** (Review B11): im Parallelbetrieb sind sie die einzige Quelle.
`deleteArchivedBatch` löscht ihre Inbox-Zeilen und per Cascade die Quellzeilen; die Versionen
bleiben und zeigen auf Positionen, deren Zeilen nicht mehr existieren — akzeptiert und dokumentiert.
Die Sicherung aus B11 (Löschen verweigern) entfällt, weil das Ledger keine Jobs referenziert.

### 3.2 Claim

1. **Eigene Transaktion** (`job-system`): `update preis_meldung_zeilen set preis_version_job_id = :lauf
   where preis_version_job_id is null and job_id in (select id from preis_meldung_diff_jobs where
   eingang_completed_at is not null)` — **ein** bedingtes Update, kein Select-then-Update. Commit.
   Zeilen eines Jobs ohne Marker bleiben ungeclaimt, bis der Marker gesetzt ist (User 2026-10-01;
   zuvor stand die Markerprüfung im Zurücklesen, wo eine markerlose Zeile geclaimt und nie gelesen
   worden wäre). Die Subquery nennt die Diff-Job-Tabelle; der produktive Job muss sie erweitern oder
   der Marker wandert nach `jobs`.
2. **Zurücklesen**: alle Zeilen mit `preis_version_job_id = :lauf`, geordnet nach (`received_at`,
   `zeilen_nr`) der Zeile — kein Join. Was ein paralleler Lauf vorher geclaimt hat, ist nicht dabei.
   Die Anzahl muss der Claim-Anzahl entsprechen; eine Abweichung ist ein Bug und lässt den Lauf
   scheitern.
3. **Retry-Guard**: existiert für eine dieser Zeilen bereits eine Quellzeile, hat der Lauf seine
   Faltung schon committet (Versionen und Quellen sind ein Commit) → Faltung überspringen, nur den
   Rest erledigen. Ohne Wertvergleich ist das der einzige Schutz gegen doppelte Versionen bei einem
   Retry nach dem Commit.

Muster im Code: `job_workload_items.processing_job_id` (V065) und `claimItem`
(`WorkQueueItemRepository:79`).

### 3.3 Filter je Zeile

Aus dem 09-24-Plan unverändert, Reihenfolge:

| Regel | Ergebnis |
|---|---|
| Kategorie LMT oder Aktion `I` | kein Schlüssel — fällt vor dem Filter weg |
| `findFonds(isin, preisdatum)` leer | überspringen, `WARN`; der Eingang lehnt unbekannte ISINs ab, Stammdaten können sich aber geändert haben |
| TEST-ISIN | überspringen, auch `D` |
| C-Plan, AIF, Fonds in Liquidation bei Gate „aus“ | überspringen, auch `D`; Gates per Default „speichern“ (Legacy `InsPreise*` = 1) |
| sonst | Zeile für die Faltung: Schlüssel, Aktion, `wert` (für `N` aus `new BigDecimal`, für `D` null), `num_wfs_ku`, Position, `preis_meldung_zeile_id` |

Übersprungene Zeilen bleiben geclaimt (sie sind verarbeitet), werden mit Grund geloggt
(`UNKNOWN_ISIN`, `TEST_ISIN`, `C_PLAN`, `AIF`, `FONDS_IN_LIQUIDATION`) und bekommen keine Quellzeile.

**Stammdaten-Cache:** `PreisMeldungStammdatenService` cacht `findFonds` nur nach ISIN
(`:50-51`, `computeIfAbsent(isin, …)`) — der erste Stichtag gewinnt. Für Zeilen mit
verschiedenen Preisdaten derselben ISIN muss der Cache-Schlüssel den Stichtag enthalten (Chunk 2).

### 3.4 Faltung je Schlüssel

Eingabe: die offene Version des Schlüssels (oder keine) mit ihrem Cursor; die gefilterten Zeilen
des Laufs zu diesem Schlüssel.

1. Zeilen nach Position sortieren; die **letzte** ist die Kandidatin. Alle anderen sind
   Zwischenwerte — keine Wirkung, keine Quellzeile.
2. Liegt die Position der Kandidatin **nicht nach** dem Cursor → keine Wirkung (späte ältere Zeile,
   oder dieselbe Zeile aus einer Wiederholung). Ohne offene Version gibt es keinen Cursor; dann
   zählt die Kandidatin immer. **Bewusst:** eine Version, die durch `D` beendet wurde, hat keinen
   Cursor mehr; eine späte ältere `N`-Zeile öffnet danach eine neue Version. Das ist die Folge von
   „`D` beendet, hinterlässt keine offene Version“ und wird akzeptiert.
3. Anwenden:

| offene Version | Kandidatin | Aktion | `operation` |
|---|---|---|---|
| keine | `N` | Version öffnen | `NEW` |
| keine | `D` | nichts | — |
| V | `N` | V beenden (`deleted = false`), Version öffnen | `UPDATE` |
| V | `D` | V beenden (`deleted = true`) | `DELETE` |

Die neue Version trägt `wert`, `num_wfs_ku` und die Position der Kandidatin, `created_at` des
Laufs. Kein Vergleich mit dem Wert von V.

**Tiebreak:** die Position ist (`received_at`, `zeilen_nr`), **ohne Job-ID**. Eine Wiederholung
hat dieselben Positionen wie ihr Original — genau deshalb schreibt sie nichts doppelt. Zwei
**fremde** Jobs mit identischem `received_at` (Mikrosekunden der DB-Uhr) kollidierten auf
`zeilen_nr`; das ist theoretisch, wird dokumentiert und nicht behandelt. Eine Job-ID in der Position
wäre falsch: sie machte die Zeile der Wiederholung zu einer „späteren“ und verdoppelte die Version.

### 3.5 Schreiben

Eine synchronisierte Transaktion (`@Transactional` über den `SynchronizingTransactionManager`,
REQUIRES_NEW, weil der Work-Queue-Handler schon in einer Transaktion läuft — Muster
`withJobSystemDbContextIsolatedTransactional` in `PreisMeldungDiffJobExecutionService:111`):

1. `created_at` = `currentDbTime()` im Kontext `business-new-introduced`, **einmal**.
2. Je Schlüssel in **fester Reihenfolge** (Schlüsselordnung): offene Version beenden
   (`invalidated_at`, `deleted`, `open = null`) — als bedingtes Update „noch offen“, Anzahl 1
   prüfen — und neue Version einfügen (`open = true`). Ein zweiter Insert auf einen Schlüssel
   scheitert am Unique-Index; das ist nach dem Claim nur noch ein Bug-Detektor.
3. Quellzeilen einfügen (`job-system`).
4. Commit: der Manager flusht alle enrollten Datenbanken, dann committet er sie nacheinander
   (`SynchronizingTransactionManager.doCommit`). Bei einem Key ist das ein Commit.

Danach markiert der Work-Queue-Executor den Job wie üblich. Fällt das aus, greift beim Retry der
Guard aus 3.2.

### 3.6 Wiederholungen

Kein eigener Code. `received_at` wird beim Einreichen der Wiederholung aus dem Original kopiert
(`repeatedFromJob`, `Job.java:85`; `JobRepository:54`); alles Weitere ergibt sich aus der Position
(Abschnitt 1, „Wiederholungen“).

### 3.7 Nebenläufigkeit und Fehler

| Situation | Verhalten |
|---|---|
| zwei Läufe gleichzeitig | der Claim entscheidet; der zweite liest 0 Zeilen zurück und endet leer. Auf Postgres wartet das zweite Update und wertet das Prädikat neu aus; auf H2 kann es mit Sperr-Timeout scheitern — dann Retry, ebenfalls leer |
| Abbruch nach Claim, vor Commit | die Zeilen bleiben dem Lauf zugewiesen; sein Retry faltet sie (Guard findet keine Quellzeilen) |
| Abbruch nach Commit, vor Job-Abschluss | Retry: Guard findet Quellzeilen → Faltung übersprungen. Die Zähler des Laufs committen **mit** der Faltung (Chunk 7), sonst bliebe ein so wiederholter Lauf `COMPLETED` ohne Zähler und ohne `versions_created_at` |
| Job endgültig `FAILED` | die Zeilen bleiben geclaimt und unverarbeitet — sichtbar über `preis_version_job_id` eines `FAILED`-Jobs. Freigabe (Claim nullen) ist ein Support-Eingriff; als UI-Aktion später |
| zwei db-keys (nur H2-only-Launcher) | best-effort 1PC: Commit `business-new-introduced`, dann `job-system`; ein Absturz genau dazwischen lässt Versionen ohne Quellzeilen zurück, `PartialCommitException` nennt die Seiten. Lokal, kein Design-Treiber |
| Konflikt am Unique-Index | nach dem Claim unerwartet; Ausnahme → Job `FAILED`, Retry |

Test-Blindfleck: in den Tests zeigen alle Kontexte auf dieselbe H2. Weder die Zwei-Key-Situation
noch die Cross-Context-Atomarität lässt sich dort prüfen; die Concurrency-Tests (Chunk 4) prüfen
den Claim.

---

## 4. Was die Sybase-Ableitung später vom Lauf braucht

Nicht in diesem Plan, aber der Lauf hinterlässt es bereits: alle Versionen eines Laufs tragen
seinen `created_at` als `created_at` oder `invalidated_at`. Der Folgejob bekommt diesen Stempel
(oder den Parent-Link) und findet damit die Schlüssel, die zu reconcilen sind. Ob er nur diese
Schlüssel oder alles seit einer Wasserstandsmarke abgleicht, entscheidet der Sybase-Plan.

---

## 5. Domänenmodell (Chunk 1, Sprachregelung)

Package `at.oekb.ifas.domain.fondspreise.verarbeitung`, Namen englisch außer Fachbegriffen:
(2026-10-01: Package `verarbeitung` statt `historie`; technische Wörter englisch auch in Typnamen —
`StorageGates`, `SkipReason` statt `SpeicherGates`, `UebersprungGrund`; `PreisKey` statt `PreisSchluessel`,
`PreisZeitreihe` bleibt nach dem Muster `GjZeitreihe`;
Schreibweise `PreisMeldung` wie `SteuerMeldung` (Tabelle `preis_meldung_zeilen`, Spalte
`preis_meldung_zeile_id`, direkt in V075 geändert — noch nirgends deployt, erstes Deployment am Abend des 2026-10-01;
ein lokales Postgres, das V075 schon ausgeführt hat, braucht Volume-Reset oder `flyway repair`), Records mit Suffix `Data` (`PreisVersionData`, `PreisMeldungZeileData`),
Service-Package `service.fondspreise`, Job-System-Persistenz `persistence.infra.fondspreise`; „Inbox“ nur
noch in Prosa — Gruppierung nach Stufe wie `eingang`; kein
„Inbox“ in Klassennamen, die Inbox ist der Name der Tabelle; die gefilterte Zeile heißt
`FilteredPreisMeldungZeile`, der Filter `PreisMeldungZeilenFilter`.)

- `PreisKey` — Record (`isin`, `preisdatum`, `waehrung`, `meldekategorie`), lehnt LMT ab.
- `Position` — Record (`receivedAt`, `zeilenNr`), `Comparable`.
- `PreisVersionData` — Record der Version (ohne DB-Details). `PreisVersion` ist die Entity; Muster
  `PreisMeldungZeile` (Entity) / `PreisMeldungZeileData` (Record).
- `FilteredPreisMeldungZeile` — gefilterte Zeile für die Faltung (Schlüssel, Aktion, `wert`, `numWfsKu`,
  Position, `zeileId`).
- `PreisVersionCalculator` — `fold(Optional<PreisVersionData> open, List<FilteredPreisMeldungZeile> lines)` →
  `Optional<VersionChange>` (welche Version beenden, wie, welche öffnen, welche Zeile ist die Quelle,
  `operation`). Reine Funktion, keine Persistenz (Review B13: Idee von `GjZeitreihe`, nicht die
  Struktur).
- `PreisZeitreihe` — Record der Versionen eines Schlüssels, Konstruktor prüft die Invarianten aus
  2.3 (für Tests und die UI, nicht für die Faltung).
- `PreisMeldungZeilenFilter` — Utility, Regeln aus 3.3; `SkipReason` als Enum.

Vom Branch `feat/fondspreise-sync` übernommen (Steinbruch, nicht gemergt): die Logik von
`PreismeldungSyncDecisions.excludedBy` und ihr Test für den Filter; `FondspreiseProperties` mit nur
den drei `store*`-Gates. **Entfallen**: `PriceGroup`, `SyncDecision`, `SyncOperation`,
`marksKorrektur`, `preis_herkunft`, `letzte_preise`, `PreismeldungSyncService`,
`LetztePreiseService`, `PreismeldungDbDiff` (später mit dem generischen Tabellenvergleich).

---

## 6. Flyway

**Geprüft 2026-09-30** nach `flyway-versions-after-merge.md`: `master`/`origin/master` enden bei
**V073**, `origin/stable` und `origin/production` bei V064, höchster Sibling `origin/pul/master`
V071, `origin/ausschuettung` V066; `origin/feat/fondspreise-sync` trägt V067–V069, die nie deployt
wurden und entfallen. → **V074** in beiden Bäumen, `sybase16/` als No-op mit Kommentar (wie V061/V063).
Vor dem Merge erneut prüfen und hier datiert vermerken.

**Erneut geprüft 2026-10-01** (Start Chunk 3/Persistenz): nach `git fetch` enden `master`/`origin/master`
weiter bei V073, `origin/stable`/`origin/production` bei V064, kein `origin/*`-Zweig über V073 → V074 bleibt.

**Kollision am selben Tag:** `master` hat danach `c4325d704` (`V074__jobs_payload.sql`, JSON-Payload
am Job) aufgenommen; Flyway meldete „Found more than one migration with version 074“. Das
Feature-Script ist noch nicht committet und wurde nach der Merge-Regel auf **V075** umbenannt (beide
Bäume, Flyway-Modul mit `clean` neu installiert).

Eine Migration für das ganze Feature (`flyway-one-file-per-feature.md`): Inbox-Änderungen,
Job-Spalten, `preis_versions`, `preis_version_sources`, Grants, Indizes. `timestamp(6) with time
zone`, nicht `timestamptz`. Nach dem Anlegen: `mvn -Pno-proxy install -pl
ifas-database/ifas-database-flyway`, sonst testet man das alte Jar.

---

## 7. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **Ableitung nach `kurs`** | Folgejob nach dem Ledger-Commit (Abschnitt 4). Reconcile je Schlüssel: offene Version mit Wert ⇒ `kurs`-Zeile mit diesem Wert (delete-then-insert je Code wie Legacy); letzte Version `deleted` ohne offene Nachfolgerin ⇒ keine `kurs`-Zeile. Idempotent, eigener Retry, Sybase = eigener db-key. **Entschieden 2026-10-08 (User): optional und konfigurierbar** — zwei Schalter: eine Property, ob das Deployment überhaupt synct (lokal/H2, TEST ohne Neusystem-Sybase: aus), und der auslösende Job, ob er den Sync will — der `PreisMeldungDiffJob` nie (wie Mail und MFT-Upload), der produktive Job ja; Muster `persistResult`/`triggerPreisVersionJob`. Der `PreisVersionJob` reicht den Sync als Folgejob nach dem Commit der Faltung ein, nur wenn beide Schalter ja sagen. Der Sync hat damit bis zum produktiven Job keinen Aufrufer: standalone bauen und testen, Verdrahtung kommt mit ihm. Folge: im Parallelbetrieb bekommt die Neusystem-Sybase keine `kurs`/`tmp_if_last`-Zeilen; wie D13 diese Tabellen vergleicht (Ledger projiziert gegen Alt-`kurs` oder erst mit dem produktiven Job auf TEST) ist **vertagt**. **Plan geschrieben 2026-10-08:** [2026-10-08-fondspreise-preis-version-sync-kurs.md](2026-10-08-fondspreise-preis-version-sync-kurs.md) |
| **Ableitung nach `tmp_if_last`** | ein Platz je (`isin`, `waehrung`, `meldekategorie`): offene Version mit höchstem `preisdatum`. Spaltenquellen (User 30.09.): `eintragezeit` aus `created_at` oder `received_at` (Legacy: Ankunft → `received_at` diffts sauberer), `txt_bez` aus den Stammdaten (bekannte Abweichung zu „wie geliefert“, bis Klärung O), `liefer_id` = Lieferant — nur der Job kennt ihn (Klärung J: Stammdaten sagen es nicht) |
| **Lieferant auf der Version** | offen: Kopie auf `preis_versions` (Eigenschaft der Version, überlebt das Job-Housekeeping) oder Hop über `preis_version_sources` → Inbox → Job. Nachrüstbar, solange die Inbox-Zeilen leben |
| **Partitionierung nach `preisdatum`** | Postgres verlangt den Partitionsschlüssel in jedem Unique-Constraint → PK würde (`preisdatum`, `id`); der Unique-Index enthält `preisdatum` schon. H2 kennt keine Partitionierung → `${pg-only}`-DDL. Ob das Ledger je beschnitten wird, ist fachlich: Legacy beschneidet `kurs` nie (42,6 Mio Zeilen seit 1994) |
| Sammelreport (Schnitt 4/5) | liest offene Versionen und das Publikationsprotokoll |
| Fehlmeldung (Schnitt 7) | Anti-Join auf offene Versionen; „letzte Version `deleted`“ = zurückgezogen |
| Kennzahlen-Invalidierung | ausgelöst durch das Beenden einer `R`-Version |
| Aufräumen der Inbox-Zeilen, Freigabe geclaimter Zeilen `FAILED`-Läufe | Todo Tracker; UI-Aktionen |
| Währungsflag im Neusystem | Todo Tracker (erst messen) |
| Javadoc `PreisMeldungZeile` („kept as text to preserve the delivered precision …“) | Begründung falsch (Legacy formatiert aus `float`); in Chunk 3 korrigieren |

---

## 8. Chunks

Reihenfolge = Abhängigkeit. Chunks 1 und 2 sind reine Domäne ohne DDL.

### Chunk 1 — Domäne: Faltung je Schlüssel

- **Inhalt:** Abschnitt 5 ohne den Filter: `PreisKey`, `Position`, `PreisVersionData`,
  `FilteredPreisMeldungZeile`, `VersionChange`, `PreisVersionCalculator`, `PreisZeitreihe`.
- **Tests** (Given-When-Then, AssertJ): die Tabelle aus 3.4 Zeile für Zeile; Zwischenwert im
  selben Lauf (nur die letzte Zeile wirkt); späte ältere Zeile vor dem Cursor (keine Wirkung);
  dieselbe Position aus einer Wiederholung (keine Wirkung); `D` ohne offene Version (No-op);
  `N` nach `D` öffnet neu, auch mit älterer Position; gleicher Wert erzeugt eine Version;
  Sortierung innerhalb eines Jobs nach `zeilen_nr`; Invarianten der `PreisZeitreihe` (Kette, eine
  offene, Positionen steigend, Bruch nach `deleted` erlaubt); Beispiel 2.5 als Ganzes.
- **Fertig, wenn:** jede Regel aus 3.4 einen Test hat.
- **Stand 2026-10-01:** umgesetzt (Package `verarbeitung`: `PreisKey`, `Position` (UTC-normalisiert),
  `PreisVersionData`, `FilteredPreisMeldungZeile`, `VersionChange` als ein Record mit `Operation`-Enum,
  `PreisVersionCalculator`, `PreisZeitreihe`; 55 Tests inkl. Replay von 2.5), Commit `aa8eaedb6`.

### Chunk 2 — Domäne: Filter je Zeile

- **Inhalt:** `PreisMeldungZeilenFilter`, `SkipReason`, Gates-Record aus `FondspreiseProperties`
  (nur `store*`); Cache-Schlüssel in `PreisMeldungStammdatenService` um den Stichtag erweitern.
- **Tests:** je Regel einer, mit `N` und `D`; drei Gates an/aus; unbekannte ISIN; `numWfsKu` zum
  Preisdatum; `wert` für `N` geparst, für `D` null; dieselbe ISIN mit zwei Preisdaten und
  verschiedenem `num_wfs_ku` aus `wkn_hist`.
- **Stand 2026-10-01:** umgesetzt (`StorageGates`, `SkipReason`, `PreisMeldungZeilenFilter` mit sealed
  `Result` Passed/Skipped/NoKey auf `PreisMeldungZeileData` + (`zeileId`, `receivedAt`);
  `FondspreiseProperties` mit drei `store*`-Gates; Stammdaten-Cache je (ISIN, Stichtag) mit
  Integrationstest H2 + Postgres), Commit `457446d83`. NoKey gilt für jeden Code außer R/E/Z/S/S2/S3;
  der CSV-Typ `PREIS_MELDEKATEGORIE` lässt ohnehin nur die neun Enum-Werte durch.

### Chunk 3 — Persistenz: eine Migration, Entities, Eingang write-once

- **Migration V075** (Abschnitt 6): Inbox neu anlegen (leer; kein Diff-Job vorhanden) mit `id` als PK, Unique (`job_id`, `zeilen_nr`), `processing_job_id` (in V076 umbenannt zu `preis_version_job_id`)
  und Indizes; `received_at`/`eingang_completed_at` am Diff-Job ohne Backfill; `preis_versions` mit Indizes und Checks; `preis_version_sources` mit
  Cascade-FK und Indizes; Grants.
- **Entities/Repositories:** `PreisMeldungZeile` auf `@Id uuid` umstellen (`PreisMeldungZeileId`
  entfällt), `received_at` auf der Zeile, Claim-Update mit Markerbedingung und „Zeilen eines Laufs“
  ohne Job-Join; `PreisVersion` + Repository (offene
  Version je Schlüssel, Kette je Schlüssel, bedingtes Beenden mit Anzahl, Versionen einer ISIN);
  `PreisVersionSource` + Repository (existiert für Zeile, nach Versions-ID).
- **Helfer:** `DatabaseContextHelper.currentDbTime()` (`select current_timestamp` über das
  Routing-`JdbcTemplate`; Postgres/H2).
- **Eingang write-once** (Review B7): `PreisMeldungDiffJobExecutionService.executeDiff` — heute
  Inbox-Transaktion (`:111-113`), dann Filestore, dann `updateResult` (`:136`); neu: auswerten →
  Bundle bauen und speichern → **eine** Transaktion (Zeilen, `eingang_completed_at`,
  Result-Referenz, Zähler). Marker gesetzt → alles überspringen. `submit` setzt `received_at`;
  der Wiederholungspfad kopiert es aus dem Original.
- **Tests** (Multi-DB, H2 + Postgres; Sybase entfällt): Unique der offenen Version greift;
  bedingtes Beenden liefert 0 bei schon beendeter Version; Cascade Inbox → Quellzeile; `wert` mit
  12 Nachkommastellen kommt unverändert zurück; Claim-Update ist bedingt (zweiter Claim bekommt 0);
  `PreisMeldungDiffJobTest`: Retry mit Marker lässt Inbox und Marker unverändert, ohne Marker
  ersetzt er.
- **Vorher:** Flyway-Modul installieren.

**Stand 2026-10-01 — Persistenzhälfte umgesetzt, Commit `b137e7724`** (V075, Entities, Repositories, `currentDbTime()`,
Multi-DB-Tests H2 + Postgres grün). **Stand 2026-10-06 — Eingang write-once umgesetzt, Commit `01ec25fb6`:**
Markerprüfung vor dem Filestore-Zugriff, eine REQUIRES_NEW-Transaktion `deleteByJobId → saveAll → updateResult →
markEingangCompleted(currentDbTime())`; der Marker wird **bedingt** gesetzt (`… AND eingangCompletedAt IS NULL`,
Rückgabe 0 → Ausnahme → Rollback), damit zwei gleichzeitige Ausführungen desselben Jobs nicht beide committen.
`PreisMeldungDiffJobTest` läuft jetzt auf H2 + Postgres (Marker + Claim, Retry mit/ohne Marker, bedingter Marker).
Für den Diff-Job gibt es keinen Wiederholungspfad; „die Wiederholung erbt `received_at`" gilt erst für den produktiven
Job. Befunde für die Folge-Chunks:

- **Bestand:** keiner — `preis_meldung_diff_jobs` ist auf allen Stages leer (User 2026-10-01); V075
  enthält keine Aufräum-Statements und scheitert auf einer nicht leeren Tabelle. Diff-Jobs, die nach V075 und vor dem write-once-Schritt laufen, haben keinen Marker und
  bleiben ungeclaimt (die Markerbedingung steht im Claim) — unkritisch, wenn Chunks 3–5 gemeinsam
  deployt werden.
- **Die Markerbedingung im Claim nennt `preis_meldung_diff_jobs`.** Kommt der produktive Job (2.2
  „später ebenso“), muss die Subquery ihn mit abdecken oder der Marker wandert nach `jobs`. Das
  Zurücklesen braucht seit 2026-10-01 keinen Job-Join mehr: `received_at` steht auf der Zeile.
- **`PreisVersionSource` hat eine zugewiesene Id:** Spring Data `save()` macht daher ein
  `merge` (SELECT vor jedem INSERT). Für das Schreiben in Chunk 4 `persist` bzw. `Persistable`
  verwenden.
- **`wert` auf H2:** bare `numeric` wird DECFLOAT — Wert exakt, Skala kann nachgestellte Nullen
  verlieren; Postgres hält die gelieferte Skala. Vergleiche mit `compareTo`.

### Chunk 4 — Service: der `PreisVersionJob`

- **Inhalt:** Job-Typ `PreisVersionJob` (Entity, Submission, Execution, Work-Queue-Handler,
  Dispatcher-Zweig) nach dem Muster der bestehenden Jobs; Ablauf 3.2 → 3.3 → 3.4 → 3.5 mit
  Retry-Guard; Zähler am Job (Zeilen geclaimt, gefiltert je Grund, Versionen geöffnet/beendet,
  ignoriert vor dem Cursor).
- **Tests** (Integration, Multi-DB): Beispiel 2.5 end to end über echte Jobs; zwei Läufe
  **nebenläufig** auf denselben ungeclaimten Zeilen → genau ein Lauf schreibt, der andere endet
  leer oder mit Ausnahme (Typ nicht prüfen, Review B10); Retry nach Commit schreibt nichts
  doppelt; Wiederholung eines Jobs schreibt nichts doppelt; Wiederholung mit jetzt angenommener
  Zeile schreibt nach Ankunftsordnung; `FAILED`-Lauf lässt Zeilen geclaimt.

**Stand 2026-10-06 — umgesetzt**, Commits `5e5b7056c` (Job) und `1f98514a2` (Claim-Spalte), gepusht (Opus-Subagent, Review Fable): `PreisVersionJob`
(Name entschieden 2026-10-06: das Produkt, nicht die Stufe — „Verarbeitung“ ist der Überbegriff für
Stufe 2 samt späterer Einspielung), Tabelle `preis_version_jobs` (V076; Flyway-Check 2026-10-06:
`origin/master` V075, `stable`/`production` V064, höchster Sibling `origin/pul/master` V071),
`versions_created_at` + 11 Zähler, `PreisVersionJobSubmissionService.submit(createdBy)`,
`PreisVersionJobExecutionService` (`maxAttempts` 3), `PreisVersionRepository.findOpenVersions` (Bulk),
V076 benennt außerdem die Claim-Spalte um: `processing_job_id` → `preis_version_job_id`.
`PreisVersionJobTest` (H2 + Postgres, 16): Beispiel 2.5 end to end, zwei Läufe nebenläufig, Retry nach
Commit, scheiternder Lauf behält den Claim, Cross-Context-Rollback, leerer Lauf, Zähler.
**Abweichung vom Plan, übernommen:** nur der **erste Versuch** eines Laufs claimt; ein Retry arbeitet auf
den schon geclaimten Zeilen (sonst würde ein Retry nach committeter Faltung inzwischen angekommene Zeilen
claimen, am Guard scheitern und sie für immer liegen lassen) — Abschnitt 3.2 entsprechend lesen.
Unbekannte ISIN wird mit `WARN` geloggt, übrige Skips mit `debug` (User 2026-10-06). Offen: kein Index, der mit `created_at`/
`invalidated_at` beginnt (der Einspielungs-Job sucht die Zeilen eines Laufs darüber — im Sybase-Plan
entscheiden); Freigabe geclaimter Zeilen eines `FAILED`-Laufs (Tracker-Todo). Befunde außerhalb des
Chunks: `with…IsolatedTransactional` enrollt den aktuellen Kontext des Aufrufers eifrig (leere
Zusatztransaktion, im Deployment Sybase); das Javadoc von `currentDbTime()` verspricht „gleicher Wert
in einer Transaktion“, das `JdbcTemplate` nimmt aber eine eigene Connection.

### Chunk 5 — Auslöser

- **Inhalt:** Einreichung des `PreisVersionJob` als Folgejob aus dem Eingang (3.1, Parent-Link);
  `maxAttempts` > 1 für den Handler.
- **Tests:** Eingang `COMPLETED` → `PreisVersionJob` existiert mit Parent; Eingang `FAILED` → keiner.

**Stand 2026-10-06 — umgesetzt**, Commit `19dfc41d6`, gepusht (Opus-Subagent, Review Fable): jede **erfolgreiche**
Ausführung des Eingangs reicht einen `PreisVersionJob` als Folgejob ein (Parent-Link über
`JobExecutionContext`), auch auf dem Marker-gesetzt-Pfad (selbstheilend: ein zweiter Lauf claimt nur
Ungeclaimtes). Schalter je Job: `PreisMeldungDiffSetting.triggerPreisVersionJob` (Default `true`;
altes JSON ohne das Feld liest `true` über einen `@JsonCreator`; Lombok-Builder-Default ist `false` —
jeder Builder-Aufrufer muss es setzen). `ifas13-jobs.md`: Abschnitt `PreisVersionJob` ersetzt die alte
Stufe-2-Beschreibung. **Befund und Fix:** das Löschen archivierter Diff-Jobs scheiterte an
`fk_wq_parent`/`fk_jobs_parent`, sobald ein Folgejob existiert — `deleteArchivedBatch` löst die Kinder
vorher (`JobRepository.nullifyParentReferences`, `WorkQueueItemRepository.nullifyParentReferencesBy…`);
die Läufe bleiben ohne Parent, ihre geclaimten Zeilen gehen mit dem Eingang, die Versionen bleiben.
Tests (H2 + Postgres, 66): Kette end to end, scheiternder Eingang reicht nichts ein, erneute Ausführung
reicht erneut ein, Löschen mit Folgejob; alle Tests, die Läufe selbst steuern, schalten den Trigger ab.
**Nicht erfüllt:** „`maxAttempts` > 1 für den Handler" gilt nur für den `PreisVersionJob` (3); der
Eingang bleibt bei 1, der selbstheilende Pfad greift erst nach manuellem Zurücksetzen auf PROCESSING.

### Chunk 6 — UI: Preisversionen (bis 2026-10-08 „Preishistorie")

- **Inhalt:** Seite je ISIN (alle Versionen, `preisdatum`, Wert, `created_at`/`invalidated_at`,
  `deleted`, Position; Quelle über `preis_version_sources` mit Link auf Job und Zeile, „Zeile nicht
  mehr in der Inbox“ wenn aufgeräumt); Einstieg von der Job-Detailseite (Schlüssel der Lieferung)
  und über eine ISIN-Suche unter *Testen*. Grenzen der Web-UI: kein npm/CDN, nur `~{::section}`.
- Kann direkt nach Chunk 4 kommen.
- **Entscheidungen 2026-10-06:** Seite `/ui/preis-versionen`, Titel **Preishistorie** (die Lesart von
  `preis_versions`), Menü unter *Testen*, neues Recht `PREIS_VERSIONEN` (IFAS_INTRA_USER,
  IFAS_INTRA_SYSTEMSUPPORT — Rollen müssen provisioniert werden). **Zwei Karten** je ISIN (optional
  Preisdatum, „nur offene"): *Gelieferte Zeilen* — alle angenommenen Inbox-Zeilen der ISIN über alle
  Jobs in Ankunftsordnung, auch LMT, Nachlieferungen, Zwischenwerte, mit Job, Claim-Zustand und Wirkung
  (`NEW`/`UPDATE`/`DELETE`/keine); *Versionen* — die Kette mit Status offen/ersetzt/gelöscht, Position
  und den zwei Quell-Links („Zeile nicht mehr in der Inbox" nach dem Aufräumen). Die Zeilen sind die
  Lieferketten-Transparenz der Fachabteilung (01.09.), die Versionen der Preisstand.
  **Umsetzung in zwei Teilen:** 6a Query-Service + Seite + Recht + Navigation; 6b Diff-Job-Detailseite
  (Wirkung je Zeile, Karte *Folgejobs*) + Detailseite `PreisVersionJob` (Zähler, Stempel, Parent) in
  `JobDetailPages`. Die Versionen eines Laufs werden auf der Laufseite **noch nicht** gelistet (braucht
  den Index auf `created_at`/`invalidated_at`, Entscheidung im Einspielungs-Plan).
- **Benennung (2026-10-06, geändert 2026-10-08):** Seitentitel und Menüpunkt heißen seit 2026-10-08
  **Preisversionen** — kein „Historie" mehr in der UI, auch nicht in Template-Parametern oder
  Kommentaren (User: „no more historie in the UI"); Java-Typen nach der
  Tabelle mit englischem Plural (`PreisVersionsView`, `PreisVersionsPageController`,
  `findPreisVersions`), URL/Recht/Template/`canAccess…` nach dem Recht (`/ui/preis-versionen`,
  `PREIS_VERSIONEN`, `preis-versionen.html`, `canAccessPreisVersionen()`).
- **Stand 2026-10-06 — 6a umgesetzt**, Commit `83c58848b` (gepusht nach Merge von `origin/master`
  `0bc0721c0`, SQL-Console-Feature mit V077): `PreisVersionQueryService.findPreisVersions` →
  `PreisVersionsView` (Zeilen mit Job/Claim/Wirkung, Versionen mit Status und zwei Quellen; drei
  Bulk-Reads, Join im Speicher), `PreisDataConversions` (aus dem `PreisVersionJobExecutionService`
  herausgezogen), Seite `/ui/preis-versionen` mit beiden Karten, Recht `PREIS_VERSIONEN` (Rollen
  provisionieren!), Menü *Testen*. Tests: Query-Service 6 × H2/PG, Seite 3 (echte Templates),
  Autorisierung.
- **Stand 2026-10-06 — 6b umgesetzt**, Commit `b9a1840de`, gepusht: Diff-Job-Detailseite zeigt je Inbox-Zeile
  *Verarbeitung* (noch nicht verarbeitet / Link auf den Lauf) und *Wirkung* (neu / ersetzt / gelöscht,
  Link in die Preishistorie mit Anker); die Folgejobs standen schon als Karte „Teilaufgaben" da
  (`42dcbb43b`). Detailseite `/ui/preis-version-jobs/{id}` (`PreisVersionJobDetailPageController
  implements JobDetailPage`, `PreisVersionJobQueryService.findById`): Parent-Banner, Karte *Lauf*
  (`versions_created_at`), Karte *Zähler*; Pfad im Recht `PREIS_VERSIONEN`. Gemeinsames Fragment
  `fragments/preis-zeile.html` für beide Seiten, `ThymeleafPageTestBase` für Render-Tests.
  `PreisVersionQueryService.findZeilenOfJob(jobId)`. Tests: Query-Service 7 × H2/PG, drei
  Seiten-Render-Tests, Autorisierung 50. Toolbar der Laufseite nur mit dem generischen
  „Zur Aufgaben-Liste" (kein eigener Listenfilter-Link).

### Chunk 7 — Verschränkungs-Tests: zwei Server, ein Lauf nimmt alles

- **Frage (2026-10-08):** Zeilen mehrerer Lieferungen landen in genau einem Lauf; was genau passiert
  bei Wiederholung, Fehlschlag, Absturz und Waisen-Erkennung auf dem anderen Server? Die Tests aus
  Chunk 4 lassen das Rennen zweier Läufe offen (wer claimt, ist Zufall) und kennen keinen zweiten
  Server. Hier wird jede Verschränkung **deterministisch** gestellt — keine Wanduhr, keine Sleeps.
- **Mittel:**
  - **Zwei Server** = zwei handgebaute `WorkQueueExecutor` mit eigenem `ServerIdProvider`
    (`server-a`, `server-b`), eigenem `WorkQueueProperties` (`claimSize` 1, Auto-Retry aus,
    Waisen-Erkennung nur wo gefragt) und eigenem Thread-Modell (A auf eigenem Thread, B synchron im
    Test). Muster: `WorkQueueExecutorIntegrationTest.createExecutor`. Extension `TEST_WITH_H2_AND_POSTGRES`
    **ohne** Work-Queue-Profil: kein Spring-Executor pollt mit, keine Server-Affinität
    (`always-execute-on-submitting-node` nur im Profil `work-queue`).
  - **Hooks im Service:** `PreisVersionJobHooks` mit `afterClaim`, `beforeWrite`, `afterWrite`,
    No-op `NONE` in der Produktionsverdrahtung, kommentiert als reine Test-Naht (User 2026-10-08:
    „no op hooks are fine, but comment accordingly"). Der Test baut sich eine eigene
    `PreisVersionJobExecutionService`-Instanz mit Latch-/Fehler-Hooks und hängt sie als Handler in
    seine Executoren. Absturz = Hook wirft; Waise = Heartbeat des Items alt gestellt.
  - **Befund, mit behoben:** ein Retry nach committeter Faltung kehrt am Guard um und schreibt die
    Zähler nicht — der Lauf endete `COMPLETED` mit leeren Zählern. Jetzt committen `updateResult`
    und die Faltung in derselben Transaktion (3.7 angepasst).
- **Szenarien** (eine Klasse `PreisVersionJobInterleavingTest`, H2 + Postgres):
  1. Zwei Lieferungen, zwei Läufe; A nach dem Claim eingefroren → B endet mit 0 → A faltet beide
     Lieferungen (gleicher Schlüssel: späterer Wert gewinnt, frühere Zeile ohne Wirkung).
  2. A nach dem Claim eingefroren, B endet leer, A scheitert **vor** dem Schreiben → Zeilen bleiben
     bei A, keine Versionen; Retry von A faltet ohne neuen Claim; eine inzwischen angekommene Zeile
     wartet auf den nächsten Lauf (auf B).
  3. A scheitert **nach** dem Commit der Faltung → Retry schreibt nichts doppelt, Zähler und
     `versions_created_at` sind gesetzt (vor dem Befund: null).
  4. A scheitert dreimal → Job `FAILED`, Zeilen bleiben geclaimt, keine Versionen; späterer Lauf auf
     B claimt 0, eine neue Lieferung wird vom nächsten Lauf allein verarbeitet.
  5. A nach dem Claim eingefroren, Heartbeat alt → B erkennt die Waise, führt Versuch 2 aus und
     schreibt; A aufgetaut läuft in den Guard (5a) bzw. — vor dem Schreiben eingefroren — in den
     Unique-Index/PK (5b): Hauptbuch unverändert, genau eine offene Version je Schlüssel, Item und
     Job `COMPLETED`.
  6. Zwei Eingänge im selben Poll-Zyklus auf zwei Servern, jeder reicht einen Lauf ein → der zuerst
     geclaimte Lauf nimmt die Zeilen beider Lieferungen, der andere endet leer; Parent-Links stimmen.

- **Stand 2026-10-08 — umgesetzt**, Commits `cd45f5c3d` (Fix: Zähler committen mit der Faltung) und
  `3bb108df6` (Hooks + Tests), gepusht (Opus-Subagent, Review Fable): `PreisVersionJobHooks`
  (`NONE` in der Spring-Verdrahtung, zweiter Konstruktor für den Test), `updateResult` läuft als
  `Consumer` in der Schreibtransaktion (Mutationstest: ohne die Änderung scheitert Szenario 3 mit
  elf `null`-Zählern). `PreisVersionJobInterleavingTest` (7 Szenarien × H2/Postgres, 4 Läufe ohne
  Flackern): Server A auf eigenem Thread (Warten über das `Future` des Dispatch), Server B synchron
  im Test; Run B wird in 1/2 erst nach dem Einfrieren von A eingereicht (Gleichstand auf `createdAt`
  vermeiden); ein Freeze blockt nur den ersten ankommenden Lauf, Retries und Versuch 2 auf B passieren.
  Gemeinsame Helfer nach `PreisVersionJobTestSupport` (`@Component` im Testpaket, Muster
  `WorkQueueTestHelper`) gezogen, `PreisVersionJobTest`/`PreisMeldungDiffJobTest` nutzen sie.
  Beobachtet, nicht geprüft: der Zombie-Versuch von A überschreibt im `finally` das Ausführungslog
  des Items, das B geschrieben hat. Unverändert und so gepinnt: ein auf jedem Versuch scheiternder
  Lauf endet `FAILED` mit leeren Zählern; seine Zeilen bleiben geclaimt (Freigabe weiterhin offen).

---

## 9. Ersetzte Dokumente

Dieser Plan ersetzt in `plans/fondspreise/`:

| Dokument | Status |
|---|---|
| `2026-09-24-fondspreise-preis-historie-zeitreihe.md` + `-review.md` | ersetzt (Sicht-Kette mit D-Zeilen, Cursor-Faltung mit Verdrängung, `verarbeitet_am`) |
| `2026-09-17-fondspreise-preis-ledger-formen.md`, `-er-diagramme.md`, `.deck.html` | ersetzt (Formen A/B/C; Ergebnis: A mit Endreferenz über `preis_version_sources`) |
| `2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md`, `2026-09-10-…-ap4-review-fixes.md` | ersetzt für Stufe 2 (`preis_herkunft`, `letzte_preise`, Klammer-Transaktionen entfallen); Schnitt 1 bleibt wie umgesetzt |
| `2026-08-31-fondspreise-neuentwicklung-konzept.md` + Deck | bleibt als Konzept; Abschnitt *Stufe 2* dort ist überholt und verweist hierher (nachziehen) |
| `tracker.md` | bleibt; Schnitt-2-Zeile und Runde 11 nachziehen |

Aufräumen (Archivierung der ersetzten Dateien) ist ein eigener Schritt nach diesem Plan.

---

## Quellen

| Aussage | Fundstelle |
|---|---|
| Inbox heute: PK (`job_id`, `zeilen_nr`), FK auf `jobs` ohne Cascade | `V061__preismeldung_zeilen.sql`, `V067__preismeldung_zeilen__job_fk.sql`, `PreisMeldungZeile.java`, `PreisMeldungZeileId.java` |
| Diff-Job-Spalten | `V063__preis_meldung_diff_jobs.sql`, `PreisMeldungDiffJob.java` |
| `kurs`/`tmp_if_last` auf master | `V073__kurs_tmp_if_last.sql`, `Kurs.java`, `TmpIfLast.java` (`5d22c157c`) |
| Claim-Muster | `V065__ausschuettung_processing.sql` (`processing_job_id`), `WorkQueueItemRepository:79` (`claimItem`) |
| Parent-Link für Folgejobs | `V069__jobs_parent.sql`, `JobService:104`, `OrchestrationJobHelper:81` |
| Wiederholung | `Job.java:85` (`repeatedFromJob`), `JobRepository:54`, `PreisMeldungDiffJobRepository:48` |
| Synchronisierte Transaktion: flush all, commit nacheinander, `PartialCommitException`; ein Key = ein Enroll | `SynchronizingTransactionManager.java` (`enrollDatabase`, `doCommit`) |
| db-keys je Profil: Deployment und lokale Postgres-Profile ein Key, H2-only zwei | `application-server-deployment.properties:24,43`; `application-local-postgres-and-sybase.properties:16,33`; `application-local-sybase-gast-and-postgres.properties:16,33`; `application-local-h2-only.properties:18,35` |
| Eingang schreibt Inbox-Transaktion → Filestore → `updateResult` | `PreisMeldungDiffJobExecutionService:111-113`, `:136` |
| Stammdaten-Cache nur nach ISIN | `PreisMeldungStammdatenService:50-51` |
| `${pg-only}`/`${h2-only}` | `DbConfigs:66-90`, `V068__jobs_timestamps_with_time_zone.sql` |
| Keine partiellen Indizes in H2 | `V035__jobs_daily_run_number.sql:16-25` |
| Routing-`JdbcTemplate` für `currentDbTime()` | `DatabaseContextHelper:40,76` |
| Legacy: letzte Zeile gewinnt; `kurs` delete-then-insert; `tmp_if_last` ein Platz je (ISIN, Whg, Code) | Formen-Dokument 0a (`c_insert.cpp:1962`, `preisekennzahl.cpp:719`, `:1226-1345`) |
| Filterregeln, Gates, TEST-ISIN | 09-24-Plan 3.3 (`calculation.cpp:196-204`, `ins_wp_art_f.cr:41-42`) |
| Flyway-Stand | `git ls-tree` auf `master`, `origin/master`, `origin/stable`, `origin/production`, alle `origin/*`, 2026-09-30 |
