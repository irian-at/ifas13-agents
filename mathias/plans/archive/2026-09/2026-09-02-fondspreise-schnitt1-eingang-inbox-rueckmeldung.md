# Fondspreise Schnitt 1 — Eingang, Inbox, Rückmeldung, PreisMeldungDiffJob

## Context

Erster Implementierungsschnitt der Fondspreis-Neuentwicklung nach dem Konzept
`mathias/plans/fondspreise/2026-08-31-fondspreise-neuentwicklung-konzept.md` (Runden 1–8) und dem
Tracker im selben Ordner. Schnitt 1 baut die **Stufe 1 der Lieferkette** — Eingangsprüfung,
Inbox (persistierte akzeptierte Zeilen), Rückmeldungs-Artefakt — getragen vom
Parallelbetrieb-Diff-Job `PreisMeldungDiffJob`, der den bestehenden BadInput-Stub ersetzt
(Muster: `IsinAnforderungslisteDiffJob`). Im Parallelbetrieb wird die Rückmeldung **nicht
versendet**, sondern gegen die Altsystem-Antwort gedifft. Der Eingang entsteht als
wiederverwendbarer Service, den später der Live-Job (`PreismeldungJob`, späterer Schnitt) aufruft.

Blocker sind gefallen: produktive `tax_code`-Werte liegen vor (TEST-Abzug, V1 der Voranalyse);
die vollständige Legacy-Prüfliste inkl. der in der Ist-Analyse fehlenden Prüfung
„Preisrelation ±16 Zeilen" ist recherchiert (Fundstellen unten).

**Gesetzte Vorgaben:** Sybase schema-gesperrt; neue Business-Tabellen nach Postgres, Katalog
`kurs`, eigener Context-Key, Modul `ifas-persistence-fondspreise`; Job-Tabellen bleiben `infra`;
`job_id` an Business-Tabellen ist logische UUID-Referenz (kein FK).

## Festgelegte Designdetails (im Code verifiziert)

- **D1 `tax_code`:** existiert nirgends in IFAS13 (kein Entity, keine Migration, keine Basedata).
  Neu: read-only Entity `TaxCode` (`catalog="kurs"`) im neuen Modul; Flyway-DDL in **beiden**
  Bäumen nach dem Muster `V041__archivierung.sql` (provisioniert Legacy-Tabellen für lokale/CI-DBs;
  sybase16-Variante mit echter DDL, weil Multi-DB-Tests tax_code im Business-Kontext auch gegen die
  Docker-Sybase lesen). Wiederverwendet: `Hwa`/`Waehrung` (`ifas-persistence-stamm`),
  `InvRepository.getInvByIsin/findAllKnownIsins`, `WknHistRepository.findWfsWknByIsin`.
- **D2 Input-Bundle = flaches ZIP:** Das Altsystem-Antwort-ZIP
  (`<YYYYMMDD_HHMMSS>_<orig>.zip` mit statistics/error/info/data.log + Originalfile) ist
  unverändert als Job-Input verwendbar — `hasOnlyPreisMeldungFiles()` greift schon (Logs zählen in
  keine Kategorie, CSV wird per Name/Inhalt erkannt; verifiziert für die 4 Beispielfiles). Nötig:
  neuer `BundleFileType.DATA_LOG_FILE` + `endsWith("data.log")`-Zweig (vor dem generischen) in
  `SteuerMeldungBundles.determineFileTypeFromFilePath` + `getDefaultFilename`-Case — sonst landet
  data.log als `UNKNOWN_FILE` mit leerem Inhalt. ZIP nur mit Lieferfile (ohne Altsystem-Antwort) →
  Job erzeugt nur die Rückmeldung, Diff-Abschnitt: „keine Altsystem-Antwort — kein Vergleich".
  Nested ZIPs / mehrere Lieferungen pro Upload: in Schnitt 1 nicht unterstützt (dokumentiert).
- **D3 Diff-Normalisierung:** `PreisMeldungDiffSetting`-Record (Muster `IsinAnforderungDiffSetting`)
  mit `databaseContext`, `ignoreInfoDelMessages=true` (B21/B22 `INFO_DEL_*` fehlen per Konzept —
  bekannte Abweichung) und `ignoredMessageCodes`. Vor dem Vergleich: ZIP-Namenspräfix
  `\d{8}_\d{6}_` strippen, Zeitstempel in Log-Kopfzeilen maskieren; dann zeilenweiser Vergleich je
  Log. Parser-Vorbild: `IsinAnforderungDiffLegacyLogs` (ifas-domain-stm).
- **D4 Meldungsmodell:** eigenes Modell in `ifas-domain-fondspreise` (csv-schema hat keine
  Severity): Enum `PreismeldungMsgCode` mit Ziel-Log (error/info/oekbinfo/data), data.log-Status,
  Severity (Zeile verworfen / Info / Feld geleert / Statistik), Texte de/en 1:1 aus Legacy
  `Ifas/cprogs2/preise4/c_param.cpp:285-586` (`InitMsgs`). LMT-CsvValidationMsgs werden auf
  `ERR_LMTPROZENT1`/`ERR_LMTRUECKL2`/`ERR_LMTRUECKL2_0` gemappt (Feld leeren, Zeile bleibt).
- **D5 Idempotenz Inbox:** `deleteByJobId(jobId)` + `saveAll(...)` in einer Transaktion im
  Fondspreise-Kontext (Konzept-Auflage).
- **D6 Kontext-Key:** neues `ContextConfig`-Feld `fondspreise` in `DatabaseContextProperties` +
  `getFondspreiseDbKey()`/`withFondspreiseDbContext[Transactional]` in `DatabaseContextHelper` —
  NICHT das `@Value`-Muster von `ausschuettung-tmp-db-key` (dort als todo markiert). Effektiver
  Property-Name: `database-context.fondspreise.db-key` (Punkt statt Bindestrich — im Tracker
  vermerken, Konzept in der nächsten Runde nachziehen).

## Arbeitspakete

### AP1 — Persistenzmodul + Flyway (parallel zu AP2/AP3/AP7)
- Neu `ifas-database/ifas-persistence-fondspreise/` (POM-Muster `ifas-persistence-stamm`; Eintrag in
  `ifas-database/pom.xml` + `dependencyManagement` im Root-POM + Dependency in
  `ifas-services/ifas-main-service/pom.xml`). Paket `at.oekb.ifas.persistence.fondspreise` wird
  über `PersistencePackage` automatisch gescannt — keine Spring-Config.
- `PreismeldungZeile` — `@Table(catalog="kurs", name="preismeldung_zeilen")`, PK `(job_id UUID,
  zeilen_nr int)` (`@EmbeddedId`), Spalten laut Konzept-Entscheidung 3: isin, preisdatum,
  waehrung (Lieferwährung), meldekategorie (nach Alias-Auflösung), aktion, `wert` als **varchar**
  (normalisiert Komma→Punkt/Blanks raus/`ignore_null`→"0" — String erhält NK8-Treue für
  Diff/Rebuild), fondsbezeichnung, lmt_prozentkennzeichen, lmt_stichtag. Kein FK auf jobs.
- `PreismeldungZeileRepository` (`deleteByJobId`, `findByIdJobIdOrderByIdZeilenNr`, `countByIdJobId`),
  `TaxCode` + `TaxCodeRepository` (`findAll`), `package-info` (`@NullMarked`).
- Flyway (Nummern beim Implementieren gegen den Stand prüfen; heute max V060):
  `postgres15/V061__preismeldung_zeilen.sql` (+ grant `${app-user}`), `sybase16/V061` = Kommentar
  „not required"; `V062__tax_code.sql` postgres15 **und** sybase16 mit echter DDL
  (Legacy-Provisionierungs-Kommentarkopf wie V041).

### AP2 — DB-Kontext `fondspreise` (parallel)
- `DatabaseContextProperties`: `private ContextConfig fondspreise = new ContextConfig("h2-db3");`
- `DatabaseContextHelper`: Getter + `withFondspreiseDbContext(...)` + `...Transactional(...)`.
- `database-context.fondspreise.db-key=` in `application-server-deployment.properties`
  (`postgres-server`) und allen `application-local-*.properties` (Wertespiegel von
  `ausschuettung-tmp-db-key`), plus Test-Property-Files der Integrationstests.

### AP3 — Meldungsmodell (parallel; Domain)
- `ifas-domain-fondspreise/.../meldung/`: `PreismeldungMsgCode` (Codes für Schnitt 1:
  ERR_FORMAT01/03/04, ERR_NODATA01/02, ERR_ISIN01/02/03/04/06, ERR_DATE02/03/04, ERR_CODE01/02/03,
  ERR_CURRENCY01/04, ERR_AKTIONSCODE01, ERR_VALUE01/02/04/05/06/08/09, ERR_LMTPROZENT1,
  ERR_LMTRUECKL2, ERR_LMTRUECKL2_0, INFO_DATE02, INFO_CURRENCY02, STAT_EMPTY01, STAT_HEADER01 —
  `ERR_ISIN05` bewusst weggelassen, produktiv tot), `PreismeldungMsg`-Record, `DataLogStatus`
  (vollständige Statusliste aus `M_INSERT.CPP` extrahieren; bekannt: −2 leer, −3 Header,
  −5 ignoriert, 1 ok).

### AP4 — Stammdaten-Provider (Interface früh; Impl nach AP1)
- Domain: `PreismeldungStammdatenProvider` (Interface + `ofStatic`-Testvariante, Muster
  `ErmittlungsvorgabeProvider`), Records `FondsStammdaten` (numWfs, kag → Region `< 10000` = Inland,
  fondswaehrung, fondsBeginn/Ende) und `TaxCodeParameter` — Domain bleibt persistence-frei.
- Service: `PreismeldungStammdatenService` implements Provider; nutzt `WknHistRepository`,
  `InvRepository`, `HwaRepository`, `WaehrungRepository`, `TaxCodeRepository`; kein eigener
  Kontextwechsel (läuft im Business-Kontext des Aufrufers).

### AP5 — Eingangs-Prüfkette (Domain; nach AP3 + AP4-Interface)
- `ifas-domain-fondspreise/.../Eingang/PreismeldungEingang.java`: **zeilengenauer** Reader (physische
  Zeilen, windows-1252, CR/LF-tolerant — nicht der commons-csv-Pfad, der `ignoreEmptyLines` hat und
  die data.log-Zeilennummern verschöbe). Fileebene: Excel-Magic→ERR_FORMAT04, UTF-16-BOM→
  ERR_FORMAT03, <5 Spalten→ERR_FORMAT01, 0 Datenzeilen→ERR_NODATA01/02. Zeilenebene in
  Legacy-Reihenfolge: B0 leer→STAT_EMPTY01(−2); B2 Header→STAT_HEADER01(−3); B3 ISIN
  12 Zeichen/2 Buchstaben/Prüfziffer→ERR_ISIN01/02 (commons-validator `ISINValidator`, Dependency
  ins POM; Vorbild `CsvAusschuettungenValidations`); B4 Stammdaten via Provider; B5 Datum/Jahr
  1900–2100→ERR_DATE02; B6 Zukunft außer `future='J'`→ERR_DATE03; B7 nur bei
  `datum_bug_or_ignore='J'`: lieferung_bis→lieferung_ab→datum_max→datum_min→ERR_CODE02; B8 nur R:
  > fonds_ende→ERR_DATE04 (einseitig, Q/T nicht); B9 nur R: < fonds_beginn→INFO_DATE02→oekbinfo;
  B11 Region/unbekannt→ERR_ISIN04/03/06; B12 Währung HWA→waehrungen→ERR_CURRENCY01,
  nur-waehrungen→INFO_CURRENCY02→oekbinfo; B13 Aktion leer=N, N/D, I nur L2→ERR_AKTIONSCODE01;
  B14 `ignore_null='J'`+leer→"0"; B16 CheckValue-Reihenfolge: ERR_CODE03→ERR_CODE01 (nach
  `tax_code.alias`-Auflösung)→bei D fertig→ERR_VALUE08→ERR_VALUE04→ERR_VALUE09 (max_nk)→
  ERR_VALUE01 (untergrenze)→ERR_VALUE02 (obergrenze)→ERR_CURRENCY04 (`isinwaehrung='J'`);
  B18/B19 LMT-Mapping (Feld leeren, Zeile bleibt); **B20 Preisrelation**: Z ≯ R, E ≮ R, gleiche
  ISIN+Datum+Währung+Aktion, Fenster ±16 Zeilen→ERR_VALUE05/06 (fehlt in der Ist-Analyse;
  Legacy `M_INSERT.CPP:3878-4042`, `lRange4Preis=16` in `c_param.cpp:139`).
  **Nicht in Schnitt 1:** B21/B22 (INFO_DEL_* → Sammelreport; bekannte Diff-Abweichung), B15
  (Q/T/TA), B17 (Intervall), B10 (Format-Mix).
- `PreismeldungEingangResult`: akzeptierte Zeilen, Meldungen, data.log-Status je physischer Zeile,
  Statistik, Urteil ERROR/INFO.

### AP6 — Rückmeldungs-Writer (Domain; nach AP3)
- `.../rueckmeldung/`: error.log (5 Kopfzeilen im `WriteLieferInfo`-Format), info.log,
  statistics.log, data.log, oekbinfo.log — **ISO-8859-1 + CRLF byte-genau** (Legacy `unix2dos -c
  iso`; 0x80–0x9F meiden). ZIP `<YYYYMMDD_HHMMSS>_<originalname-mit-extension>.zip` mit
  statistics/error/info/data.log + Originalfile; oekbinfo.log NICHT ins ZIP (separates Artefakt im
  Result-Bundle). Urteil: error.log-Zeilenzahl > 5 → ERROR, sonst INFO. Zeitquelle
  `OffsetDateTimes.now()` (forbidden-apis). Formatreferenz: STM-Antwort-ZIPs
  (`docs/Testdaten Fachabteilung/Lieferung 2026-02-17/zip_0217.zip`, gleiche Legacy-Writer) +
  `make_einzel.awk:292-427`.

### AP7 — Job-Infrastruktur (parallel)
- Neu `ifas-persistence-infra/.../preismeldungdiff/` (1:1 Muster `isinanforderungdiff/`):
  `PreisMeldungDiffJob` (JOB_TYPE "PreisMeldungDiff", WQ_TASK_TYPE "PREIS_MELDUNG_DIFF",
  `infra.preis_meldung_diff_jobs`; Felder inputBundleFile, resultBundleFile, inputFilename,
  lieferant, diffSettings, errorCount, warningCount, bugZeilenCount, rueckmeldungUrteil, notes),
  Status-Enum, Repository + Impl (`AbstractJobPagingRepository`), package-info („Parallelbetrieb
  only"). Flyway `postgres15/V063__preis_meldung_diff_jobs.sql` (uuid-PK, FK auf jobs, grant) +
  sybase16-Platzhalter. `job.priority.preis-meldung-diff=LOW` in application.properties.

### AP8 — Services + Diff (nach AP1–AP7)
- `service/preismeldung/`: **Stub ersetzen** in `PreisMeldungDiffJobSubmissionService` (Signatur
  bleibt — Aufrufer `ParallelbetriebJobSubmissionService:391-399` unverändert): Filestore-Store,
  Setting mit `databaseContext = dbCtxHelper.getCurrentDbKey()`, `jobService.submitToWorkQueue`;
  dazu repeat/reset/notes/archive nach Vorbild. `PreisMeldungDiffSetting`-Record.
- `PreisMeldungDiffJobExecutionService extends AbstractJobWorkQueueHandler`: Job/Input in
  `withJobSystemDbContext` laden → Fachlogik in `withDatabaseContext(setting.databaseContext())`
  (Bundle lesen, Eingang via `PreismeldungEingangService`) → Inbox in
  `withFondspreiseDbContextTransactional` (D5) → Rückmeldungs-ZIP erzeugen; wenn Altsystem-Logs im
  Bundle: normalisierter Diff → Result-ZIP via `filestore().store(...)` +
  `updateResultBundleFile` in `withJobSystemDbContext`; Rückgabe-URI = Protokoll.
- `PreismeldungEingangService` (wiederverwendbar für den späteren Live-Job),
  `PreisMeldungDiffJobQueryService` (Muster IsinAnforderungDiff).
- Domain-Diff `.../diff/PreismeldungRueckmeldungDiff` + Result (Normalisierung D3, Klassifizierung
  bekannt/unbekannt, Textreport ins Result-ZIP).
- `ifas-domain-stm`: `BundleFileType.DATA_LOG_FILE` + Erkennungs-/Default-Filename-Zweige (D2).

### AP9 — Tests (inkrementell; Konventionen `.claude/rules/testing-conventions.md`)
- Unit (Domain): je Prüfung B0–B20 mit `ofStatic`-Provider und TEST-Abzug-Parametern; Writer gegen
  Golden-Files (Bytes inkl. CRLF/Charset); Diff-Normalisierung.
- `ifas-test-data`: `TaxCodeTestdata`-Utility (Werte aus dem TEST-Abzug); Seeding via Repository.
- Integration: `PreisMeldungDiffJobTest` (Vorbild `IsinAnforderungDiffTest`; H2-Schnellpfad + ein
  Multi-DB-Fall für tax_code über H2/PG/Sybase): Submission→Execution→Inbox-Assertions
  (Alias-Auflösung, Wert-Normalisierung); **Idempotenz** (Job zweimal → identisch, kein
  PK-Verstoß); Diff ohne Altsystem-Antwort; Dispatch mit Antwort-ZIP-Layout.
- E2E mit den 4 Beispielfiles (`docs/Fondspreise/beispiele/`, 800/1271/363/2416 Zeilen):
  Statistik-/Urteils-/data.log-Assertions; selbst erzeugte Rückmeldung als Golden-File einfrieren;
  Diff-Selbstvergleich (eigenes ZIP als „Altsystem-Antwort" → 0 Abweichungen).

### AP10 — Doku + Tracker
- `docs/Technische Konzepte/ifas13-jobs.md`: „Fondspreise out of scope" korrigieren,
  `PreisMeldungDiffJob` ergänzen.
- Tracker (`mathias/plans/fondspreise/tracker.md`): Schnitt-1-Zeile → Detail-Plan verlinken,
  Status; neue offene Punkte: **echte Preis-Antwort-ZIPs anfordern** (idealerweise zu den 4
  Beispielfiles vom 12.05.2026, passend zu `fplausib.txt`), Property-Name
  `fondspreise.db-key` im Konzept nachziehen.

**Reihenfolge:** AP1 ∥ AP2 ∥ AP3 ∥ AP7 → AP4 → AP5 ∥ AP6 → AP8 → AP9 (E2E) → AP10.
Kritischer Pfad: AP3 → AP5 → AP8.

## Verifikation
- `mvn clean install -Pno-proxy -Pdev-build` (alle Module, MapStruct/Lombok-Prozessoren).
- Unit- und Integrationstests wie AP9; Multi-DB-Lauf ohne `-Pskip-*`-Profile mindestens einmal
  (tax_code auf Sybase).
- Manuell: `LocalH2OnlyIfasApplication` starten, unter `/ifas-uat` eines der Beispielfiles als ZIP
  über den Parallelbetrieb-Upload einspielen → Job läuft durch, Result-Bundle enthält
  Rückmeldungs-ZIP mit plausiblen Logs; Inbox-Zeilen per H2-Konsole prüfen.

## Risiken / offene Punkte
1. Keine echten Preis-Antwort-ZIPs — Byte-Verifikation des Diffs erst nach Anforderung möglich
   (blockiert nicht die Implementierung; Golden-Format aus Legacy-Quelltext + STM-ZIPs).
2. tax_code-Werte bisher nur aus dem TEST-Abzug — vor produktivem Parallelbetrieb gegen Prod
   verifizieren.
3. data.log-Statuscodes vollständig aus `M_INSERT.CPP` extrahieren (AP3), sonst difft data.log falsch.
4. Charset-Kante ISO-8859-1 vs. windows-1252 (0x80–0x9F meiden).
5. `BundleFileType`-Erweiterung berührt STM-Bundle-Code — bestehende Tests decken ab; prüfen, dass
   data.log nicht in STM-Recalc-Output-Bundles wandert.
6. Flyway-Nummern (V061–V063) beim Merge erneut prüfen.
7. Kein Web-UI in Schnitt 1 (generische Job-/WorkQueue-Sichten reichen); UI als Folgepaket.
