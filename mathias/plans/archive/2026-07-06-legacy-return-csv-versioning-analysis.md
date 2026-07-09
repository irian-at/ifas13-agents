# Analyse: Wie das Altsystem (C++) das Rückgabe-CSV schreibt & wo die Ermittlungsvorgabe-Version einfließt

**Quelle:** Legacy IFAS C++, `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/`
**Frage:** Wie wird das Return-CSV (ESTBREPORT / Steuerdaten-Meldung) geschrieben, und gibt es versionsabhängigen Code (Version der Ermittlungsvorgabe)?
**Kurzantwort:** Ja — das Output ist an drei orthogonalen Achsen versionsabhängig. Die Ermittlungsvorgabe-Version (`nVersions_nr`, 1–6) steuert ~1000 Verzweigungen: welche Spalten existieren, deren Werte und deren Validierung.

> Hinweis: Dateien im Legacy-Repo sind ISO-8859-1 kodiert und enthalten Bytes, die `grep` als „binary" wertet — immer `grep -a` verwenden, sonst kommt nichts zurück.

---

## 1. Der Schreibpfad des Return-CSV

Das Return-File wird **nicht** über `fopen`/`fprintf` erzeugt, sondern zeilenweise über einen `ostream & fOut` gestreamt (deshalb findet naives Grep nichts).

### 1a. Zweistufig: erst DB, dann Datei

1. **Berechnete Feldwerte → DB** via `cStFields::Save()` (`c_stfields.cpp:1913-1976`, BCP wenn `nUseBCP=1`, sonst INSERT):
   - `kurs.dbo.steuer_fields_data` — Felddaten ohne Länderdetails
   - `kurs.dbo.steuer_fields_data_details` — Felddaten mit Länder-/DBA-Details
   - `kurs.dbo.steuer_beh_fields` — Steuerliche-Behandlung-Records (`c_stbehandlung.cpp`)
2. **DB → Return-CSV** in separatem Lauf durch `cMakeStmFile::DoFiles()` (`m_stm_files.cpp:248-321`):
   - liest via `pcStM->ReadNext(...)` (`:269`) aus der DB zurück
   - schreibt via `pcStM->WriteMeldung(cStream[i].fOut, cStream[i].GetFlag())` (`:275`)

### 1b. Der Zeilen-Writer

`cSt_Meldung::WriteMeldung(ostream &fOut, int nVersion)` — `c_st_meldung.cpp:11874`:

```
WriteMeldung_START(fOut)      // "START;isin;art;ertragstyp;waehrung;gj_beginn;gj_ende;…"
WriteMeldung_STATUS(fOut,…)   // "STATUS;<status>;…"
WriteMeldung_EA(fOut)         // "EA;…"  (Ergänzende Angaben)
pcStF->Write(fOut, nVersion)  // Steuerfelder            (c_stfields.cpp:3955)
pcStBh->Write(fOut, nVersion) // Steuerliche Behandlung  (c_stbehandlung.cpp:1694)
WriteMeldung_END(fOut)        // "END"
```

Zwei physische Dateien pro Lauf (`m_st_meldung.cpp:907-908`):

```cpp
pcStM->WriteMeldung(fOut,      /* erweitert */ 0);   // volle Datei
pcStM->WriteMeldung(fOutSmall, /* small */     1);   // reduzierte Datei
```

**Wichtig:** Der `nVersion`-Parameter (`0`/`1`) ist die **Dateivariante** (erweitert vs. small), **nicht** die Ermittlungsvorgabe-Version. In `cStFields::Write` (`c_stfields.cpp:1699`) filtert `if (nVersion == 1)` Felder für die small-Datei aus. Die beiden „Versions"-Begriffe nicht verwechseln.

---

## 2. Die drei Achsen, die die CSV-Form bestimmen

| Achse | Variable / Ort | Wirkung |
|---|---|---|
| **Dateivariante** | `nVersion`-Param (0=erweitert, 1=small) | zwei physische Dateien; small lässt Felder weg |
| **Ermittlungsvorgabe-Version** | `nVersions_nr` (DB-Lookup Gj-Beginn × Stichtag) | welche Spalten existieren + Werte + Validierung |
| **DBA-/Zinsen-Blocktyp** | `strDba_typ` / `strZinsen_typ` je Felddefinition | in welchem Record-Block ein Feld steht |

DBA-/Zinsen-Blocktypen (aus `c_stfields.h:111-127`, kombiniert zu `strDba_Zinsen_typ`):
`X` = Basis, `A` = Ausschüttung (Subfonds), `D` = Dividende, `Z` = Zinsen, `ZA` = Zinsen Altemissionen.

---

## 3. Wie die Ermittlungsvorgabe-Version aufgelöst wird

Versionen liegen in DB-Tabelle `kurs.dbo.steuer_meldung_version` (`c_stm_version.cpp:261`), jede Zeile mit `versions_nr`, `gj_beginn_ab/bis`, `stichtag_ab/bis`, `beschreibung`.

- `cStmVersion_modul::Init(dbc, daDatum)` (`:571`) lädt die für den Stichtag gültigen Versionen (Filter `:233/:264`).
- `SetAkt_GjBeginn(daGjBeginn, daStichtag)` (`:665`) wählt die Zeile, deren Gj-Beginn **und** Stichtag in die Ranges fallen (`Exists`, `:420-421`):

```cpp
if (((cSVCodes[i].daGj_beginn_ab <= daPGjBeginn) && (cSVCodes[i].daGj_beginn_bis >= daPGjBeginn))
 && ((cSVCodes[i].daStichtag_ab  <= daPStichtag) && (cSVCodes[i].daStichtag_bis  >= daPStichtag)))
    return i;
```

- `GetAkt_Version()` (`:715`) liefert `nVersionsNr` → nach `cSt_Meldung::nVersions_nr` (`c_st_meldung.cpp:1293`).
- **Override:** CLI-Parameter `-V` erzwingt eine Version (`nUseVersion4STM`, `c_st_meldung.cpp:1255-1259`).
- **Recalc/historische Treue:** Beim Reprocessing wird die Version **nicht** neu aus Daten berechnet, sondern die auf der Meldung gespeicherte übernommen: `nVersions_nr = nAVersions_nr; SetAkt_Version(nVersions_nr)` (`c_st_meldung.cpp:12869-12870`). → Alte Versionen mit *ihren* Regeln rendern, nicht mit heutigen.

### Versions → Zeitraum (aus `c_st_meldung.h:589-599`)

| Version | Gilt für |
|---|---|
| 1 | ab 2016 |
| 2 | 2019 |
| 3 | 2019, für Geschäftsjahre **nach** 2019 |
| 4 | 2022 – ab 2023 |
| 5 | 2025 – ab 4/2025 |
| 6 | nächste Regime-Stufe (im Code als Gate `>= 6`, im Header-Kommentar noch nicht dokumentiert) |

Das erklärt die Häufung der Schwellen `<=2`, `==3`, `>=4`, `>=5`, `>=6` — jede ist eine gesetzliche Regime-Grenze.

---

## 4. Wo genau die Version das Output verändert

### 4a. Kern-Mechanismus: versions-getaggter Feldkatalog

Der Feldkatalog wird aus `kurs.dbo.steuer_fields` geladen; **jede Felddefinition trägt eine eigene `versions_nr`** (`c_stfields.cpp:2340`, Default 1) plus `veroeffentlichung`-Flag (`:2341`). Beim Schreiben werden nur Felder der aktiven Version ausgegeben (`cStFields_col::Write`, `c_stfields.cpp:3966`):

```cpp
if (cStmVersion_modul::GetAkt_Version() != cStF[j].nVersions_nr)
    continue;   // Nur die passende Version berücksichtigen
```

→ **Welche Spalten im Return-CSV erscheinen, ist rein versionsgesteuert.** Dieselbe Versions-Gleichheitsprüfung ist repliziert in `Check` (`:4019`), NaN/Inf-Prüfung (`:4047`), Feld-Lookup `Exists` by-name/by-code (`:2668/:2711`) und in `c_stbehandlung.cpp` (Save/Exists). `steuer_beh_fields` funktioniert analog (`c_stbehandlung.cpp:1002`).

### 4b. Hartkodierte Feld-Präsenz-Gates im Writer

- **`c_st_meldung.cpp:12022`** — Feld **`Art`**: in **Version 3** weggelassen (leeres `;`), ≤2 und wieder ≥4 vorhanden. Kommentar: *"das Feld Art soll in der Version 3 nicht ausgegeben werden, ab Version 4 erfolgt die Ausgabe wieder"*. Passende Pflichtfeld-Lockerung in `CheckVorhandeneMeldung` (`:8194`, `==3`).
- **`c_st_meldung.cpp:12156`** — Feld **`LEI`**: erst ab **Version 4** geschrieben (*"LEI neu ab Version 4"*; Validierung ebenso `:8025/:8081/:8133/:8655`).

### 4c. Versionsabhängige Feldwerte & Validierung (~1000 Verzweigungen)

Verteilung der `nVersions_nr`-Vergleiche über preise4:

| Datei | Anzahl |
|---|---|
| `c_stfields_calc.cpp` | 797 |
| `c_stfields_calc_stbh.cpp` | 168 |
| `c_st_meldung.cpp` | 31 |
| `c_stfields_calcdetails.cpp` | 23 |
| `c_stfields.cpp` | 5 |

Dominante Schwellen:

| Schwelle | Anzahl | Bedeutung |
|---|---|---|
| `>= 5` | 665 | großer Regelwechsel bei v5 |
| `<= 4` | 150 | Legacy-Pfad vor v5 |
| `>= 6` | 116 | weiterer Wechsel bei v6 |
| `>= 4` | 64 | LEI / Pflichtfeld-Ära |
| `==3`, `<=2`, `>=2`, u.a. | ~30 | v3-Art-Sonderfall, frühe Versionen |

Konkrete Wert-Änderung: Körperschaftsteuersatz `KoeSt_Satz` = **0.23 für v≥5, sonst 0.25** (`c_stfields.cpp:138`) — fließt direkt in zurückgelieferte Beträge.

Beispiel Liefer-Flag-Logik (`c_stfields.cpp:512-550`): bis v2 steuert der Fondstyp (`Art`, Pflichtfeld) das `strLieferFlag` (`strInvF`/`strImmoinvf`/`strAif`/`strImmoAif`); ab v3 generisch `strAif`.

Beispiel Fehlermeldungs-Templates: v<3 `ERR_FELD_NA_L`, v≥3 `ERR_FELD_NA_L_3` (mit Länderdetails) (`c_stfields.cpp:836`).

---

## 5. Fazit

Das Return-CSV ist ein gestreamter `START;… / STATUS;… / EA;… / <Felder> / END`-Echo, erzeugt über einen DB-Zwischenschritt. Es ist auf drei Achsen versionsabhängig: Dateivariante (erweitert/small), Ermittlungsvorgabe-Version (`nVersions_nr`, DB-Lookup auf Gj-Beginn × Stichtag) und DBA/Zinsen-Blocktyp. Die Ermittlungsvorgabe-Version bestimmt über einen versions-getaggten Feldkatalog **welche Spalten existieren**, über hartkodierte Gates die Präsenz von `Art`(@v3) und `LEI`(@v4), und über ~1000 Verzweigungen (v-Schwellen `<=4` / `>=5` / `>=6`) die **Werte und Validierung**. Beim Reprocessing wird die auf der Meldung gespeicherte Version verwendet — nicht neu berechnet.

---

## Datei-Referenzen (Legacy)

- `c_st_meldung.cpp` — Writer (`WriteMeldung*`), Versionsauflösung im Ablauf, Art/LEI-Gates, Reprocessing-Version
- `c_stfields.cpp` / `c_stfields.h` — Feldkatalog (`steuer_fields`), `Write`/`Check`/`Exists`, versions-getaggte Filterung
- `c_stfields_calc.cpp` / `c_stfields_calc_stbh.cpp` / `c_stfields_calcdetails.cpp` — versionsabhängige Berechnungen
- `c_stbehandlung.cpp` — Steuerliche-Behandlung-Felder (`steuer_beh_fields`)
- `c_stm_version.cpp` / `c_stm_version.h` — `cStmVersion` / `cStmVersion_modul`, DB `steuer_meldung_version`, Range-Match
- `m_st_meldung.cpp` / `m_stm_files.cpp` — Dateierzeugung (erweitert/small), DB→CSV-Lauf
