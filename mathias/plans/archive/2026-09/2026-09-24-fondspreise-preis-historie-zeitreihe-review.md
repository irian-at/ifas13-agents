# Review: `preis_historie`-Plan vom 24.09. + Implementierungsdetails der Zeitreihen-Logik

Stand 2026-09-24. Review des Plans
[2026-09-24-fondspreise-preis-historie-zeitreihe.md](2026-09-24-fondspreise-preis-historie-zeitreihe.md)
gegen den Code auf `master` (`02a839537`) und den Branch `feat/fondspreise-sync`. Abschnitt 1 sind
die Befunde, Abschnitt 2 die konkrete Spezifikation von Chunk 1 (Domäne), Abschnitt 3 der
Service-Ablauf, der die Domäne füttert, Abschnitt 4 die Persistenz-Skizze, Abschnitt 5 die
Textänderungen am Plan als Checkliste, Abschnitt 6 (25.09.) das Tabellendesign beider Tabellen mit
Beispiel als Grundlage für die Diskussion am 28.09.

**Status 2026-09-24:** B1–B7 angenommen und in den Plan eingearbeitet (B4 und B7 in revidierter Fassung; B5/B6 mit Feldbeschreibungen; B7 am 25.09. um die eindeutige Quelle ergänzt; B8, B9 und B10 am 25.09.); B11–B14 offen.

**Gesamturteil:** Form, Tabelle, Invarianten und Chunk-Schnitt tragen. Zwei Stellen sollten vor
Chunk 1 geändert werden, weil sie die Domänenlogik bestimmen: die Auflösungsregel (B1 — einfacher
und ohne den Support-Fall aus Szenario 2) und die Regel „Quelle entzogen" (B2 — fällt aus B1
heraus). Eine Stelle ist technisch falsch begründet (B3 — Transaktion über zwei DB-Kontexte),
schadet aber nicht, wenn man die Atomarität gar nicht braucht. Der Rest sind Präzisierungen.

---

## 1. Befunde

Schwere: **B** = ändert das Design, **W** = wichtig, muss in den Plan, **K** = klein.

### B1 (B) — Auflösen „je Kalender-Empfangstag + Vorbedingung" → „Fold ab der offenen Zeile"

Der Plan löst je Schlüssel **und Kalender-Empfangstag** auf und prüft dann als Vorbedingung, dass
das Ergebnis nicht älter ist als die offene Zeile. Beide Teile lassen sich zu einer Regel
zusammenziehen, die in jedem Szenario der Diskussion dasselbe Ergebnis liefert und in einem
(Szenario 2) ein besseres:

> **Ausgangszustand** = Zustand der offenen Zeile (Wert oder gelöscht; keine Zeile = gelöscht).
> **Zu falten** = alle angenommenen Zeilen des Schlüssels, deren Quelle in der Ankunftsordnung
> `(empfangen, job_id, zeilen_nr)` **nach** der Quelle der offenen Zeile liegt.
> Falten in dieser Ordnung: N setzt, D löscht. **Endzustand ≠ Ausgangszustand** → eine Änderung
> (schließen + öffnen bzw. nur öffnen), Quelle = letzte wirksame Zeile. Sonst nichts.

Was das ändert:

| Szenario | Plan (je Tag + Vorbedingung) | Fold ab offener Zeile |
|---|---|---|
| Beispiel Abschnitt 2 (4 Läufe am 16.9.) | 4 Zeilen | identisch |
| Gleicher Wert, N auf N | nichts | nichts |
| N und D am selben Tag | löschen sich auf | identisch (dieselbe Faltung) |
| Szenario 1: späte Zeile eines früheren Tags, offene Zeile jünger | Vorbedingung → nichts | Zeile liegt vor dem Cursor → nichts |
| D ohne offene Zeile | nichts | nichts |
| **Szenario 2**: D (Tag 2) verarbeitet, dann späte N-Lieferung von Tag 1 | öffnet die N-Zeile, D ist verloren → **Support-Fall**, Wiederholung des D-Jobs | Faltung ab „keine Zeile": N (Tag 1), D (Tag 2) → gelöscht = Ausgangszustand → **nichts**; kein Support-Fall |
| Reprocessing ohne neue Zeilen | nichts | nichts (Zeilen vor dem Cursor) |

Weitere Vorteile: keine Tagesgrenze (kein Europe/Vienna-Fenster in SQL, kein Problem mit D um
23:59 und N um 00:01), die Vorbedingung aus 3.1 entfällt als eigener Satz, und „D ohne Wirkung
über Tage" (Entscheidungstabelle) ist kein Sonderfall mehr. Kosten: keine — die Abfrage lädt
statt „Zeilen des Tages" alle Zeilen des Schlüssels aus dem Inbox-Fenster (je Schlüssel eine
Handvoll) und filtert im Speicher am Cursor.

Der einzige Informationsverlust: Szenario 2 endet mit *keiner* Zeile statt mit einer D-Zeile
(Fehlmeldung sagt „nie geliefert" statt „zurückgezogen"). Für einen Preis, den IFAS nie gezeigt hat,
ist das die richtige Aussage.

### B2 (B) — „Quelle entzogen": Rückfall statt pauschaler D-Zeile

Abschnitt 5 sagt: Original hat die offene Zeile geöffnet, die Wiederholung hat für den Schlüssel
keine angenommene Zeile mehr → D-Zeile mit Quelle der Wiederholung. Das ist zu grob: hatte ein
älterer, nicht verdrängter Job Z vor dem Original einen Wert geliefert, wäre „so, als hätte das
Original diese Zeile nie gehabt" = Z's Wert, nicht „gelöscht". Mit B1 fällt die richtige Regel
heraus, ohne Sonderfall:

> **Ausgangszustand** = Zustand der **letzten Zeile der Kette, deren Job nicht verdrängt ist**
> (die verdrängten Jobs sind die, zu denen eine Wiederholung mit abgeschlossenem Eingang
> existiert). Cursor = deren Quelle. Zeilen verdrängter Jobs werden nicht gefaltet.
> Vergleich weiterhin gegen die **offene** Zeile.

Fälle: Kette `Z(100) → O(101.2, offen)`, O verdrängt durch O' ohne Zeile für den Schlüssel:
Ausgang = Z (100), Faltung über nichts → 100 ≠ 101.2 → O-Zeile schließen, neue Zeile 100 mit
Quelle Z. Kette nur `O(101.2, offen)`: Ausgang = „keine Zeile" → gelöscht ≠ 101.2 → D-Zeile; **hier**
greift die Quelle aus dem Plan (Wiederholungs-Job, `zeilen_nr` des Originals), `num_wfs_ku` von
der geschlossenen Zeile. Kette `Z → O → B(offen)`, O verdrängt: Ausgang = B, nichts zu falten → nichts
(B ist ohnehin die jüngste Anweisung). O' liefert denselben Wert wie O → Endzustand = offen →
nichts; die offene Zeile behält die Quelle O — das ist in Ordnung, Jobs werden nie gelöscht.

### B3 (W) — „Eine Datei = eine Transaktion" über zwei DB-Kontexte: so nicht nötig

Auf `master` liegt `SynchronizingTransactionManager` (multidbctx-support): eine logische
Transaktion enrollt Datenbanken **lazy per `db-key`** und committet sie **in Enroll-Reihenfolge**
(`SynchronizedTransaction`, `LinkedHashMap`) als **Best-effort-1PC** mit `PartialCommitException`.
Folglich:

- `job-system` = `business-new-introduced` = `postgres-server` (Deployment, `:24`/`:43`) → **ein**
  enrolltes DB → wirklich atomar. Integrationstests: alles `h2-test` → ebenfalls. Lokal mit
  `h2-infra-db` + Postgres oder im `multidbctx`-Testmodul → zwei DBs → Best-effort.
- Der Work-Queue-Handler läuft **innerhalb** einer Transaktion (`WorkQueueExecutor:347` →
  `:484 handler.execute`); `doTransactional` wirft dann `Unexpected active transaction`. Chunk 4
  braucht `…IsolatedTransactional` (REQUIRES_NEW), wie heute
  `withJobSystemDbContextIsolatedTransactional` in `PreisMeldungDiffJobExecutionService`.

**Empfehlung:** die kontextübergreifende Atomarität gar nicht beanspruchen. Die Faltung (B1) ist
**idempotent** — ein zweiter Lauf über dieselben Zeilen ändert nichts. Also:

1. Lesen (Inbox, Job, Wiederholungskette) im `job-system`-Kontext, ohne eigene Transaktion.
2. **Eine** Transaktion auf `business-new-introduced`: alle Zeitreihen der Datei lesen, alle
   Änderungen schreiben. Das ist das „eine Datei = eine Transaktion", das zählt.
3. Danach, eigene Transaktion `job-system`: `verarbeitet_am` setzen.

Bricht es zwischen 2 und 3 → Retry → Faltung findet nichts zu tun → Marker gesetzt. Der Marker ist
Anzeige, keine Korrektheitsbedingung. Der Satz „Konfigurationsentscheidung, keine Garantie" kann
damit raus.

### B4 (W) — `wert` als `numeric` ohne Skala (revidiert 24.09.)

**Ursprüngliche Fassung („`wert` als Text“) zurückgezogen.** Sie stützte sich auf zwei Behauptungen,
die nicht halten:

1. „H2 `NUMERIC` ohne Skala hat Skala 0“ — **falsch**. Probe auf H2 2.3.232 (`MODE=PostgreSQL`):
   `numeric` ohne Angabe hält `0.123456789012` exakt und streicht nur Nachnullen (`'101.20'` →
   `101.2`); Postgres behält `101.20`. `numeric(30,10)` dagegen rundet auf **beiden** DBs still
   (`0.123456789012` → `0.1234567890`).
2. „Der Sammelreport braucht den gelieferten Text“ — **unbelegt**. Legacy hält jeden Preis als
   `float` (`kurs.num_kurs`, `tmp_if_last.num_kurs`) und erzeugt die Preisfiles aus
   `tmp_if_kurs`/`tmp_if_last` (`M_FP_DLD.CPP:127-128`); es kann den gelieferten Text also gar
   nicht wiedergeben. Der Javadoc-Satz an `PreismeldungZeile` („kept as text to preserve the
   delivered precision for the Sammelreport“) ist eine ungeprüfte Behauptung aus Schnitt 1.

**Entscheidung: einmal parsen, an der Grenze Inbox → Domäne.** Der Eingang hat den String gegen
`-?\d+(\.\d+)?` geprüft (`PreismeldungLineValidations:184`), `new BigDecimal(s)` ist darauf total
und deterministisch. `InboxZeile.wert` ist ein `BigDecimal` (D-Zeilen: `null`), `preis_historie.wert`
speichert die Zahl, die Faltung parst nichts mehr. Ein Parsefehler an dieser Grenze ist eine
verletzte Invariante (Inbox nicht über den Eingang befüllt) und lässt den Job mit `(job_id,
zeilen_nr)` in der Meldung scheitern.

**Die eine Bedingung: keine feste Skala.** `max_nk` ist im GAST-Export
(`standard_TAX_CODE_data.yaml`, 2026-09-03) für `R/E/Z/S/S2/S3` **null** — nur die nie gespeicherten
LMT-Codes haben 8. Der Eingang nimmt also beliebig viele Nachkommastellen an; eine Spalte nach der
STM-Konvention `numeric(23, 8)` würde eine 12-stellige Lieferung auf beiden DBs still runden.
Deshalb `wert numeric null` **ohne** Präzision und Skala; `null` = gelöscht (nicht `0`, nicht `''`).

**Vergleich** bleibt `BigDecimals.equalsIgnoreScale` (`compareTo`): Postgres liefert `101.20`, H2
`101.2` — `BigDecimal.equals` wäre DB-abhängig. Gilt auch für die Invariante „aufeinanderfolgende
Zeilen unterscheiden sich“.

**Was Text gebracht hätte:** nur die gelieferten Nachnullen auf beiden DBs. Kein Leser braucht sie:
`kurs`/`tmp_if_last` sind `double`, das Preisfile wird Legacy-getreu aus einer Zahl formatiert, die
Support-Ansicht zeigt die Inbox-Zeile (Text, im Aufbewahrungsfenster, über `(job_id, zeilen_nr)`).

**Absicherung:** Multi-DB-Test in Chunk 3 — ein Wert mit 12 Nachkommastellen kommt auf H2 und
Postgres unverändert zurück (schützt vor einem späteren „Aufräumen“ zu `numeric(23,8)`).
**Nacharbeit außerhalb dieses Plans:** Javadoc an `PreismeldungZeile` korrigieren.

### B5 (W) — `empfangen` aus der DB-Uhr: wie konkret

„DB-seitig bei Ankunft gesetzt" kollidiert mit dem JPA-Insert (die Spalte steht im INSERT; ein
DB-Default greift nur mit `insertable = false`, dann kennt die Entity den Wert nicht) und mit der
Wiederholung, die einen **fremden** Wert erben muss. Einfachste Form, die beides kann:

- ein kleiner Helfer, der die DB-Uhr des aktuellen Kontexts liest
  (`jdbcTemplate.queryForObject("select current_timestamp", OffsetDateTime.class)`; das
  Routing-`JdbcTemplate` folgt dem Kontext) — `DatabaseContextHelper.currentDbTime()` neben `getCurrentDbUser()`, das dasselbe Template nutzt;
  nicht für Sybase (`getdate()`);
- Einreichung: `empfangen = currentDbTime()` im `job-system`-Kontext, explizit gesetzt;
- Wiederholung: `empfangen = original.empfangen` (Muster
  `AusschuettungsMeldungDiffJobSubmissionService:102`, `setRepeatedFromJob`).

Derselbe Helfer liefert den **Verarbeitungszeitpunkt** `sicht_von` — **einmal je Transaktion**,
im `business-new-introduced`-Kontext, für alle Zeilen der Datei derselbe Wert (Postgres `now()`
ist ohnehin transaktionsstabil). Der Calculator bekommt ihn als Parameter und bleibt uhrfrei.

### B6 (W) — „Eingang abgeschlossen" braucht einen Marker

„Nur der jüngste Versuch, der seinen Eingang abgeschlossen hat, zählt" und „eine Wiederholung,
die im Eingang scheitert, verdrängt nichts" sind ohne Marker nicht entscheidbar: der Jobstatus ist
`PROCESSING` über beide Stufen, `COMPLETED` erst nach der Verarbeitung, und ein Job mit null
angenommenen Zeilen hinterlässt keine Inbox-Zeilen. Also in der Chunk-3-Migration **drei**
Zeitstempel am Job: `empfangen`, `eingang_abgeschlossen_am` (gesetzt in derselben Transaktion wie
`deleteByJobId` + `saveAll` der Inbox-Zeilen, `PreisMeldungDiffJobExecutionService:112`),
`verarbeitet_am`. Verdrängt = „es gibt in der Wiederholungskette einen jüngeren Job mit
`eingang_abgeschlossen_am is not null`".

**Ablage und Feldbeschreibung (24.09.):** alle drei auf `preis_meldung_diff_jobs`. Der Code kennt
nur flache Jobtypen mit eigener JOINED-Tabelle; das Ausschüttungs-Paar (`AusschuettungsMeldungJob` /
`AusschuettungsMeldungDiffJob`) dupliziert seine Spalten statt eine Superklasse zu teilen, und der
produktive Job ist dort ein Modus (`source_type`) desselben Typs — der wahrscheinliche Weg auch für
die Preismeldung. Nicht auf `jobs` (fachspezifisch), nicht am Work-Queue-Item (nach 30 Tagen
gelöscht), keine Nebentabelle (kein Vorbild). Die Namen sind nicht selbsterklärend; die Javadocs
tragen deshalb die volle Bedeutung:

```java
/**
 * When the delivery arrived at IFAS, by the clock of the job database — the ordering key of the
 * price-history fold: lines of one price key are folded in (empfangen, job_id, zeilen_nr) order.
 * Set at submission via DatabaseContextHelper#currentDbTime(); a repeated job inherits its
 * original's value, because a repeat is not a new arrival. Neither Job#createdAt (application
 * clock, new per job) nor the processing time.
 */
@Column(name = "empfangen", nullable = false)
private OffsetDateTime empfangen;

/**
 * When the Eingang of this job ran to completion: the accepted lines — possibly none — are final
 * in preismeldung_zeilen. Written in the same transaction as the Inbox lines, so a non-null value
 * means "this job's Inbox content will not change". Only jobs with a value take part in the fold,
 * and only a repeat with a value supersedes its original (also with zero lines). Null while the
 * Eingang runs or after it failed.
 */
@Column(name = "eingang_abgeschlossen_am")
private @Nullable OffsetDateTime eingangAbgeschlossenAm;

/**
 * When stage 2 of this job ran: the fold went over every price key of this delivery and
 * preis_historie reflects the state known at that moment. Does NOT mean rows of this job exist in
 * preis_historie (a delivery often changes nothing: same value, ineffective D, lines before the
 * cursor), and a line of this job may have become a row's source earlier, through another job's
 * processing of the same key. Written after the preis_historie transaction committed, in a
 * transaction of its own; display and "already processed" hint, never a correctness condition.
 */
@Column(name = "verarbeitet_am")
private @Nullable OffsetDateTime verarbeitetAm;
```

Zusammen gelesen: `FAILED` + `eingangAbgeschlossenAm == null` = im Eingang gescheitert (verdrängt
nichts); `FAILED` + gesetzt = in Stufe 2 gescheitert (Inbox zählt, Retry faltet neu).

### B7 (W) — Eingangsstufe write-once (revidiert 24.09.)

**Ursprünglicher Befund:** dieselbe `(job_id, zeilen_nr)` kann zwei Zeilen der Kette öffnen, weil ein
Retry desselben Jobs den Eingang neu auswertet und die Inbox-Zeile bei geänderten Stammdaten mit
anderem Wert ersetzt (`deleteByJobId` + `saveAll`, `PreisMeldungDiffJobExecutionService:112`). Die
Quelle einer `preis_historie`-Zeile zeigt dann nicht mehr den Wert, der sie erzeugt hat.

**Einwand (User):** der Retry sollte vorhandene Zeilen nicht anfassen — nur fehlende einfügen, Marker
nicht ändern. Das macht die Quellen unveränderlich, lässt aber die andere Richtung offen: lehnt der
Retry eine Zeile ab, die der erste Versuch angenommen hatte, bleibt sie in der Inbox, die Rückmeldung
sagt „abgelehnt", und die Faltung benutzt sie trotzdem.

**Entscheidung: der Retry wertet nicht neu aus.** Der Plan trennt ohnehin Retry (technisch, derselbe
Job) von Wiederholung (fachlich, neuer Job, Neuauswertung mit Verdrängung). Also:

```
Eingangsstufe, Versuch n:
  eingang_abgeschlossen_am gesetzt?  → Auswertung und Inbox überspringen; nur Restliches erledigen
  sonst: auswerten → Rückmeldung + Result-Bundle bauen → Bundle in den Filestore
         → EINE job-system-Transaktion: deleteByJobId + saveAll + Marker + Result-Referenz + Zähler
```

- Heute: Inbox-Transaktion → Filestore → `updateResult`; neu: Auswertung → Filestore → eine
  Transaktion. Ein verwaistes Bundle einer gescheiterten Transaktion ist harmlos (DB-Filestore auf
  demselben `postgres-server`, `application-server-deployment.properties:28`).
- Abbruch **vor** der Transaktion → Marker null → voller Lauf, nichts war geschrieben. Abbruch
  **danach** → Marker gesetzt → beim Diff-Job bleibt nichts zu tun, beim produktiven Job der Versand aus
  dem gespeicherten Bundle.
- `deleteByJobId` bleibt, nur auf dem Marker-null-Pfad: Zeilen ohne Marker stammen aus einem
  abgebrochenen Lauf (auch `FAILED`-Jobs aus der Zeit vor der Migration) und werden ersetzt.
  „Vorhandene Zeilen überspringen" braucht es nicht, Marker und Zeilen sind atomar.
- Neu auswerten nach einer Stammdatenkorrektur = Wiederholung, nicht Retry — konsistent mit
  „Korrekturen nur über eine neue Lieferung oder eine Wiederholung". Der manuelle Retry eines
  `FAILED`-Jobs (`isProcessable()`) muss den Marker respektieren.
- Der Handler hat heute `maxAttempts = 1` (`AbstractJobWorkQueueHandler:91`); mit Chunk 6 bekommt
  Stufe 2 Retries, Stufe 1 kann sie bekommen — write-once macht beides ungefährlich.

**Quelle eindeutig (25.09.):** das letzte Duplikat war der Rückfall (B2) — die neue Zeile zitierte die
Vorgängerin, deren Wert sie wieder zeigt, also dieselbe Zeile zweimal in der Kette. Entscheidung: die
Quelle ist der **Auslöser**, nicht die Herkunft des Werts. Beim Wegfall durch eine Wiederholung zitiert
die neue Zeile — Rückfall-Wert oder D-Zeile — `(Wiederholung, zeilen_nr des Originals)`, die Zeile,
deren Wegfall den Zustand erzeugt hat; der Wert kommt aus der Faltung, die Kette zeigt, woher. Damit
ist jede Quelle genau einmal vergeben: eine wirksame Zeile liegt stets nach dem Cursor (nie zuvor
zitiert), die Wegfall-Quelle existiert in der Wiederholung nicht als angenommene Zeile (sonst wäre sie
wirksam), eine spätere Wiederholung zitiert sich selbst, eine Zeile hat einen Schlüssel, die Faltung
ist idempotent. Unique-Index auf `preis_historie (job_id, zeilen_nr)` als DB-Garantie und lauter
Fehler bei einem künftigen Faltungsfehler. Kosten: die Wegfall-Quelle ist keine Inbox-Zeile (in der
Wiederholung abgelehnt, in deren Rückmeldung), aber über Job + File + Zeile genauso auflösbar wie
jede Quelle nach dem Aufräumen der Inbox; die Support-Ansicht zeigt sie als „Zeile n der
Wiederholung, abgelehnt: Rückfall". Der Calculator verliert den Zweig „Quelle der Startzeile".

### B8 (K) — Abfrage „letzte Ankunft, die den Schlüssel berührt hat"

Stimmt mit der Gleicher-Wert-Regel nicht: eine identische Nachlieferung bewegt die offene Zeile
nicht, `empfangen` der offenen Zeile ist also die letzte **wirksame** Ankunft. Zeile in der Tabelle
in Abschnitt 2 so umformulieren oder streichen (die Frage beantwortet die Inbox).

### B9 (K) — Chunk 2: `marksKorrektur` und `PriceGroup` entfallen ganz

Die Kennzahlen-Invalidierung wird laut Abschnitt 8 aus dem Schließen einer `R`-Zeile abgeleitet;
ein Korrektur-Kennzeichen je Zeile hat keinen Leser mehr. `PriceGroup` gruppierte je Datei und
Aktion, weil ein `D` auf `R` kategorieübergreifend wirkte (Veto) — mit E3 ist jeder Schlüssel für
sich. Die Entscheidung reduziert sich auf: TEST → weg, C-Plan/AIF/Liquidation je Gate → weg,
LMT → weg (schon an der Schlüsselbildung), sonst durchlassen **mit `num_wfs_ku`** angereichert.

### B10 (K) — Nebenläufigkeitstest auf H2

Auf Postgres verliert der zweite Schreiber mit „0 Zeilen aktualisiert" (READ COMMITTED
re-evaluiert das Prädikat nach dem Warten) bzw. mit Unique-Verletzung beim Insert. H2/MVStore
wirft stattdessen nach `LOCK_TIMEOUT` eine Sperr-Ausnahme. Der Test darf also nur „wirft
irgendeine Ausnahme, danach genau eine offene Zeile, deren Wert einer der beiden ist" prüfen —
nicht den Ausnahmetyp. Alle drei Wege enden im Retry.

### B11 (K) — Chunk 6, „wo läuft sie zuerst": Diff-Job-Stufe, mit einer Sicherung

Empfehlung: als Stufe des `PreisMeldungDiffJob`, damit echte Läufe früh sichtbar sind. Die
genannten Nachteile lassen sich klein halten: `deleteArchivedBatch` verweigert Jobs, zu denen
`preis_historie`-Zeilen existieren (ein Count im `business-new-introduced`-Kontext) — oder löscht
für den Parallelbetrieb deren Zeilen mit (Testdaten). `empfangen` = Einreichungszeitpunkt ist für
den Vergleich gegen Legacy-`kurs` ausreichend, solange die Dateien eines Tags in Reihenfolge
eingereicht werden.

### B12 (K) — Laden je Job, nicht je Schlüssel

~26 k Zeilen/Tag, Dateien mit tausenden Schlüsseln: vier Statements je Schlüssel sind zehntausende
Roundtrips je Datei. Lesen in Bulk (Zeitreihen und Inbox-Zeilen für alle Schlüssel der Datei über
`isin in (…) and preisdatum in (…)`, im Speicher auf den vollen Schlüssel filtern), falten im
Speicher, **Schreiben** in fester Schlüsselreihenfolge. Die feste Reihenfolge braucht nur der
Schreibpfad.

### B13 (K) — `GjZeitreihe` als Muster

`GjZeitreihe` ist ein Record mit vier festen Slots; `GeschaeftsjahreCalculator` persistiert
mitten in der Berechnung über eine Persister-Funktion. Für `PreisZeitreihe` passt die **Idee**
(Record, Konstruktor prüft die Kette), nicht die Struktur: Liste statt Slots, und der Calculator
liefert die Änderung als Wert zurück, statt selbst zu persistieren (Abschnitt 2).

### B14 (K) — Flyway

`master` steht bei `V071`; das Feature bekommt `V072` in beiden Bäumen (Sybase als No-op wie
`V063`). Vor dem Merge nach `flyway-versions-after-merge.md` gegen `origin/master`, `stable`,
`production` prüfen und im Plan datiert vermerken.

---

## 2. Chunk 1 — Spezifikation der Zeitreihen-Logik

Modul `ifas-domain-fondspreise`, Package `at.oekb.ifas.domain.fondspreise.historie`. Keine
Persistenz, keine Stammdaten, keine Uhr. Alles `@NullMarked`, Records, Methodennamen englisch.

**Wiederverwendung (geprüft):** `BigDecimals.equalsIgnoreScale` (core-support) für den
Wertvergleich; `Meldekategorie`, `PreisAktion` (fondspreise); `PreismeldungZeileDaten` ist die
Eingang→Inbox-Richtung ohne Job/`empfangen` und deshalb nicht der richtige Typ für die Faltung —
daher `InboxZeile` (unten). Aus dem Branch übernehmbar ist nichts Strukturelles
(`PriceGroup`/`SyncDecision` modellieren die Kurs-Schreibentscheidung, nicht eine Kette).

### 2.1 Typen

```java
/** Der Schlüssel einer Preis-Zeitreihe; die Ordnung ist die feste Schreibreihenfolge (Abschnitt 4 des Plans). */
public record PreisSchluessel(String isin, LocalDate preisdatum, String waehrung, Meldekategorie meldekategorie)
        implements Comparable<PreisSchluessel> {
    // Konstruktor: meldekategorie.isLmt() → IllegalArgumentException (LMT erreicht die Tabelle nie)
    // compareTo: isin, preisdatum, waehrung, meldekategorie
}

/**
 * Die Zeile, deren Verarbeitung einen Zustand erzeugt hat: eine Inbox-Zeile oder — beim Wegfall in einer
 * Wiederholung — die Zeile des Originals unter der Wiederholung (dort abgelehnt, nicht in der Inbox).
 * Die Ordnung ist die Ankunftsordnung. Je preis_historie genau einmal vergeben.
 */
public record Quelle(UUID jobId, int zeilenNr, OffsetDateTime empfangen) implements Comparable<Quelle> {
    // compareTo: empfangen, jobId, zeilenNr — jobId vor zeilenNr, damit Zeilen eines Jobs
    // zusammenbleiben; jobId ist nur der deterministische Gleichstand-Brecher (Wiederholungen
    // erben empfangen, werden aber über die Verdrängung behandelt, nicht über diese Ordnung)
}

/** Eine Zeile der Kette. wert == null ist die D-Zeile. */
public record PreisZeile(
        PreisSchluessel schluessel,
        @Nullable BigDecimal wert,                 // null = D-Zeile; Skala wie von der DB geliefert, nie für Gleichheit benutzen
        long numWfsKu,
        OffsetDateTime sichtVon,
        @Nullable OffsetDateTime sichtBis,
        Quelle quelle
) {
    public boolean isGeloescht()  { return wert == null; }
    public boolean isOffen()      { return sichtBis == null; }
    public PreisZeile closedAt(OffsetDateTime sichtBis) { … }
}

/** Die lückenlose Kette eines Schlüssels; der Konstruktor erzwingt die Invarianten aus Abschnitt 2 des Plans. */
public record PreisZeitreihe(PreisSchluessel schluessel, List<PreisZeile> zeilen) {
    public PreisZeitreihe {
        zeilen = List.copyOf(zeilen);
        // je Zeile: schluessel gleich
        // i → i+1: sichtBis(i) != null && sichtBis(i).equals(sichtVon(i+1))       (lückenlos)
        //          !sichtVon(i+1).isBefore(sichtVon(i))                            (geordnet; Gleichheit erlaubt = nie sichtbar gewesen)
        //          !Preiswerte.equalNumerically(wert(i), wert(i+1))                (aufeinanderfolgende unterscheiden sich; deckt D auf D ab)
        // alle außer der letzten: sichtBis != null; die letzte darf offen sein
        // Quellen paarweise verschieden (der Unique-Index deckt es DB-weit, der Konstruktor je Schlüssel)
        // Verstöße: IllegalStateException mit Schlüssel und beiden Zeilen (wie Geschaeftsjahre.ensureCorrectlyChained)
    }
    public static PreisZeitreihe empty(PreisSchluessel schluessel) { … }
    public Optional<PreisZeile> offeneZeile() { … }                 // letzte Zeile, falls offen
    public Optional<PreisZeile> letzteZeileNichtAus(Set<UUID> verdraengteJobs) { … }  // für B2
    public PreisZeitreihe with(ZeitreiheAenderung aenderung) { … }  // wendet die Änderung an, Konstruktor prüft
}

/** Eine angenommene Inbox-Zeile, wie die Faltung sie sieht (Chunk 2 hängt numWfsKu an). */
public record InboxZeile(PreisSchluessel schluessel, PreisAktion aktion, @Nullable BigDecimal wert, long numWfsKu, Quelle quelle) {
    // wert: für N an der Grenze Inbox → Domäne aus new BigDecimal(inbox.wert) geparst (der Eingang hat -?\d+(\.\d+)? geprüft;
    //       ein Fehler hier ist eine verletzte Invariante → IllegalStateException mit (job_id, zeilen_nr)); für D null
    // Konstruktor: aktion == N && wert == null → IllegalArgumentException; aktion == I → IllegalArgumentException (nur L2, erreicht die Faltung nicht)
}

/** Was der Service zu schreiben hat. Höchstens eine Änderung je Schlüssel und Lauf (keine Zwischenzustände). */
public sealed interface ZeitreiheAenderung {
    record Keine() implements ZeitreiheAenderung {}
    record Oeffnen(PreisZeile neu) implements ZeitreiheAenderung {}
    record Ersetzen(PreisZeile zuSchliessen, PreisZeile neu) implements ZeitreiheAenderung {}
}

public record ZeitreiheErgebnis(PreisZeitreihe zeitreihe, ZeitreiheAenderung aenderung) {}

@UtilityClass
public final class Preiswerte {
    /** null = gelöscht; zwei gelöschte sind gleich; 101.20 und 101.2 sind gleich (compareTo, nicht equals). */
    public static boolean equalNumerically(@Nullable BigDecimal a, @Nullable BigDecimal b) {
        return BigDecimals.equalsIgnoreScale(a, b);   // null/null gleich, null/x ungleich
    }
}
```

### 2.2 Der Calculator

```java
@UtilityClass
public final class PreisZeitreiheCalculator {

    /**
     * @param bestehend        die Kette des Schlüssels, wie sie in der DB steht (ggf. leer)
     * @param zeilen           alle angenommenen, durch die Entscheidungen (Chunk 2) gelassenen Inbox-Zeilen
     *                         des Schlüssels, die der Service kennt — unsortiert, auch schon berücksichtigte
     * @param verdraengtDurch  Original-Job → jüngster Wiederholungs-Job mit abgeschlossenem Eingang
     *                         (transitiv aufgelöst; leer, wenn es keine Wiederholungen gibt)
     * @param sichtVon         der Verarbeitungszeitpunkt dieser Transaktion (DB-Uhr), für alle Schlüssel gleich
     */
    public static ZeitreiheErgebnis resolve(
            PreisZeitreihe bestehend,
            Collection<InboxZeile> zeilen,
            Map<UUID, UUID> verdraengtDurch,
            OffsetDateTime sichtVon
    ) { … }
}
```

Ablauf von `resolve` (die Regel aus B1 + B2, sonst nichts):

```
1. offen   = bestehend.offeneZeile()                                   // Optional
2. start   = bestehend.letzteZeileNichtAus(verdraengtDurch.keySet())   // Optional; ohne Verdrängung = offen
   zustand = start.map(wert).orElse(null)                              // null = gelöscht / keine Zeile
   cursor  = start.map(quelle)                                         // Optional
   wirksam = null                                                      // InboxZeile
3. for z in zeilen
       .filter(z -> !verdraengtDurch.containsKey(z.quelle().jobId()))
       .filter(z -> cursor.isEmpty() || z.quelle().compareTo(cursor.get()) > 0)
       .sorted(comparing(InboxZeile::quelle)):
       zustand = (z.aktion() == N) ? z.wert() : null
       wirksam = z
4. if offen.isPresent():
       if Preiswerte.equalNumerically(offen.wert(), zustand): return Keine
       neu = neueZeile(zustand, wirksam, start, offen, sichtVon)
       return Ersetzen(offen.closedAt(sichtVon), neu)
   else:
       if zustand == null: return Keine                                // D ohne Wirkung
       return Oeffnen(neueZeile(zustand, wirksam, start, offen, sichtVon))

neueZeile:
   quelle    = wirksam != null ? wirksam.quelle()
             : new Quelle(verdraengtDurch.get(offen.quelle().jobId()), offen.quelle().zeilenNr(), offen.quelle().empfangen())
                                                                        // Auslöser: die Zeile des Originals, deren Wegfall in der Wiederholung den Zustand erzeugt
                                                                        // (Rückfall-Wert oder D-Zeile); nur erreichbar, wenn offen aus einem verdrängten Job stammt → get() trifft
   numWfsKu  = wirksam != null ? wirksam.numWfsKu() : offen.or(start).numWfsKu()
   sichtVon  = sichtVon, sichtBis = null
```

Eigenschaften, die die Tests festnageln:

- **Idempotent:** `resolve(z.with(a), zeilen, …)` liefert `Keine`.
- **Reihenfolgeunabhängig** in `zeilen` (Sortierung nach `Quelle` innen).
- **Höchstens eine Änderung** je Aufruf; Zwischenzustände existieren nur im Fold.
- `sichtVon` darf gleich `offen.sichtVon` sein (Zeile war nie sichtbar), nie davor →
  `IllegalArgumentException`, sonst bricht die Ordnungsinvariante im Konstruktor.
- Wirft nie wegen Daten aus der Inbox; wirft bei einer inkonsistenten Kette (Konstruktor) —
  das ist ein Datenfehler in `preis_historie`, der den Job scheitern lassen soll.

### 2.3 Tests (`PreisZeitreiheCalculatorTest`, `PreisZeitreiheTest`, `PreiswerteTest`)

Given-when-then, AssertJ, Werte mit unterschiedlichen Ziffern (`"123.4567"`). Fixtures: ein
Schlüssel `(AT0000A1NX67, 2026-09-16, EUR, R)`, Quellen mit `empfangen` im Minutenabstand,
`sichtVon` je Lauf `+1h`.

Tabelle 3.1 des Plans, Zeile für Zeile:

| Test | Erwartung |
|---|---|
| `givenEmptyZeitreihe_whenResolveN_thenOeffnen` | Zeile mit Wert, Quelle = N |
| `givenEmptyZeitreihe_whenResolveD_thenKeine` | D ohne Wirkung |
| `givenOffenWert_whenResolveNWithSameWertOtherScale_thenKeine` | `new BigDecimal("101.20")` gegen `new BigDecimal("101.2")` |
| `givenOffenWert_whenResolveNWithOtherWert_thenErsetzen` | geschlossen bei `sichtVon`, neue offen, Quelle = N |
| `givenOffenWert_whenResolveD_thenErsetzenMitDZeile` | `wert == null`, `numWfsKu` von der D-Inbox-Zeile |
| `givenOffenDZeile_whenResolveN_thenErsetzen` | |
| `givenOffenDZeile_whenResolveD_thenKeine` | |

Diskussionsszenarien:

| Test | Erwartung |
|---|---|
| `givenBeispielAbschnitt2_whenReplayedRunByRun_thenChainMatches` | vier Läufe A/B/C/D → die 4-Zeilen-Kette, `sichtBis(i) == sichtVon(i+1)` |
| `givenOffenWert_whenResolveNAndDOfSameBatchUnsorted_thenOrderByQuelleDecides` | Liste `[D, N]` mit `N.quelle < D.quelle` → D-Zeile; umgekehrt → Wert |
| `givenOffenFromLaterQuelle_whenResolveOlderLine_thenKeine` | Szenario 1 |
| `givenEmptyZeitreihe_whenResolveLateNBeforeProcessedD_thenKeine` | Szenario 2 ohne Support: N (Tag 1) und D (Tag 2) in einer Faltung → gelöscht = Ausgang |
| `givenAppliedAenderung_whenResolveSameLines_thenKeine` | Idempotenz |
| `givenOffenWert_whenResolveIdenticalNThenReprocess_thenKeineTwice` | offene Zeile behält alte Quelle, zweite Faltung sieht die Zeile wieder, bleibt `Keine` |

Verdrängung (B2, Chunk 5 kann sie dann nur noch verdrahten):

| Test | Erwartung |
|---|---|
| `givenLinesOfVerdraengtemJob_whenResolve_thenIgnored` | |
| `givenOffenFromVerdraengtemJob_whenRepeatHasOtherWert_thenErsetzenWithRepeatQuelle` | |
| `givenOffenFromVerdraengtemJobWithPredecessor_whenRepeatHasNoLine_thenReopensPredecessorWert` | Wert der Vorgängerin, Quelle = (Wiederholung, `zeilenNr` des Originals) — nicht die Vorgängerzeile |
| `givenOffenFromVerdraengtemJobWithoutPredecessor_whenRepeatHasNoLine_thenDZeileWithRepeatQuelle` | `jobId` = Wiederholung, `zeilenNr` = Original, `numWfsKu` von der offenen Zeile |
| `givenOffenFromVerdraengtemJob_whenRepeatHasSameWert_thenKeine` | Quelle bleibt das Original |

Konstruktor `PreisZeitreihe`: Lücke, Überlappung (`sichtVon(i+1) < sichtVon(i)`), zwei offene,
gleicher Wert nacheinander, D auf D, Schlüssel gemischt, doppelte Quelle → `IllegalStateException`; leere Kette
und Einzelzeile → ok. `Preiswerte`: `null/null` gleich, `null/0` ungleich, `0/0.00` gleich, `-0/0` gleich.

### 2.4 Was Chunk 1 bewusst nicht enthält

Die **Auswahl** der Zeilen (welche Jobs, Inbox-Fenster, Entscheidungen aus Chunk 2) und die
Bestimmung von `verdraengtDurch` — beides Service (Abschnitt 3). Der Calculator faltet, was er
bekommt, und filtert nur am Cursor und an der Verdrängungsmenge.

---

## 3. Chunk 4 — der Service um den Calculator herum

`PreisHistorieVerarbeitungService` (ifas-main-service), ein Aufruf je Job:

```
process(jobId):
  // Lesen, job-system, keine eigene Transaktion
  1. job, empfangen; Wiederholungskette über repeatedFromJob rückwärts und
     JobRepository.findByRepeatedFromJobOrderByCreatedAtAsc vorwärts → verdraengtDurch
     (nur Wiederholungen mit eingang_abgeschlossen_am != null)
  2. Zeilen dieses Jobs + der von ihm verdrängten Originale → Schlüsselmenge
     (Meldekategorie R/E/Z/S/S2/S3, Aktion N/D) als TreeSet<PreisSchluessel>
  3. Bulk: alle angenommenen Zeilen dieser Schlüssel mit j.empfangen, nur Jobs mit
     eingang_abgeschlossen_am != null → gruppiert je Schlüssel
  4. Chunk 2 je Zeile (Stammdaten-Cache nach (isin, preisdatum)): übersprungene fallen weg,
     Rest wird InboxZeile mit numWfsKu

  // Schreiben, business-new-introduced, EINE Transaktion, REQUIRES_NEW (B3)
  5. sichtVon = currentDbTime()
  6. Bulk: alle Zeilen der Schlüssel → PreisZeitreihe je Schlüssel (leer, wo nichts ist)
  7. je Schlüssel in TreeSet-Reihenfolge: resolve → Aenderung
  8. je Aenderung, in derselben Reihenfolge:
       Ersetzen: closeIfOpen(id, sichtVon) == 1 sonst PreisHistorieKonfliktException; insert neu
       Oeffnen:  insert neu (zweiter Öffner scheitert am Unique-Index → DataIntegrityViolation)
  // Marker, job-system, eigene Transaktion
  9. verarbeitet_am = sichtVon
```

Konflikt (0 Zeilen, Unique-Verletzung, H2-Sperr-Timeout) → Ausnahme → Work-Item scheitert → Retry
liest und faltet neu. `maxAttempts` für diesen Task-Typ > 1 (`getMaxAttempts()` überschreiben,
Muster `CsvExcelConversionHandler:72`).

---

## 4. Chunk 3 — Persistenz-Skizze

`V072__preis_historie.sql` (postgres15; sybase16 gleiche Nummer, `-- not required in sybase database`).
Vorlage für Tabellenform und Grants: `V022__ausschuettung_tmp.sql` (UUID-PK, `${app-user}`).

```sql
create table preis_historie (
    id              uuid                        not null primary key,
    isin            varchar(12)                 not null,
    preisdatum      date                        not null,
    waehrung        varchar(3)                  not null,
    meldekategorie  varchar(2)                  not null,
    wert            numeric                     null,   -- ohne Präzision/Skala: max_nk ist für R/E/Z/S/S2/S3 null, jede Skala würde still runden; null = gelöscht (D-Zeile)
    num_wfs_ku      bigint                      not null,
    sicht_von       timestamp(6) with time zone not null,
    sicht_bis       timestamp(6) with time zone null,
    offen           char(1)                     null,   -- 'J' genau dann, wenn sicht_bis null ist (V035-Argument: NULLs sind im Unique-Index verschieden)
    job_id          uuid                        not null, -- logische Referenz in den Job-Kontext, kein FK
    zeilen_nr       integer                     not null,
    empfangen       timestamp(6) with time zone not null,
    constraint ck_preis_historie_offen check ((offen = 'J' and sicht_bis is null) or (offen is null and sicht_bis is not null))
);
create unique index ux_preis_historie_offen      on preis_historie (isin, preisdatum, waehrung, meldekategorie, offen);
create index        ix_preis_historie_schluessel on preis_historie (isin, preisdatum, waehrung, meldekategorie, sicht_von);
create unique index ux_preis_historie_quelle     on preis_historie (job_id, zeilen_nr);   -- jede Quelle genau einmal (B7)
grant select, insert, update, delete on table preis_historie to ${app-user};

alter table preis_meldung_diff_jobs add column empfangen                timestamp(6) with time zone;
alter table preis_meldung_diff_jobs add column eingang_abgeschlossen_am timestamp(6) with time zone;
alter table preis_meldung_diff_jobs add column verarbeitet_am           timestamp(6) with time zone;
-- Bestand: empfangen aus jobs.created_at, eingang_abgeschlossen_am aus jobs.finished_at für COMPLETED
update preis_meldung_diff_jobs set empfangen = (select j.created_at from jobs j where j.id = preis_meldung_diff_jobs.id);
alter table preis_meldung_diff_jobs alter column empfangen set not null;

create index ix_preismeldung_zeilen_schluessel on preismeldung_zeilen (isin, preisdatum);
```

Entity `PreisHistorie` (`ifas-persistence-fondspreise`, `@Table(name = "preis_historie")` ohne
Legacy-Katalog), Repository:

```java
List<PreisHistorie> findByIsinInAndPreisdatumIn(Collection<String> isins, Collection<LocalDate> preisdaten);

@Modifying
@Query("update PreisHistorie p set p.sichtBis = :sichtBis, p.offen = null where p.id = :id and p.offen is not null")
int closeIfOpen(@Param("id") UUID id, @Param("sichtBis") OffsetDateTime sichtBis);
```

Inbox (`PreismeldungZeileRepository`, infra):

```java
@Query("""
        select z, j.empfangen from PreismeldungZeile z, PreisMeldungDiffJob j
        where j.id = z.id.jobId and j.eingangAbgeschlossenAm is not null
          and z.isin in :isins and z.preisdatum in :preisdaten and z.meldekategorie in :kategorien
        """)
List<Object[]> findAcceptedLinesWithEmpfangen(…);   // oder eine Projektion (Interface/Record)
```

Multi-DB-Tests (H2 + Postgres): Unique-Index greift (zweiter offener Insert scheitert),
`closeIfOpen` liefert 0 auf geschlossener Zeile, Check-Constraint verweigert `offen = 'J'` mit
`sicht_bis`, Inbox-Abfrage lässt Jobs ohne `eingang_abgeschlossen_am` weg. Ein `wert` mit 12 Nachkommastellen
kommt auf H2 und Postgres unverändert zurück (B4). Ein zweiter Insert mit derselben Quelle scheitert (B7).

---

## 5. Textänderungen am Plan (Checkliste)

- [x] **Entscheidungen / Auflösen:** „Je Schlüssel und Kalender-Empfangstag …" → Fold ab der
      letzten nicht verdrängten Zeile in Ankunftsordnung (B1/B2); Zeile „D ohne Wirkung" → „wird
      nicht gespeichert; über Tage hinweg löst es die Faltung selbst" — Support-Fall streichen — **B1 erledigt 24.09.**; Cursor auf die letzte
      nicht verdrängte Zeile — **B2 erledigt 24.09.**
- [x] **3.1:** Schritt 1 „deren Job am Empfangstag D empfangen wurde" → „alle im Inbox-Fenster,
      Cursor = Quelle der Ausgangszeile"; Vorbedingung-Absatz streichen (im Cursor enthalten) — **erledigt 24.09.**
- [x] **5. Wiederholungen:** Punkt „Quelle entzogen" → Rückfall auf den letzten nicht verdrängten
      Zustand, D-Zeile nur ohne Vorgänger (B2); Punkt „Support-Fall aus Szenario 2" streichen — **erledigt 24.09.**
- [x] **5. Retry / Chunk 3:** Eingangsstufe write-once (B7 revidiert) — **erledigt 24.09.**
- [x] **4. Nebenläufigkeit:** ersten Punkt ersetzen durch B3 (Rows in einer Transaktion auf
      `business-new-introduced`, Marker danach, Idempotenz statt kontextübergreifender
      Atomarität; REQUIRES_NEW, weil der Handler in einer Transaktion läuft) — **B3 erledigt 24.09.**
- [x] **2. Tabelle:** `wert` → `numeric` ohne Skala, `null` = gelöscht, Vergleich `compareTo` (B4
      revidiert) — **erledigt 24.09.**; Zeile „letzte Ankunft" umformuliert, Fachabteilungsfrage im Tracker (B8) — **erledigt 25.09.**;
      Quelle eindeutig — Auslöser-Semantik + Unique-Index (B7) — **erledigt 25.09.**
- [ ] **Chunk 1:** Typen und Signatur aus Abschnitt 2 dieses Reviews übernehmen, Arbeitstitel
      `PreisZeitreiheCalculator`; Testliste aus 2.3; Hinweis, dass `GjZeitreihe` nur die Idee liefert (B13)
- [x] **Chunk 2:** `marksKorrektur`, `PriceGroup`, `SyncDecision` entfallen; Ergebnis = gefilterte
      `InboxZeile`n mit `num_wfs_ku`; Eingabe `PreismeldungZeileDaten`, Namen ohne „Sync" (B9) — **erledigt 25.09.**
- [ ] **Chunk 3:** drei Zeitstempel am Job (B6), Spaltenname `empfangen` (offene Frage schließen),
      DB-Uhr-Helfer (B5), Backfill für Bestand, DDL-Skizze aus Abschnitt 4, `V072` (B14) — **B5/B6-Anteile erledigt 24.09.**, DDL/`V072` mit Chunk 3
- [ ] **Chunk 4:** Ablauf aus Abschnitt 3 (Bulk-Lesen, Schreiben in Schlüsselordnung, B12);
      Nebenläufigkeitstest ohne Ausnahmetyp (B10) — **erledigt 25.09.**; `getMaxAttempts()` überschreiben
- [x] **Chunk 5:** schrumpft auf Verdrahtung (`verdraengtDurch` bestimmen, Schlüssel der
      Originale mitnehmen); die Regeln sind in Chunk 1 getestet — **erledigt 24.09.**
- [ ] **Chunk 6:** Empfehlung Diff-Job-Stufe + `deleteArchivedBatch`-Sicherung (B11)
- [ ] **Quellen:** `SynchronizingTransactionManager`/`SynchronizedTransaction` (Enroll-Reihenfolge =
      Commit-Reihenfolge), `WorkQueueExecutor:347/484` (Handler in Transaktion),
      `BigDecimals.equalsIgnoreScale`, `PreismeldungZeile` Javadoc (Text wegen Sammelreport),
      `V022__ausschuettung_tmp.sql` (Tabellenvorlage)

---

## 6. Tabellendesign zur Diskussion am 28.09. — `preismeldung_zeilen` und `preis_historie`

Stand 2026-09-25. Grundlage: Plan Abschnitt 2, DDL-Skizze in Abschnitt 4 dieses Reviews und die
Diskussion vom 25.09. (Stichtag-Intervalle, Zeitstempel, Löschungen, Legacy-Verhalten bei `D` und
an Tagen ohne Lieferung). Abschnitt 6.4 ist ein durchgerechnetes Beispiel über beide Tabellen,
Abschnitt 6.5 die drei Designfragen mit Empfehlung.

**Glossar:** Schlüssel = (`isin`, `preisdatum`, `waehrung`, `meldekategorie`). Stichtag =
`preisdatum`. Sicht = `sicht_von`/`sicht_bis`, seit wann bzw. bis wann IFAS einen Zustand zeigte.
D-Zeile = Zeile mit `wert = null`, der Zustand „zurückgezogen". Quelle = (`job_id`, `zeilen_nr`,
`empfangen`), die Inbox-Zeile, deren Verarbeitung die Zeile erzeugt hat. Lauf 1/Lauf 2 = die
beiden täglichen Preisfile-Läufe. P = offene Fachabteilungsfrage zur Fallback-Semantik (Tracker).

### 6.1 Zwei Tabellen, zwei Kontexte

| Tabelle | DB-Kontext | Modul | Rolle | Schreiber | Lebensdauer |
|---|---|---|---|---|---|
| `preismeldung_zeilen` | `job-system` (Katalog `infra`) | `ifas-persistence-infra` | **Inbox**: was der Eingang einer Lieferung angenommen hat, Zeile für Zeile, wie geliefert | Eingangsstufe, **write-once je Job** (B7) | Fenster, danach Aufräumen (Todo Tracker) |
| `preis_historie` | `business-new-introduced` | `ifas-persistence-fondspreise` | **Zustände je Schlüssel**: eine Zeile je Zustand, lückenlose Kette entlang der Sicht | Verarbeitungsstufe (Chunk 4), eine Transaktion je Lieferung | unbegrenzt |
| `preis_meldung_diff_jobs` (nur die drei Zeitstempel) | `job-system` | `ifas-persistence-infra` | Ankunft und Stufenmarker der Lieferung | Einreichung, Eingang, Verarbeitung | wie Jobs (produktiv: nie gelöscht) |

Zwischen den Kontexten gibt es **keinen Fremdschlüssel**. (`job_id`, `zeilen_nr`) in
`preis_historie` ist eine logische Referenz; sie bleibt auflösbar, weil produktive Jobs nie
gelöscht werden und die Inbox write-once ist. Im Deployment liegen beide Kontexte auf demselben
`postgres-server`, in Tests beide auf `h2-infra-db`.

### 6.2 `preismeldung_zeilen` — Bestand (V061/V067) plus ein Index aus Chunk 3

| Spalte | Typ | Null | Bedeutung |
|---|---|---|---|
| `job_id` | `uuid` | nein | PK-Teil; der Job, dem die Zeile gehört. FK auf `jobs` (V067, ohne Cascade) |
| `zeilen_nr` | `integer` | nein | PK-Teil; physische Zeilennummer in der gelieferten Datei |
| `isin` | `varchar(12)` | nein | wie geliefert |
| `preisdatum` | `date` | nein | der Stichtag |
| `waehrung` | `varchar(3)` | nein | **Lieferwährung**, nicht die Fondswährung |
| `meldekategorie` | `varchar(2)` | nein | nach `tax_code`-Alias-Auflösung: `R`, `E`, `Z`, `S`, `S2`, `S3`, `L1`, `L2`, `L3` |
| `aktion` | `varchar(1)` | nein | `N`, `D`, (nur L2) `I`; leere Lieferung = `N` |
| `wert` | `varchar(30)` | nein | Text, normalisiert (Komma → Punkt, Blanks weg, `ignore_null` → `"0"`); gegen `-?\d+(\.\d+)?` geprüft; geparst erst beim Bau der `InboxZeile` (B4). Auf `D`-Zeilen der gelieferte Wert, für die Faltung bedeutungslos |
| `fondsbezeichnung` | `varchar(100)` | ja | wie geliefert |
| `lmt_prozentkennzeichen`, `lmt_stichtag` | `varchar(1)`, `date` | ja | nur LMT; LMT erreicht `preis_historie` nie |

Schlüssel und Indizes: PK (`job_id`, `zeilen_nr`); FK `job_id` → `jobs`; **neu** (Chunk 3):
Index (`isin`, `preisdatum`) für „alle Zeilen eines Schlüssels".

Eigenschaften, die die Faltung voraussetzt:

- **Nur angenommene Zeilen.** Abgelehnte stehen in der Rückmeldung, nicht hier.
- **Write-once je Job.** Ein Retry mit gesetztem `eingang_abgeschlossen_am` fasst die Zeilen nicht
  an; neu auswerten heißt Wiederholung als neuer Job (B7).
- **Nie ein Update.** Eine Korrektur ist eine neue Zeile in einem neuen Job.
- **Die Ankunft steht nicht an der Zeile, sondern am Job** (`empfangen`); die Faltung liest sie
  per Join. Es zählen nur Jobs mit `eingang_abgeschlossen_am` (B6), und von einer
  Wiederholungskette nur das Ende (Plan Abschnitt 5).

Am Job (`preis_meldung_diff_jobs`, Chunk 3, alle `timestamp(6) with time zone`):

| Spalte | Null | Bedeutung |
|---|---|---|
| `empfangen` | nein | Ankunft bei IFAS nach der DB-Uhr des Job-Kontexts; **Ordnungsgröße der Faltung**; Wiederholung erbt den Wert des Originals |
| `eingang_abgeschlossen_am` | ja | Eingang bis zum Ende gelaufen, Inbox-Zeilen final; nur dann zählt der Job |
| `verarbeitet_am` | ja | Faltung über alle Schlüssel dieser Lieferung gelaufen; Anzeige, keine Korrektheitsbedingung |

### 6.3 `preis_historie` — neu (V072)

| Spalte | Typ | Null | Bedeutung | Warum so |
|---|---|---|---|---|
| `id` | `uuid` | nein | Surrogat-PK | Tiebreak beim Lesen einer Kette mit gleichem `sicht_von` (Test-Uhren) |
| `isin` | `varchar(12)` | nein | Schlüsselteil, wie geliefert | |
| `preisdatum` | `date` | nein | Schlüsselteil; der Stichtag als **Punkt** | Kein `stichtag_bis`: Legacy `kurs` und `tmp_if_last` sind punktbasiert, der Fallback ist eine **Leseregel** (65 Tage, nur ISIN, Frage P offen). Ein gespeichertes Ende würde P beim Schreiben entscheiden und jede Ankunft zur Operation auf Nachbarzeilen machen (6.5, Frage 1) |
| `waehrung` | `varchar(3)` | nein | Schlüsselteil; Lieferwährung | Fremdwährung erreicht die Tabelle, bis das Eingangsflag an ist (Plan Abschnitt 8) |
| `meldekategorie` | `varchar(2)` | nein | Schlüsselteil; nur `R`, `E`, `Z`, `S`, `S2`, `S3` | LMT wird an der Schlüsselbildung abgewiesen |
| `wert` | `numeric` | **ja** | der Preis; **`null` = D-Zeile** (zurückgezogen) | Löschung ist ein **Zustand** der Kette, kein Flag und kein Update (6.5, Frage 3). Ohne Präzision/Skala (B4); Gleichheit per `compareTo` |
| `num_wfs_ku` | `bigint` | nein | Fonds zum Stichtag aufgelöst; **auch auf D-Zeilen** | die spätere `kurs`-Löschung braucht diese Identität |
| `sicht_von` | `timestamp(6) with time zone` | nein | seit wann IFAS diesen Zustand zeigt; DB-Uhr als erste Anweisung der Verarbeitungstransaktion, **ein Wert für alle Zeilen der Datei** | **Zeitstempel, kein Datum**: ein Schlüssel hat mehrere Zustände am selben Tag (N 10:00, Lauf 1, D 15:00, Lauf 2 → `I3`); nur die Uhr ordnet die Kette, die Quelle kann es nicht (Wiederholung erbt `empfangen`) (6.5, Frage 2) |
| `sicht_bis` | `timestamp(6) with time zone` | ja | `null` = offen; sonst = `sicht_von` der Nachfolgerin | lückenlos; **nie** verändert außer beim Schließen |
| `offen` | `char(1)` | ja | `'J'` genau dann, wenn `sicht_bis` null | Träger des Unique-Index „höchstens eine offene Zeile je Schlüssel"; H2 kennt keine partiellen Indizes (V035-Argument) |
| `job_id`, `zeilen_nr` | `uuid`, `integer` | nein | die **Quelle**: die Zeile, deren Verarbeitung den Zustand erzeugt hat — der Auslöser, nicht die Herkunft des Werts | logische Referenz; jede Quelle genau einmal (B7) |
| `empfangen` | `timestamp(6) with time zone` | nein | vom Job kopiert; Ankunftsordnung der Quelle | Cursor der Faltung ohne Join in den anderen Kontext |

Indizes und Constraints (DDL in Abschnitt 4):

- `ux_preis_historie_offen` (`isin`, `preisdatum`, `waehrung`, `meldekategorie`, `offen`) —
  höchstens eine offene Zeile je Schlüssel, der zweite Insert scheitert
- `ix_preis_historie_schluessel` (`isin`, `preisdatum`, `waehrung`, `meldekategorie`, `sicht_von`)
  — Kette eines Schlüssels, Zustand zu T
- `ux_preis_historie_quelle` (`job_id`, `zeilen_nr`) — jede Quelle genau einmal
- Check `offen = 'J' ⇔ sicht_bis is null`

Invarianten je Schlüssel (Konstruktor `PreisZeitreihe`, Abschnitt 2.1): geordnet nach
`sicht_von`; lückenlos (`sicht_bis(i) = sicht_von(i+1)`); nur die letzte Zeile offen; zwei
aufeinanderfolgende Zeilen unterscheiden sich im Wert (kein Doppel, kein D auf D); Quellen paarweise
verschieden.

**Nicht in der Tabelle**, absichtlich: Fondsbezeichnung (Klärung O), ein Grund oder „beendet durch"
(die nächste Zeile sagt es), ein Korrektur-Kennzeichen (kein Leser), Stichtag-Intervalle, und
**Zeilen für Tage ohne Lieferung** — Wochenende, Feiertag, verpasster Tag: kein Schlüssel, keine
Zeile, in keiner der beiden Tabellen.

### 6.4 Beispiel — ein Fonds, sechs Tage, beide Tabellen

**Glossar für das Beispiel:** J0–J6 = Jobs (UUIDs abgekürzt), H0–H6 = Zeilen in `preis_historie`.
Zeiten als Wochentag und Uhrzeit: Do = 2026-09-17, Fr = 18.9., Sa/So = 19./20.9., Mo = 21.9.,
Di = 22.9. Fonds `AT0000A00001`, Fondswährung EUR, `num_wfs_ku` 4711, nur Kategorie `R`.
`sicht_von` liegt ein paar Minuten nach `empfangen`: Ankunft ist die Einreichung, Sicht die
Verarbeitungstransaktion.

Ablauf:

```
Job  empfangen     Zeile  Lieferung                              Wirkung in preis_historie
J0   Do 08:00      3      N 17.9. R 100.90                       H0 öffnen
J1   Fr 08:05      3      N 18.9. R 101.20                       H1 öffnen
J2   Fr 10:05      3      N 18.9. R 101.30  (Korrektur)          H1 schließen, H2 öffnen
     Fr 14:00      —      Lauf 1: 18.9. = 101.30 geht als I2 hinaus
J3   Fr 15:05      3      D 18.9. R         (Rücknahme)          H2 schließen, H3 (D-Zeile) öffnen
     Fr 16:00      —      Lauf 2: 18.9. geht als I3 hinaus
     Sa, So        —      keine Lieferung                        nichts — kein Schlüssel, keine Zeile
J4   Mo 08:10      3      N 21.9. R 101.90                       H5 öffnen
                   4      N 18.9. R 101.30  (Nachlieferung)      H3 schließen, H4 öffnen
J5   Mo 09:00      3      N 21.9. R 101.90  (identisch)          nichts — gleicher Wert
J6   Di 08:00      3      N 17.9. R 100.95  (späte Korrektur)    H0 schließen, H6 öffnen
```

`preismeldung_zeilen` danach — acht Zeilen, eine je gelieferter Zeile, nichts verändert, nichts
gelöscht (LMT-Spalten weggelassen):

```
job_id  zeilen_nr  isin          preisdatum  waehrung  meldekategorie  aktion  wert
J0      3          AT0000A00001  2026-09-17  EUR       R               N       100.90
J1      3          AT0000A00001  2026-09-18  EUR       R               N       101.20
J2      3          AT0000A00001  2026-09-18  EUR       R               N       101.30
J3      3          AT0000A00001  2026-09-18  EUR       R               D       101.30
J4      3          AT0000A00001  2026-09-21  EUR       R               N       101.90
J4      4          AT0000A00001  2026-09-18  EUR       R               N       101.30
J5      3          AT0000A00001  2026-09-21  EUR       R               N       101.90
J6      3          AT0000A00001  2026-09-17  EUR       R               N       100.95
```

`preis_historie` danach — sieben Zeilen, nach Schlüssel und `sicht_von` (`—` = null):

```
id  preisdatum  whg  kat  wert    num_wfs_ku  sicht_von  sicht_bis  offen  job_id  zeilen_nr  empfangen
H0  2026-09-17  EUR  R    100.90  4711        Do 08:02   Di 08:02   —      J0      3          Do 08:00
H6  2026-09-17  EUR  R    100.95  4711        Di 08:02   —          J      J6      3          Di 08:00
H1  2026-09-18  EUR  R    101.20  4711        Fr 08:07   Fr 10:07   —      J1      3          Fr 08:05
H2  2026-09-18  EUR  R    101.30  4711        Fr 10:07   Fr 15:07   —      J2      3          Fr 10:05
H3  2026-09-18  EUR  R    —       4711        Fr 15:07   Mo 08:12   —      J3      3          Fr 15:05
H4  2026-09-18  EUR  R    101.30  4711        Mo 08:12   —          J      J4      4          Mo 08:10
H5  2026-09-21  EUR  R    101.90  4711        Mo 08:12   —          J      J4      3          Mo 08:10
```

Was man daran sieht:

- **Drei Ketten, drei Schlüssel.** 17.9., 18.9. und 21.9. berühren einander nie. Die späte
  Korrektur J6 zum 17.9. ist eine gewöhnliche Zeile in ihrer Kette; 18.9. und 21.9. bleiben unberührt.
  Mit Stichtag-Intervallen müsste J6 das Intervall des 17.9. neu schneiden und J4 das des 18.9. beenden.
- **Vier Zustände des 18.9. an einem Tag** (H1, H2, H3, dann Mo H4). Mit Datumsgranularität hätten
  H1–H3 alle `Fr–Fr`, Länge null, keine Ordnung; „Preis 18.9., Stand Fr" hätte drei Antworten.
- **H4 hat denselben Wert wie H2** und ist trotzdem eine eigene Zeile: dazwischen liegt H3. Die
  Regel „aufeinanderfolgende Zeilen unterscheiden sich" gilt nur für Nachbarn.
- **J5 hinterlässt eine Inbox-Zeile und keine Historie-Zeile.** Ob derselbe Preis erneut geliefert
  wurde, beantwortet die Inbox (bis zum Aufräumen), nicht die Historie (Gleicher-Wert-Regel, B8).
- **H4 und H5 teilen `sicht_von`**: eine Datei, eine Transaktion, ein DB-Uhr-Wert.
- **Sa und So kommen nirgends vor.**

Abfragen gegen dieses Beispiel:

| Frage | Prädikat | Ergebnis |
|---|---|---|
| aktueller Preis 18.9. | Schlüssel, `offen = 'J'`, `wert is not null` | H4 = 101.30 |
| Preis 18.9., Stand Fr 12:00 | Schlüssel, `sicht_von <= T < sicht_bis` | H2 = 101.30 |
| Preis 18.9., Stand Fr 16:00 (Lauf 2) | dito | H3 = zurückgezogen → `I3` |
| Preis 18.9., Stand Fr (nur Datum) | — | nicht eindeutig: 101.20, 101.30 oder zurückgezogen — deshalb Zeitstempel |
| zurückgezogen oder nie geliefert, Stand Fr 16:00 | offene D-Zeile vs. keine Zeile | 18.9.: zurückgezogen (H3); 19.9.: nie geliefert |
| „Preis zum Sa 19.9.", Stand Mo 07:00 | kein Schlüssel 19.9.; größter Stichtag ≤ 19.9. mit Wert unter den zu T sichtbaren Zeilen | 17.9. = 100.90 (H0) — **oder nichts, je nach Antwort auf P**; die Regel steht im Leser, nicht in der Tabelle |
| „Preis zum Sa 19.9.", Stand jetzt | dito über offene Zeilen | 18.9. = 101.30 (H4) |
| Preisreihe des Fonds, Stand jetzt | `offen = 'J'`, `wert is not null`, order by `preisdatum` | 17.9. 100.95, 18.9. 101.30, 21.9. 101.90 |
| Kette des Schlüssels 18.9. (Support-UI) | Schlüssel, order by `sicht_von`, `id` | H1, H2, H3, H4 |
| zweite Faltung ohne neue Zeilen | — | keine Änderung (Cursor = Quelle der offenen Zeile) |

Kein `max(sicht_von)` in keiner Zeile: „aktuell" ist `offen = 'J'`, „Stand zu T" ein
Bereichsprädikat — dasselbe Muster wie `gueltBis is null` in `LieferStatusGesamtRepository`. Das
einzige `max` ist das über `preisdatum` in der Fill-forward-Frage, und das gibt es in Legacy genauso
(`cFondsBasis::ReadMaxKursdatum`).

**Legacy im selben Beispiel, zum Vergleich:** J3 (`D` am Fr) löscht die Zeile 18.9. in `kurs`
physisch (`DeleteKurs`), ohne Version, ohne Ersatz — ein Loch; `tmp_if_last` bleibt unberührt
(`WriteLastKurse` ignoriert `D`, `DeleteLastKurse` hat keinen Aufrufer). Fr Lauf 2 sendet `I3`;
**Mo** sendet der Lauf-1-Fallback den gelöschten Preis 18.9. = 101.30 als `I2` erneut, der
Bezieher spielt ihn wieder ein (Frage P, Fall 2). Sa/So: keine Zeile in `kurs`; Leser holen
`max(dat_kurs)` zum Zeitpunkt der Frage.

### 6.5 Für Montag — die drei Designfragen, mit Empfehlung

1. **Stichtag als Punkt (Empfehlung) oder `stichtag_von`/`stichtag_bis`?** Nichts in der Kette
   behauptet einen Preis für einen Tag ohne Lieferung: `kurs` und `tmp_if_last` sind punktbasiert
   (PK mit `dat_kurs`), der Fallback sendet den letzten Preis **mit altem Preisdatum** als `I2`,
   der Bezieher upsertet auf den Punkt-Schlüssel. Fill-forward ist eine Leseregel je Leser
   (Preisfile: 65 Tage, Anti-Join nur ISIN; Fehlmeldung: 3–11 Börsetage; Kennzahlen:
   `Referenzkurs_Tage`), und P ist offen. Intervalle würden jede Ankunft zur Operation auf
   Nachbarzeilen machen (Mo beendet Fr; eine späte Zeile splittet; ein `D` entscheidet P beim
   Schreiben), die Sperreinheit auf die ISIN-Reihe ausdehnen und die Nicht-Überlappung aus der DB
   in die Anwendung verlagern (H2: keine Range-Constraints). Wer Intervalle lesen will, bekommt sie
   als View über `lead(preisdatum)` — berechnet, nie gespeichert. Plan-Wortlaut anpassen:
   `preis_historie` hält eine *Sichtkette je Schlüssel*; die *Preisreihe* entlang des Stichtags
   ist eine Abfrage über offene Zeilen.
2. **`sicht_von`/`sicht_bis` als Zeitstempel (Empfehlung) oder Datum?** Der Tag ist nicht atomar:
   zwei Läufe, Korrekturen und Rücknahmen dazwischen (Beispiel H1–H3). Nur die Uhr ordnet die
   Kette; die Quelle kann es nicht (Wiederholung erbt `empfangen`, UUIDs sortieren nicht
   chronologisch). Ein Zeitstempel beantwortet jede Datumsfrage (T = Tagesende), ein Datum keine
   Zeitfrage; Kosten null. Anzeige und API nehmen ein Datum. „Stand zu T" ist diagnostisch
   (Support, Parallelbetrieb), kein funktionaler Leser — die Läufe lesen offene Zeilen und das
   Publikationsprotokoll. Lesen der Kette mit Tiebreak `id` (Test-Uhren, vgl. STM-Flake).
3. **Löschung als D-Zeile mit `wert = null` (Empfehlung), als Flag mit Wert, oder als Absenz?**
   D-Zeile: die offene Zeile beantwortet immer „was sagt IFAS jetzt" — Wert, zurückgezogen, oder
   keine Zeile = nie geliefert (Fehlmeldung); jeder Preisleser überspringt `wert is null`. Flag +
   mitgeführter Wert: dieselbe Kette, kosmetisch (UI zeigt „zurückgezogen: 101.30" ohne
   Vorgängerin). Absenz (nur `sicht_bis` schließen, keine Nachfolgerin): verliert die
   Lückenlosigkeit, „zurückgezogen vs. nie geliefert" wird zur Historienabfrage, und im
   Intervall-Modell wäre das genau die Stelle, an der P beim Schreiben entschieden werden muss.
   **Ausgeschlossen:** ein Flag auf der Originalzeile — das schreibt Sichtbares um.
