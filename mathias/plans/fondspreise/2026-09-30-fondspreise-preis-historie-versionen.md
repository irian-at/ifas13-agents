# Fondspreise — `preis_historie`: Versionen je Preisschlüssel, Verarbeitung aus der Inbox

Stand 2026-09-30. Ergebnis der Diskussion vom 30.09. Dieses Dokument ist die **verbindliche
Fassung** des Preis-Ledgers und ersetzt alle früheren Entwürfe dazu (Abschnitt 9). Was hier nicht
steht, ist nicht entschieden.

**Scope:** korrekte, vollständige Daten in `preis_historie` samt Herkunft. Die Ableitung nach
`kurs` und `tmp_if_last` ist **nicht** Teil dieses Plans; sie wird ein eigener Folgejob nach dem
Ledger-Commit (Abschnitt 7). Die Entities `Kurs`/`TmpIfLast` liegen seit `5d22c157c` (V073) auf
`master` und bleiben bis dahin ungenutzt.

**Umsetzung in Chunks** (Abschnitt 8): jeder Chunk ist ein eigener Commit auf `master`, baut, hat
seine Tests und verbessert den Stand, ohne auf den nächsten zu warten.

---

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Schlüssel** | (`isin`, `preis_datum`, `waehrung`, `meldekategorie`) — ein Preis eines Fonds zu einem Stichtag in einer Währung und Kategorie. `meldekategorie` nur `R`, `E`, `Z`, `S`, `S2`, `S3`; LMT erreicht das Ledger nie |
| **Version** | eine Zeile in `preis_historie`: ein Zustand, den IFAS für einen Schlüssel gehalten hat, mit Beginn und (falls beendet) Ende |
| **offene Version** | die Version eines Schlüssels mit `invalidated_at is null`; höchstens eine je Schlüssel |
| **N / D** | die Aktion einer Inbox-Zeile: liefern bzw. aktualisieren (`N`) oder zurückziehen (`D`) |
| **Lauf** | eine Ausführung des Verarbeitungs-Jobs, der Inbox-Zeilen zu Versionen faltet |
| **Position** | (`empfangen_at`, `zeilen_nr`) einer Zeile: Ankunft der Lieferung nach der DB-Uhr, dann physische Zeilennummer im File. Die Ordnung der Faltung |
| **Cursor** | die Position, die die offene Version eines Schlüssels trägt — die Position der Zeile, die sie erzeugt hat |
| **Claim** | die bedingte Zuweisung noch nicht verarbeiteter Inbox-Zeilen an einen Lauf (`processing_job_id`) |
| **wirksame Zeile** | eine Inbox-Zeile, die in einem Lauf eine Version erzeugt oder beendet hat |
| **Kontexte** | `job-system` (Jobs, Inbox, `preis_historie_source`) und `business-new-introduced` (`preis_historie`); im Deployment beide `postgres-server` |

---

## 1. Entscheidungen

| Thema | Entscheidung |
|---|---|
| **Rollen der Tabellen** | Die **Inbox** `preismeldung_zeilen` ist das Operation-Log: jede angenommene Zeile, wie geliefert, write-once je Job, für Support-Fälle durchsuchbar. `preis_historie` hält **nur Operationen, die die Zeitreihe eines Schlüssels verändert haben** — eine Zeile je Version. `preis_historie_source` verbindet beide: eine Zeile je wirksamer Inbox-Zeile mit ihrer Operation |
| **Form der Version** | Versionszeile mit Beginn (`created_at`) und Ende (`invalidated_at`); das Ende trägt die Art als Flag (`deleted`). **Keine D-Zeile**, keine Ereignis-Tabelle, keine Ist-Tabelle. Eine Löschung beendet die offene Version mit `deleted = true`; danach hat der Schlüssel keine offene Version, bis ein neues `N` eine öffnet |
| **Kein Wertvergleich** | Jede wirksame `N`-Zeile erzeugt eine neue Version, auch bei gleichem Wert. Eine identische Nachlieferung ist damit im Ledger sichtbar. Zwischenwerte, die **innerhalb eines Laufs** von einer späteren Zeile desselben Schlüssels überholt werden, erzeugen keine Version — sie stehen nur in der Inbox |
| **Faltung je Lauf und Schlüssel** | Die nach Position **letzte** Zeile des Schlüssels im Lauf entscheidet; sie gilt nur, wenn ihre Position **nach dem Cursor** liegt. `N` beendet die offene Version (`deleted = false`) und öffnet eine neue; `D` beendet sie mit `deleted = true`; `D` ohne offene Version ist ein No-op. Ein Lauf schreibt je Schlüssel höchstens eine neue Version |
| **Ankunftsordnung** | Gilt **über Läufe hinweg**: die Position steht auf jeder Version (`empfangen_at`, `zeilen_nr`). Eine spät verarbeitete ältere Zeile verdrängt keine jüngere. Innerhalb eines Jobs gewinnt die höhere Zeilennummer (Legacy: „letzte Zeile gewinnt“ in `tmp_if_kurs`) |
| **Wiederholungen** | Eine Wiederholung erbt `empfangen_at` des Originals. Ihre Zeilen tragen dieselben Positionen wie die des Originals: was das Original schon geschrieben hat, wird nicht doppelt geschrieben (Position nicht nach dem Cursor); was das Original abgelehnt und die Wiederholung angenommen hat, gilt nach Ankunftsordnung. **Eine Wiederholung fügt nur hinzu, nimmt nie zurück**: eine Version, deren Zeile die Wiederholung jetzt ablehnt, bleibt offen. Sichtbar in der Inbox der Wiederholung (Zeile fehlt) und an der Version (Position zeigt auf das Original). Keine Verdrängungslogik im Lauf |
| **Nebenläufigkeit** | **Claim**: ein Lauf weist sich in **eigener Transaktion** alle Inbox-Zeilen mit `processing_job_id is null` zu (ein bedingtes Update), committet, und liest dann zurück, was er tatsächlich bekommen hat. Ein paralleler Lauf findet nichts. Keine Sperren, kein Guard |
| **Transaktion des Laufs** | Versionen (`business-new-introduced`) und Quellzeilen (`job-system`) in **einer** synchronisierten Transaktion. Im Deployment und in beiden lokalen Postgres-Profilen lösen beide Kontexte auf denselben db-key auf → ein Commit. Nur der H2-only-Launcher trennt sie (Abschnitt 3.7) |
| **Zeitstempel** | `created_at` = DB-Uhr des Kontexts `business-new-introduced` als erste Anweisung der Schreibtransaktion, **ein Wert für alle Versionen des Laufs**; `invalidated_at` der beendeten Version = derselbe Wert. `empfangen_at` am Job = DB-Uhr des Job-Kontexts bei der Einreichung |
| **Herkunft** | `preis_historie_source`: **eine Zeile je wirksamer Inbox-Zeile** mit `operation` (`NEW`, `UPDATE`, `DELETE`) und beiden Versions-IDs (`created_version_id`, `ended_version_id`, je nullable). Liegt **neben der Inbox** im `job-system`, FK auf die Inbox-Zeile **mit Cascade**; die Versions-IDs sind logische Referenzen. `preis_historie` selbst referenziert weder Job noch Inbox — Housekeeping der Jobs berührt das Ledger nie |
| **Identitäten** | Inbox-Zeile und Version bekommen je eine `id uuid`. Auf der Version zusätzlich die Position (`empfangen_at`, `zeilen_nr`), die nach dem Aufräumen der Inbox noch Job (über `empfangen_at`) und physische Zeile im archivierten File benennt |
| **Stammdaten** | Stand **zum Stichtag** (`findFonds(isin, preis_datum)`), `num_wfs_ku` auf jeder Version. Filter je Zeile wie bisher: LMT und Aktion `I` (kein Schlüssel), unbekannte ISIN, TEST-ISIN, C-Plan/AIF/Liquidation bei Gate „aus“ — übersprungen, auch ein `D`. Übersprungene Zeilen werden mit Grund geloggt, nicht gespeichert |
| **Währung** | Prüfung am **Eingang** (`ERR_CURRENCY04` über `tax_code.isinwaehrung = J` für `R/E/Z/S/S2/S3`, nur im Neusystem). Der Lauf kennt keine Währungsregel; bis das Flag an ist, erreichen Fremdwährungspreise das Ledger auf ihrem eigenen Schlüssel (Tracker, Todo „Währungsprüfung“) |
| **Veto** | entfällt (Klärung E3) |
| **Manuelle Eingriffe** | keine. Korrektur nur über neue Lieferung oder Wiederholung |
| **Aufbewahrung** | Produktive Preismeldungs-Jobs werden nie gelöscht. Inbox-Zeilen werden nach einem Fenster gelöscht (Tracker, Todo „Aufräumregel“); ihre Quellzeilen gehen per Cascade mit, die Versionen bleiben |
| **Sybase-Ableitung** | **Folgejob** nach dem Ledger-Commit, eigener Job, eigener Retry; nicht in diesem Plan (Abschnitt 7) |
| **Partitionierung** | später, nach `preis_datum`; jetzt nur vorbereitet (Abschnitt 7) |

---

## 2. Die Tabellen

### 2.1 `preismeldung_zeilen` — Änderungen an der Inbox

Bestand: V061/V067 (`job_id`, `zeilen_nr`, `isin`, `preisdatum`, `waehrung`, `meldekategorie`,
`aktion`, `wert` als Text, `fondsbezeichnung`, LMT-Spalten; PK (`job_id`, `zeilen_nr`); FK auf
`jobs` ohne Cascade). Kontext `job-system`, Modul `ifas-persistence-infra`.

| Änderung | Warum |
|---|---|
| `id uuid not null`, **neuer PK**; (`job_id`, `zeilen_nr`) wird Unique-Constraint | einspaltige Identität für `preis_historie_source`. Bestand: nur Diff-Job-Zeilen (kein produktiver Job existiert), Backfill per DB-Funktion — Postgres `gen_random_uuid()`, H2 `random_uuid()`, über die `${pg-only}`/`${h2-only}`-Platzhalter (`DbConfigs:66-90`) |
| `processing_job_id uuid null` + Index | der Claim (Abschnitt 3.2). Logische Referenz auf den Verarbeitungs-Job; kein FK, damit ein gelöschter Testlauf keine Zeilen sperrt |
| Index (`isin`, `preisdatum`) | „Zeilen eines Schlüssels“ für Support-Abfragen; der Lauf selbst liest über `processing_job_id` |

Verhalten, das der Lauf voraussetzt:

- **Nur angenommene Zeilen.** Abgelehnte stehen in der Rückmeldung.
- **Write-once je Job** (Review B7, unverändert nötig): die Eingangsstufe schreibt Zeilen, Marker
  `eingang_abgeschlossen_at`, Result-Referenz und Zähler in **einer** `job-system`-Transaktion;
  ein Retry mit gesetztem Marker wertet nicht neu aus und fasst die Zeilen nicht an. Wichtiger als
  zuvor: ein Retry, der schon **geclaimte** Zeilen ersetzte, hinterließe ungeclaimte Kopien, und
  ohne Wertvergleich würden daraus doppelte Versionen. Neu auswerten heißt Wiederholung (neuer Job).
- **Nie ein Update** außer dem Claim.

### 2.2 Spalten am Job (`preis_meldung_diff_jobs`, später ebenso der produktive Job)

Jeder Jobtyp führt seine Spalten selbst (Muster Ausschüttung), `timestamp(6) with time zone`:

| Spalte | Null | Bedeutung |
|---|---|---|
| `empfangen_at` | nein | Ankunft der Lieferung bei IFAS nach der DB-Uhr des Job-Kontexts, gesetzt bei der Einreichung über `DatabaseContextHelper.currentDbTime()` (neu, neben `getCurrentDbUser()`, `DatabaseContextHelper:76`). **Erste Komponente der Position.** Eine Wiederholung erbt den Wert des Originals. Bestand: aus `jobs.created_at` |
| `eingang_abgeschlossen_at` | ja | der Eingang ist bis zum Ende gelaufen, die angenommenen Zeilen stehen endgültig in der Inbox (write-once-Marker). Bestand: `jobs.finished_at` für `COMPLETED` |

`verarbeitet_am` aus dem 09-24-Plan **entfällt**: der Claim je Zeile sagt, welcher Lauf sie
verarbeitet hat.

### 2.3 `preis_historie` — neu

Kontext `business-new-introduced`, Modul `ifas-persistence-fondspreise`.

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `id` | `uuid` | nein | PK |
| `isin` | `varchar(12)` | nein | Schlüsselteil, wie geliefert |
| `preis_datum` | `date` | nein | Schlüsselteil; der Stichtag als Punkt. Kein Intervall: `kurs`/`tmp_if_last` sind punktbasiert, Fill-forward ist eine Leseregel je Leser |
| `waehrung` | `varchar(3)` | nein | Schlüsselteil; Lieferwährung |
| `meldekategorie` | `varchar(2)` | nein | Schlüsselteil; `R`, `E`, `Z`, `S`, `S2`, `S3` |
| `wert` | `numeric` | nein | der Preis; **ohne Präzision und Skala** (`max_nk` ist für diese Codes null, jede feste Skala rundete still); einmal an der Grenze Inbox → Domäne geparst |
| `num_wfs_ku` | `bigint` | nein | Fonds zum Stichtag aufgelöst; Schlüssel von `kurs` |
| `created_at` | `timestamp(6) with time zone` | nein | seit wann IFAS diese Version hält; DB-Uhr, ein Wert je Lauf |
| `invalidated_at` | `timestamp(6) with time zone` | ja | `null` = offen; sonst der `created_at` des Laufs, der sie beendet hat |
| `deleted` | `boolean` | nein | `true` nur mit `invalidated_at`: beendet durch `D`. `false` = offen oder durch ein neueres `N` ersetzt |
| `offen` | `boolean` | ja | `true` genau dann, wenn `invalidated_at is null`, sonst `null`. Träger des Unique-Index (siehe unten) |
| `empfangen_at` | `timestamp(6) with time zone` | nein | Position, Teil 1: `empfangen_at` des Jobs der erzeugenden Zeile |
| `zeilen_nr` | `integer` | nein | Position, Teil 2: physische Zeilennummer der erzeugenden Zeile |

Indizes und Constraints:

- `ux_preis_historie_offen` (`isin`, `preis_datum`, `waehrung`, `meldekategorie`, `offen`) —
  höchstens eine offene Version je Schlüssel. H2 kennt keine partiellen Indizes
  (`V035__jobs_daily_run_number.sql:16-25`); NULL-Werte sind in Unique-Indizes auf Postgres und H2
  verschieden, daher die Markierungsspalte statt `where invalidated_at is null`.
- `ix_preis_historie_schluessel` (`isin`, `preis_datum`, `waehrung`, `meldekategorie`, `created_at`)
  — Kette eines Schlüssels, Zustand zu T, Preisreihe eines Fonds.
- Check: `offen = true` ⇔ `invalidated_at is null`; `deleted = true` ⇒ `invalidated_at is not null`.
- Kein FK, keine Referenz auf Jobs oder Inbox.

**Invarianten je Schlüssel** (Konstruktor der Domänen-Zeitreihe, Chunk 1):

- geordnet nach `created_at`, dann `empfangen_at`, `zeilen_nr`;
- lückenlos: `invalidated_at` einer Version = `created_at` der nächsten, **außer** nach einer
  Löschung — dort ist die Kette unterbrochen, bis ein `N` neu öffnet;
- höchstens eine offene Version, und sie ist die letzte;
- Positionen streng steigend entlang der Kette (Ankunftsordnung).

**Nicht in der Tabelle**, absichtlich: Fondsbezeichnung und Lieferant (Abschnitt 7), ein Grund
oder „beendet durch“ (steht in `preis_historie_source`), Zeilen für Tage ohne Lieferung, No-op-Zeilen,
übersprungene Zeilen, Zwischenwerte innerhalb eines Laufs.

Abfragen:

| Frage | Prädikat |
|---|---|
| aktueller Preis eines Schlüssels | `offen = true` |
| zurückgezogen vs. nie geliefert | letzte Version des Schlüssels hat `deleted = true` vs. keine Version |
| Stand zu T | `created_at <= T` und (`invalidated_at is null` oder `invalidated_at > T`) |
| Preisreihe eines Fonds, Stand jetzt | `isin`, `offen = true`, order by `preis_datum` |
| Historie eines Fonds für die Fachabteilung | alle Versionen der ISIN, order by `preis_datum`, `created_at` |
| welche Zeile hat diese Version erzeugt / beendet | `preis_historie_source` über `created_version_id` / `ended_version_id` |

### 2.4 `preis_historie_source` — neu

Kontext `job-system`, Modul `ifas-persistence-infra`, neben der Inbox.

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `preismeldung_zeile_id` | `uuid` | nein | PK; FK auf `preismeldung_zeilen(id)` **on delete cascade**. Eine Zeile kommt höchstens einmal vor |
| `operation` | `varchar(6)` | nein | `NEW`: Version geöffnet, keine beendet. `UPDATE`: eine beendet, eine geöffnet. `DELETE`: eine beendet (`deleted = true`), keine geöffnet |
| `created_version_id` | `uuid` | ja | die geöffnete Version; gesetzt bei `NEW` und `UPDATE` |
| `ended_version_id` | `uuid` | ja | die beendete Version; gesetzt bei `UPDATE` und `DELETE` |

Indizes auf `created_version_id` und `ended_version_id` (Lookup „wer hat Version X berührt“).
Die Versions-IDs sind logische Referenzen in den anderen Kontext. Geschrieben in derselben
synchronisierten Transaktion wie die Versionen, nie geändert. Zeilen ohne Wirkung haben keine
Quellzeile.

Beispiel: J1/3 liefert 101.2 und öffnet A; J2/7 liefert 101.3, beendet A, öffnet B; J3/9 ist ein
`D` und beendet B:

```
preismeldung_zeile_id  operation  created_version_id  ended_version_id
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
                        empfangen_at Fr 08:06)
```

Der letzte Fall präzisiert: J7 ist eine Lieferung mit `empfangen_at` **Fr 08:06** (Einreichung
Freitag), deren Eingang erst Montag abgeschlossen wurde. Sie wird von L6 geclaimt. Position
(Fr 08:06, 3) liegt **vor** dem Cursor von V4 (Mo 08:10, 4) → ignoriert, keine Version, keine
Quellzeile. Legacy hätte sie eingespielt.

`preis_historie` danach (`—` = null):

```
id  preis_datum  wert    created_at  invalidated_at  deleted  offen  empfangen_at  zeilen_nr
V0  2026-09-17   100.90  Do 08:10    —               false    true   Do 08:00      3
V1  2026-09-18   101.30  Fr 08:15    Fr 10:15        false    —      Fr 08:07      3
V2  2026-09-18   101.35  Fr 10:15    Fr 15:15        true     —      Fr 10:05      3
V4  2026-09-18   101.30  Mo 08:20    —               false    true   Mo 08:10      4
V3  2026-09-21   101.90  Mo 08:20    Mo 09:10        false    —      Mo 08:10      3
V5  2026-09-21   101.90  Mo 09:10    —               false    true   Mo 09:00      3
```

`preis_historie_source` danach:

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
`processing_job_id` = L2 bzw. L6.

Was man sieht: Sa/So kommen nirgends vor; die Kette des 18.9. ist nach V2 unterbrochen und beginnt
mit V4 neu; V3 und V5 tragen denselben Wert und sind zwei Versionen; V3/V4 teilen `created_at`
(ein Lauf, ein Wert); die Positionen steigen je Schlüssel streng.

---

## 3. Der Verarbeitungs-Lauf

### 3.1 Auslöser

**Annahme (zu bestätigen):** der Eingang reicht nach seiner Inbox-Transaktion einen
Verarbeitungs-Job als Folgejob ein (Parent-Link `jobs.parent_id`, V069; Muster `JobService:104`).
Im Parallelbetrieb ist das der `PreisMeldungDiffJob`, später der produktive Preismeldungs-Job.
Überlappende Läufe sind durch den Claim harmlos: der zweite findet nichts. Ein periodischer Lauf ist
nicht nötig; ein manueller Anstoß aus der UI (für liegengebliebene Zeilen) kann später dazukommen.

**Diff-Job-Zeilen speisen das Ledger** (Review B11): im Parallelbetrieb sind sie die einzige Quelle.
`deleteArchivedBatch` löscht ihre Inbox-Zeilen und per Cascade die Quellzeilen; die Versionen
bleiben und zeigen auf Positionen, deren Zeilen nicht mehr existieren — akzeptiert und dokumentiert.
Die Sicherung aus B11 (Löschen verweigern) entfällt, weil das Ledger keine Jobs referenziert.

### 3.2 Claim

1. **Eigene Transaktion** (`job-system`): `update preismeldung_zeilen set processing_job_id = :lauf
   where processing_job_id is null` — **ein** bedingtes Update, kein Select-then-Update. Commit.
2. **Zurücklesen**: alle Zeilen mit `processing_job_id = :lauf`, gejoint mit ihrem Job
   (`empfangen_at`; nur Jobs mit `eingang_abgeschlossen_at`, was durch die Eingangs-Transaktion
   ohnehin gilt). Was ein paralleler Lauf vorher geclaimt hat, ist nicht dabei.
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
| `findFonds(isin, preis_datum)` leer | überspringen, `WARN`; der Eingang lehnt unbekannte ISINs ab, Stammdaten können sich aber geändert haben |
| TEST-ISIN | überspringen, auch `D` |
| C-Plan, AIF, Fonds in Liquidation bei Gate „aus“ | überspringen, auch `D`; Gates per Default „speichern“ (Legacy `InsPreise*` = 1) |
| sonst | Zeile für die Faltung: Schlüssel, Aktion, `wert` (für `N` aus `new BigDecimal`, für `D` null), `num_wfs_ku`, Position, `preismeldung_zeile_id` |

Übersprungene Zeilen bleiben geclaimt (sie sind verarbeitet), werden mit Grund geloggt
(`UNKNOWN_ISIN`, `TEST_ISIN`, `C_PLAN`, `AIF`, `FONDS_IN_LIQUIDATION`) und bekommen keine Quellzeile.

**Stammdaten-Cache:** `PreismeldungStammdatenService` cacht `findFonds` nur nach ISIN
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

**Tiebreak:** die Position ist (`empfangen_at`, `zeilen_nr`), **ohne Job-ID**. Eine Wiederholung
hat dieselben Positionen wie ihr Original — genau deshalb schreibt sie nichts doppelt. Zwei
**fremde** Jobs mit identischem `empfangen_at` (Mikrosekunden der DB-Uhr) kollidierten auf
`zeilen_nr`; das ist theoretisch, wird dokumentiert und nicht behandelt. Eine Job-ID in der Position
wäre falsch: sie machte die Zeile der Wiederholung zu einer „späteren“ und verdoppelte die Version.

### 3.5 Schreiben

Eine synchronisierte Transaktion (`@Transactional` über den `SynchronizingTransactionManager`,
REQUIRES_NEW, weil der Work-Queue-Handler schon in einer Transaktion läuft — Muster
`withJobSystemDbContextIsolatedTransactional` in `PreisMeldungDiffJobExecutionService:111`):

1. `created_at` = `currentDbTime()` im Kontext `business-new-introduced`, **einmal**.
2. Je Schlüssel in **fester Reihenfolge** (Schlüsselordnung): offene Version beenden
   (`invalidated_at`, `deleted`, `offen = null`) — als bedingtes Update „noch offen“, Anzahl 1
   prüfen — und neue Version einfügen (`offen = true`). Ein zweiter Insert auf einen Schlüssel
   scheitert am Unique-Index; das ist nach dem Claim nur noch ein Bug-Detektor.
3. Quellzeilen einfügen (`job-system`).
4. Commit: der Manager flusht alle enrollten Datenbanken, dann committet er sie nacheinander
   (`SynchronizingTransactionManager.doCommit`). Bei einem Key ist das ein Commit.

Danach markiert der Work-Queue-Executor den Job wie üblich. Fällt das aus, greift beim Retry der
Guard aus 3.2.

### 3.6 Wiederholungen

Kein eigener Code. `empfangen_at` wird beim Einreichen der Wiederholung aus dem Original kopiert
(`repeatedFromJob`, `Job.java:85`; `JobRepository:54`); alles Weitere ergibt sich aus der Position
(Abschnitt 1, „Wiederholungen“).

### 3.7 Nebenläufigkeit und Fehler

| Situation | Verhalten |
|---|---|
| zwei Läufe gleichzeitig | der Claim entscheidet; der zweite liest 0 Zeilen zurück und endet leer. Auf Postgres wartet das zweite Update und wertet das Prädikat neu aus; auf H2 kann es mit Sperr-Timeout scheitern — dann Retry, ebenfalls leer |
| Abbruch nach Claim, vor Commit | die Zeilen bleiben dem Lauf zugewiesen; sein Retry faltet sie (Guard findet keine Quellzeilen) |
| Abbruch nach Commit, vor Job-Abschluss | Retry: Guard findet Quellzeilen → Faltung übersprungen |
| Job endgültig `FAILED` | die Zeilen bleiben geclaimt und unverarbeitet — sichtbar über `processing_job_id` eines `FAILED`-Jobs. Freigabe (Claim nullen) ist ein Support-Eingriff; als UI-Aktion später |
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

Package `at.oekb.ifas.domain.fondspreise.historie`, Namen englisch außer Fachbegriffen:

- `PreisSchluessel` — Record (`isin`, `preisDatum`, `waehrung`, `meldekategorie`), lehnt LMT ab.
- `Position` — Record (`empfangenAt`, `zeilenNr`), `Comparable`.
- `PreisVersion` — Record der Version (ohne DB-Details).
- `InboxZeile` — gefilterte Zeile für die Faltung (Schlüssel, Aktion, `wert`, `numWfsKu`,
  Position, `zeileId`).
- `PreisVersionCalculator` — `fold(Optional<PreisVersion> open, List<InboxZeile> lines)` →
  `Optional<VersionChange>` (welche Version beenden, wie, welche öffnen, welche Zeile ist die Quelle,
  `operation`). Reine Funktion, keine Persistenz (Review B13: Idee von `GjZeitreihe`, nicht die
  Struktur).
- `PreisZeitreihe` — Record der Versionen eines Schlüssels, Konstruktor prüft die Invarianten aus
  2.3 (für Tests und die UI, nicht für die Faltung).
- `InboxZeilenFilter` — Utility, Regeln aus 3.3; `UebersprungGrund` als Enum.

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

Eine Migration für das ganze Feature (`flyway-one-file-per-feature.md`): Inbox-Änderungen,
Job-Spalten, `preis_historie`, `preis_historie_source`, Grants, Indizes. `timestamp(6) with time
zone`, nicht `timestamptz`. Nach dem Anlegen: `mvn -Pno-proxy install -pl
ifas-database/ifas-database-flyway`, sonst testet man das alte Jar.

---

## 7. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **Ableitung nach `kurs`** | Folgejob nach dem Ledger-Commit (Abschnitt 4). Reconcile je Schlüssel: offene Version mit Wert ⇒ `kurs`-Zeile mit diesem Wert (delete-then-insert je Code wie Legacy); letzte Version `deleted` ohne offene Nachfolgerin ⇒ keine `kurs`-Zeile. Idempotent, eigener Retry, Sybase = eigener db-key |
| **Ableitung nach `tmp_if_last`** | ein Platz je (`isin`, `waehrung`, `meldekategorie`): offene Version mit höchstem `preis_datum`. Spaltenquellen (User 30.09.): `eintragezeit` aus `created_at` oder `empfangen_at` (Legacy: Ankunft → `empfangen_at` diffts sauberer), `txt_bez` aus den Stammdaten (bekannte Abweichung zu „wie geliefert“, bis Klärung O), `liefer_id` = Lieferant — nur der Job kennt ihn (Klärung J: Stammdaten sagen es nicht) |
| **Lieferant auf der Version** | offen: Kopie auf `preis_historie` (Eigenschaft der Version, überlebt das Job-Housekeeping) oder Hop über `preis_historie_source` → Inbox → Job. Nachrüstbar, solange die Inbox-Zeilen leben |
| **Partitionierung nach `preis_datum`** | Postgres verlangt den Partitionsschlüssel in jedem Unique-Constraint → PK würde (`preis_datum`, `id`); der Unique-Index enthält `preis_datum` schon. H2 kennt keine Partitionierung → `${pg-only}`-DDL. Ob das Ledger je beschnitten wird, ist fachlich: Legacy beschneidet `kurs` nie (42,6 Mio Zeilen seit 1994) |
| Sammelreport (Schnitt 4/5) | liest offene Versionen und das Publikationsprotokoll |
| Fehlmeldung (Schnitt 7) | Anti-Join auf offene Versionen; „letzte Version `deleted`“ = zurückgezogen |
| Kennzahlen-Invalidierung | ausgelöst durch das Beenden einer `R`-Version |
| Aufräumen der Inbox-Zeilen, Freigabe geclaimter Zeilen `FAILED`-Läufe | Todo Tracker; UI-Aktionen |
| Währungsflag im Neusystem | Todo Tracker (erst messen) |
| Javadoc `PreismeldungZeile` („kept as text to preserve the delivered precision …“) | Begründung falsch (Legacy formatiert aus `float`); in Chunk 3 korrigieren |

---

## 8. Chunks

Reihenfolge = Abhängigkeit. Chunks 1 und 2 sind reine Domäne ohne DDL.

### Chunk 1 — Domäne: Faltung je Schlüssel

- **Inhalt:** Abschnitt 5 ohne den Filter: `PreisSchluessel`, `Position`, `PreisVersion`,
  `InboxZeile`, `VersionChange`, `PreisVersionCalculator`, `PreisZeitreihe`.
- **Tests** (Given-When-Then, AssertJ): die Tabelle aus 3.4 Zeile für Zeile; Zwischenwert im
  selben Lauf (nur die letzte Zeile wirkt); späte ältere Zeile vor dem Cursor (keine Wirkung);
  dieselbe Position aus einer Wiederholung (keine Wirkung); `D` ohne offene Version (No-op);
  `N` nach `D` öffnet neu, auch mit älterer Position; gleicher Wert erzeugt eine Version;
  Sortierung innerhalb eines Jobs nach `zeilen_nr`; Invarianten der `PreisZeitreihe` (Kette, eine
  offene, Positionen steigend, Bruch nach `deleted` erlaubt); Beispiel 2.5 als Ganzes.
- **Fertig, wenn:** jede Regel aus 3.4 einen Test hat.

### Chunk 2 — Domäne: Filter je Zeile

- **Inhalt:** `InboxZeilenFilter`, `UebersprungGrund`, Gates-Record aus `FondspreiseProperties`
  (nur `store*`); Cache-Schlüssel in `PreismeldungStammdatenService` um den Stichtag erweitern.
- **Tests:** je Regel einer, mit `N` und `D`; drei Gates an/aus; unbekannte ISIN; `numWfsKu` zum
  Preisdatum; `wert` für `N` geparst, für `D` null; dieselbe ISIN mit zwei Preisdaten und
  verschiedenem `num_wfs_ku` aus `wkn_hist`.

### Chunk 3 — Persistenz: eine Migration, Entities, Eingang write-once

- **Migration V074** (Abschnitt 6): Inbox `id` + Backfill + PK-Wechsel + Unique (`job_id`,
  `zeilen_nr`) + `processing_job_id` + Indizes; `empfangen_at`/`eingang_abgeschlossen_at` am
  Diff-Job mit Backfill; `preis_historie` mit Indizes und Checks; `preis_historie_source` mit
  Cascade-FK und Indizes; Grants.
- **Entities/Repositories:** `PreismeldungZeile` auf `@Id uuid` umstellen (`PreismeldungZeileId`
  entfällt), Claim-Update und „Zeilen eines Laufs mit Job“; `PreisHistorie` + Repository (offene
  Version je Schlüssel, Kette je Schlüssel, bedingtes Beenden mit Anzahl, Versionen einer ISIN);
  `PreisHistorieSource` + Repository (existiert für Zeile, nach Versions-ID).
- **Helfer:** `DatabaseContextHelper.currentDbTime()` (`select current_timestamp` über das
  Routing-`JdbcTemplate`; Postgres/H2).
- **Eingang write-once** (Review B7): `PreisMeldungDiffJobExecutionService.executeDiff` — heute
  Inbox-Transaktion (`:111-113`), dann Filestore, dann `updateResult` (`:136`); neu: auswerten →
  Bundle bauen und speichern → **eine** Transaktion (Zeilen, `eingang_abgeschlossen_at`,
  Result-Referenz, Zähler). Marker gesetzt → alles überspringen. `submit` setzt `empfangen_at`;
  der Wiederholungspfad kopiert es aus dem Original.
- **Tests** (Multi-DB, H2 + Postgres; Sybase entfällt): Unique der offenen Version greift;
  bedingtes Beenden liefert 0 bei schon beendeter Version; Cascade Inbox → Quellzeile; `wert` mit
  12 Nachkommastellen kommt unverändert zurück; Claim-Update ist bedingt (zweiter Claim bekommt 0);
  `PreisMeldungDiffJobTest`: Retry mit Marker lässt Inbox und Marker unverändert, ohne Marker
  ersetzt er.
- **Vorher:** Flyway-Modul installieren.

### Chunk 4 — Service: der Verarbeitungs-Job

- **Inhalt:** Job-Typ `PreisVerarbeitungJob` (Entity, Submission, Execution, Work-Queue-Handler,
  Dispatcher-Zweig) nach dem Muster der bestehenden Jobs; Ablauf 3.2 → 3.3 → 3.4 → 3.5 mit
  Retry-Guard; Zähler am Job (Zeilen geclaimt, gefiltert je Grund, Versionen geöffnet/beendet,
  ignoriert vor dem Cursor).
- **Tests** (Integration, Multi-DB): Beispiel 2.5 end to end über echte Jobs; zwei Läufe
  **nebenläufig** auf denselben ungeclaimten Zeilen → genau ein Lauf schreibt, der andere endet
  leer oder mit Ausnahme (Typ nicht prüfen, Review B10); Retry nach Commit schreibt nichts
  doppelt; Wiederholung eines Jobs schreibt nichts doppelt; Wiederholung mit jetzt angenommener
  Zeile schreibt nach Ankunftsordnung; `FAILED`-Lauf lässt Zeilen geclaimt.

### Chunk 5 — Auslöser

- **Inhalt:** Einreichung des Verarbeitungs-Jobs als Folgejob aus dem Eingang (3.1, Parent-Link);
  `maxAttempts` > 1 für den Handler.
- **Tests:** Eingang `COMPLETED` → Verarbeitungs-Job existiert mit Parent; Eingang `FAILED` → keiner.

### Chunk 6 — UI: Preishistorie

- **Inhalt:** Seite je ISIN (alle Versionen, `preis_datum`, Wert, `created_at`/`invalidated_at`,
  `deleted`, Position; Quelle über `preis_historie_source` mit Link auf Job und Zeile, „Zeile nicht
  mehr in der Inbox“ wenn aufgeräumt); Einstieg von der Job-Detailseite (Schlüssel der Lieferung)
  und über eine ISIN-Suche unter *Testen*. Grenzen der Web-UI: kein npm/CDN, nur `~{::section}`.
- Kann direkt nach Chunk 4 kommen.

---

## 9. Ersetzte Dokumente

Dieser Plan ersetzt in `plans/fondspreise/`:

| Dokument | Status |
|---|---|
| `2026-09-24-fondspreise-preis-historie-zeitreihe.md` + `-review.md` | ersetzt (Sicht-Kette mit D-Zeilen, Cursor-Faltung mit Verdrängung, `verarbeitet_am`) |
| `2026-09-17-fondspreise-preis-ledger-formen.md`, `-er-diagramme.md`, `.deck.html` | ersetzt (Formen A/B/C; Ergebnis: A mit Endreferenz über `preis_historie_source`) |
| `2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md`, `2026-09-10-…-ap4-review-fixes.md` | ersetzt für Stufe 2 (`preis_herkunft`, `letzte_preise`, Klammer-Transaktionen entfallen); Schnitt 1 bleibt wie umgesetzt |
| `2026-08-31-fondspreise-neuentwicklung-konzept.md` + Deck | bleibt als Konzept; Abschnitt *Stufe 2* dort ist überholt und verweist hierher (nachziehen) |
| `tracker.md` | bleibt; Schnitt-2-Zeile und Runde 11 nachziehen |

Aufräumen (Archivierung der ersetzten Dateien) ist ein eigener Schritt nach diesem Plan.

---

## Quellen

| Aussage | Fundstelle |
|---|---|
| Inbox heute: PK (`job_id`, `zeilen_nr`), FK auf `jobs` ohne Cascade | `V061__preismeldung_zeilen.sql`, `V067__preismeldung_zeilen__job_fk.sql`, `PreismeldungZeile.java`, `PreismeldungZeileId.java` |
| Diff-Job-Spalten | `V063__preis_meldung_diff_jobs.sql`, `PreisMeldungDiffJob.java` |
| `kurs`/`tmp_if_last` auf master | `V073__kurs_tmp_if_last.sql`, `Kurs.java`, `TmpIfLast.java` (`5d22c157c`) |
| Claim-Muster | `V065__ausschuettung_processing.sql` (`processing_job_id`), `WorkQueueItemRepository:79` (`claimItem`) |
| Parent-Link für Folgejobs | `V069__jobs_parent.sql`, `JobService:104`, `OrchestrationJobHelper:81` |
| Wiederholung | `Job.java:85` (`repeatedFromJob`), `JobRepository:54`, `PreisMeldungDiffJobRepository:48` |
| Synchronisierte Transaktion: flush all, commit nacheinander, `PartialCommitException`; ein Key = ein Enroll | `SynchronizingTransactionManager.java` (`enrollDatabase`, `doCommit`) |
| db-keys je Profil: Deployment und lokale Postgres-Profile ein Key, H2-only zwei | `application-server-deployment.properties:24,43`; `application-local-postgres-and-sybase.properties:16,33`; `application-local-sybase-gast-and-postgres.properties:16,33`; `application-local-h2-only.properties:18,35` |
| Eingang schreibt Inbox-Transaktion → Filestore → `updateResult` | `PreisMeldungDiffJobExecutionService:111-113`, `:136` |
| Stammdaten-Cache nur nach ISIN | `PreismeldungStammdatenService:50-51` |
| `${pg-only}`/`${h2-only}` | `DbConfigs:66-90`, `V068__jobs_timestamps_with_time_zone.sql` |
| Keine partiellen Indizes in H2 | `V035__jobs_daily_run_number.sql:16-25` |
| Routing-`JdbcTemplate` für `currentDbTime()` | `DatabaseContextHelper:40,76` |
| Legacy: letzte Zeile gewinnt; `kurs` delete-then-insert; `tmp_if_last` ein Platz je (ISIN, Whg, Code) | Formen-Dokument 0a (`c_insert.cpp:1962`, `preisekennzahl.cpp:719`, `:1226-1345`) |
| Filterregeln, Gates, TEST-ISIN | 09-24-Plan 3.3 (`calculation.cpp:196-204`, `ins_wp_art_f.cr:41-42`) |
| Flyway-Stand | `git ls-tree` auf `master`, `origin/master`, `origin/stable`, `origin/production`, alle `origin/*`, 2026-09-30 |
