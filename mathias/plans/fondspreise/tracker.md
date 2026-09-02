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
| **H** | Ausschüttung ohne Preis auch zur Ingest-Zeit melden? Empfänger, Fehler/Info, gegen `kurs` oder Landezone? | Markus / Fachabteilung | — | offen |
| **I** | Sweep bei fehlendem Referenzkurs: Voreinstellung I1 bestätigen (I2 konfigurierbar) | Fachabteilung | — (Voreinstellung blockiert nicht) | offen |
| **J** | Fehlmeldung: Zuordnung Lieferant↔ISIN, Empfänger, Zeitpunkt | Markus / Fachabteilung | Schnitt 7 | offen |
| **K** | Wem gehört `ASF.r_faktor`? (K1/K2/K3) | Markus | Schnitt 6 | offen |
| **L** | Vorrangregel Preis-/Ausschüttungs-Einspielung — Empfehlung O1+O3 bestätigen | Markus / Fachabteilung | — | offen |
| **N** | Zweck des `tmp_if_last`-Fallbacks (N1/N2) — N2 würde Entscheidung 6 kippen | Fachabteilung / Bezieher | Schnitt 5 | offen |
| 13. | `ERR_DATE04` nur für Code `R` — gilt Kommentar oder Code? | Fachabteilung | Schnitt-1-Detail | offen |
| 14. | Bestätigen, dass nur Plausi-Abschnitt 15 entfällt (nicht 17, `makeCorrelationERZ`) | Markus | Schnitt-4-Detail | offen |
| — | „LMT = Liquidity Management Tools" für Außendokumente bestätigen | Fachabteilung | — | offen |
| — | `PreisHerkunft` vs. `KursHerkunft` (Vorauswahl `PreisHerkunft`) | intern | — | offen |

## 2. Datenbeschaffung

Quelle: Konzept, Abschnitt *Datenbeschaffung*. Q-Nummern siehe Warnung unten.

- [ ] **Produktive `tax_code`-Zeilen** — definiert das gesamte Ingest-Prüfverhalten
      (**blockiert Schnitt 1**)
- [ ] Produktive `ifas..preismeldung`-Zeilen + Verteilung `INV.preismeldung` (Q5) —
      Voraussetzung Fehlmeldung (Schnitt 7)
- [ ] `kurs..KAG_lieferanten` mit `liefer_typ='F'` (Q0–Q4) — beantwortet J
- [ ] `ifas..ASF`-Statuskollisionen (Q9–Q11) — Legacy-Verhalten oder Legacy-Bug in
      `ReadAusschuettung`?
- [ ] Ausschüttungen ohne Preis (Q12) — wie oft schlägt der Zirkel produktiv zu, ist `X` der Ausweg?
- [ ] `ASF.r_faktor`-Lücken (Q13) — Gegenprobe zu K
- [ ] `CONFIG.INI`: `Referenzkurs_Tage`, `CalcOhneReferenzkurs`, `Del_Protokoll`, `Nachrechnung`;
      `PREIS_DLD.INI`: `Preis_MinTage4Meldung` / `Preis_MaxTage4Meldung`
- [ ] `AllowOldPreisFormat`, `AllowTxtExt4PreisFile` — muss das alte Format 1 bedient werden?
- [ ] `MFT_*.INI` — Zielverzeichnisse und Accounts
- [ ] `pool_if_kurs`-Semantik (Upsert oder Append, welcher Schlüssel?) — braucht es den Guard auch
      dort?
- [ ] Vollständiger `fplausib.txt` mit Treffern in allen Abschnitten (Meldungstexte)
- [ ] Aktuelle `preis.dtd`, wie tatsächlich ausgeliefert
- [ ] `datum_min`-Vergleichsrichtung (Code widerspricht Feldbeschreibung) — Fachabteilung

> **Achtung:** das im Konzept referenzierte `fondspreise-lieferant-isin-analyse.sql` (die
> Sybase-Queries Q0–Q13) liegt derzeit weder in diesem Repo noch in ifas13 — wiederfinden oder neu
> erstellen, bevor die Q-Nummern abgearbeitet werden können.

## 3. Schnitte

Definition: Konzept, *Implementierung in Schnitten*. Der Detail-Plan je Schnitt entsteht beim Start
als eigenes datiertes File in diesem Ordner und wird hier verlinkt.

| # | Schnitt | blockiert durch | Detail-Plan | Status |
|---|---|---|---|---|
| 1 | Lieferkette Stufe 1 — Ingest, Landezone, Rückmeldung | `tax_code`-Datenbeschaffung | — | offen |
| 2 | Stufe 2 — Sync, Guard (Klammer-Transaktion), `letzte_preise` inkl. Seed + Rebuild | — | — | offen |
| 3 | `WirksamePreismeldungen` als Komponente, isoliert getestet | — | — | offen |
| 4 | Sammelreport Lauf 1 — Plausi, Files, Publikationsprotokoll, Verteilung | — | — | offen |
| 5 | Lauf 2 als Delta, inkl. `I3` gegen das Publikationsprotokoll | N, F | — | offen |
| 6 | Stufe 3 + Kennzahlen-Sweep | K, Kennzahlen-Ist-Analyse | — | offen |
| 7 | Fehlmeldungs-Job | J | — | offen |
| 8 | Lieferketten-Transparenz im Report | — | — | offen |
| quer | `PreisMeldungDiffJob` (Parallelbetrieb) — ersetzt den BadInput-Stub, wächst mit 1/2/4/5 | Schnitt 1 | — | offen |

## 4. Weitere Schritte

- [ ] Kennzahlen-Ist-Analyse erstellen (`preisekennzahl.cpp`, `fondskennzahl.cpp`, `c_calc.cpp`) —
      fehlt laut Abgrenzung, Voraussetzung für Schnitt 6
- [ ] Soll-Konzept nach `docs/Fondspreise/fondspreise-soll-konzept.md`, sobald I entschieden ist
      (B ist entschieden)
- [ ] `docs/Technische Konzepte/ifas13-jobs.md` aktualisieren — „Fondspreise — out of scope" stimmt
      dann nicht mehr
- [ ] `docs/Fondspreise/fondspreise-legacy-analyse.deck.html` neu erzeugen (laut Konzept veraltet:
      zeigt noch `I4`, 26 Sektionen gegen 53 Abschnitte)

## Erledigt

- 2026-09-01 — A geschlossen; B entschieden (B3); C entschieden (C1, C1b dokumentiert);
  D entschieden (explizites `I3`)
- 2026-09-02 — M entschieden (Sybase schema-gesperrt, Business-Tabellen nach Postgres/`kurs`);
  Runden 7+8 eingearbeitet, Konzept-Deck aktuell
