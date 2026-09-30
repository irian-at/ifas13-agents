# Fondspreise — `preis_historie` als Preis-Zeitreihe, Schritt für Schritt

Stand 2026-09-24. Ergebnis der Diskussion vom 23./24.09. über das
[Formen-Dokument](2026-09-17-fondspreise-preis-ledger-formen.md) (Stand 17.09.) hinaus. Dieser
Plan ersetzt dort die offenen Abschnitte 5–8 und das Guard-Design von Schnitt 2
([Schnitt-2-Plan](2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md), Branch
`feat/fondspreise-sync`: `preis_herkunft`, `letzte_preise`, Klammer-Transaktionen).

**Review 2026-09-24** ([Review-Datei](2026-09-24-fondspreise-preis-historie-zeitreihe-review.md)):
Befunde B1–B6 übernommen — die Auflösung faltet **ab der letzten nicht verdrängten Zeile** statt je
Kalender-Empfangstag (B1/B2), die Transaktion umfasst nur `business-new-introduced`, der Marker
folgt danach (B3), `wert` ist `numeric` ohne Skala, einmal an der Inbox-Grenze geparst (B4,
revidierte Fassung), `empfangen` und `sicht_von` kommen aus der DB-Uhr über
`DatabaseContextHelper.currentDbTime()` (B5), am Job stehen drei beschriebene Zeitstempel
`empfangen`/`eingang_abgeschlossen_am`/`verarbeitet_am` (B6, Chunk 3), die Eingangsstufe ist
**write-once** — ein Retry wertet nicht neu aus — und die Quelle einer Zeile ist der **Auslöser**
und eindeutig, per Unique-Index erzwungen (B7, revidiert, 25.09.). Angepasst: Abschnitte 1, 2, 3.1, 4,
5, 8, Chunks 1/3/4/5, Quellen. Die übrigen Befunde (B8–B14) sind offen.

**Scope: korrekte Daten in `preis_historie`.** Die Ableitung nach `kurs`/`tmp_if_last`, der
Sammelreport und die Fehlmeldung lesen später aus dieser Tabelle und sind hier nur als Ausblick
(Abschnitt 8) enthalten.

**Umsetzung in Chunks** (Abschnitt 7): jeder Chunk ist ein eigener Commit auf master, baut, hat
seine Tests und macht den Stand besser, ohne auf den nächsten zu warten. Kein großer Feature-Commit.

---

## 1. Entscheidungen

| Thema | Entscheidung |
|---|---|
| Form | Eine Tabelle `preis_historie`, **eine Zeile je Zustand eines Preisschlüssels**, lückenlose Kette wie `GjZeitreihe`. Eine Löschung ist eine **eigene Zeile ohne Wert** (D-Zeile). Keine Ist-Tabelle, keine Ereignis-Tabelle |
| Zeitachsen | **Stichtag = Preisdatum** (Teil des Schlüssels). **Sichttag** = `sicht_von`/`sicht_bis` als Zeitstempel aus der DB-Uhr: seit wann IFAS diesen Zustand zeigte. „Preis für x, gesehen zum Zeitpunkt y" ist immer beantwortbar, nichts einmal Sichtbares wird umgeschrieben |
| Reihenfolge | Es zählt die **zuletzt empfangene** Lieferung: `empfangen` am Job, bei der Einreichung aus der DB-Uhr gesetzt (`DatabaseContextHelper.currentDbTime()`), Wiederholungen erben es (Chunk 3). Die Verarbeitungsreihenfolge entscheidet nichts |
| Auflösen | **Je Schlüssel, ab der letzten nicht verdrängten Zeile**: Ausgangszustand ist die letzte Zeile der Kette, deren Job nicht verdrängt ist (Abschnitt 5; ohne Wiederholungen die offene Zeile; keine Zeile = gelöscht), ihre Quelle der Cursor. Gefaltet werden alle angenommenen Zeilen des Schlüssels aus nicht verdrängten Jobs, deren Quelle in der Ankunftsordnung `(empfangen, job_id, zeilen_nr)` **nach** dem Cursor liegt, in dieser Ordnung: N setzt den Wert, D entfernt ihn. Endzustand ≠ **offene Zeile** → eine Änderung (Abschnitt 3). Kein Tagesbezug |
| Gleicher Wert | Ein neueres N mit **numerisch** gleichem Wert erzeugt keine neue Zeile (kein Informationsgehalt). Ein D auf einen schon gelöschten Schlüssel ebenso. Gleichheit = `BigDecimal.compareTo` (`BigDecimals.equalsIgnoreScale`), nicht `equals`: Postgres behält die Eingabeskala (`101.20`), H2 streicht Nachnullen (`101.2`). **Zu bestätigen (Fachabteilung):** dass die neuerliche Lieferung desselben Preises keinen Mehrwert hat — Tracker, Todo „Identische Nachlieferungen" |
| D ohne Wirkung | Wird nicht gespeichert. Auch über Tage hinweg kein Sonderfall: eine späte N-Zeile eines früheren Tags und das schon verarbeitete D landen in derselben Faltung und heben sich auf (Szenario 2) |
| Stammdaten | Stand **zum Stichtag** der Zeile. Stammdatenänderungen im Nachhinein werden nicht berücksichtigt (Fachabteilung 2026-09-24). Kein Nachlauf für Stammdatenänderungen innerhalb des Tages: realistisch kann keine Entscheidung kippen (Abschnitt 3.3) |
| Währung | Prüfung am **Eingang** (`ERR_CURRENCY04` über `tax_code.isinwaehrung = J` für `R/E/Z/S/S2/S3`), **nur im Neusystem**, für Lieferanten ab Go-live. Die Verarbeitung kennt kein `NOT_FONDSWAEHRUNG` mehr. Zeitpunkt des Flags: Todo im Tracker |
| Veto | Entfällt (Klärung E3); kein `AUSSCHUETTUNG_EXISTS` |
| Nebenläufigkeit | **Eine Datei = eine Transaktion auf `business-new-introduced`** (alle `preis_historie`-Änderungen der Lieferung); der Verarbeitungsmarker am Job folgt in eigener Transaktion, die Auflösung ist idempotent (Abschnitt 4). Schlüssel in **fester Reihenfolge** (keine Deadlocks). **Optimistisch**: eine offene Zeile wird nur geschlossen, wenn sie noch offen ist; höchstens eine offene Zeile je Schlüssel. Konflikt → der Job scheitert als Ganzes → automatischer Retry |
| Wiederholungen | Ein Retry desselben Jobs wertet **nicht neu aus**: ist `eingang_abgeschlossen_am` gesetzt, bleiben Inbox-Zeilen und Marker unangetastet, der Retry erledigt nur die restlichen Nebenwirkungen (Eingangsstufe **write-once**, Abschnitt 5). Neu auswerten heißt Wiederholung. Eine Wiederholung als neuer Job (`repeatedFromJob`) behält beide Zeilensätze; **nur der jüngste Versuch, der seinen Eingang abgeschlossen hat, zählt**. Zeilen verdrängter Jobs werden nicht gefaltet; eine offene Zeile aus einem verdrängten Job fällt auf den letzten nicht verdrängten Zustand zurück (Abschnitt 5) |
| Manuelle Eingriffe | **Keine.** Korrekturen nur über eine neue Lieferung oder eine Wiederholung |
| Inbox | `preismeldung_zeilen` bleibt, **nur angenommene Zeilen**, typisiert, mit Index auf den Schlüssel. `JobWorkloadItem` wird für Fondspreise nicht verwendet. Ungültige Zeilen stehen in der Rückmeldung |
| Aufbewahrung | Produktive Preismeldungs-Jobs werden **nie gelöscht** (wie `AusschuettungsMeldungJob`), damit `(job_id, zeilen_nr)` auflösbar bleibt. Inbox-Zeilen werden nach einem Fenster gelöscht (Todo im Tracker) |
| Fondsbezeichnung | Nicht in `preis_historie`. Entscheidet sich mit `tmp_if_last` (Klärung O) |

---

## 2. Die Tabelle

| Gruppe | Spalten | Anmerkung |
|---|---|---|
| Schlüssel | `isin` (wie geliefert), `preisdatum`, `waehrung`, `meldekategorie` | `meldekategorie` nur `R/E/Z/S/S2/S3`; LMT erreicht die Tabelle nie |
| Inhalt | `wert` (`numeric` **ohne Präzision und Skala**; **`null` = gelöscht**), `num_wfs_ku` | `wert`: `max_nk` ist für `R/E/Z/S/S2/S3` null — jede feste Skala würde still runden; einmal an der Grenze Inbox → Domäne geparst (`new BigDecimal` auf dem vom Eingang gegen `-?\d+(\.\d+)?` geprüften Text), die Faltung parst nichts. `num_wfs_ku` wie zum Stichtag aufgelöst; auch auf D-Zeilen, die spätere `kurs`-Löschung braucht diese Identität |
| Sichtbarkeit | `sicht_von`, `sicht_bis` | DB-Uhr; `sicht_bis` leer = offen |
| Quelle | `job_id`, `zeilen_nr`, `empfangen` | die Zeile, deren Verarbeitung diesen Zustand erzeugt hat — der **Auslöser**, nicht die Herkunft des Werts: bei N/D die angenommene Inbox-Zeile; beim Wegfall durch eine Wiederholung die Zeile des Originals, zitiert unter der Wiederholung (`job_id` = Wiederholung, `zeilen_nr` unverändert; sie steht nicht in der Inbox, sondern als abgelehnt in der Rückmeldung der Wiederholung). Logische Referenz, kein FK (andere DB-Kontexte); Inbox-Zeilen sind write-once (Abschnitt 5). **Eindeutig**: jede Quelle kommt genau einmal vor, Unique-Index (Chunk 3) |

Kein `grund`, keine „beendet durch"-Gruppe: warum eine Zeile endet, sagt die **nächste Zeile**
desselben Schlüssels (mit Wert = neuer Wert, ohne Wert = gelöscht).

**Invarianten** (wie `GjZeitreihe.ensureCorrectlyChained`):

- Die Zeilen eines Schlüssels sind nach `sicht_von` geordnet und **lückenlos**: `sicht_bis` einer
  Zeile = `sicht_von` der nächsten.
- Nur die letzte Zeile ist offen; höchstens eine offene Zeile je Schlüssel (auch in der DB
  erzwungen, Chunk 3).
- Zwei aufeinanderfolgende Zeilen unterscheiden sich im Wert (gleicher Wert erzeugt keine Zeile;
  zwei D-Zeilen hintereinander gibt es nicht).
- Die Quellen sind paarweise verschieden — je Schlüssel im Konstruktor geprüft, DB-weit über den
  Unique-Index `(job_id, zeilen_nr)`.

Beispiel, Schlüssel K = (AT..1, 16.9., EUR, R), mehrere Läufe am 16.9.:

```
wert   sicht_von     sicht_bis     Quelle
101.2  16.9. 08:05   16.9. 10:05   (A, 12)
101.3  16.9. 10:05   16.9. 11:05   (B, 3)
—      16.9. 11:05   16.9. 13:05   (C, 7)    ← das D
101.4  16.9. 13:05                 (D, 40)   ← offen
```

Abfragen, die sich daraus ergeben:

| Frage | Prädikat |
|---|---|
| aktuell sichtbarer Preis | offene Zeile **mit** Wert |
| sichtbar zum Zeitpunkt T | `sicht_von <= T < sicht_bis` (bzw. offen), mit Wert |
| zurückgezogen vs. nie geliefert (Fehlmeldung, Formen §7 Frage 8) | offene D-Zeile vs. keine Zeile |
| letzte Ankunft, die den Zustand **geändert** hat | `empfangen` der offenen Zeile (Wert oder D) |
| letzte Ankunft, die den Schlüssel **berührt** hat (auch ohne Änderung) | nicht aus `preis_historie` — Inbox: `max(empfangen)` der angenommenen Zeilen des Schlüssels aus Jobs mit `eingang_abgeschlossen_am`, nur im Aufbewahrungsfenster |

Jede Preis-Abfrage muss D-Zeilen überspringen — der bewusste Preis der lückenlosen Kette.

Die Historie hält **Zustände**, nicht Ankünfte: eine neuerliche Lieferung desselben Preises hinterlässt
keine Spur in `preis_historie` (Gleicher-Wert-Regel), sondern nur in der Inbox — und nach deren
Aufräumen nur noch im Job und seinem archivierten File. **Zu bestätigen (Fachabteilung, Tracker):** ob es
einen Mehrwert hat, wenn ersichtlich ist, dass derselbe Preis neuerlich geliefert wurde — vermutlich
**nein**: laut Unterlagen soll das tägliche Preisfile in erster Linie den letzten in `kurs`
veröffentlichten Preis liefern, sonst den vorherigen; der Bezieher erhält bei einer identischen
Nachlieferung also denselben Datensatz, ob `preis_historie` dafür eine Zeile hält oder nicht. Falls doch,
ist das dieselbe Frage wie „identische Nachlieferungen im Preisfile" und kippt die Gleicher-Wert-Regel
oder braucht ein Ankunftsmerkmal an der offenen Zeile.

---

## 3. Das Auflösen

### 3.1 Ablauf je Schlüssel

1. Ausgangszustand bestimmen: die letzte Zeile der Kette, deren Job **nicht verdrängt** ist
   (Abschnitt 5) — ohne Wiederholungen die offene Zeile; Wert oder D-Zeile; keine Zeile = gelöscht.
   Ihre Quelle `(empfangen, job_id, zeilen_nr)` ist der **Cursor**.
2. Alle **angenommenen** Inbox-Zeilen des Schlüssels holen — alle Empfangstage im Inbox-Fenster, nur
   vom jüngsten abgeschlossenen Versuch je Lieferung (Abschnitt 5).
3. Entscheidungen anwenden (Abschnitt 3.3); übersprungene Zeilen fallen heraus.
4. In Ankunftsordnung `(empfangen, job_id, zeilen_nr)` sortieren, alles bis einschließlich des Cursors
   verwerfen und den Rest nacheinander auf den Ausgangszustand anwenden: N setzt den Wert, D
   entfernt ihn. Ergebnis: Wert oder „gelöscht“, mit der Quelle der letzten wirksamen Zeile.
5. Endzustand mit der offenen Zeile vergleichen:

| Offene Zeile | Ergebnis | Aktion |
|---|---|---|
| — | Wert | Zeile öffnen |
| — | gelöscht | nichts (D ohne Wirkung) |
| Wert w | Wert = w (numerisch) | nichts |
| Wert w | Wert ≠ w | offene schließen, neue öffnen |
| Wert w | gelöscht | offene schließen, D-Zeile öffnen |
| D-Zeile | Wert | offene schließen, neue öffnen |
| D-Zeile | gelöscht | nichts |

Die frühere Vorbedingung „Quelle nicht älter als die offene Zeile“ steckt im Cursor: eine späte Zeile
eines früheren Empfangstags, deren Quelle vor der Quelle der offenen Zeile liegt, wird gar nicht
gefaltet (Szenario 1). Schon berücksichtigte Zeilen liegen beim nächsten Lauf ebenfalls vor dem
Cursor — die Auflösung ist **idempotent**, ein Lauf ohne neue Zeilen ändert nichts. Gefaltet wird
immer nur die Ankunftsordnung; das Preisdatum ist Teil des Schlüssels, Korrekturen historischer
Stichtage sind deshalb gewöhnliche Zeilen nach dem Cursor.

**Verdrängung** (Abschnitt 5): Zeilen verdrängter Jobs werden nicht gefaltet, und liegt die offene
Zeile selbst in einem verdrängten Job, beginnt die Faltung bei ihrer letzten Vorgängerin aus einem
nicht verdrängten Job — die Kette wird so, als hätte das Original diese Zeile nie gehabt. Gibt es
danach keine wirksame Zeile, trägt die neue Zeile den **Wert** dieser Vorgängerin (Rückfall) — ohne
Vorgängerin ist sie eine D-Zeile — und in beiden Fällen die **Quelle** (Wiederholung, `zeilen_nr` des
Originals): die Zeile, deren Wegfall in der Wiederholung den Zustand erzeugt hat; `num_wfs_ku` von der
geschlossenen Zeile. Die Quelle ist der Auslöser, nicht die Herkunft des Werts — woher der Wert kommt,
zeigt die Kette. So kommt jede Quelle genau einmal vor (Abschnitt 2).

### 3.2 Was nicht gespeichert wird

Zwischenzustände innerhalb einer Auflösung, übersprungene Zeilen, D ohne Wirkung, identische
Nachlieferungen. Alles davon steht in der Inbox (bis zum Aufräumen) bzw. in der Rückmeldung.

### 3.3 Entscheidungen

Ein **Filter je Zeile** (Chunk 2): durchlassen oder überspringen, beim Durchlassen `num_wfs_ku` anhängen.
Aus `PreismeldungSyncDecisions` (Branch) bleibt nur das; die Gruppierung je Datei/Aktion (`PriceGroup`),
`UPSERT`/`DELETE` und die Kennzeichen sind mit E3, dem Wegfall von `letzte_preise` und der Faltung
gegenstandslos. Regeln in dieser Reihenfolge:

| Regel | Ergebnis |
|---|---|
| Kategorie LMT oder Aktion `I` | kein Schlüssel — fällt vor dem Filter weg (`PreisSchluessel` lehnt LMT ab) |
| `findFonds(isin, preisdatum)` leer | überspringen mit `WARN`; sollte nicht vorkommen (der Eingang lehnt unbekannte ISINs ab), Stammdaten können sich aber geändert haben |
| TEST-ISIN | überspringen, auch ein `D`; TEST ist eine dauerhafte Kategorie („TEST Wertpapier"), kein Übergangszustand |
| C-Plan, AIF, Fonds in Liquidation bei Gate „aus" | überspringen, auch ein `D` — wie Legacy (der Schlüssel wird vor jeder Schreib-/Löschaktion verlassen); ein später abgeschaltetes Gate lässt vorhandene Zeilen stehen. Gates stehen per Default auf „speichern" (Legacy `InsPreise*` = 1, `FondspreiseProperties` = `true`) |
| sonst | `InboxZeile(schluessel, aktion, wert, numWfsKu = stammdaten.numWfsKu(), quelle)`; `wert` für `N` aus `new BigDecimal`, für `D` `null` |
| `NOT_FONDSWAEHRUNG` | **entfällt** (Eingang) |
| `AUSSCHUETTUNG_EXISTS` | **entfällt** (E3) |
| Korrektur (`preisdatum` vor dem Verarbeitungstag) | **entfällt** als Kennzeichen — kein Leser mehr; die Kennzahlen-Invalidierung leitet sich aus dem Schließen einer `R`-Zeile ab (Abschnitt 8) |

Übersprungene Zeilen werden nicht gespeichert (3.2), aber mit Grund geloggt; der Grund bleibt ein Enum
(`UNKNOWN_ISIN`, `TEST_ISIN`, `C_PLAN`, `AIF`, `FONDS_IN_LIQUIDATION`), damit ein Zähler am Job später
billig ist.

Warum keine Stammdatenänderung innerhalb des Tages eine Entscheidung kippt: C-Plan/AIF/Liquidation
speichern per Default, die Währung prüft der Eingang (dessen Urteil gilt), TEST ist dauerhaft,
eine ISIN-Umbenennung genau am Tag ist selten. Deshalb braucht es weder einen geplanten Nachlauf
noch eine gespeicherte Entscheidung je Zeile.

**Stammdaten zum Stichtag, pragmatisch:** die bestehende Suche
`PreismeldungStammdatenProvider.findFonds(isin, preisdatum)` löst die ISIN über `wkn_hist` zum
Stichtag auf; INV und `WKN_DESC` liest sie mit dem aktuellen Stand. Solange die Gates auf
„speichern" stehen, hängt keine Entscheidung an historisierten INV-Feldern. `INV_H` und
`wkn_desc_h` (Legacy-Historien, Tagesgranularität) werden erst gelesen, wenn ein Gate abgeschaltet
wird (Abschnitt 8).

---

## 4. Nebenläufigkeit

- **Eine Datei = eine Transaktion auf `business-new-introduced`:** alle `preis_historie`-Änderungen
  einer Lieferung committen gemeinsam oder gar nicht. Der Verarbeitungsmarker (`verarbeitet_am`)
  wird **danach** in eigener `job-system`-Transaktion gesetzt; er ist Anzeige, keine
  Korrektheitsbedingung — bricht es dazwischen ab, findet der Retry nichts mehr zu tun
  (Idempotenz, Abschnitt 3.1) und setzt den Marker. Inbox und Wiederholungskette werden vorher im
  `job-system`-Kontext ohne eigene Transaktion gelesen. Keine kontextübergreifende Transaktion:
  der `SynchronizingTransactionManager` auf master ist bei zwei verschiedenen `db-keys` nur
  Best-effort-1PC (Commit in Enroll-Reihenfolge, `PartialCommitException`); bei gleichem Key
  (Deployment: beide `postgres-server`) wäre sie atomar, gebraucht wird sie nicht.
- **REQUIRES_NEW:** der Work-Queue-Handler läuft bereits in einer Transaktion
  (`WorkQueueExecutor:347` → `:484`); `doTransactional` würfe `Unexpected active transaction`.
  Also `withBusinessNewIntroducedDbContextIsolatedTransactional`, wie heute
  `withJobSystemDbContextIsolatedTransactional` in `PreisMeldungDiffJobExecutionService`.
- **Feste Schlüsselreihenfolge** (ISIN, Preisdatum, Währung, Kategorie) für jeden Schreiber von
  `preis_historie`. Zwei Dateien mit überlappenden Schlüsseln warten dann höchstens aufeinander,
  ein Zyklus kann nicht entstehen.
- **Optimistisch (READ COMMITTED):** schließen nur mit der Bedingung „noch offen", Anzahl prüfen;
  0 → Konflikt. Für einen Schlüssel ohne offene Zeile greift die Eindeutigkeit „höchstens eine
  offene Zeile je Schlüssel" — der zweite Insert scheitert. Muster im Code: `claimItem`
  (`WorkQueueItemRepository:79`).
- **Konflikt → Job scheitert → Retry.** Ein Konflikt zeigt sich je nach DB verschieden — 0 Zeilen aus dem
  bedingten Schließen, Unique-Verletzung beim Insert (Postgres), Sperr-Timeout (H2) — und wird nirgends
  am Ausnahmetyp erkannt; jede Ausnahme in der Transaktion ist ein gescheiterter Versuch. Der Retry löst neu auf (liest Zeilen und offene Zeile neu)
  und kommt immer zum richtigen Ergebnis. Die Support-Mail geht erst nach dem letzten Versuch
  (`WorkQueueExecutor:388-390`); `defaultMaxAttempts` ist 1, die Verarbeitung braucht mehr.

---

## 5. Wiederholungen

- **Retry desselben Jobs** (Work-Queue oder manuell für `FAILED`): die Eingangsstufe ist **write-once**.
  Ablauf: auswerten → Rückmeldung und Result-Bundle bauen → Bundle in den Filestore → **eine**
  `job-system`-Transaktion mit `deleteByJobId` + `saveAll` + `eingang_abgeschlossen_am` + Result-Referenz
  und Zählern. Ist der Marker beim Retry schon gesetzt, werden Auswertung und Inbox **übersprungen**,
  der Retry erledigt nur, was danach noch fehlt (Diff-Job: nichts; produktiver Job: Versand aus dem
  gespeicherten Bundle). `deleteByJobId` läuft nur auf dem Marker-null-Pfad — Zeilen ohne Marker
  stammen aus einem abgebrochenen Lauf und werden ersetzt. Damit kann ein Retry weder den Wert einer
  zitierten Inbox-Zeile ändern noch eine Zeile behalten, die die Rückmeldung ablehnt; die Inbox
  entspricht immer der gespeicherten Rückmeldung. Wer nach einer Stammdatenkorrektur neu auswerten
  will, wiederholt (neuer Job, nächster Punkt).
- **Wiederholung als neuer Job** (`repeatedFromJob`, erbt `empfangen`): beide Zeilensätze bleiben,
  die Jobseite zeigt beide. Beim Auflösen zählen nur Zeilen von Jobs **ohne abgeschlossene
  Wiederholung**; bei Ketten das Ende der Kette. Eine Wiederholung, die im Eingang scheitert,
  verdrängt nichts. Maßgeblich ist `eingang_abgeschlossen_am` (Chunk 3), nicht der Jobstatus.
- Eine Wiederholung löst die Schlüssel des Originals **und** ihre eigenen auf — sonst bleibt ein
  Schlüssel, den nur das Original hatte, unberührt.
- **Quelle entzogen:** liegt die offene Zeile in einem verdrängten Job, ist die Ausgangszeile der
  Faltung ihre letzte Vorgängerin aus einem nicht verdrängten Job (Abschnitt 3.1). Hat der jüngste
  Versuch keine angenommene Zeile mehr für den Schlüssel, fällt der Schlüssel auf den Zustand dieser
  Vorgängerin zurück; gibt es keine, wird eine D-Zeile geöffnet. Quelle ist in beiden Fällen
  (Wiederholung, `zeilen_nr` des Originals) — der Auslöser; die Zeile steht nicht in der Inbox, sondern
  als abgelehnt in der Rückmeldung der Wiederholung. Liefert der jüngste Versuch denselben Wert,
  ändert sich nichts — die offene Zeile behält die Quelle des Originals (Jobs werden nie gelöscht,
  die Referenz bleibt auflösbar). Ein Job ohne Zeile für einen Schlüssel ändert an ihm sonst nichts.

---

## 6. Branch `feat/fondspreise-sync`: was übernommen wird

Der Branch wird **nicht** gemergt. Er dient als Steinbruch; seine Migrationen V067–V069 sind nie
deployt worden und entfallen.

| Artefakt auf dem Branch | Verwendung |
|---|---|
| `PreismeldungSyncDecisions`, `SyncSkipReason`, `PreismeldungSyncOptions` + Test | Chunk 2, auf einen Filter je Zeile reduziert und **umbenannt** — ohne „Sync", das Wort steht für das verworfene Design (Abschnitt 3.3); der Test als Steinbruch für Fixtures |
| `FondspreiseProperties` (`store*`-Gates) | Chunk 2, nur die drei Gates; `fallbackPriceMaxAgeDays` und `endedFundRetentionDays` gehen mit `letzte_preise` |
| `angekommen_am` an `preis_meldung_diff_jobs` (`V068__preis_meldung_diff_jobs__sync.sql`: DB-Default bei Einreichung, Wiederholung erbt) | Chunk 3, als `empfangen` |
| `PriceGroup`, `groupInboxLines` | **entfallen** — gefaltet wird je Schlüssel, eine Gruppierung je Datei und Aktion gibt es nicht mehr (E3) |
| `Kurs`, `KursRepository`, `TmpIfLast` + Repository, `V069__tmp_if_last.sql` | Entities/Repositories **übernommen 2026-09-29**, DDL als `V073__kurs_tmp_if_last.sql`; die Ableitung `kurs`/`tmp_if_last` selbst bleibt später |
| `preis_herkunft`, `letzte_preise`, `PreismeldungSyncService`, `LetztePreiseService`, Klammer-Transaktionen, Rebuild | **entfallen** — die offene Zeile ersetzt beide Guards |
| `PreismeldungDbDiff` | später, mit dem generischen Tabellenvergleich (Tracker, Plan D13) |

---

## 7. Chunks

Reihenfolge = Abhängigkeit. Chunks 1 und 2 sind reine Domäne ohne DDL; alle DDL des Features steht
nach der Regel „ein Flyway-File je Feature" in **einer** Migration in Chunk 3.

### Chunk 1 — Domäne: `PreisZeitreihe` und Auflösung (ohne Entscheidungen)

- **Ziel:** die Logik aus Abschnitt 3.1/3.2 als reine Domäne, ohne DB, ohne Stammdaten.
- **Inhalt** (`ifas-domain-fondspreise`):
  - `PreisZeitreihe`: unveränderlicher Record der Zeilen eines Schlüssels, Konstruktor prüft die
    Invarianten aus Abschnitt 2 (nach dem Muster `GjZeitreihe`).
  - ein Calculator nach dem Muster `GeschaeftsjahreCalculator`: bekommt die bestehende
    `PreisZeitreihe` und die angenommenen Zeilen des Schlüssels (alle Empfangstage), liefert die neue
    `PreisZeitreihe` plus die Änderung (welche Zeile schließen, welche öffnen). Arbeitstitel
    `PreismeldungZeitreiheCalculator`.
  - Wertvergleich über `BigDecimals.equalsIgnoreScale` (core-support): `101.20` = `101.2`, `null` = `null`;
    `wert` ist in Domäne und Entity ein `@Nullable BigDecimal`, geparst einmal beim Bau der Inbox-Zeile
    für die Faltung (Parsefehler = verletzte Invariante, Ausnahme mit `(job_id, zeilen_nr)`).
  - Verdrängung als Eingabe: die Menge der verdrängten Jobs (Original → jüngste Wiederholung mit
    abgeschlossenem Eingang) bestimmt Ausgangszeile und Filter (Abschnitt 3.1). Die Regel steht
    damit vollständig in der Domäne; Chunk 5 verdrahtet sie nur.
- **Tests** (Given-When-Then, AssertJ): die Tabelle aus 3.1 Zeile für Zeile; das Beispiel aus
  Abschnitt 2; gleicher Wert; D ohne Wirkung; D auf D; späte Zeile älter als die offene Zeile
  (Szenario 1); späte N-Zeile eines früheren Tags nach schon verarbeitetem D (Szenario 2, keine
  Änderung); Idempotenz (zweite Auflösung derselben Zeilen ändert nichts); Zeilen verdrängter Jobs werden
  ignoriert; offene Zeile aus verdrängtem Job — Wiederholung mit anderem Wert (neue Zeile, Quelle
  Wiederholung), ohne Zeile mit Vorgängerin (Rückfall auf deren Wert), ohne Zeile ohne Vorgängerin (D-Zeile) —
  beide mit Quelle (Wiederholung, `zeilen_nr` des Originals), mit gleichem Wert (keine Änderung);
  Invariantenbruch im Konstruktor, auch bei doppelter Quelle.
- **Fertig, wenn:** alle Fälle aus der Diskussion als Tests grün sind.

### Chunk 2 — Domäne: der Filter je Zeile

- **Ziel:** welche angenommene Inbox-Zeile in die Faltung eingeht, und mit welchem `num_wfs_ku`.
- **Eingabe:** eine Inbox-Zeile als `PreismeldungZeileDaten` (existiert; es ist der Datensatz der
  Inbox-Zeile, `lineNumber` = `zeilen_nr`) plus `jobId` und `empfangen`. Der Service mappt Entity →
  Record, das Gegenstück zu `toEntities` in `PreisMeldungDiffJobExecutionService`. Kein neuer Eingabetyp.
- **Inhalt** (`ifas-domain-fondspreise`, Package `historie`): `InboxZeilenFilter` (Utility,
  `static Optional<InboxZeile> accept(PreismeldungZeileDaten, Quelle, PreismeldungStammdatenProvider,
  Gates)`) mit den Regeln aus Abschnitt 3.3 in dieser Reihenfolge; `UebersprungGrund` als Enum;
  die Gates als kleiner Record aus `FondspreiseProperties` (nur noch die drei `store*`-Booleans).
  Vom Branch übernommen wird die Logik von `PreismeldungSyncDecisions.excludedBy` und der Test als
  Steinbruch — ohne `PriceGroup`, `SyncDecision`, `marksKorrektur`, `advancesLetzterPreis` (Abschnitt 3.3).
- **Wiederverwendung prüfen:** `PreismeldungStammdatenService` cacht `findFonds` **nur nach ISIN**
  (`computeIfAbsent(isin, …)`) — der erste Stichtag gewinnt. Für Zeilen mit verschiedenen
  Preisdaten derselben ISIN muss der Cache-Schlüssel den Stichtag enthalten (klein, eigener Test:
  dieselbe ISIN mit zwei Preisdaten, an denen `wkn_hist` verschiedene `num_wfs_ku` liefert).
- **Tests:** je Regel einer, jeweils mit `N` und `D`; drei Gates an/aus; unbekannte ISIN → übersprungen;
  `numWfsKu` zum Preisdatum; `wert` für `N` geparst, für `D` `null`.
- **Fertig, wenn:** der Calculator aus Chunk 1 nur `InboxZeile`n bekommt, die dieser Filter
  durchgelassen hat, und Abschnitt 3.3 nur noch diese Tabelle enthält.

### Chunk 3 — Persistenz: eine Migration, Entities, Repositories

- **Ziel:** alles, was in die DB muss, in einer Migration.
- **Migration** (neue Nummer nach `flyway-versions-after-merge.md` bestimmen; `sybase16/` bekommt
  dieselbe Nummer als No-op mit Kommentar, wie `V061`/`V063`):
  - `preis_historie` (Abschnitt 2) im Kontext `business-new-introduced`; `wert numeric null` ohne
    Präzision/Skala (B4) — nicht die STM-Konvention `numeric(23, 8)`, die still runden würde.
  - „höchstens eine offene Zeile je Schlüssel": H2 kennt **keine partiellen Indizes**
    (`V035__jobs_daily_run_number.sql`). Umsetzbar über eine Markierungsspalte, die nur bei
    offenen Zeilen gesetzt ist, und einen Unique-Index auf Schlüssel + Markierung — NULL-Werte sind
    in Unique-Indizes auf Postgres und H2 verschieden (dasselbe Argument wie V035).
  - Unique-Index auf `preis_historie (job_id, zeilen_nr)`: jede Quelle genau einmal (Abschnitt 2).
  - Index auf `preismeldung_zeilen (isin, preisdatum)` für „Zeilen eines Schlüssels".
  - **Drei Zeitstempel am Job** (`preis_meldung_diff_jobs`, `timestamp(6) with time zone`). Ablage wie
    bei der Ausschüttung: jeder Jobtyp führt seine Spalten selbst (produktiver und Diff-Job
    duplizieren sie), keine Superklasse, keine Basisspalte in `jobs`, nichts am Work-Queue-Item (wird
    nach 30 Tagen gelöscht). Die Namen sind nicht selbsterklärend, deshalb gehören diese
    Beschreibungen als Javadoc an die Entity-Felder (englisch; Wortlaut im Review, B6):
    - `empfangen` (not null) — **Ankunft der Lieferung bei IFAS nach der DB-Uhr des Job-Kontexts.**
      Die Ordnungsgröße der Faltung: Zeilen desselben Preisschlüssels werden nach
      `(empfangen, job_id, zeilen_nr)` gefaltet. Gesetzt bei der Einreichung über `currentDbTime()`;
      eine Wiederholung **erbt den Wert des Originals** (sie ist keine neue Ankunft). Ist weder
      `created_at` (App-Uhr, je Job neu) noch der Verarbeitungszeitpunkt. Bestand: aus
      `jobs.created_at`.
    - `eingang_abgeschlossen_am` (null) — **Der Eingang dieses Jobs ist bis zum Ende gelaufen; die
      angenommenen Zeilen — möglicherweise keine — stehen endgültig in `preismeldung_zeilen`.**
      Gesetzt in derselben Transaktion wie `deleteByJobId` + `saveAll`
      (`PreisMeldungDiffJobExecutionService:112`), also „gesetzt ⇒ Inbox-Inhalt dieses Jobs ist
      final". Nur Jobs mit Wert gehen in die Faltung ein, und nur eine Wiederholung mit Wert
      verdrängt ihr Original — auch mit null Zeilen. `null` = Eingang läuft noch oder ist
      gescheitert. Bestand: `jobs.finished_at` für `COMPLETED`.
    - `verarbeitet_am` (null) — **Stufe 2 dieses Jobs ist gelaufen: die Faltung ging über alle
      Schlüssel dieser Lieferung, `preis_historie` spiegelt den Stand zu diesem Zeitpunkt.** Heißt
      **nicht**, dass Zeilen dieses Jobs in `preis_historie` stehen (eine Lieferung ändert oft nichts:
      gleicher Wert, D ohne Wirkung, Zeilen vor dem Cursor), und umgekehrt kann eine Zeile dieses
      Jobs schon vorher Quelle geworden sein (die Verarbeitung eines anderen Jobs faltet alle Zeilen
      des Schlüssels). Gesetzt nach dem Commit der `preis_historie`-Transaktion in eigener
      Transaktion (Abschnitt 4); Anzeige und „schon verarbeitet"-Hinweis, keine
      Korrektheitsbedingung. Bestand: null.
    - Zusammen gelesen: `FAILED` + `eingang_abgeschlossen_am is null` = im Eingang gescheitert,
      verdrängt nichts; `FAILED` + gesetzt = in Stufe 2 gescheitert, Inbox zählt, Retry faltet neu.
  - **Helfer** `DatabaseContextHelper.currentDbTime()` neben `getCurrentDbUser()` (dasselbe
    Routing-`JdbcTemplate`; `select current_timestamp`; gilt für die Postgres/H2-Kontexte, nicht für
    Sybase). Aufrufer in diesem Chunk: `PreisMeldungDiffJobSubmissionService.submit` (→ `empfangen`;
    der Wiederholungspfad kopiert stattdessen `original.getEmpfangen()`) und
    `PreisMeldungDiffJobExecutionService` (→ `eingang_abgeschlossen_am` in der Inbox-Transaktion).
  - **Eingangsstufe write-once** (Abschnitt 5): `PreisMeldungDiffJobExecutionService.executeDiff` umbauen —
    heute Inbox-Transaktion, dann Filestore, dann `updateResult`; neu: auswerten → Bundle bauen und
    speichern → eine Transaktion (Zeilen, Marker, Result-Referenz, Zähler). Vor der Auswertung den
    Marker prüfen und bei gesetztem Marker alles überspringen. Ein vom Filestore gespeichertes Bundle
    einer gescheiterten Transaktion ist harmloser Müll (DB-Filestore auf demselben `postgres-server`).
  - Zeitstempel als `timestamp(6) with time zone` (H2 kennt kein `timestamptz`).
- **Entities/Repositories** in `ifas-persistence-fondspreise`: `PreisHistorie`, Abfragen „offene
  Zeile je Schlüssel", „Zeitreihe je Schlüssel", bedingtes Schließen mit Rückgabe der Anzahl;
  Inbox-Abfrage „angenommene Zeilen eines Schlüssels über alle Empfangstage, nur jüngster
  abgeschlossener Versuch".
- **Tests** (Multi-DB): Eindeutigkeit der offenen Zeile greift auf H2, Postgres, (Sybase entfällt);
  bedingtes Schließen liefert 0 bei schon geschlossener Zeile; Inbox-Abfrage schließt
  wiederholte Jobs aus; ein `wert` mit 12 Nachkommastellen kommt auf H2 und Postgres unverändert
  zurück (schützt vor einem späteren Umbau auf `numeric(p, s)`). `PreisMeldungDiffJobTest`: ein zweiter
  Lauf desselben Jobs mit gesetztem Marker lässt Inbox und Marker unverändert, auch wenn die Stammdaten
  inzwischen anders entscheiden würden; ohne Marker ersetzt er vorhandene Zeilen.
- **Vorher:** Flyway-Modul installieren, sonst testet man das alte Jar
  (`mvn -Pno-proxy install -pl ifas-database/ifas-database-flyway`).
- **Entschieden (24.09.):** Spaltenname `empfangen` — am Job und in `preis_historie`; nicht `angekommen_am`
  wie auf dem Branch.

### Chunk 4 — Service: Verarbeitung einer Lieferung

- **Ziel:** eine Lieferung (ein Job) vollständig verarbeiten.
- **Inhalt:** ein Service, der für einen Job die Schlüssel seiner Zeilen bestimmt, sie in fester
  Reihenfolge durchgeht, je Schlüssel Inbox-Zeilen und Zeitreihe lädt, Chunk 2 und Chunk 1 anwendet
  und die Änderungen in **einer Transaktion auf `business-new-introduced`** schreibt (REQUIRES_NEW,
  Abschnitt 4; `sicht_von` = `currentDbTime()` als erste Anweisung dieser Transaktion, ein Wert für alle
  Zeilen der Datei); `verarbeitet_am` setzt er danach in eigener `job-system`-Transaktion. Konflikt → Ausnahme.
- **Tests** (Integration, Multi-DB): Lieferung → Zeilen in `preis_historie`; zweite Lieferung mit
  neuem Wert, mit gleichem Wert, mit D; späte Lieferung eines früheren Empfangstags (Szenario 1) und nach schon verarbeitetem D
  (Szenario 2); zwei
  Lieferungen desselben Schlüssels **nebenläufig** → danach genau eine offene Zeile mit einem der beiden
  Werte, die Kette intakt, der Verlierer hat *irgendeine* Ausnahme geworfen — den Typ nicht prüfen:
  Postgres liefert 0 Zeilen aus dem bedingten Schließen oder eine Unique-Verletzung beim Insert,
  H2/MVStore wirft nach `LOCK_TIMEOUT` eine Sperr-Ausnahme; alle drei enden im Retry;
  Wiederholung der Verarbeitung ohne neue Zeilen → keine Änderung; Abbruch zwischen Zeilen und
  Marker → der Retry schreibt keine Zeile mehr und setzt den Marker.
- **Fertig, wenn:** die Szenarien aus der Diskussion als Integrationstests grün sind.

### Chunk 5 — Wiederholungen

- **Ziel:** Abschnitt 5 vollständig.
- **Inhalt:** Verdrängung bestimmen (Wiederholungskette rückwärts über `repeatedFromJob`, vorwärts
  über `findByRepeatedFromJobOrderByCreatedAtAsc`; nur Wiederholungen mit abgeschlossenem Eingang
  zählen), Schlüssel der verdrängten Originale mitnehmen, beides dem Calculator übergeben. Die
  Faltungsregel selbst ist in Chunk 1 getestet.
- **Tests:** Wiederholung mit gleichem Ergebnis (keine Änderung); mit geändertem Wert (neue
  Zeile); mit jetzt abgelehnter Zeile (Rückfall auf die Vorgängerin bzw. D-Zeile mit Quelle der
  Wiederholung); gescheiterte
  Wiederholung verdrängt nichts.

### Chunk 6 — Verdrahtung als Job-Stufe mit Retry

- **Ziel:** die Verarbeitung läuft nach jedem Eingang automatisch und wiederholt sich bei Konflikt.
- **Inhalt:** eigener Work-Queue-Schritt nach dem Eingang, damit ein Retry den Eingang (und die
  Rückmeldung) nicht wiederholt; `maxAttempts` > 1.
- **Offen, vor dem Start zu entscheiden — wo läuft sie zuerst?**
  - als Stufe des `PreisMeldungDiffJob` (Parallelbetrieb): echte Daten früh, Vergleich gegen
    Legacy-`kurs` möglich. Aber Diff-Jobs sind Testläufe: sie werden gelöscht
    (`deleteArchivedBatch` nimmt ihre Zeilen mit, Referenzen laufen ins Leere), beliebig wiederholt,
    und ihr `empfangen` ist der Einreichungszeitpunkt, nicht die Legacy-Ankunft.
  - erst mit dem produktiven Preismeldungs-Job (Tracker: „Produktiver Preismeldungs-Job,
    Phase 2"): sauberes `empfangen` und nie gelöschte Jobs, aber später verfügbar.
- **Tests:** Konflikt → Retry → Erfolg ohne Support-Mail; nach dem letzten Versuch Mail.

### Chunk 7 — UI: Zeitreihen-Ansicht

- **Ziel:** Support sieht die Zeitreihe eines Schlüssels.
- **Inhalt:** Seite je ISIN und Stichtag mit allen Zeilen (Wert/gelöscht, `sicht_von`/`sicht_bis`,
  Quelle mit Link auf Job und Zeile; eine Quelle ohne Inbox-Zeile — Wegfall in einer Wiederholung — wird
  als „Zeile n der Wiederholung, abgelehnt: Rückfall" gezeigt); Einstieg von der Job-Detailseite
  (Schlüssel der Lieferung).
  Grenzen der Web-UI beachten (kein npm/CDN, nur `~{::section}`).
- Kann direkt nach Chunk 4 kommen, um echte Läufe anzusehen.

---

## 8. Später — nicht in diesem Plan

| Thema | Stand |
|---|---|
| Ableitung nach `kurs` | aus offenen Zeilen mit Wert; **optimistisch auf den Wert** („schreibe nur, wenn `kurs` noch den gelesenen Wert hat"), `ignore_dup_key` beim Insert beachten, Bedingung nur auf `num_kurs`; Retry leitet per Vergleich ab. Optional Abgleich vor jedem Lauf |
| Ableitung nach `tmp_if_last` | Abfrage über offene Zeilen; Fondsbezeichnung aus Inbox oder Stammdaten, je nach Klärung O |
| Sammelreport (Schnitt 4/5) | liest `preis_historie`, nicht die Inbox: sichtbar im Snapshot bei Start minus Publikationsprotokoll; Lauf 1 plus Fallback, Lauf 2 plus `I3`. Stichzeitpunkt misst die Verarbeitung. Zwischenstände zwischen zwei Läufen werden nicht verschickt |
| Fehlmeldung (Schnitt 7) | Anti-Join auf offene Zeilen mit Wert; offene D-Zeile = zurückgezogen |
| Kennzahlen-Invalidierung | ausgelöst durch das Schließen einer `R`-Zeile |
| Stammdaten aus `INV_H`/`wkn_desc_h` zum Stichtag | erst, wenn ein Gate (C-Plan/AIF/Liquidation) abgeschaltet wird; `wkn_desc_h` ist in IFAS13 noch nicht gemappt |
| Aufräumen der Inbox-Zeilen | Todo im Tracker (Fenster als Property) |
| Währungsflag im Neusystem: Parallelbetrieb oder Umstellungstag | Todo im Tracker (erst messen). Bis das Flag an ist, erreichen Fremdwährungspreise `preis_historie`; relevant erst mit der `kurs`-Ableitung |
| Identische Nachlieferungen im Preisfile | Todo im Tracker (Differenzen auswerten) |
| Javadoc `PreismeldungZeile` („kept as text to preserve the delivered precision for the Sammelreport“) | Begründung ist falsch — Legacy formatiert das Preisfile aus `float`; beim nächsten Anfassen der Inbox korrigieren |

---

## Quellen

| Aussage | Fundstelle |
|---|---|
| Zeitreihen-Muster | `ifas-domain-stm/.../geschaeftsjahr/GjZeitreihe.java` (`ensureCorrectlyChained`), `GeschaeftsjahreCalculator.java` (Provider/Persister als Funktionen) |
| Stammdaten-Suche zum Preisdatum | `PreismeldungLineValidations:115`, `PreismeldungStammdatenService:50-51` (Cache nach ISIN) |
| Retry ersetzt Inbox-Zeilen | `PreisMeldungDiffJobExecutionService:112` |
| Mail erst nach letztem Versuch, Default 1 Versuch, Backoff | `WorkQueueExecutor:388-390`, `WorkQueueProperties` (`defaultMaxAttempts`, `retryBaseDelayMs`, `retryMaxDelayMs`) |
| Bedingtes Update als Muster | `WorkQueueItemRepository:79` (`claimItem`) |
| Keine partiellen Indizes in H2 | `V035__jobs_daily_run_number.sql:16-25` |
| Ein Postgres für Job-System und neue Business-Tabellen | `application-server-deployment.properties:24`, `:43` |
| Kontextübergreifende Transaktion = Best-effort-1PC, Commit in Enroll-Reihenfolge | `SynchronizingTransactionManager`, `SynchronizedTransaction` (multidbctx-support) |
| Work-Queue-Handler läuft in einer Transaktion | `WorkQueueExecutor:347` (`doTransactional`) → `:484` (`handler.execute`) |
| Produktive Ausschüttungs-Jobs werden nie gelöscht | kein `deleteArchivedBatch` für `AusschuettungsMeldungJob`; Archivieren ist nur ein Flag (`JobQueryService.setArchived`) |
| Archiv-Journal kennt Lieferant, Datei, `doc_id`, nicht den Job | `Archivierung.java` (`kurs.archivierung`) |
| TEST = dauerhafte Kategorie | Legacy `VWKN/tabledefs/ins_wp_art_f.cr:41-42`, Filter z. B. `m_fplausi.cpp:2596` |
| Gates speichern per Default | Legacy `calculation.cpp:196-204` (`InsPreise*` default 1); Branch `FondspreiseProperties` |
| INV- und WKN_DESC-Historien | Legacy `Ifas/tabledef/INV_H.cr`, `T_INV.cr` (nur letzte Änderung des Tages); `VWKN/tabledefs/wkn_desc_h_2.cr` |
| Bekannte Abweichungen im Rückmeldungs-Diff | `PreisMeldungDiffSetting` (`ignoreInfoDelMessages`) |
| `max_nk` ist für `R/E/Z/S/S2/S3` null (keine Nachkommagrenze), nur LMT hat 8 | `standard_TAX_CODE_data.yaml` (GAST-Export 2026-09-03) |
| Legacy hält Preise als `float`; Preisfiles entstehen aus `tmp_if_kurs`/`tmp_if_last` | `Kurs/tabledefs/kurs.cr:48`, `tmp_i_last.cr` (Branch `V069`: `num_kurs double precision`), `M_FP_DLD.CPP:127-128` |
| H2 `numeric` ohne Skala hält alle Stellen und streicht Nachnullen; `numeric(p,s)` rundet still | Probe H2 2.3.232 `MODE=PostgreSQL`, 2026-09-24 |
| Eingang prüft den Wert gegen `-?\d+(\.\d+)?` | `PreismeldungLineValidations:39`, `:184` |
| Jobtypen führen ihre Spalten selbst; produktiver und Diff-Job der Ausschüttung duplizieren sie, ein Jobtyp mit Modus statt zweier Tabellen | `AusschuettungsMeldungJob` / `AusschuettungsMeldungDiffJob` (`input_filename`, `liefer_id`, `result_bundle_file_ref`, `notes`); `AusschuettungsMeldungJob.source_type` |
| Routing-`JdbcTemplate` im Kontext-Helfer, Vorlage für `currentDbTime()` | `DatabaseContextHelper:82` (`getCurrentDbUser`) |
| Eingangsstufe schreibt heute Inbox-Transaktion → Filestore → `updateResult` | `PreisMeldungDiffJobExecutionService:112-140` |
| Manueller Retry eines `FAILED`-Jobs möglich; Handler-Default ein Versuch | `PreisMeldungDiffJobStatus.isProcessable()`, `AbstractJobWorkQueueHandler:91` |
| Filestore liegt in der DB auf `postgres-server` | `application-server-deployment.properties:28` |
