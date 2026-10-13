# Fondspreise — Selbstheilung des Syncs nach einem Sybase-Snapshot

Plan vom 2026-10-13. Erweitert den `PreisVersionSyncJob` aus
[2026-10-08-fondspreise-preis-version-sync-kurs.md](2026-10-08-fondspreise-preis-version-sync-kurs.md): der Sync
erkennt selbst, dass die Neusystem-Sybase (`kurs1`) komplett aus der Alt-DB ersetzt wurde, setzt das Ledger auf den
Stand des Snapshots und macht dann normal weiter. Der Tracker-Todo „Migrations-Stempel vor Go-live“ fällt damit für
den Sync weg; für das Preisfile bleibt der einmalige Publikationsstempel (Abschnitt 10).

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Alt-DB** | Sybase IFAS-ALT (`sybase-gast`), schreibt nur Legacy |
| **`kurs1`** | Tabelle `kurs` der Neusystem-Sybase (`sybase-ifasneu`, Kontext `business`); Schreiber: der Refresh und unser Sync, sonst niemand |
| **Refresh** | Vollständiges Ersetzen der Neusystem-Sybase durch eine Kopie der Alt-DB, derzeit alle 1–3 Wochen (User 2026-10-13) |
| **Ledger** | `preis_versions` (Kontext `business-new-introduced`, Postgres; lokal/Tests H2) |
| **Stempel** | `processed_at` + `preis_version_sync_job_id` einer Version: „`kurs1` spiegelt diese Version“ |
| **`guelt`** | Schreibzeitpunkt einer `kurs`-Zeile: Legacy setzt `getdate()`, der Sync `nowInVienna()`; Sybase `datetime`, lokal `timestamp(6)` |
| **Kanarienzeile** (engl. *canary*) | Die `kurs`-Zeile der jüngsten offenen Version, die der Sync selbst geschrieben hat, samt dem `guelt`, das er dabei gesetzt hat. Steht sie noch so da, hat seit unserem letzten Schreiben niemand die Tabelle ersetzt |
| **T** | Jüngstes `guelt` in `kurs1` nach dem Laden = letzter Legacy-Schreibvorgang vor dem Dump, Näherung für die Dump-Zeit |
| **T_eff** | `T − Marge` (Standard 30 Minuten), die Grenze, mit der das Ledger verglichen wird |

## 1. Befund und Entscheidungen (User 2026-10-13)

- Jeder Refresh überschreibt alles, was IFAS-NEU in seine Sybase schreibt — für die STM-Tabellen vorerst akzeptierter
  Verlust, Team-Diskussion offen (Tracker). Für `kurs1` gilt: nach dem Laden ist `kurs1` = Alt-DB zur Dump-Zeit.
  Alles, was der Sync **vor** T geschrieben hat, steht via Legacy drin; alles **nach** T ist weg, das Ledger behauptet
  es aber weiter („gestempelt“).
- Kein manueller Stempel-Lauf und kein Handschlag mit dem Betrieb: der Sync erkennt den Refresh selbst und heilt.
  Harter Schnitt oder Refresh ohne `kurs1` ändern am Sync dann nichts mehr — die Erkennung schlägt nur nicht mehr an.
- Mail bei `WARN`, aber **an den System-Support (die konfigurierten Entwickler), nicht an den Fachbereich**
  (User 2026-10-13). Dafür bekommt die Job-Benachrichtigung eine Empfängergruppe je Job-Typ (Abschnitt 5).
- Die erste produktive Aktivierung auf TEST ist derselbe Fall ohne Kanarienzeile: der Sync stempelt den
  Parallelbetriebs-Backlog vor T als „von Legacy geschrieben“ und schreibt nur, was nach T kam. Das ist der
  Migrations-Stempel für den Sync, ohne eigenes Werkzeug.

## 2. Die Regel

### 2.1 Prüfung am Anfang jedes Syncs

Nach dem Aktiv-Guard (Sync-Plan 3.2), vor dem Lesen der ungestempelten Versionen:

1. **Kanarienzeile suchen** im Ledger: die offene Version mit dem jüngsten `kurs_guelt` (neue Spalte, 3.1).
   Keine → Fall *ohne Kanarienzeile*.
2. **Zeile in `kurs1` lesen** (PK-Lookup `findById(KursId)`). Fehlt sie oder trägt sie ein anderes `guelt` als das
   gemerkte → Fall *ersetzt*. Gleich → nichts passiert, normaler Delta-Lauf.

Vergleich auf Sekunden: der Sync schreibt `guelt` ab jetzt auf Sekunden abgeschnitten
(`nowInVienna().truncatedTo(SECONDS)`), damit Sybase (`datetime`, 1/300 s) und Postgres/H2 (`timestamp(6)`) exakt
das Gemerkte zurückliefern. Ein Legacy-`getdate()` hat Millisekunden und ist damit immer „anders“.

### 2.2 T bestimmen

`T = max(guelt)` über die `kurs`-Zeilen mit `dat_kurs ≥ heute − Fenster` (Standard 65 Tage) — der Index
`kurs_2_index (dat_kurs, …)` trägt das, ein voller Scan von `kurs` (Jahrzehnte) nicht. Legacys letzter Schreibvorgang
vor einem Dump betrifft praktisch immer ein junges Preisdatum; eine Einschränkung kann T nur **kleiner** machen, und
ein zu kleines T ist ungefährlich (2.4). `T_eff = T − Marge`. Kein `guelt` im Fenster (`kurs` leer, lokal/Tests) →
T = null.

### 2.3 Die drei Updates am Ledger

| # | Fall | Update | Zähler |
|---|---|---|---|
| 1 | ohne Kanarienzeile **und** ersetzt | **als vorhanden stempeln:** ungestempelte offene Versionen mit `created_at < T_eff` (`markProcessedOpen`-Semantik), ungestempelte beendete mit `invalidated_at < T_eff` (`markProcessedEnded`-Semantik); `processed_at = jetzt`, Job = dieser Sync | `versions_snapshot_stamped` |
| 2 | nur ersetzt | **Stempel löschen:** alle Versionen mit `processed_at ≥ T_eff` → `processed_at`, Job-Id, `kurs_guelt` = null. Ihre Writes und Removes sind überschrieben; der Delta-Lauf desselben Syncs macht sie noch einmal | `versions_snapshot_cleared` |
| 3 | nur ersetzt | **Eigentum vergessen:** `kurs_guelt = null` auf allen Versionen. Nach einem Refresh ist keine Zeile mehr von uns; was Regel 2 freigibt, bekommt beim Rewrite ein neues `kurs_guelt` | — |

Reihenfolge 2, 3, 1. T = null: ohne Kanarienzeile nichts zu tun; ersetzt mit T = null (Tabelle leer) → Regel 2 und 3
ohne Grenze (alle Stempel weg, alles wird neu geschrieben — idempotent, nur teuer).

Warum Regel 2 **nicht** im Fall *ohne Kanarienzeile*: ohne Kanarienzeile gibt es keine offene Version, deren Zeile
uns gehört — also nichts, das ein Refresh zerstören konnte. Umgekehrt wäre T dann oft unser eigenes letztes `guelt`
und Regel 2 würde bei jedem Lauf die letzten Stempel löschen und neu schreiben. Akzeptierte Lücke: nur Löschungen
seit dem letzten Refresh, dann ein weiterer Refresh ohne ein einziges Write dazwischen — die Zeilen kämen zurück und
blieben unerkannt. Praktisch nur in den ersten Tagen eines Betriebs möglich; im Tracker vermerken.

### 2.4 Warum ein falsches T ungefährlich ist

T ist Legacys letzter Schreibvorgang **vor** dem Dump, also nie später als der Dump. Zu klein (ruhiger Vormittag,
Fenster-Einschränkung, Uhrenversatz zwischen sybtst02 und App-Server, den die Marge zusätzlich abdeckt) heißt:
Regel 1 stempelt weniger (die Versionen werden geschrieben — gleicher Wert, idempotent), Regel 2 löscht mehr (die
Schlüssel werden neu geschrieben — gleicher Wert). Zu groß kann T nicht sein. Einziger Preis eines Rewrites: die
Zeile verliert ein `num_bericht_kurs`, das Legacy per Kennzahlen-Job gesetzt hatte — gilt heute schon für jeden
Korrektur-Rewrite (Sync-Plan 7, Schnitt 6), daher Marge nicht größer als nötig.

Grenze der Regel (gilt für jeden Stempelansatz, nicht nur diesen): hat Legacy eine Lieferung, die IFAS-NEU vor T_eff
verarbeitet hat, bis zum Dump **nicht** verarbeitet (Plausi-Abweichung, Lag über die Marge hinaus), fehlt der Preis in
`kurs1` und die Version ist gestempelt. `kurs1` ist nach einem Refresh per Definition Legacys Sicht auf alles vor T;
der Preisfile-Diff des Parallelbetriebs zeigt solche Abweichungen ohnehin.

### 2.5 Beispiele

- **Wochenend-Refresh, nichts verloren.** Freitag: Sync schreibt A, B, C; Kanarienzeile = C mit `guelt` Fr 15:00.
  Samstag Dump (Alt-DB hat A, B, C auch), Sonntag Laden. Montag 06:00 erste Lieferung D, Sync: C steht in `kurs1`,
  aber mit Legacys `guelt` Fr 14:50 → *ersetzt*. T = Fr 16:30, T_eff = Fr 16:00. Regel 2: keine Stempel ≥ T_eff.
  Regel 1: nichts. Delta schreibt D, Kanarienzeile = D. Eine `WARN`-Zeile, eine Mail.
- **Werktags-Refresh, Writes in der Lücke.** Mo 10:00 Dump. 11:00 Lieferung E, Sync schreibt E 11:05, Kanarienzeile
  = E. 14:00 Laden: E ist weg, Ledger sagt „gestempelt“. 15:00 Lieferung F, Sync: E fehlt → *ersetzt*. T = Legacys
  letzter Write vor dem Dump, 09:40; T_eff 09:10. Regel 2 löscht E's Stempel. Delta schreibt E und F.
- **Löschung in der Lücke.** Wie oben, aber um 11:00 kommt ein `D` für G: Sync entfernt G und schreibt H. Laden
  bringt G zurück und wirft H weg. Nächster Sync: H fehlt → Regel 2 löscht die Stempel von G (beendet) und H; Delta
  entfernt G erneut, schreibt H.
- **Erste Aktivierung.** Drei Monate Parallelbetriebs-Versionen, nichts gestempelt, keine Kanarienzeile. T =
  Legacys letzter Write. Regel 1 stempelt alles vor T_eff, nichts wird geschrieben; Delta schreibt nur, was nach
  T_eff kam. `WARN`, Mail, Zähler auf dem Job.
- **Nach dem harten Schnitt.** Kein Refresh mehr: die Kanarienzeile stimmt immer, der Zweig läuft nie. Keine
  Einstellung zu ändern.

### 2.6 Was unberührt bleibt

Die Publikationsstempel (`published_at`, `deletion_published_at`) beschreiben, was das Preisfile verschickt hat; ein
Refresh der Sybase ändert daran nichts. Der Preisfile-Sammellauf liest nur das Ledger. Ihre erstmalige Setzung vor
dem Einschalten des Sammellaufs auf TEST bleibt ein einmaliger manueller Schritt (Tracker, Abschnitt 10).

## 3. Tabellen — V082 (ein File je Baum, Sybase-Platzhalter)

### 3.1 `preis_versions`

| Spalte | Typ | Bedeutung |
|---|---|---|
| `kurs_guelt` | `timestamp(6) null` (ohne Zeitzone, spiegelt `kurs.guelt`) | Das `guelt`, das **dieser Sync** in die `kurs`-Zeile der Version geschrieben hat. Null = die Zeile ist nicht von uns: per Regel übersprungen, von Legacy geschrieben (Regel 1), oder nach einem Refresh (Regel 3) |

Index `ix_preis_versions_kurs_guelt (kurs_guelt)` für die Kanariensuche (`offen = true and kurs_guelt is not null
order by kurs_guelt desc`, erste Zeile). Kein partieller Index — H2 kennt keinen (V035, V075). Keine neue Constraint.

### 3.2 `preis_version_sync_jobs`

| Spalte | Typ | Bedeutung |
|---|---|---|
| `snapshot_t` | `timestamp(6) with time zone null` | T des Laufs, gesetzt wenn der Sync `kurs1` als ersetzt behandelt hat (Fall *ersetzt*, oder *ohne Kanarienzeile* mit mindestens einem Stempel nach Regel 1); sonst null |
| `versions_snapshot_stamped` | `integer null` | Regel 1 |
| `versions_snapshot_cleared` | `integer null` | Regel 2 |

Listbare Zähler, die mit den Updates des Laufs committen; welche Version warum gestempelt oder freigegeben wurde,
steht nicht im Protokoll (das wären tausende Zeilen bei der ersten Aktivierung) — die Stempel selbst tragen die Job-Id.

## 4. Der Sync-Lauf — was sich ändert

```
process(jobId)
  stepBackIfAnOlderSyncIsActive                       unverändert
  healAfterSnapshot(jobId)                             NEU, 2.1–2.3
  unprocessed = findUnprocessed()                      unverändert ab hier
  ...
write(...)
  guelt = nowInVienna().truncatedTo(SECONDS)           geändert (2.1)
  apply(change, guelt) je KursChange                   unverändert
  markKursWritten(ids der offenen Versionen aller Write-Changes, guelt)   NEU, im selben Tx wie die Stempel
  confirmOwnership, stamp, updateResult                unverändert
```

- **`healAfterSnapshot`** liest Kanarienzeile (Ledger-Kontext) und `kurs1` (Kontext `business`, `getBusinessDbKey()`)
  **ohne Transaktion**. Nur wenn es etwas zu schreiben gibt (Fall *ersetzt*, oder Regel 1 mit Treffern), öffnet es
  **eine eigene** `withBusinessNewIntroducedDbContextIsolatedTransactional`-Klammer: Regeln 2, 3, 1, dann
  `jobRepository.updateSnapshot(jobId, t, stamped, cleared)` im Job-Kontext (enrollt nach dem Ledger, beide Postgres).
  Getrennt von der Schreib-Transaktion: scheitert der Delta-Lauf danach, bleibt die Heilung committed und ist beim
  nächsten Versuch korrekt (dann ohne Kanarienzeile: Regel 1 findet nichts mehr, Delta schreibt die freigegebenen).
  Ohne etwas zu schreiben keine Transaktion — die Commit-Fehler-Tests (`…LedgerCommitFails…`) bleiben unberührt.
- Die Ids für `markKursWritten`: je `KursChange.Write(key, …)` die offene Version `openByKey.get(key).id()`;
  chunked 1000 wie die Stempel. Unbedingt (eine seit dem Lesen beendete Version ist `offen = null` und nie Kanarie).
- **Protokoll** (englische Logzeilen wie bisher):
  - *ohne Kanarienzeile, T = null:* `INFO … no own kurs row to check and kurs holds no guelt in the window`
  - *ohne Kanarienzeile, T gesetzt, Regel 1 = 0:* `INFO … no own kurs row to check; nothing before T to stamp`
  - *ohne Kanarienzeile, Regel 1 > 0:* `WARN … kurs treated as a snapshot of T = …: n version(s) before T − margin stamped as written by legacy`
  - *ersetzt:* `WARN … kurs was replaced since the last own write (canary <key> written at <guelt>: <missing | guelt now …>); T = …, margin …: n stamp(s) since T − margin cleared, m version(s) before stamped as written by legacy`
- **Benachrichtigung:** `executeWithProtocol` → `executeWithProtocolAndNotifyOnErrorsOrWarnings(job, "Preisversionen → kurs abgleichen", Level.INFO, null, …)`.
  Damit mailen auch die bestehenden `WARN`-Zeilen *skipped, no fund resolves* (Stammdaten-Skip) — offene Frage aus
  Sync-Plan 7, hiermit mit „ja, an den Support“ beantwortet. Signatur: `Job` statt Typ/Stichtag, Rückgabe `URI`.
- Hooks (`PreisVersionSyncJobHooks`) unverändert; die Heilung liegt vor `afterRead`.

## 5. Benachrichtigung — Empfängergruppe je Job-Typ

Heute (`NotificationProperties`, Präfix `notification`):

| Einstellung | Inhalt |
|---|---|
| `notification.system-support.{from, reply-to, subject-prefix, default-importance, default-sensitivity, to[n].email-address / personal-name}` | Gruppe der Entwickler/Support; bekommt heute nur fehlgeschlagene Work-Items und REST-Fehler (`SystemSupportNotificationService`) |
| `notification.business-department.{…dieselben…}` | Fachbereich; bekommt **alle** Job-Protokoll-Mails (`BusinessDepartmentNotificationService`, Aufrufer `JobAutoProtocolAndNotificationService`) |
| `notification.jobs.<JobType>.{notify-on-errors, notify-on-warnings, sensitivity, error-importance, warning-importance}` | je Job-Typ (`Job.getJobType()`, z. B. `PreisVersionSync`); Default beides `true` |
| `notification.customer.*`, `notification.external-url` | Kunden-Mails, Link-Basis |

Im Repo stehen die Adressen nur für DEV (`application-DEV.properties`, `tester@localhost`); auf den Servern kommen
sie aus der externen Konfiguration. Zwei Fehler im Bestand, die der Chunk mit behebt, weil er genau diese Zeilen
anfasst: `isJobNotifyOnWarningsEnabled` liefert `isNotifyOnErrors()`, und die Warnungs-Mail nimmt
`getJobNotificationErrorImportance` statt der Warning-Importance.

Neu:

- `JobNotificationConfig.recipients`: Enum `JobNotificationRecipients { BUSINESS_DEPARTMENT, SYSTEM_SUPPORT }`,
  Default `BUSINESS_DEPARTMENT`; Getter `getJobNotificationRecipients(jobType)`.
- `SystemSupportNotificationService.notifySystemSupportAboutJobProtocolWithErrors / …WithWarnings(job, message,
  protocolFileUri)` — Spiegel der Fachbereichs-Methoden mit den System-Support-Defaults; dafür
  `NotificationService.notifySystemSupport` um `attachments` erweitern (bestehende Aufrufer geben `null`).
  Template `job-errors` prüfen: spricht es den Fachbereich an, bekommt es eine Variable für die Gruppe.
- `JobAutoProtocolAndNotificationService.persistProtocolAndNotifyBusinessDepartment` verzweigt nach
  `getJobNotificationRecipients(jobType)`; der private Name darf per Edit auf `persistProtocolAndNotify` — keine
  weiteren Referenzen.
- `application.properties` (ASCII, nur per Bash anfügen): `notification.jobs.PreisVersionSync.recipients=system-support`
  (Relaxed Binding auf das Enum). Auf TEST muss `notification.system-support.to[*]` gesetzt sein — ist es für die
  Work-Item-Mails schon.

## 6. UI

`preis-version-sync-job-detail.html`: Karte **„Sybase-Snapshot“** zwischen *Abgleich* und *Zähler*, nur wenn
`job.snapshotT != null`: *Letzter Legacy-Schreibvorgang (T)*, *als vorhanden gestempelt*, *Stempel gelöscht*;
`title` auf den Zeilen erklärt T und die Marge in einem Satz. Kein neuer Pfad, kein neues Recht. Test im
`PreisVersionSyncJobDetailPageControllerTest` (Karte da / nicht da).

## 7. Konfiguration

`FondspreiseProperties.PreisVersionSync` bekommt `Snapshot snapshot`:

| Property | Default | Bedeutung |
|---|---|---|
| `ifas.fondspreise.preis-version-sync.snapshot.margin` | `PT30M` | Marge 2.2/2.4 |
| `ifas.fondspreise.preis-version-sync.snapshot.preisdatum-window-days` | `65` | Fenster für `max(guelt)`, 2.2 |

Defaults im Code, keine Zeile in den Properties-Files (wie `…preis-version-sync.enabled`); Doku in `ifas13-jobs.md`.

## 8. Chunks

Jeder Chunk ein Commit auf `master`, Opus-Subagent mit eigenem Brief; Maven immer `-Pno-proxy`, Web-Module
`-Pdev-build`, Integrationstests nach `mvn -q install -Pno-proxy -DskipTests -pl ifas-testing/ifas-integration-tests -am`.
Nichts bis Chunk 3 ändert das Verhalten des laufenden Systems.

### Chunk 1 — Persistenz

- V082 in beiden Bäumen (`V082__preis_version_sync_snapshot.sql`, Sybase-Platzhalter im Wortlaut von V079–V081):
  3.1 und 3.2 in einem File, Kopfkommentar nach dem Muster von V079.
- `PreisVersion.kursGuelt` (`LocalDateTime`), `PreisVersionSyncJob.snapshotT`, `versionsSnapshotStamped`,
  `versionsSnapshotCleared`.
- `PreisVersionRepository`: `findFirstByOffenTrueAndKursGueltNotNullOrderByKursGueltDesc()`,
  `markKursWritten(ids, guelt)`, `clearStampsProcessedSince(@Nullable since)` (null = alle), `clearKursGuelt()`,
  `markProcessedOpenCreatedBefore(before, processedAt, jobId)`, `markProcessedEndedInvalidatedBefore(before,
  processedAt, jobId)` — alle `@Modifying`, Rückgabe Zeilenzahl.
- `KursRepository.findMaxGueltWithDatKursSince(LocalDate from)` → `@Nullable LocalDateTime`
  (`SELECT MAX(k.guelt) FROM Kurs k WHERE k.datKurs >= :from`).
- `PreisVersionSyncJobRepository.updateSnapshot(jobId, snapshotT, stamped, cleared)`.
- Tests: `PreisVersionSyncJobRepositoryTest` (+ Snapshot-Spalten), ein Repository-Test für die neuen
  Ledger-Queries (Kanarie = jüngstes `kurs_guelt` nur offener Versionen; `clearStampsProcessedSince` löscht
  auch `kurs_guelt`; die beiden `…Before`-Stempel treffen nur ungestempelte und respektieren offen/beendet),
  `findMaxGueltWithDatKursSince` (leer → null, Fenster). Beide DBs.

### Chunk 2 — Benachrichtigung an den System-Support je Job-Typ

- Abschnitt 5 komplett, inkl. der zwei Bestandsfehler und der Property-Zeile für `PreisVersionSync`.
- Tests (Integrationstests, Muster `MailSendServiceTest`): ein Job-Typ mit `recipients=system-support` erzeugt bei
  `WARN` ein `SEND_MAIL`-Work-Item an die System-Support-Adressen und keines an den Fachbereich; ohne die Property
  wie bisher an den Fachbereich; `notify-on-warnings=false` unterdrückt die Warnungs-Mail (der behobene Fehler).
- Verhalten ändert sich nur für Job-Typen mit gesetzter Property — vor Chunk 3 ruft der Sync noch
  `executeWithProtocol`.

### Chunk 3 — Die Heilung im Sync

- Abschnitt 4 und 7 komplett; `guelt` auf Sekunden; Umstellung auf `executeWithProtocolAndNotifyOnErrorsOrWarnings`.
- Bestehender Test anpassen: `PreisVersionSyncJobInterleavingTest` ab Zeile 378 prüft `guelt isAfterOrEqualTo(retriedAt)`
  — `retriedAt` ebenfalls auf Sekunden abschneiden.
- Neue Tests in `PreisVersionSyncJobTest` (beide DBs; `kurs`-Zeilen direkt setzen wie `putKursRow` im
  Interleaving-Test):
  1. *ohne Kanarienzeile, `kurs` leer* → wie heute: alles geschrieben, `snapshot_t` null.
  2. *erste Aktivierung:* Legacy-Zeilen mit `guelt` = T, Versionen v1 (`created_at` = T − 2 h, ungestempelt) und v2
     (T + 1 h) → v1 gestempelt, nicht geschrieben; v2 geschrieben; Zähler (T, 1, 0); `WARN`; Kanarie = v2.
  3. *Kanarie stimmt:* Sync 1 schreibt v1; v0 ungestempelt älter als T_eff nachträglich eingefügt → Sync 2 schreibt
     v0 als normalen Delta, `snapshot_t` null, kein `WARN`.
  4. *ersetzt:* Sync 1 schreibt v1, v2 (Kanarie); Refresh simulieren: `guelt` beider Zeilen auf T − 1 h setzen
     (= Legacys Werte), eine dritte Legacy-Zeile mit `guelt` = T; v3 nach T geschrieben und per `D` beendet, Removal
     gestempelt; Zeile von v3 wieder einfügen (Refresh bringt sie zurück) → Sync 2: v1, v2 behalten Stempel,
     `kurs_guelt` null; v3-Stempel gelöscht und erneut entfernt; Zähler (T, 0, n); `WARN`; Protokollzeile nennt
     die Kanarie.
  5. *Marge:* Version mit `processed_at` = T − 10 min bei Marge 30 min → freigegeben und neu geschrieben
     (`1 replaced`).
  6. *ersetzt und T = null* (alle `kurs`-Zeilen gelöscht) → alle Stempel weg, alles neu geschrieben.
  7. *Heilung committed, Delta scheitert* (Hook `beforeWrite` wirft): Stempel/Zähler der Heilung sind da; der Retry
     heilt nicht erneut (`snapshot_t` null im zweiten Versuch) und schreibt die freigegebenen Schlüssel.
  8. *Mail:* Fall 4 erzeugt ein `SEND_MAIL`-Item an den System-Support.
- `ifas-integration-tests-multidbctx`: die vier Commit-Order-Tests bleiben grün (die Heilung öffnet dort keine
  Transaktion — nichts zu tun).

### Chunk 4 — UI und Doku

- Abschnitt 6; `ifas13-jobs.md` Abschnitt `PreisVersionSyncJob` (Zeilen 106–129: Kanarienzeile, T, Marge, die
  drei Updates, Mail an Support), `jobs-catalog.md` Statuszeile `PreisVersionSync` (Zeile ~675) und die
  Einstellungen; Sync-Plan Nachtrag und Tracker (Migrations-Stempel-Todo auf den Publikationsstempel reduzieren,
  Team-Diskussions-Todo bleibt, Lücke aus 2.3 vermerken) macht Fable.

## 9. Verifikation

- Chunk-Tests wie oben; `PreisVersionSyncJobTest`, `PreisVersionSyncJobInterleavingTest`,
  `PreisVersionSyncScheduledTaskTest`, `PreisVersionJobTest`, `PreisfileJobTest`, Commit-Order-Tests grün auf H2
  und Postgres.
- End to end im `LocalH2WithMailhogIfasApplication` (Sync eingeschaltet, Rezept aus dem Skill
  `run-ifas-headless`): Stammdaten-YAML, db_union-Lieferung → Sync schreibt `kurs`, Detailseite ohne
  Snapshot-Karte. Refresh simulieren über die SQL-Konsole auf der Business-DB: `update kurs set guelt =
  dateadd('MINUTE', -90, guelt)` (Legacys Werte), zweite Lieferung → Sync: `WARN`, Karte mit T und Zählern, die
  Schlüssel der ersten Lieferung behalten ihre Stempel, `kurs_guelt` null, die zweite Lieferung geschrieben; Mailhog
  zeigt die Mail an `tester@localhost` mit Betreff-Präfix des System-Supports. Dritte Lieferung ohne Eingriff → keine
  Karte, keine Mail.
- Auf TEST nach dem Einschalten des Syncs: der erste Lauf stempelt den Backlog (Zähler auf dem Job), die Laufzeit
  von `max(guelt)` im Fenster im Protokoll bzw. Log beobachten — bleibt sie über Sekunden, Fenster verkleinern.

## 10. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **Publikationsstempel vor dem ersten Sammellauf auf TEST** | bleibt einmalig manuell (SQL unter `plans/fondspreise/sql/` oder Form); kein Refresh-Problem, Tracker |
| **Nur-Löschungen zwischen zwei Refreshes** | akzeptierte Lücke 2.3; Tracker-Vermerk |
| **`num_bericht_kurs` beim Rewrite** | Schnitt 6 (Kennzahlen), unverändert |
| **Mail-Konzept Fondspreise-Kette** | PreisMeldung/PreisVersion/Preisfile laufen weiter ohne Mail (`executeWithProtocol`); mit der Empfängergruppe je Job-Typ ist der Weg frei |
| **Harter Schnitt / Refresh ohne `kurs1`** | Team-Diskussion (Tracker); für den Sync ohne Folgen |

## 11. Nachträge und Stand

- **Nachtrag 2026-10-13 (Chunk 1 umgesetzt, Commit `5187df831`, gepusht):** V082 beide Bäume, `PreisVersion.kursGuelt`,
  drei Snapshot-Spalten am Sync-Job, sieben Ledger-Queries, `KursRepository.findMaxGueltWithDatKursSince`,
  `PreisVersionSyncJobRepository.updateSnapshot`, `postgres-db-schema.sql` neu erzeugt (4 Spalten). Tests: 122 grün
  auf H2 + Postgres (Repository-Tests, Sync-, Interleaving-, Preisfile-Tests), Commit-Order 4/4;
  `KursRepositoryTest` von Fable auf `TEST_WITH_ALL_DATABASE_SYSTEMS` gestellt, 3 × 3 grün — die Query läuft
  produktiv auf Sybase. Abweichungen: Parameternamen wie die Nachbarn (`preisVersionSyncJobId`,
  `versionsSnapshotStamped/Cleared`); statt `clearStampsProcessedSince(@Nullable)` zwei Methoden
  (`clearStampsProcessedSince(since)`, `clearAllStamps()`), kein nullable Parameter in JPQL; `endOpenVersion` lässt
  `kurs_guelt` stehen (harmlos: die Kanarie nimmt nur offene Versionen, Regel 3 räumt ab).
- **Festlegungen für Chunk 3 aus dem Bericht:** `updateSnapshot(snapshotT)` wird `@Nullable` (Fall 6, `kurs` leer →
  T = null, Zähler trotzdem gesetzt); die UI-Karte (Chunk 4) hängt an `versionsSnapshotStamped != null`, nicht an
  `snapshotT`. Javadoc von `PreisVersion.processedAt` („one value per sync“, „a run writes it null“) nachziehen.
  T (`LocalDateTime`, Wiener Wandzeit) über `Europe/Vienna` nach `OffsetDateTime` (doppelte Stunde der
  Zeitumstellung: mit der Marge unkritisch). Sekunden-Abschneiden im Service, nicht im Repository.
  Test-Helfer `PreisVersionJobTestSupport.clearStamps()` kann `clearAllStamps()` nutzen. Gleichstand bei der
  Kanarie (alle Zeilen eines Syncs tragen dasselbe `guelt`) ist egal, nur der Schlüssel in der WARN-Zeile wechselt.
- **Grenze (Agent-Befund, akzeptiert):** ohne Kanarienzeile und ohne Refresh ist T unser eigenes letztes `guelt`;
  Regel 1 stempelt dann ungestempelte Versionen vor T_eff als „von Legacy“. Unsicher nur, wenn ein Sync zwischen
  Lesen und Schreiben länger als die Marge hängt und ein Lauf in der Zeit committet — der Zombie-Schutz (Sync-Plan 3.7)
  rollt so einen Sync zurück, dann gibt es kein `guelt` von ihm.
- **Nachtrag 2026-10-13 (Chunk 2 umgesetzt, Commit `e7893c8a8`, gepusht):** `JobNotificationRecipients` (Enum), `recipients` je
  Job-Typ mit Default Fachbereich, `getJobNotificationRecipients`; die zwei Bestandsfehler behoben (Warnungs-Flag las
  das Fehler-Flag, Warnungs-Mail nahm die Fehler-Importance — per Mutations-Nachweis bestätigt);
  `NotificationService.notifySystemSupport` mit Anhängen; `SystemSupportNotificationService.notifySystemSupportAboutJobProtocolWithErrors/WithWarnings`
  als Spiegel der Fachbereichs-Methoden (Template `job-errors` nennt keine Gruppe, daher unverändert);
  `JobAutoProtocolAndNotificationService.persistProtocolAndNotify` verzweigt nach der Gruppe;
  `application.properties` + `notification.jobs.PreisVersionSync.recipients=system-support`. Tests: Service-Modul 95
  (neu `NotificationPropertiesTest`, Binder), Integrationstests 56 grün, neu `JobAutoProtocolAndNotificationServiceTest`
  (6, nur H2: Mail gibt es nur im Profil `greenmail`). Befund Transaktion: das SEND_MAIL-Item muss in der
  WQ-Haupttransaktion des Handlers eingereiht werden, weil `storeProtocol` den Anhang in derselben Transaktion ablegt —
  keine `doIsolatedTransactional`-Klammer, gilt für beide Gruppen. GreenMail 2.1.2 `waitForIncomingEmail` zählt
  SMTP-Nachrichten, nicht Postfächer — der Test pollt das Postfach per Awaitility. Hinweis: `NotificationProperties`
  sucht Job-Typen exakt (`PreisVersionSync`), aus Umgebungsvariablen käme der Schlüssel kleingeschrieben — gilt für
  alle bestehenden Job-Settings, für die Properties-Zeile ohne Belang.
- **Für Chunk 3:** Testfall 8 (Mail) braucht `TEST_WITH_H2_AND_MAIL` oder prüft die Protokoll-/Logzeile
  „notifying system support“; der Sync läuft als `AbstractJobWorkQueueHandler` in der WQ-Haupttransaktion, die
  Umstellung auf `executeWithProtocolAndNotifyOnErrorsOrWarnings` braucht deshalb keine Klammer. Javadoc von
  `executeWithProtocol` („notifies the business department“) mit anpassen.
- **Nachtrag 2026-10-13 (Chunk 3 umgesetzt, Commit `da7ca67ec`, gepusht):** `healAfterSnapshot` vor dem Lesen mit drei Zweigen
  (Kanarie stimmt → nur DEBUG; ohne Kanarie → `stampBeforeSnapshotWithoutCanary`; ersetzt → `resetToSnapshot`,
  Regeln 2, 3, 1, `updateSnapshot`, WARN). `guelt` auf Sekunden; `markKursWritten` chunked im Schreib-Tx **nach**
  `stamp()`, nicht direkt nach `apply` — sonst stünde das Ledger vor infra und die geprüfte Commit-Reihenfolge
  [business, infra, ledger] bräche. Umstellung auf `executeWithProtocolAndNotifyOnErrorsOrWarnings(job,
  „Preisversionen → kurs abgleichen“, INFO)`. `Snapshot`-Properties (PT30M, 65) mit Binding-Tests;
  `updateSnapshot(snapshotT)` nullable; Javadocs (`processedAt`, `executeWithProtocol`, Sync-Job-Spalten) nachgezogen.
  **Ohne Kanarie keine leere Transaktion:** T und `findUnprocessed()` werden ohne eigene Transaktion gelesen, die Ids
  vor T − Marge im Speicher gefiltert, nur bei Treffern eine Ledger-Klammer mit `markProcessedOpen/Ended` +
  `updateSnapshot`; `process()` liest danach neu. Fall 7 liegt im Interleaving-Test (braucht Hooks); Fall 8 als
  `PreisVersionSyncJobMailTest` (`TEST_WITH_H2_AND_MAIL`, setzt `recipients` am Bean; „notifying system support“
  steht nicht im Protokoll, weil nach der Erfassung geloggt). Tests: Integrationstests 201 grün (Sync 13 × 2,
  Interleaving 7 × 2, Mail 1), `FondspreisePropertiesTest` 10, Commit-Order 4/4 unverändert, web-ui kompiliert.
  Abweichungen: Hooks-Konstruktor (11 Argumente, multidbctx) bleibt und nimmt `new FondspreiseProperties()`;
  Testzeiten relativ zur Uhr (T = jetzt − 3 h, Preisdatum heute − 3), Kanarien-Gleichstand in Fall 4 per Warten auf
  die nächste Sekunde aufgelöst; ein bestehender Reparatur-Test wartet ebenso (ganze Sekunden sonst flaky).
- **Für Chunk 4 / Doku:** Karte an `versionsSnapshotStamped != null`; die Snapshot-Zähler committen in der
  Heil-Transaktion vor dem Schreiben — scheitert der Delta-Lauf, bleiben sie stehen, der Retry überschreibt sie
  nicht, und die WARN-Zeile des gescheiterten Versuchs steht nur im WQ-Ausführungslog, nicht im Job-Protokoll.
  Logzeilen: „no own kurs row to check and kurs holds no guelt in the window“, „… nothing before T to stamp (T = …,
  margin …)“, „kurs treated as a snapshot of T = …“, „kurs was replaced since the last own write (canary … )“.
  Stammdaten-WARN-Zeilen mailen jetzt an den Support. Nicht geprüft: Kanarien-Lookup und T-Abfrage auf Sybase (char-Padding
  von `cod_fliesscode` beim `findById` — Sybase vergleicht `char` blank-gepolstert); die Haupttransaktion trägt Sybase
  jetzt lesend ein (zweite Sybase-Verbindung je Sync). Zombie-Schutz: die Heil-Transaktion ruft kein
  `confirmOwnership` — ein aufgetauter Zombie könnte Stempel eines neueren Versuchs löschen, Kosten = erneutes Schreiben.
- **Nachtrag 2026-10-13 (Chunk 4 umgesetzt, Commit `529eb53f8`, gepusht):** Karte „Sybase-Snapshot“ zwischen *Abgleich* und
  *Zähler*, Bedingung `versionsSnapshotStamped != null` (nicht `snapshotT`, Plan 6 ist damit überholt), T über
  `@vienna.format`, ohne T „— (kurs leer)“; drei `title`-Sätze; direkt am Entity, kein Controller-Code, kein Pfad,
  kein Recht. Tests: Detailseite 7/7 (zwei neue, Reihenfolge der Karten per `containsSubsequence`), web-ui 170,
  `IfasSecurityConfigAuthorizationTest` (liegt in web-core) 74/74. Doku: `ifas13-jobs.md` vier Stichpunkte
  (Kanarienzeile/Regeln, Fall ohne Kanarie, Zähler und gescheiterter Delta, Properties und Support-Mail) und der
  erste Stichpunkt korrigiert („`kurs` wird geschrieben und nur für die Snapshot-Prüfung gelesen“);
  `jobs-catalog.md` Statuszeile und ein Satz in 5.7. **Damit ist der Plan vollständig umgesetzt**; offen aus
  Abschnitt 10 unverändert (Publikationsstempel einmalig manuell, Team-Diskussion Refresh).
- **Smoke-Test der Selbstheilung 2026-10-13 (`LocalH2WithMailhogIfasApplication`, Sync eingeschaltet, Mailhog per podman):**
  Stammdaten-YAML nötig (die automatisch geladenen Basisdaten kennen die db_union-Fonds nicht — ohne sie claimt der
  Lauf 0 Zeilen). Lieferung 31.08. → Sync: „no own kurs row to check and kurs holds no guelt in the window“, 6
  Schlüssel geschrieben, keine Karte, keine Mail. Refresh simuliert per SQL-Konsole (`update kurs set guelt =
  dateadd('MINUTE', -90, guelt)`), Lieferung 01.09. → Sync: WARN „kurs was replaced since the last own write (canary
  AT0000A0S392 2026-08-31 EUR Z written at 16:54:01: guelt now 15:24:01); T = 15:24:01, margin PT30M: 6 stamp(s)
  since T − margin cleared, 0 … stamped“, danach 12 Schlüssel geschrieben (6 neu, 6 nachgeholt); Karte
  „Sybase-Snapshot“ mit T 15:24:01, 0, 6; genau eine Mail in Mailhog an `tester@localhost` (System-Support der
  DEV-Properties), Betreff „IFAS13-…: Job with Warnings: PreisVersionSync“, Protokoll als Anhang. Manueller vierter
  Sync: Kanarie stimmt, „no unprocessed versions“, keine Karte, keine weitere Mail.

## Quellen

- `ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/fondspreise/PreisVersionSyncJobExecutionService.java`
  (Lauf, `write`, `apply`, `stamp`), `…/FondspreiseProperties.java`
- `ifas-database/ifas-persistence-fondspreise/…/PreisVersionRepository.java` (`findUnprocessed`, `markProcessedOpen/Ended`,
  `endOpenVersion` löscht den Stempel), `…/PreisVersion.java`
- `ifas-database/ifas-persistence-inv/…/Kurs.java`, `KursId.java`, `KursRepository.java`; V073 (`kurs_2_index`)
- `ifas-database/ifas-database-flyway/…/postgres15/V079__preis_version_sync.sql`, `V081__preisfile_jobs.sql`, Sybase-Platzhalter
- `ifas-services/…/service/job/JobAutoProtocolAndNotificationService.java`, `…/service/notification/NotificationProperties.java`,
  `BusinessDepartmentNotificationService.java`, `SystemSupportNotificationService.java`, `NotificationService.java`
- Tests: `PreisVersionSyncJobTest`, `PreisVersionSyncJobInterleavingTest` (`putKursRow`),
  `PreisVersionSyncJobCommitOrderMultiDbCtxTest`, `MailSendServiceTest`
- Legacy: `guelt = getdate()` bei jedem `kurs`-Write (`m_solva2kurs.cpp:325-328`, Muster in `c_ins_euro_str.cpp`)
- Smoke-Test 2026-10-13 (Sammellauf-Plan Abschnitt 9) als Vorlage für die H2-Verifikation
