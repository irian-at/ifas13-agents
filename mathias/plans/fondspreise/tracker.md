# Fondspreise — Umsetzungs-Tracker

Lebendes Dokument: der Status aller offenen Schritte zur Umsetzung von
[2026-08-31-fondspreise-neuentwicklung-konzept.md](2026-08-31-fondspreise-neuentwicklung-konzept.md).
Definitionen und Begründungen stehen ausschließlich im Konzept; hier stehen nur Status, Blocker und
Verweise. Zu diesem File gibt es bewusst **kein Deck** — es darf täglich churnen.

## 1. Klärungen

| Punkt | Frage (Kurzform) | bei wem | blockiert | Status |
|---|---|---|---|---|
| **E** | Ausschüttungs-Veto bei `R`-Löschungen: wie heute (still) oder Rückmeldung aus der Sync-Stufe? | Fachabteilung | — (mit 15./H bündeln) | offen |
| **F** | Dateinamen + Ready-File für zwei Auslieferungen; Bezieher-Zusage „Files in Reihenfolge anwenden" (gehört zu D) | Fachabteilung / Bezieher | Schnitt 5 (Auslieferung des Deltas) | offen |
| **G** | LMT persistieren und weitergeben — an wen, in welchem Format? | Fachabteilung | — | offen |
| **H** | Ausschüttung ohne Preis auch zur Eingangszeit melden? Empfänger, Fehler/Info, gegen `kurs` oder Inbox? | Markus / Fachabteilung | — | offen |
| **I** | Sweep bei fehlendem Referenzkurs: Voreinstellung I1 bestätigen (I2 konfigurierbar) | Fachabteilung | — (Voreinstellung blockiert nicht) | offen |
| **J** | Fehlmeldung: Zuordnung Lieferant↔ISIN, Empfänger, Zeitpunkt. **Befund 2026-09-02 (TEST-Abzug):** die F-Typisierung ist tot (alle 29 `fp_*`-Konten inaktiv). F3 = 0: über die **aktiven** Lieferanten hat zwar jeder meldepflichtige Fonds einen Adressaten — aber F4 zeigt, dass `KAG_lieferanten` STM-Steuerberater und Preis-Lieferanten **mischt** (alle Typ `A`; nur `db_spard` heißt „AT-Fonds Preise"). Wer je KAG der *Preis*-Lieferant ist, steht nirgends maschinenlesbar; und selbst `db_spard` hat als Rückmeldeadresse intern abi@oekb.at (F5). Zu klären: Preis-Lieferant je KAG identifizieren (Datenpflege? aus der Lieferhistorie?) und echte Adressdaten beschaffen | Markus / Fachabteilung | Schnitt 7 | Datenlage vollständig — Frage verschärft |
| **K** | Wem gehört `ASF.r_faktor`? (K1/K2/K3) | Markus | Schnitt 6 | offen |
| **L** | Vorrangregel Preis-/Ausschüttungs-Einspielung — Empfehlung O1+O3 bestätigen. **Befund 2026-09-08 (Zeitachse):** der Diskussionsstand „Cutoff 1 ~14:00 / Cutoff 2 ~16:00" kollidiert mit der Cron-Zeit von Ausschüttungs-Job 3 (16:00) — **Lauf 2 muss nach ihm liegen**, sonst fehlt dessen Buchung im Delta. Lauf 1 vor Job 3 ist damit erfüllt (14:00 < 16:00) | Markus / Fachabteilung | — | offen, Terminfrage präzisiert |
| **N** | Zweck des `tmp_if_last`-Fallbacks (N1/N2) — N2 würde Entscheidung 6 kippen | Fachabteilung / Bezieher | Schnitt 5 | offen |
| **O** | Fremdleser von `kurs..tmp_if_last`: lesen KUPL/KMS die Tabelle direkt, und welche Spalten? Entscheidet, ob die Projektion dauerhaft bleibt (sonst Fallback aus `kurs`, Plan D14) und wie exakt `txt_bez`/`liefer_id`/`eintragezeit` dem Legacy entsprechen müssen | Fachabteilung / KUPL-KMS-Verantwortliche | Schnitt 2 AP11 (Spaltentreue), Schnitt 4 | offen (User 2026-09-11) |
| **P** | Fallback-Semantik: darf ein Preis in Währung ≠ Fondswährung (steht nie in `kurs`) und ein per `D` zurückgezogener Preis im Lauf-1-Fallback erneut veröffentlicht werden? Fragen-File [2026-09-11-fondspreise-fachabteilung-fragen-fallback-waehrung.md](2026-09-11-fondspreise-fachabteilung-fragen-fallback-waehrung.md); Größenordnung über V6 im SQL-File | Fachabteilung | Schnitt 4/5; bis dahin Legacy-getreu (Plan D14) | offen |
| 13. | `ERR_DATE04` nur für Code `R` — gilt Kommentar oder Code? | Fachabteilung | Schnitt-1-Detail | offen |
| 14. | Bestätigen, dass nur Plausi-Abschnitt 15 entfällt (nicht 17, `makeCorrelationERZ`) | Markus | Schnitt-4-Detail | offen |
| — | „LMT = Liquidity Management Tools" für Außendokumente bestätigen | Fachabteilung | — | offen |
| — | `PreisHerkunft` vs. `KursHerkunft` (Vorauswahl `PreisHerkunft`) | intern | — | offen |
| — | ~~`pool_if_kurs` portieren?~~ | — | — | **geschlossen 2026-09-08: nein.** Kein Leser im Legacy; beide Schreibpfade unerreichbar (unbekannte ISIN verwirft schon der Eingang; der Vorl-Fonds-Zweig prüft `nRet` statt `nRet2`, `preisekennzahl.cpp:2760`). Kontrolle „beidseitig unverändert" wandert am 2026-09-11 mit den Diff-Ebenen 3/4 in den generischen Tabellenvergleich (Plan D13) |

## 2. Datenbeschaffung

Quelle: Konzept, Abschnitt *Datenbeschaffung*. Q-Nummern siehe Warnung unten.

- [x] **Produktive `tax_code`-Zeilen** (V1) — erhoben 2026-09-02 (TEST-Abzug): `L1`–`L3` mit
      `lieferung_ab` 2026-03-01, `isinwaehrung='J'`, `max_nk=8`; `R`/`E`/`Z` Untergrenze `1.0E-8`;
      `S` −100…150, `S2`/`S3` −100…1250; `X` fehlt in `tax_code` (nur `v_preiscode`) — nicht
      lieferbar. Gegen Prod verifizieren, dann ist **Schnitt 1 entblockt**
- [x] Produktive `ifas..preismeldung`-Zeilen + Verteilung `INV.preismeldung` (Q5) — `TGL` existiert
      und ist aktiv (`U`/`Y` inaktiv, Seed veraltet); Soll-Menge: **4549** aktive inländische
      TGL-Fonds — passt zu ~4200 Preisen/Tag
- [x] `kurs..KAG_lieferanten` mit `liefer_typ='F'` (Q0–Q4) — erhoben; Kernbefund siehe **J**
      (keine aktiven F-Lieferanten). Q4 auf dem Abzug nicht aussagekräftig (tmp_if_kurs nach
      Tagesjob fast leer) — auf Prod nach Lieferschluss wiederholen
- [x] `ifas..ASF`-Statuskollisionen (Q9–Q11) — **keine** A/V/D-Koexistenz je (Fonds, Tag), kein
      einziges `D`, keine mehrdeutigen Treffer (Q11 leer). Nur 95 V-only-Schlüssel, und **F6**
      zeigt: 93 davon liegen in der jüngsten Vergangenheit (31.08.–02.09., unmittelbar vor der
      Aktivierung), 2 in der Zukunft. Heißt: ein Preis für den Ausschüttungstag, der **vor**
      `run_asf_vorl` eintrifft, zieht bei Legacy die vorläufige Ausschüttung ins File. Das
      Neusystem filtert auf `'A'` — die Differenz im Parallelbetrieb als bekannte Abweichung
      führen bzw. in 15./L mit Markus klären, ob `V` bewusst mitgelesen werden soll
- [x] Ausschüttungen ohne Preis (Q12) — Q12a leer: jede aktive Inland-Ausschüttung hat (inzwischen)
      ihren R-Kurs am `ASF_DATUM`. Der Notausgang `X`: seit 2008 **83** Kurse gesamt (Q12b'),
      davon **69** an Ausschüttungstagen (Q12c) — `X` ist fast ausschließlich der Zirkel-Ausweg,
      zuletzt 1–3/Jahr (Häufung 2017)
- [x] `ASF.r_faktor`-Lücken (Q13) — seit 2012 dauerhaft ~1–3 %/Jahr (2026: 87 von 2934); davor
      praktisch null. **F7**: 706 der Lücken haben `ausschuettung > 0` (**echte** Lücken, brechen
      die `r_faktor_ges`-Kaskade), nur 106 sind Null-Ausschüttungen (harmlos) — verschärft K und
      bestätigt den Sweep-Bedarf
- [ ] **Produktive INI-Werte** — die Defaults stehen alle im Quelltext (dritter `GetIniString`-Parameter),
      offen ist nur, ob der Betrieb einen überschreibt. Im Repo liegt weder `PREIS_DLD.INI` noch die
      Fondspreis-`CONFIG.INI` (die eingecheckte unter `Ifas/scripts_mft/at/` ist die MFT-Variante ohne
      Fondspreis-Keys). Schnitt 2: `Tage_TmpIfLast` (65), `Tage_TmpIfLast_Beendete` (35),
      `InsPreise{CPlan,AIF,FondsInLiquidation}` (je 1). Schnitt 6: `Referenzkurs_Tage` (0),
      `CalcOhneReferenzkurs`, `Nachrechnung`/`PreiseNachrechnung` (je 1). Fürs Ausliefern:
      `Preis_MinTage4Meldung` / `Preis_MaxTage4Meldung`. **`Del_Protokoll` ist entschärft** — die
      Fondspreis-Kette schreibt `del_protokoll` gar nicht mehr (siehe *Erledigt*)
- [ ] `AllowOldPreisFormat`, `AllowTxtExt4PreisFile` — muss das alte Format 1 bedient werden?
- [ ] `MFT_*.INI` — Zielverzeichnisse und Accounts
- [x] `pool_if_kurs`-Semantik (V2) — **tot seit 2012-03-30** (4767 Zeilen, keine Duplikate,
      V2b leer). Guard-Frage erledigt; stattdessen neue Klärung: überhaupt portieren? (siehe
      Klärungen)
- [x] `tmp_if_last`-Profil (V3) — 30 668 Zeilen (14 604 im 65-Tage-Fenster), 906 mit heute nicht
      auflösbarer ISIN (Beleg: nicht aus `kurs` ableitbar), `cod_ex` durchgehend `'N'` wie vom
      Konzept behauptet. ~~Seed = volle Tabelle~~ — **2026-09-11: Seed entfällt**, der Voll-Sync zum
      Go-live bringt `tmp_if_last` mit; auch der Guard-Seed nach Postgres entfällt (User 2026-09-11, Plan D12). Die
      906 Zeilen sind Altlasten mit heute ungültiger ISIN, kein Ableitbarkeitsbeleg — der einzige
      lebende Unterschied zu `kurs` ist die Preiswährung (Plan D14)
- [ ] **V6 — `tmp_if_last` gegen `kurs` klassifizieren** (2026-09-11, im SQL-File): je Zeile ISIN
      nicht auflösbar / Währung ≠ Fondswährung / kein Kurs zum Datum (gelöscht o. ä.) / jüngerer Kurs
      vorhanden / aktuell — quantifiziert O/P. Erste Fassung lief zu lange (korreliertes `max` über
      die Kurshistorie), Fassung mit `#lp`-Zwischentabelle und `exists` liegt bereit. **Auf GAST
      ausführen, Ergebnis eintragen**
- [ ] Vollständiger `fplausib.txt` mit Treffern in allen Abschnitten (Meldungstexte)
- [ ] Aktuelle `preis.dtd`, wie tatsächlich ausgeliefert
- [ ] `datum_min`-Vergleichsrichtung (Code widerspricht Feldbeschreibung) — Fachabteilung

> Das im Konzept referenzierte SQL war verschollen und wurde am 2026-09-02 **rekonstruiert**:
> [fondspreise-lieferant-isin-analyse.sql](fondspreise-lieferant-isin-analyse.sql) — Q0–Q5 und
> Q9–Q13 nach den Verweisen im Konzept, plus neuer **V-Block** (V1 `tax_code`/`v_preiscode`-Dump,
> V2 `pool_if_kurs`-Semantik, V3 `tmp_if_last`-Profil für Seed/B3, V4 Tagesvolumen je Lieferant,
> V5 `kurs.guelt`-Pflege für C3). Q4 und V4 sind Momentaufnahmen von `tmp_if_kurs` — nach
> Lieferschluss, vor dem Tagesjob ausführen. Die übrigen Punkte der Liste (INI-Werte, `fplausib.txt`,
> `preis.dtd`, MFT) sind Dateien, kein SQL.

## 3. Schnitte

Definition: Konzept, *Implementierung in Schnitten*. Der Detail-Plan je Schnitt entsteht beim Start
als eigenes datiertes File in diesem Ordner und wird hier verlinkt.

| # | Schnitt | blockiert durch | Detail-Plan | Status |
|---|---|---|---|---|
| 1 | Lieferkette Stufe 1 — Eingang, Inbox, Rückmeldung | ~~`tax_code`~~ (erhoben, V1) | [2026-09-02-fondspreise-schnitt1-eingang-inbox-rueckmeldung.md](2026-09-02-fondspreise-schnitt1-eingang-inbox-rueckmeldung.md) | **umgesetzt + gepusht** (ifas13 `1f3d9f393`/`0dbd47271`; Byte-Verifikation des Rückmelde-Formats wartet auf echte Antwort-ZIPs) |
| 2 | Stufe 2 — Sync, Guard (Klammer-Transaktion), Projektion `tmp_if_last` + `letzte_preise` als Guard/Spiegel, Rebuild | O/P (nur für „Projektion überhaupt?") | [2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md](2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md) | **in Arbeit** — AP1–AP8 fertig; **Designreview 2026-09-11 → AP11 umgesetzt** (Projektion nach `kurs..tmp_if_last` in der Neusystem-Sybase, `letzte_preise` ist Guard + Spiegel, Diff-Ebenen 3/4 ausgebaut; Plan D11–D14, *Stand AP11*); AP9–AP10 offen; Branch `feat/fondspreis` (`30b6adec8`, `b5af3541d`, `1470b78ba`, `26edc0ad7`, `8f9491f73`, `3c4a6d63b`, `903f7dd60`, Merge `origin/master` `1ba887699`), nicht gepusht |
| 3 | `WirksamePreismeldungen` als Komponente, isoliert getestet | — | — | offen |
| 4 | Sammelreport Lauf 1 — Plausi, Files, Publikationsprotokoll, Verteilung | — | — | offen |
| 5 | Lauf 2 als Delta, inkl. `I3` gegen das Publikationsprotokoll | N, F | — | offen |
| 6 | Stufe 3 + Kennzahlen-Sweep | K, Kennzahlen-Ist-Analyse | — | offen |
| 7 | Fehlmeldungs-Job | J | — | offen |
| 8 | Lieferketten-Transparenz im Report | — | — | offen |
| quer | `PreisMeldungDiffJob` (Parallelbetrieb) — ersetzt den BadInput-Stub, wächst mit 1/4/5 | — | mit Schnitt 1 + 2 | **Ebene 1 umgesetzt** (Rückmeldungs-Diff mit Normalisierung + bekannten Abweichungen). Ebenen 3/4 waren mit Schnitt 2 gebaut und sind nach dem Designreview 2026-09-11 **wieder ausgebaut** (AP11, umgesetzt) — der DB-Vergleich wird ein eigener generischer Job (siehe *Weitere Schritte*); Ebene 2 (Files) folgt mit Schnitt 4/5 |

## 4. Weitere Schritte

- [ ] **Vor dem finalen Merge nach `master`: Deploy-Check Fondspreise** (User 2026-09-11) — was der
      Stand `feat/fondspreis` beim Deploy tatsächlich tut, einmal komplett durchgehen. Befund vom
      2026-09-11: von sich aus passiert nichts (kein Cron, kein MFT-Abholer, keine Mail); alles hängt
      an einem eingereichten Preismeldungs-ZIP über den UI-Upload der STM-Nachrechnungsseite oder
      `/api/recalculations`. Dann laufen Eingang, Inbox, Rückmeldungs-ZIP (nur Filestore), Stufe 2
      nach `kurs`/`tmp_if_last` der Business-Sybase plus Guard/Spiegel in Postgres, Ebene-1-Diff.
      Zu prüfen:
      - [ ] **Schreibkontext**: REST läuft im Business-Kontext (`sybase-ifasneu`), der UI-Upload im
            gerade gewählten UI-Kontext — Default im Server-Deployment ist `sybase-gast`, das
            Altsystem. Der Sync-Pfad prüft das `writeable`-Flag nicht (nur `ArchiveService` nutzt den
            `DatabaseWriteSwitch`). Entscheiden: Guard im Sync-Pfad bzw. Ablehnung nicht
            beschreibbarer Kontexte bei der Job-Submission
      - [ ] **Automatischer Feed**: postet ein MFT-seitiger Automatismus eingehende ZIPs an
            `/api/recalculations`? Dann wird ab dem Deploy jede Preismeldung verarbeitet und in die
            Neusystem-Sybase geschrieben. Steht nicht im Repo — Betrieb fragen
      - [ ] **`tax_code` in der Fondspreise-Postgres** befüllen (YAML-Abzug von GAST im
            Testdatenmodul, per Import einspielen), sonst kennt der Eingang keine Codes
      - [ ] **Flyway-Flag `OEKB_IFAS_SYBASE_IFASNEU_FLYWAY_MIGRATION_ENABLED`**: ist es gesetzt,
            scheitern V065/V067 (`create table kurs`/`tmp_if_last`), wo die Tabellen existieren —
            dasselbe Muster wie V041/V062. Postgres-Flyway läuft immer: V065–V067 legen
            `preis_herkunft`, `letzte_preise` und leere Kopien von `kurs`/`tmp_if_last` an
      - [ ] **Nicht verdrahtet, bewusst**: Cleanup beendeter Fonds, Rebuild, Guard-Seed, generischer
            Tabellenvergleich, Sammelreport/Filegenerierung, Fehlmeldung, Kennzahlen — bestätigen,
            dass das für den ersten Deploy so gewollt ist
      - [ ] **Sichtbarkeit**: der Job erscheint nur in der generischen Aufgaben-Liste über den
            Typ-Filter; keine eigene Seite. Reicht das für den Parallelbetrieb?
      - [ ] Flyway-Nummern gegen `origin/master` und Geschwister-Branches erneut prüfen
            (`mathias/rules/flyway-versions-after-merge.md`)
- [x] **Zeitlicher Ablauf als eigener Schritt** (User 2026-09-08) — erledigt:
      [2026-09-08-fondspreise-tagesablauf-alt-vs-neu.deck.html](2026-09-08-fondspreise-tagesablauf-alt-vs-neu.deck.html),
      die Tages-Zeitachse Alt gegen Neu als Gegenüberstellung, plus dieselben Bausteine als
      **Ablaufdiagramm nebeneinander** — gleiches Raster, sodass nur die drei Kanten auffallen, die
      links stehen und rechts fehlen (Rückkante um `ASF`, EZB-Selbstschleife, der Mensch als
      Knoten). Für die Diskussion mit der Fachabteilung. Dazu das Begleitblatt
      [2026-09-08-fondspreise-tagesablauf-diagramme.html](2026-09-08-fondspreise-tagesablauf-diagramme.html)
      mit dem **vollständigen** Bild ohne Spaltenbreiten-Limit: Gantt je System über alle
      Cron-Läufe, der Altsystem-Ablauf mit beiden Batches und ihrer Verzahnung, und der Tagesjob
      mit allen neun Checkpoints. Quellen dafür neu im Repo: `docs/Tagesjob und Programmablauf/` (Crontab,
      Tagesjob-Logik mit den Checkpoints `cp_tagesjob_01…09`, Event-Logging, Wartungsbildschirm).
      Die feste Vorgabe (Ausschüttungen bleiben Batch 3×/Tag, Sammellauf 1 vor Ausschüttungsjob 3)
      ist eingearbeitet; Punkt **L** ist dort analysiert und um den Terminbefund zu Lauf 2
      geschärft (siehe Klärungen). Verbleibende Terminfragen stehen im Deck als eigener Abschnitt
- [ ] **Veto-Befunde persistent auswerten** — Schnitt 2 sammelt Ausschüttungs-Vetos und übersprungene
      Zeilen im `sync-report.txt` des Jobs plus Zählern am Job. Das reicht *vorerst* (User
      2026-09-08); eine eigene Befundtabelle („wie oft passiert das?" ohne Filedurchsicht) bleibt als
      spätere Optimierung offen, ebenso die Veto-Zeile im Sammelreport (Schnitt 4)
- [ ] **Fondsaktivierung als eigenes Feature** (Stammdaten, nicht Fondspreise; User 2026-09-10):
      Legacy aktiviert vorläufige Fonds auf zwei Wegen — Preispfad (`VorlFondsAktivieren` aus
      `MakeTmpPreise`) und Aktion `isin_aktivieren` (`run_isins_aktivieren.csh`, seit 2018-12-12,
      täglich, `fonds_beginn <= Stichtag`). Die Aktion ist seit 2018 der maßgebliche Pfad; die
      beiden Kopien driften (Weihnachtsregel → 2.1., `liefer_status` ja/nein, Idempotenz). Schnitt 2
      lässt den Status bewusst unberührt (Plan D10, TODO in `PreismeldungSyncDecisions`). Zu klären
      mit Markus, analog K: wem gehören `INV.status`/`fonds_beginn`, welche Variante wird portiert,
      braucht es den Preis-Auslöser überhaupt noch
- [x] ~~**Guard-Seed für `letzte_preise`**~~ — **entschieden 2026-09-11: kein Seed** (Plan D12).
      `tmp_if_last` kommt mit dem Voll-Sync, `letzte_preise` startet leer. Folge: der erste Write je
      Schlüssel nach dem Go-live findet keine Guard-Zeile und verhält sich wie Legacy („zuletzt
      verarbeitet gewinnt"), ab dem zweiten greift unsere Regel über `(preisdatum, angekommen_am)`.
      Der Postgres-Spiegel bleibt für nie mehr gelieferte Schlüssel lückenhaft; ihn liest niemand,
      der Cleanup nimmt seine Kandidaten aus `tmp_if_last`. Der gebaute Code
      (`LetztePreiseService.seedGuardFromTmpIfLast` / `importLegacyLastPrices` + 2 Tests) bleibt
      vorerst liegen und kann beim Aufräumen von `letzte_preise` mitgehen
- [ ] **Generischer Tabellenvergleich Sybase alt ↔ Sybase neu** (User 2026-09-11, Plan D13): ein
      geplanter Job nach dem Legacy-Tagesjob, je Szenario konfigurierbar (Tabelle, Schlüsselfenster,
      bekannte Abweichungen), für alle Tabellen, die das Neusystem schreibt — `kurs`, `tmp_if_last`,
      `pool_if_kurs` als „beidseitig unverändert"-Kontrolle (D2), später ASF/Kennzahlen. Ersetzt die
      Diff-Ebenen 3/4 des `PreisMeldungDiffJob`. Keim: `DatabaseCompareService` (old/new-Kontext aus
      Properties, `compareStmIds` noch `todo`), Vergleichskern `PreismeldungDbDiff`. Bekannte
      Abweichungen von Anfang an: `guelt` (Lieferzeit vs. Tagesende), Projektion bei fallendem
      Preisdatum (strengerer Guard, Plan D5), transiente `N`-dann-`D`-Zustände (User 2026-09-08)
- [ ] **Dual-DB-Testprofil** (`business` = Neusystem-Sybase, `legacyBusiness` = Altsystem-DB): nach
      D13 nicht mehr für den Diff-Job nötig, aber für den generischen Tabellenvergleich und als
      realistische Umgebung für die beiden Cross-DB-Klammern (`kurs`, `tmp_if_last`). Vor
      Parallelbetrieb-Start aufsetzen
- [ ] **Konzept nachziehen (Runde 10, Designreview 2026-09-11)**: Entscheidung 9 Schreiberliste
      (`R`-Löschpfad toter Code, unbekannte ISIN tot), Entscheidung B Verortung (B3 bleibt, Tabelle
      ist `kurs..tmp_if_last` in der Neusystem-Sybase, `letzte_preise` Guard + Spiegel), Abschnitt
      *Parallelbetrieb* (Ebenen 3/4 → generischer Vergleich), Entscheidung M nur für **neue**
      Tabellen; Deck neu erzeugen. Details im Schnitt-2-Plan unter AP10
- [ ] **Schnitt 6 — `Calc*`-Gates**: Legacy trennt je Fondskategorie das *Speichern* der Preise
      (`InsPreiseCPlan`/`InsPreiseAIF`/`InsPreiseFondsInLiquidation`) vom *Nachrechnen* der
      Kennzahlen (`CalcCPlan`/`CalcAIF`/`CalcFondsInLiquidation`, `preisekennzahl.cpp:2795-2820`).
      Die Sync-Entscheidung (Schnitt 2) kennt nur Ersteres; `marksKorrektur` sagt „Kennzahlen ab
      Preisdatum veraltet", nicht „nachrechnen erlaubt". Die Kennzahlen-Stufe muss die `Calc*`-Gates
      selbst anwenden — Befund aus dem Review vom 2026-09-10
- [ ] **Echte Preis-Antwort-ZIPs anfordern** (Fachabteilung/Betrieb): idealerweise die
      Altsystem-Antworten zu den 4 Beispielfiles vom 12.05.2026 (`docs/Fondspreise/beispiele/`,
      passend zu `fplausib.txt`) — nötig für die Byte-Verifikation des Rückmeldungs-Diffs
      (Schnitt 1, blockiert nicht die Implementierung)

- [ ] **Zeichenkodierung in `kurs..tax_code`**: 3 der 57 GAST-Zeilen haben doppelt kodierte
      Umlaute in `txt_bez` (`AQS`, `L1`, `TD` — z. B. „RuecknahmebeschrÃ¤nkung"); `txt_bez_e` ist
      jeweils sauber. Zusätzlich Tippfehler in `Z.txt_bez` („Rüchnahmepreis"). Betrifft die
      Preismeldung nur über `L1`. Datenkorrektur im Altsystem anfragen (Fachabteilung), sonst
      wandert der Fehler beim Umstieg mit

- [ ] Kennzahlen-Ist-Analyse erstellen (`preisekennzahl.cpp`, `fondskennzahl.cpp`, `c_calc.cpp`) —
      fehlt laut Abgrenzung, Voraussetzung für Schnitt 6
- [ ] Soll-Konzept nach `docs/Fondspreise/fondspreise-soll-konzept.md`, sobald I entschieden ist
      (B ist entschieden)
- [ ] `docs/Technische Konzepte/ifas13-jobs.md` aktualisieren — „Fondspreise — out of scope" stimmt
      dann nicht mehr
- [ ] `docs/Fondspreise/fondspreise-legacy-analyse.deck.html` neu erzeugen (laut Konzept veraltet:
      zeigt noch `I4`, 26 Sektionen gegen 53 Abschnitte)

## Erledigt

- 2026-09-11 — **Designreview Schnitt 2** (Diskussion, keine Codeänderung). Entschieden: DB-Setup
  bestätigt (zwei Sybase, eingefroren; Postgres frei; Voll-Sync zum Go-live, danach
  Divergenz-Beobachtung aller vom Neusystem geschriebenen Tabellen); Diff-Ebenen 3/4 raus aus dem
  Job, DB-Vergleich als generischer Tabellenvergleich; `kurs..tmp_if_last` bleibt vorerst und wird in
  der Neusystem-Sybase Legacy-getreu geschrieben (mögliche Fremdleser KUPL/KMS, Klärung O);
  `letzte_preise` bleibt ganz und wird Klammer/Guard + Spiegel; Verhalten bei Währung ≠ Fondswährung
  und Löschungen vorerst Legacy-getreu (Klärung P). Befunde aus dem Legacy-Code: einziger lebender
  Unterschied `tmp_if_last`↔`kurs` ist die Preiswährung (`isinwaehrung` auf GAST für alle Preis- und
  Solva-Codes `N`); der `R`-Löschpfad nach `tmp_if_last` ist toter Code (`DeleteLastKurse` ohne
  Aufrufer, SQL mit falschen Spaltennamen) — gelöschte Preise werden im Fallback erneut
  veröffentlicht; alle `I2`-Spalten stehen in `kurs`; `kurs` hat außer der Einspielung keinen
  regulären Schreiber; `preis_herkunft` kann wegen `dat_kurs` im Schlüssel nicht Guard der Projektion
  sein. Plan D11–D14 + AP11, Fragen-File für die Fachabteilung, Kontrollabfragen V6 im SQL-File

- 2026-09-11 — **`origin/master` in `feat/fondspreis` gemergt** (`1ba887699`, konfliktfrei;
  `InvRepository` beidseitig geändert, automatisch zusammengeführt). Flyway: master, stable und
  production enden bei V064, unsere V065–V067 bleiben; Kollision nur mit `origin/ausschuettung`
  (eigene V065/V066) — wer später mergt, nummeriert um. Regel dafür:
  `mathias/rules/flyway-versions-after-merge.md`

- 2026-09-11 — **Guard-Seed entfällt** (User, nach dem Umbau). Der Seed hätte die strengere
  Reihenfolgeregel auch gegen die per Voll-Sync mitgebrachten Altbestände durchgesetzt und damit
  eine Korrektur zu einem älteren Datum abgelehnt, die Legacy annimmt — ein Parallelbetrieb-
  Unterschied beim ersten Write je Schlüssel. Ohne Seed ist dieser erste Write Legacy-getreu, alle
  weiteren folgen unserer Regel. Nichts zu bauen, nichts auszuführen; Code bleibt vorerst

- 2026-09-11 — **AP11 umgesetzt** (Schnitt 2, Branch `feat/fondspreis`, Commit `903f7dd60`):
  Diff-Ebenen 3/4 aus dem `PreisMeldungDiffJob` ausgebaut (`PreismeldungDbDiffService` gelöscht,
  `db_diff_count` direkt aus V066 gestrichen, `PreismeldungDbDiff` bleibt für den generischen
  Vergleich); `TmpIfLast` schreibend mit delete-then-insert je Code, `liefer_id`/`eintragezeit`/
  `intervall`, trimmende Getter; `LetztePreiseService.recordLastPrice` als Klammer über die
  `letzte_preise`-Zeile mit innerem Sybase-Write; Rebuild als Replay durch den Guard ohne Löschen;
  Cleanup beidseitig, Fondsende-Abfrage in 1000er-Blöcken; Guard-Seed-Leser
  `seedGuardFromTmpIfLast`. Tests: SyncService 13 (H2), DiffJob 3, Guard 14 (H2+PG), neu
  `TmpIfLastRepositoryTest` auf H2/PG/Sybase — alle grün; Test-Compile aller Module grün

- 2026-09-08 — **Zeitachse Alt gegen Neu** als Deck
  ([2026-09-08-fondspreise-tagesablauf-alt-vs-neu.deck.html](2026-09-08-fondspreise-tagesablauf-alt-vs-neu.deck.html)),
  aus der neuen Doku unter `docs/Tagesjob und Programmablauf/` plus Ist-Analyse und Konzept.
  Drei Befunde, die vorher nur implizit waren: (a) **ein** Sammler (`run_preise`, alle 10 Min)
  trägt Preis-, Ausschüttungs- **und** Steuermeldungen, weil `preis_ins.e` die Meldungsart selbst
  erkennt; (b) die zwei echten Sperren auf der Legacy-Zeitachse sind die **manuelle Datenwartung**
  vor dem Tagesjob-Start (~15:00, aus `TAGESJOB.jam`) und die **Warteschleife ohne Timeout** auf
  die EZB-Referenzkurse (Beleg 12.06.2023: Schritte 1–6 dauern 5 Minuten, das Warten eine Stunde);
  (c) `run_aussch.csh 3` um 16:00 ist der **erste** Lauf des Tages, der den heutigen Preis in
  `kurs` findet — 57 Minuten nachdem das Preisfile draußen ist. Neuer Terminbefund zu **L** siehe
  Klärungen

- 2026-09-08 — **`run_stm.csh` schreibt nach `tmp_aussch`.** Beim Aufarbeiten des vollständigen
  Ablaufs gefunden und im Quelltext belegt: bei einer FINAL-Meldung liest die
  Steuerdaten-Verarbeitung die Ausschüttungsinformationen nach und legt einen Satz in
  `tmp_aussch` an — „Damit die FINAL Ausschüttung auch in ASF und den Ausschüttungsfiles landet"
  (`c_st_meldung.cpp:3060-3066`, Funktion `ProcessAusschuettung4aussch`; ausländische
  Ausschüttungen sind ausgenommen). Damit ist die **Reihenfolge STM → Ausschüttung** eine echte
  fachliche Kopplung und nicht bloß Cron-Kosmetik: Ausschüttungslauf 2 liegt 15 Minuten nach
  STM-Lauf 2 (11:45 → 12:00), Lauf 3 zwanzig Minuten nach STM-Lauf 3 (15:40 → 16:00). Nur Lauf 1
  (07:30) liegt vor seinem STM-Lauf — er räumt auf, was der Vortag geschrieben hat. Relevant für
  die Ausschüttungs-Domäne, wenn die STM-Seite im Neusystem nicht mehr nach `tmp_aussch` schreibt

- 2026-09-08 — **Schnitt 2 begonnen**, Detail-Plan
  [2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md](2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md).
  AP1–AP3 umgesetzt: `FondsStammdaten` um `numWfsKu`/`codArtF`/`status` erweitert (eine gebündelte
  Query statt zweier Lookups), `FondspreiseProperties` (`ifas.fondspreise`), Entities `Kurs`,
  `PreisHerkunft` und `LetzterPreis` samt Guard-Repositories, Flyway `V065__fondspreise_sync.sql`
  je Baum. Neue Tests: `PreismeldungSyncGuardTest` (beide Guards, H2 + Postgres),
  `KursRepositoryTest` (alle drei DBMS). Committet als `30b6adec8` auf dem Branch
  `feat/fondspreis` (nicht gepusht)

- 2026-09-08 — **`del_protokoll` wird für die Fondspreise nicht geschrieben.** Kein Leser im
  Legacy-Code (alle vier Fundstellen sind Schreiber); die einzige lesende Stelle ist die Stored
  Procedure `s_exp_del`, die nirgends aufgerufen wird; IFASNXT zieht die Preise per SSIS direkt aus
  `kurs` (`run_ifasnxt_update` → `CallSSIS/api/Call/kurs`), und der im Kopfkommentar erwähnte
  Parameter `DEL` ist im `switch` nicht implementiert. Da `Del_Protokoll` per Default `0` ist, wäre
  Schreiben ohnehin **neues Verhalten** und erzeugte eine Diff-Abweichung je Löschung. Rückweg
  dokumentiert im Schnitt-2-Plan unter D6

- 2026-09-08 — **Sybase-`char`-Padding**: `kurs.cod_fliesscode char(2)` liefert `"R "` statt `"R"`,
  `wp_art_f.cod_art_f char(4)` liefert `"AIF "`. Ungefixt hätte Diff-Ebene 3 auf jeder Zeile eine
  Abweichung gemeldet und `isAif()` wäre auf Sybase nie wahr geworden. Gelöst über trimmende Getter
  auf der `Kurs`-Entity (ein `@Convert` greift auf `@Id`-Attributen nicht) und Normalisierung von
  `cod_art_f` an der DB-Grenze. `INV.status` ist `varchar(5)` — dort kein Problem

- 2026-09-08 — **Eingangs-Code in drei Klassen geschnitten**: `PreismeldungEingangProcessor`
  (Instanzklasse, Provider im Konstruktor, Ablauf und Ergebnisbau), `PreismeldungFileChecks`
  (`@UtilityClass`: Fileformat und Zeilenstruktur), `PreismeldungLineValidations`
  (`@UtilityClass`: Regeln B3–B20, gibt ein `LineCheckResult` zurück statt in eine übergebene
  Liste zu schreiben — damit fällt `@SuppressWarnings("NullAway")` weg). `Candidate` eigenständig
  package-private. Bezeichner auf Englisch, Deutsch nur noch für Fachbegriffe.
  Konventionsbefunde: `-Processor` heißt im Repo „Objekt mit Verarbeitungsrolle", nie
  `@UtilityClass`; Utility-Klassen stehen im Plural und tragen `@UtilityClass`; `ofStatic` **im**
  Produktions-Interface ist Hausmuster (24 Verwendungen im STM-Bereich) und gibt einen benannten
  nested `record Static` zurück — `PreismeldungStammdatenProvider` folgt dem jetzt

- 2026-09-03 — **`tax_code`-Stammdaten als YAML im Testdatenmodul**: `standard_TAX_CODE_data.yaml`
  (57 Zeilen, Abzug von sybase-gast) unter `at/oekb/ifas/testdata/fondspreise/`, dazu
  `TaxCodeTestdataCreator` + `FondspreiseBasedataCreator`. Bewusst **nicht** in `BasedataCreator`:
  die Fondspreise-Tabellen liegen in einer eigenen DB, der Aufrufer setzt den Kontext
  (`withFondspreiseDbContext`). `PreisMeldungDiffJobTest` seedet damit die echte Konfiguration
  statt handkopierter Werte — bestätigt die Werte in `TaxCodeTestdata` (Unter-/Obergrenzen,
  `maxNk=8`, `lieferungAb=2026-03-01`). Restbegriffe „Landezone"/„ingest" in Properties-Kommentaren
  und einem Javadoc nachgezogen

- 2026-09-02 — **`tax_code` im YAML-Datenexport**: Entity auf alle 26 Legacy-Spalten
  vervollständigt, `TaxCodeDto` mit `@TypeId("TAX_CODE")` + MapStruct-Paar in
  `ifas-data-import-export` — der Typ erscheint automatisch in der UI-Export-Liste.
  Round-Trip-Test (Export → Tabelle leeren → Re-Import) grün. Damit können
  Parallelbetrieb-Fixtures die produktive tax_code-Konfiguration als YAML mitführen

- 2026-09-01 — A geschlossen; B entschieden (B3); C entschieden (C1, C1b dokumentiert);
  D entschieden (explizites `I3`)
- 2026-09-02 — M entschieden (Sybase schema-gesperrt, Business-Tabellen nach Postgres/`kurs`);
  Runden 7+8 eingearbeitet, Konzept-Deck aktuell
- 2026-09-02 — **Begriffe umbenannt** (Konzept-Runde 9): „Ingest" → **Eingang**
  (`PreismeldungEingang*`, Package `.eingang`), „Landezone" → **Inbox** (nur Prosa; Entity
  `PreismeldungZeile`/Tabelle `preismeldung_zeilen` bleiben). Code, Konzept, Deck, Tracker und
  Doku nachgezogen; alle Tests weiter grün
- 2026-09-02 — **Schnitt 1 implementiert** (Detail-Plan im Ordner): neues Modul
  `ifas-persistence-fondspreise` (Inbox `kurs.preismeldung_zeilen`, `TaxCode` read-only,
  Flyway V061–V063), Kontext `database-context.fondspreise.db-key`, Meldungsmodell mit
  Legacy-Codes/-Texten, Eingangs-Prüfkette B0–B20, Rückmeldungs-Writer (Legacy-ZIP-Format),
  `PreisMeldungDiffJob` mit Rückmeldungs-Diff. 95 Domain-Unit-Tests + 2 E2E-Integrationstests
  grün (inkl. Selbstvergleich → 0 Abweichungen); `BundleFileType.DATA_LOG_FILE` neu in
  ifas-domain-stm. Offen aus dem Plan: echte Antwort-ZIPs für die Byte-Verifikation, UI-Seiten,
  E2E mit den 4 Beispielfiles
- 2026-09-02 — Voranalysen auf dem TEST-Abzug (Stand ~2026-08-29) **vollständig** gelaufen:
  Q0–Q5, Q9–Q13, Q12b', V1–V5', F1–F7; Ergebnisse im SQL-File. Kernbefunde: `kurs.guelt` aktuell
  gepflegt, aber 29,5 Mio Altzeilen NULL (C3 nur vorwärts); KAG-Zuordnung existiert über aktive
  `A`-Lieferanten (F3 = 0, jeder Fonds hat einen Adressaten), mischt aber STM- und
  Preis-Lieferanten (J verschärft); 93/95 V-Zeilen unmittelbar vor Aktivierung (bekannte
  Abweichung Statusfilter); `X` fast nur Zirkel-Ausweg (69/83); 706 echte r_faktor-Lücken.
  Einzig offen (je `-- todo` im File): **Q4/V4 auf Prod** nach Lieferschluss, vor dem Tagesjob
