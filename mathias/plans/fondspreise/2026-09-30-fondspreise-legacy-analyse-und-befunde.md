# Fondspreise — Altsystem-Befunde, Datenlage, Fachabteilung und Constraints des Neusystems

Stand 2026-09-30. **Digest** aller Analyse-Ergebnisse aus den Plandokumenten vom 31.08. bis 30.09.
in einer Datei. Basis bleibt die Ist-Analyse `docs/Fondspreise/fondspreise-legacy-analyse.md`
(ifas13-Repo, 10 Kapitel): sie beschreibt die Programme, Tabellen, Meldungstexte und Parameter im
Detail; hier stehen die **Befunde, die seither dazukamen oder sie korrigieren**, die Zahlen aus der
Produktions- bzw. GAST-Datenbank, die Aussagen der Fachabteilung, die offenen Klärungen und die
technischen Constraints des Neusystems, die das Design geprägt haben. Das Design selbst steht
ausschließlich in [2026-09-30-fondspreise-preis-historie-versionen.md](2026-09-30-fondspreise-preis-historie-versionen.md).

Legacy-Pfade relativ zu `~/dev/projects/oekb/ifas`; die Quellen sind ISO-8859-1 (`grep -a`,
`iconv`), Extensions teils groß (`M_INSERT.CPP`, `m_fp_rec.CPP`, `M_FP_DLD.CPP`).

---

## 0. Begriffe

| Begriff | Bedeutung |
|---|---|
| **Preisschlüssel** | (ISIN, Preisdatum, Währung, Meldekategorie). Jede ISIN ist eine Tranche mit genau einer Fondswährung (`INV.WAEHRUNG`); ein Fonds mit EUR- und USD-Klasse hat zwei ISINs. Umgerechnet wird im Preisweg nirgends; die Währung ist überall Teil des Schlüssels |
| **Meldekategorie** | Spalte 4 des Lieferformats, im Altsystem „Preis-Code“, in `kurs` die Spalte `cod_fliesscode`; Zeilen der Tabelle `tax_code`, die je Code das Eingangsverhalten steuert (Grenzen, `max_nk`, `future`, `isinwaehrung`, `ignore_null`, Datumsgrenzen) |
| **`I1`/`I2`/`I3`/`I9`** | Satzarten des ausgehenden Preisfiles: Header, Upsert, Delete, Footer; Solva `S1`–`S3`, Delete `D1`–`D3`. **`I4` kommt im inländischen `preis.csv` nicht vor** |
| **Eingang** | Stufe 1 der Lieferkette (`preis_ins.e`; früher „Ingest“) |
| **Inbox** | die gelieferten, angenommenen Zeilen je Job (`preismeldung_zeilen`; früher „Landezone“) |
| **Sammelreport** | alles bis zu einem Stichzeitpunkt Gesammelte — Preisfile **und** Plausi — für einen Bezieherkreis; zwei Läufe je Tag |
| **Publikationsprotokoll** | je Preisschlüssel, in welchem Lauf er als `I2`/`I3` hinausging; Bezugspunkt für das Delta von Lauf 2 |
| **Fehlmeldung** | Meldung fehlender Preise (`FehlendePreismeldungenJob`); das Wort ist zweideutig |
| **LMT** | `L1`/`L2`/`L3`: Rücknahmebeschränkung, Verlängerung der Rückgabefrist, Rückgabegebühr; seit Lieferformat V3.0 (2026). „Liquidity Management Tools“ ist unbelegt |
| **Zielgruppe** | `ALLE`, `VENDOR`, `PUBLIKUM` — Filter der Ausgabeströme |
| **Klammer-Transaktion, monotoner Guard, Letztpreis-Projektion** | Begriffe des verworfenen Stufe-2-Designs (Schnitt-2-Plan, archiviert); nicht mehr in Verwendung |

### Die Meldekategorien

| Code | Bedeutung | Gruppe | Wohin |
|---|---|---|---|
| `R` | Errechneter Wert, der NAV je Anteil. Basis aller Kennzahlen | PREIS | `kurs`, `preis*.csv` |
| `E` | Ausgabepreis (NAV + Ausgabeaufschlag) | PREIS | `kurs`, `preis*.csv` |
| `Z` | Rücknahmepreis | PREIS | `kurs`, `preis*.csv` |
| `S`, `S2`, `S3` | Solvabilität (Solva I, Basel II Standardansatz, vereinfachter IRB) — ein Prozentsatz, kein Preis | SOLVA | `kurs`, `solva*.csv` |
| `L1`, `L2`, `L3` | LMT — geprüft, **nirgends gespeichert oder ausgeliefert** | LMT | nur Rückmeldung |
| `X` | indikativer, fiktiver errechneter Wert — Notausgang zur Aktivierung eines vorläufigen Fonds; nie ausgegeben, im aktuellen Lieferformat nicht enthalten | PREIS | `kurs` |
| `C`, `F`, `Q`, `T`, `TA` | historische Steuercodes — seit 2017 im Preisweg still verworfen | KEST, QUST | — |

`tax_code` ist mit der Steuerdaten-Meldung geteilt (`KEST`, `DIVI`, `AQS` haben mit Preisen nichts
zu tun). Herkunft der Buchstaben ist in den Quellen nicht dokumentiert (Vermutung: `R` = Rechenwert,
`E` = Emissionspreis, `Z` weil `R` vergeben war); Fremdcodes werden umgeschlüsselt (C → R, F → E,
B → Z, `auslkennzahl.cpp:360ff`).

---

## 1. Die Kette und der Tagesablauf

Vier Stufen, drei Programme: Sammlung `preis_ins.e` → Plausibilität `preis_dld.e -P` →
Filegenerierung `preis_dld.e -fPREISE` → Einspielung `preise.e -p0`; Nahtstelle `kurs..tmp_if_kurs`.
Der große Plausi-Report `fplausib.txt` ist **kein** Tagesjob-Schritt (`create_plausibel`, `-P -a`).

### 1.1 Cron und Tagesjob (Produktion `car@sybprd02`; Quellen `docs/Tagesjob und Programmablauf/`)

| Uhrzeit | Schritt | Programm / Script | Bemerkung |
|---|---|---|---|
| 05:30–05:50 | Monitoring, Statusfeld, OeNB-Stammdaten, `tmp_af_kurs` leeren | `run_monitor.csh`, `run_ifas_admin`, `run_oenb_stammdaten.csh`, `run_admin_clear_tmp_af_kurs` | Admin/Ausland |
| 05:55 | Geschäftsjahr | `run_geschaeftsjahr.csh` | Neusystem: `GeschaeftsjahreBerechnenJob` 05:55 MON–FRI |
| 05:58 | vorläufige ISINs aktivieren | `run_isins_aktivieren.csh` → `aktionen.e -Aisin_aktivieren` | seit 2018-12-12 der maßgebliche Aktivierungspfad |
| 06:00 → 15:30 | Eingang Ausland, alle 10 Min | `run_af_lieferung` | Ende `last` 15:30 → Event `PREIS_INS_AUSL_LAST` |
| 06:05 → 17:55 | **Eingang Inland, alle 10 Min** | `run_preise` → `preis_ins.e` | **ein** Sammler für Preis-, Ausschüttungs- und Steuermeldungen (erkennt die Art selbst); schreibt `tmp_if_kurs` (PREIS, SOLVA), `tmp_tax`, `tmp_aussch` (nur Inland, `M_INSERT.CPP:2098-2118`); Rückmeldung je Datei als ZIP in `receive/`, NetApp, Mail |
| 07:30 | Ausschüttungen 1 | `run_aussch.csh 1` → `preis_dld.e -EAUSSCH`, `-fAUSSCH` | `tmp_aussch` → `ASF` (Kopie `cop_aussch`), Files, Verteilung; räumt auf, was der Vortag schrieb |
| 08:00 | Steuerdaten 1 | `run_stm.csh 1` | mit Mahnungen |
| 11:45 / 12:00 | Steuerdaten 2 / Ausschüttungen 2 | `run_stm.csh 2`, `run_aussch.csh 2` | bei FINAL schreibt die STM-Verarbeitung nach `tmp_aussch` (`c_st_meldung.cpp:3060-3066`, `ProcessAusschuettung4aussch`; Ausland ausgenommen) — Reihenfolge STM → Ausschüttung ist fachliche Kopplung, nicht Cron-Kosmetik |
| 12:50 / 17:50 | ISIN-Sonderauswertung 1 / 2 | — | Neusystem `IsinAnforderungslisteJob` |
| 13:05 | Stammdatenfile Börse | `create_boe_st.csh -B2` | läuft hier **und** als Tagesjob-Schritt 2 |
| 14:00 → 18:00 | EZB-Referenzkurse, alle 5 Min | `run_refkurs.csh` | „vorhanden“ gemessen ~16:05 |
| 14:35 (Doku) / 14:50 (Crontab) | Fondspreis-Plausibilität | `create_plausibel` → `preis_dld.e -P` → `fplausib.txt` | Quellen widersprechen sich (auch „14:45–15:45 je nach Vollständigkeit“) |
| ≈14:50 → 15:00 | **manuelle Datenwartung** | Fachabteilung | arbeitet den Plausi-Report ab, startet den Tagesjob **von Hand** aus `TAGESJOB.jam` |
| 15:00 | Tagesjob START | `run_tagesjob.csh datum [-U]` | Event `TAGESJOB \| START`; Restart überspringt Schritte mit Checkpoint; gemessen 12.06.2023 15:00:41 |
| 15:00–15:05 | **cp_01** Preis- und Solvafiles | `create_preise.csh` → `preis_dld.e -fPREISE` | liest `tmp_if_kurs`, `tmp_if_last`, `ASF` (`ReadAusschuettung` **ohne** Statusfilter); MFT und T2S |
| | cp_02 / cp_03 | `create_boe_st.csh -B2`, `create_notify_wdbo.csh` | Börse-Stammdaten, WDBO-Notify (3 setzt 2 voraus) |
| | **cp_04** Einspielung | `run_preise_einspielen` → `preise.e -p0` | `tmp_if_kurs` → `kurs`, `tmp_if_cop`, `tmp_if_last`. **Erst hier steht der Tagespreis in `kurs`**, nach dem Preisfile aus cp_01 |
| | cp_05 | `run_asf_vorl` | vorläufige Ausschüttungen/Splits `V` → `A`, Nachrechnung `r/s_faktor_ges` |
| | cp_06 / cp_06a | `run_vendor_stamm.csh` (+ Archiv), Verteilung MFT-TEST im Hintergrund | Event `ENDE \| Preise Stammdaten` (15:05:50) |
| 15:05 → ~16:05 | **Warten auf EZB** | `refkursVorhanden.e` gegen `zeas..adev`, Minutentakt | **ohne Timeout**; Notbremse `CONFIG.INI CalcOhneReferenzkurs = 1` (Wartungsbildschirm, einmalig, am Jobende zurückgesetzt); gemessen 1 h am 12.06.2023. Betrifft nur währungsbereinigte Kennzahlen von Fremdwährungsfonds |
| 15:30 / 15:35 | letzte Sammler-Läufe | `run_af_lieferung last`, `run_preise last` | Events `PREIS_INS_AUSL_LAST` / `PREIS_INS_INL_LAST`; `run_preise last` ist das **Tor für STM-Lauf 3** |
| 15:40 | Steuerdaten 3 FINAL | `run_stm.csh 3` | wartet in `while(1)`/`sleep 60` auf beide LAST-Events; Event `STM_FINISHED 3` |
| 16:00 | Ausschüttungen 3 | `run_aussch.csh 3` | **erster Lauf des Tages, der den heutigen Preis in `kurs` findet** — 57 Min nachdem das Preisfile draußen ist |
| ~16:05–16:11 | cp_07 / cp_08 / cp_08a | `run_calc -r2 -r3 [-r4 -U] -f0 -a`, `run_vendor_kennz.csh`, Verteilung MFT-TEST | berichtigte Kurse, Performance, Volatilität, am Ultimo Risiko; Event `ENDE` 16:11:35 |
| 16:11 | cp_09 | `create_plausi_taegliche_preise.csh` → `preis_dld.e -P2` | liefern die TGL-Fonds täglich? Event `ENDE PREIS PLAUSI`; danach alle `cp_tagesjob_*` löschen |
| 16:15 / 16:30 | Kontrollen | `event_stm_finished.csh 3`, `event_aussch_finished.csh 3`, `event_calc_finished.csh` | Mail, wenn ein Event fehlt |
| 17:55 | letzter `run_preise` | | nur mehr Fondspreise; was jetzt kommt, wirkt erst im Tagesjob von morgen |
| — | IFASNXT-Abzug | `run_ifasnxt_update` → SSIS `…/CallSSIS/api/Call/kurs` | Cron-Zeit in den Quellen nicht belegt; zieht direkt aus `kurs` |

Mechanik: Checkpoint-Dateien `cp_tagesjob_01…09` (existiert eine, wird der Schritt übersprungen;
Neustart setzt dort fort); Returncode 2 = „kein Börsetag“; Event-Tabellen `event_log`/`events` mit
Schlüssel `(datum, inland_ausland, event_id, event_nr)`, `eventwriter.e`/`eventreader.e`.
Beleg 31.08.2023: 15:03 `TAGESJOB #2 ENDE Preise Stammdaten`, 15:31 `PREIS_INS_AUSL_LAST`,
15:36 `PREIS_INS_INL_LAST`, 15:41 `PREIS_DLD_STM_CHECK 3` (1:47 min, 64 081 Fonds), 15:44
`STM_FINISHED 3`, 16:00 `PREIS_DLD_AUSSCH_INSERT/_FILES 3`.

### 1.2 Die drei Kanten, die das Neusystem nicht hat

1. **Rückkante um `ASF` (der Zirkel).** cp_01 liest `ASF` und will die Ausschüttung gebucht;
   `run_aussch` braucht den `R`-Kurs zum `ASF_DATUM` aus `kurs` (`asfkennzahl.cpp:880-916`:
   „Inlaendische Fonds → es muss ein Preis vorhanden sein“, `return -1`; Ausland hat einen
   Vortags-Fallback), und den schreibt erst cp_04 **nach** cp_01. Eine Ausschüttung landet nur im
   Preisfile, wenn sie an einem früheren Tag gebucht wurde oder `run_aussch.csh` zufällig dazwischen
   lief. Ausweg: der fiktive Code `X` (`CONFIG.INI/FiktiverErrechneterWert` Default 1,
   `PREISE.CPP:820-821`). Zweiter, unbeabsichtigter Ausweg: `ReadAusschuettung` filtert
   `aussch_status` nicht, cp_01 läuft vor cp_05 → ein Preis vor der Aktivierung zieht die
   **vorläufige** Ausschüttung ins File (Zahlen in Abschnitt 9).
2. **EZB-Selbstschleife** ohne Timeout (oben).
3. **Der Mensch als Knoten**: Datenwartung und manueller Tagesjob-Start bestimmen den Nachmittag.

Fünf Tagesjob-Schritte haben im Neusystem keinen Nachfolger: cp_02, cp_03, cp_05, cp_06, cp_08,
dazu die MFT-TEST-Verteilung. Nicht Teil des Umbaus: Auslandskette (`-R1`, `liefer_status`,
Mahnungen), Meldefonds-Listen, Fristenprüfung, Kennzahlen-Formeln (eigene Ist-Analyse fehlt).
Legacy hat einen Delta-Mechanismus (`szEintragezeit` → `eintragezeit > '<zeitpunkt>'`,
`m_fp_rec.CPP:2579-2584`), nutzt ihn im Fondspreis-Pfad aber nicht. `fplausib.txt` (`-P`) und
Tagesjob-Schritt 9 (`-P2`) prüfen Verschiedenes.

---

## 2. Eingang (`preis_ins.e`)

- **`N` und `D` in derselben Tagesmenge** (`Check4DeleteInTmp`, `M_INSERT.CPP:4138-4271`, Aufruf
  `:1278-1291`): `D` auf ein früheres `N` gleichen Schlüssels → das `N` fällt aus `tmp_if_kurs`;
  ist der Schlüssel weder in `kurs` noch in einem früheren Lauf berichtet → auch das `D` fällt weg
  (`INFO_IGNORE_DEL`); sonst bleibt `D` und wird `I3`. `D` ohne vorheriges `N` läuft ungeprüft
  durch. `N` auf früheres `D` → `D` fällt weg. Der `kurs`-Lookup passiert **nur** im Storno-Zweig.
  Folge: **ein Tages-Paar `N`+`D` erreicht `kurs` nie**; ein `D` auf einen älteren Preis entfernt
  die Zeile in Schritt 4 physisch, ohne Spur.
- Eine Zeile in `tmp_if_kurs` wird nie wieder geprüft; das Eingangsurteil gilt. Der Eingang kennt
  nur `N` und `D` („neu und update Sätze [werden] gleich gehandhabt“, `M_INSERT.CPP:3643`, `:4064`);
  in `tmp_if_kurs` gewinnt die letzte Lieferung (`DeleteTmpPreisRecord`, `c_insert.cpp:1962`).
- **Lieferberechtigung wird produktiv nicht geprüft**: `nCheckKag` Default 0 (`c_param.cpp:39`),
  `make_einzel.awk` ruft `-K0`; `ERR_ISIN05` kann nie feuern.
- **Beendeter Fonds**: abgelehnt nur `Preisdatum > fonds_ende` mit `ERR_DATE04`, und nur für Code
  `R` (`M_INSERT.CPP:2932-2958`); `R` vor `fonds_beginn` erzeugt nur `INFO_DATE02` (JIRA 7897).
  Ob Kommentar oder Code gilt, ist Klärung 13.
- **`E`/`Z` gegen `R`** nur in derselben Datei (±`lRange4Preis` Zeilen, gleiche ISIN/Währung/Aktion,
  `M_INSERT.CPP:1231-1250`), nie gegen `kurs`; Verletzung verwirft nur die `E`/`Z`-Zeile
  (`ERR_VALUE05`/`06`). `E` ohne `R` ist zulässig; kein Code setzt einen anderen voraus.
- **Alle Prüfungen einer Zeile laufen durch**, nur `nIsOk = 0` (`M_INSERT.CPP:1123-1200`); eine
  Zeile kann mehrere Bugs tragen (Beleg `db_gut` 01.09.: drei Bugs). Das Neusystem kehrt bei der
  ersten Meldung zurück — offener Punkt im Tracker.
- **Währung**: `ERR_CURRENCY04` existiert, ist per `tax_code.isinwaehrung` für `R/E/Z/S/S2/S3`
  und `C/F` **explizit `N`** — so seit dem Install-Skript 2012 (`insert_tax_code.cr:160-307`), so
  auf GAST; feuert nur für `L1`–`L3` und Steuercodes. Der Eingang prüft den Wert eines `D` nicht.
- **LMT** wird vollständig validiert (`ERR_LMTPROZENT1`, `ERR_LMTRUECKL2`, `CheckAktionL2`) und
  nicht gespeichert („derzeit nicht gespeichert“, `M_INSERT.CPP:2049-2056`). Lieferformat V3.0
  §4.2: aktives Tool täglich melden, keine Leermeldungen; nur `L2` wird mit `I` (Wert 0)
  inaktiviert, `L1`/`L3` enden durch Ausbleiben. LMT sind Zustände, keine Preise.
- `Q`/`T`/`TA` seit 2017 still verworfen (`M_INSERT.CPP:1164`) — kein Bug, kein Zähler, nur
  `data.log`-Status. `db_union` liefert täglich vier solche Zeilen je ISIN.
- `datum_min`: `CheckDatum`/`SavePreisRecords` vergleichen `> daDatumMin` (`M_INSERT.CPP:2020`,
  `:2906`), die Feldbeschreibung erwartet das Gegenteil. `intervall` seit 2017 leer.
- `ISIN_UPD.CPP:228` pflegt `tmp_if_last.txt_bez` bei ISIN-Umbenennung mit.

### 2.1 Rückmeldung — am echten Archiv verifiziert (`testdaten_september.zip`, 103 Antworten, 01.–08.09.2026)

- `error.log`/`info.log` stimmen Zeichen für Zeichen; Labels durchgehend aus `txt_bez_e`.
- `data.log` je Zeile: Trennlinie, `--- input row: %05d`, die Lieferzeile, `--- data-records: `,
  Feldzeilen `%-3d %-30s: %s` (Betrag `%.4f`, Code als `<code> - <txt_bez_e>`), dann der Status;
  verworfene Zeilen tragen statt des Status den **letzten** Bug-Text (`szBugInfo` wird
  überschrieben). Zeitstempel je Zeile ist die aktuelle Uhrzeit (`cAAktTime::OutAktDateTime`).
- `statistics.log`: `%7d  - <Label>` mit `Rows delivered`, je Preiscode `<txt_bez_e> (<code>)`,
  `Import-Bugs`, `Plausi-Infos`, plus `bug statistics` in der Deklarationsreihenfolge von
  `cBugStatMsgs`.
- `NODATA`: **ein** Bug, nur für ein File ganz ohne Zeile (`M_INSERT.CPP:442`).
- Zeilenenden **LF**, Zeichensatz ISO-8859-1 (102 von 103); nur `db_allianz`s `data.log` war
  CRLF + CP437 (`make_einzel.awk:296-300` schickt alle Logs durch `unix2dos -c iso`; wovon das
  abhängt, ist offen — deployte MFT-Skripte/INIs liegen nicht im Repo).
- ZIP-Name und Eintragsreihenfolge bestätigt. Gepinnt von `PreismeldungRueckmeldungGoldenFileTest`
  (`db_union` 10 Zeilen end to end, `db_gut` 4 Zeilen nur Writer).
- `kurs..tax_code`: 3 von 57 GAST-Zeilen mit doppelt kodierten Umlauten in `txt_bez` (`AQS`, `L1`,
  `TD`), `txt_bez_e` sauber; Tippfehler „Rüchnahmepreis“ in `Z.txt_bez`. Datenkorrektur anfragen.

---

## 3. Die Meldekategorien im Legacy-Verhalten (`preis_ins.e`, `preise.e`)

**Parallel, ohne Verbund.** Jede Zeile trägt genau eine Kategorie; in `kurs` ist sie Teil des
Schlüssels `(num_wfs_ku, dat_kurs, cod_fliesscode, waehrung)` (`Kurs/tabledefs/I_kurs.cr`).

| | `R` | `E`, `Z` | `S`, `S2`, `S3` | `L1`–`L3` |
|---|---|---|---|---|
| in `kurs` | ja, dazu `num_bericht_kurs` | ja | ja | nein |
| löschbar | ja, außer Ausschüttung/Split am Preisdatum (Veto) | immer | immer | `D` angenommen, wirkungslos |
| Kennzahlen | **einzige Basis** (`ReadKurs` Default `R`, `fondsbasis.h:992`; alle Selects in `fondskennzahl.cpp` filtern `'R'`) | nein | nein | nein |
| rückdatiert | Korrektur, Nachrechnung ab Preisdatum | zählt als Korrektur, Nachrechnung ändert nichts | nie Korrektur (`CheckKorrektur`, `preisekennzahl.cpp:2990`) | — |
| ein `D` löst aus | Kennzahlen des Tages löschen, Nachrechnung | nur die Zeile | nur die Zeile | — |

**Das Veto trifft das ganze Paket.** Die Einspielung gruppiert `tmp_if_kurs` per `select distinct`
auf (ISIN, Datum, Währung, Aktion) über alle Dateien seit dem letzten Lauf
(`preisekennzahl.cpp:2248`); `ReadTmpKurse` lädt alle Codes des Pakets (`:601`). Ist `R` im
Lösch-Paket und gibt es eine aktive Ausschüttung oder einen Split mit Ex-Tag = Preisdatum
(`fondsbasis.cpp:360`, Status `A`), bleibt alles stehen, auch `E`, `Z`, `S` (`:2887`): `D E`+`D S` →
beide gelöscht; `D R`+`D E`+`D S` → nichts; `D E` in einem Lauf, `D R` im nächsten → `E` weg, `R`
bleibt. Der Eingang kennt das Veto nicht, der Lieferant bekommt eine normale Rückmeldung.
`D R` löscht nur `R` und die Kennzahlen; `E`, `Z`, `S` bleiben ohne NAV stehen.

**Ein `D` im Detail:** ohne `R` im Paket nur die gelieferten Codes (`DeleteKurseReally`, `:1443`);
mit `R` ohne Veto zusätzlich `pkz_kum`, `pkz_abs` (und `PKZ` bei `PerformanceOptimierung = 0`)
des Tages, am Ultimo `ream_kum`/`frkz_kum` (`DeleteKennzahlen :1985`), dann Nachrechnung ab
Preisdatum (`c_preise.cpp:166`, `:233`). Ein `D`, das nichts trifft, löscht null Zeilen ohne Fehler.
Das Lieferformat verlangt, dass ein `D` die ursprünglichen Werte trägt (V3.0 §4.1).

---

## 4. Einspielung (`preise.e -p0`) und `kurs`

- **Reihenfolge in `MakeTmpPreise`** (`preisekennzahl.cpp:2656-2935`), je Gruppe (ISIN,
  Preisdatum, Währung, Aktion): Stammdaten (`cFondsBasis::Read`); TEST-ISIN (`cod_art_f='TEST'`)
  verwerfen (`:2702`); C-Plan, AIF, Liquidation je INI-Gate (`:2710-2731`; die `continue` liegen in
  `c_preise.cpp:113-132`, vor beiden Writes); ISIN in `vwkn` unauflösbar → `pool_if_kurs` +
  `tmp_if_last` (`:2925-2934`, unerreichbar); **Preiswährung ≠ Fondswährung → kein `kurs`-Write,
  `WriteLastKurse` trotzdem** (`:2843-2850`); bei `D` in Fremdwährung passiert gar nichts;
  vorläufiger Fonds mit `R` → `VorlFondsAktivieren` (`:2747-2782`).
- **`N` ist immer ein Update**: je geliefertem Code delete-then-insert in `kurs` (`WriteKurse
  :719-800`, `WriteKurseBCP :815`); nur der gelieferte Code wird überschrieben. `S`/`S2`/`S3`
  gehen nach `kurs` („Schleife über alle Kursfelder (auch Solva)“), nur LMT nicht.
- `kurs_1_index` ist `with ignore_dup_key`: ein doppelter Insert wird still verworfen. Wegen des
  vorgelagerten Deletes greift das nie; ein vergessenes Delete bliebe aber unbemerkt beim alten Wert.
- **`kurs.guelt` ist kein Lieferzeitpunkt**: `getdate()` beim Einspielen, bei BCP die Uhr des
  App-Servers (`:774`, `:877`), also Tagesende. Ohne neue Lieferung wird neu gestempelt: `R`-Zeilen
  durch `CalcBerichtKurs`, sobald der berichtigte Kurs abweicht (`fondskennzahl.cpp:2072`, `:2106`;
  ein frisches `R` mit `num_bericht_kurs = null` trifft das immer), ausländische Fonds zusätzlich
  durch `Faktor2Kurs` (`auslkennzahl.cpp:719`). Der Eingangszeitpunkt steht nur in
  `tmp_if_kurs.eintragezeit` (→ `tmp_if_cop`). `kurs` führt **keine `liefer_id`**; Lieferhistorie
  nur in NetApp-Archiven.
- **Korrektur** = `Stichtag > Preisdatum` **und** Kurse betroffen (Solva allein zählt nicht,
  `CheckKorrektur :2990`); Nachrechnung inline nur bei Korrekturen (`:3049`, „Keine Nachrechnung
  wenn nicht eine Korrektur“), Stichtagspreise bleiben `run_calc`. `MakePreiseEinzel` ist schon
  pro Satz organisiert, nur als Tagesjob-Schritt terminiert.
- **Ausschüttungs-Veto**: `R`-Löschung mit Ausschüttung zum Preisdatum wird verweigert, `// ????`
  (`:2539-2547`, `:2885-2897`), eine Logzeile. Im Nicht-Veto-Pfad tut Legacy, was die Fachabteilung
  will (Abschnitt 10): `DeleteKurseReally`, `DeleteKennzahlen`, Nachrechnung ab Preisdatum;
  `ASF.r_faktor` wird inländisch nicht genullt, sondern von der Nachrechnung neu gesetzt (`:3072`,
  `ReCalcReinvestFaktor`); genullt nur im Auslands-„alles löschen“ (`DeleteKurs :1660-1690`).
- **Fondsaktivierung** hat zwei Wege: Preispfad `VorlFondsAktivieren` (`:2759`) und die tägliche
  Aktion `isin_aktivieren` (seit 2018-12-12, `fonds_beginn <= Stichtag`). Die Aktion ist
  maßgeblich; beide Kopien driften (Weihnachtsregel → 2.1., `liefer_status`, Idempotenz). Der
  Rückfall „nicht aktiviert → `pool_if_kurs`“ prüft `nRet` statt `nRet2` (`:2760-2762`) — feuert nie.
  Eigenes Stammdaten-Feature, nicht Fondspreise (Tracker).
- **`pool_if_kurs`** (`pool_i_k.cr:7`, 1994): Dead-Letter ohne Leser; beide Schreibpfade zu
  (Eingang verwirft unbekannte ISIN per `ERR_ISIN06`); empirisch kein Schreiber seit 2012-03-30.
  **Nicht portiert** (geschlossen 2026-09-08); Kontrolle „beidseitig unverändert“ im
  Tabellenvergleich.
- **`del_protokoll`** (`del.cr`, `del_code = "kurs1"`): kein Leser (alle vier Fundstellen
  Schreiber; einziger Leser `s_exp_del`, nirgends aufgerufen); IFASNXT zieht per SSIS direkt aus
  `kurs`; der Parameter `DEL` ist im `switch` nicht implementiert; `Del_Protokoll` Default 0
  (`c_basisparam.cpp:136`). Schreiben wäre neues Verhalten. **Nicht portiert.**
- **Zwei Nummern**: `kurs` ist über `num_wfs_ku` aus `vwkn..wkn_hist` geschlüsselt (historisiert,
  ISIN-Auflösung zum Stichtag), `ASF` über `WFS_WKN` (`num_wfs`). Verwechslung wäre still und falsch.
  `cod_art_f`, `status` per String-Vergleich (`fondsbasis.cpp:3794-4075`).
- Außer der Einspielung hat `kurs` keinen regulären Schreiber (`s_ins_kurs_direct` 2005 ohne
  Aufrufer, `WAEHR_UM` Euro-Umstellung, Trigger auf `wkn_desc` bei Fondslöschung, `einmal`-Programme).
  Keine Trigger auf `tmp_if_last`.
- Größen (Produktion, `Ifas/admin/spaceused/csv/kurs.csv`): `kurs` 42,6 Mio Zeilen; `tmp_if_cop`
  (ein Tag) 26 k; `tmp_if_last` 28 k. Legacy beschneidet `kurs` nie.
- INI-Defaults (produktive Werte nicht im Repo): `InsPreiseCPlan`/`InsPreiseAIF`/
  `InsPreiseFondsInLiquidation` = 1 (`IFASTOOL.CPP:904`, `:930`, `:1000`); `Tage_TmpIfLast` = 65
  (`M_FP_DLD.CPP:457`), `Tage_TmpIfLast_Beendete` = 35 (`:466`); `Del_Protokoll` = 0;
  `Referenzkurs_Tage` = 0; `CalcOhneReferenzkurs`, `Nachrechnung`/`PreiseNachrechnung` = 1;
  `Preis_MinTage4Meldung`/`MaxTage4Meldung`. Legacy trennt je Kategorie `InsPreise*` (speichern)
  von `CalcCPlan`/`CalcAIF`/`CalcFondsInLiquidation` (nachrechnen, `preisekennzahl.cpp:2795-2820`).

---

## 5. `tmp_if_last` — die Letztpreis-Projektion

- **Genau ein Leser**: `cFondsRecord::StartTmpKursSchleife(nQuellTab, …)` (`m_fp_rec.CPP:2554-2576`):
  `0` = `tmp_if_kurs` (normaler Lauf), `1` = `tmp_if_last` mit Anti-Join gegen `tmp_if_kurs`
  **nur auf die ISIN** und 65-Tage-Filter (`DoFiles(1)`, der Fallback), `3` = Out-of-bounds, nie
  aufgerufen. `M_FP_DLD.CPP:127` ruft `DoFiles(1)` und `DoFiles()`. Nicht die Plausi, nicht
  Kennzahlen, nicht die Einspielung. Die Programmhilfe zu `TempPreise4Vortag` ist falsch (liest
  `tmp_if_kurs`).
- **Schreiben** (`WriteLastKurse`, `preisekennzahl.cpp:1226-1345`): delete-then-insert je Code mit
  Schlüssel `(num_okb, cod_waehrung, cod_preiscode, cod_ex='N')` — **ohne `dat_kurs`, ohne
  Datumsvergleich**: zuletzt verarbeitet gewinnt, auch mit älterem Preisdatum. `cod_ex` hart
  `'N'`; Aufruf außerhalb `if (nRet == 1)`, hängt nicht am Erfolg des `kurs`-Writes. Zwei
  Konzeptstellen behaupteten „nur wenn Preisdatum neuer“ — falsch.
- **`DeleteLastKurse`** (`:1849`, SQL `:1939` mit Spalten `waehrung`/`cod_fliesscode`, die die
  Tabelle nicht hat) ist toter Code. Ein `D` löscht in `kurs`, lässt `tmp_if_last` stehen: **der
  zurückgezogene Preis wird im Lauf-1-Fallback erneut veröffentlicht.**
- 65 ist ein **Lesefilter**; gelöscht wird nur 35 Tage nach Fondsende und bei leerer ISIN
  (`CleanUpTmpIfLast`, `m_fp_rec.CPP:5555ff`, nur Inland; `c_preise.cpp:250`, `:450-472`).
- **Der einzige lebende Unterschied zu `kurs` ist die Preiswährung** (plus die Reihenfolge-Semantik
  „zuletzt verarbeitet“). Alle `I2`-Spalten stehen in `kurs` (plus `ASF`, `wkn_desc`); `txt_bez`,
  `liefer_id`, `eintragezeit`, `intervall` werden gelesen, erreichen das Preisfile aber nicht.
  Spalten: `num_kurs float`, `txt_bez` = gelieferte Fondsbezeichnung, `liefer_id` = **Lieferant**
  (nicht ein Job), `eintragezeit` = Ankunft im Eingang, `intervall` seit 2017 leer.
- Zweck des Fallbacks ist nirgends dokumentiert (Klärung **N**); ob KUPL/KMS die Tabelle direkt
  lesen, ist Klärung **O**.

### Der Währungsfall im Detail (USD-Tranche, Preis mit Währungscode EUR)

| Stufe | Verhalten | Wer erfährt es |
|---|---|---|
| Eingang | angenommen (`isinwaehrung = N`) | niemand |
| Preisfile | ausgegeben als `I2;Datum;EUR;ISIN;R;Wert` — beim Bezieher ein Upsert auf (ISIN, Datum, Währung, Code) | der Bezieher, ohne es zu merken |
| `kurs` | still verworfen, eine Logzeile; `tmp_if_last` bekommt die Zeile auf (ISIN, EUR, R) | eine Logzeile |
| Fallback | an jedem Tag ohne Lieferung dieser ISIN erneut als `I2`, bis zu 65 Tage (Anti-Join nur ISIN) | der Bezieher |
| späteres `D` in EUR | löscht nirgends etwas, Fallback läuft weiter | niemand |

Kein Auslandsthema: die Inlandskette (`-R0`) ist Gegenstand des Umbaus; Ausland (`-R1`,
`run_af_lieferung`, `af_kurs`, kein `tmp_if_last`-Fallback) nicht. Codes über
`tax_code.inland_ausland`: `R/E/Z` = `IA`, `S/S2/S3` = `I`.

---

## 6. Preisfile und Filegenerierung (`preis_dld.e -fPREISE`)

- Satzarten `I1`/`I2`/`I3`/`I9`; **kein `I4`** im inländischen `preis.csv`: Preis-Streams ohne
  `SetFlag()` (`M_FP_DLD.CPP:243-257`), `GetOutAktionscode` (`m_fp_rec.CPP:5649-5698`) liefert bei
  `nFlag == 0` `D` → `3`, sonst `2`. Der Bezieher upsertet auf (ISIN, Preisdatum, Währung, Code).
  Legacy schreibt jede am Tag empfangene Zeile ins File, also auch identische Nachlieferungen zu
  älteren Stichtagen (No-op-Upsert beim Bezieher). Das `I3` trägt das File nur am Tag der Löschung.
- `ReadAusschuettung` (Spalten 7–9: Ex-Code `EA`, Betrag, Zahltag) liest `ASF` mit
  `<preisdatum> between ASF_DATUM and isnull(aussch_datum, ASF_DATUM)` und
  `isnull(ausschuettung,-1) >= 0` — **ohne `aussch_status`, ohne `waehrung`, ohne `order by`**,
  erste Zeile gewinnt (`aussch_status` ist im PK: `'A'`, `'V'`, `'D'` können koexistieren).
  `makeAusOhnePreis` schließt `'V'` dagegen aus und joint die Währung.
- Die Filegenerierung liest `kurs` **nicht** (kein `kurs..kurs`-Zugriff in `m_fp_rec.CPP`/
  `M_FP_DLD.CPP`) und prüft die Fondswährung nirgends.
- Dateinamen `preis.csv`, `solva.csv`, ein `pr_ready.txt`; `-N<nr>` für Fondspreise ungenutzt, nur
  T2S kann `<YYYY-MM-DD_HH-MM>_preis.csv`; das Formatblatt `2025_Funddata_Provision.xlsx` (V2.0, ab
  17.11.2025) kennt eine Lieferung pro Tag → Klärung **F** für zwei Läufe.
- Zielgruppenfilter: `INV.veroeffentlichung` (A/V/K/N/X), `cod_art_f` (TEST/AIF), `FONDS_ZGRU`
  (`cFondsRecord::ReadStammdaten`). Verteilung (MFT, NetApp, Ready-File) nicht transaktional.
- Bereitstellungs-ZIPs für Schnitt 5 liegen in `docs/Fondspreise/beispiele/testdaten_september.zip`
  (`Bereitstellung/preis*.zip`, 5 Stück).

---

## 7. Plausibilität und Fehlmeldung

- `makeAbweichung` = Abschnitt 15 (`m_fplausi.cpp:2377-2520`, `preise_check`-Toleranzen) —
  **entfällt** (Entscheidung 14; „nur 15, nicht 17“ mit Markus bestätigen, Klärung 14);
  `makeCorrelationERZ` = 17 (`Plausi_Abweichung_ERZ` 20 %); 18–20 `makeAusOhnePreis`,
  `makeVorlAusOhnePreis`, `makeVorlAusIdentDemPreis` → Sammelreport. `makeGleicherKurs` („5 mal
  derselbe Preis“) existiert im Code nicht; `GleichePreise4Log` ist toter Text.
- `pdPreis_ber` wird in `cPreisPlausi::BerichtigePreise()` (`m_fplausi.cpp:193-208`) lokal
  gerechnet; das Kennzahlenergebnis lesen Plausi und Files nirgends.
- **Tagesjob-Schritt 9 (`-P2`, `m_plausi4tag_preise.cpp`) ist schon ein Fehlmeldungs-Report**:
  Quelle `kurs` mit `'R'`, Fenster 3–11 Börsetage, Empfänger Fachabteilung. Selektion `DoCheck()`:
  `INV.status = 'A'`, `cod_art_f in ('FOND','TECH','C-PL')`, am Stichtag lebend, `KAG < 10000`,
  `INV.preismeldung = 'TGL'` (`:265`; das Seed `ins_preismeldung.cr` kennt nur `U`/`Y`).
- Stammdatenprüfungen melden statt zurückzunehmen: `makeNichtVorhanden`, `makeFondsNotInINV`,
  `makePreisVorFondsBeginn`, `makePreisNachFondsEnde`, `makePreisNichtInFondswhrg`, `makeVorlFonds`.
- Datenbasis Fehlmeldung: `INV.preismeldung` → `ifas..preismeldung`, `INV.KAG`,
  `kurs..KAG_lieferanten (KAG, liefer_id)` n:m, `lieferanten.liefer_typ = 'F'` — siehe Klärung **J**.

---

## 8. Kennzahlen — nur die Naht

- EZB-Referenzkurs nur für währungsbereinigte Performance/Volatilität bei Fremdwährungsfonds
  (`fondskennzahl.cpp:2208`, `:3386`; `Kurse2EUR4AbsVol :4843`).
- `dR_faktor = (dNav + dAusschuettung) / dNav` (`fondsbasis.cpp:1960ff`), ohne Kurs `-1`;
  `r_faktor_ges` kumuliert vorwärts (`MakeNextReinvestFaktor`); `ASF.r_faktor` schreiben **beide**:
  Ausschüttungs-Einspielung (`asfkennzahl.cpp:921`, `:1156`) und Preis-Einspielung bei Korrektur
  (`preisekennzahl.cpp:3072`) → Klärung **K**.
- Formelwechsel per Datum (`StetigeVolaAb`, `PerfYtdFbY1Neu`, beide 2007-01-01) bleiben Konstanten.
- Kennzahlen-Ist-Analyse (`preisekennzahl.cpp`, `fondskennzahl.cpp`, `c_calc.cpp`) fehlt —
  Voraussetzung für Schnitt 6.

---

## 9. Datenlage (TEST-Abzug ~2026-08-29 und GAST; Abfragen in [fondspreise-lieferant-isin-analyse.sql](fondspreise-lieferant-isin-analyse.sql))

| Befund | Zahl / Ergebnis |
|---|---|
| `tax_code` produktiv (V1) | `L1`–`L3` mit `lieferung_ab` 2026-03-01, `isinwaehrung='J'`, `max_nk=8`; `R/E/Z` Untergrenze 1.0E-8; `S` −100…150, `S2`/`S3` −100…1250; `X` fehlt in `tax_code` (nur `v_preiscode`), nicht lieferbar; `max_nk` für `R/E/Z/S/S2/S3` null. GAST-Export 2026-09-03 in `standard_TAX_CODE_data.yaml` (57 Zeilen) |
| `INV.preismeldung` (Q5) | `TGL` existiert und ist aktiv (`U`/`Y` inaktiv, Seed veraltet); **4549** aktive inländische TGL-Fonds ≈ 4200 Preise/Tag |
| Preis-Lieferanten (Q0–Q4, F1–F5) | die `F`-Typisierung ist tot: alle 29 `fp_*`-Konten inaktiv. Über die aktiven `A`-Lieferanten hat jeder meldepflichtige Fonds einen Adressaten (F3 = 0), aber `KAG_lieferanten` mischt STM- und Preis-Lieferanten; nur `db_spard` heißt „AT-Fonds Preise“ und hat als Rückmeldeadresse abi@oekb.at. **Wer je KAG Preise liefert, steht nirgends maschinenlesbar** (J) |
| `ASF`-Status (Q9–Q11, F6) | keine A/V/D-Koexistenz je (Fonds, Tag), kein `D`, keine mehrdeutigen Treffer; 95 V-only-Schlüssel, 93 davon unmittelbar vor der Aktivierung (31.08.–02.09.), 2 in der Zukunft → der Preis vor `run_asf_vorl` zieht die vorläufige Ausschüttung ins File; Neusystem filtert `'A'` = bekannte Abweichung |
| Ausschüttungen ohne Preis (Q12) | Q12a leer (jede aktive Inland-Ausschüttung hat inzwischen ihren `R`-Kurs); Notausgang `X`: 83 Kurse seit 2008, 69 an Ausschüttungstagen, zuletzt 1–3/Jahr |
| `ASF.r_faktor`-Lücken (Q13, F7) | seit 2012 ~1–3 %/Jahr (2026: 87 von 2934); 706 mit `ausschuettung > 0` (echte Lücken, brechen die `r_faktor_ges`-Kaskade), 106 Null-Ausschüttungen |
| `pool_if_kurs` (V2) | 4767 Zeilen, tot seit 2012-03-30, keine Duplikate |
| `tmp_if_last` (V3) | 30 668 Zeilen, 14 604 im 65-Tage-Fenster, 906 mit heute nicht auflösbarer ISIN (Altlasten), `cod_ex` durchgehend `'N'` |
| `kurs.guelt` (V5) | aktuell gepflegt, aber 29,5 Mio Altzeilen NULL |
| Rückmeldungen (Archiv 01.–08.09.2026) | 103 Preismeldungs-Antworten aus 10 Lieferantenverzeichnissen, 46 STM-Antworten, 5 Bereitstellungs-ZIPs |
| Inbox-Volumen | ~26 k Zeilen/Tag |

**Noch zu erheben:** Q4/V4 auf Prod nach Lieferschluss (Tagesvolumen je Lieferant); **V6**
(`tmp_if_last` gegen `kurs` klassifiziert: ISIN nicht auflösbar / Währung ≠ Fondswährung / kein
Kurs zum Datum / jüngerer Kurs / aktuell — quantifiziert O/P; Fassung mit `#lp`-Zwischentabelle
liegt bereit, auf GAST ausführen); Häufigkeit der Währungsprüfung je Code, Lieferant und Tag über
mehrere Liefertage; identische Nachlieferungen je Tag und Lieferant aus dem Preisfile-Diff; die
produktiven INI-Werte (`PREIS_DLD.INI`, Fondspreis-`CONFIG.INI` liegen nicht im Repo);
`AllowOldPreisFormat`/`AllowTxtExt4PreisFile`; `MFT_*.INI`; vollständiges `fplausib.txt`;
aktuelle `preis.dtd`; `datum_min`-Richtung.

---

## 10. Aussagen der Fachabteilung und Klärungen

### Aussagen (datiert)

- **2026-09-01 (Markus/Fachabteilung):** Lauf 2 als Delta („diese erhalten nun 2 reports“); „Alles
  was zu einem bestimmten Zeitpunkt vorhanden ist wird verarbeitet, der Rest am nächsten Tag“
  (Tagesjob vollautomatisch); Fehlmeldung an Fachabteilung oder Lieferant; Lieferketten-Transparenz
  „New, Delete, New…“; Preis für beendeten Fonds bleibt zulässig; `makeAbweichung` entfällt;
  Ausschüttung ohne Preis melden.
- **2026-09-08 (User):** Ausschüttungen bleiben Batch mit drei Läufen; Sammellauf 1 **vor**
  Ausschüttungs-Job 3. Befund dazu: Lauf 2 muss **nach** Job 3 (16:00) liegen, sonst fehlt dessen
  Buchung im Delta; „~14:00 / ~16:00“ löst das nicht (Vorschlag 16:30).
- **2026-09-17:** (1) „Ein Preis, der die Prüfung nicht besteht und nicht in `kurs` landet, darf
  auch nicht an die Bezieher — auch nicht als Fallback.“ Heute das Gegenteil. Stiftet die
  Invariante **veröffentlicht ⊆ in `kurs`**; damit ist `tmp_if_last` aus `kurs` bzw. dem Ledger
  ableitbar. (2) „Das Ausschüttungs-Veto hält nicht. Eine gebuchte Ausschüttung darf keine
  Operation des Preislieferanten blockieren; stattdessen sind Folgerechnungen (berichtigter Preis,
  Kennzahlen) zu invalidieren.“ → **E3**, das Veto entfällt; die Preisdomäne darf `ASF.r_faktor`
  invalidieren, gebucht wird er von der Ausschüttungsdomäne (Antwort auf K).
- **2026-09-24:** Stammdaten gelten zum **Stichtag** der Zeile; nachträgliche Stammdatenänderungen
  werden nicht berücksichtigt. Währungsprüfung: `isinwaehrung = J` für `R/E/Z/S/S2/S3` **nur im
  Neusystem**, Lieferanten bekommen `ERR_CURRENCY04` ab Go-live; wann das Flag gesetzt wird
  (Parallelbetrieb oder Umstellungstag), ist offen — erst messen.
- **2026-09-25 (User, aus den Unterlagen):** das tägliche Preisfile soll in erster Linie den letzten
  in `kurs` veröffentlichten Preis liefern, sonst den vorherigen — `tmp_if_last` wird vermutlich
  nicht mehr gebraucht (N); eine identische Nachlieferung ändert für den Bezieher nichts. Mit der
  Fachabteilung nur noch bestätigen.

### Fragen an die Fachabteilung (Stand 11.09., Fallback und Währung; noch zu stellen)

1. Ist ein Preis in anderer Währung als der Fondswährung fachlich zulässig, oder ein
   Datenqualitätsproblem, das nur niemand blockiert? — **Antwort vom 17.09.: nicht an die Bezieher.**
   Folgefrage: Eingang ablehnen (Flag `J`, Urteil `ERROR`, Lieferant sieht es) oder still
   aussortieren? — **entschieden: am Eingang, nur Neusystem.**
2. Darf ein per `D` zurückgezogener Preis im Fallback erneut erscheinen, soll auf die Vorversion
   durchgegriffen werden, oder fällt der Fonds an dem Tag aus dem File? (**P**, Rest)
3. Wozu dient der Fallback aus Sicht der Bezieher: verpassten Preis nachliefern oder täglich eine
   Zeile je Fonds? (**N**; N2 kippt „Lauf 2 als Delta“)
4. Lesen KUPL/KMS `tmp_if_last` direkt, welche Spalten? (**O**)
5. Soll der Lieferant erfahren, dass seine Löschung eine gebuchte Ausschüttung entwertet hat? (E3)
6. Was sehen Kennzahlen-Leser zwischen Invalidierung und Nachrechnung — nichts oder „veraltet“? (C)
7. Braucht ein Bezieher künftig einen Änderungsstrom statt eines Standes (IFASNXT per SSIS)?
8. Soll „fehlt“ in der Fehlmeldung „keine gültige Version heute“ heißen, und soll sie *nie
   geliefert*, *übersprungen* und *zurückgezogen* unterscheiden?
9. Hat es Mehrwert, wenn ersichtlich ist, dass derselbe Preis neuerlich geliefert wurde? —
   **im Design vom 30.09. ohnehin sichtbar** (jede wirksame Zeile ist eine Version).

### Klärungen — Stand 2026-09-30

| Punkt | Frage | Stand |
|---|---|---|
| A | Wann läuft der Sync? | geschlossen: pro Lieferung, sofort; **30.09.: Verarbeitung als Folgejob nach dem Eingang, Sybase-Ableitung als weiterer Folgejob** |
| B | `tmp_if_last` geführt / Abfrage | B3 (Projektion) → **30.09.: aus dem Ledger abgeleitet**, Folgejob; Spaltenquellen im Plan |
| C | Kennzahlen: Invalidierung oder Auftrag | C1 faktisch; Auslöser = Beenden einer `R`-Version; Rest (Sichtbarkeit „veraltet“) offen |
| D | Rücknahme eines berichteten Preises | explizites `I3` gegen das Publikationsprotokoll; bekannte Abweichung |
| E | Ausschüttungs-Veto | **E3** (17.09.): ausführen, Abhängiges invalidieren |
| F | Dateinamen/Ready-File für zwei Läufe | offen, Fachabteilung/Bezieher |
| G | LMT persistieren/weitergeben | offen |
| H | Ausschüttung ohne Preis zur Eingangszeit melden | offen (Markus/Fachabteilung) |
| I | Sweep ohne Referenzkurs | Voreinstellung I1, I2 konfigurierbar; fachlich offen |
| J | Preis-Lieferant je KAG, Empfänger der Fehlmeldung | Datenlage vollständig, Frage verschärft (Abschnitt 9) |
| K | Wem gehört `ASF.r_faktor` | teilweise durch E3 beantwortet; Rest mit Markus vor Schnitt 6 |
| L | Vorrang Preis-/Ausschüttungs-Einspielung | Empfehlung O1 + O3; Terminbefund Lauf 2 nach 16:00 |
| M | Darf `kurs` eine Spalte bekommen | **nein** (02.09.): Sybase schema-gesperrt, Alt wie Neu; nur neue Tabellen nach Postgres |
| N | Zweck des Fallbacks | offen; Vermutung N1 (25.09.) |
| O | Fremdleser von `tmp_if_last` | offen |
| P | Gelöschter Preis im Fallback | Währungshälfte beantwortet (17.09./24.09.); `D`-Hälfte offen |
| 13 | `ERR_DATE04` nur für `R` — Kommentar oder Code? | offen |
| 14 | Nur Plausi 15 entfällt, nicht 17? | offen (Markus) |
| — | „LMT = Liquidity Management Tools“ bestätigen | offen |
| — | `INV.status`/`fonds_beginn`: welche Aktivierungsvariante, braucht es den Preis-Auslöser | offen (Stammdaten-Feature) |
| — | `ASF` wird von der Ausschüttungs-Kette nach Postgres geschrieben, obwohl Alt-Tabelle (Verortungsregel) | mit Markus/Ausschüttungs-Team klären |

---

## 11. Constraints des Neusystems, die das Design geprägt haben

Aus dem Code verifiziert (Stand `master` 2026-09-30) bzw. aus den Reviews vom 24./25.09.

| Constraint | Befund | Fundstelle |
|---|---|---|
| **Transaktion über mehrere Datenbanken** | `SynchronizingTransactionManager` enrollt je berührtem db-key eine Datenbank, flusht **alle**, committet dann **nacheinander** (best-effort 1PC, kein XA). Scheitert ein späterer Commit, bleiben die früheren, `PartialCommitException` nennt die Seiten. Ein Kontext, der auf einen schon enrollten Key auflöst, wird nicht erneut enrollt: **ein Key = ein Commit** | `support-libs/multidbctx-support/.../SynchronizingTransactionManager.java` |
| **db-keys je Profil** | job-system und business-new-introduced: `postgres-server` im Deployment und im GAST+Postgres-Profil, `postgres-localhost-7432` lokal; **nur der H2-only-Launcher trennt** (`h2-infra-db` / `h2-db1`). Sybase (`business`) ist immer ein eigener Key | `application-server-deployment.properties:24,43`; `application-local-h2-only.properties:18,35` |
| **Test-Blindfleck** | in den Tests zeigen alle Kontexte auf dieselbe H2; falscher Seed-/Lesekontext fällt erst im Deployment auf (Beleg: `tax_code` wurde im Fondspreise-Kontext geseedet, im Business-Kontext gelesen — `f89c5d06b`) | Memory `project_db-context-blind-spot-in-tests` |
| **Verortungsregel** | Tabellen, die es im Altsystem gab, füllt IFAS-neu weiter in der Sybase (Fremdleser lesen sie auch nach der Ablöse); neue Tabellen nach Postgres, Business-Tabellen **nicht** nach `infra`; Sybase-Migration 2027. Kontext dafür heißt `business-new-introduced` (kodiert die Regel, nicht das Feature, `2da0312a7`) | Entscheidung M; Tracker 2026-09-14 |
| **Inbox beim Job-System** | `preismeldung_zeilen` hängt über `(job_id, zeilen_nr)` am Job, liegt in `ifas-persistence-infra`, FK auf `jobs` ohne Cascade (wie `job_workload_items`); `tax_code` wird im **Business**-Kontext gelesen | V061, V067, `PreismeldungZeile.java` |
| **Keine partiellen Indizes in H2** | „höchstens eine offene Zeile“ braucht eine Markierungsspalte + Unique-Index; NULLs sind in Unique-Indizes auf Postgres und H2 verschieden | `V035__jobs_daily_run_number.sql:16-25` |
| **`numeric` ohne Skala** | H2 `numeric` ohne Skala hält alle Stellen und streicht Nachnullen (`101.2`), Postgres behält die Eingabeskala (`101.20`); `numeric(p,s)` rundet still. `max_nk` ist für `R/E/Z/S/S2/S3` null → keine feste Skala. Gleichheit nur per `compareTo` (`BigDecimals.equalsIgnoreScale`) | Probe H2 2.3.232 `MODE=PostgreSQL`, 2026-09-24 |
| **DB-Uhr** | `DatabaseContextHelper.getCurrentDbUser()` zeigt das Muster (Routing-`JdbcTemplate`); ein `currentDbTime()` daneben gilt für Postgres/H2, nicht Sybase | `DatabaseContextHelper:40,76` |
| **`timestamptz`** | H2 kennt es nicht; `timestamp(6) with time zone` schreiben; Engine-spezifische DDL über `${pg-only}`/`${h2-only}` | `DbConfigs:66-90`, V068 |
| **Temporal-Typen** | alle drei `java.time`-Typen einig über den Instant; Offset-Typen speichern UTC auf Sybase/Postgres, Wien auf H2 | Memory `project_temporal-type-storage-per-dbms` |
| **Nebenläufigkeit je Engine** | Postgres READ COMMITTED wertet das Prädikat nach dem Warten neu aus (0 Zeilen) oder wirft Unique-Verletzung; H2/MVStore wirft nach `LOCK_TIMEOUT` eine Sperr-Ausnahme → Tests dürfen den Ausnahmetyp nicht prüfen | Review B10 |
| **Claim-Muster** | `job_workload_items.processing_id`/`processing_job_id` (V065), `claimItem` als bedingtes Update | `WorkQueueItemRepository:79` |
| **Work-Queue-Handler läuft in einer Transaktion** | `doTransactional` würfe „Unexpected active transaction“ → eigene Transaktionen als REQUIRES_NEW (`with…IsolatedTransactional`) | `WorkQueueExecutor:347` → `:484` |
| **Retry und Mail** | Support-Mail erst nach dem letzten Versuch; `defaultMaxAttempts` = 1 | `WorkQueueExecutor:388-390`, `WorkQueueProperties` |
| **Jobs** | jeder Jobtyp führt seine Spalten selbst (Muster Ausschüttung: produktiver und Diff-Job duplizieren sie); Parent-Link `jobs.parent_id` (V069) für Folgejobs; Wiederholung über `repeatedFromJob`; produktive Meldungs-Jobs werden nie gelöscht, Archivieren ist ein Flag | `AusschuettungsMeldungJob`, `JobService:104`, `Job.java:85` |
| **Eingang heute** | Inbox-Transaktion → Filestore → `updateResult` in drei Schritten; Retry ersetzt die Zeilen (`deleteByJobId`) — muss write-once werden | `PreisMeldungDiffJobExecutionService:111-113`, `:136` |
| **Stammdaten-Cache** | `findFonds` cacht nur nach ISIN, der erste Stichtag gewinnt | `PreismeldungStammdatenService:50-51` |
| **Bulk statt je Schlüssel** | ~26 k Zeilen/Tag, Dateien mit tausenden Schlüsseln: lesen in Bulk, falten im Speicher, nur der Schreibpfad in fester Schlüsselreihenfolge | Review B12 |
| **Sybase `char`-Padding** | `cod_fliesscode char(2)` liefert `"R "`, `cod_art_f char(4)` `"AIF "`; `@Convert` greift auf `@Id` nicht → trimmende Getter. Hibernate flusht Inserts vor Deletes → Re-Insert desselben Schlüssels überholt das Delete (mit `ignore_dup_key` still) → JPQL-Bulk-Delete | `Kurs.java`, `TmpIfLast.java` |
| **jTDS** | Calendar-AIOOBE unter jTDS ist Hibernates geteilter `UTC_CALENDAR`, nie schlechte Daten; Produktname exakt „ASE“ | Memory `project_jtds-shared-calendar-race` |
| **Flyway** | ein File je Feature und Baum, gleiche Nummer; vor jedem Merge gegen `origin/master`, `stable`, `production` und Siblings prüfen; Modul installieren, sonst testet man das stale Jar | `mathias/rules/flyway-*.md` |
| **Web-UI** | kein npm/webjars/CDN; das Layout zieht nur `~{::section}`; `@ControllerAdvice` mit `assignableTypes` scopen | Memory `project_web-ui-frontend-constraints` |
| **Ausschüttungs-Keys** | `ausschuettung-tmp-db-key`/`ausschuettung-asf-db-key` hängen an `@Value` mit eigenem `// todo`; `ASF` nach Postgres widerspricht der Verortungsregel — fremder Code | `AusschuettungWorkQueueHandler:46,50` |

---

## 12. Offene Punkte der Ist-Analyse (Kapitel 10) — was seither beantwortet ist

| # | Punkt | Stand |
|---|---|---|
| 1 | `MFT_*.INI` fehlen | offen (Betrieb) |
| 2 | produktive `tax_code`-Zeilen | **erhoben** (V1, GAST-Export 2026-09-03 als YAML im Testdatenmodul, im Standard-Basisimport) |
| 3 | `preise_check`-Toleranzen | gegenstandslos (Abschnitt 15 entfällt) |
| 4 | INI-Werte auf dem Server | offen; Defaults aus dem Quelltext bekannt (Abschnitt 4) |
| 5 | `fplausib.txt` abgeschnitten | offen |
| 6, 7, 8, 9 | Solva-Datumsformat, `preis_a.csv`, TXT-Einstellung, `preis.dtd` | offen (Schnitt 4/5) |
| 10 | `datum_min`-Richtung | offen (Fachabteilung) |
| 11 | LMT-Persistenz | Klärung G |
| 12 | `makeGleicherKurs` | existiert nicht; fachlich offen |
| 13 | produktive `INV.preismeldung` | **erhoben**: `TGL` aktiv, 4549 Fonds |
| 14 | `Referenzkurs_Tage`, `CalcOhneReferenzkurs`, `Preis_Min/MaxTage4Meldung` | offen (INI) |
| 15 | `aussch_status`-Koexistenz | **erhoben**: keine; 95 V-only vor Aktivierung |
| 16 | Zirkel-Häufigkeit | **erhoben**: `X` 83/69 seit 2008 |
| 17 | `Del_Protokoll`, `Nachrechnung` | **entschärft**: `del_protokoll` hat keinen Leser, wird nicht portiert |

Weiter offen aus dem Konzept: `fondspreise-legacy-analyse.deck.html` ist veraltet (zeigt `I4`, 26
Sektionen gegen 53 Abschnitte) — neu erzeugen oder löschen.

---

## 13. Was dieses Dokument ersetzt

Archiviert unter `plans/archive/2026-08/` bzw. `2026-09/`: `2026-08-31-fondspreise-legacy-analyse.md`
(der Plan, der die Ist-Analyse erzeugt hat), `2026-08-31-fondspreise-neuentwicklung-konzept.md`
+ Deck (Zielarchitektur mit fünf Jobs, Entscheidungen 1–15 und A–P, Änderungsprotokoll Runden
1–10; die Stufe-2-Hälfte ist durch den Plan vom 30.09. ersetzt, die übrigen Schnitte 3–8 stehen im
Tracker), `2026-09-02-…-schnitt1-…` (umgesetzt), `2026-09-08-…-schnitt2-…` und
`2026-09-10-…-ap4-…` (Guard-Design, verworfen), `2026-09-08-…-tagesablauf-…` (Deck + Begleitblatt,
Inhalt in Abschnitt 1), `2026-09-11-…-fachabteilung-fragen-…` (Abschnitt 10),
`2026-09-17-…-preis-ledger-formen/-er-diagramme` (Formen A/B/C; Legacy-Teile in Abschnitten 0, 3,
5, 6), `2026-09-24-…-preis-historie-zeitreihe` + `-review` (Constraints in Abschnitt 11).

**Was bleibt:** dieses Dokument, der Plan vom 30.09., `tracker.md` (Status), das SQL-File.

## Quellen

| Quelle | Inhalt |
|---|---|
| `docs/Fondspreise/fondspreise-legacy-analyse.md` | Ist-Analyse, 10 Kapitel, Kapitel 10 offene Punkte |
| `docs/Tagesjob und Programmablauf/` | Crontab, Tagesjob-Logik mit Checkpoints, Event-Logging, Wartungsbildschirm |
| `docs/Fondspreise/*.pdf`, `2025_Funddata_Provision.xlsx`, `fplausib.txt` | Confluence-Exports, Lieferformat V2.0/V3.0 (LMT), Ausgabelayouts, Beispielreport |
| `docs/Fondspreise/beispiele/testdaten_september.zip` | MFT-Archiv 01.–08.09.2026: 103 Preismeldungs-Antworten, 5 Bereitstellungs-ZIPs |
| `Ifas/cprogs2/preise4/` (`M_INSERT.CPP`, `m_fp_rec.CPP`, `M_FP_DLD.CPP`, `m_fplausi.cpp`, `m_plausi4tag_preise.cpp`) | Eingang, Filegenerierung, Plausi |
| `Ifas/cprogs2/calc/` (`preisekennzahl.cpp`, `c_preise.cpp`, `fondskennzahl.cpp`, `asfkennzahl.cpp`, `fondsbasis.cpp`) | Einspielung, Kennzahlen, ASF |
| `Kurs/tabledefs/*.cr`, `Ifas/tabledef/*.cr`, `VWKN/tabledefs/` | Datenmodell |
| `fondspreise-lieferant-isin-analyse.sql` | Q0–Q13, V1–V6, F1–F7 mit Ergebnissen |
| `standard_TAX_CODE_data.yaml` (ifas-test-data) | produktive `tax_code`-Konfiguration |
