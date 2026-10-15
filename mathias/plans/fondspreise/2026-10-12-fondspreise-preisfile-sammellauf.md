# Fondspreise — Preisfile-Sammellauf (`PreisfileJob`, Lauf 1 und 2)

Datum 2026-10-12. Schnitte 3–5 des Trackers in einem Plan: das tägliche Preisfile für die Bezieher aus dem
Ledger, zwei Läufe je Tag, Publikationsprotokoll, Archiv und MFT. Entscheidungen des Users vom 2026-10-12
(Tracker „Sammellauf — Entscheidungen“): jeder Lauf ein Delta, Fallback im letzten Lauf des Tages, kein
`tmp_if_last`, Dateinamen vorerst mit Laufnummer, alle elf Dateien plus Ready-File, Plausi (`-P`) ein eigener Plan.

**Namen** (Nachtrag 2026-10-15): Spalten- und Indexnamen folgen dem Stand nach V084 (`2a007ec34`), Java-Namen der
Namensbereinigung vom selben Tag. V081 legte `funds`, `funds_skipped_fondswaehrung` und den Fallback-Index über
`preis_datum`, `offen` an.

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Preisfile** | die Bezieher-Dateien `preis*.csv/.xml/.txt`, `solva*.csv/.xml`, Satzarten `I1`/`I2`/`I3`/`I9` bzw. `S<n>`/`D<n>` |
| **Lauf** | eine Ausführung des `PreisfileJob`; `daily_run_number` 1 oder 2 |
| **Delta** | alles, was seit dem letzten Lauf noch nicht publiziert ist: offene Versionen ohne Stempel (`I2`), beendete Versionen, deren Löschung noch nicht hinaus ist (`I3`) |
| **Fallback** | je Schlüssel-Tripel (ISIN, Währung, Code) ohne Zeile heute die jüngste offene Version im Fenster — die Legacy-Letztpreis-Projektion, aus dem Ledger |
| **Publikationsprotokoll** | die Stempel `published_at`/`preisfile_job_id` und `deletion_published_at`/`deletion_preisfile_job_id` auf `preis_versions` |
| **Zielgruppe** | `alle` (`preis.csv`, nicht `X`, nicht TEST/AIF), `v` (zusätzlich `veroeffentlichung` A oder V), `p` (zusätzlich `FONDS_ZGRU` PFR oder PF) |
| **Ready-File** | `pr_ready.txt`, Inhalt `INVESTMENFONDSPREISE dd.MM.yyyy-HH:mm` (Legacy-Tippfehler beibehalten), als Letztes hochgeladen |

Legacy-Belege: Explore-Bericht vom 2026-10-12 (Satzaufbau `m_fp_rec.CPP:5996-6043`, Streams `M_FP_DLD.CPP:379-406, 547-717`,
Upload-Reihenfolge `create_preise.csh:182-213`, `ReadAusschuettung` `m_fp_rec.CPP:3698-3721`, Zielgruppen `M_FP_DLD.CPP:521-593`);
Beispiel vom 02.09.2026 in `docs/Fondspreise/beispiele/testdaten_september/Bereitstellung/`.

## 1. Entscheidungen

- **Ein Jobtyp, eine Regel:** jeder Lauf publiziert das Delta; `with_fallback` ist wahr für Lauf 2 und für Lauf 1,
  wenn Lauf 2 ausgeschaltet ist (`scheduled-tasks.preisfile-sammellauf.run2.enabled`). Was nach dem letzten Lauf
  ankommt, geht am nächsten Tag in Lauf 1. Ein manuell ausgelöster Lauf 2 hat immer Fallback.
- **Publikationsprotokoll als Stempel** auf der Version (Muster Sync-Stempel), keine Verlaufstabelle: das erste
  `I2` einer Version und das `I3` ihrer Löschung werden gestempelt; Fallback-Wiederholungen nicht (sie stehen im
  archivierten File). Eine Verlaufstabelle (13 000 Zeilen/Tag) brächte nur Lieferketten-Transparenz (Schnitt 8), die
  später aus den Files gelesen werden kann.
- **`I3` nur, wenn ein `I2` hinausging:** eine Version, die zwischen zwei Läufen entstand und endete, erzeugt keine
  Zeile (wie Legacy `Check4DeleteInTmp`). Ein ersetzter Preis (neue Version, gleicher Schlüssel) ist ein `I2` der
  neuen Version, kein `I3`.
- **Fallback nach Legacy-Semantik aus dem Ledger:** je (ISIN, Währung, Code) die offene Version mit dem höchsten
  Preisdatum im Fenster (`ifas.fondspreise.preisfile.fallback-window-days`, Default 65), ausgenommen Tripel, die heute
  schon eine Zeile hatten (`I2` oder `I3` mit Stempel von heute). Nach einem `D` erscheint damit ab dem nächsten
  Tag der Vorgängerpreis (Rest von P, mit der Fachabteilung bestätigen).
- **Veröffentlicht ⊆ `kurs`:** nur Versionen, deren Währung die Fondswährung ist (Regel wie `KursChanges`), gehen
  ins File; der Eingang lehnt Fremdwährungen nach Go-live ohnehin ab.
- **Zielgruppen wie Legacy:** `X` fällt überall weg, `N` steht in `alle` (Befund K5; mit der Fachabteilung klären,
  bis dahin Legacy-getreu), TEST immer draußen, AIF über `ifas.fondspreise.preisfile.include-aif` (Default `false`,
  Legacy `PREIS_Include_AIF`), C-PL/TECH drin. Stammdaten nach der **aktuellen** `wkn_hist`-Zuordnung (Legacy liest
  nicht zum Preisdatum).
- **Ausschüttungsspalten** 7–9 nur in `alle`: `ASF` des Fonds mit `preisdatum between asf_datum and coalesce(aussch_datum, asf_datum)`
  und `ausschuettung >= 0`, erste Zeile nach `asf_datum, aussch_status` (Legacy ohne `order by`, hier deterministisch),
  Ex-Code fest `EA`, Betrag max. 4 NK, Zahltag `YYYY.MM.DD` oder leer. Hängt an allen Zeilen der Gruppe, auch an Fallback und `I3`.
- **Dateinamen mit Laufnummer:** `preis_1.csv`, `preis_v_1.csv`, …, `pr_ready_1.txt`; Bundle `preis_<yyyy-MM-dd-HH-mm-ss>_<lauf>.zip`.
  Umbenennung, sobald die Fachabteilung entschieden hat (Klärung F); eine Property je Namensschema ist nicht nötig,
  der Writer kennt die Laufnummer.
- **Upload geordnet mit Ready-File zuletzt**, in **einem** Work-Item: `MftService` bekommt einen Sequenz-Upload
  (mehrere ZIP-Einträge in Reihenfolge, dann das Ready-File); Abbruch beim ersten Fehler, Ready-File nur nach
  vollständigem Upload (Verbesserung gegenüber Legacy). T2S (`<YYYY-MM-DD_HH-MM>_preis.csv`, ohne Ready) später.
- **Zahlenformat** wie Legacy `outFloat(v, -1, -4)`: höchstens 4 Nachkommastellen, so viele wie nötig, mindestens
  eine (`204.0`), kaufmännisch gerundet; `preis_v.txt` mit 5 impliziten NK, 13-stellig.
- **Kodierung** ISO-8859-1, Zeilenende LF auch nach der letzten Zeile, kein BOM, kein Quoting.
- Der Job ist nie gelöscht (wie alle produktiven Jobs); Protokoll über `executeWithProtocol`.

## 2. Flyway V081 (Postgres-Baum; Sybase-Platzhalter)

### 2.1 `preis_versions` — vier Stempel, ein Index

| Spalte | Typ | Bedeutung |
|---|---|---|
| `published_at` | timestamptz null | erstes `I2` dieser Version |
| `preisfile_job_id` | uuid null | der Lauf, der es schrieb (logische Referenz) |
| `deletion_published_at` | timestamptz null | das `I3` dieser Version |
| `deletion_preisfile_job_id` | uuid null | der Lauf, der es schrieb |

Checks `ck_preis_versions_published` und `ck_preis_versions_deletion_published` (beide Spalten eines Paars null oder
beide gesetzt). Index `ix_preis_versions_fallback (isin, waehrung, meldekategorie, preisdatum, open)` für die
Fallback-Abfrage; Index `ix_preis_versions_published_at (published_at)` für das Delta (`published_at is null` auf
Postgres über den Index). Kein Backfill: alle Versionen gelten als unpubliziert — **vor dem ersten produktiven Lauf
ist ein Migrations-Stempel nötig** (wie beim Sync; Tracker-Todo erweitern: Versionen vor dem Snapshot gelten als von
Legacy publiziert).

### 2.2 `infra.preisfile_jobs`

JOINED-Kind von `jobs` (Muster V080). `daily_run_number` auf `jobs` (1/2, Unique mit `key_date`).

| Spalte | Typ | Bedeutung |
|---|---|---|
| `id` | uuid PK, FK `jobs` | |
| `with_fallback` | boolean not null | war dies der letzte Lauf des Tages |
| `fallback_window_days` | integer not null | das Fenster zur Laufzeit |
| `erstellt_at` | timestamptz null | der `I1`-Zeitstempel (Beginn der Erzeugung) |
| `result_bundle_file_ref` | text null | `preis_<ts>_<lauf>.zip` mit den elf Dateien (`JobWithResultBundle`) |
| `versions_i2` | integer null | `I2`-Zeilen aus dem Delta |
| `versions_i3` | integer null | `I3`-Zeilen |
| `versions_fallback` | integer null | Fallback-Zeilen |
| `solva_rows` | integer null | Solva-Zeilen (`S<n>` + `D<n>`) |
| `fonds` | integer null | ISINs in `preis_<lauf>.csv` |
| `fonds_skipped_fondswaehrung` | integer null | Versionen, die die Währungsregel ausließ |

Zähler null bis zum Commit; Details (welcher Schlüssel in welchen Stream, Skips) im Protokoll (Memory „Job counters vs protocol“).

## 3. Auswahl aus dem Ledger (`PreisVersionRepository`, Kontext `business-new-introduced`)

1. **Delta `I2`:** `open = true and published_at is null and preisdatum >= :windowStart` (Fenster auch hier, damit
   uralte Nachlieferungen nicht als Delta hinausgehen — Legacy-Fenster `tmp_if_kurs` kennt kein Alter; Abweichung
   bewusst, im Protokoll gezählt).
2. **Delta `I3`:** beendete Versionen mit `deleted = true`, `deletion_published_at is null`, `published_at is not null`
   (oder eine frühere Version desselben Schlüssels publiziert — vereinfacht: die gelöschte Version selbst war
   publiziert), und ohne offene Nachfolgerin desselben Schlüssels (ISIN, Preisdatum, Währung, Code).
3. **Fallback** (nur `with_fallback`): offene Versionen mit `preisdatum >= :windowStart`, je (ISIN, Währung, Code)
   die mit dem höchsten Preisdatum (`NOT EXISTS` jüngere offene desselben Tripels), ausgenommen Tripel mit einer
   Version, deren `published_at` oder `deletion_published_at` heute liegt, und ausgenommen die Versionen aus 1.
4. **Stempel** nach dem Schreiben, in 1000er-Chunks: `markPublished(ids, at, jobId)` bedingt `published_at is null`,
   `markDeletionPublished(ids, at, jobId)` bedingt `deletion_published_at is null`.

Alles über die Währungsregel gefiltert (Stammdaten-Lookup je ISIN, `fondswaehrung = waehrung`), Skips gezählt.

## 4. Stammdaten und Ausschüttungen (Kontext `business`, lesend)

- `InvRepository.findPreisfileFondsDataByIsinIn(Collection<String> isins)`: ISIN, `wfs_wkn`, Name (`txt_bez_xl`,
  ersatzweise `txt_bez_m`), `veroeffentlichung`, `fonds_zgru`, `cod_art_f`; aktuelle `wkn_hist`-Zuordnung
  (`dat_gueltig_bis` null bzw. jüngste), in 1000er-Chunks (Muster `findAusschuettungFundDataByIsinIn`).
  ISIN ohne Stammdaten: Zeile in `alle` mit leerem Namen? Legacy nimmt den gelieferten `txt_bez`; das Ledger hat
  keinen → Name leer, `_v`/`_p` fallen weg, Protokollzeile.
- `AsfRepository.findForPreisfile(Collection<Long> wfsWkns, LocalDate from, LocalDate to)`: alle ASF-Zeilen der
  Fonds mit `asf_datum <= :to` und `coalesce(aussch_datum, asf_datum) >= :from` und `ausschuettung >= 0`; die
  Zuordnung je Preisdatum in Java (erste nach `asf_datum, aussch_status`). Kein Ex-Code in `ASF`: Konstante `EA`.

## 5. Domäne `at.oekb.ifas.domain.fondspreise.preisfile` (reine Funktionen, keine DB)

- `PreisfileRecord(Satzart I2|I3, LocalDate preisdatum, String waehrung, String isin, Meldekategorie code, BigDecimal wert,
  @Nullable Ausschuettung ausschuettung, String fondsname, Zielgruppen gruppen, boolean fallback)`;
  `Ausschuettung(BigDecimal betrag, @Nullable LocalDate zahltag)`; `SolvaRecord(Satzart S|D, int nummer, LocalDate datum, String isin, BigDecimal wert, Zielgruppen gruppen)`;
  `Zielgruppen` aus `veroeffentlichung`, `fonds_zgru`, `cod_art_f`, `include-aif` → Flags `alle`, `v`, `p`.
- `PreisfileRecords.sort`: Block Fallback vor Block Delta, innerhalb nach ISIN, Preisdatum, Währung, Code E–R–Z.
- Writer je Datei, alle auf denselben Records: `PreisfileCsvWriter(Zielgruppe)` (`I1`/`I2`/`I3`/`I9`; Spalten 7–9 nur
  `alle`; `I9` = Stichtag, Anzahl `I3`, Anzahl `I2`), `SolvaCsvWriter(Zielgruppe)` (ohne `I1`/`I9`, Datum `yyyyMMdd`),
  `PreisfileTxtWriter` (Festformat 80 Zeichen für `I1`/`I9`, Positionen laut Bericht), `PreisfileXmlWriter(Zielgruppe)`
  und `SolvaXmlWriter` (DTD-Struktur des Beispiels; Escaping nur `& ' " < >`, ISO-8859-1; `ZAHLTAG` leer → kein
  Element, statt Legacy `XXXX.XX.XX`), `ReadyFileWriter`. `PreisfileNumbers.format` (max. 4 NK, min. 1) und `formatTxt`.
- `PreisfileBundle`: die elf Einträge in Legacy-Reihenfolge (`preis_v.txt`, `preis.csv`, `preis_v.csv`, `preis_p.csv`,
  `solva.csv`, `solva_p.csv`, `solva_v.csv`, `preis.xml`, `preis_v.xml`, `preis_p.xml`, `solva.xml`), Namen mit Laufnummer.
- Tests: Golden-Zeilen aus dem Beispiel vom 02.09. (eine normale Gruppe, eine `EA`-Gruppe mit `101.1000`/`2026.08.03`,
  eine Fallback-Zeile, `I1`/`I9`, eine `S1`/`S2`-Zeile, eine TXT-Zeile, ein XML-`PREISRECORD`), Zielgruppen-Matrix,
  Zahlenformat-Fälle (`204.0`, `0.12`, Rundung auf 4 NK), Sortierung, Umlaute als Einzelbytes.

## 6. Der Job

### 6.1 Einreichung und Scheduling

- `PreisfileJobSubmissionService.submit(LocalDate keyDate, int runNumber, String createdBy)`: `with_fallback`
  nach 1., Fenster aus der Property, `DuplicateJobException` bei vorhandenem `(key_date, daily_run_number)` (Muster
  `SteuerdatenAuswertungenJobExecutionService.submitJob`), `submitToWorkQueue(WQ_TASK_TYPE, job)`.
- `PreisfileSammellaufSchedulingConfig` (Muster `AusschuettungsMeldungBatchSchedulingConfig`): Tasks
  „Preisfile Sammellauf – Lauf 1/2“, ids `preisfile-sammellauf-run-1/2`, `jobType` `Preisfile`, `dailyRunNumber`,
  `triggerIfEnabledAndStichtagIsWorkday` (Legacy MON-FRI); `ScheduledTasksProperties.PreisfileSammellauf { run1 =
  Run(false, "0 0 15 * * MON-FRI"); run2 = Run(false, "0 30 16 * * MON-FRI") }` (Lauf 1 vor Ausschüttungsjob 3, Lauf 2
  nach 16:00 — Befund 2026-09-08); Properties in Hauptanwendung, `ifas-integration-tests`, `-multidbctx` (ASCII, nur per Bash).
- `FondspreiseProperties.Preisfile { int fallbackWindowDays = 65; boolean includeAif = false; }`.

### 6.2 Ausführung — `PreisfileJobExecutionService extends AbstractJobWorkQueueHandler`

Unter `executeWithProtocol(JOB_TYPE, keyDate, INFO, …)`:
1. `erstellt_at = OffsetDateTimes.now()` (der `I1`-Zeitstempel); Auswahl 3.1–3.3 im Ledger-Kontext.
2. Stammdaten und ASF (4.) im Business-Kontext; Währungsregel; Records bauen (5.); Protokollzeilen je Skip.
3. Bundle in den Filestore (`filestore.store(ZipOutputStream…)`, Muster `EstbDailyReportService.writeBundle`).
4. **Eine** isolierte Transaktion (`withJobSystemDbContextIsolatedTransactional`, Ledger und Job-System sind auf dem
   Server dieselbe Postgres): Stempel (3.4, Ledger-Kontext), `updateResult` (Zähler, Bundle, `erstellt_at`),
   `archiveService.sendToArchive(bundle, "preis_<ts>_<lauf>.zip", ArchiveType.FONDSPREISE_SOLVA_AUSWERTUNG, keyDate)`,
   `mftService.sendZipEntriesToMft(bundle, <elf Einträge in Reihenfolge>, readyFile("pr_ready_<lauf>.txt", inhalt), MftTarget.FONDSPREISE, SubmitOptions HIGH)`.
   Stempel und Aufträge fallen nie auseinander; ein Lauf, der vor dem Commit stirbt, hinterlässt nichts, der Retry
   erzeugt das File neu (Zähler/Bundle überschrieben).
5. Logzeilen-Summary; Rückgabe Protokoll-URI. `maxAttempts` Default.

Nebenläufigkeit: ein Lauf (`PreisVersionJob`) kann während der Auswahl Versionen beenden oder anlegen — eine danach
beendete Version wurde als offen gelesen und gestempelt (`I2` hinaus, Bezieher hat sie); ihr `I3` folgt im nächsten
Lauf, weil die Stempel bedingt sind und `deletion_published_at` null bleibt. Zwei Läufe zugleich (Lauf 1 und ein
manueller Lauf 2) wären über `(key_date, daily_run_number)` verschieden; die bedingten Stempel verhindern doppelte
`I2`, ein Schlüssel kann aber in beiden Files stehen (harmlos, Upsert). Kein Aktiv-Guard nötig.

### 6.3 `MftService`: geordneter Sequenz-Upload

- `MftUploadPayload` erhält optional `List<MftUploadEntry> entries` (`zipEntryName`, `remoteFileName`) und
  `@Nullable ReadyFile readyFile` (`remoteFileName`, `content`); Handler: Einträge in Reihenfolge aus dem ZIP
  hochladen, dann das Ready-File, Abbruch beim ersten Fehler (Retry wiederholt alles — Bezieher überschreibt).
  `sendZipEntriesToMft(URI zip, List<MftUploadEntry>, @Nullable ReadyFile, MftTarget, SubmitOptions)`.
- `MftTarget.FONDSPREISE` (Legacy `MFT_PRD`/`MFT_TST`, ftpdir pool — dieselbe Gegenstelle wie `STEUERDATEN_AUSWERTUNG`):
  `mft.service.targets.FONDSPREISE.endpoint-type=STEUERDATEN_AUSWERTUNG` in Hauptanwendung und `ifas-integration-tests`;
  `archive.service.types.FONDSPREISE_SOLVA_AUSWERTUNG.*` in `ifas-integration-tests` nachziehen (fehlt dort).
- `mft-interface.md`: Target und Sequenz-Upload beschreiben; die veraltete „Current state“-Tabelle (Property
  `directory`, Multipart-Felder) auf den Stand des Codes bringen.

## 7. UI und Dokumentation

- Detailseite `/ui/preisfile-jobs/{id}` (`PreisfileJobDetailPageController implements JobDetailPage`, Paket
  `at.oekb.ifas.web.stm`, aktive Seite `preis-meldungen`): Hauptkarte „Preisfile Sammellauf – Lauf n“, Karte
  „Lauf“ (Fallback ja/nein, Fenster, erstellt um), Karte „Zähler“ (sechs Zeilen), generische Ergebnis-Bundle-Karte
  (Download `/ui/jobs/{id}/result-file`), Protokoll. Keine Liste, keine Aktionen; Pfade ins Recht `PREIS_MELDUNGEN`
  (+ Autorisierungsfälle). Geplante Aufgaben zeigen die zwei Tasks automatisch.
- `ifas13-jobs.md` Abschnitt `PreisfileJob`, `jobs-catalog.md` 5.x + Statuszeile + „Who triggers whom“, `mft-interface.md` (6.3).

## 8. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| Plausi `preis_dld.e -P` (`fplausib.txt`, `preise_check`, E/R/Z-Relationen, `i_neue_fonds` → WDBO) | eigener Plan (User 2026-10-12) |
| T2S-Datei `<YYYY-MM-DD_HH-MM>_preis.csv` ohne Ready | eigenes `MftTarget`, nach Klärung der Bezieher |
| Endgültige Dateinamen (Klärung F) | Umbenennung im Writer, eine Zeile je Datei |
| `N`-Fonds in `alle` (Befund K5), AIF-Schalter produktiv | Fachabteilung / Betrieb |
| Migrations-Stempel für die Publikation | mit dem Sync-Stempel zusammen setzen: Versionen vor dem Snapshot gelten als publiziert |
| Lieferketten-Transparenz (Schnitt 8), Verlaufstabelle der Publikationen | aus den archivierten Files oder später eigene Tabelle |
| MFT-TEST-Zweitverteilung (cp_06a) | Betrieb |
| Fehlmeldung (Schnitt 7), Kennzahlen (Schnitt 6) | unverändert offen |

## 9. Chunks (je ein Opus-Agent, je ein Commit; Persistenz zuerst, Verdrahtung zuletzt)

### Chunk 1 — Persistenz
- V081 (2.1, 2.2, Sybase-Platzhalter), Entity `PreisfileJob` (+ Status, `JobWithResultBundle`), Repository
  (`updateResult`, `findByKeyDateAndDailyRunNumber`, `countByKeyDateAndDailyRunNumber`), `PreisVersionRepository`
  (3.1–3.4), `InvRepository`/`AsfRepository` (4.), `PreisVersion` Stempelfelder, Schema-Referenz regenerieren,
  `package-info`. Tests: Repository-Tests der vier Abfragen (Delta, `I3`-Kandidaten, Fallback mit „heute schon eine
  Zeile“, bedingte Stempel), Stammdaten-/ASF-Abfragen gegen `FondspreiseStammdatenCreator`-Seeds.
- **Nachtrag 2026-10-12 (umgesetzt):** V081 wie geplant (Sybase-Platzhalter); `PreisfileJob` mit `JobPagingRepository`-
  Fragment (abgeleitetes `countBy…` bricht unter Hibernate 6 bei JOINED, wie beim Ausschüttungs-Batch), keine Setter
  auf den Ergebnisfeldern. `PreisfileFondsData` trägt zusätzlich die Fondswährung (`inv.waehrung`) für die Währungsregel;
  `findCurrentPreisfileFondsDataByIsinIn` wählt je ISIN wie Legacy (`dat_gueltig_bis` null zuerst, dann jüngste, dann
  `dat_gueltig_ab` jüngste). `txt_bez_xl` ist not null — der `COALESCE` auf `txt_bez_m` bleibt, ist aber untestbar.
  **Für Chunk 3 (vom Agenten notiert):** (1) ein Tripel aus dem Delta kann zugleich einen Fallback-Kandidaten liefern
  (verspätete Lieferung mit älterem Preisdatum als die jüngste publizierte offene Version, oder sein `I3` im selben
  Lauf) — der Service filtert die Delta-Tripel aus dem Fallback; (2) `findUnpublishedDeletions` kann zwei `I3` je
  Schlüssel liefern (A publiziert und gelöscht, B eröffnet, publiziert und gelöscht, bevor A's `I3` hinausging) — je
  Schlüssel nur eines schreiben, beide stempeln; (3) `cod_art_f` kommt auf Sybase gepolstert (`"AIF "`), strippen wie
  `PreisMeldungStammdatenService`; (4) `findForPreisfile` erwartet `from`/`to` als Tagesbeginn; (5)
  `fonds_skipped_fondswaehrung` zählt Versionen.
- **Stand 2026-10-12 — umgesetzt, Commit `efd1c5fd2`** (gepusht). `PreisfileJobRepositoryTest` 7 × 2 DBs,
  `PreisVersionRepositoryTest` +11, `InvRepositoryTest` +3, `AsfRepositoryTest` neu; Nachbartests grün (134 im Rerun ohne Sybase).

### Chunk 2 — Domäne: Records und Writer
- Paket `preisfile` (5.), alle elf Writer, Zahlen-/Datumsformat, Zielgruppen, Sortierung, Bundle-Reihenfolge, Ready-File.
- Tests mit den Golden-Zeilen des 02.09. (Beispiel als Testressource auszugsweise), Umlaute, Rundung, leere Ausschüttung,
  Datei ohne `I2` (`I9` mit `0`), Solva ohne Kopf/Fuß.
- **Nachtrag 2026-10-13 (umgesetzt):** Paket `preisfile` mit Records (`PreisfileRecord`, `SolvaRecord`, `Zielgruppen.of`
  strippt `cod_art_f`), `PreisfileNumbers` als Port von `outFloat` (bis 4 NK so viele wie nötig, min. 1; braucht es
  mehr, genau 4 **mit** Nullen — `1.00001` → `1.0000`, und der Float-Rest `101.09999847…` → `101.1000` wie Legacy; der
  ASF-Betrag ist deshalb **ungerundet** durchzureichen), elf Writer, Ready-File, `PreisfileBundle` in Legacy-**Upload**-
  Reihenfolge (das Legacy-Archiv-ZIP ordnet anders: `preis.csv, preis.xml, preis_v.csv, …` — belanglos). Probe gegen alle
  fünf Legacy-Tage (01.–07.09.): 45 von 55 Files byteidentisch, die übrigen 10 (`preis.csv`/`preis.xml`) nur im
  Float-Rest der Ausschüttungsbeträge verschieden. Bewusste Abweichungen: `I9`/TXT bei leerem File ohne Legacys fünftes
  Feld; `<ZAHLTAG/>` statt `XXXX.XX.XX`; Halb-Rundung dezimal statt binär; `I3` vor `I2` desselben Schlüssels (Legacy nach
  `eintragezeit`); Zeichen außerhalb ISO-8859-1 als `?`. Solva-XML: ein `SOLVARECORD` je Wert (Legacy `OutSolvaXml`), nicht
  je (ISIN, Datum); `ANZAHL`-Zähler im XML zählen Records, nicht Zeilen. Kein Legacy-Tag enthält ein `I3`/`D` — diese
  Formate stammen allein aus dem Code. **Für Chunk 3:** Name und Ausschüttung einer Gruppe kommen aus ihrem ersten
  Record; `I3`-Duplikate je Schlüssel vorher entfernen (der XML-Writer lehnt einen Code zweimal je Gruppe ab); Writer
  nehmen `Collection` und sortieren selbst. **TXT/XML sind Blätter:** ein Writer + ein Bundle-Eintrag, später ohne
  Nebenwirkung entfernbar (User-Frage 2026-10-13).
- **Stand 2026-10-13 — umgesetzt, Commit `f9fbc64fe`** (gepusht, Merge `4e1dd44b5`). Domänenmodul 289 Tests grün,
  davon 85 neu (12 Golden-Zeilen-Tests), forbiddenapis sauber.

### Chunk 3 — Services, Scheduling, MFT-Sequenz
- `MftService` Sequenz-Upload + `MftTarget.FONDSPREISE` + Properties (6.3; `MftServiceIntegrationTest` +
  `RestMftClientTest` erweitern: Reihenfolge, Ready zuletzt, Abbruch beim Fehler, Retry wiederholt alles).
- `PreisfileJobExecutionService`, `…SubmissionService`, `…QueryService`, `PreisfileSammellaufSchedulingConfig`,
  Properties (6.1, 6.2). Integrationstests (H2 + Postgres, Work-Queue-Profil, Fixture über `PreisVersionJobTestSupport`
  und Stammdaten-Creator): Lauf 1 schreibt das Delta und stempelt; Lauf 2 am selben Tag ohne neue Lieferung schreibt nur
  Fallback (alle Tripel ohne Zeile heute); Lieferung zwischen den Läufen → nur in Lauf 2; `D` → `I3` im nächsten Lauf,
  danach Vorgängerpreis im Fallback des letzten Laufs; Lauf 2 aus → Lauf 1 mit Fallback; Fremdwährung übersprungen;
  Bundle-Einträge und Reihenfolge; genau ein Archiv- und ein MFT-Item mit elf Einträgen und Ready; Duplikat am selben
  Tag abgelehnt; Stempel sind bedingt (Wiederholung schreibt kein zweites `I2`).
- **Nachtrag 2026-10-13 (umgesetzt):** `MftService.sendZipEntriesToMft(zip, entries, readyFile, target, options)` — ein
  Item, Einträge in Listenreihenfolge, Ready-File zuletzt, Abbruch beim ersten Fehler, Retry von vorn
  (`MftUploadEntry`, `MftReadyFile`; alte Payloads lesbar). `MftTarget.FONDSPREISE` auf dem Endpoint
  `STEUERDATEN_AUSWERTUNG`. Auswahl/Stammdaten/ASF/Records im package-privaten `PreisfileRecordsAssembler`; der
  Execution-Service hält Stempel, Zähler, Archiv- und MFT-Item in einer Transaktion. Abweichungen: Fall 2 des Plans war
  in sich widersprüchlich (heute publizierte Tripel haben heute eine Zeile und bekommen keinen Fallback) — der Test
  seedet „gestern publiziert“; Versionen außerhalb jeder Zielgruppe (`X`, TEST, AIF ohne Schalter) werden gestempelt,
  sonst kämen sie jeden Lauf wieder; ohne Stammdaten → WARN, ungestempelt; Fremdwährung → übersprungen, gezählt,
  ungestempelt; bei mehreren Löschungen je Schlüssel geht die jüngste als `I3`, alle werden gestempelt; Ready-File-Zeit
  = `erstellt_at` des Laufs (nicht Upload-Zeit); `publishedAt` = `erstellt_at`. **Umgebung:** der Postgres-Testcontainer
  startet seit heute Mittag nicht mehr (podman `log_driver = journald`, Testcontainers wartet auf die Logzeile);
  der Agent lief über einen temporären Socket mit `k8s-file`, mein Rerun nur H2 (`-Pskip-postgres15-tests`, 68 grün).
- **Stand 2026-10-13 — umgesetzt, Commit `6f40d81f5`** (gepusht). main-service 92, Integrationstests 68 (H2) grün;
  Postgres-Hälfte beim Agenten grün, lokal bis zum Log-Driver-Fix nicht nachprüfbar.

### Chunk 4 — UI und Dokumentation
- Detailseite, Recht, Autorisierungstests, Render-Tests; `ifas13-jobs.md`, `jobs-catalog.md`, `mft-interface.md`;
  Tracker-Todo Migrations-Stempel um die Publikationsstempel erweitern.
- **Nachtrag 2026-10-13 (umgesetzt):** Detailseite `/ui/preisfile-jobs/{id}` in `web.stm` nach dem Muster der
  Sync-Seite (Karten *Lauf* mit Fallback/Fenster/Erstellt um und *Zähler* mit sechs Zeilen; Ergebnis-Bundle über die
  generische Karte und `/ui/jobs/{id}/result-file` — erste dedizierte Seite, die den generischen Download nutzt, Javadoc
  dort nachgezogen), Pfade im Recht `PREIS_MELDUNGEN` (+8 Autorisierungsfälle). Doku: `ifas13-jobs.md` Abschnitt
  `PreisfileJob`, `jobs-catalog.md` 5.8 (Folgeabschnitte nummeriert, Timer-Knoten in „Who triggers whom“, Statuszeile),
  `mft-interface.md` „Current state“ gegen den Code berichtigt (Property `endpoint-type`, ein `FILE`-Part + Supplier-Header,
  sieben Targets, Sequenz-Upload). Tracker-Todo Migrations-Stempel um die Publikationsstempel erweitert (nur offene
  Versionen vor T stempeln; beendete nicht anfassen, sonst würden alte Löschungen zu `I3`-Kandidaten).
- **Stand 2026-10-13 — umgesetzt, Commit `50d943850`** (gepusht). web-core 153, web-ui 168 grün. **Damit ist der Plan
  vollständig umgesetzt** (Chunks `efd1c5fd2`, `f9fbc64fe`, `6f40d81f5`, `50d943850`). Offen laut Abschnitt 8: Plausi
  `-P`, T2S, endgültige Dateinamen, `N`-Fonds in `alle`, Migrations-Stempel (Sync + Publikation) vor dem Einschalten.
- **Smoke-Test 2026-10-13 (`LocalH2OnlyIfasApplication`, Sync eingeschaltet, Lauf-Tasks manuell ausgelöst):**
  db_union-Lieferung 31.08. → Lauf 1: `preis_1.csv` mit sechs `I2` (Namen aus `inv`, Spalten 7–9 leer, `I9;…;0;6`),
  alle elf Dateien plus `pr_ready_1.txt` in Legacy-Reihenfolge am NoOp-MFT, Bundle archiviert; zweiter Trigger von
  Lauf 1 → `DuplicateJobException` als Flash. Lieferung 01.09. → Lauf 2: sechs neue `I2`, 0 Fallback (alle Tripel
  hatten heute eine Zeile). Fallback-Pfad: `published_at` der zwölf Versionen und `key_date` der beiden Jobs per
  SQL-Konsole um einen Tag zurückgesetzt, Lauf 2 erneut → 0 `I2`, sechs Fallback-Zeilen (als `I2` mit Preisdatum
  01.09., Protokoll „6 fallback version(s) of 6 candidate(s)“, nichts neu gestempelt). Hinweis: lokal sind beide
  Tasks aus, daher zeigt auch Lauf 1 `Fallback: Ja` (`withFallback = run == 2 || !run2.enabled`) — korrekt nach Regel.

## 10. Verifikation

- Chunk-Tests wie oben; `PreisVersion*Test`, `PreisMeldungJobTest`, `MftServiceIntegrationTest`,
  `ArchiveServiceIntegrationTest` unverändert grün; `ifas-integration-tests-multidbctx` bootet.
- End to end im `LocalH2OnlyIfasApplication`: Stammdaten-YAML und die db_union-Lieferungen vom 01.–03.09. über das
  Preismeldungs-Formular; Lauf 1 manuell auslösen → Bundle herunterladen, `preis_1.csv` gegen die Zeilen der
  Beispiel-Bereitstellung derselben ISINs vergleichen (Format, Spalten 7–9 ohne ASF leer); zweite Lieferung, Lauf 2 →
  nur Delta plus Fallback; Preisversionen-Seite unverändert; Work-Queue zeigt das MFT-Item mit zwölf Schritten (NoOp-Client).
- Maven immer `-Pno-proxy`, Web-Module `-Pdev-build`; Properties nur per Bash anfügen.
