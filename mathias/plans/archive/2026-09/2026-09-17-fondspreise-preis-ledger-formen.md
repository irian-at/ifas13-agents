# Fondspreise — ein Preis-Ledger als Quelle für `kurs`, `tmp_if_last` und die Bezieher

Stand 2026-09-17, ergänzt um zwei weitere Aussagen der Fachabteilung (Abschnitt 1a), die
Guard-Analyse (5a), eine Empfehlung auf Nachfrage (5b) und den Brainstorming-Stand vom Abend (8:
Tendenz C-ohne-Ist-Tabelle, Herkunftsreferenz, `JobWorkloadItem` als Inbox, Fehlmeldung aus dem
Ledger). Fortsetzung 2026-09-18. **Diskussionsgrundlage, nichts entschieden.** Entity-Diagramme Alt/Neu im Begleitblatt
[2026-09-17-fondspreise-preis-ledger-er-diagramme.md](2026-09-17-fondspreise-preis-ledger-er-diagramme.md).
Entstanden aus dem Gespräch mit der
Fachabteilung zu Stufe 2 ([Schnitt-2-Plan](2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md),
Klärungen **N**, **O**, **P** im [Tracker](tracker.md)). Die Legacy-Befunde unten sind am Code des
Altsystems nachgeprüft (Pfade relativ zu `~/dev/projects/oekb/ifas`, Quellen ISO-8859-1).

---

## 0. Begriffe: die Meldekategorien

Eine Preismeldung besteht aus Zeilen; jede Zeile trägt eine ISIN, ein Preisdatum, eine Währung,
**eine Meldekategorie** (Spalte 4 des Lieferformats; im Altsystem „Preis-Code", in `kurs` die Spalte
`cod_fliesscode`) und einen Wert. Ein Fonds liefert pro Tag also mehrere Zeilen zur selben ISIN. Die
Kategorien sind Zeilen der Tabelle `tax_code`, die je Code das Eingangsverhalten steuert
(Grenzen, Nachkommastellen, Zukunftsdaten, Inland/Ausland, `isinwaehrung`).

| Code | Bedeutung | Gruppe | Wohin |
|---|---|---|---|
| `R` | Errechneter Wert — der Nettoinventarwert je Anteil (NAV). Der zentrale Preis, Basis aller Kennzahlen | PREIS | `kurs`, `preis*.csv` |
| `E` | Ausgabepreis — NAV plus Ausgabeaufschlag, was der Anleger beim Kauf zahlt | PREIS | `kurs`, `preis*.csv` |
| `Z` | Rücknahmepreis — was der Anleger bei Rückgabe erhält, oft gleich dem NAV | PREIS | `kurs`, `preis*.csv` |
| `S`, `S2`, `S3` | Solvabilität — aufsichtliches Risikogewicht des Fonds für Banken im Bestand; `S` nach Solva I, `S2` Basel II Standardansatz, `S3` Basel II vereinfachter IRB. Ein Prozentsatz, kein Preis | SOLVA | `kurs`, `solva*.csv` |
| `L1`, `L2`, `L3` | Liquidity Management Tools, neu seit Lieferformat V3.0 (2026): Rücknahmebeschränkung, Verlängerung der Rückgabefrist, Rückgabegebühr. Werden geprüft, aber nirgends gespeichert oder ausgeliefert | LMT | nur Rückmeldung |
| `X` | indikativer, fiktiver errechneter Wert — Notausgang zur Aktivierung eines vorläufigen Fonds; nie ausgegeben, im aktuellen Lieferformat nicht mehr enthalten | PREIS | `kurs` |
| `C`, `F`, `Q`, `T`, `TA` | historische Steuercodes (KESt-Pflicht, KESt-Gesamt, EU-Quellensteuer, TIS) — seit 2017 im Preisweg abgewiesen | KEST, QUST | — |

`tax_code` ist mit der Steuerdaten-Meldung geteilt; Codes wie `KEST`, `DIVI` oder `AQS` dort haben
mit Fondspreisen nichts zu tun. Für dieses Dokument zählen `R`, `E`, `Z` und die drei Solva-Codes —
genau die sechs Zeilen mit `isinwaehrung = N` (Abschnitt 1a, Frage 3).

**Fondswährung** ist `INV.WAEHRUNG`: genau eine Währung je ISIN, denn jede ISIN ist eine Tranche.
Ein Fonds mit EUR- und USD-Klasse hat zwei ISINs. „Preis in anderer Währung als Fondswährung" heißt
also: zur USD-ISIN wird ein Preis mit Währungscode EUR gemeldet. Umgerechnet wird im Preisweg
nirgends; die Währung ist überall Teil des Schlüssels (`tmp_if_kurs`, PK von `kurs`, `tmp_if_last`,
Spalte 3 des `I2`-Satzes). Quelle: Ist-Analyse 8.1/8.2, Konzept *Begriffe*.

## 0a. Die Kategorien im Legacy-Verhalten (Befunde 2026-09-28)

Am Code nachgeprüft. Eingang = `preis_ins.e` (`Ifas/cprogs2/preise4/M_INSERT.CPP`), Einspielung =
`preise.e` (`Ifas/cprogs2/calc/preisekennzahl.cpp`, `MakeTmpPreise :2656`). Ergänzt die Abschnitte 1
und 1a, dort stehen der Tagesablauf eines `D` und das Ausschüttungs-Veto.

**Parallel, ohne Verbund.** Jede Zeile trägt genau eine Kategorie; in `kurs` ist sie Teil des
Schlüssels `(num_wfs_ku, dat_kurs, cod_fliesscode, waehrung)` (`Kurs/tabledefs/I_kurs.cr`). Kein Code
setzt einen anderen voraus, `E` ohne `R` ist zulässig. Die Kopplungen unten hängen alle an `R`.

| | `R` | `E`, `Z` | `S`, `S2`, `S3` | `L1`–`L3` |
|---|---|---|---|---|
| in `kurs` | ja, dazu `num_bericht_kurs` | ja | ja | **nein**, nach der Prüfung verworfen (`M_INSERT.CPP:2051`: „derzeit nicht gespeichert") |
| eigene Eingangsprüfung | nach Fondsende `ERR_DATE04`, vor Fondsbeginn nur `INFO_DATE02` (`M_INSERT.CPP:2933`, `:2965`) | `E ≥ R`, `Z ≤ R` (Kopplung 1) | Grenzen aus `tax_code` | Prozentkennzeichen, Rückgabefrist nur `L2`, Aktion `I` nur `L2` (`CheckAktionL2`, `M_INSERT.CPP:3687`) |
| löschbar | ja, außer Ausschüttung/Split am Preisdatum (Veto, 1a) | immer | immer | `D` wird angenommen, bewirkt nichts |
| Kennzahlen | **einzige Basis**: `ReadKurs` hat den Default `R` (`Ifas/cprogs2/calc/fondsbasis.h:992`), alle `kurs`-Selects in `fondskennzahl.cpp` filtern `cod_fliesscode = 'R'` | nein | nein | nein |
| rückdatiert | Korrektur, Nachrechnung ab Preisdatum | zählt als Korrektur (`nKurseVorhanden`), die Nachrechnung läuft an, ändert aber nichts | nie Korrektur (`CheckKorrektur`, `preisekennzahl.cpp:2990`) | — |
| ein `D` löst aus | Kennzahlen des Tages löschen, Nachrechnung | nur die Zeile | nur die Zeile | — |

**Kopplungen.**

1. `E`/`Z` werden gegen `R` nur **in derselben Datei** geprüft (±`lRange4Preis` Zeilen, gleiche
   ISIN, Währung und Aktion; `M_INSERT.CPP:1231-1250`), nie gegen `kurs`. Bei Verletzung wird nur
   die `E`/`Z`-Zeile verworfen (`ERR_VALUE05`/`06`).
2. **Das Veto trifft das ganze Paket.** Die Einspielung gruppiert `tmp_if_kurs` per `select distinct`
   auf (ISIN, Datum, Währung, Aktion), über alle Dateien seit dem letzten Lauf
   (`preisekennzahl.cpp:2248`); `ReadTmpKurse` lädt alle Codes des Pakets (`:601`). Ist `R` im
   Lösch-Paket und gibt es eine aktive Ausschüttung **oder einen Split** mit Ex-Tag = Preisdatum
   (`fondsbasis.cpp:360`, Status `A`), bleibt alles stehen, auch `E`, `Z` und `S` (`:2887`).

   | Löschungen zum Ex-Tag | Ergebnis in `kurs` |
   |---|---|
   | `D E`, `D S` | beide gelöscht |
   | `D R`, `D E`, `D S` | nichts gelöscht |
   | `D R` vormittags, `D E` nachmittags, derselbe Lauf | ein Paket, nichts gelöscht |
   | `D E` in einem Lauf, `D R` im nächsten | `E` gelöscht, `R` bleibt |

   Der Eingang kennt das Veto nicht, der Lieferant bekommt eine normale Rückmeldung. Die `D`-Zeilen
   verschwinden mit `RemoveTmpKurse` (`c_preise.cpp:258`), nur `tmp_if_cop` behält sie.
3. `D R` löscht nur `R` und die Kennzahlen; `E`, `Z` und `S` desselben Tages bleiben ohne NAV stehen.
4. `R` auf einem vorläufigen Fonds ruft `VorlFondsAktivieren` (`preisekennzahl.cpp:2759`). Der
   Rückfall „nicht aktiviert → alle Codes nach `pool_if_kurs`" ist toter Code: geprüft wird `nRet`
   statt `nRet2`.

**Ein `N` ohne vorheriges `D` ist ein Update.** Der Eingang kennt nur `N` und `D` (`CheckAktion`,
`M_INSERT.CPP:3643`; „neu und update Sätze [werden] gleich gehandhabt", `:4064`). In `tmp_if_kurs`
gewinnt die letzte Lieferung (`DeleteTmpPreisRecord`, `c_insert.cpp:1962`). `WriteKurse` und
`WriteKurseBCP` löschen je geliefertem Code und fügen neu ein (`preisekennzahl.cpp:719`, `:815`).
Überschrieben wird **nur der gelieferte Code**. `kurs_1_index` ist `with ignore_dup_key`, ein
Duplikat würde also still verworfen. Wegen des vorgelagerten Löschens greift das nie.

**`kurs.guelt` ist kein Lieferzeitpunkt** (präzisiert Abschnitt 1). Gesetzt wird er beim
Einspielen: `getdate()`, bei BCP die Uhr des App-Servers (`preisekennzahl.cpp:774`, `:877`). Ohne
neue Lieferung wird er später neu gestempelt:
- `R`-Zeilen durch `CalcBerichtKurs`, sobald der berichtigte Kurs vom gespeicherten abweicht
  (`fondskennzahl.cpp:2072`, `:2106`). Ein frisch eingefügtes `R` trifft das immer, weil es mit
  `num_bericht_kurs = null` eingefügt wird.
- Ausländische Fonds zusätzlich durch `Faktor2Kurs` (`auslkennzahl.cpp:719`).

Auch eine unveränderte Nachlieferung stempelt neu. Der Eingangszeitpunkt steht nur in
`tmp_if_kurs.eintragezeit` (weiter nach `tmp_if_cop`), nicht in `kurs`.

**Ein `D` im Detail.**
- Ohne `R` im Paket: nur die gelieferten Codes (`DeleteKurseReally`, `preisekennzahl.cpp:1443`).
- Mit `R`, ohne Veto: zusätzlich `pkz_kum`, `pkz_abs` (und `PKZ` bei `PerformanceOptimierung = 0`)
  dieses Tages, am Monatsultimo (`KMU`) auch `ream_kum`/`frkz_kum` (`DeleteKennzahlen :1985`).
  Danach Nachrechnung ab Preisdatum (`c_preise.cpp:166`, `:233`).
- `del_protokoll` (`kurs1`, `perf`, `risiko`) wird nur mit `Del_Protokoll = 1` geschrieben.
- Ein `D`, das nichts trifft, löscht null Zeilen, ohne Fehler.

Das Lieferformat verlangt, dass eine Löschung die ursprünglich gelieferten Werte trägt (V3.0 §4.1).
Der Eingang prüft den Wert eines `D` nicht (`CheckValue`).

**LMT sind Zustände, keine Preise.** Lieferformat V3.0 §4.2 (IFAS13:
`docs/Fondspreise/202604-LMT-Preismeldung_ISINs_2026.pdf`):
- Ein aktives Tool ist **täglich** zu melden, solange es aktiv ist. Für inaktive Tools gibt es keine
  Leermeldungen.
- Nur `L2` wird einmalig mit `I` (Wert `0`) inaktiviert. `L1`/`L3` enden, indem sie nicht mehr
  geliefert werden; dort sind `0` und `I` verboten.

Legacy prüft nur und speichert oder verteilt nichts, kein anderes Legacy-Programm kennt LMT. Wohin
sie gehen, ist Klärung **G**. Für eine Speicherung heißt das: `L1`/`L3` passen nicht in die
`N`-setzt-bis-`D`-Logik der Preise, ihr Ende ist das Ausbleiben einer Meldung.

**Herkunft der Buchstaben.** In den Quellen nicht dokumentiert (geprüft: Tabellendefinitionen,
`tmp_code`-Skripte, `Kurs/Beschreibung_v_lieferanten.xlsx`, `VWKN`/`ZEAS`/`PKVS`). `cod_fliesscode`
ist IFAS-intern, `kurs` stammt von 1994; Fremdcodes werden umgeschlüsselt (C → R, F → E, B → Z,
`auslkennzahl.cpp:360ff`). Vermutung:
- `R` = Rechenwert, der InvFG-Begriff für den NAV je Anteil
- `Z` = Rücknahmepreis, weil `R` schon vergeben war
- `E` = Emissionspreis

Bei der Fachabteilung bestätigen, falls es für Außendokumente zählt.

## 1. Anlass: was die Fachabteilung beobachtet — und was der Code dazu sagt

| Aussage der Fachabteilung | Befund | Beleg |
|---|---|---|
| „Ein `D` untertags landet nie in `kurs`" | **Stimmt, über zwei Wege.** (a) Folgt ein `D` am selben Tag auf ein `N` mit gleichem Schlüssel, löscht der Eingang das `N` aus `tmp_if_kurs`, sucht den Preis in `kurs`, findet ihn nicht (Einspielung läuft erst in Tagesjob-Schritt 4) und verwirft das `D` (`INFO_IGNORE_DEL`). Weder File noch `kurs` noch `tmp_if_last` sehen das Paar. (b) Ein `D` auf einen älteren Preis läuft ungeprüft durch, steht als `I3` im File und **entfernt** in Schritt 4 die Zeile aus `kurs` physisch. Danach ist nichts mehr nachvollziehbar: `del_protokoll` ist per Default aus und hat keinen Leser, `kurs.guelt` ist nur der Insert-Zeitstempel. | `Ifas/cprogs2/preise4/M_INSERT.CPP:4161-4271`; `Ifas/cprogs2/calc/preisekennzahl.cpp:2851-2915`, `DeleteKurseReally :1443`; `WriteKurse :719` (`getdate()`) |
| dazu, unausgesprochen | Ein `D` auf einen Preis, der **nie** in `kurs` war (z. B. Fremdwährung), löscht **nirgends** etwas. Der Preis bleibt in `tmp_if_last` und wird im Lauf-1-Fallback erneut veröffentlicht. `WriteLastKurse` liegt nur im Nicht-`D`-Zweig und setzt `cod_ex` hart `'N'`; der Löschpfad `DeleteLastKurse` ist toter Code. | `preisekennzahl.cpp:2843-2850`, `:1226-1345`, `:1849` |
| „Manche fehlgeschlagenen Prüfungen landen in `tmp_if_last`, aber nie in `kurs`" | **Stimmt für genau eine lebende Prüfung.** Zeilen, die die Eingangsprüfung ablehnen, erreichen `tmp_if_kurs` nicht und damit auch `tmp_if_last` nicht; die Plausibilität (Stufe 2) blockiert nichts. Gemeint ist die Prüfung in Stufe 4: **Preiswährung ≠ Fondswährung** → kein `kurs`-Write, `WriteLastKurse` läuft trotzdem. Zwei weitere Pfade nur auf dem Papier: ISIN in `vwkn` unbekannt (→ `pool_if_kurs` + `tmp_if_last`, seit 2012 ohne Schreiber) und ein fehlgeschlagener `kurs`-Insert (`WriteLastKurse` ignoriert den Rückgabewert von `WriteKurse`). | `preisekennzahl.cpp:2843-2850`, `:2925-2934`, `WriteKurse :719-727` |
| „Bezieher sehen gelöschte Preise nie" | **Stimmt.** `kurs` löscht physisch, `tmp_if_last` kennt kein `D`, das Preisfile trägt das `I3` nur am Tag der Löschung. Es gibt keinen Ort, an dem „dieser Preis galt von–bis und wurde am … zurückgezogen" steht. | `Kurs/tabledefs/kurs.cr`, `tmp_i_last.cr` |

Größenordnungen (Produktion, `Ifas/admin/spaceused/csv/kurs.csv`):

| Tabelle | Zeilen |
|---|---|
| `kurs` | 42,6 Mio |
| `tmp_if_cop` (verarbeitete Menge eines Tages) | 26 k |
| `tmp_if_last` | 28 k |

## 1a. Zwei weitere Aussagen der Fachabteilung (2026-09-17)

**„Ein Preis, der die Prüfung nicht besteht und nicht in `kurs` landet, darf auch nicht an die
Bezieher — auch nicht als Fallback."**

- *Heute:* das Gegenteil. Die Filegenerierung liest `tmp_if_kurs` ohne Währungsprüfung und gibt den
  Preis mit der gelieferten Währung als `I2` aus (`m_fp_rec.CPP:2554-2576`); der Fallback aus
  `tmp_if_last` veröffentlicht ihn bis zu 65 Tage weiter. Nur `kurs` verweigert ihn.
- *Folge:* die Aussage stiftet eine **Invariante — veröffentlicht ⊆ in `kurs`**. Die Zielgruppenfilter
  des Files (`veroeffentlichung`, TEST, AIF, Streams) bleiben eine *Teilmenge* davon. Damit ist
  `tmp_if_last` aus `kurs` bzw. dem Ledger ableitbar, und das Ledger braucht **keine** Zeilen mehr
  für Preise, die `kurs` nie erreichen: es wird zur Historie von `kurs`. Klärung **P** ist für den
  Währungsfall beantwortet; für den `D`-Fall (Vorversion oder Lücke?) noch nicht.
- *Wo die Regel greift, ist offen:* (a) **am Eingang** — `tax_code.isinwaehrung = J` auch für
  `R/E/Z/S/S2/S3`, dann feuert `ERR_CURRENCY04` in Alt- **und** Neusystem gleich, die Lieferung
  bekommt das Urteil `ERROR`, der Lieferant erfährt es; reine Datenänderung. (b) **beim Sync** —
  annehmen, im Ledger als „nicht in `kurs`" führen, File und Fallback filtern; der Lieferant erfährt
  nichts, das Ledger behält die Spalte, und der Filevergleich im Parallelbetrieb zeigt jeden Fall
  als Abweichung.

#### Der Währungsfall im Detail — was heute mit so einem Preis passiert

Beispiel: inländischer Fonds, USD-Tranche, der Lieferant meldet einen `R`-Preis mit Währung EUR
(Begriffe in Abschnitt 0).

| Stufe | Verhalten | Wer erfährt es |
|---|---|---|
| 1 Eingang (`preis_ins.e`) | **Angenommen.** Die Währungsprüfung `ERR_CURRENCY04` existiert, ist für `R/E/Z/S/S2/S3` aber per `isinwaehrung = N` abgeschaltet. Die Zeile landet in `tmp_if_kurs` mit `cod_waehrung = EUR`. | niemand |
| 3 Preisfile (`preis_dld.e -fPREISE`) | **Ausgegeben** als `I2;Datum;EUR;ISIN;R;Wert`. `I2` ist beim Bezieher ein Upsert auf (ISIN, Datum, Währung, Code) — er hat damit zur USD-ISIN einen EUR-Preis, neben dem USD-Preis oder als einzigen Preis des Tages. | der Bezieher, ohne es zu merken |
| 4 `kurs` (`preise.e -p0`) | **Still verworfen**, eine Zeile im Programm-Log. Kein Kurs, kein berichtigter Kurs, keine Kennzahlen. `tmp_if_last` bekommt die Zeile trotzdem, auf dem eigenen Platz (ISIN, EUR, R). | eine Logzeile |
| Fallback (Lauf 1) | An jedem Tag **ohne Lieferung dieser ISIN** wird die Zeile aus `tmp_if_last` erneut als `I2` ausgegeben, bis zu 65 Tage. Der Anti-Join prüft nur die ISIN, nicht die Währung. | der Bezieher, wieder ohne es zu merken |
| später ein `D` in EUR | Löscht in `kurs` nichts (dort war nie etwas), `tmp_if_last` bleibt unberührt, der Fallback läuft weiter. | niemand |

Die Tragweite liegt nicht in der Menge, sondern in der **Unsichtbarkeit**: der Lieferant bekommt
keinen Fehler, die OeKB sieht eine Logzeile, der Bezieher erhält einen Preis, den IFAS selbst nicht
als Kurs anerkennt, mit einer Währung, die zur ISIN nicht passt. `kurs`, `tmp_if_last` und Preisfile
laufen genau hier auseinander. Wie oft das vorkommt, sagt **V6d** auf GAST (SQL-File, noch nicht
gelaufen).

Wirkung, wenn das Flag auf `J` gesetzt wird: die eine Zeile wird mit `ERR_CURRENCY04` verworfen, die
übrigen Zeilen der Lieferung laufen normal durch, die Lieferung gilt als `ERROR`, weil eine Zeile im
Fehlerlog steht. Gleiches Verhalten in Alt- und Neusystem, weil beide dasselbe Flag lesen.

**Inland gegen Ausland.** Der Fall ist kein Auslandsthema. Die beschriebene Kette ist die
Inlandskette (`preis_ins.e -R0` → `tmp_if_kurs` → `kurs`/`tmp_if_last` → Preis- und Solva-Files),
und genau die ist Gegenstand von IFAS13-Fondspreise. Ausländische Fonds laufen über `-R1` und
`run_af_lieferung`: primär Steuerdaten (KESt, QuSt, Taxdata) mit Preisen als Rechenbasis, eigene
Tabellen (`tmp_af_fonds`, `af_kurs`, `af_pool`, `af_liefer_bugs`), eigene Files, **kein**
`tmp_if_last`-Fallback. Dieselbe Währungsprüfung mit demselben Flag gilt auch dort. Die Codes sind
über `tax_code.inland_ausland` zugeordnet: `R/E/Z` = `IA` (beide), `S/S2/S3` = `I` (nur Inland). Die
Auslandskette ist in der Ist-Analyse ausgegrenzt und nicht Teil des Umbaus.

**„Das Ausschüttungs-Veto hält nicht. Eine gebuchte Ausschüttung darf keine Operation des
Preislieferanten blockieren; stattdessen sind die Folgerechnungen (berichtigter Preis, Kennzahlen)
zu invalidieren, falls schon gerechnet."**

- *Heute:* liegt zum Preisdatum eine Ausschüttung mit Status `A`, wird eine `R`-Löschung still
  verweigert — `// ????` (`preisekennzahl.cpp:2539-2547`, `:2885-2897`). Im Nicht-Veto-Pfad tut
  Legacy bereits, was die Fachabteilung will: `DeleteKurseReally`, `DeleteKennzahlen` (Fondswährung
  und währungsbereinigt), Nachrechnung ab Preisdatum. `ASF.r_faktor` wird beim inländischen Löschen
  **nicht** genullt, sondern erst von der Nachrechnung neu gesetzt (`:3072`); genullt wird er nur im
  Auslands-Sonderfall „alles löschen" (`DeleteKurs :1660-1690`).
- *Folge:* Klärung **E** ist mit einer dritten Option beantwortet — **E3: ausführen und Abhängiges
  invalidieren**. Das Veto in D6 und `SyncSkipReason.AUSSCHUETTUNG_EXISTS` entfallen. Inhaltlich ist
  das die schon „faktisch gesetzte" Entscheidung **C1** (der Sync räumt abhängige Kennzahlen weg, der
  Sweep rechnet nach), ausgeweitet auf `ASF.r_faktor`/`r_faktor_ges` — und damit eine Antwort auf
  **K**: die Preisdomäne darf den Faktor invalidieren, gebucht wird er von der Ausschüttungsdomäne.
- *Fürs Ledger:* das **Schließen einer Version** ist der natürliche Auslöser. Zwei Wege, „schon
  gerechnet" zu erkennen: **löschen** (C1, Kennzahlen in Sybase sind bis zur Nachrechnung abwesend)
  oder **Herkunft mitführen** — jede Kennzahl kennt die Ledger-Version, aus der sie gerechnet wurde;
  „veraltet" ist dann ein Join gegen geschlossene Versionen. Die Herkunft kann wegen der
  Sybase-Schemasperre nur in Postgres liegen (C1b, mit eigener Tabelle). Was Verbraucher zwischen
  Invalidierung und Nachrechnung sehen sollen — nichts oder einen als veraltet markierten Wert — ist
  der offene Rest von **C**.

## 2. Wer liest — und was

Zwei bekannte Konsumenten, beide lesen einen **Zustand**, keinen Änderungsstrom:

1. **Preisfile-Abonnenten.** Täglich ein Preis je relevantem Fonds — der heutige, sonst der letzte
   bekannte (Fallback). Ob „vollständig" für *jedes* File gilt oder für den Tag als Ganzes (Lauf 1
   voll, Lauf 2 Delta), ist Klärung **N** — mit der Fachabteilung offen.
2. **UI** auf (derzeit) `kurs`, möglicherweise mit Fallback auf `tmp_if_last` (Klärung **O**: wer
   genau, welche Spalten).

Für einen Zustandsleser heißt „gelöschte Preise sehen": der Preis steht da, daneben „gelöscht am …,
Grund …". Kein Feed, ein geschlossener Eintrag.

## 3. Was Stufe 2 heute hat — und was ein Ledger daran ändert

| Artefakt heute (Postgres) | Rolle | mit Ledger |
|---|---|---|
| Inbox `preismeldung_zeilen` | rohe Lieferzeilen je Job, `N` und `D` | **bleibt** — der Rohinput |
| `preis_herkunft` | Guard „wer hat diese `kurs`-Zeile zuletzt geschrieben", ohne Historie, ohne Zeilen für Preise, die `kurs` nie erreichen | **geht im Ledger auf** |
| `letzte_preise` | Guard + Spiegel von `tmp_if_last` | **geht im Ledger auf** |
| zwei Cross-DB-Klammern (D4, D12) | Reihenfolge über zwei Server | **eine** Postgres-Schreibung ins Ledger; `kurs` und `tmp_if_last` werden **abgeleitet** |
| `PreismeldungSyncDecisions` | die Regeln (TEST-ISIN, C-Plan, AIF, Liquidation, Währung, Veto, Korrektur) | **bleibt**, ohne das Veto (1a) — das Ledger hält ihr Ergebnis fest |

Wichtig für das Verständnis: das Ledger ist **keine Kopie der Inbox**. Es ist das Protokoll der
Sync-Entscheidung, und die hängt von Stammdaten *zum Zeitpunkt* ab. Ein Rebuild aus der Inbox ist
deshalb retroaktiv (bekannt aus B3).

Randbedingungen: Sybase ist schema-gesperrt (Entscheidung M) → das Ledger liegt in Postgres, Kontext
`business-new-introduced`; `kurs` bleibt bis zur Sybase-Migration 2027 in Sybase, der Schritt
Ledger → `kurs` bleibt bis dahin Cross-DB. Danach kann `kurs` eine Sicht auf das Ledger werden.

## 4. Was das Ledger aus den offenen Fachfragen macht

Mit einem Ledger werden **P** und **N** zu Filtern statt zu Schemafragen:

- **Gelöschter Preis im Fallback?** Entweder fällt er heraus, oder der Fallback greift auf die
  *vorherige* noch gültige Version durch. Legacy kann beides nicht (`tmp_if_last` hat einen Platz
  je Schlüssel und veröffentlicht den zurückgezogenen Preis erneut).
- **Fremdwährungspreis im Fallback?** — **beantwortet 2026-09-17: nein**, weder Fallback noch File
  (1a). Offen ist nur, ob der Eingang ablehnt oder der Sync markiert; im zweiten Fall bleibt es ein
  Prädikat.
- **Zeitpunkt der Ableitung.** Läuft Ledger → `kurs` zur Legacy-Tagesjob-Zeit, erreicht das
  Tages-Paar `N`+`D` `kurs` nie — wie im Altsystem — und der Tabellenvergleich im Parallelbetrieb
  ist nicht mehr „rot per Konstruktion" (D13). Läuft er inline, ist `kurs` untertags frisch, mit
  den bekannten transienten Zeilen.

## 5. Die drei Formen

Alle drei Sketches zeigen denselben Fall: Fonds AT..1 liefert am 16.9. um 08:00 einen `R`-Preis und
zieht ihn um 09:00 mit `D` zurück, am 17.9. kommt der nächste Preis; Fonds AT..2 liefert in USD bei
Fondswährung EUR.

### A — eine Zeile je Preis-Version (Gültigkeitsintervalle)

Eine Version öffnet, wenn der Sync sie annimmt, und schließt, wenn eine Korrektur oder ein `D` sie
ablöst. Grund und Zeitpunkt des Endes stehen an der geschlossenen Zeile.

```
isin  | preisdatum | whg | code | wert  | gueltig_ab  | gueltig_bis | ende_grund | in_kurs
AT..1 | 2026-09-16 | EUR | R    | 101.2 | 09-16 08:00 | 09-16 09:00 | D          | ja
AT..1 | 2026-09-17 | EUR | R    | 101.9 | 09-17 08:10 | null        | -          | ja
AT..2 | 2026-09-17 | USD | R    |  55.1 | 09-17 08:12 | null        | -          | nein: Whg

aktuell  = gueltig_bis is null
Fallback = jüngste offene Zeile je (isin, whg, code) im 65-Tage-Fenster
gelöscht = geschlossene Zeilen mit ende_grund D
Stand zu T = gueltig_ab <= T < gueltig_bis
```

| Preisfile mit Fallback | UI aktuell + gelöscht | Kosten |
|---|---|---|
| ein Prädikat auf offenen Zeilen | offene Zeilen, dazu geschlossene mit Grund | eine Ablösung berührt zwei Zeilen (schließen + öffnen); der „Warum"-Kontext liegt an der alten Zeile, nicht an der neuen |

Vertraut im Haus: dasselbe Muster wie `guelt_ab`/`guelt_bis` an `steuer_meldung`.

### B — eine Zeile je Operation (Ereignis-Ledger)

Append-only: `NEU`, `DEL`, `SKIP` mit Zeitpunkt und Grund. Nie ein Update.

```
isin  | preisdatum | whg | code | op   | wert  | zeitpunkt   | grund
AT..1 | 2026-09-16 | EUR | R    | NEU  | 101.2 | 09-16 08:00 |
AT..1 | 2026-09-16 | EUR | R    | DEL  |   -   | 09-16 09:00 | D
AT..1 | 2026-09-17 | EUR | R    | NEU  | 101.9 | 09-17 08:10 |
AT..2 | 2026-09-17 | USD | R    | SKIP |  55.1 | 09-17 08:12 | Waehrung

aktuell  = letzte op je Schlüssel ist NEU
Fallback = je Schlüssel falten, dann Fenster
gelöscht = letzte op je Schlüssel ist DEL
Stand zu T = alle ops <= T falten
```

| Preisfile mit Fallback | UI aktuell + gelöscht | Kosten |
|---|---|---|
| je Schlüssel falten, dann Fenster | je Schlüssel falten | **jeder** Leser faltet — auch die eigene Ableitung nach `kurs`; die Stärke der Form, ein Änderungsstrom, hat derzeit keinen Abnehmer |

### C — Ist-Tabelle plus Historie

Eine Ist-Tabelle in der Gestalt von `kurs` und eine getrennte Historie mit jeder Version und jeder
Löschung.

```
preis_aktuell
 isin | preisdatum | whg | code | wert  | seit
 AT..1| 2026-09-17 | EUR | R    | 101.9 | 09-17 08:10

preis_historie
 isin | preisdatum | whg | code | wert  | von         | bis         | grund
 AT..1| 2026-09-16 | EUR | R    | 101.2 | 09-16 08:00 | 09-16 09:00 | D
 AT..1| 2026-09-17 | EUR | R    | 101.9 | 09-17 08:10 | null        | -

aktuell  = preis_aktuell
Fallback = preis_aktuell, sonst jüngste in preis_historie
gelöscht = nur in preis_historie sichtbar
```

| Preisfile mit Fallback | UI aktuell + gelöscht | Kosten |
|---|---|---|
| Ist-Tabelle, für den Fallback zusätzlich die Historie | Ist-Tabelle; Löschungen nur, wer die Historie liest | zwei Tabellen konsistent halten; der Fallback joint trotzdem beide; „Bezieher sehen Löschungen" hängt daran, dass sie die zweite Tabelle wirklich lesen |

## 5a. Der Guard aus Stufe 2 — was aus ihm in den drei Varianten wird

Stufe 2 führt heute einen monotonen Guard (`preis_herkunft`, Konzept *Zwei Server, ein Pool*, Plan
D4) und einen zweiten für die Projektion (`letzte_preise`, D12). Der Guard leistet drei Dinge:

1. **Serialisierung** — zwei Server, die gleichzeitig denselben Preisschlüssel bearbeiten, laufen
   über die gesperrte Guard-Zeile hintereinander.
2. **Reihenfolge-Entscheidung** — die später *angekommene* Lieferung gewinnt, egal welcher Server
   zuerst dran ist; `angekommen_am` wird bei der Ankunft vergeben, nicht bei der Verarbeitung.
3. **Klammer** — der Sybase-Write nach `kurs` hängt an dieser Entscheidung, weil er in derselben
   gesperrten Spanne passiert (Cross-DB-Klammer, Fehlerfenster laut Konzept).

Der zweite Guard `letzte_preise` (Schlüssel ohne Preisdatum, Regel „jüngstes Preisdatum, dann
späteste Ankunft") **entfällt in allen drei Varianten**: die Projektion wird zur Abfrage, die Regel
wandert in die Abfrage.

| | A Intervalle | B Ereignisse | C Ist + Historie |
|---|---|---|---|
| Serialisierung beim Schreiben | die **offene Version je Schlüssel ist der Guard**: bedingtes Schließen, wenn `angekommen_am` neuer ist, dann neue Version öffnen; `preis_herkunft` geht darin auf | **nicht nötig** — Append kollidiert nie | die Ist-Zeile ist der Guard, wie A |
| Reihenfolge-Entscheidung | beim Schreiben; eine verspätete ältere Lieferung wird als **von Geburt geschlossene** Version eingetragen, damit die Historie vollständig bleibt | beim **Lesen**: Faltung sortiert nach `angekommen_am`, deterministischer Tiebreak (Job, Zeile) | beim Schreiben, wie A |
| Ableitung nach `kurs` | liest den committeten Stand; die Klammer über zwei DBMS entfällt, sobald der Sync nicht mehr inline schreibt | **inline**: zwei Server falten gleichzeitig, sehen je nur das eigene Ereignis, schreiben beide nach `kurs`, die Sybase-Reihenfolge entscheidet — genau das Rennen, das der Guard heute verhindert. **Entkoppelt**: ein einzelner Sync faltet den committeten Stand, kein Rennen, aber Wasserstandsmarke auf einer **monotonen Einfügesequenz** (ein verspätetes Ereignis trägt ein altes `angekommen_am`) | wie A |
| Wiederholung eines Jobs | findet die eigene offene Version → No-op | fügt das Ereignis **erneut** an → Eindeutigkeitsschlüssel (Job, Zeile) nötig | wie A |
| Stand zu Zeitpunkt T | Index auf (`gueltig_ab`, `gueltig_bis`) | alles bis T falten | Ist-Tabelle nur „jetzt", Historie für T |

**Folge:** zwei Entscheidungen, die getrennt aussahen, hängen zusammen. Variante B spart den Guard
nur, wenn die Ableitung nach `kurs`/`tmp_if_last` **nicht** im Lieferjob passiert, sondern als eigener
Schritt aus dem committeten Ledger; B mit Inline-Ableitung bringt den Guard zurück (als Sperre oder
Zeile). A und C brauchen den Guard weiter, aber nicht als eigene Tabelle — er ist die Zeile, die sie
ohnehin führen; und auch bei ihnen fällt die Cross-DB-Klammer nur, wenn die Ableitung aus dem
committeten Stand liest.

In keiner Variante fällt weg: irgendwo wird einmal entschieden, welche von zwei Lieferungen zum
selben Schlüssel gilt. Bei A und C steht die Entscheidung **in der Tabelle**, bei B **im Lesecode**.
Das ist die eigentliche Wahl, nicht ob es eine Guard-Tabelle gibt.

## 5b. Empfehlung (Stand 2026-09-17, auf Nachfrage)

**Variante A — Gültigkeitsintervalle.**

- **Beide bekannten Leser wollen einen Zustand.** „Aktuell", „Fallback im 65-Tage-Fenster", „gelöscht
  am", „Stand zum Lauf-1-Cutoff" sind bei A je ein Prädikat auf indizierten Spalten. Bei B faltet
  jeder Leser — auch die eigene Ableitung nach `kurs`.
- **Die Reihenfolge-Entscheidung steht in der Tabelle, nicht im Lesecode.** Die offene Version ist
  der Guard, eine Job-Wiederholung ein No-op, und im Parallelbetrieb lässt sich die Entscheidung
  zeilenweise diffen. Bei B muss jeder Leser dieselbe Sortier- und Tiebreak-Regel richtig umsetzen.
- **Systemzeit gibt es umsonst.** `gueltig_ab`/`gueltig_bis` sind genau die Spalten, die Lauf 2 als
  Differenz zweier Stände und eine terminierte Ableitung brauchen.
- **C ist A plus eine zweite Tabelle, die es schon gibt.** Die „Ist-Tabelle in Gestalt von `kurs`"
  ist während des Parallelbetriebs `kurs` selbst, abgeleitet aus dem Ledger. Eine weitere Kopie in
  Postgres konsistent zu halten bringt nichts, was A nicht hat.
- **Bekanntes Muster.** `guelt_ab`/`guelt_bis` an `steuer_meldung` ist dasselbe Modell; Team und
  IFASNXT kennen es.

**Was die Empfehlung kippen würde:** ein Bezieher, der einen **Änderungsstrom** braucht — etwa
IFASNXT, wenn es statt des vollen SSIS-Abzugs aus `kurs` künftig nur Deltas ziehen soll. Dann trägt
B seine Kosten selbst. Nach heutigem Wissen über die Bezieher nicht in Sicht; als Frage neben N an
die Fachabteilung mitnehmen (Abschnitt 7, Frage 7).

**Was A nicht vorentscheidet:** ob die Ableitung nach `kurs` inline oder terminiert läuft. Beides
geht, weil sie aus dem committeten Stand liest.

## 6. Was jetzt entschieden werden muss — und was warten kann

> Brainstorming-Stand vom Abend des 2026-09-17 dazu in **8.5**.

**Jetzt**, weil es die Gestalt einer Zeile ist und später nicht nachgefüllt werden kann:

| Entscheidung | Warum nicht später |
|---|---|
| **Form A, B oder C** (Abschnitt 5) | legt fest, wie jeder Leser schaut — auch die Ableitung nach `kurs` |
| **Systemzeit an jeder Zeile**: seit wann eine Version in IFAS gilt, seit wann nicht mehr, und warum | ohne sie kein Stand „zum Lauf-1-Cutoff", keine Wasserstandsmarke für einen terminierten Sync, kein Lauf 2 als Differenz zweier Stände |
| **Zeilen, die `kurs` nie erreichen** — nach 1a nur noch, wenn der Fremdwährungsfall **beim Sync** statt am Eingang abgefangen wird; sonst ist das Ledger die reine Historie von `kurs`, und Ablehnungen stehen in Rückmeldung und Job-Ergebnis | eine Spalte „nicht in `kurs`, Grund" lässt sich später nicht nachfüllen; ohne sie ist die Beobachtung der Fachabteilung nur aus Logs rekonstruierbar |
| **Beide Identitäten**: ISIN wie geliefert **und** `num_wfs_ku` wie zur Sync-Zeit aufgelöst | `kurs` ist über die eine, `tmp_if_last` über die andere geschlüsselt; ISIN-Umbenennungen gibt es (`ISIN_UPD`) |
| **Exakter Wert** | die Inbox trägt den gelieferten Dezimalwert als Text, `kurs` ein `float` |

**Später**, weil es Ableitung, Filter oder Terminierung ist:

- **wann** Ledger → `kurs` und Ledger → `tmp_if_last` laufen: inline (Minuten nach der Lieferung)
  oder terminiert (Legacy-Tagesjob-Zeit) — Abschnitt 4
- ob `tmp_if_last` überhaupt weitergeführt wird (Klärung **O**)
- welche Zeilen der Fallback nimmt: gelöschte, Fremdwährung, Durchgriff auf die Vorversion (**P**)
- Lauf 2 als Delta oder als zweiter Vollstand, und damit die Rolle des Publikationsprotokolls (**N**)
- Rebuild und Aufräumregeln (35 Tage nach Fondsende)

## 7. Fragen an die Fachabteilung, die die Form nicht blockieren, aber die Filter entscheiden

1. Gilt „alle relevanten Fonds, mit Fallback" für **jedes** ausgelieferte File oder für den Tag als
   Ganzes? (**N**; entscheidet Lauf 2 Delta vs. Vollstand)
2. Darf ein per `D` zurückgezogener Preis im Fallback erneut erscheinen — oder soll auf die
   Vorversion durchgegriffen werden — oder fällt der Fonds an dem Tag aus dem File? (**P**, Rest)
3. ~~Fremdwährung im Fallback?~~ **Beantwortet: nein** (1a). Folgefrage: **heute bekommt der
   Lieferant dafür keinen Fehler** — die Prüfung `ERR_CURRENCY04` existiert in Alt- und Neusystem,
   ist aber per `tax_code.isinwaehrung` nur für LMT- und Steuercodes eingeschaltet (`J`), für
   `R/E/Z/S/S2/S3` und die KESt-Codes `C/F` **explizit `N`** — so schon im Install-Skript von 2012
   (`Kurs/tabledefs/insert_tax_code.cr:160-307`), so auf GAST (`standard_TAX_CODE_data.yaml`). Der
   Mechanismus selbst läuft für jede Zeile (`M_INSERT.CPP:1184` → `CheckValue :3285`); im
   Preismeldungs-Pfad feuert er damit nur für `L1`–`L3`. Soll sie für die Preis- und
   Solva-Codes eingeschaltet werden (Datenänderung, gilt für beide Systeme, Urteil `ERROR`, Lieferant
   sieht es; Häufigkeit über V6 auf GAST), oder soll der Sync still aussortieren? (Fragen-File vom
   [2026-09-11](2026-09-11-fondspreise-fachabteilung-fragen-fallback-waehrung.md), Frage 3)
4. Welche UI liest heute `kurs`, und greift sie auf `tmp_if_last` durch? Welche Spalten? (**O**)
5. Zum aufgehobenen Veto (**E3**): soll der Lieferant erfahren, dass seine Löschung eine gebuchte
   Ausschüttung entwertet hat, oder ist das ein interner Befund (Sync-Report, Sammelreport)?
6. Was sollen Leser von Kennzahlen zwischen Invalidierung und Nachrechnung sehen — keinen Wert oder
   einen als veraltet gekennzeichneten? (Rest von **C**; entscheidet zwischen Löschen und
   Herkunft-Mitführen, 1a)
7. Braucht ein Bezieher künftig einen **Änderungsstrom** („alles seit meinem letzten Abzug") statt
   eines Standes — insbesondere IFASNXT, das heute per SSIS voll aus `kurs` zieht? (entscheidet
   zwischen Variante A und B, Abschnitt 5b)
8. Soll „fehlt" in der Fehlmeldung **„keine gültige Version heute"** heißen (dann ist der Ledger die
   Quelle, 8.4)? Und soll die Meldung unterscheiden zwischen *nie geliefert*, *übersprungen* und
   *zurückgezogen*? (entscheidet, ob eine übersprungene Zeile einen Status braucht — das eine, was
   `JobWorkloadItem` mitbringt, 8.3)

## 8. Brainstorming-Stand 2026-09-17 (Abend) — Tendenz und offene Fäden

**Noch nicht entschieden.** Fortsetzung am 2026-09-18. Festgehalten, damit die Diskussion dort
weitergeht, wo sie aufgehört hat.

### 8.1 Tendenz: Variante C mit optionaler Ist-Tabelle — also A mit Nachrüstoption

Die Tendenz geht zu **C**, wobei `preis_aktuell` nur gebaut wird, wenn eine Abfrage es aus
Performancegründen verlangt. Ohne `preis_aktuell` **ist** C die Variante A: `preis_historie` mit
`von`, `bis` und Grund, `bis is null` = aktueller Stand. Die Ist-Tabelle wird damit zu einer
materialisierten Sicht, die ohne Datenverlust nachrüstbar ist. Empfehlung 5b und Tendenz decken sich
inhaltlich.

### 8.2 Herkunft: `preis_historie` referenziert ihre Ursprungszeile

Jede Version entsteht aus **genau einer** angenommenen Lieferzeile → Referenz 1:1. Über sie erreicht
man Job, Lieferant, Zeilennummer, Ankunftszeit und die Rohwerte. Der Ledger trägt selbst nur, was
seine Leser brauchen: Preisdatum, Währung, Kategorie, Wert, `num_wfs_ku` **und die Fondsbezeichnung**
(sonst müsste die Ableitung nach `tmp_if_last` in die andere Datenbank greifen).

Zwei Präzisierungen:

- **Zwei Referenzen je Version**, nicht eine: `ursprung` (die öffnende `N`-Zeile) und
  `beendet_durch` (die korrigierende `N`-Zeile **oder** die `D`-Zeile). Ohne die zweite wäre eine
  `D`-Zeile vom Ledger aus unerreichbar — und genau die interessiert die Fachabteilung. Eine
  korrigierende Zeile steht damit zweimal im Ledger: als Ende der alten, als Ursprung der neuen
  Version.
- **Die Referenz ist logisch**, kein DB-Fremdschlüssel: die Inbox liegt seit V067 in der Datenbank
  des Job-Systems, der Ledger soll in `business-new-introduced` liegen (dasselbe gilt heute für
  `preis_herkunft.job_id`). Ein echter FK bräuchte beide in einer Datenbank — Ledger zum Job-System
  widerspräche „Business-Tabellen nicht nach infra". Folge: die **Lebensdauer der referenzierten
  Zeile muss dem Ledger folgen**, sonst degradiert die Herkunft still zu einer UUID ohne Ziel;
  oder der Ledger nimmt beim Archivieren die für ihn wichtigen Felder mit.

Der PK der Inbox ist zusammengesetzt `(job_id, zeilen_nr)` — für die Referenz wäre eine einspaltige
Identität (`uuid`) angenehmer. Das führt zu 8.3.

### 8.3 Inbox durch `JobWorkloadItem` ersetzen?

`JobWorkloadItem` (`infra.job_workload_items`, V065) ist die generische Arbeitsvorrats-Tabelle des
Job-Systems: `id uuid`, `owner_job_id`, `item_type`, `payload TEXT` (JSON), `status`
(`PENDING/PROCESSING/COMPLETED/FAILED/SKIPPED`), `status_message`, Claim-Spalten `processing_id` /
`processing_job_id`, `created_at`, `processed_at`. Heute genutzt von der Ausschüttungs-Kette (ein
Item je `Ausschuettung`).

| | `preismeldung_zeilen` heute | `JobWorkloadItem` |
|---|---|---|
| Identität einer Zeile | `(job_id, zeilen_nr)` | `id uuid`, einspaltig — fertig für die Ledger-Referenz |
| Status je Zeile | keiner; Inbox ist append-only (Konzept 3) | Sync-Ausgang je Zeile **mit Grund** (`SKIPPED` + `status_message`) |
| Abfragen über Jobs hinweg | typisierte Spalten (ISIN, Preisdatum, Währung, Kategorie, Aktion) | `payload TEXT`, kein `jsonb`: nach ISIN filtern heißt lesen und parsen, oder fondspreise-spezifische Ausdrucksindizes auf einer generischen Infra-Tabelle |
| Reihenfolge im File | `zeilen_nr` | nur im Payload |
| Claim-Protokoll | — | vorhanden, bliebe leer (Preiskette verarbeitet je Lieferung inline) |
| Aufbewahrung | ≥ 65 Tage + Puffer, bewusst | Items gehen mit ihren Jobs — Lebensdauer neu zu regeln (8.2) |
| Volumen | ~26 k Zeilen/Tag | dasselbe, in einer Tabelle, die bisher wenige Ausschüttungen hält |

**Das Hauptgegenargument entfällt mit dem Ledger.** Die drei Leser, für die die Inbox typisierte
Spalten quer über Jobs brauchte, wandern:

| Leser | vorher (Inbox) | mit Ledger |
|---|---|---|
| Fehlmeldung (Konzept 11) | Inbox quer über Jobs nach ISIN | **Anti-Join auf dem Ledger** (8.4) |
| Lieferketten-Transparenz (Konzept 12) | Inbox nach ISIN und Datum | jede Version trägt ihren Job; geschlossene Versionen zeigen die Ablösung |
| Rebuild der Projektion (B3) | Inbox in Ankunftsreihenfolge | entfällt — die Projektion ist eine Abfrage |

Was von der Inbox übrig bleibt, ist **per Job** adressiert: Replay einer Lieferung, wenn der
Ledger-Write scheiterte; Zeilenliste in der UI; übersprungene Zeilen mit Grund. Für die ersten
beiden reicht ein Payload, das dritte ist genau der Item-Status.

**Arbeitsteilung, wie sie sich abzeichnet:** das Item sagt, *was aus jeder Zeile wurde*; der Ledger
sagt, *welche Preise wann galten und warum sie aufhörten*. Eine Zeile ohne Version (übersprungen,
nur schließend) ist vom Ledger aus nicht sichtbar, sondern nur über ihren Item-Status — kein Mangel,
sondern diese Arbeitsteilung.

### 8.4 Fehlmeldung aus dem Ledger

Fachlich fragt die Fehlmeldung nicht „hat der Lieferant etwas geschickt", sondern **„gibt es für
diesen Fonds heute einen gültigen Preis"** — und das steht nur im Ledger. Als Anti-Join: alle Fonds
mit `INV.preismeldung` und täglicher Periodizität ohne Version mit `preisdatum = heutiger Börsetag`
und `gueltig_bis is null`. Ein Teilindex auf `(preisdatum, isin)` für offene Versionen macht das
billig. Weil der Ledger auch `gueltig_ab` kennt, lässt sich „heute angekommen" von „Preisdatum heute"
trennen (T+1-Lieferanten).

Drei Fälle, in denen Ledger und Inbox verschiedene Antworten geben:

| Fall | Inbox | Ledger |
|---|---|---|
| **übersprungen** (TEST-ISIN, AIF, C-Plan, Liquidation, nur LMT, Währung falls nicht am Eingang) | „geliefert" | „fehlt" — fachlich richtig; die Meldung an den Lieferanten sollte den Unterschied aber kennen (Item-Status) |
| **zurückgezogen** (`D` schließt die heutige Version) | nur durch Nachrechnen | „fehlt", und zugleich „zurückgezogen um … durch Job …" aus der geschlossenen Version |
| **am Eingang abgelehnt** | nicht enthalten | nicht enthalten — nur im Job-Ergebnis, für beide gleich |

### 8.5 Was das für Abschnitt 6 („jetzt entscheiden") heißt

- **Form:** A bzw. C-ohne-Ist-Tabelle (8.1) — Tendenz, nicht Entscheidung.
- **Beide Identitäten** (ISIN, `num_wfs_ku`) und **exakter Wert**: unverändert nötig; dazu die
  **Fondsbezeichnung** am Ledger (8.2).
- **Systemzeit:** `von`/`bis` je Version — unverändert.
- **Zeilen, die `kurs` nie erreichen:** nicht im Ledger, sondern als Item-Status (8.3) — falls die
  Inbox zum `JobWorkloadItem` wird; sonst offen.
- **Neu:** zwei Item-Referenzen je Version (8.2) und die Lebensdauer der Items (8.2, 8.3).

## Quellen

| Aussage | Fundstelle |
|---|---|
| Tages-`N`+`D` wird am Eingang verschluckt; `kurs`-Lookup nur in diesem Zweig | `Ifas/cprogs2/preise4/M_INSERT.CPP:4138-4371` (`Check4DeleteInTmp`), Aufruf `:1278-1291` |
| Stufe 3 (File) vor Stufe 4 (`kurs`) im Tagesjob | `docs/Fondspreise/fondspreise-legacy-analyse.md` 1.1 |
| Währung ≠ Fondswährung → kein `kurs`, `WriteLastKurse` trotzdem; `D` in Fremdwährung → nichts | `Ifas/cprogs2/calc/preisekennzahl.cpp:2843-2850`, `:2862`, `:2879` |
| `WriteLastKurse`: Schlüssel ohne `dat_kurs`, `cod_ex` hart `'N'`, Rückgabewert von `WriteKurse` unbeachtet | `preisekennzahl.cpp:1226-1345`, `:719-727` |
| `DeleteLastKurse` ohne Aufrufer, SQL mit falschen Spalten | `preisekennzahl.cpp:1849`, `:1939` |
| Pool-Zweig (`cod_art_g != 'IF'`) schreibt `pool_if_kurs` + `tmp_if_last` | `preisekennzahl.cpp:2925-2934` |
| Fallback-Selektion: Anti-Join gegen `tmp_if_kurs`, 65-Tage-Fenster | `Ifas/cprogs2/preise4/m_fp_rec.CPP:2554-2576`, `M_FP_DLD.CPP:127` |
| `kurs`: PK `(num_wfs_ku, dat_kurs, cod_fliesscode, waehrung)` mit `ignore_dup_key`; `guelt` = Insert-Zeit | `Kurs/tabledefs/kurs.cr`, `I_kurs.cr` |
| `tmp_if_last`: PK inkl. `cod_ex`, Unique-Index `(num_okb, cod_preiscode, cod_waehrung)` | `Kurs/tabledefs/tmp_i_last.cr`, `I_tmp_il.cr` |
| Filegenerierung ohne Währungsprüfung; Zielgruppenfilter | `m_fp_rec.CPP:2554-2576`; `docs/Fondspreise/fondspreise-legacy-analyse.md` 4.2 |
| Ausschüttungs-Veto (`// ????`); Nicht-Veto-Pfad löscht Kennzahlen und rechnet nach | `preisekennzahl.cpp:2539-2547`, `:2885-2915`, `DeleteKennzahlen :1985` |
| `r_faktor` nur im Auslands-„alles löschen" genullt; sonst von der Nachrechnung gesetzt | `preisekennzahl.cpp:1660-1690`, `:3072` |
| Ausschüttungs-Einspielung verlangt inländisch einen Preis | `Ifas/cprogs2/calc/asfkennzahl.cpp:880-916` |
| Klärungen C (C1/C1b), E, K im Konzept | [Konzept](2026-08-31-fondspreise-neuentwicklung-konzept.md), Abschnitte C, E, K |
| Stufe-2-Artefakte heute | `feat/fondspreise-sync`: `V067__fondspreise_sync.sql`, `V069__tmp_if_last.sql`, `PreismeldungSyncService`, `LetztePreiseService`, `PreismeldungSyncDecisions` |
