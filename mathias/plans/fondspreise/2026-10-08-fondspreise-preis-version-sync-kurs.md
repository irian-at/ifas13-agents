# Fondspreise — Sybase-Ableitung `kurs`: der `PreisVersionSyncJob`

Datum: 2026-10-08. Stand: **Design entschieden** (/discuss 2026-10-08), Umsetzung offen.
Setzt auf [2026-09-30-fondspreise-preis-historie-versionen.md](2026-09-30-fondspreise-preis-historie-versionen.md)
auf (dort Abschnitte 4 und 7: „Folgejob nach dem Ledger-Commit") und löst die Zeile „Ableitung nach
`kurs`" in dessen Abschnitt 7 ein. `tmp_if_last` bleibt ein späterer, eigener Plan (Abschnitt 7).

Kurzfassung: ein Folgejob des Laufs bringt die Sybase-Tabelle `kurs` auf den aktuellen Stand des
Ledgers. Das Ledger bleibt die einzige Wahrheit; `kurs` wird nie gelesen, um etwas zu entscheiden,
nur geschrieben. Jede Version trägt einen Stempel, wer sie wann in die Ableitung mitgenommen hat;
alles ohne Stempel ist die Arbeit des nächsten Syncs, egal welcher Lauf ihn ausgelöst hat. Daraus
folgt die Selbstheilung: ein gescheiterter Sync hinterlässt nur ungestempelte Zeilen.

---

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| Ledger | `preis_versions` (Kontext `business-new-introduced`, Postgres; lokal H2) |
| Lauf | ein `PreisVersionJob`: verarbeitet Inbox-Zeilen zu Versionen (Vorgänger-Plan) |
| Sync | ein `PreisVersionSyncJob`: bringt `kurs` auf den Stand des Ledgers (dieser Plan) |
| Schlüssel | (`isin`, `preisdatum`, `waehrung`, `meldekategorie`), wie im Ledger |
| aktueller Stand | die offene Version eines Schlüssels (`open = true`), oder keine |
| Reconcile | `kurs` für einen Schlüssel an den aktuellen Stand angleichen, unabhängig davon, was der auslösende Lauf geschrieben hat |
| Stempel | `processed_at` / `preis_version_sync_job_id` auf der Version: ein Sync hat die Zeile mitgenommen (geschrieben **oder** regelkonform übersprungen) |
| Fondswährung | `FondsStammdaten.fondswaehrung`, aufgelöst über `PreisMeldungStammdatenService` zum Stichtag der Zeile |
| aktiv | ein Sync mit Work-Item `RUNNING`, dessen `heartbeat_at` jünger ist als `WorkQueueProperties.processingTimeout` (Default 5 min) |
| Klärung N / O / P | Zweck des `tmp_if_last`-Fallbacks / Fremdleser von `tmp_if_last` / Fallback-Semantik Fremdwährung (Tracker, Abschnitt 1) |
| D13 | generischer Tabellenvergleich Sybase alt ↔ neu (Tracker; für `kurs`/`tmp_if_last` vertagt 2026-10-08) |

---

## 1. Entscheidungen (2026-10-08, User)

| Thema | Entscheidung |
|---|---|
| **Was ein Sync ist** | „Bring `kurs` jetzt auf den Stand des Ledgers", nicht „der Sync von Lauf X". Jeder produktive Lauf sorgt nur dafür, dass danach ein Sync stattfindet; welcher Sync eine Version mitnimmt, ist egal. Der Parent-Link Lauf → Sync dient der Nachvollziehbarkeit |
| **Nur `kurs`** | `tmp_if_last` später, eigener Plan (Abschnitt 7). Beides ist aus dem Ledger ableitbar; `tmp_if_last` braucht zusätzlich Lieferant und Ankunftszeit (nicht auf der Version) und die Fondsbezeichnung — die **aus den IFAS-Stammdaten**, nicht aus dem gelieferten File |
| **Schalter** | Zwei: (1) `ifas.fondspreise.preis-version-sync.enabled` je Deployment — in Produktion immer an, aus nur, wo kein Sync gewollt ist (Parallelbetrieb-Test, lokal nach Bedarf); (2) der auslösende Job: der `PreisMeldungDiffJob` **nie** (wie Mail und MFT-Upload), der produktive Preismeldungs-Job ja. Kein Umschalten im Betrieb |
| **Stempel statt Claim** | `processed_at`, `preis_version_sync_job_id` auf `preis_versions`, gesetzt **nach** dem Sybase-Write in derselben synchronisierten Transaktion (Abschnitt 3.5). Kein Reservieren vor der Arbeit: ein Claim brächte die Frage nach verwaisten Claims zurück und keine Sicherheit, die die Serialisierung nicht schon gibt |
| **Benennung** | `PreisVersionSyncJob`, Tabelle `preis_version_sync_jobs`. Stempel `processed_at` / `preis_version_sync_job_id` — die Id-Spalte nennt den Jobtyp wie `preis_meldung_zeilen.preis_version_job_id` (V076 hat genau dafür von `processing_job_id` umbenannt); kein FK (anderer DB-Kontext, in `local-h2-only` liegt das Ledger in `h2-db1`, die Jobs in `h2-infra-db`). `processed` statt `synced`, weil der Stempel auch auf übersprungenen Zeilen steht. Zuerst war `processed_by` als bewusste Ausnahme geplant; am 2026-10-08 nach Blick auf die Hauspraxis auf die Regel zurück |
| **Zähler und Protokoll** | Fünf Zähler als Spalten (2.2): nur was eine Liste zeigt oder ein Filter braucht und was mit dem Stempel committen muss. Welcher Schlüssel geschrieben, entfernt oder nach welcher Regel übersprungen wurde, steht im **Protokoll** des Jobs (`jobs.protocol_file_ref`, Muster `JobAutoProtocolAndNotificationService`, Anzeige über `fragments/job-detail.html`). Entschieden 2026-10-08; vorher acht Zähler (`keys_reconciled` = Summe, `kurs_deleted`/`kurs_inserted` = Mechanik) |
| **Reconcile, kein Replay** | Je Schlüssel wird der aktuelle Stand geschrieben, nie der Wert des auslösenden Laufs. Idempotent; zwei Syncs können sich damit nicht gegenseitig alte Werte unterschieben, sofern sie nicht überlappen |
| **Alles oder nichts** | Ein Sync schreibt alle Schlüssel in einer Transaktion. `FAILED` heißt: nichts davon ist in `kurs`; der Retry macht alles noch einmal |
| **Ein aktiver Sync** | Nie zwei Syncs gleichzeitig. Ein Sync, der einen älteren aktiven findet, beendet seinen Versuch als transient; die Work-Queue bringt ihn mit Backoff zurück. **Keine wartenden Jobs, keine blockierten Worker-Slots** |
| **Selbstheilung** | Ein Sync nimmt alles Ungestempelte, egal von welchem Lauf. Gescheiterte Kinder bleiben als Spur `FAILED` stehen, ihre Zeilen heilt der nächste Sync. Reparatur jeder Art: Stempel löschen |
| **Fehlerbild** | Fehlschläge sind Infrastruktur; schlechte Daten kommen nicht bis hierher (der Lauf hat sie aufgelöst und gefiltert). Leere Sync-Jobs sind erwünscht: sie zeigen, dass nichts anstand |
| **Lauf ohne Änderungen** | löst trotzdem einen Sync aus (Heilung früher, Transparenz) |
| **Kein stündlicher Sweep** | vorerst manueller Auslöser („Geplante Aufgaben", Task deaktiviert). Der Sweep ist ein Umschalten von `scheduled-tasks.preis-version-sync.enabled`, falls ein Ausfall ihn je nötig macht |
| **Währungsregel** | wie Legacy: Preiswährung ≠ Fondswährung → keine `kurs`-Zeile (auch kein Delete), geloggt als *skipped by rule*, gestempelt. Sollte nach Einschalten der Eingangsprüfung (`ERR_CURRENCY04`) nicht mehr vorkommen. Klärung P bleibt davon unberührt (betrifft den Fallback) |
| **`guelt`** | Schreibzeit des Syncs (App-Uhr Wien), wie Legacy `getdate()` beim Einspielen. `created_at`/`received_at` wären Abweichungen, die nur D13 oder ein Fremdleser bemerkt — beides vertagt |
| **`num_bericht_kurs`** | Delete-then-Insert schreibt die Zeile neu, ein `R` verliert seinen berichtigten Kurs wie im Legacy; Auffüllen ist Sache der Kennzahlen (Schnitt 6). Der Sync weiß nichts davon |
| **Fehlende Stammdaten** | Fonds zum Stichtag nicht mehr auflösbar (Stammdaten seit dem Lauf geändert): Schlüssel übersprungen (`skipped_stammdaten`, `WARN`), gestempelt; Reparatur über Stempel löschen |
| **Vertagt** | D13 für `kurs`/`tmp_if_last`; Lieferant auf der Version. Go-live-Backlog: Verfahren „Migrations-Stempel“ entschieden 2026-10-12 (Abschnitt 7) |

---

## 2. Die Tabellen

### 2.1 `preis_versions` — zwei Spalten

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `processed_at` | `timestamp(6) with time zone` | ja | wann ein Sync die Zeile mitgenommen hat; **ein Wert je Sync** (= `preis_version_sync_jobs.versions_processed_at`) |
| `preis_version_sync_job_id` | `uuid` | ja | Id des `PreisVersionSyncJob`; logische Referenz in den Job-Kontext, kein FK (wie die Versions-Ids in `preis_version_sources`) |

- Check: `processed_at is null` ⇔ `preis_version_sync_job_id is null`.
- Index `ix_preis_versions_preis_version_sync_job_id (preis_version_sync_job_id)` — die Auswahl des Syncs ist `preis_version_sync_job_id is null`; das sind zu jedem Zeitpunkt wenige Zeilen gegenüber dem Bestand.
- Beide `null` bei jeder Zeile, die der Lauf **schreibt**: beim Öffnen und **beim Beenden** (Abschnitt 4). Null = „der nächste Sync muss diesen Schlüssel ansehen". Gesetzt = „ein Sync hat die Zeile angesehen", geschrieben oder regelkonform übersprungen; welches von beiden, sagt das Log des Syncs.
- Keine weitere Spalte (kein Outcome auf der Version): die zweite Hop ins Sync-Log ist tragbar, weil Skips nach Einschalten der Eingangsprüfung nicht mehr vorkommen sollen (User 2026-10-08).

### 2.2 `preis_version_sync_jobs` — neu

Kontext `job-system`, Katalog `infra`, Modul `ifas-persistence-infra`, `PreisVersionSyncJob extends Job`,
Diskriminator `PreisVersionSync`, Task-Type `PREIS_VERSION_SYNC`. Muster `preis_version_jobs` (V076).

| Spalte | Bedeutung |
|---|---|
| `id` | PK, FK auf `jobs` |
| `versions_processed_at` | der Stempelwert, den dieser Sync auf seine Zeilen geschrieben hat; `null` bei leerem oder gescheitertem Sync |
| `versions_processed` | gelesene ungestempelte Zeilen |
| `keys_written` | Schlüssel mit offener Version → `kurs`-Zeile geschrieben |
| `keys_removed` | Schlüssel ohne offene Version → `kurs`-Zeile entfernt (letzte Version `deleted`) |
| `keys_skipped_fondswaehrung` | Preiswährung ≠ Fondswährung, nichts geschrieben |
| `keys_skipped_stammdaten` | Fonds zum Stichtag nicht auflösbar, nichts geschrieben |

Zähler `null` bis zum Commit; gesetzt in derselben synchronisierten Transaktion wie Sybase-Write und Stempel
(der Job-Kontext ist dort schon enrollt — Muster `updateResult` des Laufs, Fix `cd45f5c3d`). Die
Versuche, die „auf einen aktiven Sync gewartet" haben, stehen am Work-Item (`attempt_count`) und im Log.

**Protokoll** (`jobs.protocol_file_ref`): das mitgeschnittene Log des Syncs ab `INFO` — je Schlüssel eine
Zeile (*written*, *removed*, *skipped by rule: Fondswährung*, *skipped: Stammdaten*), die Zähler-Summary,
*wartet auf Sync X*. Muster `AusschuettungsMeldungBatchJobExecutionService` →
`JobAutoProtocolAndNotificationService.executeWithProtocol(...)`, URI im `onSuccess` des Handlers an den
Job. Das Protokoll liegt im Filestore, **außerhalb** der Transaktion aus 3.5: ein Sync, dessen Ausführung
mit Ausnahme endet, hat keines (der Retry schreibt sein eigenes); die Zähler dagegen committen mit dem
Stempel. Benachrichtigung des Fachbereichs (`…AndNotifyOnErrorsOrWarnings`) vorerst nicht — Abschnitt 7.

### 2.3 `preis_version_jobs` — der Wunsch des Auslösers

| Spalte | Bedeutung |
|---|---|
| `sync_requested boolean not null default false` | der Einreicher des Laufs sagt, ob nach dem Lauf ein Sync folgen soll. Der `PreisMeldungDiffJob` reicht mit `false` ein, der produktive Job mit `true` (Benennung: Vorschlag, im Chunk festziehen) |

`PreisVersionJobSubmissionService.submit(createdBy)` bekommt den Parameter; der einzige heutige Aufrufer
(`PreisMeldungDiffJobExecutionService:112`) übergibt `false`.

**Zähler-Diät und Protokoll des Laufs** (User 2026-10-08, dieselbe Regel wie 2.2): die Spalten
`zeilen_no_key`, `zeilen_without_effect`, `versions_deleted` fallen — sie sind Summen oder Diagnostik und
stehen künftig im Protokoll des Laufs (je übersprungene Zeile eine Zeile mit Grund, eine Summenzeile für
Zeilen ohne Preisschlüssel, je Schlüssel ohne Wirkung eine Zeile, die Summary). Es bleiben `zeilen_claimed`,
die fünf `zeilen_skipped_*`, `versions_created`, `versions_ended`. Der Lauf wird wie der Sync in
`executeWithProtocol` gekapselt (keine Benachrichtigung); `AbstractJobWorkQueueHandler.onSuccess` hängt die
URI an den Job. **Drop in V079**, nicht in einer eigenen Migration: es gibt keine produktiven Läufe, V076
wird nicht angefasst (sie ist auf master).

### 2.4 `kurs` — was geschrieben wird

Entity `Kurs` (`ifas-persistence-inv`, Kontext `business`: auf dem Server `sybase-ifasneu`, lokal H2/Postgres —
V073 legt die Tabelle in jedem Profil an). Legacy-Quelle: `WriteKurse`, `preisekennzahl.cpp:719-800`.

| `kurs` | Quelle | Bemerkung |
|---|---|---|
| `num_wfs_ku` | Version | vom Lauf zum Stichtag aufgelöst |
| `dat_kurs` | `preisdatum` | |
| `cod_fliesscode` | `meldekategorie` | `R`, `E`, `Z`, `S`, `S2`, `S3`; gleiche Codes wie Legacy |
| `waehrung` | `waehrung` | = Fondswährung, sonst übersprungen |
| `num_kurs` | `wert` | `numeric` → `float`; Legacy schreibt `%.20le` eines `double` |
| `num_bericht_kurs` | — | `null`; Legacy ebenso beim Einspielen |
| `guelt` | Schreibzeit | App-Uhr Wien; Legacy `getdate()` |
| `cod_zusatz`, `cod_ex` | — | `null`; Legacy schreibt sie beim Einspielen nicht |

Schreibmuster wie Legacy: **Delete je vollem Schlüssel, dann Insert** — `KursRepository.deleteByNumWfsKuAndDatKursAndWaehrungAndCodFliesscode`
(JPQL-Bulk mit Flush, sonst überholt Hibernates Insert das Delete; Befund in `Kurs.java`), dann `save`.
Kein offener Stand → nur das Delete.

---

## 3. Der Sync-Lauf

### 3.1 Auslöser

- **Jeder produktive Lauf** mit `sync_requested = true` reicht nach seiner Schreibtransaktion genau einen
  `PreisVersionSyncJob` ein, auch ohne Änderungen und auch auf dem Retry-Guard-Pfad (`isFoldWritten`):
  Doppelte sind leere Syncs und damit harmlos. Parent-Link über `JobExecutionContext.currentJobId()`
  (Muster `PreisVersionJobSubmissionService`). Einreichung **in** der synchronisierten Schreibtransaktion
  des Laufs (der Job-Kontext ist dort enrollt): auf dem Server wird das Item mit den Versionen sichtbar.
  Im H2-only-Launcher sind es zwei Commits; ein zu früher Sync findet weniger und der nächste heilt.
- Nur wenn `ifas.fondspreise.preis-version-sync.enabled` an ist. Aus → kein Sync-Job, eine Logzeile.
- **Manueller Auslöser**: `ScheduledTask` „Preisversionen → `kurs` abgleichen" auf „Geplante Aufgaben",
  `enabled` Default `false`, Cron Default stündlich (für den späteren Sweep), `jobType` =
  `PreisVersionSync`, `dailyRunNumber` `null`. `triggerManually` reicht einen Sync **ohne Parent** ein;
  bei ausgeschalteter Property lehnt er mit Meldung ab (kein versehentlicher Backlog-Write im
  Parallelbetrieb). Der Trigger-Button der Seite ist nicht an `enabled` gebunden (`scheduled-tasks.html:69`).
  Kein Bankarbeitstags-Guard: der Sync hat keinen Stichtag.
- Der `PreisMeldungDiffJob` löst nie einen Sync aus (Entscheidung 2026-10-08, Vorgänger-Plan Abschnitt 7).

### 3.2 Aktiv-Guard — ein Sync zur Zeit

Die Work-Queue hat kein Limit je Task-Type (nur Server-Affinität), die Anwendung keinen Leader-Knoten.
Darum prüft der Sync als Erstes:

- Gibt es ein Work-Item vom Typ `PREIS_VERSION_SYNC` mit Status `RUNNING`, `created_at` **älter** als
  das eigene, `heartbeat_at` jünger als `processingTimeout`? → Versuch beenden mit einer transienten
  Ausnahme (`PreisVersionSyncBusyException` o. ä., eigene Logzeile „wartet auf Sync X"). Die
  Work-Queue wiederholt mit Backoff (`retryBaseDelayMs` 1 s, verdoppelnd, Kappung `retryMaxDelayMs`
  5 min). **Kein Warten im Job.**
- Der ältere gewinnt: zwei gleichzeitig startende Syncs sehen einander, der jüngere tritt zurück. Ein
  eingefrorener älterer (Heartbeat älter als `processingTimeout`) zählt nicht als aktiv; dessen Zombie
  fängt 3.7 ab.
- `getMaxAttempts()` großzügig — Vorschlag **50** (≈ 4 h am Kappungswert; Obergrenze
  `maxMaxAttempts` 100). Warten verbraucht Versuche; ein Sync, der sie aufbraucht, endet `FAILED` als
  Rauschen, der aktive nimmt seine Zeilen. Das Log trennt „gewartet" von „Sybase gescheitert"
  (Abschnitt 5, Support).

### 3.3 Auswahl

`select … from preis_versions where preis_version_sync_job_id is null` — alle Zeilen, nicht die eines Laufs. Daraus
die Menge der Schlüssel; je Schlüssel der aktuelle Stand per Bulk-Read der offenen Versionen
(`PreisVersionRepository.findOpenVersions`, Chunk 4 des Vorgänger-Plans). Gelesene Zeilen merkt sich
der Sync mit `id` **und `invalidated_at`** (für den bedingten Stempel, 3.5).

Leer → Job `COMPLETED` mit Zählern 0, `versions_processed_at null`, eine Logzeile. Erwünscht.

### 3.4 Reconcile je Schlüssel

| aktueller Stand | Fondswährung | Aktion in `kurs` | Zähler |
|---|---|---|---|
| offene Version | = `waehrung` | Delete je vollem Schlüssel, Insert aus 2.4 | `keys_written` |
| offene Version | ≠ `waehrung` | nichts (auch kein Delete — eine solche Zeile hat IFAS nie geschrieben) | `keys_skipped_fondswaehrung`, Log `INFO` *skipped by rule* |
| offene Version | Fonds nicht auflösbar | nichts | `keys_skipped_stammdaten`, Log `WARN` |
| keine offene Version (letzte `deleted`) | — | Delete je vollem Schlüssel | `keys_removed` |

Mehrere ungestempelte Zeilen desselben Schlüssels (beendete und neue) ergeben **einen** Reconcile; jeder
Reconcile ist eine Protokollzeile (2.2).
Stammdaten: `PreisMeldungStammdatenService.createProvider()` im Kontext `business`, `findFonds(isin,
preisdatum)` → `fondswaehrung`; Reihenfolge der Schlüssel deterministisch (`PreisKey`-Ordnung des Laufs),
damit Sybase-Sperren in fester Reihenfolge genommen werden.

### 3.5 Schreiben — eine synchronisierte Transaktion, Sybase zuerst

Der `SynchronizingTransactionManager` ist **Best-effort 1PC**: alle enrollten Datenquellen werden geflusht
und dann **in Enroll-Reihenfolge** nacheinander committet; scheitert ein späterer Commit, sind die früheren
durch, der Rest rollt zurück, `PartialCommitException`. Kein XA. Daraus die eine Disziplin dieses Plans:

> **Sybase muss die zuerst enrollte Datenquelle sein.** Dann kann ein Stempel fehlen (Sybase committet,
> Postgres nicht → der nächste Sync macht die Schlüssel noch einmal, idempotent), aber nie lügen
> (Postgres committet, Sybase nicht → gestempelte Versionen ohne `kurs`-Zeile).

Ablauf in **einer** `with…IsolatedTransactional`-Klammer:

1. Transaktion im Kontext `business` öffnen (Sybase enrollt). **Befund Chunk 4 beachten:**
   `with…IsolatedTransactional` enrollt den aktuellen Kontext des Aufrufers eifrig — aus der Work-Queue
   heraus ist das der Job-Kontext (auf dem Server dieselbe Postgres-Datenquelle wie das Ledger), und
   die stünde dann **vor** Sybase. Der Sync setzt deshalb vor dem Öffnen den Kontext auf `business`
   (oder der Befund wird im Helper behoben — im Chunk entscheiden), und ein Test prüft die Reihenfolge
   von `SynchronizedTransaction.getEnrolledDatabases()`.
2. Stammdaten lesen, `kurs` schreiben (3.4), in Schlüsselreihenfolge.
3. Zombie-Schutz (3.7): bedingtes Update am eigenen Work-Item (`status = RUNNING`, `server_id`,
   `attempt_count` wie beim Start); 0 Zeilen → Ausnahme → Rollback beider Seiten.
4. Stempel setzen — **bedingt**: `update preis_versions set processed_at = :t, preis_version_sync_job_id = :job where
   id = :id and invalidated_at is not distinct from :gelesen`. Eine Zeile, die ein Lauf seit dem Lesen
   beendet hat (`invalidated_at` jetzt gesetzt, Stempel vom Lauf gelöscht), bleibt ungestempelt und ist
   Arbeit des nächsten Syncs. Ohne diese Bedingung würde ein Sync, der eine Version als offen gelesen
   hat, das `D` eines dazwischen committeten Laufs für immer verdecken.
5. Zähler und `versions_processed_at` am Sync-Job (Job-Kontext enrollt, nach Sybase).
6. Commit: Sybase, dann Postgres.

`processed_at` = App-Uhr beim Schreiben, ein Wert für alle Zeilen des Syncs (kein DB-Uhr-Lesen wie
`created_at`: der Stempel ordnet nichts, `currentDbTime()` nimmt eine eigene Connection — Befund Chunk 4).

### 3.6 Selbstheilung und Wiederholungen

| Fall | Ergebnis | Heilung |
|---|---|---|
| Fehler vor der Commit-Phase (Sybase down, Stammdaten-Fehler, Zombie-Schutz) | Rollback beider Seiten | Retry mit Backoff, bis zu `maxAttempts`; dann `FAILED`, Zeilen bleiben ungestempelt → nächster Sync |
| Sybase committet, Postgres-Commit scheitert (`PartialCommitException`) | `kurs` aktuell, Stempel fehlen | nächster Versuch/Sync schreibt dieselben Werte noch einmal; PK in `kurs` wird durch das vorgelagerte Delete nicht verletzt |
| Sync `FAILED` nach allen Versuchen | Spur bleibt, Zeilen ungestempelt | der Sync des nächsten Laufs nimmt sie; ohne weiteren Lauf der manuelle Auslöser |
| Wiederholung eines Syncs (UI-Retry) | wie ein neuer Sync | findet meist nichts mehr |
| `kurs` aus irgendeinem Grund falsch | — | Stempel löschen (SQL-Console), nächster Sync schreibt neu. Keine Daten zu rekonstruieren |

### 3.7 Nebenläufigkeit und Fehler

| Situation | Verhalten | Rest-Risiko |
|---|---|---|
| Zwei Syncs starten gleichzeitig | beide sehen einander, der jüngere tritt zurück (3.2) | keines |
| Lauf committet, während ein Sync schreibt (hat eine Version als offen gelesen, die der Lauf beendet) | der Sync schreibt den gelesenen Stand (für einen Sync veraltet), stempelt die beendete Zeile wegen 3.5 (4) **nicht**; die neue Version ist ungestempelt; der vom Lauf ausgelöste Sync reconcilet den Schlüssel | `kurs` einen Sync lang veraltet |
| Lauf öffnet einen Schlüssel neu (`N` nach `D`, oder erster Preis), während ein Sync das `D` abgleicht | Delete und Insert in beliebiger Reihenfolge; die neue Version ist ungestempelt → nächster Sync | einen Sync lang veraltet |
| Zombie: ein Sync friert ein, Orphan-Recovery setzt sein Item zurück, Versuch 2 oder ein anderer Sync läuft, der Zombie taut auf | Zombie-Schutz 3.5 (3): sein bedingtes Update am Item trifft 0 Zeilen → Rollback vor dem Commit | Fenster zwischen Prüfung und Sybase-Commit (ms); dann `kurs` veraltet bis ein Lauf den Schlüssel anfasst oder jemand Stempel löscht. Pinnen, beobachten |
| Ausfall Sybase über Stunden | jeder Sync scheitert, Retries; die wartenden Syncs verbrauchen Versuche | nach Ende der Versuche `FAILED`-Jobs als Rauschen; Heilung durch den nächsten Lauf oder manuellen Auslöser (bewusst kein Sweep) |
| Sync-Jobs archiviert | Flag blendet aus, löscht nicht → `preis_version_sync_job_id` zeigt immer auf einen existierenden Job | keines |
| jTDS Shared-Calendar-Race (Memory) | nur ein Sybase-Schreiber zur Zeit (3.2) | keines |

### 3.8 Beispiel — drei Preisfiles

F1–F3 → Eingänge E1–E3 → Läufe V1–V3 → Syncs S1–S3; Schlüssel A, B, C, D.

**Ruhiger Tag** (je eine Stunde Abstand): V1 schreibt A, B → S1 nimmt A, B, stempelt „S1". V2 schreibt B
erneut und C → B alt beendet (Stempel gelöscht), B neu und C ungestempelt → S2 nimmt beide B-Zeilen und
C, schreibt B aktuell und C. V3 → S3 nimmt D. Jeder Sync nimmt zufällig genau seinen Lauf.

**Gebündelt** (alle drei Läufe committen, bevor Sybase erreichbar war): S1 nimmt A, B (aktuell), C, D in
einer Transaktion, stempelt alles „S1". S2 und S3 enden leer. V2s Versionen sagen „S1", V2s Kind S2 ist
ein leerer Job — gewollt.

**Verschränkt**: t1 S1 liest A, B alt. t2 V2 committet (B alt beendet, B neu, C). t3 S1 schreibt B alt
nach `kurs` (veraltet), Stempel auf B alt greift nicht (3.5 (4)). t4 S2, bisher zurückgetreten, läuft:
findet B alt, B neu, C → schreibt B aktuell. Veraltet für genau einen Sync.

**Ausfall**: S1 scheitert, Retries über Stunden; V2, V3 committen; S1 gelingt später und nimmt A–D. Oder
S1, S2, S3 brauchen alle Versuche auf → `FAILED`; A–D warten auf den Sync des nächsten Laufs oder den
manuellen Auslöser.

---

## 4. Was der `PreisVersionJob` dafür tut

- **Beenden löscht den Stempel**: beim Beenden einer Version (durch `N` oder `D`) setzt `writeVersions`
  `processed_at`/`preis_version_sync_job_id` auf `null` — die Zeile wird ohnehin aktualisiert (`invalidated_at`,
  `deleted`, `open`). Bei `D` ist die beendete Zeile der einzige Träger von „`kurs`-Zeile entfernen";
  bei `N` deckt die Nachfolgerin den Schlüssel, das Löschen ist dann redundant und billig.
- **Neue Versionen** entstehen ohne Stempel (Spalten-Default).
- **Einreichung des Syncs** nach 3.1, gesteuert über `sync_requested` und die Property.
- Zähler des Laufs: acht statt elf (2.3), Protokoll neu.

---

## 5. UI

- **Detailseite** `/ui/preis-version-sync-jobs/{id}` (`PreisVersionSyncJobDetailPageController implements
  JobDetailPage`, Muster `PreisVersionJobDetailPageController`): Parent-Banner (Lauf, falls vorhanden),
  Karte *Abgleich* (`versions_processed_at`, fünf Zähler), Protokoll und Ausführungslog (beides generisch
  aus `fragments/job-detail.html`: `protocolText`). Pfade ins Recht
  `PREIS_VERSIONEN` (`IfasRight`), Autorisierungstest ergänzen (`web-authorization.md`).
- **Laufseite**: das Sync-Kind erscheint in der generischen Karte *Teilaufgaben*
  (`fragments/job-detail.html:286`) — prüfen, dass der Link auf die neue Detailseite auflöst.
- **Preisversionen-Seite**: an jeder Version eine Spalte *`kurs`*: „seit `processed_at` (Sync X)" mit
  Link, sonst „ausstehend". `PreisVersionsView`/`PreisVersionQueryService` ergänzen; keine Cross-Context-
  Lesung nötig, beide Werte stehen auf der Version.
- **Geplante Aufgaben**: der Task aus 3.1 mit Trigger-Button; Anzeige „Aktiv: Nein" bis zum Sweep.
- **Support-Pfad** bei „Preis fehlt in `kurs`": Preisversionen-Seite → Version → *ausstehend* (kein Sync
  seit dem Lauf: Sync-Kind des Laufs ansehen, ggf. manuell auslösen) oder *seit … Sync X* → Protokoll von X:
  *skipped by rule* / *skipped: Stammdaten* / normal geschrieben (dann ist `kurs` anderweitig verändert).

---

## 6. Flyway

Ein File je Baum für dieses Feature (Regel). Nur der **Postgres-Baum** (H2 teilt ihn); in Sybase nichts
(Schema-Freeze). Nummer beim Start des Chunks prüfen (heute lokal V078; `origin/master` und
Geschwister-Branches ansehen, wie beim Chunk 4 des Vorgänger-Plans): voraussichtlich **V079**:

- `preis_versions`: `processed_at`, `preis_version_sync_job_id`, Check, Index (2.1)
- `preis_version_jobs`: `sync_requested`; Drop `zeilen_no_key`, `zeilen_without_effect`, `versions_deleted` (2.3)
- `preis_version_sync_jobs` (2.2) mit Grants wie V076

Kein Backfill: alle bestehenden Versionen bleiben ungestempelt (Go-live-Backlog, Abschnitt 7).

---

## 7. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **`tmp_if_last`** | eigener Plan, wenn Klärung N (Zweck des Fallbacks) und O (Fremdleser) stehen. Aus dem Ledger: Schlüssel, Wert, `dat_kurs`. Nicht auf der Version: Lieferant (nur der Eingang kennt ihn; Vorgänger-Plan Abschnitt 7 „Lieferant auf der Version") und Ankunftszeit (Inbox-Zeile, über `preis_version_sources` erreichbar, solange das Inbox-Fenster sie hält — vor der Aufräumregel entscheiden). Fondsbezeichnung aus den **IFAS-Stammdaten** (User 2026-10-08; Legacy pflegt `txt_bez` bei ISIN-Umbenennung ohnehin nach, `ISIN_UPD.CPP:228`). Semantik „zuletzt verarbeitet gewinnt, `D` lässt stehen" vs. „offene Version mit höchstem `preisdatum`" dort entscheiden |
| **Stündlicher Sweep** | `scheduled-tasks.preis-version-sync.enabled=true` — nur relevant, wenn nach einem Ausfall alle Syncs des Tages ihre Versuche aufgebraucht haben und kein weiteres File kommt |
| **Go-live-Backlog** | Die Versionen aus dem Parallelbetrieb (Diff-Job) sind ungestempelt; der erste produktive Sync würde den gesamten Backlog gegen die Neusystem-Sybase abgleichen. **Verfahren entschieden 2026-10-12 (User):** die Neusystem-Sybase startet mit einem migrierten Stand von `kurs` (Voll-Sync aus der Alt-DB, Snapshot-Zeitpunkt T). Alles, was Legacy bis T geschrieben hat, steht damit schon in `kurs`; alles danach schreibt Legacy nur noch in die Alt-DB. Daher: **Migrations-Stempel** — alle Versionen mit `created_at < T` per SQL stempeln (`processed_at = T`, `preis_version_sync_job_id` = ein eigens angelegter `PreisVersionSyncJob` „migration“, COMPLETED, damit die Spalte *kurs* „seit T (Sync …)“ zeigt und der Link auflöst); alles ab T bleibt ungestempelt und ist Arbeit des ersten echten Syncs. Spätere Änderungen an alten Schlüsseln fließen trotzdem: ein Lauf, der eine gestempelte Version beendet, löscht ihren Stempel. Snapshot in einem ruhigen Fenster nach Legacys letztem Schreiben des Tages, damit „vor T erzeugt“ und „von Legacy geschrieben“ dieselben Lieferungen meinen; wird die Migration vor dem Go-live wiederholt, wandert T mit. Schlüssel, die Legacy schrieb, der Parallelbetrieb aber nie sah, bleiben migriert und unberührt. D13 ist damit keine Go-live-Voraussetzung. Ein Pro-Lauf-Design hätte den Schritt stillschweigend übersprungen |
| **D13 für `kurs`/`tmp_if_last`** | vertagt (User 2026-10-08): Ledger projiziert gegen Alt-`kurs`, oder erst mit dem produktiven Job auf TEST |
| **Kennzahlen** | Auffüllen von `num_bericht_kurs` nach einem `R`-Rewrite; Invalidierung von `ASF.r_faktor` (Klärung K) — Schnitt 6 |
| **Produktiver Preismeldungs-Job** | Tracker; er ist der erste Einreicher mit `sync_requested = true`. Bis dahin hat der Sync außer Tests und dem manuellen Auslöser keinen Aufrufer |
| **Partitionierung des Ledgers** | unverändert Vorgänger-Plan |
| **Benachrichtigung des Fachbereichs** | Der Sync schneidet nur mit (`executeWithProtocol`); ob `WARN` im Protokoll (Stammdaten-Skip) eine Mail auslöst (`…AndNotifyOnErrorsOrWarnings`), mit dem produktiven Job entscheiden |

---

**Nachtrag 2026-10-13 — Go-live-Backlog und Selbstheilung nach Sybase-Snapshot:** der Migrations-Stempel für den Sync ist
kein eigenes Werkzeug mehr. Der Sync prüft am Anfang seine Kanarienzeile (die `kurs`-Zeile der jüngsten offenen Version,
die er selbst geschrieben hat, `preis_versions.kurs_guelt`), erkennt daran einen ersetzten `kurs` (Voll-Refresh der
Neusystem-Sybase) und setzt das Ledger auf T − Marge; ohne Kanarie stempelt er den Backlog vor T als „von Legacy
geschrieben“ — das ist die erste Aktivierung. Mail bei `WARN` an den System-Support. Eigener Plan:
[2026-10-13-fondspreise-sync-selbstheilung-sybase-snapshot.md](2026-10-13-fondspreise-sync-selbstheilung-sybase-snapshot.md).

## 8. Chunks

Reihenfolge wie gehabt: Persistenz zuerst, Live-Verdrahtung zuletzt; jeder Chunk ein Commit, Opus-Subagent
implementiert, Fable reviewt, User committet.

### Chunk 1 — Persistenz

- **Inhalt:** Migration (Abschnitt 6); `PreisVersion` um `processedAt`/`preisVersionSyncJobId` (Javadoc nennt
  `preis_version_sync_jobs` als Ziel, kein FK); `PreisVersionRepository`: Bulk-Read
  `preis_version_sync_job_id is null`, bedingter Stempel (3.5 (4)) als JPQL-Bulk-Update in zwei Statements (gelesen als
  offen: nur wenn `invalidated_at` noch null; gelesen als beendet: ohne Bedingung, eine beendete Zeile
  ändert sich nie mehr), `endOpenVersion` löscht die Stempel gleich mit (Abschnitt 4; Chunk 4 testet es
  nur noch über den Lauf); `PreisVersionJob.syncRequested`;
  Entity `PreisVersionSyncJob` + Repository mit `updateResult` (fünf Zähler, `versions_processed_at`);
  `Kurs`-Schreibpfad ist vorhanden (V073, Repository-Deletes) — nur prüfen.
  **Nachtrag 2026-10-08:** Zähler-Diät und Protokoll des Laufs (2.3) gehören mit in diesen Chunk, weil der
  Drop in V079 liegt: `PreisVersionJob`/`updateResult` ohne die drei Spalten,
  `PreisVersionJobExecutionService` in `executeWithProtocol` mit den Protokollzeilen, Detailseite ohne die
  drei Zeilen und mit `protocolCard`, Schema-Referenz.
- **Tests** (Multi-DB): Stempel-Update greift nur bei unverändertem `invalidated_at`; Check-Constraint;
  Sync-Job speichern/lesen; `syncRequested` Default; Lauf-Zähler (acht) und Protokolltext des Laufs
  (`PreisVersionJobTest`), Controller-Test der Detailseite.
- **Stand 2026-10-08 — umgesetzt, Commit `22adddcf6`** (gepusht). V079 beide Bäume, Stempel mit
  `preis_version_sync_job_id`, Sync-Job mit fünf Zählern, Lauf mit Protokoll und acht Zählern; 90
  Integrationstests H2 + Postgres und 4 Controller-Tests grün. Bekannt: ein Lauf, der nach dem Commit seines
  Folds abbricht, verliert sein Protokoll (der Retry schreibt nur *already written*); nur der Skip-Grund
  `UNKNOWN_ISIN` ist im Protokoll getestet (Fixture kann nur einen Fonds anlegen).

### Chunk 2 — Reconcile als Komponente

- **Inhalt:** reine Ableitung „ungestempelte Zeilen + offene Versionen + Stammdaten → je Schlüssel eine
  `KursAenderung` (write/remove/skip mit Grund)" ohne DB (Domäne `ifas-domain-fondspreise` oder
  Service-Paket, im Chunk entscheiden; Muster `PreisZeitreihe`/Faltung des Vorgänger-Plans).
  `Meldekategorie` → `cod_fliesscode`, `wert` → `double`.
- **Tests:** Unit: jede Zeile der Tabelle 3.4; mehrere Zeilen eines Schlüssels → ein Reconcile; feste
  Schlüsselreihenfolge.
- **Nachtrag 2026-10-09 (umgesetzt, Benennung User):** Domäne, Paket `verarbeitung` neben der Faltung.
  `KursChanges.derive(unprocessed, openByKey, stammdaten)` → `List<KursChange>` (nicht `KursAenderung`,
  nicht *Reconciler*: die Klasse gleicht nichts an, sie leitet ab; *Reconcile* bleibt der Name des Schritts).
  `KursChange` ist ein sealed interface: `Write(key, KursData)`, `Remove(key, numWfsKu)`,
  `SkippedFondswaehrung(key, fondswaehrung)`, `SkippedStammdaten(key)`; `KursData` die Zeile aus 2.4
  (`numWfsKu`, `datKurs`, `codFliesscode` = Name der Meldekategorie, `waehrung`, `numKurs` als `double`),
  ohne `guelt` (setzt der Sync). Entschieden wird **allein nach `openByKey`** — ungestempelte Zeilen und offene
  Versionen sind zwei Reads, ein Lauf kann dazwischen committen (3.8 „Verschränkt"); die ungestempelten
  Zeilen nennen nur den Schlüssel und, für ein `Remove`, den Fonds der jüngsten Zeile (Kettenordnung).
  Einträge in `openByKey` ohne ungestempelte Zeile werden ignoriert (der Aufrufer darf die Obermenge von
  `findOpenVersions` durchreichen). `PreisKey` ist jetzt `Comparable` (ISIN, Preisdatum, Währung, Name der
  Meldekategorie); der Lauf nutzt die natürliche Ordnung statt seines privaten `KEY_ORDER`.
  Kein Logging, keine Zähler in der Komponente — beides macht der Sync (Chunk 3).
- **Stand 2026-10-09 — umgesetzt, Commit `068df2816`** (gepusht). 24 neue Unit-Tests (`KursChangesTest` 12,
  `KursDataTest` 2, `PreisKeyTest` +1), Domänenmodul 203 Tests grün; `PreisVersionJobTest` und
  `PreisVersionJobInterleavingTest` (30) unverändert grün nach dem `KEY_ORDER`-Umbau.

### Chunk 3 — Der `PreisVersionSyncJob`

- **Inhalt:** Submission-Service (mit/ohne Parent), Execution-Service als `WorkQueueHandler`
  (`maxAttempts` 50), Aktiv-Guard 3.2 (Repository-Query am Work-Item: Typ, `RUNNING`, älter, Heartbeat
  frisch), Ablauf 3.3 → 3.5 in einer synchronisierten Transaktion mit **Sybase zuerst** (Kontext vor
  dem Öffnen auf `business` setzen oder den eifrigen Enroll im Helper beheben — Befund Chunk 4 des
  Vorgänger-Plans), Zombie-Schutz, bedingter Stempel, Zähler, Protokoll (2.2: `executeWithProtocol`
  um die Ausführung, URI im `onSuccess`; Logzeilen je Schlüssel, *wartet auf Sync X*, Zähler-Summary).
  Property `ifas.fondspreise.preis-version-sync.enabled` in
  `FondspreiseProperties` (Default `false`; Server-Deployment: erst zum Go-live `true`).
  `PreisVersionSyncJobHooks` als Test-Seam nach dem Muster `PreisVersionJobHooks` (nach dem Lesen /
  vor dem Schreiben / nach dem Sybase-Commit).
- **Tests** (Integration, Multi-DB, `kurs` liegt im selben Test-DB): Beispiel 3.8 „ruhiger Tag" und
  „gebündelt" mit direkt eingereichten Syncs; leerer Sync; Skip-Regel (Fremdwährung, fehlende Stammdaten)
  stempelt und schreibt nicht; `D` entfernt die `kurs`-Zeile; das Protokoll nennt jeden Schlüssel mit
  seiner Aktion; Retry nach Fehler schreibt nichts doppelt
  (PK); Reihenfolge der enrollten Datenquellen beginnt mit dem Business-Key (einziger Punkt, den die
  Ein-DB-Tests nicht beweisen — siehe Chunk 6).
- **Nachtrag 2026-10-09 (umgesetzt):** Sybase zuerst durch Konstruktion — der Sync setzt den Kontext
  `business` und öffnet **dann** `doIsolatedTransactional`, sodass der eifrige Enroll in `doBegin` Sybase
  nimmt; `withDatabaseContextIsolatedTransactional` bewusst nicht (beginnt vor dem Umschalten, nähme den
  Kontext des Work-Items, auf dem Server das Ledger). Aktiv-Guard als generische Work-Queue-Lesung
  `WorkQueueService.findActiveOlderItemsOfType` (Totalordnung `created_at`, dann `id`: zwei Syncs derselben
  Mikrosekunde sehen nie beide nichts), wirft `PreisVersionSyncBusyException`, läuft als Erstes, auch für
  leere Syncs. Zombie-Schutz als generisches `WorkQueueService.confirmOwnership` (bedingter Heartbeat-Touch
  am eigenen Item nach Server und `attempt_count`, 0 Zeilen → Ausnahme → Rollback; verlangt die aktive
  Transaktion). Offene Versionen über **eine** Query `findOpenVersionsOfUnprocessedKeys` (EXISTS auf
  ungestempelte Zeilen desselben Schlüssels, keine IN-Liste); nur die Stempel in 1000er-Chunks.
  `kurs`-Write je Schlüssel Delete, `persist`, `flush` (das Repository-Delete leert den Persistence-Context).
  `processed_at` = `OffsetDateTimes.now()`, `guelt` = `LocalDateTimes.nowInVienna()`. `PreisKey.describe()`
  ersetzt das private `describe` des Laufs. Property `ifas.fondspreise.preis-version-sync.enabled` als
  verschachtelte Klasse, liest noch niemand. **Akzeptiert:** ein Retry nach committetem Write findet nichts
  und überschreibt die Zähler mit Nullen (die Stempel tragen die Job-Id). **Verschoben:** Hook-getriebene
  Fälle (Retry nach werfendem Hook, Zombie, zwei Syncs gleichzeitig) nach Chunk 5, die Enroll-Reihenfolge
  nach Chunk 6 (dort einen öffentlichen Zugriff auf die Enroll-Reihenfolge am `SynchronizedTransactionHolder`
  ergänzen); stattdessen hier: Aktiv-Guard durch den echten Executor mit handgeclaimtem Item (aktiv und
  eingefroren), Reparatur „Stempel löschen, Sync erneut" als Idempotenz-Beweis.
- **Stand 2026-10-09 — umgesetzt, Commit `47094764d`** (gepusht). `PreisVersionSyncJobExecutionService`,
  `…SubmissionService`, `…Hooks`, `PreisVersionSyncBusyException`; `PreisVersionSyncJobTest` 7 Fälle × 2 DBs,
  dazu Repository-/Service-Tests der Work-Queue (+8), `PreisVersionRepositoryTest` (+1),
  `FondspreisePropertiesTest` (+2); Lauf- und Verschränkungstests unverändert grün.

### Chunk 4 — Der Lauf

- **Inhalt:** Stempel-Löschen beim Beenden liegt schon im Repository (Chunk 1); Einreichung des Syncs nach 3.1
  (`sync_requested` + Property), auch ohne Änderungen und auf dem Guard-Pfad; `submit(createdBy,
  syncRequested)`, Diff-Job übergibt `false`.
- **Tests:** Lauf beendet gestempelte Version → Stempel weg; Lauf mit `sync_requested` → Sync-Kind mit
  Parent, ohne → keines, Property aus → keines; Diff-Job-Kette erzeugt nie einen Sync.
- **Nachtrag 2026-10-09 (umgesetzt):** Die Einreichung liegt **nach** der Schreibtransaktion des Laufs, in der
  umgebenden Handler-Transaktion, als letzter Schritt aller drei Ausgänge (Guard-Pfad, keine Änderungen,
  geschrieben) — nicht in der Schreibtransaktion wie in 3.1 geplant: ein Pfad statt drei, und das Sync-Item wird
  mit dem Abschluss des Laufs sichtbar, also nach seinen Versionen; der H2-only-Vorbehalt aus 3.1 („zwei Commits,
  ein zu früher Sync findet weniger") entfällt damit. `submit(createdBy, syncRequested)` ohne Überladung, Diff-Job
  übergibt `false`. Property aus → eine INFO-Zeile im Protokoll des Laufs. Nebeneffekt: das Protokoll des Laufs
  enthält auch die „Submitting job"/„Submitted work item"-Zeilen der Einreichung. Tests schalten die Property
  nur innerhalb des Falls ein (`withSyncEnabled`, restore in `finally`).
- **Stand 2026-10-09 — umgesetzt, Commit `34b20d641`** (gepusht). `PreisVersionJobTest` +6 Fälle (Stempel weg bei N und D,
  Sync-Kind mit beiden Parent-Links, Flag aus, Property aus, leerer Lauf, Guard-Pfad reicht erneut ein),
  Diff-Ketten-Test erweitert; alle Fondspreise-Integrationstests grün.

### Chunk 5 — Verschränkungs-Tests

- **Inhalt:** nach dem Muster `PreisVersionJobInterleavingTest` (zwei handgebaute Executor, Hooks):
  (1) zwei Syncs gleichzeitig → der jüngere tritt zurück, Retry, dann leer; (2) Lauf committet zwischen
  Lesen und Schreiben → beendete Zeile bleibt ungestempelt, der nächste Sync heilt, `kurs` am Ende
  aktuell; (3) `N` nach `D` während des Syncs → nächster Sync heilt; (4) Zombie nach Orphan-Recovery
  → Zombie-Schutz, kein Write; (5) Fehler nach Sybase-Commit vor Stempel (Hook wirft) → Stempel fehlen,
  Retry schreibt idempotent; (6) Ausfall: alle Versuche verbraucht → `FAILED`, Lauf 4 heilt alles.
- **Tests:** genau diese sechs, H2 + Postgres.
- **Nachtrag 2026-10-09:** Seams liegen bereit — `PreisVersionSyncJobHooks` (`afterRead`, `beforeWrite`,
  `afterKursWritten` innerhalb der Transaktion vor Zombie-Schutz und Stempel, `afterCommit`) und der
  Test-Konstruktor der Execution-Service; die Executor-Bauweise aus `PreisVersionJobInterleavingTest`
  (eigener `ServerIdProvider` je Server, auch an den Sync-Service geben).
- **Nachtrag 2026-10-09 (umgesetzt):** Harness in `TwoServerWorkQueue` (Test-Paket) extrahiert, beide
  Verschränkungstests nutzen sie; je Server eine eigene Sync-Service-Instanz mit eigenem `ServerIdProvider`
  (der Zombie-Schutz vergleicht den Server des Items). Alle sechs Fälle verhielten sich wie in 3.7/3.8
  vorhergesagt, keine Produktionsänderung. Fall 5 im Ein-DB-Profil: der Hook-Wurf rollt auch `kurs` zurück; eine
  von Hand gesetzte `kurs`-Zeile steht für den halb committeten Versuch und wird ersetzt (echter Zwei-Quellen-Fall:
  Chunk 6). Fall 6 senkt `max_attempts` des Items im Test auf 3. Mutationsprobe des Agenten: ohne Zombie-Schutz,
  ohne Aktiv-Guard, ohne `invalidated_at`-Bedingung des Stempels fallen die Fälle 4, 1, 2.
  Beobachtung: der aufgetaute Versuch überschreibt das `execution_log` des Items (unbedingtes `saveExecutionLog`),
  verliert aber nichts, da beide Versuche denselben MDC-Task teilen.
- **Stand 2026-10-09 — umgesetzt, Commit `f5091bb5f`** (gepusht). `PreisVersionSyncJobInterleavingTest` 6 × 2 DBs grün,
  zweimal gelaufen; `PreisVersionJobInterleavingTest` unverändert 14 grün.

### Chunk 6 — Commit-Reihenfolge mit zwei Datenquellen

- **Inhalt:** ein Test, in dem `business` und `business-new-introduced` **verschiedene** Datenquellen
  sind (im Testprofil zeigen alle Keys auf `h2-test`, Memory „DB-Kontext-Blindfleck"): billigste
  Variante zweiter H2-Key für `business`, sonst `SybaseTestcontainer` neben Postgres. Beweist: Sybase
  committet zuerst; Postgres-Commit-Fehler nach Sybase-Commit lässt Stempel fehlen und `kurs` korrekt;
  der umgekehrte Fall tritt nicht ein.
- Berührt ggf. das Tracker-Todo „Dual-DB-Testprofil".
- **Nachtrag 2026-10-09 (umgesetzt):** Kein neues Testprofil und kein `SybaseTestcontainer` — das Modul
  `ifas-integration-tests-multidbctx` fährt bereits drei physische H2-Datenbanken mit dem produktiven Routing:
  `h2-test-write` = `business` (`kurs`, Stammdaten), `h2-test` = `business-new-introduced` (Ledger),
  `h2-infra-test` = Job-System/Work-Queue/Filestore. Test `PreisVersionSyncJobCommitOrderMultiDbCtxTest`
  (4 Fälle, Ein-Server-Executor von Hand wie `TwoServerWorkQueue`; der Sync wird aus dem **Ledger**-Kontext
  eingereicht, damit sein Item den Schlüssel trägt, den `withDatabaseContextIsolatedTransactional` zuerst
  enrollen würde). Enroll- = Commit-Reihenfolge dort `[h2-test-write, h2-infra-test, h2-test]`: Business, dann
  Infra (Zombie-Schutz), dann Ledger (Stempel) — am Server sind Ledger und Job-System dieselbe Postgres, also
  Sybase, dann Postgres. Fehlerinjektion: ein Hibernate-`BeforeTransactionCompletionProcess` auf der enrollten
  Session der gewählten DB, registriert aus einem Spring-`beforeCommit` (läuft nach allen Enrolls, vor
  `doCommit`, enrollt selbst nichts); er wirft im `EntityTransaction.commit()` dieser DB, also nach den
  Commits der davor enrollten. Ledger-Commit scheitert → `PartialCommitException: committed [h2-test-write,
  h2-infra-test], failed on 'h2-test'`: `kurs` geschrieben, Stempel fehlen, **Zähler des Sync-Jobs schon
  committet** (Infra vor Ledger; am Server fielen Zähler und Stempel gemeinsam), der Retry schreibt dieselbe
  Zeile (`1 replaced`) und stempelt. Business-Commit scheitert → `committed [], failed on 'h2-test-write'`:
  nichts committet, der Retry heilt. Öffentlicher Zugriff `SynchronizedTransactionHolder.enrolledDatabaseKeys()`
  (+3 Unit-Tests). Mutationsprobe: mit `withDatabaseContextIsolatedTransactional` enrollt der Item-Kontext
  `h2-test` zuerst — Fall 2 (Reihenfolge), Fall 3 (`committed []`) und Fall 4 (`committed [h2-test]`: Stempel
  ohne `kurs`, genau der verbotene Zustand) fallen. Nebenbefund: `ScheduledTaskDbContextMultiDbCtxTest` hielt
  seinen gecachten Kontext mit laufendem Executor (100 ms Polling) am Leben, der Items späterer Klassen aus
  der geteilten In-Memory-Infra-DB claimte und auto-retryte → dort `@DirtiesContext`.
- **Stand 2026-10-09 — umgesetzt, Commit `03804889c`** (gepusht). `PreisVersionSyncJobCommitOrderMultiDbCtxTest`
  4 Fälle grün, Modul `ifas-integration-tests-multidbctx` 19/4 skipped (zweimal gelaufen), `multidbctx-support`
  38 Unit-Tests; `PreisVersionSyncJobExecutionService` unverändert.

### Chunk 7 — UI und Auslöser

- **Inhalt:** Detailseite, Recht, Autorisierungstest; Spalte *`kurs`* auf der Preisversionen-Seite;
  `ScheduledTask` mit manuellem Auslöser (Property-Prüfung), Properties
  `scheduled-tasks.preis-version-sync.{enabled,cron}`; `ifas13-jobs.md` um den Sync ergänzen.
- **Tests:** Seiten-Render (Muster `ThymeleafPageTestBase`), Autorisierung, Task erscheint und reicht ein.
- **Nachtrag 2026-10-12 (umgesetzt):** Detailseite `PreisVersionSyncJobDetailPageController` (`/preis-version-sync-jobs`,
  `JobDetailPage`, aktive Seite `preis-versionen`, kein Menüeintrag; Karten *Preis-Abgleich*, *Abgleich* mit
  „Stempel der Versionen“ und dem Hinweis „(keine Version verarbeitet)“ für einen leeren Sync, *Zähler* mit den
  fünf Spalten, Protokoll) samt `PreisVersionSyncJobQueryService`; Pfade in `IfasRight.PREIS_VERSIONEN`
  (bestehendes Recht, kein neues Provisioning), +8 Autorisierungsfälle. Spalte *kurs* auf der
  Preisversionen-Seite über zwei neue Komponenten `processedAt`/`preisVersionSyncJobId` an
  `PreisVersionsView.VersionRow` (aus der Entity gefüllt; `PreisVersionData` unverändert): „seit … (Sync …)“
  mit Link, sonst „ausstehend“. `PreisVersionSyncSchedulingConfig` nach dem Muster der Ausschüttungs-Batches:
  Task `preis-version-sync` „Preisversionen → kurs abgleichen“, `jobType` `PreisVersionSync`, kein
  `dailyRunNumber`; `triggerManually` ignoriert `keyDate` und lehnt bei ausgeschalteter Property mit
  „Der Abgleich ist ausgeschaltet (ifas.fondspreise.preis-version-sync.enabled)“ ab (die Seite zeigt
  „Fehler beim Auslösen: …“); `scheduledTrigger` ohne Bankarbeitstags-Guard und ohne Duplikatprüfung
  (jeder Server feuert, der Aktiv-Guard lässt den jüngeren zurücktreten). Properties
  `scheduled-tasks.preis-version-sync.{enabled,cron}` (Default aus, stündlich) in der Klasse und in den drei
  Properties-Files (Hauptanwendung, `ifas-integration-tests`, `-multidbctx`; der `@Scheduled`-Platzhalter hat
  keinen Default, jeder Kontext mit Service-Scan braucht die Zeile). `ifas13-jobs.md`: Abschnitt
  `PreisVersionSyncJob`, Lauf-Abschnitt nachgezogen (Zähler, `sync_requested`, Stempel-Löschung beim Beenden).
  Tests: Render der Detailseite (5), Preisversionen-Seite (+1, zwei Schlüssel: gestempelt und ausstehend — ein
  Vorgänger und sein Nachfolger sind nie verschieden gestempelt, das Beenden löscht den Stempel),
  `PreisVersionQueryServiceTest` (+1 Stempel-Durchreichung), `PreisVersionSyncScheduledTaskTest` (6 × 2 DBs:
  Bean vorhanden, manuell mit/ohne Property, Sweep aus / an / Property aus), Autorisierung.
- **Stand 2026-10-12 — umgesetzt, Commit `1e23c2c5f`** (gepusht). 18 Files; web-core 58, web-ui 22,
  main-service 11, Integrationstests 70 (H2 + Postgres), multidbctx-Boot 4 — alle grün. **Damit sind alle sieben
  Chunks des Plans umgesetzt.** Offen bleibt, was Abschnitt 7 bewusst ausklammert: der produktive
  Preismeldungs-Job als erster Einreicher mit `sync_requested`, die Go-live-Backlog-Entscheidung vor dem
  Einschalten von `ifas.fondspreise.preis-version-sync.enabled`, `tmp_if_last`.

---

## Quellen

- Vorgänger-Plan [2026-09-30-fondspreise-preis-historie-versionen.md](2026-09-30-fondspreise-preis-historie-versionen.md), Abschnitte 2.3, 3.5, 3.7, 4, 7, Chunk 4 (Befunde eifriger Enroll, `currentDbTime()`), Chunk 7 (Hooks, Zombie)
- Legacy-Analyse [2026-09-30-fondspreise-legacy-analyse-und-befunde.md](2026-09-30-fondspreise-legacy-analyse-und-befunde.md), Abschnitte 4 (`WriteKurse`, `guelt`, `ignore_dup_key`), 5 (`tmp_if_last`), 10 (Invariante „veröffentlicht ⊆ in `kurs`", 2026-09-17)
- `support-libs/multidbctx-support/.../SynchronizingTransactionManager.java` (Best-effort 1PC, Enroll-Reihenfolge, `PartialCommitException`)
- `ifas-services/.../workqueue/WorkQueueProperties.java` (Backoff 1 s … 5 min, `processingTimeout` 5 min, `maxMaxAttempts` 100), `WorkQueueExecutor` (Orphan-Recovery, Heartbeat)
- `ifas-persistence-inv/.../Kurs.java`, `KursRepository.java`, V073 (`kurs` in jedem Profil)
- `ifas-services/.../schedule/ScheduledTask.java`, `scheduled-tasks.html` (Trigger unabhängig von `enabled`)
- `Ifas/cprogs2/calc/preisekennzahl.cpp:719-800` (`WriteKurse`: Spalten und `getdate()`)
- Diskussion 2026-10-08 (dieser Plan): Entscheidungen in Abschnitt 1
