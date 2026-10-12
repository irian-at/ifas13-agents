# Produktiver Preismeldungs-Job — `PreisMeldungJob`

Datum 2026-10-12. Nachfolger der Sync-Plan-Lücke „der Sync hat außer Tests und dem manuellen Auslöser
keinen Aufrufer“ (Sync-Plan Abschnitt 7, Tracker „Produktiver Preismeldungs-Job (`persistResult=true`)“).

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Eingang** | Stufe 1 der Lieferkette (`preis_ins.e`): Prüfung des Lieferfiles, Inbox-Zeilen, Rückmeldung — in IFAS13 `PreisMeldungEingangService` |
| **Rückmeldung** | das ZIP, das der Lieferant zurückbekommt (`statistics/error/info/data.log` + Originalfile; `RueckmeldungArtefakte`) |
| **oekbinfo.log** | internes Protokoll des Eingangs, nicht Teil der Rückmeldung |
| **Diff-Job** | `PreisMeldungDiffJob`, Parallelbetrieb: entscheidet nur, keine Außenwirkung, difft gegen Altsystem-Logs |
| **Lauf** | `PreisVersionJob`, faltet die Inbox ins Ledger `preis_versions` |
| **Sync** | `PreisVersionSyncJob`, leitet `kurs` aus dem Ledger ab (Neusystem-Sybase, `kurs1..kurs`) |
| **Außenwirkung** | Archiv + Journal der Rückmeldung (NetApp), Ablage der Rückmeldung im MFT-`receive` des Lieferanten |

## 1. Kontext und Entscheidungen (2026-10-12, User)

Der Echtbetrieb braucht einen Job, der ein geliefertes Preisfile durch den Eingang schickt, die Rückmeldung
an den Lieferanten bringt und als **erster Einreicher mit `sync_requested = true`** die Kette Lauf → Sync
auslöst. Der Diff-Job des Parallelbetriebs bleibt unverändert (entscheidet nur, difft, `sync_requested`
`false`).

- **Ankunft via MFT bleibt aus.** Es gibt in IFAS13 noch keinen Inbound-Pull (`mft-interface.md`: „the pull
  direction“ offen). Der Job bekommt ein **eigenes Upload-Formular** wie die Ausschüttungsmeldungen, damit
  TEST ihn fahren kann; die automatische Einreichung für angekommene Files bleibt als **auskommentierter
  Aufruf mit TODO** im Submission-Service (User: „comment it out with a todo“). Der Parallelbetrieb-Dispatcher
  (`ParallelbetriebJobSubmissionService`, Zweig `hasOnlyPreisMeldungFiles`) routet weiter zum Diff-Job.
- **Menü:** STM-Gruppe, Eintrag „Preismeldungen“ neben „Ausschüttungsmeldungen“; neues Recht `PREIS_MELDUNGEN`.
- **Vorbild** ist der produktive `AusschuettungsMeldungJob` (Web-Upload, Archiv+Journal, MFT-`receive`), die
  Eingangs-Logik kommt 1:1 aus dem Diff-Job (`PreisMeldungEingangService`, Write-once-Marker).
- **Nie gelöscht** (Tracker-Entscheidung 2026-09-24): Archivieren ist nur das Flag; keine Lösch-Aktion. Die
  Inbox-Aufräumregel bleibt ein eigenes Todo.
- Die Property `ifas.fondspreise.preis-version-sync.enabled` bleibt aus, bis der Migrations-Stempel gesetzt
  ist (Sync-Plan Abschnitt 7). Mit Property aus endet die Kette beim Lauf — eine Protokollzeile, kein Sync.
- `keyDate` des Jobs = Empfangstag (die Preismeldung hat keinen Stichtag; kein Stichtag-Feld im Formular).

## 2. Die Tabelle `infra.preis_meldung_jobs` (Flyway V080, nur Postgres-Baum; H2 teilt ihn)

JOINED wie `preis_meldung_diff_jobs` (V063), PK = `jobs.id`. Die Inbox `preismeldung_zeilen.job_id` zeigt per
FK auf `jobs` (V067 — „der produktive Preismeldungs-Job besitzt ebenfalls Inbox-Zeilen“), also nichts zu tun.

| Spalte | Typ | Bedeutung |
|---|---|---|
| `id` | uuid PK, FK `jobs` | |
| `source_type` | text not null | `WEB` (Upload), `MFT` (später, Ankunft) — Muster `AusschuettungsMeldungJob.SourceType` |
| `input_file_ref` | text not null | das gelieferte CSV im Filestore (ein File, kein Bundle) |
| `input_filename` | text not null | |
| `liefer_id` | text not null | |
| `result_bundle_file_ref` | text | die Rückmeldung als ZIP, so wie sie der Lieferant bekommt (`JobWithResultBundle`) |
| `oekbinfo_log_file_ref` | text | das interne Eingangsprotokoll, Download auf der Detailseite |
| `zeilen_count` | integer | gelieferte Zeilen (`PreisMeldungEingangResult.lineCount()`) |
| `zeilen_accepted_count` | integer | angenommene Zeilen = Inbox-Zeilen |
| `bug_zeilen_count` | integer | verworfene Zeilen |
| `rueckmeldung_urteil` | varchar(5) | `RueckmeldungUrteil` |
| `empfangen_at` | timestamptz not null | DB-Uhr des Job-Systems bei Einreichung; Positionsteil 1 der Inbox-Zeilen |
| `eingang_abgeschlossen_at` | timestamptz | Write-once-Marker wie beim Diff-Job |
| `notes` | text | |

Zähler nur, was listbar ist (Memory „Job counters vs protocol“); je Zeile steht alles in Rückmeldung und
oekbinfo.log. Grants wie V063.

## 3. Der Job

### 3.1 Einreichung — `PreisMeldungJobSubmissionService`

- `submitFromWebUi(NamedContentTypeResource csv, String lieferant, String createdBy, @Nullable String notes)`:
  `requireActiveTransaction()`, CSV in den Filestore, Job `PENDING`/`WEB`, `keyDate = LocalDates.nowInVienna()`,
  `createdAt = OffsetDateTimes.now()`, `empfangenAt = withJobSystemDbContext(currentDbTime)` (wie der Diff-Job),
  `jobService.submitToWorkQueue(WQ_TASK_TYPE, job, URGENT)` (Muster `AusschuettungsMeldungJobSubmissionService`).
- **Auskommentiert mit TODO:** `submitFromMft(...)` — `SourceType.MFT`, Priorität `NORMAL`, Aufrufer ist der
  noch nicht gebaute Inbound-Pull (Legacy `preis_ins.e` alle 10 Minuten aus `<base>/<liefer_id>/send`). Kommentar
  nennt, was fehlt (Pull, Dedup nach Dateiname + Empfang, Verschieben ins `done`-Verzeichnis).
- `updateNotes`, `setArchived`, `setArchivedBatch`; **kein** `deleteArchivedBatch`.

### 3.2 Ausführung — `PreisMeldungJobExecutionService extends AbstractJobWorkQueueHandler`

Unter `protocolService.executeWithProtocol(JOB_TYPE, keyDate, INFO, …)` wie Lauf und Sync (die Protokollkarte der
Detailseite zeigt die Job-Logzeilen). `maxAttempts` Default (1), wie Diff- und Ausschüttungs-Job; Wiederholung
über die Work-Queue-UI.

1. `JobInfo` im Job-Kontext: Status `PROCESSING`, Marker gelesen; Marker gesetzt → Schritt 2 übersprungen,
   Logzeile „bereits abgeschlossen am …“.
2. **Eingang** im konfigurierten Business-Kontext (`withDatabaseContext(getBusinessDbKey())` — Stammdaten
   `wkn_hist`/`INV`/`tax_code` der Neusystem-Sybase): `eingangService.process(lieferfile, lieferant, now)`.
   Rückmeldung-ZIP (`rueckmeldung.zipName()`, `rueckmeldung.zip()`) und `oekbinfo.log` in den Filestore.
   Dann **eine** isolierte Job-System-Transaktion (`withJobSystemDbContextIsolatedTransactional`), in der alles
   zusammen committet:
   - `zeileRepository.deleteByJobId` (Reste eines abgebrochenen Versuchs), `saveAll(toEntities(...))` — das
     Mapping wird aus `PreisMeldungDiffJobExecutionService.toEntities` in einen gemeinsamen package-private
     Helfer gezogen (`PreisMeldungZeilen.toEntities(jobId, empfangenAt, lines)`), der Diff-Job ruft ihn ebenfalls;
   - `jobRepository.updateResult(id, resultBundleFile, oekbinfoLogFile, zeilen, accepted, bugs, urteil)`;
   - `markEingangAbgeschlossen` bedingt (`eingang_abgeschlossen_at is null`), 0 Zeilen → Ausnahme → Rollback
     (Schutz gegen die nebenläufige zweite Ausführung, wie beim Diff-Job);
   - **Außenwirkung in derselben Transaktion**, damit Marker und Aufträge nie auseinanderfallen:
     `archiveService.sendToArchiveAndJournal(resultBundleFile, zipName, ArchiveType.FONDSPREISE, keyDate, lieferant,
     "Fondspreise - Lieferant: %s Meldefile: %s", bugs > 0 ? WARNING : INFO)` (Typ existiert, Verzeichnis
     `/In/<YYYY>/<MM>/Fondspreise/<LIEFER_ID>`, Journal) und `mftService.sendToMft(resultBundleFile, zipName,
     MftTarget.PREIS_MELDUNG, lieferant, SubmitOptions createdBy "PreisMeldungJob(<id>)", HIGH)`. Beide reihen
     nur Work-Items ein (`ARCHIVE_FILE`, `UPLOAD_TO_MFT`) und treten der aktiven Transaktion bei; die Clients
     sind `NoOp`, solange `archive.client.enabled`/`mft.client.enabled` aus sind (TEST heute).
3. **Folgejob** auf jedem Ausgang nach Schritt 1 (auch bei gesetztem Marker, wie der Diff-Job):
   `preisVersionJobSubmissionService.submit(job.getCreatedBy(), true)` — der Lauf ist Kind des Jobs
   (`JobExecutionContext`), `sync_requested = true`; ob ein Sync folgt, entscheidet der Lauf an der Property.
4. Rückgabe des Protokoll-URI (`onSuccess` → `markAsCompleted`).

Fehler im Eingang (unlesbares File, Stammdaten-Fehler) → Ausnahme vor der Transaktion → nichts committet,
Job `FAILED`, kein Folgejob. Ein wiederholter Job mit gesetztem Marker schreibt keine Zeilen, reiht Archiv/MFT
nicht erneut ein (sie liegen in der Marker-Transaktion), reicht aber einen weiteren (leeren) Lauf ein.

### 3.3 `MftTarget.PREIS_MELDUNG` (neu)

Javadoc wie `STM_MELDUNG`/`AUSSCHUETTUNG_AT_NON_MELDEFONDS`: das `receive`-Verzeichnis des Lieferanten, Lieferant
erforderlich. Properties (ASCII-Zeilen, nur per Bash anfügen, nie mit Edit/Write):
- `ifas-applications/ifas-main-application/src/main/resources/application.properties`:
  `mft.service.targets.PREIS_MELDUNG.endpoint-type=LIEFERANT_RECEIVE` neben den anderen Targets.
- `ifas-testing/ifas-integration-tests/src/test/resources/application.properties`: dieselbe Zeile, dazu
  `archive.service.types.FONDSPREISE.directory=/In/<YYYY>/<MM>/Fondspreise/<LIEFER_ID>` und
  `archive.service.types.FONDSPREISE.journal=true` (dort fehlt der Typ; `MftService`/`ArchiveService` werfen bei
  fehlender Konfiguration erst beim Aufruf, der Integrationstest braucht sie).
- `ifas-integration-tests-multidbctx` hat keine Archiv-/MFT-Properties und braucht keine (nur Boot).

## 4. UI

Controller in `at.oekb.ifas.web.stm` (Menügruppe STM; Konvention „Sub-Package = Navigation“), Templates
`preis-meldung-list.html`, `preis-meldung-detail.html`, `preis-meldung-form.html`. Muster: die drei
`PreisMeldungDiff*PageController` und ihre Templates (gleiche Karten, ohne Diff-Block), für das Formular
`PreisMeldungDiffFormPageController` (Lieferant-Datalist über `LieferantSuggestionsAdvice`, Vorprüfung des
Uploads per `Resources.peek`) und `AusschuettungMeldungFormPageController` (Rückkehr mit `submittedJob`).

- **Liste** `/ui/preis-meldungen` (`PreisMeldungListPageController`): Spalten Empfangen, Lieferant, Datei, Quelle,
  Zeilen geliefert/angenommen/Bugs, Urteil, Status, Erstellt von; Filter Text (Lieferant/Datei), Status, Urteil,
  Archiviert; Bulk-Archivieren/Dearchivieren wie die Diff-Liste, **ohne** Löschen; Button „Neue Preismeldung“ → Formular.
- **Detail** `/ui/preis-meldungen/{id}` (`PreisMeldungDetailPageController implements JobDetailPage`,
  `jobClass()` `PreisMeldungJob.class`): Toolbar mit Listen-Link, `parentJobBanner` (leer bei Upload), Hauptkarte
  „Preismeldung“ (core rows + Lieferant, Datei, Quelle, empfangen), Karte „Eingang und Rückmeldung“ (Zeilen
  geliefert/angenommen/Bugs, Urteil-Badge, Eingang abgeschlossen), `childJobsCard` (der Lauf; darunter sein
  Sync), Karte „Inbox – angenommene Zeilen“ mit `fragments/preis-zeile :: verarbeitungCell/wirkungCell` über
  `PreisVersionQueryService.findZeilenOfJob`, drei `fileCard`s (Lieferfile `/{id}/input-file`, Rückmeldung
  `/{id}/result-file`, oekbinfo.log `/{id}/oekbinfo-log`), Protokollkarte, Notizen-Formular (`POST /{id}/notes`).
- **Formular** `/ui/preis-meldung` (`PreisMeldungFormPageController`): Lieferant (Pflicht, Datalist), **eine**
  CSV-Datei, Notizen; keine Datenbank-Auswahl (die Kette läuft im konfigurierten Business-Kontext, wie beim
  Diff-Job begründet); Vorprüfung: genau ein File, erkannt als `IfasCsvMeldeFileType.PREIS_MELDEFILE`
  (`IfasCsvMeldeFileTypes`), sonst Fehlermeldung ohne Job; Erfolg → Redirect auf die Detailseite.
- **Recht** `IfasRight.PREIS_MELDUNGEN` (`IFAS_INTRA_USER`, `IFAS_INTRA_SYSTEMSUPPORT`):
  `/ui/preis-meldungen`, `/ui/preis-meldungen/**`, `/ui/preis-meldung`, `/ui/preis-meldung/**`;
  `WebUiAuthorization.canAccessPreisMeldungen()` in `canAccessStm()`; `layout.html` STM-Dropdown-Eintrag
  „Preismeldungen“ und `activePage` `preis-meldungen`/`preis-meldung` in der Aktiv-Liste der Gruppe;
  `IfasSecurityConfigAuthorizationTest` granted/denied (Regel `web-authorization.md`).
- **Preisversionen-Seite, Lieferung statt Diff-Job:** `PreisVersionsView.ZeileRow.job` ist heute
  `@Nullable PreisMeldungDiffJob`. Wird zu `@Nullable Lieferung lieferung` mit
  `record Lieferung(UUID jobId, String jobType, String lieferant, String inputFilename)`;
  `PreisVersionQueryService.toZeileRows` löst die Job-Ids über **beide** Repositories auf (Diff + produktiv,
  je ein `findAllById`). Die Templates (`preis-versionen.html`: Spalten Lieferant/Datei, „erzeugt durch“,
  „beendet durch“) verlinken auf `@{/ui/jobs/{id}}` — der generische Forward landet über `JobDetailPages` auf der
  richtigen Detailseite; kein UI-Pfad im Service. `PreisVersionsPageControllerTest` zieht nach.

## 5. Dokumentation

- `docs/Technische Konzepte/ifas13-jobs.md`: Abschnitt `## PreisMeldungJob` vor `PreisVersionJob` (Eingang,
  Write-once, Außenwirkung, Folgejob mit `sync_requested`, Upload heute / MFT-Ankunft später, nie gelöscht).
- `docs/Technische Konzepte/jobs-catalog.md`: Abschnitt 5.x `PreisMeldungJob — PREIS_MELDUNG` (Mermaid wie 5.3
  mit Upload → Job → Inbox, Rückmeldung-ZIP → Archiv/MFT, → `PreisVersionJob` → `PreisVersionSyncJob`), Diagramm
  „Who triggers whom“ (FORM → PreisMeldungJob → PreisVersionJob → PreisVersionSyncJob), Statustabelle
  (PreisMeldungDiff: „stage 2 … not merged“ → Sync-Plan umgesetzt; PreisMeldung: complete, MFT arrival TODO).
- `docs/Technische Konzepte/mft-interface.md`: `PREIS_MELDUNG` in der Target-Aufzählung des Abschnitts
  „Current state in IFAS13“.

## 6. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **MFT-Ankunft** (Inbound-Pull, `submitFromMft`) | auskommentierter Aufruf mit TODO; braucht den Pull-Kanal, Dedup, `done`-Verschiebung |
| Dispatcher-Zweig für Preisfiles | bleibt beim Diff-Job, solange der Parallelbetrieb läuft |
| Rückmeldungs-Mail / Benachrichtigung Fachbereich | Legacy mailt bei der Preismeldung nicht; ob `WARN`-Protokolle eine Mail auslösen, mit dem Betrieb klären |
| Inbox-Aufräumregel | Tracker-Todo (Fenster, Auslöser, Konsequenzen) |
| Parallelbetrieb-Ende | Diff-Job, Dispatcher-Zweig und `preis_meldung_diff_jobs` entfernen (eigene Migration) |
| Migrations-Stempel, Property einschalten | Sync-Plan Abschnitt 7 / Tracker-Todo |

## 7. Chunks (je ein Opus-Agent, je ein Commit; Persistenz zuerst, Verdrahtung zuletzt)

### Chunk 1 — Persistenz und MFT-Target
- V080 `preis_meldung_jobs`; Entity `PreisMeldungJob` (+ `SourceType`, `JobWithResultBundle`),
  `PreisMeldungJobStatus` (PENDING, PROCESSING, COMPLETED, FAILED, CANCELLED), `PreisMeldungJobRepository`
  (`updateResult`, `markEingangAbgeschlossen` bedingt, `updateNotes`, `updateArchived(Batch)`, Listen-Query mit
  Filtern nach dem Muster `PreisMeldungDiffJobRepository`); `MftTarget.PREIS_MELDUNG`; die Properties-Zeilen (3.3).
- Tests: `PreisMeldungJobRepositoryTest` (Integrationstests, Muster `PreisVersionJobRepositoryTest`): speichern/
  lesen, Marker bedingt (zweiter Aufruf 0), Listen-Filter; `mvn install` des Flyway-Moduls vor den Tests
  (Memory „Flyway-Modul installieren“).
- **Nachtrag 2026-10-12 (umgesetzt):** V080 im Postgres-Baum plus Kommentar-Platzhalter im Sybase-Baum (Regel
  „ein File je Feature und Baum“, wie V063–V079). Die Inbox heißt seit V075 `preis_meldung_zeilen`, ihr FK zeigt
  auf `jobs` — nichts zu tun. Listenfilter liegen als `findListPage(text, status, urteil, archived, pageable)` am
  Repository (Spezifikation + `JobPagingRepository`-Fragment wie beim Diff-Job; Urteil als String, da
  `ifas-persistence-infra` die Domäne nicht kennt). `MftTarget.PREIS_MELDUNG` als letzte Konstante (Ordinale bleiben).
  Schema-Referenz `postgres-db-schema.sql` regeneriert, `package-info` nachgezogen. **Befund:** der Claim des Laufs
  kennt nur Diff-Jobs — nach Chunk 2 verschoben (oben).
- **Stand 2026-10-12 — umgesetzt, Commit `a15b22307`** (gepusht). `PreisMeldungJobRepositoryTest` 14 × 2 DBs;
  Diff-, Lauf- und Sync-Tests unverändert grün (96 Integrationstests).

### Chunk 2 — Services
- `PreisMeldungJobSubmissionService` (3.1, inkl. auskommentiertem `submitFromMft` + TODO),
  `PreisMeldungJobExecutionService` (3.2), `PreisMeldungJobQueryService` (`findById`, `getJobs`, Ressourcen für
  die drei Downloads), Helfer `PreisMeldungZeilen.toEntities` (Diff-Job umgestellt).
- **Claim des Laufs weiten** (Befund Chunk 1): `PreisMeldungZeileRepository.claimUnclaimed` claimt heute nur
  Zeilen, deren Job ein `PreisMeldungDiffJob` mit gesetztem Marker ist. Zweite Unterabfrage auf
  `PreisMeldungJob` mit `eingangAbgeschlossenAt IS NOT NULL` (OR), Javadoc dort und an `deleteByJobId` nachziehen;
  `PreisMeldungZeileRepositoryTest`/`PreisVersionJobTest` um den Fall „Zeilen eines produktiven Jobs werden
  geclaimt, die eines Jobs ohne Marker nicht“ ergänzen.
- Tests `PreisMeldungJobTest` (Integration, H2 + Postgres, Profil mit Work-Queue wie `PreisVersionSyncJobTest`;
  Fixture das Golden-File `db_union` aus `ifas-domain-fondspreise/src/test/resources/.../rueckmeldung/`, als
  Testressource der Integrationstests kopiert): Upload → `COMPLETED`, Zähler, Inbox-Zeilen, Rückmeldung-ZIP mit
  den vier Logs + Originalfile, oekbinfo.log; genau ein `ARCHIVE_FILE`-Item (`FONDSPREISE`, Lieferant) und ein
  `UPLOAD_TO_MFT`-Item (`PREIS_MELDUNG`, Lieferant — Muster
  `AusschuettungsMeldungJobExecutionServiceIntegrationTest:135`); Kind `PreisVersionJob` mit `isSyncRequested()`;
  mit `withSyncEnabled` ein `PreisVersionSyncJob` als Enkel, `kurs`-Zeilen vorhanden; Wiederholung mit gesetztem
  Marker: Zeilen und Items unverändert, ein weiterer Lauf; unbrauchbares File → `FAILED`, keine Zeilen, keine Items,
  kein Lauf. `PreisMeldungDiffJobTest` unverändert grün.
- **Nachtrag 2026-10-12 (umgesetzt):** Claim des Laufs mit zweiter Unterabfrage auf `PreisMeldungJob` (OR), Javadocs
  nachgezogen; `PreisMeldungZeilen.toEntities` als gemeinsamer Helfer, der Diff-Job delegiert. Die Marker-Transaktion
  hält Zeilen, Zähler, Marker und die beiden Work-Items (`ARCHIVE_FILE` FONDSPREISE mit WARNING bei Bugs, sonst INFO;
  `UPLOAD_TO_MFT` PREIS_MELDUNG, HIGH, `createdBy` „PreisMeldungJob(<id>)“). Die Info-Zeile „bereits abgeschlossen“
  steht im Protokoll (innerhalb `executeWithProtocol`), die Zeile „Eingang … completed; Rückmeldung … queued“ ebenso.
  oekbinfo.log heißt `<Basisname>#oekbinfo.log`. `submitFromMft` auskommentiert hinter dem TODO (Pull, Dedup,
  `done`-Verschiebung). Fixture: keine Kopie des Golden-Files, sondern CSV-Zeilen aus `PreisVersionJobTestSupport`
  (zwei gültige, eine unbekannte ISIN → 3/2/1, Urteil `ERROR`). `followUps`/`zeilen` der Test-Support nehmen `Job`.
  Fall 3 (Marker gesetzt) wiederholt den Job wie der Diff-Job-Test über `execute(new JobPayload(id))`; Fall 4 löscht
  das Lieferfile vor der Ausführung (FAILED, Statusmeldung nennt die URI). Hinweis des Agenten: `PreisDataConversions`
  ist die Umkehrung von `PreisMeldungZeilen` — bei Gelegenheit zusammenlegen.
- **Stand 2026-10-12 — umgesetzt, Commit `791ab3736`** (gepusht). `PreisMeldungJobTest` 4 × 2 DBs,
  `PreisMeldungZeileRepositoryTest` +1; main-service 90, Integrationstests 114 grün.

### Chunk 3 — UI und Dokumentation
- Liste, Detail (`JobDetailPage`), Formular, Recht + `WebUiAuthorization` + Menü, Autorisierungstests,
  `Lieferung`-Generalisierung (4), Render-Tests (`ThymeleafPageTestBase`: Liste mit Filtern, Detail mit Inbox-Zeilen
  und drei Downloads, Formular lehnt ein Nicht-Preisfile ohne Job ab, `JobDetailPages` löst den Typ auf),
  Dokumentation (5).
- **Nachtrag 2026-10-12 (umgesetzt):** Seiten in `at.oekb.ifas.web.stm` nach dem Muster der Diff-Seiten: Liste mit
  Spalten Quelle/Geliefert/Angenommen/Bugs/Urteil (+ Notizen), Standardsortierung `empfangenAt` absteigend, Bulk-Archivieren
  ohne Löschen; Detail mit drei Downloads, Inbox-Zeilen über `preis-zeile`-Fragment, Notizen inline, Protokollkarte;
  Formular prüft die Datei per `Resources.peek` + `IfasCsvMeldeFileTypes` (Ausschüttungs-CSV und unerkennbare Datei
  werden mit Klartext abgewiesen, ohne Job), rendert Fehler wie das Ausschüttungs-Formular, kein Lieferant-Default,
  kein DB-Selektor. Recht `PREIS_MELDUNGEN` in `canAccessStm()`, +8 Autorisierungsfälle (inkl. `POST /ui/preis-meldung/upload`).
  `Lieferung(jobId, jobType, lieferant, inputFilename)` an `ZeileRow`; Links über `/ui/jobs/{id}` (Forward via
  `JobDetailPages`). Das geteilte `pagination`-Fragment trägt jetzt auch `urteil` (auf anderen Seiten leer, wie dort
  schon `keyDate`/`taskType`); Befund des Agenten: die nummerierten Seitenlinks aller Listen verlieren `archived`
  (vorbestehend, nicht behoben). `ThymeleafPageTestBase` bekam Pageable-Binding und einen Multipart-Helfer.
  Doku: `jobs-catalog` 5.7 neu (Folgeabschnitte nummeriert), Statuszeilen PreisMeldung/PreisVersion/PreisVersionSync,
  `mft-interface` „Six exist“ mit `PREIS_MELDUNG`, `ifas13-jobs` Abschnitt `PreisMeldungJob`.
- **Stand 2026-10-12 — umgesetzt, Commit `63dfb558b`** (gepusht). web-core 145, web-ui 143, main-service 90,
  Integrationstests 92 (Subset), multidbctx-Boot 4 — grün. **Damit ist der Plan vollständig umgesetzt** (Chunks
  `a15b22307`, `791ab3736`, `63dfb558b`). Offen laut Abschnitt 6: MFT-Ankunft (auskommentiert mit TODO), Inbox-Aufräumregel,
  Parallelbetrieb-Ende, Migrations-Stempel vor dem Einschalten der Property.

## 8. Verifikation

- Chunk-Tests wie oben; zusätzlich `PreisVersionsPageControllerTest`, `PreisMeldungDiffDetailPageControllerTest`,
  `PreisVersionJobTest`, `PreisVersionSyncJobTest` unverändert grün; `ifas-integration-tests-multidbctx` bootet
  (`SteuerdatenAuswertungenJobExecutionServiceMultiDbCtxTest`).
- End to end im `LocalH2OnlyIfasApplication`: Formular → Job → Detailseite mit Rückmeldung-Download, Lauf als
  Teilaufgabe, Preisversionen-Seite zeigt Lieferant/Datei des produktiven Jobs; mit `ifas.fondspreise.preis-version-sync.enabled=true`
  erscheint der Sync unter dem Lauf und die Spalte `kurs` zeigt „seit …“.
- Maven: immer `-Pno-proxy`, Web-Module mit `-Pdev-build`; Properties nur per Bash anfügen.
- **Geprüft 2026-10-12 im `LocalH2OnlyIfasApplication`** (Sync-Property per `-D` an, Stammdaten aus
  `stammdaten-fondspreise-september.yaml`, Lieferung `db_union` 31.08. aus `testdaten_september`): Job COMPLETED
  (10/6/0, INFO), drei Downloads, Archiv/Journal/MFT als NoOp durchgelaufen, Lauf 6 Versionen, Sync 6 `kurs`-Zeilen,
  Preisversionen-Seite verlinkt den produktiven Job und zeigt „seit … (Sync …)“, manueller Auslöser auf Geplante
  Aufgaben liefert einen leeren Sync. User: „looks good to me“.
