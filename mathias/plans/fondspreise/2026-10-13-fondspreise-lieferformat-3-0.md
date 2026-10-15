# Fondspreise — Lieferformat 3.0 im Preismeldungs-Eingang

Plan vom 2026-10-13, Stand 2026-10-14. Setzt die Regeln der „Beschreibung Format Preismeldung (inkl. LMT- &
Solvabilität), Version 3.0“ (`docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf`) um, die der produktive Eingang
heute nicht prüft — **ab sofort, ohne Stichtag** (User 2026-10-14: „we should only apply the new v3 implementation
starting now“).

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Spec 3.0** | das PDF oben, Version 3.0, „anwendbar für Meldungen ab dem [tbd]“ |
| **Eingang** | `domain.fondspreise.eingang`: `PreisMeldungEingangProcessor`, `PreisMeldungFileChecks`, `PreisMeldungLineValidations`, `Candidate` — der produktive Pfad, bisher Legacy-treu (`M_INSERT.CPP`) |
| **csv-schema-Pfad** | `domain.fondspreise.csv`: `CsvPreisMeldungen`, `CsvPreisMeldungValidations`, `CsvPreisMeldungMessageProcessor`, `PreisMeldungFields` — zweiter Parser auf `csv-schema`, produktiv von niemandem aufgerufen (nur `PreisMeldungCsvSchemaTest`, `PreisMeldungCsvTests`) |
| **Rückmeldung** | `error.log`, `info.log`, `oekbinfo.log`, `data.log`, `statistics.log` an den Lieferanten (`PreisMeldungRueckmeldungen`), Golden-File-Test gegen die Legacy-Logs vom September 2026 |
| **Inbox** | `preis_meldung_zeilen` (Kontext `job-system`, Postgres/H2), Entity `PreisMeldungZeile` in `ifas-persistence-infra` |
| **Parallelbetrieb** | `PreisMeldungDiffJob` schickt die Original-Lieferungen aus dem Legacy-MFT-Archiv durch den Eingang und vergleicht die Rückmeldungen |
| **Löschung** | Zeile mit Aktion `D`; die Spec verlangt die ursprünglich gelieferten Werte |
| **R1–R7** | die Regeln aus Abschnitt 1 |

## 1. Befund (2026-10-13/14) und Entscheidungen

Der Eingang kennt das 3.0-Layout bereits (zehn Spalten, `L1`–`L3`, Aktion `I`, Prozentkennzeichen, Stichtag) und prüft
genau das, was Legacy prüft. Legacy hat das Layout mit OEKBSD-76527 bekommen (Commits 2026-03-17 „LMT Werte sollen
ignoriert werden“, 2026-03-24, 2026-04-15; Kommentar „Ab 2026.06 LMT Kennzeichen“; `tax_code` `L1`–`L3` mit
`lieferung_ab` 2026-03-01) — ohne Datumsschalter, ohne Dateinamens-, Längen- oder Löschwert-Prüfung.

| # | Spec 3.0 | heute | Legacy | Treffer in heutigen Lieferungen¹ |
|---|---|---|---|---|
| R1 | 4.2: `L1`/`L3` ohne `0`-Wert | — | — | 0 (keine LMT-Zeile geliefert) |
| R2 | 4.2: Inaktivierung `I` nur mit Wert `0` | `I` nur bei `L2` (B13) | wie heute | 0 |
| R3 | 4.2/Anhang: `L2` mit `0` Tagen (außer `I`) verlangt den Stichtag | nur die Umkehrung (B19) | wie heute | 0 |
| R4 | Spalte 8 Periodizität, STRING(2) | nicht gespeichert | seit 2017 geleert (`M_INSERT.CPP:1189`) | `D` 44 290, leer 11 793, `W` 3, 1 verschobener Fondsname |
| R5 | Spalte 7 Fondsbezeichnung STRING(45) | ungeprüft, Inbox `varchar(100)` | `char(100)` | **695 von 56 087 Zeilen (1,2 %)**, Mai 2,7 %; db_gut 375, db_copri 225, db_rloo 60, db_pioneer 20, db_allianz 15; längster Name 64 |
| R6 | 4.1: Löschung mit den ursprünglich gelieferten Werten | `VersionChange.delete` nur über den Schlüssel | wie heute | 0 (kein `D` geliefert) |
| R7 | 1.: `Preis_<absender>_<YYYYMMDD>_<HHMMSS>.csv`, nur `-` und `_` | nirgends geprüft | `*.csv` im MFT-Script | **203 von 203 Dateien** (`20260901.csv`, `URA_…`, `Gutmann_…`, `AI_2026-07-02_…`) |

¹ Zählung 2026-10-14 über `docs/Fondspreise/beispiele`: September 2026 (199 Dateien in den Rückmeldungs-Zips, 56 087
Zeilen, 9 Lieferanten) und die vier Mai-Beispiele (4 850 Zeilen).

Entscheidungen (User):

- **Kein Stichtag, kein Gate** (2026-10-14). Alle Prüfregeln gelten ab dem Deploy. Folgen, bewusst in Kauf genommen:
  - R7 lehnt bis zur Umstellung der Lieferanten **jede** heutige Lieferung ab. Im Parallelbetrieb auf TEST heißt das:
    der `PreisMeldungDiffJob` sieht für jede Archivdatei „Datei abgelehnt“ statt eines Zeilenvergleichs, und Ledger,
    Sync und Sammellauf bekommen aus echten Lieferungen keine Daten mehr, bis die Lieferanten die 3.0-Namen verwenden
    (Kommunikation der Fachabteilung an die Lieferanten, Datum offen). Fixtures und Tests müssen 3.0-Namen tragen.
  - R5 verwirft ab sofort rund 1–3 % der Zeilen von fünf Lieferanten; im Diff als „Neusystem strenger“ sichtbar.
- **R4 nur speichern, nicht prüfen** (2026-10-14): Inbox-Spalte `periodizitaet` (Chunk 1, `77210f79c`), verbatim
  getrimmt, null wenn leer oder länger als 2 Zeichen; keine Regel, kein Default, keine Meldung. Nicht in die Version
  (Fondsattribut, kein Leser; erst mit Fehlmeldung J oder der Inbox-Aufräumregel neu bewerten).
- **R5: Zeile verwerfen** (`ERR_FONDSBEZ01`; 2026-10-13, nach der Zählung 2026-10-14 bestätigt durch „starting now“).
- **Schweregrade:** R1–R3, R5, R6 verwerfen die Zeile; R7 bricht die Datei ab (wie `ERR_FORMAT04`).
- **R6 im Eingang, nicht im Lauf:** nur der Eingang erzeugt die Rückmeldung; der Vergleich braucht die offene Version
  (Port ins Ledger) und die früheren Zeilen derselben Datei. Numerisch (`100` = `100.0`); keine offene Version und
  keine frühere `N`-Zeile → keine Prüfung (wie heute: der Lauf ignoriert das `D`).
- **csv-schema-Pfad löschen**, sobald R1–R3 im Eingang sind (Chunk 4).
- Dateiendung in R7 case-insensitiv (`.csv`/`.CSV`), der Rest exakt; `<absender>` darf `-` und `_` enthalten (die
  Lieferanten heißen `db_gut`, `db_union`; die Spec erlaubt beide Zeichen) und wird nicht gegen den Lieferanten
  geprüft. Für die MFT-Ankunft (Tracker) steht der Absender damit an zweiter Stelle statt „alles vor dem Datum“.

## 2. Die Regeln im Eingang

Reihenfolge wie `checkLine` (B-Nummern der Legacy-Analyse), neue Schritte mit R:

| Schritt | Prüfung | Code (neu) | Ziel / Schwere / `BugStat` |
|---|---|---|---|
| vor B1 (Datei) | R7 Dateiname: `^Preis_[A-Za-z0-9_-]+_\d{8}_\d{6}\.csv$`, Endung case-insensitiv | `ERR_FILENAME01` | `ERROR_LOG`, `FILE_ABORTED`, `BUG_FORMAT` |
| nach B12 | R5 Fondsbezeichnung länger als 45 | `ERR_FONDSBEZ01` | `ERROR_LOG`, `LINE_DROPPED`, `BUG_VALUE` |
| nach B13 | R2 `I` mit Wert ≠ `0` | `ERR_LMTINAKTIV01` | `LINE_DROPPED`, `BUG_LMT` |
| nach B16 (Wert geparst) | R1 `L1`/`L3` mit Wert `0` | `ERR_LMTWERT01` | `LINE_DROPPED`, `BUG_LMT` |
| nach B19 | R3 `L2`, Wert `0`, Aktion ≠ `I`, kein Stichtag | `ERR_LMTRUECKL2_1` | `LINE_DROPPED`, `BUG_LMT` |
| in `checkPreisRelation` | R6 Löschung: Wert ≠ Wert der offenen Version bzw. der letzten `N`-Zeile desselben Schlüssels in dieser Datei | `ERR_DELETE01` | `LINE_DROPPED`, `BUG_VALUE` |
| nach B12 | R4 Spalte 8 ungeprüft übernehmen: getrimmt, null wenn leer oder länger als 2 | — | — |

Texte deutsch/englisch im Legacy-Stil („…, Spalte %d: Zeile wird ignoriert.“ / „…: row has been ignored.“), die
Spaltennummer als Argument wie bei den Nachbarn. Keine neuen `BugStat`-Zähler: `statistics.log` bleibt stabil.
`data.log` erhält wie bisher den Text der Meldung, an der die Zeile gescheitert ist.

### Port für R6

Interface `OpenVersionProvider` im Package `eingang` (englische Rolle wie `PreisMeldungStammdatenProvider`, Fachbegriff
nur im Methodennamen): `Optional<BigDecimal> findOpenWert(String isin, LocalDate preisdatum, String waehrung, String
meldekategorie)`, statische Variante `OpenVersionProvider.NONE` für Tests. Konstruktorparameter von
`PreisMeldungEingangProcessor` neben dem Stammdaten-Provider. Der Eingang hält je Datei eine Map Schlüssel → Wert der letzten akzeptierten `N`-Zeile und fragt
den Port nur, wenn die Map nichts kennt. LMT-Zeilen und Aktion `I` haben keinen Schlüssel im Ledger — keine R6-Prüfung.

## 3. Tabellen — V083 (umgesetzt, Chunk 1)

`preis_meldung_zeilen.periodizitaet varchar(2) null` (gelieferte Periodizität des Fondshandels, verbatim; null wenn
nicht geliefert, nicht STRING(2), oder Zeile vor dieser Migration). Entity, Record, `Candidate.toZeileData()`,
Inbox-Schreib-/Lesepfad; der YAML-Export kennt die Inbox nicht.

## 4. Service, Fixtures, Doku

- `PreisMeldungEingangService`: Port `OpenVersionProvider` als Lambda über `PreisVersionRepository.findOpenVersion(...)` im
  Kontext `business-new-introduced` (lesend; der Eingang läuft in der Haupttransaktion des `PreisMeldungJob`, das
  Ledger wird dort nur enrollt, nicht geschrieben). Keine Property.
- Upload-Formular und MFT-Ankunft unverändert: R7 lehnt im Eingang ab und erzeugt die Rückmeldung, auf beiden Wegen gleich.
- **Fixtures auf 3.0-Namen:** alle Testlieferungen, die den Eingang durchlaufen, heißen künftig
  `Preis_<absender>_<YYYYMMDD>_<HHMMSS>.csv` — Golden-File-Test (`URA_20260831_104207.csv` → `Preis_URA_20260831_104207.csv`,
  `Gutmann_20260901133037.csv` → `Preis_Gutmann_20260901_133037.csv`; die erwarteten Logs und der Zip-Name tragen den
  Dateinamen, Erwartungen entsprechend anpassen — der Test pinnt das Log-Format, nicht den Namen), `PreisMeldungJobTest`,
  `PreisMeldungDiffJobTest`, Smoke-Test-Daten. Ein Fixture mit altem Namen bleibt als Negativfall.
- Doku: `ifas13-jobs.md` Abschnitt `PreisMeldungJob` (die sechs Regeln, Codes, Folgen für den Parallelbetrieb),
  `jobs-catalog.md` 5.6/5.7 je ein Satz; `docs/Fondspreise/fondspreise-legacy-analyse.md` 2.8 letzter Absatz (R1–R3
  jetzt im Eingang, csv-schema-Pfad gelöscht); Tracker-Todo „MFT-Ankunft“ um den Absender an zweiter Stelle ergänzen.

## 5. Chunks

Jeder Chunk ein Commit auf `master`, Opus-Subagent mit eigenem Brief; Maven immer `-Pno-proxy`, Web-Module
`-Pdev-build`, Integrationstests nach `mvn -q install -Pno-proxy -DskipTests -pl ifas-testing/ifas-integration-tests -am`.
Chunk 2 ändert das Verhalten des Eingangs auf allen Wegen — Web-Upload, Diff-Job, später MFT.

### Chunk 1 — Persistenz (umgesetzt, `77210f79c`)

V083 beide Bäume, Entity, Record, `Candidate.toZeileData()` (null), Inbox-Schreib-/Lesepfad, Schema-Datei, Tests.

### Chunk 2 — Domäne: die sechs Regeln, Spalte 8 speichern

- `OpenVersionProvider`, die sechs Codes in `PreisMeldungMsgCode`, R1–R3 und R5–R7 in `PreisMeldungFileChecks` /
  `PreisMeldungLineValidations` / `checkPreisRelation`; Spalte 8 durch `Candidate` bis `PreisMeldungZeileData`.
- `PreisMeldungEingangTest`: bestehende Fälle auf 3.0-Dateinamen umstellen (sonst scheitern sie an R7 statt an dem, was
  sie prüfen); neu je Regel ein positiver und ein negativer Fall, dazu: `I` mit `0` akzeptiert; `L2` mit `0` und
  Stichtag akzeptiert; `L2` mit `0`, ohne Stichtag, Aktion `I` akzeptiert; Periodizität `M2` gespeichert, leer → null,
  `XYZ` → null ohne Meldung; Fondsbezeichnung mit genau 45 Zeichen akzeptiert; `D` mit `100,0` gegen offene `100`
  akzeptiert; `D` ohne offene Version und ohne `N` in der Datei passiert; `N` dann `D` mit anderem Wert in einer Datei
  → `ERR_DELETE01`; `Preis_URA_20260831_104207.CSV` akzeptiert, `URA_20260831_104207.csv` → `ERR_FILENAME01` mit
  Rückmeldung „abgelehnt“.
- `PreisMeldungRueckmeldungWriterTest`: je neuer Code eine Zeile in `error.log` im erwarteten Format.
  Golden-File-Test: Fixtures umbenannt, Erwartungen an Zip-Name/Log-Zeilen mit dem Namen nachgezogen, sonst unverändert.
- Die zwei Testklassen des csv-schema-Pfads bleiben bis Chunk 4 unangetastet.

### Chunk 3 — Service, Fixtures, Doku

- Abschnitt 4 komplett. `PreisMeldungJobTest`: alte Dateinamen abgelehnt (Rückmeldung-ZIP mit `ERR_FILENAME01`, Job
  `COMPLETED` mit Urteil abgelehnt); R6 über das Ledger: Lieferung 1 `N` 100, Lieferung 2 `D` 101 → Zeile verworfen,
  Version bleibt offen; `D` 100 → Version beendet. `PreisMeldungDiffJobTest`: Fixtures umbenannt.
- Docs laut Abschnitt 4; Plan-Nachtrag und Tracker macht Fable.

### Chunk 4 — csv-schema-Pfad entfernen

- `domain.fondspreise.csv` (vier Klassen) und `PreisMeldungCsvSchemaTest`, `PreisMeldungCsvTests` löschen; Enums
  `Meldekategorie`, `PreisAktion` bleiben. Abhängigkeit `csv-schema` im POM von `ifas-domain-fondspreise` entfernen,
  wenn das Modul ohne sie kompiliert (`CsvTypeConversions` kommt aus `ifas-domain-core`).
- Legacy-Analyse 2.8 Absatz anpassen; `mvn -q install` des Moduls plus `PreisMeldungEingangTest`.

## 6. Verifikation

- Domäne: `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-fondspreise` (Eingang, Rückmeldung, Golden File).
- Integration: `PreisMeldungJobTest`, `PreisMeldungDiffJobTest`, `PreisVersionJobTest`, `PreisVersionRepositoryTest`,
  beide DBs.
- End to end in `LocalH2OnlyIfasApplication`: `URA_20260831_104207.csv` → Rückmeldung abgelehnt (`ERR_FILENAME01`);
  dieselbe Datei als `Preis_URA_20260831_104207.csv` → 6 Zeilen akzeptiert; Datei mit `…;L1;0;N;;;J;;`, `…;L2;0;I;;;;;`
  (akzeptiert), `…;L2;5;I;;;;;`, `…;L2;0;;;;;;` (ohne Stichtag), Fondsname mit 50 Zeichen → `error.log` zeigt je Zeile
  den erwarteten Code, `statistics.log` zählt sie unter LMT/Value; zweite Datei mit `D` und anderem Wert →
  `ERR_DELETE01`, Version bleibt offen.
- Auf TEST nach dem Deploy: der Diff-Job meldet für jede Archivdatei `ERR_FILENAME01` — erwartet, bis die Lieferanten
  umstellen.

## 7. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **Lieferanten auf 3.0-Namen** | Fachabteilung informiert die Lieferanten; bis dahin lehnt IFAS-NEU alles ab, Legacy nicht |
| **LMT persistieren/weitergeben** | Klärung G; der Eingang speichert weiter nur Inbox-Felder |
| **MFT-Ankunft für Preismeldungen** | Tracker; nutzt den Absender an zweiter Stelle des Namens |
| **Format 1 / `.txt`** (`AllowOldPreisFormat`, `AllowTxtExt4PreisFile`) | Tracker, mit 3.0 obsolet, wenn die Fachabteilung zustimmt |
| **`D` ohne offene Version** | bleibt stillschweigend wirkungslos wie heute |
| **Periodizität in der Version** | nein; neu bewerten mit Fehlmeldung J oder der Inbox-Aufräumregel |

## 8. Nachträge und Stand

- **Nachtrag 2026-10-14 (Chunk 1 umgesetzt, Commit `77210f79c`, gepusht):** V083 beide Bäume, `PreisMeldungZeile.periodizitaet`,
  `PreisMeldungZeileData.periodizitaet` (nach `fondsbezeichnung`), `Candidate.toZeileData()` übergibt vorerst null,
  `PreisMeldungZeilen`/`PreisDataConversions` tragen den Wert durch; sechs Test-Aufrufer des Records um ein `null`
  ergänzt; `postgres-db-schema.sql` um die eine Zeile. Tests: Domäne 289 unverändert grün, Integration 90 (H2 +
  Postgres, `PreisMeldungZeileRepositoryTest` 6 × 2 mit zwei neuen Fällen), web-ui kompiliert, drei web-ui-Tests 11
  grün. Zwischenentscheidungen am selben Tag: R4 erst gestrichen, dann „speichern, nicht prüfen“; Gate erst geplant
  (Stichtag-Property), dann nach der Zählung der Treffer gestrichen — „ab sofort“. Nebenbefund: `DatabaseSchemaTool`
  erzeugt heute drei fremde Hunks in `postgres-db-schema.sql` (`source_type`-Check doppelt geklammert,
  `wkn_join`-Spalten und -FKs vertauscht; die Datei in HEAD stammt aus dem Spring-Boot-4-Merge `4db0ba67c`), der Agent
  hat die Datei von Hand auf die eine Zeile beschränkt — bei der nächsten Regenerierung in einem eigenen Commit
  bereinigen. Der Postgres-Testcontainer läuft mit `postgres:18`, nicht 15.
- **Für Chunk 2:** `Candidate` braucht Feld und Konstruktorparameter aus Spalte 8 (getrimmt, null wenn leer oder
  länger als 2, sonst verbatim), `toZeileData()` an Position 9; Javadoc am Record-Feld nachziehen.
- **Nachtrag 2026-10-14 (Chunk 2 umgesetzt, Commit `e9db4cb0c`, gepusht):** `OpenVersionProvider` (+ `NONE`), sechs Codes als
  eigener Block „Lieferformat 3.0“ in `PreisMeldungMsgCode`, R7 als erste Prüfung in `checkFileFormat`, R5 nach B12,
  R2 direkt nach dem Parsen in B16 (Kommentar erklärt die Stelle), R1 nach B16, R3 nach B19, R6 als eigene Methode
  `checkDeletions(candidates, provider)` neben `checkPreisRelation` (gleiche Stelle, ein von der Preisrelation
  verworfenes `N` ist keine Referenz; übersprungen wird alles ohne Ledger-Schlüssel: LMT, `I`, Codes ohne
  `Meldekategorie`), Spalte 8 verbatim durch `Candidate` (neu auch `wertRaw` für den Meldungstext).
  `PreisMeldungEingangService` übergibt `OpenVersionProvider.NONE`. Fixtures: `PreisVersionJobTestSupport.FILENAME` →
  `Preis_testbank_20260917_080000.csv`, `PreisMeldungDiffJobTest` → `Preis_testbank_20260512_120000.csv`; Golden-File-Test
  speist `Preis_URA_20260831_104207.csv`/`Preis_Gutmann_20260901_133037.csv` und ersetzt beim Laden der unveränderten
  Legacy-Logs den alten Namen (alle vier Logs tragen ihn: `inputfile`-Zeile, `### delivery-bug … file:`).
  Tests: Domäne 314 → mit Fables Nachbesserung 315 (`PreisMeldungEingangTest` 64, Writer 9, Golden 2); Integration
  146 grün (H2 + Postgres; vorher 36 Fehlschläge durch R7, alle Fixture-Namen), Zusatzlauf 129 grün; web-ui 30
  unverändert (mocken den Eingang). **Nachbesserung Fable:** das Muster ließ `_` im Absender nicht zu
  (`Preis_db_gut_…` wäre abgelehnt worden) → `[A-Za-z0-9_-]+`, Test `givenSenderWithUnderscore…`. Statistik-Labels:
  die drei neuen LMT-Codes zählen unter „LMT percentage code“ (BUG_LMT), FONDSBEZ01/DELETE01 unter BUG_VALUE,
  FILENAME01 unter BUG_FORMAT — keine neuen Zähler, wie geplant.
- **Für Chunk 3:** `OpenVersionProvider.NONE` im Service durch die Lambda über `PreisVersionRepository.findOpenVersion`
  ersetzen (Port bekommt den kanonischen Code, wird nur für `D`-Zeilen ohne frühere `N`-Zeile derselben Datei gerufen);
  `PreisMeldungDiffJobTest.givenALoeschlieferung…` muss mit verdrahtetem Ledger weiter passen (nichts offen);
  Negativfall alter Dateiname in `PreisMeldungJobTest`; Doku; Smoke-Test-Daten im Scratchpad umbenennen.

## Quellen

- `docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf` (3.0), `docs/Fondspreise/Preismeldung_ISINs_2025.pdf` (2.0, Diff: LMT, Spalten 9/10, Aktion `I`, Dateiname)
- `docs/Fondspreise/beispiele/` (Mai-Beispiele, `testdaten_september/Meldung/*/…zip`) — Zählung Abschnitt 1
- `ifas-domain/ifas-domain-fondspreise/src/main/java/at/oekb/ifas/domain/fondspreise/eingang/*` (Processor, FileChecks `MIN_COLUMNS 5`/`MAX_COLUMNS_FORMAT3 17`, LineValidations B1–B19, Candidate, ZeileData),
  `meldung/PreisMeldungMsgCode.java` (Konstruktor: LogTarget, Schwere, BugStat, Texte DE/EN), `meldung/PreisMeldungBugStat.java`,
  `verarbeitung/PreisMeldungZeilenFilter.java` (LMT und `I` ohne Schlüssel), `verarbeitung/PreisVersionCalculator.java` (`D` über den Schlüssel)
- `csv/CsvPreisMeldungValidations.java` (R1–R3 heute nur dort), Nutzer: nur zwei Testklassen
- `ifas-services/…/service/fondspreise/PreisMeldungEingangService.java`, `PreisMeldungJobSubmissionService.java`, `PreisMeldungDiffJob*`
- `ifas-database/…/postgres15/V075__preis_versions.sql` (Inbox-DDL), `V083__preis_meldung_zeilen_periodizitaet.sql`, `PreisVersionRepository.findOpenVersion`
- Legacy: `M_INSERT.CPP:1142, 1189-1226, 2040-2056, 3538-3700`, `c_param.cpp:56, 434-439`; Legacy-Git `eb80f34` (2026-03-17), `730bf23` (2026-03-24), `f5d7f8e` (2026-04-15); Legacy-Analyse 2.6, 2.8, 8.4
- Tracker-Todo „Lieferformat 3.0 vollständig umsetzen“ (2026-10-13)
