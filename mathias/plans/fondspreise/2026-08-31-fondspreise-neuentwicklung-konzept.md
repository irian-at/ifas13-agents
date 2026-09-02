# Fondspreise — Konzept für die Neuentwicklung in IFAS13

## Context

Die Ist-Analyse des Altsystems liegt vor: `docs/Fondspreise/fondspreise-legacy-analyse.md`.
Sie beschreibt vier Stufen — Sammlung (`preis_ins.e`) → Plausibilität (`preis_dld.e -P`) →
Filegenerierung (`preis_dld.e -fPREISE`) → Einspielung (`preise.e -p0`) — mit der Sammeltabelle
`kurs..tmp_if_kurs` als Nahtstelle.

Dieses Dokument hält das **Zielkonzept** fest. Vier Quellen:

1. die Diskussion vom **2026-08-31** (Grundentscheidungen 1–10),
2. der fachliche Input von **Markus vom 2026-09-01** (9 Punkte, Entscheidungen 11–15),
3. die Nachfragen vom **2026-09-01** zum Jobschnitt, die den Zuschnitt der Jobs und das
   Statusmodell noch einmal geändert haben,
4. das Review gegen die Codebase vom **2026-09-02** (Runde 7): DB-Topologie, Vorgaben zum
   Parallelbetrieb, zwei technische Korrekturen am Guard.

Zwei Leitgedanken:

- **Kein Nachbau der tmp-Tabellen.** Der Sammelzustand liegt in den Jobs, nicht in einer geteilten
  veränderlichen Tabelle.
- **Was pro Lieferung geht, geht pro Lieferung.** Gesammelt wird nur, was gesammelt werden muss —
  die Reports an die Bezieher und die Fehlmeldung.

Vorhanden in IFAS13 ist bisher nur das Lieferformat (`ifas-domain-fondspreise`:
`PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml`, `Meldekategorie`, `PreisAktion`,
`CsvPreismeldungValidations`, `CsvPreismeldungen.loadCsvFile`).
`PreisMeldungDiffJobSubmissionService` ist ein Stub. Keine Persistenz, keine Plausibilität, keine
Filegenerierung, keine Verteilung.

Passend vorgefunden und wiederverwendbar:

| Baustein | Ort | Nutzen |
|---|---|---|
| `AbstractJobWorkQueueHandler` mit konfigurierbarem `completedStatus` | `service/job/` | Stufenweise Statusübergänge, ohne den Basis-Handler zu umgehen |
| `Job.keyDate` + `Job.dailyRunNumber` mit Unique-Index `ux_jobs_type_key_date_daily_run_number` | `persistence/infra/job/Job.java` | mehrere Läufe pro Tag sind **geerbt**, nicht nachzubauen (STM fährt schon 3) |
| `ScheduledTask` + `triggerIfEnabledAndStichtagIsWorkday` + manueller Trigger | `IsinAnforderungslistenBatchJobScheduleService` | Cron, Werktagsprüfung, „Geplante Aufgaben"-Seite |
| `OrchestrationJobHelper` | `service/job/` | Verkettung, wo sie noch gebraucht wird |
| Ergebnisfiles am Job als Filestore-URI | `StmCalcJob.resultBundleFile` | Return-ZIP am Job |
| Diff-Job-Muster für den Parallelbetrieb | `IsinAnforderungslisteDiffJob`, `AusschuettungsMeldungDiffJobSubmissionService` | Altsystem-Results einspielen, Neusystem rechnet nach, Diff — siehe **Parallelbetrieb** |
| `DatabaseCompareService` | `service/dbcompare/` | DB-Stand Neusystem-Sybase gegen Altsystem-Sybase |

`liefer_bugs` und `liefer_zeit` existieren in IFAS13 nirgends (kein Java, kein Flyway). Das
Lieferprotokoll lebt für STM bereits im Job. Das Konzept setzt das fort.

---

## Änderungsprotokoll

### Runde 9 — 2026-09-02, Begriffe: Eingang und Inbox

| Was | vorher | jetzt |
|---|---|---|
| „Ingest" | Anglizismus für die erste Stufe | **Eingang** — Klassen `PreismeldungEingang` / `PreismeldungEingangService` / `PreismeldungEingangResult`, Package `.eingang`; die Prüfung heißt durchgängig **Eingangsprüfung** |
| „Landezone" | Metapher für den Zeilen-Behälter | **(Preismeldung-)Inbox** — nur in der Prosa; Entity `PreismeldungZeile` und Tabelle `kurs.preismeldung_zeilen` bleiben (eine Zeile der Inbox) |

### Runde 8 — 2026-09-02, Business-Tabellen nicht nach `infra`

Korrektur der Runde-7-Zuordnung: nach Postgres ja, aber nicht alles nach `infra`.

| Was | vorher | jetzt |
|---|---|---|
| **Die vier Artefakte** (Inbox, Publikationsprotokoll, `preis_herkunft`, `letzte_preise`) | Katalog `infra`, `ifas-persistence-infra` | **Business-Tabellen**: Postgres, Katalog `kurs`, eigener Context-Key (`database-context.fondspreise.db-key`), Modul **`ifas-persistence-fondspreise`** — das Muster von `ifas.ausschuettung_tmp` (`ifas-persistence-stm`, `ausschuettung-tmp-db-key` → Postgres) |
| Die vier Job-Tabellen | — | bleiben `infra` / `ifas-persistence-infra` (JOINED-Vererbung von `infra.jobs`) |
| `job_id` an den Artefakten | FK auf den Job | **logische Referenz** (UUID) — Job-System und Business-Tabellen sind verschiedene DB-Kontexte |
| Ausblick | — | die Sybase wird im Lauf von 2027 nach Postgres migriert; Guard und `kurs` landen dann im selben DBMS, und die Klammer-Transaktion kollabiert zu einer gewöhnlichen |

### Runde 7 — 2026-09-02, Review gegen die Codebase

Zwei technische Kernannahmen hielten dem Code nicht stand; dazu die Vorgaben zum Parallelbetrieb.

| Was | vorher | jetzt |
|---|---|---|
| **Guard-Transaktion** | Guard-Update und `kurs`-Write „in einer Transaktion" | geht nicht: `infra` (Postgres, Job-System-DB) und `kurs` (Sybase, Business-Kontext) sind **zwei DBMS**, kein XA. Neu: **Klammer-Transaktion** — die Postgres-TX hält die Guard-Rowlock über den Sybase-Commit; Fehlerfenster analysiert, konvergiert über den Retry |
| **`angekommen_am`** | aus `work_queue_items.created_at`, „wird in der DB erzeugt" | falsch — `created_at` setzt die Applikation (`OffsetDateTimes.now()` in `WorkQueueService`), also Serverzeit. Neu: eigenes Feld am `PreismeldungJob`, **DB-seitig** befüllt; Wiederholungen **erben** es |
| **Offener Punkt M** | offen, Vorauswahl M1 | **entschieden: Sybase ist schema-gesperrt** — keine neuen Tabellen/Spalten, weder Alt- noch Neusystem-Sybase; alles Neue nach Postgres. M2 dauerhaft vom Tisch |
| **Parallelbetrieb** | nur als Argument referenziert (B3, D, M1) | eigener Abschnitt: eigene Neusystem-Sybase, Altsystem-Results rein, Neusystem rechnet nach inkl. Persistenz, vier Diff-Ebenen; Träger `PreisMeldungDiffJob` (der Stub existiert) |
| **Claims eines gescheiterten Laufs** | Fehlerfall fehlte | der Folgelauf (`repeatedFromJob`) übernimmt die geclaimten Lieferungen — sonst blieben sie unsichtbar |
| **Initialbefüllung `letzte_preise`** | fehlte | Seed aus `kurs..tmp_if_last`, sonst 65 Tage blinder Fallback und roter B3-Diff |
| **Schnitt-Blocker** | „nur K blockiert einen Schnitt" | `tax_code` → Schnitt 1; **N** und **F** → Schnitt 5; **K** + fehlende Kennzahlen-Ist-Analyse → Schnitt 6; **J** → Schnitt 7 |
| Kleineres | — | `PreismeldungJobStatus` (Binde-s-Tippfehler); O3 = Plausi 18–20 im Sammelreport plus Fehlmeldungs-Mail; Rückmeldungs-Guard als bedingtes Update (at-most-once); Inbox-Retention ≥ 65-Tage-Fenster; Solva-Sätze durch dieselbe Pipeline; C1b eingearbeitet (kollidiert mit der Schemasperre); `pool_if_kurs`-Semantik in die Datenbeschaffung |

### Runde 6 — 2026-09-01, Namen für die Implementierung

| Was | vorher | jetzt |
|---|---|---|
| **Begriffe** | Metaphern („Landezone", heute „Inbox") ohne Code-Entsprechung | **Glossar** unter *Begriffe*: je Begriff ein Typ- und ein Tabellenname, abgeleitet aus den im Code belegten Konventionen |
| „Laufnummer" | als Muster beschrieben, das nachzubauen wäre | `Job.dailyRunNumber` **existiert**, samt Unique-Index `ux_jobs_type_key_date_daily_run_number` — geerbt, nicht nachgebaut |
| Lauf-Wiederholung | „braucht eine Regel" | `Job.repeatedFromJob` **existiert** — ein Lauf mit gesetztem FK *ist* Lauf 1b |
| `sammelreport_lauf` | `int`, null \| 1 \| 2 | **FK** `sammelreport_job_id` → `PreisSammelreportJob`; `dailyRunNumber` daran ist die 1 oder 2 |
| `rueckmeldung_gesendet` | ohne Suffix | `rueckmeldung_gesendet_at`, nach der Zeitstempel-Konvention |
| **„Auflösung"** | Prosa-Begriff, dann als `Preisaufloesung` zum Klassennamen gemacht | **gestrichen.** Im Deutschen kollidiert „Auflösung" mit der Fondsauflösung; und der Vorgang braucht keinen eigenen Namen: `WirksamePreismeldungen` (Plural-Klasse mit statischen Fabriken, Muster `SteuerMeldungBundles`) liefert `WirksamePreismeldung`. In der Prosa heißt es *welche Lieferung sich durchsetzt* |
| „Tagesmenge" | als Name des Laufergebnisses | seit Runde 4 ungenau — Lauf 2 ist ein Delta. Im Text als solches markiert; gemeint ist die Menge **eines Laufs** |

### Runde 5 — 2026-09-01, `tmp_if_last` im Detail

| Was | vorher | jetzt |
|---|---|---|
| **Offener Punkt B** | Empfehlung B2 (Abfrage) | **entschieden: B3** — geführte Tabelle plus Rebuild. Ausschlaggebend war der **Parallelbetrieb**: bei B2 gibt es nichts zu diffen, und die retroaktive Abfrage würde die Legacy-Tabelle systematisch verfehlen |
| **Leser von `tmp_if_last`** | behauptet „einziger Verbraucher: Lauf 1" | **belegt** über die drei `nQuellTab`-Zweige, plus die vollständige Schreib- und Aufräumseite (zwei Aufräumpfade) |
| **65 / 35 Tage** | beide als Aufräumregeln beschrieben | **65 ist ein Lesefilter**, 35 die einzige altersbasierte Löschregel |
| **Ausschlüsse** | „ohne die Ausschlüsse aus 8." | genau drei Fondsklassen, als `continue` im Aufrufer (`c_preise.cpp:113-132`); `WriteLastKurse` selbst hat keine |
| **Entscheidung 6** | „kein Fallback in Lauf 2" behauptet | mit Fallanalyse und Invariant **begründet** |
| **Entscheidung 8** | Protokoll implizit aus den wirksamen Preismeldungen | **Auflage:** das Publikationsprotokoll wird vom File-Writer gefüttert, sonst fehlen die Fallback-Zeilen und der `I3`-Bezug greift für sie nicht |
| **Neu** | — | offener Punkt **N**: wozu dient der Fallback? N2 wäre die einzige Anforderung, die Entscheidung 6 wieder aufwerfen würde |

### Runde 4 — 2026-09-01, zwei Server und die Reihenfolge

| Was | vorher | jetzt |
|---|---|---|
| **Nebenläufigkeit der Sync-Stufe** | „muss serialisiert werden — einthreadige Queue oder Lock" | **monotoner Guard** auf `preis_herkunft`. Kein Applikations-Lock, die Stufe läuft auf beiden Servern voll parallel |
| **Reihenfolge** | sollte erzwungen werden | wird **nicht** erzwungen — der Endzustand ist ordnungsunabhängig (Kommutativität statt Reihenfolge) |
| **Retry-Risiko aus Runde 3** | akzeptiertes Risiko | **erledigt als Beifang** — der wiederholte alte Job verliert am Prädikat |
| **Offener Punkt B** | B2 wurde durch die Serialisierungsauflage begünstigt | Argument entfällt; B entscheidet sich wieder an Zustand gegen Rechenaufwand |
| **Neu** | — | drittes eigenes Artefakt `preis_herkunft`; offener Punkt **M** (Spalte in `kurs` erlaubt?) |

### Runde 3 — 2026-09-01, Status und Reproduzierbarkeit

| Was | vorher | jetzt |
|---|---|---|
| **Statusmodell** | eigenes Enum `RECEIVED → VALIDATED → IN_KURS → CALCULATED` | die **fünf Standardwerte** des Job-Systems plus zwei Felder. `CALCULATED` ist redundant (der Sweep leitet aus den Daten ab), `IN_KURS` fragt niemand ab |
| **Orthogonalität** | echte Orthogonalität, begründet mit „berichtet, aber nicht `IN_KURS`" | **Vorrang**: der Sammelreport nimmt nur `COMPLETED`-Jobs mit. Der begründende Zustand verschwindet |
| **Stufen** | trugen je einen Status | intern, ohne eigene Statuswerte |
| **Neu** | — | Abschnitt **Reproduzierbarkeit** mit der Idempotenz je Stufe, der Reihenfolge-Gefahr und der Unterscheidung „erneut senden" / „neu laufen lassen" |
| **Offene Frage bei 7** | „Lauf 1 wird wiederholt — braucht eine Regel" | **geklärt**: zwei verschiedene Operationen mit zwei Namen |

### Runde 2 — 2026-09-01, Nachfragen zum Jobschnitt

Die einschneidendste Runde: der Jobschnitt selbst hat sich geändert.

| Was | vorher | jetzt |
|---|---|---|
| **Jobschnitt** | sechs gleichrangige Jobs in einer Kette | **eine Lieferkette mit Stufen + vier terminierte Jobs** — Sync und Kennzahlen sind Stufen, keine eigenen Jobs |
| **Statusmodell** | ein Enum, `READY_FOR_BATCH` → `PUBLISHED` → `SYNCED` | **zwei unabhängige Achsen**: `RECEIVED → VALIDATED → IN_KURS → CALCULATED` plus `sammelreport_job_id` |
| **`PUBLISHED`** | ein Status | **gestrichen** — es gibt zwei Veröffentlichungen an zwei Adressaten, „published" sagt nicht welche |
| **Entscheidung 8** | Sync liest die materialisierte Tagesmenge nach den Läufen | Sync ist eine **Stufe der Lieferkette**; übrig bleibt das **Publikationsprotokoll** je Schlüssel |
| **Entscheidung 11** | Vollständigkeits-Trigger *und* Fehlmeldung | nur die **Fehlmeldung**, ein Tagesjob zu einem definierten Zeitpunkt. Kein Trigger, nichts gated die Läufe |
| **Offener Punkt A** | „wann läuft der Sync?" | **geschlossen** — pro Lieferung, sofort |
| **Offener Punkt C** | drei Optionen offen | **C1 ist faktisch gesetzt**, weil der Kennzahlen-Sweep selbstheilend sein muss |
| **Neu belegt** | — | Legacy rechnet Kennzahlen schon pro Preissatz nach (nur bei Korrekturen); die Filegenerierung liest `kurs` nie; EZB-Kurse nur für Fremdwährungsfonds; `nCheckKag` ist produktiv `0` |

### Runde 1 — 2026-09-01, Input von Markus

| Was | Alt (31.8.) | Neu | Auslöser |
|---|---|---|---|
| **Entscheidung 6** | Lauf 2 liefert ein vollständiges Ersatz-File | Lauf 2 liefert ein **Delta** | Punkt 2 + Befund: es gibt kein `I4` |
| **Entscheidung 10** | Kennzahlen haben eine Obergrenze „vor dem nächsten Plausi-Lauf" | **keine** Obergrenze — die Behauptung war falsch | `pdPreis_ber` wird lokal gerechnet |
| **Offener Punkt D** | Wahl zwischen `I3` und Auslassung | **entschieden: explizites `I3`** | ein Delta lässt keine Wahl |
| **Offener Punkt F** | Rückfallposition „ein Lauf" war offen | zwei Auslieferungen sind gesetzt | „diese erhalten nun 2 reports" |
| **Neu 11–15** | — | Fehlmeldung, Lieferketten-Transparenz, beendete Fonds, `makeAbweichung` entfällt, Ausschüttung ohne Preis | Punkte 3, 4, 7, 8, 9 |
| **Datenbeschaffung** | `preise_check`-Toleranzen nötig | entfällt; dafür neu: `preismeldung`-Werte, Referenzkurs-Parameter | Punkt 9 bzw. 4/6 |

---

## Begriffe

### Satzart-Identifier (`I2` / `I3`) — im **ausgehenden** Preisfile

Die erste Spalte jeder Zeile in `preis*.csv` ist ein zweistelliger Identifier:

| Identifier | Bedeutung |
|---|---|
| `I1` | Header (Kursdatum, Erstelldatum, Erstellzeit) |
| `I2` | Preis, **Insert oder Update** (Upsert) |
| `I3` | Preis, **Delete** |
| `I9` | Footer (Anzahl Deletes, Inserts, Korrekturen) |
| `S1`/`S2`/`S3` | Solvabilität, Ziffer = Stufe |
| `D1`/`D2`/`D3` | Solvabilität, Delete |

**`I4` kommt im inländischen `preis.csv` nicht vor.** Beleg:

- Die Preis-Streams werden **ohne** `SetFlag()` angelegt (`M_FP_DLD.CPP:243-257`); nur die
  Solva-Streams setzen `SetFlag(9)`. Default ist `nFlag = 0` (`c_streams.cpp:37`).
- `GetOutAktionscode` (`m_fp_rec.CPP:5649-5698`) verzweigt bei `nFlag == 1 | 3 | 4` in die
  Korrekturkennzeichen-Variante (`0`/`2`/`3`/`4`, über `szAktion_neu`) — das ist der Pfad der
  **ausländischen** KESt/QuSt-Files. Für `nFlag == 0` greift die Standardvariante:
  `szAktion[0] == 'D'` → `3`, sonst → `2`, mit dem Kommentar `nAktion = 2; // Insert / Update`.

Folgen: der Bezieher macht bei `I2` einen **Upsert** auf `(ISIN, Preisdatum, Währung, Code)`. Der
Rückgabewert `0` („bereits vorhanden") ist im Fondspreis-Pfad unerreichbar. Und ein Delta-File
braucht **keinen** Bezugspunkt für Insert-gegen-Update, weil es die Unterscheidung nicht gibt — die
Grundlage von Entscheidung 6.

### LMT — die Meldekategorien `L1` / `L2` / `L3`

Neu mit Lieferformat **V3.0** (2026, `docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf`);
V2.0 (2025) kennt sie nicht.

| Code | Bedeutung | Wertebefüllung (Spalte 5) |
|---|---|---|
| `L1` | Rücknahmebeschränkung | Quote — Prozentzahl wenn Spalte 9 = `J`, sonst Geldwert |
| `L2` | Verlängerung der Rückgabefrist | Anzahl Tage; bei `0` trägt Spalte 10 den Stichtag |
| `L3` | Rückgabegebühr | Gebühr, Prozent oder Geldwert je Spalte 9 |

Die Aktion `I` (Inaktivierung) existiert **ausschließlich** für `L2` und kam ebenfalls erst mit V3.0
(`PreisAktion.java:10`). LMT steht branchenüblich für **Liquidity Management Tools**; aus unseren
Quellen belegt ist das nicht — für ein Dokument nach außen bei der Fachabteilung bestätigen lassen.

### Namen für die Implementierung

Die Begriffe dieses Plans sind zum Teil Bilder — „Inbox" beschreibt einen Behälter, nicht eine
Sache. Für den Code gilt: **Metaphern bleiben in der Prosa, Identifier benennen Dinge.**

#### Konventionen, wie sie im Code tatsächlich gelten

| Regel | Belege |
|---|---|
| Typen: deutsche Domänen-Substantive, **umlautfrei transliteriert** | `AusschuettungJob`, `FristenpruefungJob`, `GeschaeftsjahreCalcJob`, `Meldekategorie` |
| Englisch für Technisches, Mischung erlaubt | `…Job`, `…Repository`, `Csv…`, `isQuoteOrGebuehr()` |
| **Kein Binde-s vor `Job`** | `AusschuettungJob`, nicht `AusschuettungsJob` |
| Tabellen: `catalog = "infra"` für neue Artefakte, snake_case **Plural** | `infra.stm_calc_jobs`, `infra.isin_anforderungsliste_diff_jobs` |
| Spalten: snake_case, Englisch technisch / Deutsch fachlich, Zeitstempel `…_at` | `input_filename`, `error_count` vs. `liefer_id`; `started_at`, `next_retry_at` |
| Status: `<Domain>JobStatus implements JobStatus`, die fünf Standardwerte | `StmCalcJobStatus`, `BadInputJobStatus` |
| Indizes `ux_<tabelle>_<spalten>`, FK `fk_<tabelle>_<rolle>` | `ux_jobs_type_key_date_daily_run_number`, `fk_jobs_repeated_from` |
| Javadoc: englische Prosa, deutsche Fachbegriffe **mit** Umlauten | `Meldekategorie` |

Kataloge sind `kurs`, `ifas` und `vwkn` (Legacy-Schemata) sowie **`infra`** für die Job- und
Work-Queue-Infrastruktur. **Sybase ist schema-gesperrt** (Vorgabe 2026-09-02, offener Punkt M):
keine neuen Tabellen und keine neuen Spalten, weder in der Altsystem- noch in der Neusystem-Sybase —
die Schemata müssen für den Parallelbetrieb-Diff identisch bleiben, und die Sybase wandert im Lauf
von 2027 ohnehin nach Postgres. Daraus die Aufteilung (präzisiert in Runde 8):

- **Die vier Job-Tabellen** sind Infrastruktur: Katalog `infra`, Paket `fondspreise` in
  `ifas-persistence-infra` — dort liegen sämtliche Job-Entities (JOINED-Vererbung von `infra.jobs`).
- **Die vier Artefakte** (Inbox, Publikationsprotokoll, `preis_herkunft`, `letzte_preise`) sind
  **Business-Tabellen** und gehören **nicht** nach `infra`. Sie liegen auf Postgres im Katalog
  `kurs` (dem fachlichen Legacy-Schema — nach der Migration landen die Legacy-Tabellen im selben
  Katalog), angebunden über einen eigenen Context-Key (`database-context.fondspreise.db-key`),
  Modul **`ifas-persistence-fondspreise`**, das die Struktur von `ifas-domain-fondspreise`
  spiegelt. Das ist exakt das Muster von `ifas.ausschuettung_tmp`: neue Business-Tabelle im
  Legacy-Katalog, in `ifas-persistence-stm`, geroutet über `ausschuettung-tmp-db-key` → Postgres.

Business-Kontext auf Sybase gegen neue Tabellen auf Postgres heißt bis zur Migration: **zwei DBMS,
keine gemeinsame Transaktion** (Folgen siehe *Zwei Server, ein Pool*). Und weil die Artefakte und
die Jobs in verschiedenen DB-Kontexten liegen, ist `job_id` an den Artefakten eine **logische
Referenz** (UUID), kein DB-FK.

#### Die Namen

| Begriff im Plan | Typ | Tabelle |
|---|---|---|
| Preismeldungs-Job, pro Lieferdatei | `PreismeldungJob` | `infra.preismeldung_jobs` |
| dessen Status | `PreismeldungJobStatus` | — |
| **Inbox** — eine gelieferte Zeile | `PreismeldungZeile` | `kurs.preismeldung_zeilen` (Postgres) |
| Preisschlüssel (ISIN, Preisdatum, Währung, Meldekategorie) | `Preisschluessel` (embeddable) | eingebettet |
| **Sammelreport**-Lauf | `PreisSammelreportJob` | `infra.preis_sammelreport_jobs` |
| **Publikationsprotokoll** — ein publizierter Schlüssel je Lauf | `PreisPublikation` | `kurs.preis_publikationen` (Postgres) |
| die Aktion `I2`/`I3` darin | `AusgabeAktion { UPSERT, DELETE }` | — |
| monotoner Guard | `PreisHerkunft` | `kurs.preis_herkunft` (Postgres) |
| `tmp_if_last`-Projektion | `LetzterPreis` | `kurs.letzte_preise` (Postgres) |
| **welche Lieferung sich durchsetzt** — die Komponente | `WirksamePreismeldungen` (statische Fabriken, wie `SteuerMeldungBundles`) | — |
| deren Ergebniszeile | `WirksamePreismeldung` | — |
| Fehlmeldungs-Job | `FehlendePreismeldungenJob` | `infra.fehlende_preismeldungen_jobs` |
| Kennzahlen-Sweep | `OffeneKennzahlenJob` | `infra.offene_kennzahlen_jobs` |
| Zielgruppe des Ausgabestroms | `Zielgruppe { ALLE, VENDOR, PUBLIKUM }` | — |
| erwartete Lieferung (Soll) | `ErwartetePreismeldung` | Abfrage, keine Tabelle |

Felder am `PreismeldungJob` über das Geerbte hinaus:

```java
@ManyToOne(fetch = FetchType.LAZY)
@JoinColumn(name = "sammelreport_job_id",
            foreignKey = @ForeignKey(name = "fk_preismeldung_jobs_sammelreport"))
private PreisSammelreportJob sammelreportJob;   // null = noch in keinem Lauf berichtet

@Column(name = "rueckmeldung_gesendet_at")
private OffsetDateTime rueckmeldungGesendetAt;  // Guard gegen doppelte Mails
```

#### Was die Basisklasse schon liefert — und der Plan erfunden hatte

`Job` (Tabelle `infra.jobs`, JOINED-Vererbung, Diskriminator `job_type`) bringt mit:

| geerbt | ersetzt im Plan |
|---|---|
| `keyDate` + **`dailyRunNumber`**, mit Unique-Index `ux_jobs_type_key_date_daily_run_number` | die erfundene „Laufnummer" und das angebliche „Muster" aus Entscheidung 5 — es ist ein geerbtes Feld, kein Nachbau |
| **`repeatedFromJob`** (`repeated_from_job_id`, mit FK) | bedient direkt „neu laufen lassen" aus der Reproduzierbarkeit: ein Lauf mit gesetztem `repeatedFromJob` **ist** Lauf 1b |
| `status`, `statusMessage`, `createdAt`, `startedAt`, `finishedAt`, `protocolFile`, `createdBy`, `archived` | — |

Und eine Verbesserung, die aus den Konventionen folgt: `sammelreport_lauf` wird **kein `int`**,
sondern ein FK auf den Lauf. Die Abfrage bleibt `sammelreport_job_id IS NULL`, aber man kommt vom
Job an seinen Lauf — und `dailyRunNumber` daran ist die 1 oder 2.

#### Zwei offene Namensfragen

- **`PreisHerkunft` oder `KursHerkunft`?** Die Tabelle hält die Ankunftsmarke der Lieferung, die
  eine `kurs`-Zeile zuletzt geschrieben hat. `PreisHerkunft` passt zu `PreisPublikation`,
  `KursHerkunft` sagt genauer, wessen Herkunft protokolliert wird. Vorauswahl `PreisHerkunft`.
- **`OffeneKennzahlenJob`** trägt kein Domänenpräfix. Ein `Preis`-Präfix wäre zu eng: Legacy trennt
  `preisekennzahl.cpp` (je Preis) von `fondskennzahl.cpp` (je Fonds), und der Sweep deckt beides ab.

> **„Fehlmeldung" darf kein Identifier werden.** Das Wort ist im Deutschen zweideutig — „Meldung
> über etwas Fehlendes" *und* „irrtümliche Meldung". In der Prosa bleibt es, im Code heißt es
> `FehlendePreismeldungenJob`. `PreismeldungMahnungJob` wäre die naheliegende Alternative, kollidiert
> aber mit den Legacy-„Mahnungen" der ausländischen Fonds (`preis_dld.e -M/-L`).

---

## Die Jobs

Fünf Jobs. Einer läuft pro Lieferdatei, vier sind terminiert und lesen mit.

### 1. Preismeldungs-Job — pro Lieferdatei

Nicht terminiert; startet, sobald eine Datei eingeht. Drei Stufen — **intern, ohne eigene
Statuswerte** (siehe unten):

| Stufe | tut | Nebenläufigkeit |
|---|---|---|
| parsen, prüfen, antworten | Eingangsprüfung (Entscheidung 2), Inbox-Zeilen schreiben, ZIP an den Lieferanten | **parallel** über alle Lieferungen |
| nach `kurs` | Berechtigungsfilter, `kurs` / `pool_if_kurs`, Löschungen, `tmp_if_last` | **parallel** — der Guard ordnet je Preisschlüssel (siehe *Zwei Server, ein Pool*) |
| Kennzahlen | die betroffenen Kennzahlen des Fonds nachrechnen | Versuch; darf unvollständig bleiben |

### 2. + 3. Sammelreport Lauf 1 und Lauf 2 — Cron, zwei Cutoffs

Lesen die Inbox-Zeilen der Lieferungen mit `sammelreport_job_id IS NULL`, lösen sie auf
(Entscheidung 4), erzeugen Preisfile und Plausi-Report, verteilen, und schreiben das
Publikationsprotokoll. Nichts gated sie: sie starten zu ihrer Zeit und verarbeiten, was da ist.

### 4. Fehlmeldungs-Job — Cron, ein definierter Zeitpunkt

Einmal am Tag, z. B. 17:00. Alles, was bis dahin nicht geliefert wurde, gilt als fehlend.
Ergebnis: Mail je Lieferant mit den fehlenden ISINs, bzw. Sammelmail an die Fachabteilung.
Siehe Entscheidung 11.

### 5. Kennzahlen-Sweep — periodisch

Sucht Preise ohne Kennzahl und rechnet sie. Fängt, was die Stufe „Kennzahlen" des
Preismeldungs-Jobs nicht konnte — vor allem Fremdwährungsfonds, deren EZB-Referenzkurs noch fehlte.
Seine Arbeitseinheit ist nicht eine Lieferung, deshalb ist er ein eigener Job.

### Der Status: der Standard des Job-Systems, plus zwei Felder

**Geändert am 2026-09-01 (Runde 3).** Ein vierstufiges eigenes Enum
(`RECEIVED → VALIDATED → IN_KURS → CALCULATED`) war über-modelliert. Der Test ist: *was fragt den
Status überhaupt ab?*

| Wer | fragt | braucht einen Fortschritts-Status? |
|---|---|---|
| Sammelreport-Lauf | `sammelreport_job_id IS NULL` | nein |
| Kennzahlen-Sweep | „Preise ohne Kennzahl" — **aus den Daten**, nicht aus dem Jobzustand | nein |
| Fehlmeldungs-Job | die Inbox | nein |
| Betrieb / UI | „durch oder nicht" | nur terminal + Fehler |

`CALCULATED` ist damit **redundant**: der Sweep ist gerade deshalb selbstheilend, weil er seine
Arbeit aus den Daten ableitet und nicht aus Jobzuständen. Und `IN_KURS` fragt niemand ab.

Dazu die Konvention der Codebase: `JobStatus` ist ausdrücklich der „*Informal business status …
not to be confused with the technical state of a Work Queue Item*". Alle Domänen-Enums sind
dieselben fünf, und `StmCalcJobStatus` fügt genau **einen** hinzu —
`WAITING_FOR_START_OF_DAY`, also einen *Wartezustand auf etwas außerhalb*, keinen
Fortschrittsmarker. Das ist das Kriterium.

```
PreismeldungJobStatus   =  PENDING, PROCESSING, COMPLETED, FAILED, CANCELLED
am Job zusätzlich:         sammelreportJob       : FK → PreisSammelreportJob, nullable
                           rueckmeldungGesendetAt: timestamp   (Guard, siehe Reproduzierbarkeit)
```

**Und eine Revision:** die Orthogonalität war mit dem Fall „berichtet, aber noch nicht `IN_KURS`"
begründet. Besser: **der Sammelreport nimmt nur `COMPLETED`-Jobs mit.** Damit verschwindet dieser
Zustand ganz, `kurs` und das ausgehende File bleiben konsistent, und der Preis ist nur Latenz — eine
im Sync steckende Lieferung verpasst den Cutoff und geht im nächsten Lauf mit. Das ist
genau das „Nachzügler wartet"-Verhalten, das wir ohnehin akzeptieren.

Die zwei Achsen bleiben damit als **Vorrang** statt echter Orthogonalität. `sammelreport_job_id` bleibt,
weil es von einem *anderen* Job gesetzt wird als dem, der die Lieferung besitzt, und weil es der
Abfrageschlüssel ist. `READY_FOR_BATCH` entfällt: der Lauf fragt
`status = COMPLETED AND sammelreport_job_id IS NULL`.

**`PUBLISHED` ist gestrichen.** Es gibt zwei Veröffentlichungen an zwei Adressaten, und „published"
sagt nicht, welche gemeint ist:

| | wohin | Wirkung |
|---|---|---|
| Sync-Stufe | `kurs`, `del_protokoll` → IFASNXT | der interne Bestand wird aktuell |
| Sammelreport-Lauf | `preis.csv` / `solva.csv` → MFT, T2S | der Bestand **beim Bezieher** ändert sich |

Der Sammelreport ist also nicht „nur ein Protokoll": die Bezieher wenden `I2`/`I3` auf ihren eigenen
Bestand an, und die kundenseitige Formatbeschreibung beschreibt einen Datenfeed. „Report" trifft die
Rolle im Ablauf (periodische Zusammenfassung des Geänderten), nicht die Wirkung. Deshalb heißen beide
nach ihrem Artefakt, nicht nach dem abstrakten Akt.

### Warum Stufen und nicht fünf gleichrangige Jobs

Sync und Kennzahlen haben dieselbe Arbeitseinheit wie der Eingang — eine Lieferdatei — und müssen
innerhalb dieser Einheit in Reihenfolge laufen. Eigene Jobs bräuchten je eigene Identität, eigenes
Retry und eine Rückbindung an die Lieferung: Buchhaltung ohne Gewinn. Und weil die Stufen keine
eigenen Statuswerte tragen, kostet die Zusammenlegung auch nichts an Nachvollziehbarkeit — was eine
Stufe getan hat, steht im Joblog.

Der Kennzahlen-Sweep ist die Ausnahme, weil seine Arbeitseinheit „alle Preise ohne Kennzahl" ist und
nicht eine Lieferung.

### Zwei Server, ein Pool: die Reihenfolge

**Geändert am 2026-09-01 (Runde 4).** Eine frühere Fassung verlangte, die Sync-Stufe zu
serialisieren — einthreadige Queue oder Lock. Das ist nicht nötig und wird verworfen: Locks sind ein
Deadlock-Risiko, und das Problem lässt sich ordnungsfrei lösen.

Das Neusystem läuft auf **zwei Servern**, die beide Work-Queue-Items aus demselben Pool ziehen.
Ohne weitere Maßnahme kann die neuere Lieferung vor der älteren verarbeitet werden.

**Der Kern: es braucht keine Reihenfolge, sondern Kommutativität.** Die Anforderung ist nicht
„A vor B verarbeiten", sondern: *der Endzustand muss der sein, den die spätere Ankunft impliziert.*
Das ist ohne Koordination erreichbar.

#### Was die Work Queue schon mitbringt

| Baustein | Leistung |
|---|---|
| `required_server` | Server-Affinität, über `SubmitOptions` setzbar; `findNextPendingItemIds` respektiert `(requiredServer IS NULL OR requiredServer = :serverId)` |
| `ORDER BY priority, createdAt` | Kandidaten werden in Ankunftsreihenfolge gezogen |
| `claimItem` | atomares Compare-and-Set (`UPDATE … WHERE status = 'PENDING'`), kein Lock, liefert 1/0 |
| `heartbeatAt` + Orphan-Recovery | abgestürzte Server geben Items frei |

Was fehlt: **geordnete Auswahl ist nicht geordnete Fertigstellung.** Es gibt einen Pool je Server
(`executorPoolSize`) und *keine* Concurrency-Grenze je Task-Type — auch auf einem Server laufen
mehrere Items gleichzeitig.

#### Gewählt: monotoner Guard (Last-Write-Wins nach Ankunft)

Eine eigene kleine Tabelle als Serialisierungspunkt je Preisschlüssel. Nicht in der Sybase, weil
die schema-gesperrt ist (offener Punkt M, entschieden) — `preis_herkunft` liegt wie die übrigen
Artefakte als Business-Tabelle auf Postgres (Runde 8):

```
preis_herkunft   PK (num_wfs_ku, dat_kurs, cod_fliesscode, waehrung)
                 → job_id, angekommen_am
```

Pro Preisschlüssel:

```sql
update preis_herkunft
   set job_id = @job, angekommen_am = @arrival
 where <schlüssel> = ...
   and angekommen_am < @arrival
-- rowcount = 1 → wir sind die Neueste → kurs schreiben
-- rowcount = 0 → Zeile fehlt (dann insert, bei PK-Verstoß update wiederholen)
--                oder eine Neuere hat gewonnen → still überspringen, das ist korrekt
```

Warum das ordnungsunabhängig ist: läuft A (älter) zuerst, gewinnt A, dann gewinnt B und
überschreibt — Endzustand B. Läuft B zuerst, gewinnt B, dann scheitert A am Prädikat und überspringt
— Endzustand B. Beide Reihenfolgen, gleiches Ergebnis.

Dasselbe Muster nutzt die Codebase schon: `claimItem` ist ein bedingtes `UPDATE`, und
`WorkQueueExecutor` nennt es ausdrücklich „*Cluster-safe: Uses optimistic concurrency*". Gleiche
Form, anderes Prädikat — statt `status = 'PENDING'` eben `angekommen_am < @arrival`. Versionsbasiertes
optimistisches Sperren löst ein Reihenfolgeproblem nicht; ein Vergleich auf einem **monoton
wachsenden fachlichen Wert** löst es.

`angekommen_am` muss aus **einer** Uhr kommen, bei zwei Servern also nicht aus der Serverzeit.
`work_queue_items.created_at` taugt dafür **nicht**: es wird applikationsseitig gesetzt
(`WorkQueueService` verwendet `OffsetDateTimes.now()`) — die frühere Behauptung „wird in der DB
erzeugt" war falsch. Stattdessen: ein Feld `angekommen_am` am `PreismeldungJob`, **DB-seitig
befüllt** beim Insert (Postgres `now()`) — beide Server stellen in dieselbe DB ein, das ist die
eine Uhr. Ein wiederholter Job (`repeatedFromJob` gesetzt) **erbt** die Ankunftszeit seines
Originals; nur so verliert er am Prädikat, statt als „Neuester" zu gewinnen. Gleichstand
deterministisch über `job_id` brechen.

#### Die eine Einschränkung: die Klammer-Transaktion

**Korrigiert am 2026-09-02 (Runde 7).** Die frühere Auflage „Guard-Update und `kurs`-Schreiben in
einer Transaktion" ist nicht umsetzbar: `preis_herkunft` liegt in Postgres, `kurs`
auf Sybase — **zwei DBMS**, kein XA. Die Serialisierung leistet stattdessen eine
**Klammer**: die Postgres-Transaktion mit dem Guard-Update bleibt offen, bis der Sybase-Write
committet ist — erst dann committet sie selbst. Die Rowlock auf der Guard-Zeile hält damit über den
`kurs`-Write hinweg; ein nebenläufiges B für denselben Schlüssel wartet auf dieser Zeile, bis As
Write sichtbar ist. Dieselbe Garantie wie die Ein-DB-Transaktion, nur über zwei Verbindungen.
Deadlockfrei bleibt es unverändert durch:

- **eine Klammer pro Preisschlüssel** statt pro Datei, und
- die Schlüssel in **deterministischer Reihenfolge** (sortiert) abarbeiten — gesperrt wird nur in
  Postgres, die Sybase-Writes sind kurze eigenständige Transaktionen.

Bei ~4200 Preisen/Tag ist der Overhead irrelevant.

**Das neue Fehlerfenster:** stürzt der Prozess zwischen Sybase-Commit und Postgres-Commit ab, ist
`kurs` geschrieben, aber der Guard unmarkiert. Das konvergiert: der automatische Retry gewinnt am
unveränderten Guard erneut und wiederholt den idempotenten Upsert. Kommt dazwischen eine neuere
Lieferung B, gewinnt B den Guard und schreibt; der Retry von A verliert dann am Prädikat und
überspringt — Endzustand B, korrekt. Nur ein endgültig aufgegebener `FAILED`-Job kann einen
veralteten `kurs`-Stand hinterlassen; dafür gibt es das Reparaturwerkzeug aus B3 (Neu-Herleitung in
Ankunftsreihenfolge). Die Gegenrichtung ist ausgeschlossen: scheitert der Sybase-Write, rollt die
Klammer den Guard mit zurück.

Eine Spalte in `kurs`, die das alles erübrigt hätte, ist **entschieden ausgeschlossen** — die
Sybase ist schema-gesperrt (offener Punkt M). `kurs.guelt` umzudeuten war ohnehin keine Option,
weil C3 `guelt` als Reparatursignal vorsieht.

Die Klammer ist ein **Übergangszustand**: mit der Sybase-Migration nach Postgres (im Lauf von 2027)
liegen Guard und `kurs` im selben DBMS, und die Klammer kollabiert zu einer gewöhnlichen
Transaktion — ohne dass sich am Prädikat oder an der Schlüssel-Sortierung etwas ändert.

#### `tmp_if_last` braucht dieselbe Behandlung

Legacy schreibt dort „nur wenn Preisdatum neuer" — das ist schon ein monotoner Guard, aber der
falsche: zwei Lieferungen zum **gleichen** Preisdatum (eine Korrektur) würden am Prädikat
`preisdatum <` scheitern. Der Guard muss lexikografisch über `(preisdatum, angekommen_am)` gehen.
Weil `tmp_if_last` unsere eigene Projektion ist, kann die Zeile `angekommen_am` einfach mitführen.

Damit fällt auch das Serialisierungsargument bei **offenem Punkt B** weg: B1 (geführte Tabelle) und
B2 (Abfrage) sind nebenläufigkeitsseitig beide unbedenklich. B entscheidet sich wieder allein an
Zustand gegen Rechenaufwand.

#### Verworfene Alternativen

| Ansatz | warum nicht |
|---|---|
| Affinität: alle Lieferungen eines Lieferanten via `required_server` auf einen Server | Reduziert Kollisionen, löst es nicht — der Pool dieses Servers läuft weiter parallel. Und ob „je Lieferant" ein *gültiger* Partitionsschlüssel ist, entscheidet erst Q1/Q3; produktiv wurde die Zuordnung nie erzwungen (`-K0`) |
| Sync als eigener Task-Type, auf einen Knoten gepinnt, Concurrency 1 | Concurrency-Grenze je Task-Type gibt es nicht; der Job zerfällt in zwei; der Knoten wird Single Point of Failure für die Stufe |
| Sequenz-Gate: Item *n* erst nach *n−1* | Head-of-line blocking — ein gescheitertes Item blockiert den Schlüssel dauerhaft |
| Reihenfolge ignorieren | Das Fenster ist die Dauer der Sync-Stufe, die Kollision also selten. Aber der Fehler ist still und landet beim Bezieher |

### Reproduzierbarkeit: kann ein Job wiederholt werden?

Die Datenseite ja, die Außenwirkung nein.

| Stufe | Datenseite | Außenwirkung |
|---|---|---|
| parsen, prüfen | rein, beliebig wiederholbar | — |
| Inbox schreiben | idempotent **nur wenn** auf `job_id` gescoped. PK ist `(job_id, zeilen_nr)`, ein naives Re-Insert knallt → `delete by job_id` + insert, oder Upsert | — |
| Rückmeldung | — | **nicht idempotent** — zweite Mail beim Lieferanten. Guard: `rueckmeldung_gesendet_at` |
| nach `kurs` | Upsert idempotent; `D` auf eine gelöschte Zeile ist No-op; `tmp_if_last` schreibt „nur wenn Preisdatum neuer" → No-op | `del_protokoll` bekommt einen zweiten Eintrag (`CONFIG.INI/Del_Protokoll` Default `0`) |
| Kennzahlen | deterministisch, gleiche Eingaben → gleiche Werte | `ASF.r_faktor` identisch — **aber** `r_faktor_ges` muss vorwärts kaskadieren (`MakeNextReinvestFaktor`), sonst bleiben die Folge-Ausschüttungen stale |

Daraus die allgemeine Regel: **idempotente Datenarbeit von nicht-idempotenter Außenwirkung trennen
und festhalten, was hinausgegangen ist.** Das Publikationsprotokoll tut das für das Preisfile;
dasselbe braucht die Rückmeldung und die Fehlmeldung — sonst mailt jeder Retry erneut.

Der Rückmeldungs-Guard braucht dabei dieselbe Form wie der monotone: ein **bedingtes Update**
(`… set rueckmeldung_gesendet_at = now() where … and rueckmeldung_gesendet_at is null`), gesendet
wird nur bei `rowcount = 1` — sonst mailen zwei Server im Retry-Fall doppelt. Markieren-dann-Senden
heißt at-most-once: stürzt der Prozess zwischen Markierung und Versand ab, fehlt die Mail. Das ist
die richtige Seite des Zweifels, weil es mit „erneut senden" eine benannte manuelle Reparatur gibt.

#### Die eine echte Gefahr ist nicht Wiederholung, sondern Reihenfolge

Der Sync ist für **eine** Lieferung isoliert idempotent, aber **nicht umsortierbar**:

> Job A scheitert in der Sync-Stufe. Später eingelangte Lieferungen B für denselben Preisschlüssel
> laufen durch und schreiben `kurs`. Jetzt A wiederholen → **A überschreibt B mit älteren Daten.**

Den *neuesten* Job wiederholen ist sicher, einen *alten* nicht.

**Entscheidung (User, 2026-09-01): war als akzeptiertes Risiko protokolliert** — „Wenn jemand
manuell einen Job wiederholt, muss er wissen was er tut."

**Erledigt in Runde 4.** Der monotone Guard aus **Zwei Server, ein Pool** löst das als Beifang: der
wiederholte A verliert am Prädikat `angekommen_am < @arrival` und überspringt still. Das Risiko muss
nicht mehr akzeptiert werden, weil es strukturell verschwindet — und zwar unabhängig davon, ob der
Retry manuell oder automatisch ausgelöst wurde.

Das ist relevant, weil der Retry eben nicht nur manuell passiert: die Work Queue holt
`FAILED`-Items **selbst** wieder (`findItemsReadyForRetry`:
`status = FAILED AND attemptCount < maxAttempts AND nextRetryAt <= now`). Beim manuellen Retry weiß
der Mensch, was er tut; beim automatischen weiß es niemand.

Als Reparaturwerkzeug für unordentliche Fälle bleibt das Neu-Herleiten der betroffenen Schlüssel aus
allen Lieferungen in Ankunftsreihenfolge.

#### Das Preisfile ist beim Bezieher inhalts-idempotent

Folgt aus dem `I4`-Befund: `I2` ist ein Upsert, `I3` ein Delete. Dasselbe File zweimal angewandt
ändert nichts. Ein versehentlich doppelt verschicktes File ist harmlos.

**„Lauf wiederholen" ist deshalb zweideutig** — und das löst die Frage, die bei Entscheidung 7 offen
stand:

| Operation | Bedeutung | idempotent? |
|---|---|---|
| **erneut senden** | das im Publikationsprotokoll aufgezeichnete Ergebnis noch einmal ausliefern | ja |
| **neu laufen lassen** | neu selektieren. Ergibt ein *anderes* File, sobald zwischenzeitlich Lieferungen kamen | nein — kein Wiederholen, sondern ein neuer `PreisSammelreportJob` mit gesetztem `repeatedFromJob` und der nächsten `dailyRunNumber` |

---

## Abhängigkeiten — und die eine, die weh tut

Die Frage „kommen wir ohne Batch aus?" lässt sich nicht an den Preisen allein entscheiden. Sie
entscheidet sich an den **Ausschüttungen**, und dort hat das Altsystem eine zirkuläre zeitliche
Abhängigkeit, die es nicht auflöst.

### Was die Kette liest und schreibt

| Bereich | Quelle | wofür |
|---|---|---|
| Identität | `vwkn..wkn_hist` | ISIN → `num_wfs`/`num_wfs_ku`; historisiert **und** auf Währung geschlüsselt |
| | `vwkn..wkn_desc` | `cod_art_f` (FOND/TECH/C-PL/TEST), Bezeichnungen |
| Fondsstammdaten | `ifas..INV` | KAG, Währung, Status, `fonds_beginn`/`-ende`, `veroeffentlichung`, `FONDS_ZGRU`, `preismeldung` |
| Konfiguration | `kurs..tax_code` | **jede** Eingangsprüfung hängt daran |
| | `HWA` / `waehrungen` | Währungsprüfung |
| | `kurs..lieferanten`, `KAG_lieferanten` | Rückmeldeadressen, Berechtigung (produktiv abgeschaltet) |
| | Kalender / Börsetage | Werktagsprüfung, Altersfenster |
| Nachbardomänen | **`ifas..ASF`** | **Ausschüttungen und Splits** — siehe unten |
| | `zeas..adev` | EZB-Referenzkurse; nur Kennzahlen, nur Fremdwährungsfonds |

Geschrieben werden `kurs..kurs`, `pool_if_kurs`, `tmp_if_last`, die Kennzahlentabellen,
`ifas..del_protokoll` (→ IFASNXT), die Preisfiles (→ MFT/T2S), die Rückmeldung (→ Lieferant) —
**und `ifas..ASF.r_faktor`**.

### Ausschüttungen: sechs Berührungspunkte, drei Richtungen

Alles hängt an **einer** Tabelle: `ifas..ASF`, PK
`(WFS_WKN, ASF_DATUM, waehrung, aussch_status)`, `aussch_status in ('A','V','D')`. Sie trägt
Ausschüttungen **und** Splits, und sie trägt den Reinvestitionsfaktor.

| # | Wo | Richtung | Was genau |
|---|---|---|---|
| 1 | Filegenerierung | Preis **braucht** Ausschüttung | Spalten 7–9 des Preissatzes: Ex-Code `EA`, Betrag, Zahltag. `ReadAusschuettung` liest ASF mit `<preisdatum> between ASF_DATUM and isnull(aussch_datum, ASF_DATUM)`. Nur Stream „alle", nur Inland. |
| 2 | Kennzahlen | Ausschüttung **braucht** Preis | `dR_faktor = (dNav + dAusschuettung) / dNav` (`fondsbasis.cpp:1960ff`). Ohne Kurs `return -1`. `r_faktor_ges` ist das kumulierte Produkt über alle früheren Ausschüttungen des Fonds. |
| 3 | Plausi 18–20 | Kontrolle der Paarung | `makeAusOhnePreis`: `ASF_DATUM = Stichtag`, `aussch_status <> 'V'`, inländisch — aber kein Preis geliefert. Genau die Konstellation, in der 2. scheitert. Markus Punkt 8. |
| 4 | Einspielung, `R`-Löschung | Ausschüttung **blockiert** | Liegt zum Preisdatum eine Ausschüttung vor, wird die Löschung verweigert — ohne jede Rückmeldung, mit `// ????` im Quelltext (`preisekennzahl.cpp:2539-2547`). Offener Punkt E. |
| 5 | Plausi `makeAbweichung` | Ausschüttung **verzerrt** | `pdPreis_ber = pdPreis * dSplitfaktor (+ dAusschuettung)`, lokal gerechnet. Entfällt mit 14. |
| 6 | `run_asf_vorl` (Tagesjob 5) | Ausschüttung **löst aus** | `ASF_VORL → ASF`, „inkl. kompletter Nachrechnung der r/s_faktor_ges, der berichtigten Kurse und aller Kennzahlen". |

### Der Zirkel im Altsystem

Zwei Programme greifen gegenläufig auf dieselbe Nahtstelle:

```
Filegenerierung (Tagesjob Schritt 1)   liest  ASF   → will die Ausschüttung gebucht haben
Ausschüttungs-Einspielung (crontab)    liest  kurs  → will den Preis gebucht haben
Preis-Einspielung (Tagesjob Schritt 4) schreibt kurs → läuft NACH Schritt 1
```

Drei Belege, die das hart machen:

- **`run_aussch.csh` ist kein Tagesjob-Schritt.** Im Kopf steht „wird von crontab gestartet"; die
  Kette ist `tmp_aussch → ASF` (Kopie `cop_aussch`) plus Files plus Archivierung. Zwischen ihr und
  dem Tagesjob gibt es **keine erzwungene Reihenfolge** — nur zwei Cron-Zeiten.
- **Für inländische Fonds ist der Riegel absolut.** `asfkennzahl.cpp:880-916` liest den `R`-Kurs zum
  `ASF_DATUM`; fehlt er, heißt es wörtlich „Inlaendische Fonds --> es muss ein Preis vorhanden sein"
  und „--> Die Ausschuettung kann nicht eingespielt werden." (`return -1`). Für **ausländische**
  Fonds gibt es einen Fallback (Vortagskurs minus Ausschüttungsbetrag), für inländische nicht.
- **Der Code `X` existiert genau als Notausgang.** `CONFIG.INI/FiktiverErrechneterWert` (Default
  `1`) erlaubt, einen indikativen, fiktiven errechneten Wert zur Aktivierung zu verwenden
  (`PREISE.CPP:820-821`) — und `X` wird in **keinem** Ausgabefile ausgeliefert.

Praktische Folge im Altsystem: eine Ausschüttung landet im Preisfile nur, wenn sie **an einem
früheren Tag** gebucht wurde — im Voraus geliefert — oder wenn `run_aussch.csh` zufällig zwischen
dem Einspielschritt von gestern und der Filegenerierung von heute lief. Am Ausschüttungstag selbst
ist es ohne `X` nicht möglich.

### Was das neue Modell daran ändert

Die Antwort auf „brauchen wir doch einen Batch?" ist: **nein, aber wir brauchen eine ausgedrückte
Vorrangregel zwischen zwei Domänen** — und die Lieferkette macht sie erstmals einhaltbar.

Der Grund: der Preis ist in `kurs`, sobald die Lieferung durch ist — Minuten statt „Tagesjob
Schritt 4". Damit ist die Vorbedingung der Ausschüttungs-Einspielung **am selben Tag früh** erfüllt,
und der Zirkel wird zu einer Ordnung:

```
Preislieferung → geprüft → Preis steht in kurs          (Minuten nach Eingang)
                                  ↓  Vorbedingung erfüllt
                 Ausschüttungs-Einspielung rechnet r_faktor, bucht ASF
                                  ↓
Cutoff 1      → Sammelreport liest ASF → Ausschüttung ist im Preisfile
```

Drei Wege, das auszudrücken:

| Option | Folge |
|---|---|
| **O1 — Ausschüttungs-Einspielung bleibt Tagesjob, terminiert vor Cutoff 1** | Die Ordnung ist eine Terminvereinbarung, wie heute — aber mit einer Vorbedingung, die jetzt tatsächlich erfüllt ist. Billigste Variante, und die, die der User als wahrscheinlich bezeichnet. |
| **O2 — Ausschüttungen ebenfalls pro Lieferung** | Die Ordnung löst sich von selbst: was heute nicht rechenbar war, holt der gemeinsame Kennzahlen-Sweep. Setzt voraus, dass die Ausschüttungs-Domäne genauso umgebaut wird. |
| **O3 — Sammelreport prüft die Vorbedingung** | Der Lauf stellt fest, ob für die heutigen `ASF_DATUM` die Buchung vorliegt, und **meldet**, wenn nicht — statt still ein unvollständiges File zu verschicken. |

Empfehlung: **O1 plus O3**. O3 ist unabhängig von O1/O2 richtig, weil es die einzige Stelle ist, die
den Fehler überhaupt sichtbar macht; heute schickt Legacy das File einfach ohne Ausschüttungsangaben.
O3 lebt dabei an **zwei Stellen**: je Lauf leisten es die portierten Plausi-Abschnitte 18–20 im
Sammelreport (15., Teil 1) — die Prüfung *zur Laufzeit*, im Report des Laufs, der das File erzeugt;
am Tagesende ergänzt der Fehlmeldungs-Job (11.) die Mail-Sicht — „für diese ISIN ist heute eine
Ausschüttung gebucht, aber kein Preis geliefert" ist dieselbe Art von Befund und deckt gleichzeitig
Markus Punkt 8 ab.

### Neuer offener Punkt K: wem gehört `ASF.r_faktor`?

Beide Domänen schreiben ihn:

- die **Ausschüttungs-Einspielung** beim Buchen (`asfkennzahl.cpp:921,1156`),
- die **Preis-Einspielung** bei einer Korrektur — `PreiseNachrechnung` ruft
  `cAusSpl.ReCalcReinvestFaktor(dbc_p, cPrTyp[i].dPreis)` (`preisekennzahl.cpp:3072`).

Die Abgrenzung dieses Konzepts sagt „Ausschüttungen: eigene Domäne", und gleichzeitig schreibt
unsere Kennzahlen-Stufe in deren Tabelle. Drei Lesarten:

| Option | Folge |
|---|---|
| **K1 — gehört der Ausschüttungs-Domäne** | Sie rechnet ihn selbst und braucht dafür eine Preis-Abfrage über die Domänengrenze. Unsere Kette schreibt ASF nicht mehr; bei einer Preiskorrektur müssen wir die Ausschüttungs-Domäne benachrichtigen. |
| **K2 — gehört der Kennzahlen-Domäne** | Dann liegt er in der falschen Tabelle und sollte zu den Kennzahlen wandern. Sauberer Schnitt, aber eine Datenmodell-Änderung mit Verbrauchern außerhalb (Ausschüttungs-Files, CASA, OeNB-Auswertungen). |
| **K3 — bewusst geteilt** | Wie heute. Braucht eine explizite Regel, wer bei gleichzeitiger Änderung gewinnt — und der Sweep aus 10. muss ihn mit abdecken. |

Zu klären mit Markus. Vor der Entscheidung nicht implementieren: die Kennzahlen-Stufe berührt
`ASF.r_faktor` sonst, ohne dass geklärt ist, ob sie darf.

### Befund am Rand: `ReadAusschuettung` filtert den Status nicht

Die Abfrage der Filegenerierung lautet (sinngemäß):

```sql
select ausschuettung, aussch_datum
from ifas.dbo.ASF
where WFS_WKN = <num_wfs>
  and '<preisdatum>' between ASF_DATUM and isnull(aussch_datum, ASF_DATUM)
  and isnull(ausschuettung, -1) >= 0.0
```

Kein `aussch_status`, kein `waehrung`, kein `order by` — und es wird die **erste** Zeile genommen.
Da `aussch_status` Teil des Primärschlüssels ist, können `'A'`, `'V'` und `'D'` für denselben Fonds,
Tag und dieselbe Währung nebeneinander liegen. `makeAusOhnePreis` schließt `'V'` dagegen
ausdrücklich aus und joint die Währung mit.

Heißt: es ist nicht ausgeschlossen, dass eine **vorläufige oder gelöschte Ausschüttung ins
Preisfile** gerät, und bei mehreren Treffern ist undefiniert, welche. Ob das produktiv vorkommt,
klären die Queries Q9–Q11 in `fondspreise-lieferant-isin-analyse.sql`. Davon hängt ab, ob wir hier
ein Legacy-Verhalten nachbauen oder einen Legacy-Bug.

## Entscheidungen

### 1. Keine Sammeltabelle — der Sammelzustand liegt in den Jobs

`tmp_if_kurs` und `tmp_if_cop` werden **nicht** nachgebaut. Ein Job pro Lieferdatei.

| Leistung von `tmp_if_kurs` | neu |
|---|---|
| Akkumulator, „letzte Lieferung gewinnt" | `WirksamePreismeldungen` im Sammelreport-Lauf (Entscheidung 4); für `kurs` ergibt es sich aus der seriellen Anwendung von selbst (Entscheidung 8) |
| Datenquelle für Plausi / Files / Einspielung | Inbox |
| Puffer für Spätlieferungen (`RemoveTmpKurse`, QMS 644) | entfällt — eine spät eingelangte Lieferung bleibt auf `sammelreport_job_id IS NULL` |
| Cross-File-Abgleich beim Eingang (`Check4DeleteInTmp`) | verschoben in den Sammelreport-Lauf, siehe 4. |

### 2. Das Eingangs-Urteil gilt

Der Eingang führt die Eingangsprüfung genau einmal durch (ISIN + Prüfziffer, Datumsgrenzen aus
`tax_code`, Wertbereich, `max_nk`, Währung, Aktionscode, LMT-Feldregeln, Fondsende siehe 13.) und
erzeugt die Rückmeldung. **Kein späterer Job wiederholt sie.**

- Legacy verhält sich identisch — eine Zeile in `tmp_if_kurs` wird nie wieder geprüft.
- Die einzigen Stammdaten, die sich untertags realistisch bewegen, sind die Anlage eines Fonds und
  `fonds_ende`. In beiden Fällen tut Legacy dasselbe.
- Für „Stammdaten und Lieferung passen nicht zusammen" hat Legacy einen Platz, und der ist der
  Report: `makeNichtVorhanden`, `makeFondsNotInINV`, `makePreisVorFondsBeginn`,
  `makePreisNachFondsEnde`, `makePreisNichtInFondswhrg`, `makeVorlFonds` prüfen gegen die dann
  aktuellen Stammdaten und **melden**, statt zurückzunehmen.

Ausgabeseitige, stammdatenabhängige Entscheidungen trifft der Sammelreport dagegen jedes Mal frisch
— `INV.veroeffentlichung`, `cod_art_f` (TEST/AIF), `FONDS_ZGRU`. Das ist legacy-konform
(`cFondsRecord::ReadStammdaten`). Es sind zwei verschiedene Fragen, nicht dieselbe zweimal.

### 3. Inbox: die gelieferten Zeilen pro Job

| Spalte | Inhalt | Anmerkung |
|---|---|---|
| `job_id` | logische Referenz (UUID) auf den Preismeldungs-Job | ersetzt `liefer_id` **und** `eintragezeit` — beides steht am Job. Kein DB-FK: der Job liegt im `infra`-Kontext, die Inbox im Business-Kontext (Runde 8) |
| `zeilen_nr` | Zeile im Lieferfile | Rückbindung an `data.log`/`error.log`, Reihenfolge in der Datei |
| `isin` | | |
| `preisdatum` | Berechnungsdatum (Spalte 1 des Lieferformats) | |
| `waehrung` | Währung der Lieferung, nicht die Fondswährung | |
| `meldekategorie` | `R`/`E`/`Z`/`S`/`S2`/`S3`/`X`/`L1`/`L2`/`L3` | nach Alias-Auflösung (`tax_code.alias`) |
| `aktion` | `N`/`D`/`I` | |
| `wert` | normalisiert: Komma→Punkt, Blanks entfernt, `ignore_null='J'` → `0` | |
| `fondsbezeichnung` | wie geliefert | Fallback, wenn `INV` keine hat |
| `lmt_prozentkennzeichen`, `lmt_stichtag` | | siehe offener Punkt G |

PK `(job_id, zeilen_nr)`. Vier Eigenschaften:

- **Kein Unique-Key auf dem Preisschlüssel.** Duplikate über den Tag sind der Normalfall.
- **Append-only.** Nichts wird nachträglich geändert oder gelöscht.
- **Gehört genau einem Job.** Kein lieferantenübergreifender veränderlicher Zustand.
- **Retention:** mindestens das 65-Tage-Lesefenster des Fallbacks plus Puffer — der B3-Rebuild, die
  Transparenz (12.) und die Fehlmeldung (11.) hängen an der Historie. Archivierung erst danach.

Append-only trägt mehr, als beim Entwurf absehbar war: die Lieferketten-Transparenz (12.) und die
Soll/Ist-Prüfung (11.) brauchen die *Historie* der Lieferungen, nicht ihr Ergebnis.

Nicht übernommen: `num_ausschuettung`/`dat_zahltag` (die Ausschüttungsangaben im Preisfile kommen
aus den Stammdaten) und `intervall` (produktiv seit 2017 ersatzlos geleert).

### 4. Welche Lieferung sich durchsetzt — nur für den Sammelreport, nicht für `kurs`

Der Sammelreport-Lauf bildet aus den Zeilen seiner Lieferungen die Menge, die in das File geht:

1. Sortierung nach Job-Ankunftszeit, innerhalb des Jobs nach `zeilen_nr`.
2. **Letzte Lieferung gewinnt** pro `(ISIN, Preisdatum, Währung, Code, Aktion)` — datumsgenau.
   Verschiedene Preisdatümer zum selben Fonds sind **kein** Konflikt, sondern zwei Fakten (im
   Beispielreport 107 Korrekturen an einem Tag).
3. **D/N-Verrechnung** — siehe unten.

**Warum nur für das File.** Ein File darf keine zwei widersprüchlichen Zeilen zum selben Schlüssel
enthalten, und sein Footer zählt. `kurs` ist eine Tabelle: sequenzielle Upserts in
Ankunftsreihenfolge konvergieren auf denselben Zustand wie „letzte gewinnt". Welche Lieferung sich
durchsetzt, ist damit ein **Datei**-Anliegen. Das ist der Grund, warum die Sync-Stufe ohne sie auskommt (8.).

Die D/N-Regeln des Altsystems (`Check4DeleteInTmp`, `M_INSERT.CPP:4138-4271`) — präziser als in der
Vorversion dieses Dokuments beschrieben:

| Konstellation | Ergebnis |
|---|---|
| `D` trifft auf ein früheres `N` mit gleichem Schlüssel | das `N` fällt weg |
| **danach**, und nur dann: Schlüssel weder persistiert noch in einem früheren Lauf des Tages berichtet | das `D` fällt ebenfalls weg (`INFO_IGNORE_DEL`) |
| **danach**: Schlüssel persistiert oder in einem früheren Lauf berichtet | das `D` bleibt und wird `I3` |
| `D` **ohne** vorheriges `N` desselben Tages | läuft ungeprüft durch und wird `I3` |
| `N` trifft auf ein früheres `D` | das `D` fällt weg |
| innerhalb einer Datei: einem `D` folgt weiter unten ein Nicht-`D` mit gleichem Schlüssel | das `D` fällt weg |

Die zweite Zeile ist die eigentliche Legacy-Regel, und sie ist **enger**, als ich sie zuerst
beschrieben habe: der `kurs`-Lookup passiert nur in dem Zweig, in dem ein `D` gerade ein `N`
desselben Tages storniert hat. Fachlich: „geliefert und noch am selben Tag zurückgezogen, bevor
etwas rausging" ist ein No-op, und beides fällt weg.

Neu ist, woran „schon berichtet" gemessen wird: nicht mehr an `kurs` (das ist jetzt untertags
aktuell und damit kein Maß für „hat der Bezieher es gesehen"), sondern am **Publikationsprotokoll**
(8.).

Folge der Verschiebung in den Lauf: die vier `INFO_DEL_*`-Meldungen stehen nicht mehr im
`info.log` des Lieferanten. Vertretbar, weil es Infos sind, die das Urteil `ERROR`/`INFO` nicht
berühren, die Texte OeKB-Interna beschreiben, und sie über 12. sichtbar bleiben. Aufgegeben wird die
Korrekturschleife innerhalb des Tages.

Die Verrechnung, das Publikationsprotokoll und der Delta-Mechanismus gelten **einheitlich auch für
die Solvabilitätssätze** (`S`/`S2`/`S3`, ausgehend `S1`–`S3` bzw. `D1`–`D3`); sie unterscheiden sich
nur im Ausgabestrom (`solva.csv`, siehe F).

### 5. Zwei Sammelreport-Läufe pro Tag

Identität über die geerbten `Job.keyDate` und `Job.dailyRunNumber` — der Unique-Index
`ux_jobs_type_key_date_daily_run_number` erzwingt sie. Beide Zeiten konfigurierbar
(Diskussionsstand: ~14:00 und ~16:00).

Ein „Sammelreport" ist *alles bis zu einem Stichzeitpunkt Gesammelte* — die Preise **und** die
Plausi. Es gibt dafür einen **eigenen Bezieherkreis**, nicht identisch mit den Lieferanten; dieser
Kreis bekommt zwei Reports, je einen pro Lauf.

Davon strikt getrennt: die **Rückmeldung an den Lieferanten** für seine eigene Datei. Die geht
sofort raus, pro Lieferung, aus der ersten Stufe der Lieferkette. Zwei Kommunikationswege, zwei
Adressaten, zwei Taktungen — und diese Trennung ist der eigentliche Gewinn gegenüber dem Altsystem.

Damit entfällt das heutige manuelle **Stoppen des Batchs** bei einer gemeldeten Verspätung: eine um
15:30 eingelangte Lieferung bleibt einfach auf `sammelreport_job_id IS NULL`. Fällt Lauf 2 aus, ist
sie morgen dran — statt verloren. Das ist Markus Punkt 5 wörtlich: „Alles was zu einem bestimmten
Zeitpunkt vorhanden ist wird verarbeitet, der Rest am nächsten Tag."

**Kein Vollständigkeits-Trigger.** Ein früherer Entwurf wollte Lauf 1 vorziehen, sobald alles
Erwartete da ist. Verworfen: der Lauf darf in jedem Fall starten, und die Soll-Menge gehört
ausschließlich in den Fehlmeldungs-Job (11.). Der Eingang kennt keine Vollständigkeit.

### 6. Lauf 2 liefert ein Delta

Lauf 1 hält den Zwischenstand, Lauf 2 nur noch das Delta; was nach Lauf 2 kommt, geht morgen in
Lauf 1 (Markus Punkt 2).

| | Lauf 1 | Lauf 2 |
|---|---|---|
| Eingangsmenge | alle Lieferungen bis Cutoff 1 | nur Lieferungen zwischen Cutoff 1 und Cutoff 2 |
| `tmp_if_last`-Fallback | **ja** — Fonds ohne heutigen Preis bekommen ihren letzten bekannten | **nein** |
| Preisfile | Zwischenstand, vollständig | Delta |
| Plausi-Report | über die Menge von Lauf 1 | über die neuen Lieferungen |

Der Fallback darf in Lauf 2 nicht wiederholt werden — sonst erscheint jeder Fonds ein zweites Mal
und das Delta ist keins mehr. Dass dabei **nichts verloren geht**, folgt aus einem Invariant:

| Fall | Lauf 1 | Lauf 2 | Ergebnis beim Bezieher |
|---|---|---|---|
| X liefert den ganzen Tag nicht | Fallback (alter Schlüssel, alter Wert) | nichts | hat den Fallback aus Lauf 1 |
| X liefert vor Cutoff 1 | echter Preis, **kein** Fallback (Anti-Join greift) | nichts | korrekt |
| X liefert zwischen den Cutoffs | Fallback | echter Preis (anderes Preisdatum) | beide Schlüssel, korrekt |
| späte Korrektur für ein älteres Datum, X hat heute keinen Preis | Fallback | die Korrektur ist eine **Lieferung**, also im Delta | korrekt, nur nicht als Fallback |

Der Invariant: **der Fallback-Wert kann sich nur durch eine Lieferung ändern, und jede Lieferung ist
im Delta.** Ein zweiter Fallback-Durchlauf würde also entweder dasselbe wiederholen oder etwas
ausgeben, das das Delta schon enthält.

Eine Ausnahme betrifft nicht den Fallback selbst, sondern seine Rücknahme — siehe die Auflage zum
Publikationsprotokoll in 8. Und falls der Fallback einem anderen Zweck dient als angenommen, fällt
der Invariant: offener Punkt N.

Warum das trägt:

- Das Gegenargument der Vorversion („bei einem Delta bräuchten die Identifier einen neuen
  Bezugspunkt, sonst steht `I2`, wo `I4` hingehört") ist widerlegt: **es gibt kein `I4`**, und
  `I2` ist ein Upsert.
- Ein Bezugspunkt wird nur für **einen** Fall gebraucht: ein `D` in Lauf 2 auf einen in Lauf 1
  berichteten Preis. Dafür gibt es das Publikationsprotokoll (8.). → offener Punkt D entschieden.
- Der Fehlerfall bleibt gutartig: wer das Lauf-2-File verpasst, hat den **vollständigen**
  Zwischenstand von Lauf 1 — veraltet, aber in sich stimmig.
- Der Vertrag wird **einfacher**. Das Ersatz-File hätte die Zusage gebraucht, „alles für das
  Kursdatum im Header zu verwerfen und die Datei neu anzuwenden". Das Delta braucht nur „Files in
  Reihenfolge anwenden" — die natürliche Semantik eines Operationsformats.
- Lauf 2 ist klein (die Nachzügler) statt ~4200 Zeilen plus Fallback.
- Legacy hat den Mechanismus sogar schon: `szEintragezeit` schränkt die Selektion auf
  `eintragezeit > '<zeitpunkt>'` ein und „erlaubt so eine inkrementelle Erstellung; im
  Fondspreis-Pfad wird er nicht gesetzt" (`m_fp_rec.CPP:2579-2584`, Ist-Analyse 4.5).

Ein Sonderfall löst sich von selbst: Lauf 1 gibt den Fallback-Preis mit altem Preisdatum aus, in
Lauf 2 kommt der echte Preis für heute. Zwei verschiedene Schlüssel, zwei gültige Fakten, der
Bezieher hat beide — identisch zum Altsystem.

### 7. Statusmodell

Siehe **Die Jobs**. Kurz: die fünf Standardwerte des Job-Systems plus `sammelreportJob` und
`rueckmeldungGesendetAt`. `PUBLISHED`, `READY_FOR_BATCH` und die vier eigenen Fortschrittswerte sind
gestrichen. Der Status beschreibt den **Job**, nicht seine Zeilen — eine Lieferung kann berichtet
sein, während einzelne ihrer Zeilen sich nicht durchgesetzt haben.

Fehlerfälle, die das Modell tragen muss:

| Fall | Verhalten |
|---|---|
| Lauf 2 fällt aus | `sammelreport_job_id` bleibt null, morgen Lauf 1 |
| Sync-Stufe hängt | der Job ist nicht `COMPLETED`, der Lauf nimmt ihn nicht mit — er geht im nächsten Lauf |
| Kennzahlen-Stufe bleibt unvollständig | kein Fehler; der Job wird `COMPLETED`, der Sweep holt den Rest aus den Daten |
| Lieferung trifft nach Lauf 2 ein | morgen |
| Lauf scheitert **nach** dem Claimen | die geclaimten Lieferungen tragen die `sammelreport_job_id` des gescheiterten Laufs und wären für `IS NULL` unsichtbar. Der Folgelauf (`repeatedFromJob` auf ihn) **übernimmt sie** zusätzlich zur `IS NULL`-Menge |
| Lauf wird wiederholt | zwei verschiedene Operationen — siehe **Reproduzierbarkeit**. „Neu laufen lassen" ist ein neuer `PreisSammelreportJob` mit gesetztem `repeatedFromJob` |

### 8. Einspielung nach `kurs` als Stufe der Lieferkette

**Geändert.** Der Sync ist kein terminierter Job mehr, sondern die zweite Stufe des
Preismeldungs-Jobs. Er läuft, sobald die Lieferung geprüft ist.

Der Grund, dass das geht: **die Sync-Stufe braucht `WirksamePreismeldungen` nicht** (4.). Upserts in
Ankunftsreihenfolge sind last-wins; `D` auf eine vorhandene Zeile löscht, `D` auf eine fehlende ist
ein No-op, `N` nach `D` fügt wieder ein. Der Endzustand ist derselbe.

Und die Ankunftsreihenfolge muss dabei **nicht** eingehalten werden — sie wird über den monotonen
Guard auf `preis_herkunft` erzwungen (siehe **Zwei Server, ein Pool** unter *Die Jobs*). Die Stufe
darf damit auf beiden Servern voll parallel laufen. `preis_herkunft` ist das dritte eigene Artefakt
neben Inbox und Publikationsprotokoll, und das kleinste: vier Schlüsselspalten plus `job_id` und
`angekommen_am`.

Der Berechtigungsfilter — diese Logik gehört in die Stufe, nicht in die Tabelle:

- ISIN in IFAS nicht auflösbar → `pool_if_kurs`, `kurs` unberührt
- Preiswährung ≠ Fondswährung → nicht nach `kurs`
- TEST-ISIN, C-Plan, AIF, Fonds in Liquidation → Ausschlüsse (`InsPreise*`-Schalter)
- vorläufiger Fonds mit `R`-Wert → Aktivierungsversuch, bei Misserfolg `pool_if_kurs`
- Löschungen: `DeleteKurseReally` in `kurs`, bei `R` zusätzlich die abhängigen Kennzahlen,
  `del_protokoll`

**Legacy tut hier schon dasselbe.** `cPreiseKennzahlen::MakePreiseEinzel` (`preisekennzahl.cpp`,
gehört zu `preise.e`) läuft über die Preissätze und ruft inline `PreiseNachrechnung()` und danach
`WriteLastKurse()` (`:2500,:2512`). Die Einspielung ist also schon pro Satz organisiert; nur
terminiert war sie als Tagesjob-Schritt.

**Was von der „materialisierten Tagesmenge" übrig bleibt: das Publikationsprotokoll.** (Der Begriff
„Tagesmenge" stammt aus Runde 1 und ist seit Runde 4 ungenau — Lauf 2 ist ein Delta, also gerade
nicht die Menge des Tages. Gemeint ist die Menge **eines Laufs**.) Sein
einziger Zweck ist der Bezugspunkt aus 6.: je `(ISIN, Preisdatum, Währung, Code)` festhalten,
in welchem Lauf er als `I2` oder `I3` hinausgegangen ist. Kleiner und ehrlicher benannt als
„Tagesmenge", und ein Feld am Job reicht dafür nicht — der Bezug muss schlüsselgenau sein.

Die Ausgabefilter (`veroeffentlichung`, `cod_art_f`, `FONDS_ZGRU`, Zielgruppe) werden auf das `I3`
genauso angewandt wie auf das `I2`. Dadurch wird ein nie berichteter Preis auch nie zurückgenommen,
ohne dass der Lauf das gesondert wissen muss.

**Auflage: das Protokoll wird vom File-Writer gefüttert, nicht aus `WirksamePreismeldungen`.** Der
`tmp_if_last`-Fallback aus Lauf 1 (9.) stammt nicht aus den wirksamen Preismeldungen, sondern aus
der Projektion —
eine Implementierung, die das Protokoll aus den wirksamen Preismeldungen ableitet, würde Fallback-Zeilen
übersehen. Dann greift der `I3`-Bezug aus Punkt D für genau diese Zeilen nicht:

> Lauf 1 gibt den Fallback für (X, T−3) aus — einen Preis, der **nie in `kurs` gelandet** ist
> (unbekannte ISIN, Währungsabweichung; genau solche Werte trägt `tmp_if_last`). Um 15:00 kommt ein
> `D` für (X, T−3). Die Legacy-Regel prüft `kurs`, findet nichts, verwirft das `D` — und der Bezieher
> behält einen zurückgezogenen Preis.

Eine Zeile Spezifikation, aber sie entscheidet über ein stilles Auseinanderlaufen.

Zwei Kosten der Verlagerung:

- **`del_protokoll`-Rauschen.** Bei „`N` um 08:00, `D` um 09:00" schreibt Legacy nie nach `kurs`;
  wir schreiben und löschen wieder. Endzustand identisch, aber IFASNXT bekommt eine Löschung für
  etwas, das es nie gesehen hat. Relativiert: `CONFIG.INI/Del_Protokoll` ist per Default `0`
  (Ist-Analyse 5.3) — produktiven Wert prüfen.
- **Mehrfachnachrechnung.** Drei Korrekturen an einem Fonds an einem Tag heißen dreimal
  `Nachrechnung(daTag, daEndTag)`, und `daEndTag` ist „heute". Legacy hat dasselbe Verhalten, es ist
  keine Regression, aber verschwenderisch.

Nicht durch eine Transaktion abgedeckt: die Verteilung. MFT-Upload, NetApp-Archivierung und
`pr_ready.txt` liegen außerhalb; Legacy hat dasselbe Problem und löst es nicht.

### 9. `tmp_if_last` ist eine Projektion, kein Eingang

Die einzige tmp-Tabelle, die fachlich überlebt — aber nicht auf dem Weg nach `kurs`. Je
`(ISIN, Währung, Code)` die Zeile mit dem höchsten `preisdatum`, ohne Löschsätze und ohne die drei
Fondsklassen-Ausschlüsse (siehe unten).

#### Genau ein Leser

`cFondsRecord::StartTmpKursSchleife(nQuellTab, …)` (`m_fp_rec.CPP:2554-2576`) hat drei Zweige:

| `nQuellTab` | Quelle | Aufrufer |
|---|---|---|
| `0` | `pszTempTabelle[nInOrAusland]` = `tmp_if_kurs` für Inland | `DoFiles()` — der normale Lauf |
| `1` | **`tmp_if_last`**, Anti-Join gegen `tmp_if_kurs`, 65-Tage-Filter | `DoFiles(1)` — der Fallback |
| `3` | `pszTempTabelle[2]` — Array hat zwei Elemente, also Out-of-bounds | nirgends aufgerufen |

`M_FP_DLD.CPP:127` ruft genau `DoFiles(1)` und `DoFiles()`. Die Lauf-1-Selektion ist damit der
**einzige** Leser — nicht die Plausi (die liest für Inland `tmp_if_kurs`), nicht die Kennzahlen,
nicht die Einspielung.

Vollständig, damit die Portierung nichts übersieht:

- **schreiben:** `WriteLastKurse` (`preisekennzahl.cpp:1218ff`), Variante `WriteLastKurse2`
  (`:1025ff`), Löschen im `R`-Löschpfad (`:1939`)
- **aufräumen, zwei Pfade:** `CleanUpTmpIfLast` (`m_fp_rec.CPP:5555ff`, nur Inland) und ein zweiter
  in der Einspielung (`c_preise.cpp:250,450-472`)
- **ISIN-Umbenennung:** `ISIN_UPD.CPP:228` pflegt `txt_bez` mit — Wartungswerkzeug, kein Verbraucher

#### 65 ist ein Lesefilter, 35 die einzige Löschregel

*Korrektur meiner früheren Beschreibung.* `Tage_TmpIfLast` (65) steht als
`l.dat_kurs > dateadd(dd, -65, getdate())` in der **Leseabfrage**; gelöscht wird nur nach
`Tage_TmpIfLast_Beendete` (35 Tage nach Fondsende) und bei leerer ISIN. Ein lebender Fonds, der
aufhört zu liefern, behält seine Zeile für immer — sie wird nach 65 Tagen nur nicht mehr gelesen.
Die Tabelle bleibt trotzdem klein: **28.264 Zeilen / 3,1 MB** produktiv
(`Ifas/admin/spaceused/csv/kurs.csv:45`).

#### Die Ausschlüsse liegen im Aufrufer

`WriteLastKurse` hat **keine** eigenen Ausschlüsse: Delete-dann-Insert je Preis-Typ mit Wert,
`cod_ex` hart `'N'`, Löschschlüssel ohne `dat_kurs`. Die Ausschlüsse sind drei `continue` im
Aufrufer `RunTmpPreise` (`c_preise.cpp:113-132`): C-Plan, AIF und Fonds in Liquidation, jeweils
hinter `InsPreiseCPlan` / `InsPreiseAIF` / `InsPreiseFondsInLiquidation`. Alle drei brauchen
**Stammdaten**.

Und `WriteLastKurse` liegt **außerhalb** von `if (nRet == 1)`, hängt also nicht am Erfolg des
`kurs`-Writes. Genau deshalb trägt `tmp_if_last` Werte, die `kurs` nie sieht (unbekannte ISIN,
Währungsabweichung) — und ist **nicht** aus `kurs` ableitbar. Dieselbe Einsicht trägt 11.: `kurs`
sieht nicht alles, was geliefert wurde.

#### Warum es die Inbox nicht sein kann

Der Delete-vor-Insert-Schlüssel enthält **kein** `preisdatum`. Es gibt genau einen Platz je
(ISIN, Währung, Code); eine spätere Korrektur für ein *früheres* Datum verdrängt den jüngeren Preis,
und kein Filter auf der Leseseite holt ihn zurück. Zusätzlich setzt `WriteLastKurse` `cod_ex` hart
auf `'N'` — Löschsätze wären strukturell unsichtbar.

#### Nebenläufigkeit

Der Guard aus **Zwei Server, ein Pool** gilt auch hier, und zwar lexikografisch über
`(preisdatum, angekommen_am)`: Legacys „nur wenn Preisdatum neuer" würde eine Korrektur zum
*gleichen* Preisdatum verwerfen. Weil `tmp_if_last` unsere eigene Projektion ist, kann die Zeile
`angekommen_am` mitführen. Und weil `letzte_preise` in Postgres liegt, ist der Guard hier ein
einzelnes bedingtes Update in der eigenen Zeile — keine Klammer-Transaktion nötig.

#### Initialbefüllung

Beim Start — des Parallelbetriebs wie später des Echtbetriebs — ist `letzte_preise` leer. Ohne Seed
verfehlt der Lauf-1-Fallback 65 Tage lang fast alle Fonds, und der B3-Diff gegen die Legacy-Tabelle
wäre von Tag 1 an rot. Deshalb ein einmaliger Migrationsschritt: Seed aus `kurs..tmp_if_last` des
Altsystems, mit synthetischem `angekommen_am` (Seed-Zeitpunkt); ab dann führt die Kette die Tabelle
selbst.

#### Wozu der Fallback da ist, steht nirgends

Der Mechanismus ist dokumentiert, der **Zweck nicht**. Der Fallback schickt für einen Fonds ohne
heutigen Preis dessen letzten bekannten Preis als `I2` mit dem *alten* Preisdatum — weil `I2` ein
Upsert ist, beim Bezieher also ein No-op mit gleichem Schlüssel und gleichem Wert. Zwei plausible
Zwecke, keiner belegt: **Robustheit** (wer ein File verpasst hat, holt den letzten Preis nach) oder
**eine Zeile je Fonds je Tag** (ein Abnehmersystem, das das erwartet). Siehe offener Punkt N — die
Antwort entscheidet, ob Lauf 2 den Fallback doch braucht.

### 10. Kennzahlen: Stufe plus Sweep

Die Kennzahlen (berichtigte Kurse, Reinvestitionsfaktoren, Performance, Volatilität,
Risikokennzahlen) kommen nach IFAS13, **zweigeteilt**:

- als **Stufe** des Preismeldungs-Jobs — ein optimistischer Versuch direkt nach der Einspielung,
- als **Sweep-Job** — sucht Preise ohne Kennzahl und rechnet sie, wann immer er läuft.

**Legacy macht die Stufe schon.** `MakePreiseEinzel` ruft `PreiseNachrechnung()` inline pro
Preissatz. Aber mit einem Riegel: `if (cPrTyp.daPreisDatum >= daStichtag) return 0;
// Keine Nachrechnung wenn nicht eine Korrektur` (`preisekennzahl.cpp:3049`). Nur **Korrekturen**
werden sofort nachgerechnet; die Preise für den Stichtag selbst bleiben `run_calc` (Tagesjob-Schritt
7) überlassen — und genau der wartet auf die EZB.

**Die EZB-Abhängigkeit ist partiell.** Der Referenzkurs wird ausschließlich für die
**währungsbereinigte** Variante von Performance und Volatilität bei **Fremdwährungsfonds**
gebraucht:

- `if (strcmp(szWaehrung, "EUR") != 0)` vor `CalcCurrency` (`fondskennzahl.cpp:2208`) und an
  `:3386`,
- `Kurse2EUR4AbsVol` steigt bei EUR sofort aus: `if (strcmp(szWaehrung, "EUR") == 0) return 0;`
  (`:4843`).

Für einen EUR-Fonds ist der Referenzkurs nirgends im Spiel. Die Stufe kann für die weit überwiegende
Menge also sofort fertig rechnen; für Fremdwährungsfonds ohne Referenzkurs bleibt sie unvollständig,
und der Sweep holt es nach. Das setzt **C1** voraus (Invalidierung, selbstheilend) — siehe offener
Punkt C.

Weiterhin gilt:

- **Keine Abhängigkeit zu den Preisfiles.** Die Selektion der Filegenerierung liest `tmp_if_last`
  und die Inbox, beide ohne berichtigten Kurs. Und die Filegenerierung liest `kurs`
  **überhaupt nicht** — in `m_fp_rec.CPP` und `M_FP_DLD.CPP` gibt es keinen einzigen
  `kurs..kurs`-Zugriff. *Korrektur gegenüber der Vorversion, die behauptete, `kurs` werde „nach
  Existenz gefragt".*
- **Auch keine Abhängigkeit zur Plausi.** `pdPreis_ber` wird in
  `cPreisPlausi::BerichtigePreise()` (`m_fplausi.cpp:193-208`) lokal als
  `pdPreis * dSplitfaktor (+ dAusschuettung)` aus dem *gelieferten* Preis gerechnet. Das
  Kennzahlenergebnis wird nirgends gelesen.
- **Basis ist `kurs`, nicht `tmp_if_last`.** Kennzahlen sind Zeitreihen; `tmp_if_last` hat keine
  Historie, ist auf die ISIN geschlüsselt und hat keine Ergebnisspalte.
- **Legacy trennt fachlich:** `CalcCPlan`/`InsPreiseCPlan`, `CalcAIF`/`InsPreiseAIF`,
  `CalcFondsInLiquidation`/`InsPreiseFondsInLiquidation` — Preise werden eingespielt, Kennzahlen
  nicht gerechnet. Zwei Geltungsbereiche, zwei Schalter.
- **Historientreue:** `StetigeVolaAb` und `PerfYtdFbY1Neu` (beide `2007.01.01`) sind
  datumsgesteuerte **Formelwechsel**. Eine Nachrechnung ist „die Historie mit den Regeln
  nachrechnen, die zu jedem Zeitpunkt gegolten haben" — dieselbe Klasse von Anforderung wie bei der
  STM-Recalc-Historientreue.

### 11. Fehlmeldung: erwartete Lieferung gegen tatsächliche (Markus Punkt 4)

Ein Tagesjob zu einem definierten Zeitpunkt. Alles, was bis dahin nicht geliefert wurde, gilt als
fehlend.

- **Soll** — die für den Stichtag erwarteten Lieferungen.
- **Ist** — die Inbox.
- **Ergebnis** — die Differenz als Liste `(Lieferant, ISIN, Code)`, versendet als Mail je Lieferant
  („Preis für Isins XYZ fehlt") bzw. als Sammelmail an die Fachabteilung.

**Die Datenbasis ist nicht *eine* Tabelle:**

| Quelle | Rolle | Beleg |
|---|---|---|
| `ifas..INV.preismeldung` → FK `ifas..preismeldung` | Meldeverpflichtung je Fonds | `INV.cr:165`, `cc_INV.cr:325` |
| `ifas..INV.KAG` | Fonds → KAG | |
| `kurs..KAG_lieferanten (KAG, liefer_id)` | KAG → Lieferant | `KAG_lieferanten.cr` |
| `kurs..lieferanten.liefer_typ = 'F'` | grenzt auf **Fondspreis**-Lieferanten ein | `m_lieferanten.cpp` schließt `liefer_typ <> 'F'` aus der Steuerdatei-Bezieherliste aus; `upd_lieferanten_fpp.cr` setzt `'F'` für alle `fp_*`-Accounts |

Die Fondsselektion steht fertig in `m_plausi4tag_preise.cpp:DoCheck()`: `INV.status = 'A'`,
`cod_art_f in ('FOND','TECH','C-PL')`, am Stichtag lebend, `KAG < 10000`, und
`INV.preismeldung = 'TGL'`.

**Die Zuordnung wurde nie erzwungen.** `cProgParameter::nCheckKag` ist per Default `0`
(`c_param.cpp:39`), und `make_einzel.awk` ruft `preis_ins.e` explizit mit **`-K0`** auf — für `-R0`
und `-R1`. `ERR_ISIN05` („User %s ist nicht berechtigt für ISIN (%s) zu liefern", `c_param.cpp:408`)
kann damit nie feuern. `KAG_lieferanten` ist gepflegte Absicht, keine Garantie. Das ist der Grund
für offenen Punkt J: eine Mail an „den" Lieferanten stützt sich auf eine Zuordnung, die das System
nie geprüft hat.

**Kein historischer Nachweis in der DB.** `kurs..kurs` führt keine `liefer_id` — nur
`tmp_if_kurs`, und die wird täglich geleert. Wer wann für welche ISIN geliefert hat, steht nur in
den NetApp-Archiven der Eingangsfiles.

**Was heute schon existiert und die drei Lücken.** Tagesjob-Schritt 9 (`preis_dld.e -P2`,
`m_plausi4tag_preise.cpp`) ist bereits ein Fehlmeldungs-Report:

| | heute | gewünscht |
|---|---|---|
| Datenquelle | `kurs..kurs` mit `cod_fliesscode = 'R'` — erst *nach* der Einspielung | die Inbox |
| Zeitfenster | letzter Preis ist 3 bis 11 Börsetage alt (`Preis_MinTage4Meldung`/`MaxTage`) | „heute fehlt" |
| Empfänger | Fachabteilung | Fachabteilung und/oder Lieferant |

### 12. Transparenz der Lieferkette im Sammelreport (Markus Punkt 3)

Der Report soll zeigen, „was alles geliefert wurde, zB (New, Delete, New...)" — die **Folge** je
Preisschlüssel, nicht nur das aufgelöste Ergebnis. Die Inbox liefert das ohne Zusatzaufwand:
append-only, `job_id` + `zeilen_nr`, Ankunftszeit und Lieferant am Job.

Ein neuer Abschnitt listet je `(ISIN, Preisdatum, Währung, Code)` mit mehr als einer Lieferung des
Tages die Kette in Ankunftsreihenfolge, mit Lieferant, Zeit und Aktion, und markiert die Zeile, die
sich durchgesetzt hat. Nebeneffekt: die vier `INFO_DEL_*`-Meldungen aus 4. werden hier
sichtbar.

Bei zwei Läufen zeigt Report 2 die Ketten zwischen den Cutoffs; eine Kette über den Cutoff hinweg
(`N` vor Lauf 1, `D` danach) muss den Vorlauf-Teil mit ausweisen, sonst ist die Rücknahme dort
unerklärlich.

### 13. Preis für einen beendeten Fonds bleibt zulässig (Markus Punkt 7)

**Kein Verhaltenswechsel** — das Altsystem macht es schon so; die Anforderung ist eine Auflage und
ein Testfall. `M_INSERT.CPP:2935-2958`: abgelehnt wird nur `Preisdatum > fonds_ende`, mit
`ERR_DATE04` und Zähler `BUG_DATE`. Zwei Details:

- Die Prüfung greift **nur für Code `R`** (`M_INSERT.CPP:2932`), obwohl der Kommentar darüber
  „2012.07.27 … Q und R Werte … 2012.10.23 auch keine T Werte" behauptet. Vor der Portierung mit der
  Fachabteilung klären, ob Kommentar oder Code gilt.
- Der Spiegelfall ist keine Ablehnung: `R` vor `daFonds_beginn` erzeugt nur `INFO_DATE02` nach
  `oekbinfo.log` (JIRA 7897, `M_INSERT.CPP:2962-2987`) — der Lieferant sieht es nicht.

IFAS13 kann das heute nicht prüfen: `CsvPreismeldungValidations` hat keinen Stammdatenzugriff.

### 14. Die Kursabweichung zwischen den Tagen entfällt (Markus Punkt 9)

Gemeint ist **`makeAbweichung`**, Abschnitt 15 des Plausi-Reports (`m_fplausi.cpp:2377-2520`) —
beide Kursdatümer, beide Preise, Abstand in Tagen, Abweichung in Prozent, bei Ausschüttung oder
Split zusätzlich `BerErrWert … (Diff.)`.

Mit dem Abschnitt entfallen `cPreisChecker` im Fondspreis-Pfad, die Datenbeschaffung der Toleranzen
`ifas..preise_check` / `preise_check_faktor`, und `cPreisPlausi::BerichtigePreise()` (kein anderer
Verbraucher).

**Nicht** betroffen: Abschnitt 17 `makeCorrelationERZ` (`Plausi_Abweichung_ERZ`, Default 20 %) — ein
Vergleich *innerhalb* eines Tages zwischen Codes. Mit Markus bestätigen, dass nur Abschnitt 15
gemeint ist.

### 15. Ausschüttung ohne vorhandenen Preis (Markus Punkt 8)

Zwei Teile. **Teil 1, im Sammelreport: portieren wie im Altsystem** — die Plausi-Abschnitte 18–20
(`makeAusOhnePreis`, `makeVorlAusOhnePreis`, `makeVorlAusIdentDemPreis`).

**Teil 2, zur Eingangszeit: offener Punkt H.** Markus formuliert „wenn eine Ausschüttung … gemeldet
wird", also eine Rückmeldung beim Ausschüttungs-Eingang. Anderer Auslöser, anderer Empfänger, und es
greift in die Ausschüttungs-Domäne.

---

## Offene Entscheidungen

### A. Wann läuft der Sync? — **geschlossen**

Pro Lieferung, sofort, als Stufe der Lieferkette (8.). Die ursprüngliche Frage („braucht jemand
`kurs` untertags aktuell?") ist damit erledigt: `kurs` **ist** untertags aktuell, unabhängig davon,
ob jemand es braucht.

Was als Auflage bleibt, steht in **Die Jobs** unter *Zwei Server, ein Pool*: der monotone Guard.
Serialisiert werden muss die Stufe **nicht**.

### B. `tmp_if_last` — **entschieden: B3, geführte Tabelle plus Neu-Herleitung**

| Option | Folge |
|---|---|
| **B1 — nur geführte Tabelle** | Lauf 1 liest eine Zeile je Schlüssel. Entscheidung zum Schreibzeitpunkt festgehalten, also kein retroaktiver Effekt. Aber: **kann still driften** — eine fehlgeschlagene Sync-Stufe hinterlässt Inbox-Zeilen ohne Eintrag, und der Fallback vergisst den Fonds unbemerkt. |
| **B2 — nur Abfrage** | Kein Zustand, keine Drift, kein Aufräumjob. Aber: die drei Fondsklassen-Ausschlüsse müssen mit Stammdaten-Joins nachgebaut werden; die Abfrage ist **retroaktiv sensitiv** (wird ein Fonds heute AIF, verschwindet er rückwirkend für 65 Tage — Verhaltensänderung gegenüber Legacy); und die **Retention der Inbox wird tragend** (wer nach 30 Tagen archiviert, verkürzt still den Fallback). |
| **B3 — geführt, plus Rebuild aus der Inbox** | B1 im Normalbetrieb, B2s Abfrage als Reparaturwerkzeug. Leseseite bleibt einfach, Drift ist erkennbar und behebbar, ein Konsistenz-Check „Tabelle gegen Herleitung" ist ein billiger Testfall. Der Rebuild ist retroaktiv — für ein Reparaturwerkzeug in Ordnung, muss aber dokumentiert sein. |

**Entschieden: B3.** Ausschlaggebend ist ein Argument, das in den früheren Runden fehlte: der
**Parallelbetrieb**. `tmp_if_last` ist mit 28.264 Zeilen / 3,1 MB winzig und in sich abgeschlossen —
ein zeilenweiser Diff gegen die Legacy-Tabelle ist trivial und wäre ein tägliches Regressionssignal,
genau wie die Return-File-Diffs im STM-Parallelbetrieb.

Bei B2 gibt es **nichts zu vergleichen**: man müsste das Abfrageergebnis materialisieren, um zu
diffen, und das ist B1. Schlimmer, B2 würde die Legacy-Tabelle systematisch *nicht* treffen, sobald
sich Stammdaten geändert haben. Für die Vergleichbarkeit ist B2 also nicht neutral, sondern
schlechter.

### C. Kennzahlen — Invalidierung oder Auftragsübergabe? — **C1 faktisch gesetzt**

Mit der Zweiteilung aus 10. (Stufe plus Sweep) braucht der Sweep ein Kriterium, an dem er erkennt,
was zu rechnen ist. C1 liefert es: der Sync räumt bei *jeder* Änderung die abhängigen Kennzahlen
weg, nicht nur bei `R`-Löschungen; dann sind fehlende und veraltete Kennzahlen derselbe Fall, und
der Sweep sucht schlicht Preise ohne Kennzahl. Beliebig terminierbar, wiederholbar, selbstheilend.

Preis: zwischen Sync und Nachrechnung sind die Kennzahlen **abwesend** statt veraltet. Mit
Entscheidung 14 hat das keinen Verbraucher im Report mehr; für andere Verbraucher von Kennzahlen
noch zu prüfen — das ist der Rest von C.

C2 (Arbeitsliste) und C3 (Ableitung aus `kurs.guelt`) bleiben als Reparaturpfade interessant: C3
deckt Korrekturen und Neuwerte ab, **nicht** Löschungen, taugt also für „rechne alles nach, was seit
X berührt wurde", nicht als vollständiger Auslöser.

**C1b — markieren statt löschen** (aus der Diskussion, eingearbeitet 2026-09-02): eine
Stale-Markierung, damit die vier externen Auswertungen weiter einen Wert lesen, statt auf Abwesenheit
zu treffen. Als Spalte `stale_since` auf den fünf Kennzahlentabellen ist das mit der
**Sybase-Schemasperre nicht umsetzbar** (M); bliebe eine eigene Postgres-Tabelle mit den als stale
markierten Schlüsseln — dann müssten die Auswertungen sie aber auch abfragen, was sie heute nicht
tun. Der Rest von C („wer liest Kennzahlen zwischen Sync und Nachrechnung?") entscheidet, ob C1b
gebraucht wird oder die Abwesenheit aus C1 akzeptabel ist.

### D. Rücknahme eines bereits berichteten Preises — **entschieden: explizites `I3`**

In einem Delta-File **ist** eine Auslassung nichts. Ein in Lauf 1 berichteter und danach per `D`
zurückgezogener Preis muss in Lauf 2 als `I3` erscheinen. Bezugspunkt ist das
Publikationsprotokoll, nicht `kurs`.

Bewusste Abweichung vom Altsystem, dessen Regel den Löschsatz in diesem Fall fallen ließe. Im
Parallelbetrieb als bekannte Abweichung führen.

Was mit den Beziehern zu klären bleibt: dass **beide** Files des Tages in Reihenfolge angewandt
werden müssen. Deutlich milder als die Zusage, die das verworfene Ersatz-File gebraucht hätte, aber
immer noch eine. Hängt an F.

### E. Ausschüttungs-Veto bei `R`-Löschungen

Heute: liegt zum Preisdatum eine Ausschüttung vor, wird die Löschung verweigert und es passiert
*nichts* — keine Löschung, keine Kennzahlenbereinigung, nur eine Zeile im Programm-Log, keine
Rückmeldung. Im Quelltext steht `// ????`.

| Option | Folge |
|---|---|
| **E1 — wie heute** | Divergenz bleibt: Preis beim Bezieher weg, in `kurs` vorhanden. |
| **E2 — früh erkennen** | Die Sync-Stufe erkennt es zur Eingangszeit und der Lieferant bekommt eine Rückmeldung, dass die Löschung nicht möglich ist. |

**Der neue Jobschnitt verbessert das:** das Veto feuert jetzt in der Sync-Stufe, also Minuten nach
der Lieferung statt am Tagesende. Eine Rückmeldung ist damit überhaupt erst möglich. Gehört in
dasselbe Gespräch wie 15./H.

### F. Dateinamen und Ready-File für zwei Auslieferungen pro Tag

Dass es zwei Auslieferungen gibt, ist entschieden. Offen ist die Benennung und das
Vollständigkeitssignal.

`preis.csv`, `solva.csv` und das eine `pr_ready.txt` sind fix. Legacy hat für Nummerierung
`-N<nr>` (laufende Nummer aus dem `event_log`), für Fondspreise ungenutzt; nur der T2S-Strom kann es
schon (`<YYYY-MM-DD_HH-MM>_preis.csv`). Die kundenseitige Formatbeschreibung
(`2025_Funddata_Provision.xlsx`, Version 2.0, gültig ab 17.11.2025) kennt **eine** Lieferung pro
Tag.

Gleiche Namen und Überschreiben ist mit dem Delta **nicht** vereinbar — ein überschriebenes
Delta-File ist verloren und nicht rekonstruierbar. Empfehlung: nummerierte Files, je ein
Ready-File. Änderung nach außen → Fachabteilung, gemeinsam mit D.

### G. LMT persistieren und weitergeben?

Das Altsystem validiert `L1`/`L2`/`L3` vollständig — Prozentkennzeichen (`ERR_LMTPROZENT1`),
Stichtag nur bei `L2` und nur bei 0 Tagen (`ERR_LMTRUECKL2`, `ERR_LMTRUECKL2_0`), Aktion `I` nur bei
`L2` (`CheckAktionL2`) — und **speichert nichts**:

```cpp
// M_INSERT.CPP:2049-2056
if (strcmp(cPrCodes.GetGruppe(cPrRecords[i].szCode), "LMT") == 0)
{
    // LMT Daten sollen derzeit nicht gespeichert werden
```

IFAS13 prüft in `CsvPreismeldungValidations` bereits **mehr** als das Altsystem. Mit der Inbox
kostet die Persistenz zwei Spalten; die Frage verschiebt sich auf **an wen weitergeben, in welchem
Format?** Heute existiert kein Ausgabestrom, der LMT transportiert — ein neuer wäre eine Änderung am
Bezieher-Vertrag (vgl. F).

### H. Ausschüttung ohne Preis — auch zur Eingangszeit?

Aus 15., Teil 2. Zu klären mit Markus/Fachabteilung:

- **Wer bekommt die Meldung** — der Lieferant der Ausschüttung oder die Fachabteilung?
- **Fehler oder Info?** Eine Ausschüttungsmeldung vor dem zugehörigen Preis ist ein normaler
  Ablauf; ein `error.log`-Eintrag würde das Delivery-Urteil auf `ERROR` kippen (mehr als 5 Zeilen)
  und wäre falsch. Vermutlich `info.log`.
- **Wogegen wird geprüft?** Gegen `kurs` — das ist jetzt untertags aktuell und damit deutlich
  brauchbarer als vorher — oder gegen die Inbox. Letzteres wäre eine neue Abhängigkeit zwischen
  zwei getrennten Domänen und bräuchte eine bewusst geschnittene Abfrage-Schnittstelle.

Der neue Jobschnitt macht die `kurs`-Variante attraktiv: `kurs` hinkt nur noch Minuten nach, nicht
einen Tag.

### I. Kennzahlen-Sweep bei fehlendem Referenzkurs

Nach 10. betrifft das nur **Fremdwährungsfonds** und dort nur die währungsbereinigte Variante von
Performance und Volatilität.

| Option | Folge |
|---|---|
| **I1 — rechnen, was rechenbar ist** | Fehlt der Referenzkurs, bleibt die währungsbereinigte Kennzahl offen, der Sweep holt sie später. Passt zu C1 und zu Markus' Grundlinie. Kein Warten, kein Timeout, keine Notbremse. |
| **I2 — Vortagskurs verwenden** | Es wird immer gerechnet, mit dem letzten verfügbaren Kurs. **Fachliche** Frage, nicht technische: es verändert die Zahlen. Legacy hat die Schraube schon: `CONFIG.INI/Referenzkurs_Tage`, Default `0`, negativ = früher (`cAReferenzkurs::InitTage()`). |

Empfehlung: **I1** als Voreinstellung, I2 als konfigurierbare Alternative. Damit ist die fachliche
Entscheidung offen, ohne zu blockieren.

Was Legacy sonst hat und was wir nicht übernehmen: eine **unbegrenzte** Warteschleife im 2-Minuten-
Takt gegen `refkursVorhanden.e -d<datum>` (`run_tagesjob.csh:519-566`) und die einmalige manuelle
Notbremse `CONFIG.INI/CalcOhneReferenzkurs`, die am Jobende von `unset_CalcOhneRefkurs.csh`
zurückgesetzt wird.

### J. Fehlmeldung — Zuordnung und Empfänger

Zu klären mit Markus/Fachabteilung; die Datenanalyse dazu läuft
(`fondspreise-lieferant-isin-analyse.sql`, 11 Sybase-Queries).

- **Ist `INV.preismeldung` die gemeinte Tabelle?** Der Code prüft auf `'TGL'`
  (`m_plausi4tag_preise.cpp:265`, die alte Prüfung auf `"U"` steht auskommentiert daneben), das
  eingecheckte Seed `ins_preismeldung.cr` kennt nur `U` („tägliche Preismeldung") und `Y`.
- **Gilt die Verpflichtung je Code oder nur für `R`?** Der bestehende Report prüft ausschließlich
  `cod_fliesscode = 'R'`.
- **Ein Lieferant je ISIN?** `KAG_lieferanten` ist n:m (PK `(KAG, liefer_id)`), und die Prüfung war
  nie aktiv (`-K0`). Bei mehreren berechtigten Lieferanten ist „wer muss liefern" nicht eindeutig.
  Und der umgekehrte Fall — ein Fonds mit Meldepflicht ohne jeden `liefer_typ='F'`-Lieferanten —
  hätte eine Fehlmeldung ohne Adressat.
- **Empfänger und Zeitpunkt** (Markus lässt beides offen: „entweder Fachabteilung oder Lieferant").

### K. Wem gehört `ASF.r_faktor`?

Ausformuliert unter **Abhängigkeiten**. Kurz: beide Domänen schreiben ihn — die
Ausschüttungs-Einspielung beim Buchen (`asfkennzahl.cpp:921,1156`), die Preis-Einspielung bei einer
Korrektur (`preisekennzahl.cpp:3072`). K1 (Ausschüttungs-Domäne), K2 (Kennzahlen-Domäne, mit
Datenmodell-Änderung) oder K3 (bewusst geteilt, mit expliziter Vorrangregel). Zu klären mit Markus,
**bevor** die Kennzahlen-Stufe implementiert wird.

### L. Vorrangregel zwischen Preis- und Ausschüttungs-Einspielung

Ebenfalls unter **Abhängigkeiten**. O1 (Ausschüttungs-Tagesjob vor Cutoff 1), O2 (Ausschüttungen
ebenfalls pro Lieferung) oder O3 (Sammelreport prüft die Vorbedingung und meldet). Empfehlung
**O1 + O3**; O3 leisten je Lauf die Plausi-Abschnitte 18–20 im Sammelreport (15., Teil 1), am
Tagesende der Fehlmeldungs-Job — und es deckt Markus Punkt 8 ab.

### M. Darf `kurs` eine Spalte bekommen? — **entschieden: nein, Sybase ist schema-gesperrt**

**Entscheidung (User, 2026-09-02):** In der Sybase werden **keine neuen Tabellen und keine neuen
Spalten** angelegt — weder im Altsystem noch in der Neusystem-Sybase; neue Tabellen kommen nach
Postgres. Die Schemata der beiden Sybase-Instanzen müssen für den Parallelbetrieb-Diff identisch
bleiben, und die Sybase läuft aus.

Damit ist M2 dauerhaft vom Tisch, nicht nur für den Parallelbetrieb. `preis_herkunft` liegt als
Business-Tabelle auf Postgres (Katalog `kurs`, **nicht** `infra` — Runde 8); den Preis dafür — die
Klammer-Transaktion über zwei DBMS samt Fehlerfenster-Analyse — beschreibt *Zwei Server, ein Pool*,
und mit der Sybase-Migration 2027 entfällt er. `kurs.guelt` umzudeuten bleibt ebenso
ausgeschlossen (C3 sieht `guelt` als Reparatursignal vor).

### N. Wozu dient der `tmp_if_last`-Fallback?

Aus Entscheidung 9. Der Mechanismus ist im Legacy-Code dokumentiert, der Zweck nicht. Weil `I2` ein
Upsert ist, ist eine Fallback-Zeile beim Bezieher ein No-op — gleicher Schlüssel, gleicher Wert.
Zwei plausible Zwecke:

| Option | Folge für Lauf 2 |
|---|---|
| **N1 — Robustheit** („wer ein File verpasst hat, holt den letzten Preis nach") | Lauf 2 braucht den Fallback **nicht**: der Zwischenstand aus Lauf 1 erfüllt den Zweck schon |
| **N2 — eine Zeile je Fonds je Tag** (ein Abnehmersystem erwartet das) | Dann müsste **jedes** ausgelieferte File vollständig sein — das widerspricht dem Delta aus Entscheidung 6 und wäre eine Rückkehr zum Ersatz-File |

Mit der Fachabteilung bzw. den Beziehern zu klären. N2 wäre die einzige bekannte Anforderung, die
Entscheidung 6 wieder aufwerfen würde — deshalb vor der Filegenerierung klären, nicht danach.

### Datenbeschaffung

- **`ifas..ASF`-Statuskollisionen** (Queries Q9–Q11) — entscheidet, ob eine vorläufige oder
  gelöschte Ausschüttung ins Preisfile geraten kann, und damit ob wir ein Legacy-Verhalten oder
  einen Legacy-Bug nachbauen.
- **Ausschüttungen ohne Preis** (Query Q12) — zeigt, wie oft der Zirkel produktiv zuschlägt und ob
  der fiktive Wert `X` dabei tatsächlich der Ausweg ist.
- **`ASF.r_faktor`-Lücken** (Query Q13) — Gegenprobe zu K.
- **Produktive `tax_code`-Zeilen.** `L1`/`L2`/`L3` fehlen in allen eingecheckten
  `insert_tax_code*.cr`; `S2`, `S3`, `X` nur in `v_preiscode`. Die real gültigen
  `untergrenze`/`obergrenze`/`max_nk`/`future`/`isinwaehrung`/`ignore_null` und Datumsgrenzen
  definieren das gesamte Prüfverhalten. **Voraussetzung für jede Eingangs-Implementierung.**
- **Produktive `ifas..preismeldung`-Zeilen** und die Verteilung von `INV.preismeldung`
  (Query Q5). Voraussetzung für 11.
- **`kurs..KAG_lieferanten` mit `liefer_typ='F'`** (Queries Q0–Q4) — beantwortet J.
- **`CONFIG.INI`:** `Referenzkurs_Tage`, `CalcOhneReferenzkurs`, `Del_Protokoll`, `Nachrechnung`.
  **`PREIS_DLD.INI`:** `Preis_MinTage4Meldung`, `Preis_MaxTage4Meldung`.
- **`AllowOldPreisFormat`, `AllowTxtExt4PreisFile`** — davon hängt ab, ob das alte Format 1
  bedient werden muss.
- **`MFT_*.INI`** — Zielverzeichnisse und Accounts sind nicht im Repo.
- **`pool_if_kurs`-Semantik** — Upsert oder Append, welcher Schlüssel? Davon hängt ab, ob der
  monotone Guard auch dort gilt (zwei Lieferungen zur selben unbekannten ISIN, außer der Reihe
  verarbeitet).
- **Vollständiger `fplausib.txt`** mit Treffern in allen Abschnitten, für die Meldungstexte.
- **Aktuelle `preis.dtd`**, wie sie tatsächlich ausgeliefert wird.
- **`datum_min`-Vergleichsrichtung** (`M_INSERT.CPP:2020,2906` vergleichen mit `> daDatumMin`,
  entgegen der Feldbeschreibung) — mit der Fachabteilung klären.
- ~~Toleranzen `preise_check` / `preise_check_faktor`~~ — **entfällt** mit 14.

---

## Abgrenzung

**Enthalten:** die inländische Kette — Eingang, Plausibilität, Filegenerierung, Verteilung,
Einspielung nach `kurs`, `tmp_if_last`, `pool_if_kurs`; die Fehlmeldung (11.); die
Kennzahlenberechnung als Stufe plus Sweep (10. legt die Naht fest, nicht die Formeln).

**Nicht enthalten:** die Formeln der Kennzahlen-/Performance-/Volatilitätsnachrechnung
(`preisekennzahl.cpp`, `fondskennzahl.cpp`, `c_calc.cpp`) — dafür fehlt eine eigene Ist-Analyse.
Ausländische Fonds (`-R1`) samt `liefer_status`/`liefer_status_gesamt` und den Mahnungen.
Meldefonds-Listen, Fristenprüfung. Stammdatenfiles Börse/Vendoren/WDBO.

**Die Ausschüttungs-Domäne ist nicht enthalten, aber die Naht zu ihr schon** — und sie ist breiter
als bis zum 2026-09-01 angenommen: `ifas..ASF` wird von dieser Kette gelesen *und* geschrieben
(`r_faktor`), und es gibt eine zeitliche Vorrangregel in beide Richtungen. Siehe
**Abhängigkeiten** sowie die offenen Punkte H, K und L.

### Landkarte des Legacy-Tagesjobs

Markus Punkt 5 fordert, dass der Tagesjob vollautomatisch läuft. Der Tagesjob ist neunteilig
(`run_tagesjob.csh`, Checkpoints `cp_tagesjob_01`…`09`, manuell gestartet aus `TAGESJOB.jam`).
Die Abgrenzung bleibt; die Landkarte macht sichtbar, was noch fehlt.

| # | Script → Programm | Inhalt | in diesem Konzept |
|---|---|---|---|
| 1 | `create_preise.csh` → `preis_dld.e -fPREISE` | Preisfiles erstellen und verteilen | **ja** — Sammelreport-Läufe |
| 2 | `create_boe_st.csh` → `preis_dld.e -B2` | Stammdatenfile Börse und Vendoren | nein — eigener Job nötig |
| 3 | `create_notify_wdbo.csh` | Benachrichtigung an WDBO | nein — eigener Job nötig |
| 4 | `run_preise_einspielen` → `preise.e -p0` | Preise nach `kurs` einspielen | **ja** — als **Stufe** der Lieferkette |
| 5 | `run_asf_vorl` | vorläufige Ausschüttungen und Splits aktivieren | nein — Ausschüttungs-Domäne |
| 6 | `run_vendor_stamm.csh` | Vendorauswertung STAMMDATEN | nein — eigener Job nötig |
| — | `refkursVorhanden.e` | Warteschleife auf die EZB-Referenzkurse | **entfällt** — 10., Punkt I |
| 7 | `run_calc -r2 -r3 [-r4 -U]` | Kennzahlenberechnung | **ja** — als Stufe **und** Sweep |
| 8 | `run_vendor_kennz.csh` | Vendorauswertung KENNZAHLEN | nein — eigener Job nötig |
| 9 | `create_plausi_taegliche_preise.csh` → `-P2` | Fehlmeldungs-Report | **ja**, erweitert — 11. |

Zwei Anmerkungen: der große Plausi-Report `fplausib.txt` ist **nicht** Teil des Tagesjobs — er
kommt aus dem separaten Script `create_plausibel` (`preis_dld.e -P -a`, Zeile 60). Und das
Checkpoint-Verfahren ist genau das, was das Job-/Work-Queue-System ersetzt: kein Feature, das
portiert werden muss, sondern ein Symptom.

Ordnungsauflagen für die restlichen Schritte: 3 setzt 2 voraus, 8 setzt 7 voraus. 2 und 6 hängen
**nicht** an 1 — die Umstellung vom 2018.12.27 hat sie bewusst vor die Warteschleife gezogen.

---

## Parallelbetrieb

**Vorgaben (User, 2026-09-02):** Das Neusystem schreibt in eine **eigene Sybase**
(Business-Kontext); die Sybase des Altsystems ist read-only angebunden (Kontext `legacy-business`).
Beide Schemata sind eingefroren — keine neuen Tabellen, keine neuen Spalten (M); alles Neue liegt
in Postgres.

Der Modus ist derselbe wie bei den Steuermeldungen und den ISIN-Anforderungslisten: **das Altsystem
verarbeitet und persistiert zuerst**; seine Input- und Resultfiles kommen ins Neusystem, das
dieselbe Operation inklusive Persistenz in der eigenen Sybase durchführt — und dann wird verglichen.
Träger ist ein **`PreisMeldungDiffJob`** nach dem Muster `IsinAnforderungslisteDiffJob` /
`AusschuettungsMeldungDiffJobSubmissionService`; der Einstieg existiert schon:
`ParallelbetriebJobSubmissionService` erkennt Preismeldungs-Files und ruft den heutigen Stub
`PreisMeldungDiffJobSubmissionService` (derzeit BadInput).

Vier Diff-Ebenen:

| Ebene | Neusystem | gegen |
|---|---|---|
| Rückmeldung | das erzeugte ZIP (`data.log`/`error.log`/`info.log`) | das Rückmelde-ZIP des Altsystems |
| Ausgabefiles | `preis.csv`/`solva.csv`, Reports | die Files des Altsystems |
| DB-Stand | `kurs`, `pool_if_kurs`, `del_protokoll` in der Neusystem-Sybase | dieselben Tabellen im Altsystem (`DatabaseCompareService`) |
| Projektion | `kurs.letzte_preise` (Postgres) | `kurs..tmp_if_last` im Altsystem — der B3-Diff |

**Außenwirkungen sind unterdrückt:** keine Rückmeldungs-Mails an Lieferanten, kein MFT/T2S-Upload,
keine Fehlmeldungs-Mails. Die Rückmeldung wird als File erzeugt und gedifft statt versandt; die
Ergebnisartefakte hängen am Diff-Job (Muster `resultBundleFile`).

**Bekannte Abweichungen** müssen im Diff konfigurierbar geführt werden — dasselbe Muster wie die
`ValidationSettings` der STM-Return-File-Diffs. Von Anfang an bekannt: das explizite `I3` aus D und
das `del_protokoll`-Rauschen aus 8.

Der Diff-Job wächst mit den Schnitten: nach Schnitt 1 difft er die Rückmeldung, nach Schnitt 2 den
DB-Stand und die Projektion, nach den Schnitten 4/5 die Ausgabefiles.

---

## Vorgehen

Der **lebende Stand** dieser Schritte wird im [Tracker](tracker.md) geführt (gleicher Ordner) —
dieses Kapitel definiert die Schritte, hakt sie aber nicht ab.

1. **Query-Ergebnisse zu J auswerten** (`fondspreise-lieferant-isin-analyse.sql`). Entscheidet die
   Adressierung der Fehlmeldung.
2. **Datenbeschaffung anstoßen** — `tax_code` und `preismeldung` zuerst.
3. **Offene Punkte klären.** A ist geschlossen, C, D und M entschieden, B und I (Voreinstellung)
   intern entscheidbar; E, F, G, H, J, K, L und N brauchen die Fachabteilung bzw. Markus. Blocker
   je Schnitt: die produktiven `tax_code`-Zeilen blockieren Schnitt 1, **N** und **F** blockieren
   Schnitt 5 (N könnte Entscheidung 6 kippen, F die Auslieferung des Deltas), **K** und die noch
   fehlende Kennzahlen-Ist-Analyse blockieren Schnitt 6, **J** blockiert Schnitt 7.
4. **Konzept nach `docs/Fondspreise/fondspreise-soll-konzept.md`**, sobald B und I entschieden sind.
   Dieser Plan ist der Arbeitsstand; das Dokument im Repo ist das Ergebnis.
5. **`docs/Technische Konzepte/ifas13-jobs.md`** aktualisieren — „Fondspreise — out of scope"
   stimmt dann nicht mehr.

### Implementierung in Schnitten

Der Zuschnitt folgt jetzt den Jobs, nicht den Legacy-Stufen:

1. **Lieferkette, Stufe 1** — Eingang, Inbox, Rückmeldung. Inbox-Schreiben auf `job_id`
   gescoped, Rückmeldung über `rueckmeldung_gesendet_at` geguardet.
2. **Lieferkette, Stufe 2** — Sync nach `kurs`, plus `preis_herkunft` mit dem monotonen Guard und
   `tmp_if_last` (B3: geführt, mit Guard über `(preisdatum, angekommen_am)`). **Nicht** serialisiert;
   der Guard ersetzt die Serialisierung. Die Rebuild-Funktion aus der Inbox gehört dazu — sie ist
   gleichzeitig der Parallelbetrieb-Vergleich und der Konsistenz-Testfall.
3. **`WirksamePreismeldungen`** als Komponente — nur für den Sammelreport. Früh und isoliert
   getestet.
4. **Sammelreport Lauf 1** — Plausi-Report, Filegenerierung, Publikationsprotokoll, Verteilung.
5. **Lauf 2 als Delta** — inklusive `I3` gegen das Publikationsprotokoll.
6. **Lieferkette, Stufe 3 + Sweep** — Kennzahlen. Damit ist der Job `COMPLETED`, auch wenn die
   Kennzahlen unvollständig blieben. **Vorher K klären**, sonst schreibt die Stufe in
   `ASF.r_faktor`, ohne dass geklärt ist, ob sie darf.
7. **Fehlmeldungs-Job** — hängt an der Inbox und an J, nicht an der Filegenerierung.
8. **Lieferketten-Transparenz** im Report (12.).

Quer dazu wächst der **`PreisMeldungDiffJob`** (siehe *Parallelbetrieb*): er ersetzt den
BadInput-Stub, sobald Schnitt 1 steht, und nimmt mit jedem weiteren Schnitt eine Diff-Ebene dazu.
Die Initialbefüllung von `letzte_preise` (9.) gehört zu Schnitt 2.

**Stand 2026-09-02: Schnitt 1 ist umgesetzt** — Diff-Job, Eingangsprüfung, Inbox und
Rückmeldungs-Erzeugung inklusive Diff-Ebene 1. Detail-Plan:
`2026-09-02-fondspreise-schnitt1-eingang-inbox-rueckmeldung.md` (gleicher Ordner); die
Klassen-/Kontext-Architektur zeigt die Deck-Sektion *Schnitt-1-Architektur*.

## Verifikation

Noch kein Code — prüfbar ist die Konsistenz des Konzepts:

- Jede Aussage über das Altsystem gegen die Ist-Analyse und, wo dort nicht belegt, gegen
  `file:line` im Legacy-Repo (ISO-8859-1 → `grep -a` / `iconv`).
- Die Inbox gegen ihre Verbraucher durchspielen: `WirksamePreismeldungen`, Plausi,
  Transparenz-Abschnitt,
  Projektion (`tmp_if_last`), Fehlmeldung. Jeder muss aus den Zeilen pro Job bedient werden können.
- **Das zweiachsige Statusmodell gegen die Fehlerfälle** durchspielen: Sync-Stufe hängt, während
  Lauf 1 die Lieferung schon berichtet; Kennzahlen-Stufe scheitert am fehlenden Referenzkurs; Lauf 2
  fällt aus; Lieferung trifft nach Lauf 2 ein; Lauf 1 wird wiederholt.
- **Den monotonen Guard prüfen**: zwei Lieferungen mit demselben Preisschlüssel, auf zwei Servern
  gleichzeitig verarbeitet — der Endzustand in `kurs` muss der der späteren Ankunft sein, und zwar
  **in beiden Bearbeitungsreihenfolgen**. Dasselbe für `tmp_if_last` mit gleichem Preisdatum und
  unterschiedlicher Ankunft.
- **Deadlockfreiheit**: zwei Lieferungen mit überlappenden, unterschiedlich sortierten
  Schlüsselmengen gleichzeitig — keine Verklemmung, weil je Schlüssel eine Klammer und die
  Schlüssel sortiert abgearbeitet werden.
- **Das Crash-Fenster der Klammer-Transaktion**: Sybase-Commit ohne Postgres-Commit → der Retry
  konvergiert; kommt dazwischen eine neuere Lieferung, verliert der Retry am Prädikat.
- **Claims-Übernahme**: Lauf 1 scheitert nach dem Claimen → der Folgelauf mit `repeatedFromJob`
  nimmt die geclaimten Lieferungen mit; keine Lieferung bleibt unsichtbar.
- **Initialbefüllung**: nach dem Seed aus `tmp_if_last` liefert der erste Lauf-1-Fallback dieselben
  Zeilen wie das Altsystem.
- **Parallelbetrieb**: derselbe Input durch Alt- und Neusystem → alle vier Diff-Ebenen leer bis auf
  die geführten bekannten Abweichungen.
- **Idempotenz je Stufe** prüfen: denselben Job zweimal laufen lassen. Inbox unverändert (kein
  PK-Verstoß), `kurs` unverändert, `tmp_if_last` unverändert, Kennzahlen identisch — und die
  Rückmeldung geht **nicht** zweimal raus.
- **Die Reihenfolge-Gefahr dokumentiert nachstellen** (akzeptiertes Risiko, aber der Testfall soll
  zeigen, was passiert): A scheitert im Sync, B überschreibt, A wird wiederholt.
- Die D/N-Regeln an den Fällen aus 4. prüfen, inklusive „`D` ohne vorheriges `N`" (läuft durch)
  und „`N` und `D` am selben Tag, dazwischen Lauf 1" (→ `I3`).
- Die Delta-Semantik: Fallback in Lauf 1 und echter Preis in Lauf 2 (zwei Schlüssel); zweimal
  `I2` auf denselben Schlüssel (Upsert, kein `I4`); Ausgabefilter unterdrückt `I2` in Lauf 1, `D`
  in Lauf 2 (kein `I3` nötig, weil derselbe Filter greift).
- **Die vier Fälle aus 6. durchspielen** (X liefert nie / vor Cutoff 1 / zwischen den Cutoffs /
  späte Korrektur für ein älteres Datum) und prüfen, dass Lauf 2 ohne Fallback nichts verliert.
- **Die Protokoll-Auflage aus 8.**: Lauf 1 gibt einen Fallback für einen Preis aus, der nie in
  `kurs` war; ein `D` dafür kommt vor Cutoff 2 → Lauf 2 muss `I3` ausgeben.
- **`tmp_if_last` gegen die Neu-Herleitung** vergleichen (B3): nach einem Tag Lieferungen muss die
  geführte Tabelle dem Rebuild entsprechen — und beides dem Legacy-Stand im Parallelbetrieb.
- Entscheidung 13 als Testfall: `preisdatum < fonds_ende` akzeptiert, `> fonds_ende` mit
  `ERR_DATE04` abgelehnt, beides nur für Code `R`.
- **Die Ausschüttungs-Ordnung durchspielen:** Ausschüttung für heute gebucht, Preis kommt erst nach
  Cutoff 1 — was steht in Report 1, was in Report 2? Preis kommt gar nicht — meldet O3 es?
  Ausschüttung wird erst nach Cutoff 2 gebucht — trägt das Preisfile von morgen die Angaben nach,
  und mit welchem Preisdatum? Und: eine Preiskorrektur trifft einen Tag mit Ausschüttung — wird
  `ASF.r_faktor` neu gerechnet, und von wem (Punkt K)?

## Korrekturen an der Ist-Analyse

### Eingearbeitet

**Diskussion 2026-08-31:** `oekbinfo.log`-Inhalt (2.9); die vier `INFO_DEL_*` gehen nach `info.log`
(2.7); Löschung über `DeleteKurseReally` samt Währungsvorbehalt und Ausschüttungs-Veto (5.2/7);
`tmp_if_last`-Aktualisierung ist nicht unbedingt (5.2/8).

**Recherche 2026-09-01, elf Änderungen** (1322 → 1451 Zeilen): `I4` gibt es im Fondspreis-Pfad
nicht (4.3); `pdPreis_ber` ist lokal gerechnet (3.4); neuer Abschnitt 1.1 „Der Tagesjob im Ganzen"
mit den neun Schritten und der EZB-Warteschleife; neuer Abschnitt 9.1 „Was `-P2` tatsächlich prüft";
`ERR_DATE04` nur für `R` und einseitig (2.6); `liefer_intervall` für Inland toter Zustand (6.2);
`PreisGrenze4Log`-Fundstellen (3.4); zwei neue offene Punkte (10).

### Runde 2 — Jobschnitt und Ausschüttungs-Nahtstelle, eingearbeitet 2026-09-01

1451 → 1649 Zeilen (zwei Durchgänge, siehe unten). Die substanziellen Änderungen:

| Stelle | Was |
|---|---|
| **neu: 1.2** | „Die Nahtstelle zu den Ausschüttungen (`ifas..ASF`)" — die sechs Berührungspunkte mit Richtung, der doppelt geschriebene `r_faktor`, die zirkuläre zeitliche Abhängigkeit mit den drei Belegen, und der fehlende `aussch_status`-Filter in `ReadAusschuettung`. `ASF` kam in der Ist-Analyse vorher **ein einziges Mal** vor |
| 1.1 | EZB-Referenzkurse nur für **Fremdwährungsfonds** (`fondskennzahl.cpp:2208`, `:3386`, `:4843`) — für einen EUR-Fonds ist der Kurs nirgends im Spiel |
| 2.6 | Zeile 11 plus Absatz: die Lieferberechtigung wird produktiv **nicht** geprüft (`nCheckKag` Default `0`, `make_einzel.awk` ruft mit `-K0`, `ERR_ISIN05` kann nie feuern) |
| 2.7 | neue Tabellenzeile: ein `D` **ohne** vorheriges `N` läuft ungeprüft durch; der `kurs`-Lookup passiert nur im Storno-Zweig |
| 5.3 | die Nachrechnung läuft **inline pro Preissatz** in `preise.e`, mit dem Riegel `daPreisDatum >= daStichtag → return 0` — nur Korrekturen, Stichtagspreise bleiben `run_calc` |
| 5.4 | `X` ist der **Notausgang aus dem Zirkel** aus 1.2, mit der Fundstelle des zweiten Leseversuchs |
| 6.1 | `kurs..kurs` führt **keine `liefer_id`** — kein historischer Nachweis in der DB, wer für welche ISIN geliefert hat |
| 6.2 | `liefer_typ = 'F'` ist der Fondspreis-Lieferant, doppelt belegt |
| 6.3 | `ifas..ASF` in die Tabellenliste aufgenommen |
| Abgrenzung | präzisiert: die Ausschüttungs-*Kette* ist nicht enthalten, die **Nahtstelle** schon |
| 10 | drei neue offene Punkte: 15 (`aussch_status`-Koexistenz), 16 (wie oft der Zirkel zuschlägt), 17 (`Del_Protokoll`, `Nachrechnung`) |

### Runde 3 — `tmp_if_last` im Detail, eingearbeitet 2026-09-01

| Stelle | Was |
|---|---|
| 4.5 | die drei `nQuellTab`-Zweige von `StartTmpKursSchleife`, damit belegt: **`tmp_if_last` hat genau einen Leser**. Dazu: `case 3` liest `pszTempTabelle[2]` auf einem zweielementigen Array — im Fondspreis-Pfad unerreichbar, aber latenter Out-of-bounds. Und: **65 ist ein Lesefilter**, 35 die einzige altersbasierte Löschregel, mit zwei Aufräumpfaden; produktiv 28.264 Zeilen / 3,1 MB |
| 3.5 | die Legacy-Programmhilfe zu `TempPreise4Vortag` ist **falsch** — sie behauptet `tmp_if_last`, der Code liest für Inland `tmp_if_kurs` |

### Noch offen

**`docs/Fondspreise/fondspreise-legacy-analyse.deck.html` ist veraltet.** Stand 13:27 gegen eine
Quelle von 18:36: es zeigt weiterhin `I4`, kennt keinen der neuen Abschnitte 1.1, 1.2 und 9.1, und
hat 26 Sektionen gegen 53 Abschnitte in der Ist-Analyse. Muss neu erzeugt werden.

**C1b ist eingearbeitet** (2026-09-02): steht jetzt bei offenem Punkt C — samt der Einschränkung,
dass die Sybase-Schemasperre (M) die `stale_since`-Spalte ausschließt und nur eine eigene
Postgres-Tabelle bliebe.
