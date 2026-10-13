# Fondspreise — Lieferformat 3.0 im Preismeldungs-Eingang

Plan vom 2026-10-13. Setzt die Regeln der „Beschreibung Format Preismeldung (inkl. LMT- & Solvabilität), Version 3.0“
(`docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf`) um, die der produktive Eingang heute nicht prüft, hinter
einem Stichtag, damit der Parallelbetrieb bis zum Inkrafttreten unverändert gegen Legacy läuft. Entscheidung User
2026-10-13: „we need to follow 3.0 spec“.

## 0. Glossar

| Begriff | Bedeutung |
|---|---|
| **Spec 3.0** | das PDF oben, Version 3.0, „anwendbar für Meldungen ab dem [tbd]“ |
| **Eingang** | `domain.fondspreise.eingang`: `PreisMeldungEingangProcessor`, `PreisMeldungFileChecks`, `PreisMeldungLineValidations`, `Candidate` — der produktive Pfad, Legacy-treu (`M_INSERT.CPP`) |
| **csv-schema-Pfad** | `domain.fondspreise.csv`: `CsvPreisMeldungen`, `CsvPreisMeldungValidations`, `CsvPreisMeldungMessageProcessor`, `PreisMeldungFields` — zweiter Parser auf `csv-schema`, produktiv von niemandem aufgerufen (nur `PreisMeldungCsvSchemaTest`, `PreisMeldungCsvTests`) |
| **Rückmeldung** | `error.log`, `info.log`, `oekbinfo.log`, `data.log`, `statistics.log` an den Lieferanten (`PreisMeldungRueckmeldungen`), Golden-File-Test gegen die Legacy-Logs vom September 2026 |
| **Inbox** | `preis_meldung_zeilen` (Kontext `job-system`, Postgres/H2), Entity `PreisMeldungZeile` in `ifas-persistence-infra` |
| **Stichtag 3.0** | `ifas.fondspreise.preismeldung.format3-ab` (`LocalDate`, Default leer = Regeln aus); gilt für Lieferungen, deren Verarbeitungsbeginn an oder nach dem Tag liegt |
| **Löschung** | Zeile mit Aktion `D`; die Spec verlangt die ursprünglich gelieferten Werte |

## 1. Befund (2026-10-13) und Entscheidungen

Der Eingang kennt das 3.0-Layout bereits (zehn Spalten, `L1`–`L3`, Aktion `I`, Prozentkennzeichen, Stichtag) und
prüft genau das, was Legacy prüft (Legacy-Analyse 2.6/2.8). Nicht geprüft, in der Spec aber verbindlich:

| # | Spec 3.0 | heute | Legacy |
|---|---|---|---|
| R1 | 4.2: `L1`/`L3` ohne `0`-Wert | — | — |
| R2 | 4.2: Inaktivierung `I` nur mit Wert `0` | `I` nur bei `L2` (B13) | wie heute |
| R3 | 4.2/Anhang: `L2` mit `0` Tagen (außer `I`) verlangt den Stichtag | nur die Umkehrung (Stichtag nur bei `0` Tagen, B19) | wie heute |
| R4 | Spalte 8 Periodizität: `D` (Default), `W`, `M2`, `M`, `Q`, `S`, `A`; Pflicht wenn nicht `D` | Spalte ignoriert, nicht gespeichert | seit 2017 ersatzlos geleert (`ERR_INTERVALL01/02` tot) |
| R5 | Spalte 7 Fondsbezeichnung STRING(45) | ungeprüft, Inbox `varchar(100)` | `char(100)` |
| R6 | 4.1: Löschungen müssen die ursprünglich gelieferten Werte beinhalten | `VersionChange.delete` beendet die offene Version über den Schlüssel | wie heute |
| R7 | 1.: Dateiname `Preis_<absender>_<YYYYMMDD>_<HHMMSS>.csv`, nur `-` und `_` als Sonderzeichen | nirgends geprüft (Upload-Formular wählt den Lieferanten, MFT-Ankunft auskommentiert) | `preis_ins.e -L<lief> -E<file>`: Name egal |
| — | 3.: Prozentangaben als Prozentzahl | nicht prüfbar | — |
| — | 5.: Datum nicht in der Zukunft; Nachkommastellen; Währung/ISIN-Länge | geprüft (B6 mit `tax_code.future`; `max_nk`; Tabellen) | gleich |

R1–R3 stehen bereits im csv-schema-Pfad (`CsvPreisMeldungValidations`), den produktiv niemand aufruft.

Entscheidungen (User 2026-10-13):

- **Alle sieben Regeln hinter dem Stichtag 3.0.** Ohne Datum verhält sich der Eingang wie heute — die
  Golden-File-Tests und der Parallelbetriebs-Diff bleiben sauber; die Fixtures heißen `URA_20260831_104207.csv`
  und `Gutmann_20260901133037.csv`, R7 würde heute jede Lieferung ablehnen. Das Datum liefert die Fachabteilung
  („anwendbar ab“ ist im PDF offen); gesetzt wird es je Stage in den Properties. Nach dem Stichtag sind neue
  Ablehnungen im Diff „Neusystem strenger“ — gewollt.
- **Schweregrade wie Legacy, wo Legacy eine Regel kannte:** R4 leert nur das Feld (`ERR_INTERVALL01`, Wortlaut aus
  `c_param.cpp:434-439`); R1–R3, R6 verwerfen die Zeile; R7 bricht die Datei ab (wie `ERR_FORMAT04`).
- **R5: Zeile verwerfen** (`ERR_FONDSBEZ01`; entschieden User 2026-10-13), weil die Spec Abweichungen als
  Verarbeitungshindernis erklärt. Kürzen auf 45 mit `INFO` war die Alternative und ist verworfen.
- **R6 im Eingang, nicht im Lauf:** nur der Eingang erzeugt die Rückmeldung an den Lieferanten; der Vergleich
  braucht die offene Version (Port ins Ledger) und die früheren Zeilen derselben Datei. Numerischer Vergleich
  (`100` = `100.0`), keine offene Version und keine frühere `N`-Zeile → keine Prüfung (Verhalten wie heute: der
  Lauf ignoriert das `D`).
- **R4 wird gespeichert** (Inbox-Spalte `periodizitaet`, Default `D` wie Aktion `N`), sonst nicht verwendet — kein
  Abnehmer bekannt; Klärung G (LMT) unberührt.
- **csv-schema-Pfad löschen**, sobald R1–R3 im Eingang sind (Chunk 4). Zwei Parser für ein Format sind ein
  Wartungsfehler; die Dateityperkennung (`IfasCsvMeldeFileTypes.PREIS_MELDEFILE`) hängt nicht daran.
- Dateiendung in R7 case-insensitiv (`.csv`/`.CSV`), der Rest exakt; `<absender>` wird nicht gegen den
  Lieferanten geprüft (die Spec verlangt nur das Muster). Für die MFT-Ankunft (Tracker) steht der Absender damit
  an zweiter Stelle statt „alles vor dem Datum“.

## 2. Die Regeln im Eingang

Reihenfolge wie `checkLine` (B-Nummern der Legacy-Analyse), neue Schritte mit R:

| Schritt | Prüfung | Code (neu) | Ziel / Schwere / `BugStat` |
|---|---|---|---|
| vor B1 (Datei) | R7 Dateiname: `^Preis_[A-Za-z0-9-]+_\d{8}_\d{6}\.csv$`, Endung case-insensitiv | `ERR_FILENAME01` | `ERROR_LOG`, `DATEI_ABGEBROCHEN`, `BUG_FORMAT` |
| nach B13 | R2 `I` mit Wert ≠ `0` | `ERR_LMTINAKTIV01` | `ERROR_LOG`, `ZEILE_VERWORFEN`, `BUG_LMT` |
| nach B16 (Wert geparst) | R1 `L1`/`L3` mit Wert `0` | `ERR_LMTWERT01` | `ZEILE_VERWORFEN`, `BUG_LMT` |
| nach B19 | R3 `L2`, Wert `0`, Aktion ≠ `I`, kein Stichtag | `ERR_LMTRUECKL2_1` | `ZEILE_VERWORFEN`, `BUG_LMT` |
| neu B17' | R4 Periodizität leer → `D`; sonst einer von `D W M2 M Q S A` (Uppercase wie Legacy), sonst Feld leeren → `D` | `ERR_INTERVALL01` | `ERROR_LOG`, `FELD_GELEERT`, `BUG_INTERVAL` |
| neu nach B12 | R5 Fondsbezeichnung länger als 45 | `ERR_FONDSBEZ01` | `ZEILE_VERWORFEN`, `BUG_VALUE` |
| in `checkPreisRelation` | R6 Löschung: Wert ≠ Wert der offenen Version bzw. der letzten `N`-Zeile desselben Schlüssels in dieser Datei | `ERR_DELETE01` | `ZEILE_VERWORFEN`, `BUG_VALUE` |

Texte deutsch/englisch im Legacy-Stil („…, Spalte %d: Zeile wird ignoriert.“ / „…: row has been ignored.“), die
Spaltennummer als Argument wie bei den Nachbarn. Keine neuen `BugStat`-Zähler: `statistics.log` bleibt stabil.

`data.log` erhält wie bisher den Text der Meldung, an der die Zeile gescheitert ist; ein geleertes Feld (R4) lässt
die Zeile „inserted“.

### Gate

Ein Record `EingangRegeln(boolean format3)` im Package `eingang`, Parameter von
`PreisMeldungEingangProcessor.process(content, filename, today, regeln)`. `format3 = false` → kein R-Schritt läuft,
die Periodizität wird trotzdem gespeichert (leer → `D`), der Port für R6 wird nicht befragt. So bleibt
`PreisMeldungEingangTest` für den Legacy-Fall unverändert und bekommt je Regel einen Fall mit `format3 = true`.

### Port für R6

Interface `OffeneVersionen` im Package `eingang`:
`Optional<BigDecimal> findOffenenWert(String isin, LocalDate preisdatum, String waehrung, String meldekategorie)`.
Statische Variante `OffeneVersionen.NONE` für Tests und den Legacy-Fall. Der Eingang hält je Datei eine Map
Schlüssel → Wert der letzten akzeptierten `N`-Zeile und fragt den Port nur, wenn die Map nichts kennt. LMT-Zeilen
und Aktion `I` haben keinen Schlüssel im Ledger — für sie keine R6-Prüfung.

## 3. Tabellen — V083 (ein File je Baum, Sybase-Platzhalter)

`preis_meldung_zeilen` + `periodizitaet varchar(2) null` (gelieferte oder per Default gesetzte Periodizität des
Fondshandels; null nur für Zeilen vor dieser Migration). Entity `PreisMeldungZeile`, Record `PreisMeldungZeileData`,
`Candidate.toZeileData()`. YAML-Export/-Import der Inbox prüfen (`ifas-data-import-export`): trägt er die Zeilen,
bekommt er das Feld; `postgres-db-schema.sql` neu erzeugen.

## 4. Service und Konfiguration

- `FondspreiseProperties.Preismeldung preismeldung` mit `@Nullable LocalDate format3Ab` → Property
  `ifas.fondspreise.preismeldung.format3-ab`, Default leer. Keine Zeile in den Properties-Files (Stage-Konfiguration
  setzt sie, wenn die Fachabteilung das Datum nennt).
- `PreisMeldungEingangService.process(lieferfile, lieferant, verarbeitungsbeginn)`: `format3 = format3Ab != null &&
  !verarbeitungsbeginn.toLocalDate().isBefore(format3Ab)`; Port `OffeneVersionen` als Lambda über
  `PreisVersionRepository.findOpenVersion(...)` im Kontext `business-new-introduced` (lesend; der Eingang läuft in
  der Haupttransaktion des `PreisMeldungJob`, das Ledger wird dort nur enrollt, nicht geschrieben).
- Upload-Formular und MFT-Ankunft unverändert: R7 lehnt im Eingang ab und erzeugt die Rückmeldung, auf beiden
  Wegen gleich.
- Doku: `ifas13-jobs.md` Abschnitt `PreisMeldungJob` (Stichtag 3.0, die sieben Regeln, Codes), `jobs-catalog.md`
  5.7 ein Satz; `docs/Fondspreise/fondspreise-legacy-analyse.md` 2.8 letzter Absatz (R1–R3 jetzt im Eingang, Pfad
  gelöscht).

## 5. Chunks

Jeder Chunk ein Commit auf `master`, Opus-Subagent mit eigenem Brief; Maven immer `-Pno-proxy`, Web-Module
`-Pdev-build`, Integrationstests nach `mvn -q install -Pno-proxy -DskipTests -pl ifas-testing/ifas-integration-tests -am`.
Verhalten des laufenden Systems ändert sich erst mit gesetztem Stichtag (Chunk 3), nie durch Chunk 1 oder 2.

### Chunk 1 — Persistenz

- V083 beide Bäume (`V083__preis_meldung_zeilen_periodizitaet.sql`, Sybase-Platzhalter im Wortlaut von V080),
  Entity, Record, Builder/Konstruktor, Export/Import falls betroffen, Schema-Datei.
- Tests: Inbox-Repository-Test (Feld rund), Import/Export-Kompatibilitätstest falls die Inbox exportiert wird.
  Beide DBs.

### Chunk 2 — Domäne: die Regeln hinter dem Gate

- `EingangRegeln`, `OffeneVersionen`, die sieben Codes in `PreisMeldungMsgCode`, R1–R7 in `PreisMeldungFileChecks`
  / `PreisMeldungLineValidations` / `checkPreisRelation`, Periodizität durch `Candidate` bis `PreisMeldungZeileData`.
- `PreisMeldungEingangTest`: bestehende Fälle mit `format3 = false` unverändert grün; neu je Regel ein positiver und
  ein negativer Fall mit `format3 = true`, dazu: `I` mit `0` akzeptiert; `L2` mit `0` und Stichtag akzeptiert; `L2`
  mit `0`, ohne Stichtag, Aktion `I` akzeptiert; Periodizität `m2` → `M2`; leere Periodizität → `D`; Fondsbezeichnung
  mit genau 45 Zeichen akzeptiert; `D` mit `100,0` gegen offene `100` akzeptiert; `D` ohne offene Version und ohne
  `N` in der Datei passiert; `N` dann `D` mit anderem Wert in einer Datei → `ERR_DELETE01`; Dateiname `Preis_URA_20260831_104207.CSV`
  akzeptiert, `URA_20260831_104207.csv` → `ERR_FILENAME01` mit Rückmeldung „abgelehnt“.
- `PreisMeldungRueckmeldungWriterTest`: je neuer Code eine Zeile in `error.log` im erwarteten Format;
  Golden-File-Test unverändert (Gate aus).
- Keine Verhaltensänderung: `PreisMeldungEingangService` übergibt noch `EingangRegeln` mit `format3 = false` und
  `OffeneVersionen.NONE` — oder der Prozessor behält bis Chunk 3 einen Default-Konstruktor; im Chunk entscheiden,
  was weniger Übergangscode ist.

### Chunk 3 — Service, Property, Doku

- Abschnitt 4 komplett. `PreisMeldungJobTest`: ein Fall mit gesetztem `format3Ab` am Bean (Properties-Files nicht
  anfassen): alte Dateinamen abgelehnt, Rückmeldung-ZIP mit `ERR_FILENAME01`, Job `COMPLETED` mit Urteil abgelehnt;
  ein Fall R6 über das Ledger: Lieferung 1 `N` 100, Lieferung 2 `D` 101 → Zeile verworfen, Version bleibt offen;
  `D` 100 → Version beendet. Datum vor dem Stichtag → wie heute.
- Docs laut Abschnitt 4; Plan-Nachtrag und Tracker macht Fable.

### Chunk 4 — csv-schema-Pfad entfernen

- `domain.fondspreise.csv` (vier Klassen) und `PreisMeldungCsvSchemaTest`, `PreisMeldungCsvTests` löschen; Enums
  `Meldekategorie`, `PreisAktion` bleiben (werden vom Eingang und der Verarbeitung genutzt). Abhängigkeit
  `csv-schema` im POM von `ifas-domain-fondspreise` entfernen, wenn das Modul ohne sie kompiliert
  (`CsvTypeConversions` kommt aus `ifas-domain-core`).
- Legacy-Analyse 2.8 Absatz anpassen; `mvn -q install` des Moduls plus `PreisMeldungEingangTest`.

## 6. Verifikation

- Domäne: `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-fondspreise` (Eingang, Rückmeldung, Golden File).
- Integration: `PreisMeldungJobTest`, `PreisVersionJobTest`, `PreisMeldungDiffJobTest`, `PreisVersionRepositoryTest`,
  Import/Export-Tests, beide DBs.
- End to end in `LocalH2OnlyIfasApplication` mit `-Difas.fondspreise.preismeldung.format3-ab=2026-01-01`:
  `URA_20260831_104207.csv` → Rückmeldung abgelehnt (`ERR_FILENAME01`); dieselbe Datei als
  `Preis_URA_20260831_104207.csv` → 6 Zeilen akzeptiert; Datei mit `…;L1;0;N;;;J;;`, `…;L2;0;I;;;;;` (akzeptiert),
  `…;L2;5;I;;;;;`, `…;L2;0;;;;;;` (ohne Stichtag), Periodizität `x`, Fondsname mit 50 Zeichen → `error.log`
  zeigt je Zeile den erwarteten Code, `statistics.log` zählt sie unter LMT/Intervall/Value; zweite Datei mit `D`
  und anderem Wert → `ERR_DELETE01`, Version bleibt offen. Ohne die Property: alles wie beim Smoke-Test vom
  2026-10-13 (Sammellauf-Plan Abschnitt 9).

## 7. Später — bewusst nicht in diesem Plan

| Thema | Stand |
|---|---|
| **Stichtag 3.0 je Stage setzen** | wenn die Fachabteilung das Datum nennt; bis dahin Property leer |
| **LMT persistieren/weitergeben** | Klärung G; der Eingang speichert weiter nur Inbox-Felder |
| **MFT-Ankunft für Preismeldungen** | Tracker; nutzt den Absender an zweiter Stelle des Namens |
| **Format 1 / `.txt`** (`AllowOldPreisFormat`, `AllowTxtExt4PreisFile`) | Tracker, mit 3.0 obsolet, wenn die Fachabteilung zustimmt |
| **`D` ohne offene Version** | bleibt stillschweigend wirkungslos wie heute; eine Meldung dafür wäre ein eigener Beschluss |

## Quellen

- `docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf` (3.0), `docs/Fondspreise/Preismeldung_ISINs_2025.pdf` (2.0, Diff: LMT, Spalten 9/10, Aktion `I`, Dateiname)
- `ifas-domain/ifas-domain-fondspreise/src/main/java/at/oekb/ifas/domain/fondspreise/eingang/*` (Processor, FileChecks `MIN_COLUMNS 5`/`MAX_COLUMNS_FORMAT3 17`, LineValidations B1–B19, Candidate, ZeileData),
  `meldung/PreisMeldungMsgCode.java` (Konstruktor: LogZiel, Schwere, BugStat, Texte DE/EN), `meldung/PreisMeldungBugStat.java`,
  `verarbeitung/PreisMeldungZeilenFilter.java` (LMT und `I` ohne Schlüssel), `verarbeitung/PreisVersionCalculator.java` (`D` über den Schlüssel)
- `csv/CsvPreisMeldungValidations.java` (R1–R3 heute nur dort), Nutzer: nur zwei Testklassen
- `ifas-services/…/service/fondspreise/PreisMeldungEingangService.java`, `PreisMeldungJobSubmissionService.java`, `FondspreiseProperties.java`
- `ifas-database/…/postgres15/V075__preis_versions.sql` (Inbox-DDL), `PreisVersionRepository.findOpenVersion`
- Legacy: `M_INSERT.CPP:1205-1226, 2049-2056, 3480, 3510`, `c_param.cpp:434-439` (`ERR_INTERVALL01/02`), Legacy-Analyse 2.6, 2.8, 8.4
- Tracker-Todo „Lieferformat 3.0 vollständig umsetzen“ (2026-10-13)
