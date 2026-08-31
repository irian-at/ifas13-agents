# Fondspreise — Konzept für die Neuentwicklung in IFAS13

## Context

Die Ist-Analyse des Altsystems liegt vor: `docs/Fondspreise/fondspreise-legacy-analyse.md`.
Sie beschreibt vier Stufen — Sammlung (`preis_ins.e`) → Plausibilität (`preis_dld.e -P`) →
Filegenerierung (`preis_dld.e -fPREISE`) → Einspielung (`preise.e -p0`) — mit der Sammeltabelle
`kurs..tmp_if_kurs` als Nahtstelle.

Dieses Dokument hält das **Zielkonzept** fest, das in der Diskussion vom 2026-08-31 entstanden ist.
Leitgedanke: **kein Nachbau der tmp-Tabellen.** Der Tagessammelzustand liegt in den Jobs des
bestehenden Job-/Work-Queue-Systems, nicht in einer geteilten veränderlichen Tabelle.

Vorhanden in IFAS13 ist bisher nur das Lieferformat (`ifas-domain-fondspreise`:
`PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml`, `Meldekategorie`, `PreisAktion`,
`CsvPreismeldungValidations`, `CsvPreismeldungen.loadCsvFile`).
`PreisMeldungDiffJobSubmissionService` ist ein Stub. Keine Persistenz, keine Plausibilität, keine
Filegenerierung, keine Verteilung.

Passend vorgefunden und wiederverwendbar:

| Baustein | Ort | Nutzen |
|---|---|---|
| `AbstractJobWorkQueueHandler` mit konfigurierbarem `completedStatus` | `service/job/` | Ingest-Job kann nach `READY_FOR_BATCH` abschließen, ohne den Basis-Handler zu umgehen |
| `StmCalcJobStatus.WAITING_FOR_START_OF_DAY` | `persistence/infra/calc/` | Präzedenz für einen Parkstatus (bisher unbenutzt, nirgends referenziert) |
| `(keyDate, laufnummer)` als Job-UK | `EstbDailyReportJob`, `FristenpruefungJob`, `MeldefondsListenJob` | Muster für mehrere Läufe pro Tag (STM fährt schon 3) |
| `ScheduledTask` + `triggerIfEnabledAndStichtagIsWorkday` + manueller Trigger | `IsinAnforderungslistenBatchJobScheduleService` | Cron, Werktagsprüfung, „Geplante Aufgaben"-Seite |
| `OrchestrationJobHelper`, serielle Verkettung | `service/job/`, „STM Lauf 1" | Reihenfolge-Auflagen zwischen Jobs ausdrücken |
| Ergebnisfiles am Job als Filestore-URI | `StmCalcJob.resultBundleFile` | Return-ZIP am Job |

`liefer_bugs` und `liefer_zeit` existieren in IFAS13 nirgends (kein Java, kein Flyway). Das
Lieferprotokoll lebt für STM bereits im Job. Das Konzept setzt das fort.

---

## Begriffe

Zwei Kürzel, die unten laufend vorkommen.

### Satzart-Identifier (`I2` / `I3` / `I4`) — im **ausgehenden** Preisfile

Die erste Spalte jeder Zeile in `preis*.csv` ist ein zweistelliger Identifier
(`m_fp_rec.CPP`, Ist-Analyse 4.3):

| Identifier | Bedeutung |
|---|---|
| `I1` | Header (Kursdatum, Erstelldatum, Erstellzeit) |
| `I2` | Preis, **Insert** |
| `I3` | Preis, **Delete** |
| `I4` | Preis, **Update / Korrektur** |
| `I9` | Footer (Anzahl Deletes, Inserts, Korrekturen) |
| `S1`/`S2`/`S3` | Solvabilität, Ziffer = Stufe |
| `D1`/`D2`/`D3` | Solvabilität, Delete |

`GetOutAktionscode` (`m_fp_rec.CPP:5986-5993`) bildet auf `2` = Insert, `3` = Delete,
`4` = Update ab; `0` bedeutet „nicht ausgeben, Satz bereits vorhanden".

Ein `I3` sagt dem Bezieher: **wirf diesen Preis weg.** Es ist das ausgehende Gegenstück zur
eingehenden Aktion `D`. Achtung auf die Asymmetrie: **eingehend** steht die Aktion als Buchstabe in
Spalte 6 des Lieferformats (`N`/`D`/`I`), **ausgehend** ist sie in den Identifier der Spalte 1
eingebacken. Die Entscheidung, ob ein `I3` das Haus verlässt, ist der Kern der D/N-Auflösung
(Entscheidung 4) und der offenen Punkte D und E.

### LMT — die Meldekategorien `L1` / `L2` / `L3`

Neu mit Lieferformat **V3.0** (2026, `docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf`);
die Vorgängerversion V2.0 (2025) kennt sie nicht.

| Code | Bedeutung | Wertebefüllung (Spalte 5) |
|---|---|---|
| `L1` | Rücknahmebeschränkung | Quote — Prozentzahl wenn Spalte 9 = `J`, sonst Geldwert |
| `L2` | Verlängerung der Rückgabefrist | Anzahl Tage; bei `0` trägt Spalte 10 den Stichtag |
| `L3` | Rückgabegebühr | Gebühr, Prozent oder Geldwert je Spalte 9 |

Dazu die zwei LMT-Felder des Lieferformats: `LMT_PROZENTKENNZEICHEN` (Spalte 9, `J`/`N`) und
`LMT_STICHTAG` (Spalte 10, nur bei `L2`). Die Aktion `I` (Inaktivierung) existiert
**ausschließlich** für `L2` und kam ebenfalls erst mit V3.0 (`PreisAktion.java:10`).

Die Abkürzung ist weder im Repo noch in der Ist-Analyse ausgeschrieben. Branchenüblich steht LMT für
**Liquidity Management Tools** — die Instrumente, die Fonds nach der EU-AIFMD/UCITS-Novelle wählen
und melden müssen; Rücknahmebeschränkung, Verlängerung der Rückgabefrist und Rückgabegebühr sind
drei aus dem Standardkatalog, und `PreisAktion.java:10` nennt `L2` selbst „the LMT tool". Aus
unseren Quellen belegt ist das **nicht** — für ein Dokument nach außen bei der Fachabteilung
bestätigen lassen.

---

## Entscheidungen (mit dem User abgestimmt)

### 1. Keine Sammeltabelle — der Tagesstand liegt in den Jobs

`tmp_if_kurs` und `tmp_if_cop` werden **nicht** nachgebaut. Ein Job pro Lieferdatei.

Was `tmp_if_kurs` im Altsystem leistet und wo es im neuen Konzept landet:

| Leistung | neu |
|---|---|
| Akkumulator, „letzte Lieferung gewinnt" pro Preisschlüssel | Auflösung im Batchlauf, über die Zeilen aller Jobs des Tages |
| Datenquelle für Plausi / Files / Einspielung | dieselben Zeilen, drei Verbraucher |
| Puffer für Spätlieferungen (`RemoveTmpKurse` mit Stichzeitpunkt, QMS 644) | entfällt — ein spät eingelangter Job bleibt auf `READY_FOR_BATCH` liegen |
| Cross-File-Abgleich **beim Ingest** (`Check4DeleteInTmp`) | verschoben in den Batchlauf, siehe 4. |

Nebeneffekt: die Ingest-Jobs laufen parallel, ohne sich zu koppeln. Legacy musste dafür
serialisieren (PID-File, alphabetisch je Lieferant).

### 2. Das Ingest-Urteil gilt

Der Ingest führt die Eingangsprüfung genau einmal durch (ISIN + Prüfziffer, Datumsgrenzen aus
`tax_code`, Wertbereich, `max_nk`, Währung, Aktionscode, LMT-Feldregeln) und erzeugt die
Rückmeldung an den Lieferanten. **Der Batchlauf wiederholt sie nicht.**

Begründung:

- Legacy verhält sich identisch — eine Zeile in `tmp_if_kurs` wird nie wieder geprüft.
- Die einzigen Stammdaten, die sich untertags realistisch bewegen, sind die Anlage eines Fonds
  (`INV` + `vwkn..wkn_hist`; vorher `ERR_ISIN06`, Zeile abgelehnt, Lieferant hat einen echten Bug
  bekommen) und `fonds_ende` (vorher akzeptiert, Preis wird publiziert). In beiden Fällen tut
  Legacy dasselbe. `tax_code` und `HWA` sind Konfiguration und bewegen sich nicht untertags.
- Legacy hat für „Stammdaten und Lieferung passen nicht zusammen" bereits einen Platz, und der ist
  der Batch: die Plausi-Abschnitte `makeNichtVorhanden`, `makeFondsNotInINV`,
  `makePreisVorFondsBeginn`, `makePreisNachFondsEnde`, `makePreisNichtInFondswhrg`,
  `makeVorlFonds` prüfen zur Batchzeit gegen die dann aktuellen Stammdaten und **melden**, statt
  zurückzunehmen.

Ausgabeseitige, stammdatenabhängige Entscheidungen trifft der Batch dagegen jedes Mal frisch —
`INV.veroeffentlichung`, `cod_art_f` (TEST/AIF), `FONDS_ZGRU`. Das ist legacy-konform
(`cFondsRecord::ReadStammdaten` in Stufe 3). Es sind zwei verschiedene Fragen, nicht dieselbe
zweimal.

### 3. Landezone: die gelieferten Zeilen pro Job

Gewählt wurde Variante „Zeilen pro Job" (gegenüber einer gemeinsamen Sammeltabelle, einer
zusätzlichen aufgelösten Tagesmenge und einem Blob im Filestore).

| Spalte | Inhalt | Anmerkung |
|---|---|---|
| `job_id` | FK auf den Preismeldung-Job | ersetzt `liefer_id` **und** `eintragezeit` — beides steht am Job |
| `zeilen_nr` | Zeile im Lieferfile | Rückbindung an `data.log`/`error.log`, Reihenfolge innerhalb der Datei |
| `isin` | | |
| `preisdatum` | Berechnungsdatum (Spalte 1 des Lieferformats) | |
| `waehrung` | Währung der Lieferung, nicht die Fondswährung | |
| `meldekategorie` | `R`/`E`/`Z`/`S`/`S2`/`S3`/`X`/`L1`/`L2`/`L3` | nach Alias-Auflösung (`tax_code.alias`), also der Zielcode |
| `aktion` | `N`/`D`/`I` | |
| `wert` | normalisiert: Komma→Punkt, Blanks entfernt, `ignore_null='J'` → `0` | |
| `fondsbezeichnung` | wie geliefert | Fallback, wenn `INV` keine hat |
| `lmt_prozentkennzeichen`, `lmt_stichtag` | | siehe offener Punkt G |

PK `(job_id, zeilen_nr)`. Drei Eigenschaften, die den Unterschied zu `tmp_if_kurs` ausmachen:

- **Kein Unique-Key auf dem Preisschlüssel.** Duplikate über den Tag sind der Normalfall;
  „letzte gewinnt" ist eine Regel im Batch, keine Constraint in der DB.
- **Append-only.** Nichts wird nachträglich geändert oder gelöscht. Kein Leeren, kein `tmp_if_cop`.
- **Gehört genau einem Job.** Kein lieferantenübergreifender veränderlicher Zustand.

Nicht übernommen aus `tmp_if_kurs`: `num_ausschuettung` / `dat_zahltag` (die Ausschüttungsangaben im
Preisfile kommen aus den Stammdaten, nicht aus der Lieferung) und `intervall` (wird produktiv seit
2017 ersatzlos geleert, `daNoEuQust` ist hart auf `2017.01.01` verdrahtet).

### 4. Auflösung im Batchlauf, als gemeinsame Komponente

Der Batch bildet aus den Zeilen aller Jobs des Tages die Tagesmenge:

1. Sortierung nach Job-Ankunftszeit, innerhalb des Jobs nach `zeilen_nr`.
2. **Letzte Lieferung gewinnt** pro `(ISIN, Preisdatum, Währung, Code, Aktion)` — datumsgenau.
   Verschiedene Preisdatümer zum selben Fonds sind **kein** Konflikt, sondern zwei Fakten und
   müssen beide durch (im Beispielreport 107 Korrekturen an einem Tag).
3. **D/N-Verrechnung** (Legacy: `Check4DeleteInTmp`, `CheckDelete4Update`):
   - `D` trifft auf ein früheres `N` mit gleichem Schlüssel → das `N` fällt weg
   - danach: ist der Preis persistiert bzw. schon ausgeliefert? nein → das `D` fällt ebenfalls weg
   - `N` trifft auf ein früheres `D` → das `D` fällt weg
   - innerhalb einer Datei: folgt einem `D` weiter unten ein Nicht-`D` mit gleichem Schlüssel,
     fällt das `D` weg

Weil sowohl der Batch als auch der Sync-Job (siehe 8.) diese Auflösung brauchen, liegt sie in
**einer** Komponente, die beide aufrufen. Sie darf nicht zweimal implementiert werden — sonst können
Preisfiles und `kurs` auseinanderlaufen.

Die Verschiebung des Cross-File-Abgleichs vom Ingest in den Batch hat eine sichtbare Folge: die vier
`INFO_DEL_*`-Meldungen stehen nicht mehr im `info.log` des Lieferanten, sondern im Batch-Protokoll.
Bewertet als vertretbar, weil (a) es Infos sind, die das Urteil `ERROR`/`INFO` nicht berühren — das
hängt allein an der Zeilenzahl in `error.log`; (b) die Texte OeKB-Interna beschreiben („Delete-DS
wurde aus TMP-Tabelle entfernt"); (c) die Fachabteilung sie über `liefer_bugs` ohnehin ein zweites
Mal im `fplausib.txt` sieht. Aufgegeben wird die Korrekturschleife innerhalb des Tages.

### 5. Zwei Batchläufe pro Tag

Identität `(keyDate, laufnummer)` wie bei den STM-Batchjobs. Beide Zeiten konfigurierbar
(Diskussionsstand: ~14:00 und ~16:00).

Damit entfällt das heutige manuelle **Stoppen des Batchs**, wenn ein Lieferant eine Verspätung
meldet. Nicht wegen des zweiten Laufs, sondern wegen der Jobs: eine um 15:30 eingelangte Lieferung
bleibt einfach auf `READY_FOR_BATCH` liegen. Fällt Lauf 2 aus, ist sie morgen dran — statt verloren.

### 6. Lauf 2 liefert ein vollständiges Ersatz-File

Nicht ein Delta. Der ganze Tag noch einmal, inklusive des `tmp_if_last`-Fallbacks für Fonds ohne
heutigen Preis.

Begründung: die Identifier `I2`/`I3`/`I4` bleiben gegen den persistierten Stand gerechnet, wie
heute — bei einem Delta bräuchten sie einen neuen Bezugspunkt („was haben wir heute schon
ausgeliefert"), sonst steht `I2`, wo `I4` hingehört. Und der Fehlerfall ist gutartiger: wer das
Ersatz-File verpasst, hat veraltete, aber in sich stimmige Daten; wer ein Delta verpasst, hat falsche
Daten und weiß es nicht.

Konsequenz für den Bezieher: „letztes File des Tages gewinnt" braucht eine präzise Lesart —
*alles für das Kursdatum im Header verwerfen und die Datei neu anwenden*. Eine Auslassung ist in
einem Operationsformat (`I2`/`I3`/`I4` plus zählender Footer) sonst **keine** Rücknahme. Siehe
offener Punkt D.

### 7. Lauf 2 darf Entscheidungen von Lauf 1 revidieren

Daraus folgt das Statusmodell. Der Stempel nach Lauf 1 heißt **nicht** „fertig":

```
READY_FOR_BATCH        Lieferung liegt vor, noch kein Lauf hat sie gesehen
PUBLISHED              von mindestens einem Batchlauf ausgeliefert (+ batch_job_id)
SYNCED / PROCESSED     in kurs übernommen, geschlossen
```

- Der Batch liest **`READY_FOR_BATCH` ∪ `PUBLISHED`** und stempelt alles neu. Läse er nur
  `READY_FOR_BATCH`, würde Lauf 2 ein Delta erzeugen — im Widerspruch zu 6.
- Der Batch muss wissen, **was der vorige Lauf ausgeliefert hat**. Nötig für die Rücknahme eines
  Preises, der um 14:00 als `I2` rausging und um 15:30 per `D` zurückgezogen wird: der Preis ist
  nicht in `kurs` (der Sync läuft später), die Legacy-Regel würde das `D` verwerfen, und der
  Bezieher behielte ihn. Die Batch-Stempel an den Jobs liefern diese Information.
- Der Status beschreibt den **Job**, nicht seine Zeilen. Eine Lieferung kann `PUBLISHED` sein,
  während einzelne ihrer Zeilen in der Auflösung verloren haben.

### 8. Einspielung nach `kurs` als eigener Job, nach dem letzten Batchlauf des Tages

Der Sync-Job liest dieselben Zeilen, wendet dieselbe Auflösung an (Komponente aus 4.) und legt
seinen **Berechtigungsfilter** darüber — diese Logik gehört in den Sync, nicht in die Tabelle:

- ISIN in IFAS nicht auflösbar → `pool_if_kurs`, `kurs` unberührt
- Preiswährung ≠ Fondswährung → nicht nach `kurs`
- TEST-ISIN, C-Plan, AIF, Fonds in Liquidation → Ausschlüsse (`InsPreise*`-Schalter)
- vorläufiger Fonds mit `R`-Wert → Aktivierungsversuch, bei Misserfolg `pool_if_kurs`
- Löschungen: `DeleteKurseReally` in `kurs`, bei `R` zusätzlich die abhängigen Kennzahlen,
  `del_protokoll`

**Harte Reihenfolge-Auflage:** der Sync läuft nach dem letzten Batchlauf des Tages. Weil Batch und
Sync sich dieselbe Menge teilen, würde ein Sync zwischen den Läufen die Jobs schließen und Lauf 2
lautlos zu einem Delta degradieren — das Ergebnis von Lauf 2 hinge davon ab, ob ein anderer Job
zufällig vorher lief. Die Auflage muss explizit verkettet werden (Muster „STM Lauf 1"), nicht
durch Cron-Zeiten gehofft. Siehe offener Punkt A.

Nicht durch eine Transaktion abgedeckt: die Verteilung. MFT-Upload, NetApp-Archivierung und
`pr_ready.txt` liegen außerhalb; Legacy hat dasselbe Problem und löst es nicht
(`create_preise.csh`: Archivierungsfehler erzeugt eine Mail mit Neustartanleitung, bricht aber
nicht ab).

### 9. `tmp_if_last` ist eine Projektion, kein Eingang

Die einzige tmp-Tabelle, die fachlich überlebt — aber **nicht** auf dem Weg nach `kurs`.

Definition: je `(ISIN, Währung, Code)` die Zeile mit dem höchsten `preisdatum`, ohne Löschsätze,
ohne die Ausschlüsse aus 8., innerhalb von `Tage_TmpIfLast` (65) Tagen; beendete Fonds nach
`Tage_TmpIfLast_Beendete` (35) Tagen entfernt. Einziger Verbraucher: der Fallback in Lauf 1 der
Filegenerierung (Fonds ohne heutigen Preis bekommen ihren letzten bekannten Preis).

Belegt aus `WriteLastKurse` (`preisekennzahl.cpp:1226`): gespeichert wird der **gelieferte** Wert
(`cPrTyp[i].dPreis`); es gibt keine Spalte für ein Rechenergebnis; aus der Nachrechnung fließt
nichts zurück. `tmp_if_last` ist damit eine reine Funktion der Lieferungen — und **nicht** aus
`kurs` ableitbar, weil es Werte trägt, die `kurs` nie sieht (unbekannte ISIN, Währungsabweichung).

Warum es die Landezone nicht sein kann: der Delete-vor-Insert-Schlüssel enthält **kein**
`preisdatum`. Es gibt genau einen Platz je (ISIN, Währung, Code). Trifft um 09:10 ein Preis für den
12.05. ein und um 11:20 eine Korrektur für den 08.05., verdrängt die zweite die erste — kein Filter
auf der Leseseite holt eine überschriebene Zeile zurück. Zusätzlich setzt `WriteLastKurse` `cod_ex`
hart auf `'N'`: Löschsätze existieren dort nicht und wären auf diesem Weg strukturell unsichtbar.
Das Datum in den Schlüssel aufzunehmen löst das nicht, sondern macht daraus die Sammeltabelle: die
Lauf-1-Abfrage joint nur über `num_okb` und würde mehrere abgestandene Preise je Fonds ausgeben.

Offen: geführte Tabelle oder Abfrage über die Landezone — offener Punkt B.

### 10. Kennzahlenberechnung wandert mit, läuft aber eigenständig

Die Kennzahlen (berichtigte Kurse, Reinvestitionsfaktoren, Performance, Volatilität,
Risikokennzahlen) kommen ebenfalls nach IFAS13, als **eigener, unabhängig terminierbarer Job**.

- **Keine Abhängigkeit zu den Preisfiles.** Das Preisfile schreibt den gelieferten Preis; die
  Selektion liest `tmp_if_last` und die Tagesmenge, beide ohne berichtigten Kurs. `kurs` wird bei
  der Filegenerierung nur nach *Existenz* gefragt (für `I2`/`I3`/`I4`). Die Reihenfolge im
  Legacy-Tagesjob ist Ablauf, nicht Abhängigkeit.
- **Basis ist `kurs`, nicht `tmp_if_last`.** Kennzahlen sind Zeitreihen; `tmp_if_last` hat keine
  Historie, ist auf die ISIN geschlüsselt (`kurs` auf `num_wfs_ku`) und hat keine Ergebnisspalte.
- **Obergrenze für „später":** vor dem nächsten Plausi-Lauf. `makeAbweichung` vergleicht den
  *berichtigten* Kurs (`pdPreis_ber`), damit Ausschüttungen und Splits keine Scheintreffer
  erzeugen. Hinkt die Berechnung nach, degradiert dieser Abschnitt des Reports. Als Abhängigkeit
  zwischen zwei Jobs ausdrückbar.
- **Legacy trennt hier schon fachlich:** `CalcCPlan`/`InsPreiseCPlan` = `0`/`1`,
  `CalcAIF`/`InsPreiseAIF` = `0`/`1`, `CalcFondsInLiquidation`/`InsPreiseFondsInLiquidation` =
  `0`/`1`. Preise werden eingespielt, Kennzahlen nicht gerechnet — zwei Geltungsbereiche, zwei
  Schalter.
- **Historientreue:** `StetigeVolaAb` = `2007.01.01` und `PerfYtdFbY1Neu` = `2007.01.01` sind
  datumsgesteuerte **Formelwechsel**. Eine Nachrechnung ist nicht „ab Datum X vorwärts rechnen",
  sondern „die Historie ab X mit den Regeln nachrechnen, die zu jedem Zeitpunkt gegolten haben" —
  dieselbe Klasse von Anforderung wie bei der STM-Recalc-Historientreue.

Auslöser: offener Punkt C.

---

## Offene Entscheidungen

### A. Braucht jemand `kurs` untertags aktuell? — **TODO User: Fachabteilung fragen**

Entscheidet, ob die Reihenfolge-Auflage aus 8. tragbar ist.

| Option | Folge |
|---|---|
| **A1 — nein, niemand** | Sync läuft nach dem letzten Batchlauf des Tages. Landezone bleibt wie in 3. Nichts weiter zu tun. |
| **A2 — ja (Oberfläche, anderer Job, IFASNXT via `del_protokoll`)** | Batch und Sync dürfen sich die Menge nicht teilen. Dann braucht es die **aufgelöste Tagesmenge pro Batchlauf** als eigene Tabelle: der Batch friert sein Ergebnis ein, der Sync liest es und kennt keine Regeln. Preis: Nutzdaten zweimal, zwei Schreibschritte, zwei Artefakte konsistent zu halten. Gewinn: der Sync ist frei terminierbar, „was hat Lauf 1 ausgeliefert" steht als Tabelle da, und der Scoping-Fehler aus 7. ist strukturell unmöglich. |

### B. `tmp_if_last` — geführte Tabelle oder Abfrage?

| Option | Folge |
|---|---|
| **B1 — geführte Tabelle** | Lauf 1 liest direkt, wie heute. Muss am Ende jedes Batchlaufs fortgeschrieben werden, mit Aufräumregeln (65 Tage, beendete Fonds nach 35 Tagen). Expliziter, sichtbarer Zustand. Kann veralten. |
| **B2 — Abfrage zur Laufzeit über die Landezone** | Kein Zustand, nichts kann veralten, nichts aufzuräumen. Über 65 Tage sind es bei ~4200 Preisen/Tag rund 270.000 Zeilen — für eine gruppierte Abfrage unkritisch. Damit bliebe **keine** der Legacy-tmp-Tabellen übrig. |

Hinweis: B2 setzt voraus, dass die Landezone eine Tabelle ist (bei einem Filestore-Blob nicht
möglich) — durch Entscheidung 3 gegeben.

### C. Kennzahlen — Invalidierung oder Auftragsübergabe?

Der Auslöser ist in Legacy flüchtig: `daLastDatum` (je Fonds das früheste betroffene Preisdatum)
wird in `MakeTmpPreise` im Speicher gemerkt und sofort verbraucht. Drei Fälle verhalten sich
unterschiedlich: ein **neuer** Preis und ein **gelöschter** `R` hinterlassen eine Lücke (Kennzahl
fehlt bzw. wurde von `DeleteKennzahlen` mitgelöscht), ein **korrigierter** Preis hinterlässt eine
vorhandene, aber falsche Kennzahl.

| Option | Folge |
|---|---|
| **C1 — Invalidierung** | Der Sync räumt bei *jeder* Änderung die abhängigen Kennzahlen weg, nicht nur bei `R`-Löschungen. Dann sind alle drei Fälle dieselbe Lücke, und der Kennzahlen-Job braucht keine Übergabe: er sucht Preise ohne Kennzahl und rechnet sie, wann immer er läuft — beliebig terminierbar, wiederholbar, selbstheilend. Preis: zwischen Sync und Nachrechnung sind die Kennzahlen **abwesend** statt veraltet. Für `makeAbweichung` vermutlich besser (Sätze ohne Vergleichswert werden ohnehin übersprungen); für andere Verbraucher von Kennzahlen zu prüfen. |
| **C2 — Auftragsübergabe** | Der Sync hinterlässt eine Arbeitsliste (je Fonds das früheste betroffene Datum). Kennzahlen bleiben bis zur Nachrechnung veraltet statt abwesend. Braucht ein zusätzliches Artefakt und einen Aufräummechanismus für nicht abgearbeitete Aufträge. |
| **C3 — Ableitung aus `kurs.guelt`** | `kurs.guelt` ist ein Zeitstempel je Zeile; „welche Fonds ab wann" ist eine Abfrage. Deckt Korrekturen und Neuwerte ab, **nicht** Löschungen (eine gelöschte Zeile hinterlässt nichts). Taugt daher als *Reparaturpfad* („rechne alles nach, was seit X berührt wurde"), nicht als vollständiger Auslöser. |

### D. Rücknahme eines bereits ausgelieferten Preises — explizit oder implizit?

Aus 6. und 7.: das Ersatz-File von Lauf 2 enthält einen um 14:00 publizierten und um 15:30
zurückgezogenen Preis einfach nicht mehr.

| Option | Folge |
|---|---|
| **D1 — explizites `I3`** | Lauf 2 gibt den Löschsatz aus, obwohl die Legacy-Regel („nicht in `kurs`" → verwerfen) ihn verwerfen würde. Funktioniert unabhängig davon, wie der Bezieher das File anwendet. Bewusste Abweichung vom Altsystem, im Parallelbetrieb als bekannte Abweichung zu führen. |
| **D2 — Auslassung genügt** | Setzt voraus, dass jeder Bezieher „alles für das Kursdatum im Header verwerfen und neu anwenden" umsetzt. Keine Codeänderung, aber eine Zusage, die von außen kommen muss. |

Fachabteilung/Bezieher-Vertrag. Hängt an F.

### E. Ausschüttungs-Veto bei `R`-Löschungen

Heute: liegt zum Preisdatum eine Ausschüttung vor, wird die Löschung verweigert und es passiert
*nichts* — keine Löschung, keine Kennzahlenbereinigung, nur eine Zeile im Programm-Log, kein
Delivery-Bug, keine Rückmeldung an den Lieferanten. Der `I3` ist zu diesem Zeitpunkt beim Bezieher
schon draußen. Im Quelltext steht an der Stelle `// ????`.

| Option | Folge |
|---|---|
| **E1 — wie heute** | Divergenz bleibt: Preis beim Bezieher weg, in `kurs` vorhanden. Mit entkoppeltem Sync wird das Fenster größer. |
| **E2 — Batch erkennt es vorab** | Der Batch prüft die Ausschüttung schon bei der Auflösung und gibt den `I3` gar nicht aus; der Lieferant bekommt eine Rückmeldung, dass die Löschung nicht möglich ist. Kein Auseinanderlaufen. Abweichung vom Altsystem. |

### F. Dateinamen und Ready-File für zwei Auslieferungen pro Tag

`preis.csv`, `solva.csv` und das eine `pr_ready.txt` als Vollständigkeitssignal sind fix. Zwei
Auslieferungen brauchen Nummerierung — Legacy hat dafür `-N<nr>` (laufende Nummer aus dem
`event_log`), für Fondspreise ungenutzt. Nur der T2S-Strom kann es schon heute
(`<YYYY-MM-DD_HH-MM>_preis.csv`). Die kundenseitige Formatbeschreibung
(`2025_Funddata_Provision.xlsx`, Version 2.0, gültig ab 17.11.2025) kennt **eine** Lieferung pro Tag.

Änderung nach außen → Fachabteilung. Optionen: nummerierte Zweitfiles mit eigenem Ready-File; oder
gleiche Namen und Überschreiben (setzt D2 voraus); oder — als Rückfallposition — **ein** Lauf,
später terminiert, ohne Zweitlauf und ohne Vertragsänderung.

### G. LMT persistieren und weitergeben?

Offener Punkt 11 der Ist-Analyse. Bedeutung der Codes siehe **Begriffe**.

Das Altsystem validiert `L1`/`L2`/`L3` vollständig — Prozentkennzeichen `J`/`N`
(`ERR_LMTPROZENT1`), Stichtag nur bei `L2` und nur bei 0 Tagen (`ERR_LMTRUECKL2`,
`ERR_LMTRUECKL2_0`), Aktion `I` nur bei `L2` (`CheckAktionL2`) — und **speichert nichts**:

```cpp
// M_INSERT.CPP:2049-2056
if (strcmp(cPrCodes.GetGruppe(cPrRecords[i].szCode), "LMT") == 0)
{
    // LMT Daten sollen derzeit nicht gespeichert werden
```

Keine LMT-Spalten in `tmp_if_kurs`, keine in `kurs`, in keinem Ausgabeformat. Die LMT-Felder des
Lieferformats sind heute reine Eingangsvalidierung — Daten, die die KAGs liefern und die im Nichts
landen.

IFAS13 prüft in `CsvPreismeldungValidations` bereits **mehr** als das Altsystem: bei `L1`/`L3` keine
`0`-Meldungen, die Inaktivierung `I` muss immer `0` melden, und `L2` mit 0 Tagen verlangt (außer bei
Inaktivierung) einen Stichtag.

Mit der Landezone aus 3. kostet die Persistenz zwei Spalten. Die Frage verschiebt sich damit auf:
**an wen weitergeben, in welchem Format?** Heute existiert kein Ausgabestrom, der LMT transportiert;
ein neuer wäre eine Änderung am Bezieher-Vertrag (vgl. F).

### H. Weiterhin offen aus der Ist-Analyse (Daten beschaffen)

- **Produktive `tax_code`-Zeilen exportieren.** `L1`/`L2`/`L3` fehlen in allen eingecheckten
  `insert_tax_code*.cr`; `S2`, `S3`, `X` nur in `v_preiscode`. Die real gültigen
  `untergrenze`/`obergrenze`/`max_nk`/`future`/`isinwaehrung`/`ignore_null` und Datumsgrenzen
  definieren das gesamte Prüfverhalten und liegen nur in der Produktionsdatenbank.
- **Toleranzen der Kursabweichung:** `ifas..preise_check` (`WFS_WKN = -1`) und
  `preise_check_faktor`.
- **Produktive INI-Werte**, insbesondere `AllowOldPreisFormat` (davon hängt ab, ob das alte
  Format 1 überhaupt bedient werden muss) und `AllowTxtExt4PreisFile`.
- **`MFT_*.INI`** — Zielverzeichnisse und Accounts sind nicht im Repo.
- **Vollständiger `fplausib.txt`** mit Treffern in allen Abschnitten, um die Meldungstexte wörtlich
  übernehmen zu können.
- **Aktuelle `preis.dtd`**, wie sie tatsächlich ausgeliefert wird.
- **`datum_min`-Vergleichsrichtung** (`M_INSERT.CPP:2020,2906` vergleichen mit `> daDatumMin`,
  entgegen der Feldbeschreibung) — mit der Fachabteilung klären.
- **`makeGleicherKurs`** („mindestens 5 mal hintereinander derselbe Preis") ist im Confluence
  beschrieben, existiert im Code nicht — fachlich gewünscht?

---

## Abgrenzung

**Enthalten:** die inländische Kette — Ingest, Plausibilität, Filegenerierung, Verteilung,
Einspielung nach `kurs`, `tmp_if_last`, `pool_if_kurs`; die Kennzahlenberechnung als eigener,
später zu konzipierender Job (Entscheidung 10 legt nur die Naht fest).

**Nicht enthalten:** die Formeln der Kennzahlen-/Performance-/Volatilitätsnachrechnung
(`preisekennzahl.cpp`, `fondskennzahl.cpp`, `c_calc.cpp`) — dafür fehlt noch eine eigene
Ist-Analyse. Ausländische Fonds (`-R1`). STM und Ausschüttungen (bereits portiert bzw. eigene
Domäne). Meldefonds-Listen, Fristenprüfung, Mahnungen. Stammdatenfiles Börse/Vendoren/WDBO.

---

## Vorgehen

1. **Offene Punkte A–G klären** (A ist beim User, D/E/F/G brauchen die Fachabteilung, B und C sind
   intern entscheidbar). Vor A steht die Landezone fest, aber nicht, ob eine zweite Tabelle für die
   aufgelöste Tagesmenge dazukommt — das betrifft den Zuschnitt der ersten Implementierungsschritte.
2. **Datenbeschaffung H anstoßen** — die `tax_code`-Zeilen sind Voraussetzung für jede
   Ingest-Implementierung, nicht ein Detail am Rand.
3. **Konzept in `docs/Fondspreise/fondspreise-soll-konzept.md` ablegen**, neben der Ist-Analyse,
   sobald A–C entschieden sind. Dieser Plan ist der Arbeitsstand; das Dokument im Repo ist das
   Ergebnis.
4. **Implementierung in Schnitten**, jeder für sich testbar:
   Ingest + Landezone → Auflösung (Komponente) → Plausi-Report → Filegenerierung →
   Verteilung/Archivierung → Sync nach `kurs` → `tmp_if_last`-Projektion → Zweitlauf.
   Die Auflösung ist der Angelpunkt: sie wird von Batch und Sync geteilt und sollte früh und
   isoliert getestet stehen.
5. **`docs/Technische Konzepte/ifas13-jobs.md`** aktualisieren: der Eintrag „Fondspreise — out of
   scope" stimmt dann nicht mehr.

## Verifikation

Noch kein Code — prüfbar ist bisher nur die Konsistenz des Konzepts:

- Jede Aussage über das Altsystem gegen die Ist-Analyse und, wo dort nicht belegt, gegen
  `file:line` im Legacy-Repo (ISO-8859-1 → `grep -a` / `iconv`).
- Die Anforderungen an die Landezone gegen die vier Verbraucher durchspielen: Batch (Files),
  Plausi, Sync (`kurs`), Projektion (`tmp_if_last`). Jeder muss aus den Zeilen pro Job vollständig
  bedient werden können.
- Das Statusmodell aus 7. gegen die beiden Läufe und den Sync durchspielen, inklusive der
  Fehlerfälle: Lauf 2 fällt aus; Sync fällt aus; Lieferung trifft nach Lauf 2 ein; Lauf 1 wird
  wiederholt.
- Die D/N-Auflösung an den Fällen aus der Diskussion prüfen: zwei Lieferungen zum gleichen
  Preisdatum (last wins), zwei Lieferungen zu verschiedenen Preisdatümern (beide gültig), `D` in
  Lauf 2 auf einen in Lauf 1 ausgelieferten Preis (Anforderung an D).

## Korrekturen an der Ist-Analyse (bereits eingearbeitet)

Während der Diskussion in `docs/Fondspreise/fondspreise-legacy-analyse.md` behoben:

- **2.9** — `oekbinfo.log` enthielt fälschlich `INFO_DEL_NEW`; im Fondspreis-Pfad landen dort nur
  `INFO_DATE02` und `INFO_CURRENCY02` (`cLieferBugs::WriteOekbInfo`, `M_INSERT.CPP:2979,3409`).
- **2.7** — ergänzt: alle vier `INFO_DEL_*` gehen über `WriteInfo`/`WriteInfo2Rows` nach `info.log`
  (`c_insert.cpp:3111,3216`), also in das ZIP beim Lieferanten, und als `bug_info='I'` nach
  `liefer_bugs`.
- **5.2 Schritt 7** — ergänzt: Löschung über `DeleteKurseReally` in `kurs..kurs`; beide Zweige
  stehen unter dem Vorbehalt Preiswährung = Fondswährung (bei Abweichung passiert stillschweigend
  nichts); das Ausschüttungs-Veto ohne jede Rückmeldung, mit `// ????` im Quelltext.
- **5.2 Schritt 8** — „aktualisiert in jedem Fall `tmp_if_last`" war falsch: Ausschlüsse kehren
  vorher zurück, nur Preis-Typen mit Wert, `cod_ex` hart `'N'`, Delete-Schlüssel ohne `dat_kurs`,
  gespeichert wird der gelieferte Wert.
