# Fondspreise — Ist-Analyse des Altsystems dokumentieren

## Context

Die Fondspreise sind in IFAS13 bisher explizit **out of scope**
(`docs/Technische Konzepte/ifas13-jobs.md:43-44`). Implementiert ist nur das Lieferformat der
eingehenden Preismeldung: `ifas-domain-fondspreise` mit dem Schema
`PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml`, `Meldekategorie`, `PreisAktion` und
`CsvPreismeldungValidations`. Es gibt **keine** Persistenz (kein `kurs`/`tmp_if_kurs`-Äquivalent in
den Flyway-Migrationen), keine Plausibilität und keine Filegenerierung;
`PreisMeldungDiffJobSubmissionService` ist ein Stub, der jede Lieferung als
`BadInputJob` mit "not yet implemented" ablegt.

Für die Portierung fehlt die Bestandsaufnahme. Die neu unter `docs/Fondspreise/` abgelegten
Confluence-Exports beschreiben den Soll-Ablauf grob, lassen aber genau die Details offen, die eine
Implementierung braucht: die Layout-Tabellen sind in den PDFs Bilder, die Schwellwerte stehen nur in
INI-Dateien auf dem Server, die Codelisten nur in der DB.

**Ergebnis dieses Schrittes:** eine Markdown-Datei, die die *bestehende* Funktionalität aus den
C++-Quellen und Batch-Scripts belegt (mit `file:line`), als gemeinsame Basis für die anschließende
Analyse und den Neubau. Kein Code, kein Design, keine Empfehlungen — reine Ist-Beschreibung.

## Entscheidungen (mit dem User abgestimmt)

- **Sprache:** Deutsch
- **Scope:** die komplette Fondspreis-Kette — Sammlung → Plausibilität → Filegenerierung →
  Einspielung in `kurs`. Ohne die Kennzahlen-/Performance-/Volatilitätsnachrechnung aus
  `Ifas/cprogs2/calc` (eigenes Themengebiet). Angrenzendes (STM, Ausschüttungen,
  Ausland-Taxdata, Meldefonds-Listen) nur als Abgrenzungsliste, damit klar ist, was die beiden
  Legacy-Programme *sonst noch* tun.
- **Ablageort:** `docs/Fondspreise/fondspreise-legacy-analyse.md`

## Quellen

Legacy-Repo `~/dev/projects/oekb/ifas` (alle `.cpp/.h` sind ISO-8859-1 → `grep -a` / `iconv`;
Achtung auf Groß-Extensions `M_INSERT.CPP`, `m_fp_rec.CPP`, `M_FP_DLD.CPP`):

| Bereich | Dateien |
|---|---|
| Sammlung | `Ifas/cprogs2/preise4/preis_ins.cpp`, `M_INSERT.CPP`, `c_insert.cpp/.h`, `c_param.cpp`, `m_lieferanten.cpp` |
| Filegenerierung | `preis_dld.cpp`, `M_FP_DLD.CPP`, `m_fp_rec.CPP`, `m_stamm.cpp`, `c_param_dld.cpp` |
| Plausibilität | `m_fplausi.cpp/.h`, `m_plausi4tag_preise.cpp`, `m_plausi4new.cpp` |
| Einspielung in `kurs` | `Ifas/cprogs2/calc/PREISE.CPP`, `c_preise.cpp/.h` |
| Codelisten / Basis | `Ifas/cprogs2/lib/c_preiscode.h`, `c_taxcode.h`, `c_msg.h` |
| Orchestrierung | `Ifas/scripts/{run_preise_all.csh,create_preise.csh,create_plausibel,create_plausi_taegliche_preise.csh,run_preise_einspielen,run_tagesjob.csh}`, `Ifas/scripts_mft/at/{run_preise,run_preise_einzel,make_einzel.awk}` |
| Datenmodell | `Kurs/tabledefs/*.cr` (`kurs`, `tmp_i_ku`, `tmp_i_last`, `tmp_i_co`, `pool_i_k`, `lieferanten`, `liefer_bugs`, `liefer_zeit`, `liefer_intervall`, `tax_code`, `preis_aktion`, `v_preiscode`, `KAG_lieferanten`), `Ifas/tabledef/{INV.cr,preismeldung.cr,del.cr}` |

Repo `docs/Fondspreise/`: Confluence-Exports (Programmablauf, Datenmodell, Plausibilität,
Filegenerierung, Parametrisierung), Lieferformat-PDFs V2.0 (2025) und V3.0 (2026, inkl. LMT),
`fplausib.txt` (Produktionsreport), 4 Beispiel-Lieferfiles,
`2025_Funddata_Provision.xlsx` — dessen Sheets `preis.csv`, `solva.csv` und `Codelist` enthalten die
exakten Ausgabe-Layouts (Version 2.0, gültig ab 17.11.2025).

## Gliederung des Dokuments

1. **Zweck & Abgrenzung** — was drin ist, was nicht; Verweis auf den Stand in IFAS13
2. **Überblick: die vier Stufen** — Tabelle Stufe → Programm/Parameter → Auslöser/Zeitplan →
   Quelle/Ziel → Logfile; dazu ein Ablaufdiagramm (mermaid) über
   `Lieferantenverzeichnis → tmp_if_kurs → {Files, Plausibilität} → kurs`
3. **Stufe 1: Sammlung (`preis_ins.e`)**
   - Verzeichnisbaum je Lieferant (`send/`, `receive/`, `archive/zipfiles/`), Steuerdatei
     `liefer.lst` aus Tabelle `lieferanten`, Aufruf `preis_ins.e -L… -E… -R0 -a -S… -I…`
   - Formaterkennung: Headerzeilen, Separator `;`/`,`, Spaltenanzahl → Format 1 (altes
     Standardformat, 17 Spalten), Format 3 (aktuelles Lieferformat, 10 Spalten), Format 5
     (Ausschüttungen); Flag `AllowOldPreisFormat`
   - Feldabbildung Format 3 ↔ Lieferformat V3.0 ↔ neues Java-Schema
   - Steuerung über `tax_code` (Gruppe PREIS/SOLVA/LMT/QUST/KEST, `untergrenze`/`obergrenze`,
     `max_nk`, `future`, `lieferung_ab/bis`, `datum_min/max`, `datum_bug_or_ignore`,
     `isinwaehrung`, `ignore_null`)
   - Vollständige Validierungs-/Meldungstabelle (Code, deutscher + englischer Text, Konsequenz)
     aus `c_param.cpp:285-620` plus die `BUG_*`-Statistikcodes
   - Duplikate, Korrekturen, Deletes (`INFO_DEL_*`, `DeleteTmpDeletes4Update`)
   - **LMT wird validiert, aber nicht gespeichert** (`M_INSERT.CPP:2049-2056`)
   - Zieltabellen `tmp_if_kurs` / `pool_if_kurs` / `tmp_tax`, `liefer_bugs`, `liefer_zeit`
   - Rückmeldung an den Lieferanten: error/info/statistics/data.log, ZIP in `receive/`,
     NetApp-Archivierung, Mail-Betreffzeilen
4. **Stufe 2: Plausibilität (`preis_dld.e -P`)** — Reportstruktur Abschnitt für Abschnitt mit den
   Originaltexten aus `fplausib.txt`, je Abschnitt die erzeugende Funktion, die Regel und der
   Schwellwert (`PreisGrenze4Log`, `GleichePreise4Log`, `Plausi_Abweichung_ERZ`,
   `Preis_MinTage4Meldung`/`MaxTage4Meldung`, `TempPreise4Vortag`); Vortag-/Börsetag-Ermittlung;
   `-P2` und `-P3` kurz abgegrenzt
5. **Stufe 3: Filegenerierung (`preis_dld.e -fPREISE`)**
   - Stream-Matrix: 11 Streams — `preis{,_v,_p}.csv/xml`, `preis_v.txt`, `solva{,_v,_p}.csv`,
     `solva.xml` — mit Zielgruppenfilter (`INV.veroeffentlichung` A/V/K/N/X, `FONDS_ZGRU`,
     `cod_art_f` TEST/AIF)
   - Satzaufbau CSV (Identifier `I2`/`I3`/`I4`, Datumsformat, Nachkommastellen,
     optionale Ausschüttungsspalten), TXT, XML/DTD; Header/Footer/`ANZAHL`; `pr_ready.txt`
   - Datenselektion: `tmp_if_last` zuerst, dann `tmp_if_kurs`; `Tage_TmpIfLast`,
     `Tage_TmpIfLast_Beendete`; Stammdatenanreicherung; Preiscode `X` wird nie ausgegeben
   - Verteilung (MFT-Ziele, T2S-Umbenennung) und `preis.zip` → NetApp; Querverweis
     `docs/Technische Konzepte/mft-interface.md`
6. **Stufe 4: Einspielung in `kurs` (`preise.e -p0`)** — `tmp_if_kurs` → `tmp_if_cop` → `kurs`,
   `tmp_if_last`-Pflege, Behandlung von Korrekturen und Deletes (inkl. `@DEL_R`: Löschen des
   errechneten Werts löscht den ganzen Preissatz), `del_protokoll` für IFASNXT, Auslösen der
   Nachrechnung (nur als Schnittstelle beschrieben)
7. **Datenmodell** — Spaltenlisten der zentralen Tabellen mit Schlüsseln und der Rolle von
   `cod_ex` (= Aktion, Teil des PK), Trigger-Übersicht
8. **Parametrisierung** — `PREIS_INS.INI`, `PREIS_DLD.INI`, `CONFIG.INI`: Key, Default, Wirkung,
   Fundstelle
9. **Codelisten** — Preiscodes/Meldekategorien mit Gültigkeitsbereich (`v_preiscode` inkl. `X`,
   `tax_code.gruppe`), `preis_aktion`, `INV.veroeffentlichung`, `INV.preismeldung`, Periodizität
10. **Offene Punkte / nicht aus dem Repo belegbar** — Inhalte der `MFT_*.INI`, die
    produktiven `tax_code`-Zeilen (insb. L1/L2/L3 fehlen in den eingecheckten `.cr`-Skripten),
    die tatsächlichen INI-Werte auf dem Server, die abgeschnittenen Abschnitte in
    `fplausib.txt`, Stand der TXT-Einstellung (Doku sagt 15.11.2025, `create_preise.csh` lädt
    `preis_v.txt` weiterhin hoch)

## Vorgehen

1. `docs/Fondspreise/fondspreise-legacy-analyse.md` nach obiger Gliederung schreiben; jede
   Aussage mit `file:line` aus dem Legacy-Repo (Pfade relativ zu `~/dev/projects/oekb/ifas`)
   oder mit der Confluence-/PDF-Quelle belegen. Meldungstexte und Dateinamen wörtlich.
2. Diagramme als mermaid-Blöcke (die Repo-Docs verwenden `.dot`/`.drawio`; mermaid bleibt im
   Markdown lesbar und braucht kein Rendering).
3. In `docs/Technische Konzepte/ifas13-jobs.md` den Eintrag "Fondspreise — out of scope" um einen
   Verweis auf das neue Dokument ergänzen (eine Zeile, kein inhaltlicher Eingriff).

## Verifikation

Kein Code — die Prüfung ist die Belegbarkeit:

- Jede `file:line`-Referenz im Dokument gegen die Quelle nachziehen
  (`sed -n '<n>p' <file> | iconv -f ISO-8859-1`), stichprobenartig über alle Kapitel.
- Die Feldabbildung Format 3 gegen die vier Beispieldateien in `docs/Fondspreise/beispiele/`
  prüfen (Spaltenanzahl, Dezimaltrennzeichen `.` und `,`, Datumsvarianten `YYYYMMDD` und
  `YYYY.MM.DD`, Periodizität `D`) — alle vier müssen von der beschriebenen Erkennung als
  Format 3 klassifiziert werden.
- Das beschriebene `preis.csv`-Layout gegen das Sheet `preis.csv` in
  `2025_Funddata_Provision.xlsx` abgleichen (7 Spalten, Identifier `STRING(2)`).
- Die Abschnittsliste in Kapitel 4 gegen `fplausib.txt` abgleichen; Abschnitte, die dort fehlen,
  im Kapitel "Offene Punkte" als "im Beispielreport nicht enthalten" kennzeichnen statt zu raten.
- Markdown-Tabellen und mermaid-Blöcke visuell prüfen (keine überlangen Zeilen, Tabellen
  schließen).
