# Fondspreise Schnitt 2 — Sync nach `kurs`, monotoner Guard, `letzte_preise`

## Context

Zweiter Implementierungsschnitt der Fondspreis-Neuentwicklung nach dem Konzept
`mathias/plans/fondspreise/2026-08-31-fondspreise-neuentwicklung-konzept.md` (Entscheidungen 8 + 9,
Abschnitt *Zwei Server, ein Pool*) und dem Tracker im selben Ordner. Schnitt 1 (Eingang, Inbox,
Rückmeldung, `PreisMeldungDiffJob` mit Diff-Ebene 1) ist umgesetzt und gepusht
(`1f3d9f393`, `0dbd47271`, `bef9800c6`).

Schnitt 2 baut **Stufe 2 der Lieferkette**: die geprüften Inbox-Zeilen gehen nach `kurs..kurs` in der
Neusystem-Sybase, geordnet über einen monotonen Guard statt über Serialisierung, und die Projektion
`letzte_preise` ersetzt `kurs..tmp_if_last`. Der `PreisMeldungDiffJob` wächst dabei um die
Diff-Ebenen 3 (DB-Stand) und 4 (Projektion).

> **Revidiert 2026-09-11 (Designreview, D11–D14):** Die Projektion bleibt in `kurs..tmp_if_last` der
> Neusystem-Sybase und wird Legacy-getreu geschrieben; `letzte_preise` bleibt als Guard und Spiegel.
> Die Diff-Ebenen 3 und 4 kommen wieder aus dem Job heraus, der DB-Vergleich wird ein eigener,
> generischer Tabellenvergleich Sybase alt gegen Sybase neu. Umbau in AP11.

Der fachliche Wert der Stufe: der Preis steht **Minuten nach der Lieferung** in `kurs` statt am
Tagesende. Damit ist die Vorbedingung der Ausschüttungs-Einspielung erstmals am selben Vormittag
erfüllt, und der Legacy-Zirkel (Filegenerierung braucht die Ausschüttung, Ausschüttung braucht den
Preis, Preis kommt erst nach der Filegenerierung) wird zu einer Ordnung.

**Vorgaben, die schon feststehen:** Sybase schema-gesperrt (M) — neue Tabellen nach Postgres,
Katalog `kurs`, Kontext `fondspreise`; Job-Tabellen bleiben `infra`; `job_id` an Business-Tabellen
ist logische UUID-Referenz ohne FK.

**Entscheidungen des Users vom 2026-09-08, in diesen Plan eingearbeitet:**

1. **Vorübergehende Zustände in `kurs` sind akzeptiert.** Dass ein „`N` um 08:00, `D` um 09:00"
   bei uns kurz in `kurs` landet und wieder verschwindet (Legacy schreibt in dem Fall nie), ist die
   legitime Folge der Sofortverarbeitung — kein Bug, sondern eine bewusst geführte Abweichung im
   Diff.
2. **`pool_if_kurs` wird nicht portiert** (Begründung unter D2).
3. **Ausschüttungs-Veto (E): Legacy-Verhalten bleibt**, aber der Befund muss sichtbar gesammelt
   werden statt nur ins Programm-Log zu fallen (D6).
4. **Zeitlicher Ablauf ist ein eigener Schritt** — Ablaufdiagramm für die Fachabteilung, inkl. der
   Anforderung „Sammellauf 1 **vor** Ausschüttungsjob 3" und der Analyse von Punkt L. **Nicht Teil
   dieses Schnitts**; Schnitt 2 liefert nur die Vorbedingung dafür.

**Entscheidungen des Users vom 2026-09-11 (Designreview), in diesen Plan eingearbeitet:**

1. **DB-Setup bestätigt.** Im Parallelbetrieb gibt es zwei Sybase-Instanzen: die alte schreibt nur
   das Altsystem, die neue nur das Neusystem; beide Schemata sind eingefroren. Postgres schreibt nur
   das Neusystem und ist frei änderbar. Zum Go-live ein einmaliger Voll-Sync der Datenbank, danach
   werden **alle vom Neusystem geschriebenen Tabellen** auf Divergenz zum Altsystem beobachtet.
2. **Diff-Ebenen 3 und 4 kommen aus dem `PreisMeldungDiffJob` heraus.** Der DB-Vergleich wird ein
   eigener, generischer und geplanter Tabellenvergleich Sybase alt gegen Sybase neu (D13). Ebene 1
   bleibt im Job.
3. **`kurs..tmp_if_last` bleibt vorerst** und wird vom Neusystem in der Neusystem-Sybase
   Legacy-getreu geschrieben (D11). Grund: möglicherweise lesen KUPL/KMS direkt aus der Tabelle. Ob
   sie überhaupt gebraucht wird, klärt der User mit der Fachabteilung (Tracker O/P).
4. **`letzte_preise` bleibt ganz erhalten** — Werte, `job_id`, `angekommen_am` — und wird zur
   Klammer für den `tmp_if_last`-Write (D12). Aufräumen auf einen reinen Guard ist später möglich.
5. **Verhalten vorerst Legacy-getreu** bei Preiswährung ≠ Fondswährung und bei Löschungen (D14);
   einzige bewusste Abweichung bleibt die strengere Reihenfolge über `(preisdatum, angekommen_am)`.
6. **Kein Guard-Seed** (nach dem Umbau AP11): `letzte_preise` startet leer, der erste Write je
   Schlüssel nach dem Go-live verhält sich wie Legacy, ab dem zweiten greift unsere Regel (D12).

## Stand 2026-09-08

**AP1–AP3 umgesetzt und verifiziert**, committet als `30b6adec8` auf dem Branch
`feat/fondspreis` (nicht gepusht). Gesamtbuild grün; 95 Domain-Tests,
`PreismeldungSyncGuardTest` 14 (7 Fälle × H2 + Postgres), `KursRepositoryTest` 9 (alle drei DBMS),
`PreisMeldungDiffJobTest` 2.

| AP | Stand |
|---|---|
| AP1 Stammdaten | fertig — `FondsStammdaten` um `numWfsKu`/`codArtF`/`status` + Prädikate erweitert, eine gebündelte `InvRepository#findFondsStammdatenByIsin` ersetzt die zwei bisherigen Lookups |
| AP2 Properties | fertig — `FondspreiseProperties` (`ifas.fondspreise`) |
| AP3 Persistenz + Flyway | fertig — `Kurs`/`KursId`/`KursRepository`, `PreisHerkunft`(+Id/Repo), `LetzterPreis`(+Id/Repo), `V065__fondspreise_sync.sql` je Baum |
| AP4 Entscheidungslogik | fertig — `PreismeldungSyncDecisions` + `SyncDecision`/`SyncOperation`/`SyncSkipReason`, `PriceGroup`, `PreismeldungSyncOptions`, `AusschuettungProvider`; 20 Unit-Tests; Review-Fixes vom 2026-09-10 eingearbeitet (siehe unten) |
| AP5 Sync-Service | fertig — `PreismeldungSyncService` (Inbox→`PriceGroup`, Entscheidung im Business-Kontext, Klammer je Preisschlüssel, `kurs`-Write, Projektion fortschreiben), Ausschüttungs-Veto über `AsfRepository`; `PreismeldungSyncServiceTest` 5 (H2) |
| AP6 Projektion/Rebuild/Seed | fertig — `LetztePreiseService` (Fortschreiben aus AP5 hierher extrahiert, `cleanupEndedFunds`, `seed`), `PreismeldungSyncService.rebuildProjection`; +4 Tests. **Seed-Leser** aus `tmp_if_last` offen (Cross-DB, siehe unten). **→ AP11 (2026-09-11):** Projektion wandert nach `kurs..tmp_if_last`, `letzte_preise` bleibt Guard + Spiegel, Seed-Leser hinfällig |
| AP7 Job-Erweiterung | fertig — `PreisMeldungDiffJob` um `angekommen_am` (DB-Uhr bei Submission) + Zähler `synced/skipped/veto/db_diff`; Execution-Service ruft Stufe 2, schreibt `sync-report.txt` und die Zähler; Flyway V066. `PreisMeldungDiffJobTest` prüft Stufe 2 mit |
| AP8 Diff-Ebenen 3+4 | fertig — `PreismeldungDbDiff` (Domain) + `PreismeldungDbDiffService` (kurs neu↔alt, letzte_preise↔tmp_if_last im legacyBusiness-Kontext); `db-diff.txt` + `db_diff_count`; read-only `TmpIfLast` + Flyway V067. 6 Domain-Tests + Selbstvergleich-E2E. **`pool_if_kurs`-Kontrolle verschoben**. **→ AP11 (2026-09-11): wieder ausgebaut** — DB-Vergleich wird generischer Job (D13) |
| AP9–AP10 | offen |
| AP11 Umbau nach Designreview | fertig — Projektion nach `tmp_if_last`, `letzte_preise`-Klammer, Diff-Ebenen 3/4 ausgebaut, Guard-Seed-Leser; siehe *Stand 2026-09-11 — AP11* |

**Stand 2026-09-10 — AP4 und Code-Review.** `/code-review-ifas` über AP4 fand zwei echte
Logikfehler gegen Legacy, beide behoben und mit Tests gepinnt:

- `D` in Fremdwährung hätte die Projektion mit dem zurückgezogenen Wert fortgeschrieben — Legacy
  ruft `WriteLastKurse` nur im Nicht-`D`-Zweig (`preisekennzahl.cpp:2735/:2850`). Jetzt: `D` in
  Fremdwährung ist ein vollständiger No-op. Verschärfend: `D`-Zeilen durchlaufen im Eingang keine
  Wertprüfung, ihr `wert` kann leer sein.
- Die Aktivierungs-Flag ignorierte das `fondsBeginn`-Gate (`fondsbasis.cpp:3882`) — behoben,
  dann mit AP5 **ganz entfernt**: die Fondsaktivierung ist kein Preis-Thema (D10).

Dazu zwei Kontraktkorrekturen unter der Schwelle, trotzdem genommen: `marksKorrektur` gilt bei `D`
nur noch für `R`-Löschungen *eines früheren Tages* (Javadoc und Legacy `:2915` stimmen jetzt überein),
und ein `NOT_FONDSWAEHRUNG`-Skip, der die Projektion fortschreibt, trägt die betroffenen Codes.
Plus Formatierungsregel (schließende Klammer) an sieben Stellen und `@NullMarked` am Test.
Detail-Plan: `2026-09-10-fondspreise-schnitt2-ap4-review-fixes.md`.

**Stand 2026-09-10 — AP5.** Die Klammer ist so gebaut, wie *Zwei Server, ein Pool* sie
beschreibt, mit drei Festlegungen, die erst am Code sichtbar wurden:

- **Entscheiden vor Schalten.** Stammdaten- und ASF-Abfragen laufen im Business-Kontext, *bevor*
  irgendein Kontextwechsel passiert; erst die fertigen Entscheidungen werden in sortierter
  Reihenfolge ausgeführt. Der Provider cached je ISIN — ein Lookup aus der offenen
  Postgres-Transaktion heraus würde sonst auf die falsche Datenbank routen.
- **Klammer = zwei `REQUIRES_NEW`.** Außen `withFondspreiseDbContextIsolatedTransactional`
  (Guard-Claim, Zeile bleibt gesperrt), innen das neue
  `withDatabaseContextIsolatedTransactional(businessKey, …)` für den `kurs`-Write. Ein
  `PlatformTransactionManager`, Routing über den Kontext zum Zeitpunkt des ersten Statements —
  dasselbe Muster, das der Diff-Job schon für jobSystem/fondspreise nutzt.
- **Erstanspruch-Rennen.** `claimIfNewer` = 0 und kein Guard-Satz → Insert + `flush` in derselben
  Transaktion; kollidiert er mit einem parallelen Erstanspruch, wirft die Klammer eine
  `DataIntegrityViolationException` und wird genau einmal wiederholt — beim zweiten Mal
  entscheidet `claimIfNewer` regulär.

`KursRepository` löscht jetzt per JPQL-Bulk statt abgeleiteter Methode: Hibernate flusht Inserts
vor Deletes, der Re-Insert desselben Schlüssels hätte das Delete sonst überholt — auf Sybase mit
`ignore_dup_key` still, auf Postgres/H2 mit PK-Verstoß.

**Entscheidung User 2026-09-10: keine Fondsaktivierung im Preispfad** (D10). Ein zunächst gebauter
`FondsAktivierungService` ist wieder entfernt; an der Stelle steht ein TODO.

**Stand 2026-09-10 — AP6.** Die Projektion hat mit `LetztePreiseService` einen eigenen Besitzer;
das Fortschreiben aus AP5 ist dorthin gewandert (Sync-Service und Rebuild rufen dieselbe `advance`).

- **Rebuild** (`PreismeldungSyncService.rebuildProjection`) läuft denselben Entscheidungspfad wie
  `sync` — genau das macht ihn zum Konsistenzcheck: die neu hergeleitete Projektion ist die, die die
  inkrementelle halten müsste. Er fasst nur die Projektion an, nie `kurs`.
- **Ankunftsreihenfolge:** der Rebuild nimmt die Lieferungen als bereits sortierte `DeliveryRef`-Liste
  entgegen, weil die Ankunftszeit am Job hängt — den persistiert erst AP7. Bis dahin ist der Rebuild
  voll testbar (Test übergibt die Reihenfolge), die Job-Verdrahtung ist die Naht zu AP7.
- **Seed:** die Schreibhälfte (`LetztePreiseService.seed(rows, seedTime)`) ist da, idempotent (ein
  Schlüssel, den die Kette schon hält, bleibt unberührt) und getestet. Der **Leser** aus
  `kurs..tmp_if_last` ist bewusst **nicht** gebaut: dev-tools laufen single-DB
  (`DatabaseContextKey.SINGLE`), der Seed spannt aber Sybase (lesen) und Postgres (schreiben) — das
  braucht Cross-DB-Routing und gehört dorthin, wo es das gibt (Migrationsläufer / Parallelbetrieb),
  nicht in ein single-DB-Tool. Als offener Punkt im Tracker.

**Stand 2026-09-10 — AP7.** Die Klammer läuft jetzt end-to-end im Diff-Job: der Execution-Service
hängt Stufe 2 zwischen Inbox-Schreiben und Result-Bundle, im Business-Kontext des Jobs.

- **`angekommen_am`** liegt am Job und wird bei der Submission aus der **Job-DB-Uhr**
  (`SELECT CURRENT_TIMESTAMP` über den jobSystem-Kontext) gesetzt — eine Uhr für beide Server,
  stabil über Retries (der Wert steht am Job, jeder Retry liest denselben). Zusätzlich trägt die
  Spalte `default now()`: das backfillt Bestandszeilen und ist der Fallback. Ein **Repeat** würde
  hier den Wert des Originals durchreichen (Builder kann es) — einen Repeat-Pfad gibt es für diesen
  Job-Typ noch nicht, daher nur vorbereitet, nicht verdrahtet.
- **Zähler** `synced/skipped/veto` schreibt `updateResult` mit; `db_diff` bleibt null bis AP8.
- **`sync-report.txt`** kommt ins Result-ZIP: Kopfzahlen plus je auffälligem Preisschlüssel eine
  Zeile (Veto, Skip, von späterer Lieferung überholt). Das ist der sichtbare Ort für den
  Ausschüttungs-Veto-Befund aus D6.

**Stand 2026-09-10 — AP8.** Diff-Ebenen 3 (DB-Stand `kurs`) und 4 (Projektion `letzte_preise`
gegen `kurs..tmp_if_last`) laufen nach dem Sync im Execution-Service; das Ergebnis geht als
`db-diff.txt` ins Result-ZIP und als `db_diff_count` an den Job.

- **`PreismeldungDbDiff`** (Domain, rein) vergleicht zwei Schlüssel→Wert-Maps; der Service flacht
  beide Seiten ab und lässt bekannte Abweichungen aus dem Vergleichswert: `guelt` fehlt (D8), und
  Preise werden **numerisch** verglichen, damit der gelieferte String der Projektion zum
  Legacy-Float von `tmp_if_last` passt.
- **Testrealität:** `business` und `legacyBusiness` zeigen im Test auf dieselbe H2 — Ebene 3 ist
  damit ein echter Selbstvergleich (0). Ebene 4 vergleicht zwei verschiedene Tabellen; der E2E-Test
  seedet `tmp_if_last` passend, sodass auch dort 0 herauskommt. Der belastbare Beweis der
  Diff-Logik sind die reinen Domain-Tests (identisch→0, abweichend→N, nur-eine-Seite→N). Ein echter
  Unterschied Neu↔Alt braucht das Dual-DB-Profil (AP9).
- **`pool_if_kurs`-Kontrolle verschoben:** eine Kontrolle für eine tote Tabelle (D2), die im
  Selbstvergleich trivial 0 ist — Aufwand (eigene read-only Entity) ohne Aussage bis der echte
  Dual-DB-Parallelbetrieb steht. Im Tracker vermerkt.

**Stand 2026-09-11 — Designreview mit dem User.** Drei Fragen standen an: warum eine eigene Tabelle
`letzte_preise` statt `tmp_if_last`, das DB-Setup im Parallelbetrieb, und was der Diff-Job
eigentlich vergleicht. Ergebnis sind die Entscheidungen oben und D11–D14; die Befunde aus dem
Legacy-Code, die dabei herausgekommen sind:

- **Der einzige lebende Unterschied zwischen `tmp_if_last` und `kurs` ist die Preiswährung.** Ein
  Preis in einer Währung ≠ Fondswährung passiert den Eingang (`tax_code.isinwaehrung` ist auf GAST
  für `R`/`E`/`Z`/`S`/`S2`/`S3` `N`, nur LMT- und Steuercodes haben `J`), wird im Preisfile mit der
  gelieferten Währung veröffentlicht, aber nicht nach `kurs` geschrieben
  (`preisekennzahl.cpp:2843-2848`); `WriteLastKurse` läuft trotzdem. Die Fileerstellung prüft die
  Fondswährung nirgends.
- **Der `R`-Löschpfad nach `tmp_if_last` ist toter Code.** `DeleteLastKurse`
  (`preisekennzahl.cpp:1849`) ist nur im Header deklariert und wird nirgends aufgerufen; das SQL in
  `DeleteLastKurs` (`:1939`) referenziert obendrein die Spalten `waehrung`/`cod_fliesscode`, die
  `tmp_if_last` nicht hat. Eine `D`-Lieferung löscht also aus `kurs`, lässt `tmp_if_last` stehen —
  der zurückgezogene Preis wird im Lauf-1-Fallback erneut veröffentlicht. Unser „Löschung lässt die
  Zeile unberührt" trifft das effektive Legacy-Verhalten, aber aus dem falschen Grund. Die
  Konzept-Schreiberliste (Entscheidung 9) ist an dieser Stelle falsch.
- **Unbekannte ISIN** als Ableitbarkeitsgrund ist tot (D2); die **Reihenfolge-Semantik** („zuletzt
  verarbeitet" statt „jüngstes Datum") ist der zweite echte Unterschied — den unser Guard ohnehin
  in Richtung `kurs`-Semantik verschiebt.
- **Alle Spalten des `I2`-Preissatzes stehen in `kurs`** (plus `ASF` und `wkn_desc`). `txt_bez`,
  `liefer_id`, `eintragezeit`, `intervall` aus `tmp_if_last` werden gelesen, erreichen das
  Preisfile aber nicht.
- **`kurs` hat außer der Einspielung keinen regulären Schreiber**: `s_ins_kurs_direct` (2005, ohne
  Aufrufer im Repo), `WAEHR_UM` (Euro-Umstellung), der Trigger auf `wkn_desc` (löscht Kurse bei
  Fondslöschung) und `einmal`-Programme. Auf `tmp_if_last` gibt es keine Trigger.
- **Diff-Ebenen 3/4 saßen am falschen Zeitpunkt**: Legacy schreibt `kurs`/`tmp_if_last` im
  Tagesjob-Schritt 4 am Tagesende, wir Minuten nach der Lieferung. Ein Vergleich im Lieferjob am
  selben Tag ist per Konstruktion rot, und „nur berührte Schlüssel" sieht keine Drift.
- **`preis_herkunft` kann nicht Guard der Projektion sein** (Schlüssel enthält `dat_kurs`, D12).

Dazu zwei Punkte, an denen das Konzept sich selbst widerspricht: Entscheidung B wählte die geführte
Tabelle *wegen* der Parallelbetrieb-Vergleichbarkeit und legte sie dann in das DBMS, in dem der
Vergleich am schwersten ist; und Entscheidung M („neue Tabellen nach Postgres") wurde auf eine Tabelle
angewendet, die nicht neu ist. Korrekturen in AP10.

Die Fragen an die Fachabteilung (Währung ≠ Fondswährung, gelöschte Preise, Zweck des Fallbacks)
stehen in `2026-09-11-fondspreise-fachabteilung-fragen-fallback-waehrung.md`; die Kontrollabfragen für
GAST als **V6** im SQL-File.

**Stand 2026-09-11 — AP11 umgesetzt.** Gesamtbuild grün; `PreismeldungSyncServiceTest` 13 (H2),
`PreisMeldungDiffJobTest` 3, `PreismeldungSyncGuardTest` 14 (H2 + Postgres), neu
`TmpIfLastRepositoryTest` 3 × alle drei DBMS (Sybase-Testcontainer inklusive, `char`-Padding
geprüft). Drei Festlegungen, die erst am Code fielen:

- **`db_diff_count` ist aus V066 gestrichen**, keine Folge-Migration: die Flyway-Skripte des
  Feature-Branch sind nirgends ausgerollt (User 2026-09-11). Entity, Repository und Execution-Service
  kennen den Zähler nicht mehr; `PreismeldungDbDiffService` ist gelöscht, `PreismeldungDbDiff` +
  Result bleiben im Domain-Modul für den generischen Vergleich.
- **Rebuild = Replay durch den Guard, ohne vorheriges Löschen** (Abweichung vom AP11-Wortlaut
  „Schlüssel ersetzen"). Eine gespeicherte Zeile, die ihren Schlüssel schon gewinnt, kann nur von
  einem legitimen Gewinner stammen; sie vorher zu löschen würde eine Seed-Zeile, deren Preisdatum
  alle Inbox-Lieferungen schlägt, durch eine ältere Korrektur ersetzen. Der Replay repariert
  fehlende oder zurückhängende Zeilen auf beiden Seiten und lässt Vor-Go-live-Zeilen stehen
  (Tests `givenDeliveryNeverSynced…`, `givenProjectionRowFromBeforeGoLive…`).
- **Guard-Seed-Leser gebaut**: `LetztePreiseService.seedGuardFromTmpIfLast(businessDbKey, seedTime)`
  liest `tmp_if_last` im business-Kontext und spiegelt nach `letzte_preise` (idempotent, `job_id`
  null). Entscheidung User 2026-09-11, nach dem Umbau: **der Seed wird nicht ausgeführt** (D12);
  der Code bleibt vorerst liegen.

Weiter: die Projektions-Klammer sitzt in `LetztePreiseService.recordLastPrice` (außen
`letzte_preise`-Update/Insert + `flush`, innen `tmp_if_last` delete-then-insert im business-Kontext,
Erstanspruch-Wiederholung bei `DataIntegrityViolationException`); `eintragezeit` beider Seiten ist die
Ankunftszeit der Lieferung in Wiener Zeit; `cleanupEndedFunds` löscht beidseitig und fragt die
Fondsenden in 1000er-Blöcken ab, damit die IN-Liste auf Sybase auch für die volle Projektion trägt.
`TmpIfLast` trägt jetzt `liefer_id`, `eintragezeit`, `intervall` und trimmt `cod_ex`/`txt_bez`.

**Abweichungen vom Plan, bewusst:**

- Die Properties liegen im **Service-** statt im Domain-Modul: `ifas-domain-fondspreise` hat nur
  `spring-core`, und dessen Schlankheit für `@ConfigurationProperties` aufzugeben wäre der
  schlechtere Tausch. Die Domain bekommt die Werte in AP4 als Record gereicht.
- **Ein Flyway-File je Baum** statt eines pro Tabelle (Vorgabe User 2026-09-08).
- **`del_protokoll` entfällt ersatzlos** — Begründung unter D6.

**Zusätzlich erledigt (Schnitt-1-Code, weil AP4 die Schwesterklasse danebenlegt):**

- Aus der einen Klasse `PreismeldungEingang` sind **drei** geworden:
  - `PreismeldungEingangProcessor` — **Instanzklasse**, kein `@UtilityClass`. Der
    `PreismeldungStammdatenProvider` steckt im Konstruktor statt in jedem Aufruf; eine Instanz
    bedient eine Lieferung, die Stammdaten-Momentaufnahme steht bei der Konstruktion fest.
    `-Processor` bedeutet im Repo durchgehend „Objekt mit Verarbeitungsrolle"
    (`CsvMessageProcessor` und seine Implementierungen), nie statischer Utility-Sack.
  - `PreismeldungFileChecks` (`@UtilityClass`) — Magic Bytes, leere Zeile, Header-Zeile,
    Spaltensplit, Spaltenzahl des Format 3: alles, was ohne Fachwissen über den Inhalt entscheidet.
  - `PreismeldungLineValidations` (`@UtilityClass`) — die Regeln B3–B20. Gibt ein
    `LineCheckResult` zurück statt in eine übergebene Liste zu schreiben; damit ist das
    `@SuppressWarnings("NullAway")` weg. `Candidate` ist package-private eigenständig.
- Utility-Klassen tragen `@UtilityClass` und stehen im Plural — die Hauskonvention
  (`Instants`, `CsvValueFormatters`), 193 Dateien im Repo nutzen die Annotation.
- `PreismeldungStammdatenProvider.ofStatic` gibt jetzt einen benannten nested
  `record Static implements PreismeldungStammdatenProvider` zurück, genau wie
  `ErmittlungsvorgabeProvider.ofStatic` → `record Static`. Die Alias-Map ist damit eine benannte
  Komponente statt eines Closures in einer anonymen Klasse. Signatur unverändert, Aufrufer
  unberührt. **Befund dazu:** `ofStatic` **im** Produktions-Interface ist Hausmuster (24
  Verwendungen im STM-Bereich, aus Produktion und Tests) — es gehört nicht herausgezogen.
- Bezeichner auf Englisch gezogen; Deutsch bleibt nur für Fachbegriffe
  (`isin`, `waehrung`, `preisdatum`, `aktion`, `wert`, `fondsbezeichnung`, `lmtStichtag`).

## Festgelegte Designdetails (im Code verifiziert)

### D1 — Was Stufe 2 aus dem Legacy erbt

Vorbild ist `cPreiseKennzahlen::MakeTmpPreise` (`preisekennzahl.cpp:2656-2935`), je Gruppe aus
(ISIN, Preisdatum, Währung, Aktion), in dieser Reihenfolge:

| # | Regel | Legacy | im Neusystem |
|---|---|---|---|
| 1 | Stammdaten lesen | `cFondsBasis::Read` | Provider erweitern (AP1) |
| 2 | TEST-ISIN (`cod_art_f='TEST'`) → verwerfen | `:2702` | portieren |
| 3 | C-Plan (`cod_art_f='C-PL'`), AIF (`'AIF'`), Liquidation (`status='L'`) → je Property | `:2710-2731` | portieren, Properties D7 |
| 4 | ISIN unauflösbar → `pool_if_kurs` | `:2925-2934` | **entfällt** (D2) |
| 5 | Preiswährung ≠ Fondswährung → **nicht** nach `kurs`, aber in die Projektion; bei `D` gar nichts (`WriteLastKurse` nur im Nicht-`D`-Zweig) | `:2843-2850`, `:2862/:2879` | portieren |
| 6 | vorläufiger Fonds (`status='V'`) mit `R` → `VorlFondsAktivieren` | `:2747-2782`, `fondsbasis.cpp:3882` | **entfällt** — Fondsaktivierung ist ein eigenes Feature der Stammdaten (siehe D10); die Preise eines `V`-Fonds werden geschrieben wie alle anderen |
| 7 | `N`/`U`: je Preiscode delete-then-insert in `kurs`, `guelt = getdate()` | `WriteKurse:719-800` | portieren |
| 8 | `D`: löschen; ist `R` dabei → Ausschüttungs-Veto, sonst löschen (Legacy zusätzlich `del_protokoll`) | `:2519-2560`, `DeleteKurseReally:1443` | portieren **ohne** `del_protokoll` (D6) |
| 9 | Korrektur-Erkennung: `Stichtag > Preisdatum` **und** Kurse betroffen (Solva allein zählt nicht) | `CheckKorrektur:2990` | erkennen und **vormerken**; die Nachrechnung selbst ist Schnitt 6 |
| 10 | Projektion fortschreiben | `WriteLastKurse:1226` | D4 |

Zwei Punkte, die leicht übersehen werden:

- **Solva zählt mit.** `WriteKurse` läuft über `lAnzPreise` — „Schleife über alle Kursfelder (auch
  Solva)". `S`/`S2`/`S3` gehen also nach `kurs`, nur `L1`/`L2`/`L3` nicht: LMT wird laut Ist-Analyse
  8.1 ausschließlich validiert und nirgends ausgeliefert. LMT-Zeilen bleiben in der Inbox stehen —
  das ist der offene Punkt G, kein Schnitt-2-Thema.
- **`kurs` hat `with ignore_dup_key`** auf `kurs_1_index` (`I_kurs.cr`). Ein doppelter Insert wird
  von Sybase still verworfen, nicht abgelehnt. Unser Upsert muss darum wie Legacy explizit
  delete-then-insert je Preiscode machen; ein vergessenes Delete bliebe sonst unbemerkt beim
  **alten** Wert stehen.

### D2 — `pool_if_kurs` wird nicht portiert

Belegt am 2026-09-08 gegen den Quelltext:

- Zweck (Kommentar in `Kurs/tabledefs/pool_i_k.cr:7`, 1994): „Hilfstabelle in die alle Kurse
  eingetragen werden, die nicht in `kurs` eingetragen werden konnten." Ein Dead-Letter-Postfach mit
  `txt_bez` (gelieferte Fondsbezeichnung) als einzigem Hinweis für den Menschen.
- **Kein Leser** in der gesamten Legacy-Codebasis; berührt nur von `ISIN_UPD.CPP` (Massen-Umbenennung)
  und den Rechte-/Spaceused-Skripten.
- Beide Schreibpfade sind zu: unbekannte ISINs verwirft schon die Eingangsprüfung
  (`ERR_ISIN06`, Zeile wird ignoriert) — die Zeile erreicht die Einspielung nie; und der
  Vorl-Fonds-Pfad prüft in `preisekennzahl.cpp:2760-2762` `nRet` statt `nRet2`, also den
  Rückgabewert von `ReadTmpKurse` (Anzahl gelesener Sätze, `:586`) statt das Ergebnis der
  Aktivierung — der Zweig feuert nie.
- Empirisch deckungsgleich: kein Schreiber seit 2012-03-30 (Voranalyse V2).

Konsequenz: kein Pool-Zweig in der Sync-Stufe. `pool_if_kurs` läuft trotzdem in **Diff-Ebene 3** als
Kontrolltabelle mit — beide Seiten müssen unverändert bleiben; das ist der Beweis unter
Produktivlast und kostet eine Zeile Konfiguration.

### D3 — Entity- und Modulverortung

| Tabelle | DBMS/Kontext | Modul | Begründung |
|---|---|---|---|
| `kurs..kurs` | Sybase, **business** | `ifas-persistence-inv` | dort liegen bereits die `catalog="kurs"`-Sybase-Business-Entities (`Kest98`, `Absicht`, `LieferStatus`, `CheckCode`) |
| `kurs.preis_herkunft` | Postgres, **fondspreise** | `ifas-persistence-fondspreise` | neue Business-Tabelle |
| `kurs.letzte_preise` | Postgres, **fondspreise** | `ifas-persistence-fondspreise` | seit 2026-09-11 **Guard + Spiegel** der Projektion (D12), nicht mehr die Projektion selbst |
| `kurs..tmp_if_last` | Sybase, **business** | `ifas-persistence-inv` | Legacy-Tabelle, vom Neusystem Legacy-getreu geschrieben (D11); die read-only Entity `TmpIfLast` (AP8) wird schreibend |

Ausdrücklich **nicht** nach `ifas-persistence-fondspreise` gehört `Kurs`: dessen Invariante ist
„eigene DB, der Aufrufer setzt den Fondspreise-Kontext" (so dokumentiert seit dem
`FondspreiseBasedataCreator`), `kurs..kurs` liegt aber im Business-Kontext. Alternative wäre ein
eigenes Modul `ifas-persistence-kurse` — für eine Entity nicht gerechtfertigt.

### D4 — Guard und Klammer-Transaktion

```
preis_herkunft   PK (num_wfs_ku, dat_kurs, cod_fliesscode, waehrung)
                 → job_id UUID, angekommen_am timestamp with time zone
```

Der PK ist exakt der unique clustered index von `kurs` (`I_kurs.cr`:
`num_wfs_ku, dat_kurs, cod_fliesscode, waehrung`) — ein Guard-Satz je `kurs`-Zeile.

Ablauf je Preisschlüssel, Schlüssel in **sortierter** Reihenfolge:

```sql
update preis_herkunft set job_id = :job, angekommen_am = :arrival
 where <schlüssel> and angekommen_am < :arrival
-- rowcount 1 → wir sind die Neueste → kurs schreiben
-- rowcount 0 → insert versuchen; bei PK-Konflikt Update wiederholen;
--              verliert es erneut, hat eine Neuere gewonnen → still überspringen
```

Klammer: die Postgres-Transaktion mit dem Guard-Update bleibt offen, bis der Sybase-Write
committet ist. Eine Klammer **pro Preisschlüssel**, nicht pro Datei. Muster im Haus:
`WorkQueueService.claimItem` ist dasselbe bedingte Update („Cluster-safe: optimistic concurrency"),
nur mit anderem Prädikat.

`angekommen_am` muss aus **einer** Uhr kommen: neues Feld am Job, **DB-seitig** per Postgres
`now()` beim Insert befüllt (nicht `OffsetDateTimes.now()`, das ist Applikationszeit auf zwei
Servern). Ein wiederholter Job erbt die Ankunftszeit seines Originals; Gleichstand deterministisch
über `job_id` brechen.

### D5 — `letzte_preise` (Projektion, B3)

> **Geändert 2026-09-11:** Die Projektion selbst liegt wieder in `kurs..tmp_if_last` (D11);
> `letzte_preise` ist Guard und Spiegel (D12). Die Legacy-Fakten unten gelten unverändert. Der
> **Seed** aus dem Altsystem entfällt (Voll-Sync zum Go-live), ebenso der Guard-Seed (D12,
> entschieden 2026-09-11).
> Ergänzung zur Schreiberliste: der `R`-Löschpfad (`DeleteLastKurse`) ist toter Code — Löschungen
> erreichen `tmp_if_last` nie, siehe *Stand 2026-09-11*.

Legacy-Fakten, im Code nachgelesen (`WriteLastKurse`, `preisekennzahl.cpp:1226-1330`):

- Delete-vor-Insert-Schlüssel `(num_okb, cod_waehrung, cod_preiscode, cod_ex='N')` — **ohne
  `dat_kurs` und ohne jeden Datumsvergleich**. Der zuletzt verarbeitete Satz gewinnt, auch wenn sein
  Preisdatum älter ist.
- `cod_ex` hart `'N'` → Löschsätze erreichen die Tabelle nie.
- Keine eigenen Ausschlüsse; die drei `continue` für C-Plan/AIF/Liquidation liegen im Aufrufer
  (`c_preise.cpp:113-132`).
- Der Aufruf liegt **außerhalb** von `if (nRet == 1)`, hängt also nicht am Erfolg des
  `kurs`-Writes — deshalb trägt die Tabelle Werte, die `kurs` nie sieht (Währungsabweichung).

**Unser Guard ist strenger:** lexikografisch über `(preisdatum, angekommen_am)`, damit eine Korrektur
zum gleichen Preisdatum gewinnt und eine ältere Lieferung nicht den jüngeren Preis verdrängt. Weil
`letzte_preise` in Postgres liegt, ist das ein einzelnes bedingtes Update — keine Klammer nötig.

Das ist eine **bewusste Verhaltensabweichung** und muss als solche in Diff-Ebene 4 geführt werden.

> **Konzept-Korrektur (klein, in AP10):** zwei Stellen des Konzepts behaupten, Legacy schreibe
> `tmp_if_last` „nur wenn Preisdatum neuer" (Abschnitte *Zwei Server, ein Pool* und
> *Reproduzierbarkeit*). Das stimmt nicht — es gibt gar keinen Datumsvergleich. Die Ist-Analyse
> (5.2, Punkt 8) hat es richtig.

**Seed:** einmaliger Migrationsschritt aus `kurs..tmp_if_last` des Altsystems (legacyBusiness,
lesend) → `letzte_preise`, mit synthetischem `angekommen_am` = Seed-Zeitpunkt. Ohne ihn wäre der
B3-Diff 65 Tage lang rot. Umfang laut Voranalyse V3: 30.668 Zeilen (14.604 im 65-Tage-Fenster),
`cod_ex` durchgehend `'N'`.

**Rebuild:** Neu-Herleitung der Projektion aus der Inbox in Ankunftsreihenfolge. Ist gleichzeitig
Reparaturwerkzeug (für den `FAILED`-Job-Fall aus dem Konzept), Konsistenz-Testfall und
Parallelbetrieb-Vergleich.

### D6 — Ausschüttungs-Veto (E); kein `del_protokoll`

**Veto:** portiert wie Legacy (`preisekennzahl.cpp:2539-2547`) — liegt zum Preisdatum eine
Ausschüttung vor, wird die `R`-Löschung nicht ausgeführt. Der Statusfilter ist dabei korrekt:
`cAusschuettung_Split::Read` hat den Default-Parameter `szAussch_statusP = "A"` (`fondsbasis.h:313`)
und hängt `and aussch_status = 'A'` an (`fondsbasis.cpp:414-424`). Kein `order by`-Problem wie bei
`ReadAusschuettung`.

**Neu gegenüber Legacy — der Befund wird sichtbar** (User-Auflage): Legacy schreibt nur eine Zeile
ins Programm-Logfile, im Quelltext steht `// ????`. Bei uns bekommt er drei Orte:

1. eine Zeile im neuen `sync-report.txt` des Result-Bundles (Schlüssel, Grund, betroffene Codes),
2. einen Zähler `vetoCount` am Job,
3. **später** eine Zeile im Sammelreport (Schnitt 4) — dort sieht ihn die Fachabteilung. Als offener
   Punkt im Tracker vermerken, nicht in diesem Schnitt bauen.

Entscheidung User 2026-09-08: Punkt 1 und 2 reichen **vorerst**; eine persistente Befundtabelle
(„wie oft passiert das eigentlich?", ohne Filedurchsicht) bleibt als spätere Optimierung offen und
geht so in den Tracker.

Eine Rückmeldung an den Lieferanten ist bewusst **nicht** vorgesehen: das Rückmeldungs-ZIP ist zum
Zeitpunkt der Sync-Stufe schon erzeugt (Stufe 1 „parsen, prüfen, antworten"). E2 würde entweder die
Rückmeldung bis nach Stufe 2 verzögern oder eine zweite Nachricht einführen — beides ist eine
Änderung am Lieferketten-Schnitt und gehört in dasselbe Gespräch wie 15./H.

**`del_protokoll` wird nicht geschrieben** (Entscheidung User 2026-09-08, nach Recherche am
Quelltext). Die generische Lösch-Protokolltabelle (`Ifas/tabledef/del.cr`, `del_code = "kurs1"`) hat
auf der Fondspreis-Seite keinen nachweisbaren Verbraucher:

- **Kein Leser** im gesamten Legacy-Code. Die vier Fundstellen sind alle Schreiber
  (`preisekennzahl.cpp`, `m_fp_rec.CPP`, `asfkennzahl.cpp`, `m_deleteFonds.cpp`); die
  `select`-Treffer sind `max(id)+1`-Abfragen derselben Schreiber.
- Die einzige lesende Stelle ist die Stored Procedure `s_exp_del`
  (`Ifas/tabledef/export/s_exp_del.cr`), die aus den Key/Value-Paaren XML-Delete-Sätze baut —
  **aufgerufen wird sie nirgends im Repository**.
- IFASNXT holt die Preise per SSIS direkt aus `kurs`
  (`run_ifasnxt_update` → `http://…/CallSSIS/api/Call/kurs`), nicht über das Protokoll. Der im
  Kopfkommentar desselben Scripts erwähnte Parameter `DEL` („Deletes durchfuehren") ist im
  `switch` **nicht implementiert** und liefe in den `exit 1`.
- `Del_Protokoll` ist per Default `0` (`c_basisparam.cpp:136`). Solange der Produktivwert nicht
  belegt ist, wäre Schreiben also nicht einmal eine Portierung, sondern **neues Verhalten** — und
  es erzeugte eine Diff-Abweichung auf jeder Löschung statt eine zu vermeiden.
- Die Konfiguration in `ins_del.cr` zeigt `kurs1` zwar aktiv (`"J"`), die Preiscode-Kinder
  `R`/`B`/`E`/`Z`/`C`/`F`/`Q`/`T` aber alle inaktiv (`"N"`). Produktiv hat `del_code` nur
  **13** von 26 Zeilen des Install-Skripts (`Ifas/admin/spaceused/csv/ifas.csv`) — welche, ist
  offen.

**Wieder eingebaut wird es**, wenn die Datenbeschaffung `Del_Protokoll = 1` zeigt *und* ein
Verbraucher benannt ist. Der Aufwand ist gering und lokal: Entity + Repository in
`ifas-persistence-inv`, `PkSequence.DEL_PROTOKOLL_ID` plus Seeding-Quelle, DDL in beiden
Migrationsbäumen, ein Property und der Schreibaufruf im Löschpfad.

### D7 — Properties statt INI

Neue Klasse `FondspreiseProperties`, Prefix `ifas.fondspreise` (Muster: `StmValidationProperties`,
`ifas.stm.validation`). **Die Namen beschreiben die Wirkung, nicht den INI-Key** — der Legacy-Key
steht als Brücke im Javadoc. Für Schnitt 2:

| Property | Default | Legacy-Key | Fundstelle |
|---|---|---|---|
| `store-c-plan-prices` | `true` | `InsPreiseCPlan` | `IFASTOOL.CPP:904` |
| `store-aif-prices` | `true` | `InsPreiseAIF` | `IFASTOOL.CPP:930` |
| `store-fonds-in-liquidation-prices` | `true` | `InsPreiseFondsInLiquidation` | `IFASTOOL.CPP:1000` |
| `fallback-price-max-age-days` | `65` | `Tage_TmpIfLast` | `M_FP_DLD.CPP:457` |
| `ended-fund-retention-days` | `35` | `Tage_TmpIfLast_Beendete` | `M_FP_DLD.CPP:466` |

Nicht als Property: historische Stichtage (`StetigeVolaAb`, `PerfYtdFbY1Neu`, `daNoEuQust`,
`lRange4Preis`) bleiben Konstanten im Code — sie datieren Verhaltensänderungen für die
Vergangenheit, und als Property lädt man ein, sie „aufzuräumen". Ebenfalls nicht: Infrastruktur
(`UseBCP`, `IfasServer`/`IfasDB`, `Sql2Log`, `Debug`).

Die produktiv gesetzten Werte sind **nicht im CPP-Repo** — die eingecheckte `CONFIG.INI`
(`Ifas/scripts_mft/at/`, 19 Zeilen) ist die MFT-Script-Variante ohne Fondspreise-Keys, `PREIS_DLD.INI`
fehlt ganz. Die Defaults oben stammen aus den Leseaufrufen selbst und sind damit belastbar; ob der
Betrieb einen überschreibt, bleibt offen (Tracker).

### D8 — Diff-Ebenen 3 und 4

> **Aufgehoben 2026-09-11 (D13):** Die Ebenen 3 und 4 werden aus dem Job wieder ausgebaut. Der Text
> unten beschreibt den Stand AP8 und bleibt als Begründung für den generischen Tabellenvergleich stehen.

`DatabaseCompareService` ist **kein** generischer Tabellenvergleich — er vergleicht STM-Ids
(`dbcompare/DatabaseCompareService.java:41`). Für Schnitt 2 also schlüsselgenau statt
Tabellen-Dump:

- **Ebene 3 (DB-Stand):** die von *dieser* Lieferung berührten Preisschlüssel im business-Kontext
  gegen dieselben Zeilen im legacyBusiness-Kontext — `kurs` und `pool_if_kurs` (Letzteres als
  Kontrolle auf „beidseitig unverändert", D2).
- **Ebene 4 (Projektion):** `letzte_preise` gegen `kurs..tmp_if_last` für die berührten
  (ISIN, Währung, Code).

Bekannte Abweichungen ins `PreisMeldungDiffSetting` (Muster: die bestehenden
`ignoreInfoDelMessages`/`ignoredMessageCodes`):

| Abweichung | Grund |
|---|---|
| `del_protokoll` bleibt auf unserer Seite leer | wir schreiben es nicht (D6); bei Legacy-Default `0` schreibt es dort ebenfalls niemand |
| `guelt`-Zeitstempel | wir schreiben zur Lieferzeit, Legacy am Tagesende |
| Projektion bei zwei Lieferungen mit fallendem Preisdatum | unser Guard ist strenger als Legacy (D5) |

### D9 — Kontexte je Arbeitsschritt

| Schritt | Kontext | Helper |
|---|---|---|
| Job/Input laden, Ergebnis schreiben | jobSystem | `withJobSystemDbContext` |
| Stammdaten (INV, WKN, HWA, tax_code) | business | Aufrufer-Kontext |
| Guard + Projektion | fondspreise (Postgres) | `withFondspreiseDbContextTransactional` |
| `kurs` | business (Neusystem-Sybase) | `withDatabaseContextTransactional(setting.databaseContext())` |
| Projektion `tmp_if_last` | business (Neusystem-Sybase), **innerhalb** der `letzte_preise`-Klammer | `withDatabaseContextIsolatedTransactional(businessKey, …)` (D12) |
| ~~Diff-Gegenseite~~ | ~~legacyBusiness, nur lesend~~ | entfällt mit D13 — der Job liest das Altsystem nicht mehr |

### D10 — Fondsaktivierung ist kein Preis-Thema

Legacy aktiviert einen vorläufigen Fonds (`INV.status='V'`) auf **zwei** Wegen: im Preispfad
(`VorlFondsAktivieren` aus `MakeTmpPreise`, `preisekennzahl.cpp:2759`) und über die Aktion
`isin_aktivieren` (`aktionen.e -Aisin_aktivieren`, `run_isins_aktivieren.csh`, seit 2018-12-12),
die täglich alle `V`-Fonds mit erreichtem `fonds_beginn` aktiviert. Seit 2018 ist die Aktion der
maßgebliche Pfad; der Preispfad feuert nur noch, wenn ein Preis vor der Aktion desselben Tages
eingespielt wird — bei Einspielung als Tagesjob-Schritt 4 praktisch nie. Die beiden Kopien sind
auseinandergedriftet (Weihnachtsregel 24.12.–1.1. → 2.1., `liefer_status` ja/nein, Idempotenz,
WDBO-Notify).

Die Sync-Stufe schreibt darum **keine Stammdaten**: die Preise eines `V`-Fonds landen in `kurs` und
`letzte_preise` wie alle anderen, der Status bleibt unberührt. Die Fondsaktivierung wird ein eigenes
Feature der Stammdaten-Domäne, das seine Arbeit unabhängig von Preismeldungen korrekt abliefert —
mit der Klärung, welche Legacy-Variante gilt und wem `INV.status`/`fonds_beginn` gehören (Tracker).
Parallelbetrieb-Folge in Schnitt 2: keine; `INV` ist keine Diff-Tabelle der Ebenen 3/4.

### D11 — Die Projektion bleibt `kurs..tmp_if_last` (Neusystem-Sybase), Legacy-getreu

Entscheidung User 2026-09-11. Auslöser: KUPL und/oder KMS lesen möglicherweise direkt aus der Tabelle
— dann muss sie dort aktuell sein, wo diese Anwendungen sie nach dem Umstieg finden, in Legacy-Form.
Dazu drei Gründe aus dem Parallelbetrieb-Setup: der Voll-Sync zum Go-live bringt die Tabelle gefüllt
mit (kein Seed), die Divergenz-Beobachtung „alle vom Neusystem geschriebenen Sybase-Tabellen" erfasst
sie ohne eigenen Adapter, und die Sybase-Migration 2027 nimmt sie ohnehin mit. Ob die Tabelle
überhaupt gebraucht wird, klärt die Fachabteilung (Tracker O/P); bis dahin gilt:

| Regel | Legacy | im Neusystem |
|---|---|---|
| Schlüssel des Ersetzens | delete `(num_okb, cod_waehrung, cod_preiscode, cod_ex='N')`, dann insert — **ohne** `dat_kurs` | identisch: delete-then-insert je Code. **Kein** Upsert über den PK, der enthält `dat_kurs` — ein neues Datum ergäbe eine zweite Zeile |
| `cod_ex` | hart `'N'` | hart `'N'` |
| `num_kurs` | `float` | Float aus dem gelieferten Wert; die exakte Dezimaldarstellung bleibt im Spiegel `letzte_preise.wert` |
| `txt_bez` | gelieferte Fondsbezeichnung | gelieferte Fondsbezeichnung |
| `liefer_id`, `eintragezeit` | aus dem Lieferdatensatz | Lieferant und Eingangszeitpunkt der Zeile |
| `intervall` | aus dem Lieferfeld, seit 2017 leer | `null` |
| `D`-Lieferung | Zeile bleibt (Löschpfad toter Code) | Zeile bleibt |
| Preiswährung ≠ Fondswährung | geschrieben (nicht nach `kurs`) | geschrieben (nicht nach `kurs`) |
| C-Plan / AIF / Liquidation | drei `continue` im Aufrufer, vor beiden Writes | identisch, über die Properties aus D7 |
| Aufräumen | 35 Tage nach Fondsende; Zeilen ohne ISIN | 35 Tage nach Fondsende, auf **beiden** Seiten (Sybase-Zeile und Spiegel) |

Konsequenzen: die read-only Entity `TmpIfLast` (AP8) wird schreibend, bleibt in `ifas-persistence-inv`
neben `Kurs` (D3-Logik: Sybase-Business-Tabelle im Katalog `kurs`); trimmende Getter wie bei `Kurs`
(`char`-Padding). Der **Rebuild** darf die Sybase-Tabelle nicht leeren — sie enthält die Zeilen von
vor dem Go-live, die die Inbox nicht kennt — sondern ersetzt nur die Schlüssel, die er aus der Inbox
herleitet. Flyway: nichts Neues in Sybase; `V067` provisioniert `tmp_if_last` bereits für die Docker-
und H2/PG-Testdatenbanken.

### D12 — Guard der Projektion: die `letzte_preise`-Zeile als Klammer

**`preis_herkunft` scheidet aus.** Sein Schlüssel enthält `dat_kurs`, der Projektionsschlüssel nicht.
Zwei Lieferungen für denselben Fonds mit verschiedenen Preisdaten treffen zwei verschiedene
Guard-Zeilen, beide gewinnen, und für die Projektionszeile gibt es keinen Punkt, an dem sie sich
begegnen. Ein Nachsehen „steht in `preis_herkunft` schon ein jüngeres Datum?" hilft nicht: die Zeile
der parallel laufenden Lieferung ist noch nicht committet und damit unsichtbar; die ältere Lieferung
hielte sich für die neueste. Nur ein bedingtes Update auf **einer** Zeile serialisiert. Außerdem hat
ein Preis in abweichender Währung gar keine `preis_herkunft`-Zeile (kein `kurs`-Write).

**Die Zeile in `letzte_preise` ist dieser Guard bereits** — `updateIfNewer` mit dem Prädikat über
`(preisdatum, angekommen_am)`. Entscheidung User 2026-09-11: die Zeile bleibt **ganz**, mit Werten,
`job_id` und `angekommen_am`; Postgres führt damit einen Spiegel der Projektion, den niemand liest.
Abmagern auf einen reinen Guard ist später möglich.

Ablauf je (ISIN, Währung, Code), Schlüssel sortiert, Muster identisch zur `kurs`-Klammer aus D4:

1. Außen (fondspreise, `REQUIRES_NEW`): bedingtes Update auf `letzte_preise`. Trefferzahl 1 → wir
   sind die Neueste, Zeile bleibt gesperrt. 0 und keine Zeile → Insert + `flush` (Erstanspruch);
   kollidiert er, `DataIntegrityViolationException`, genau eine Wiederholung. 0 und Zeile vorhanden →
   eine Neuere hat gewonnen → überspringen, nichts in Sybase anfassen.
2. Innen (business, `REQUIRES_NEW`): delete-then-insert in `kurs..tmp_if_last` für diesen Code.
3. Innen committen, dann außen.

Fehlerfenster wie bei `kurs`: Absturz zwischen Sybase- und Postgres-Commit lässt `tmp_if_last`
geschrieben und den Guard unmarkiert zurück; der Retry wiederholt den idempotenten Write. Für Preise in
abweichender Währung ist dies die **einzige** Klammer. `kurs`-Klammer und Projektions-Klammer bleiben
getrennt (verschiedene Schlüssel); Reihenfolge je Gruppe: erst alle `kurs`-Schlüssel, dann die
Projektionsschlüssel.

**Guard-Seed — entschieden 2026-09-11: entfällt.** `letzte_preise` startet leer. Der erste Write je
Schlüssel nach dem Go-live verhält sich damit wie Legacy, ab dem zweiten greift unsere Regel; der
Postgres-Spiegel bleibt für nie mehr gelieferte Schlüssel lückenhaft, was niemand liest. Der Code
(`seedGuardFromTmpIfLast`, `importLegacyLastPrices`) bleibt vorerst liegen. Die Abwägung dahinter:

Ohne Postgres-Zeile entscheidet beim ersten Write je Schlüssel nach dem Go-live
niemand über die Reihenfolge — eine Korrektur zu einem älteren Datum überschriebe die vom Altsystem
per Voll-Sync mitgebrachte jüngere Zeile. Das ist exakt Legacy-Verhalten („zuletzt verarbeitet
gewinnt"), aber nicht unsere Regel. Deshalb einmalig nach dem Voll-Sync: `tmp_if_last` der
**Neusystem**-Sybase (business-Kontext) in `letzte_preise` spiegeln, synthetisches `angekommen_am` =
Seed-Zeitpunkt, `job_id` null. Die Schreibhälfte existiert (`importLegacyLastPrices`); der Leser
braucht keinen legacyBusiness-Kontext mehr, nur business + fondspreise — beides Neusystem-Routing.

### D13 — Diff-Ebenen 3 und 4 kommen aus dem Job heraus

Entscheidung User 2026-09-11. Zwei Gründe:

- **Zeitpunkt.** Legacy schreibt `kurs` und `tmp_if_last` im Tagesjob-Schritt 4 am Tagesende, das
  Neusystem Minuten nach der Lieferung. Die Rückmeldungs-Logs des Altsystems liegen dagegen sofort
  vor, der Job kann also am selben Tag laufen — und vergleicht dann unseren frischen Stand mit einem
  Legacy-Stand, der noch nicht existiert. Rot per Konstruktion.
- **Granularität.** „Nur die berührten Schlüssel" sieht weder, was Legacy schrieb und wir nicht, noch
  Drift, die sich über Tage aufbaut.

Stattdessen ein **generischer, geplanter Tabellenvergleich Sybase alt gegen Sybase neu** nach dem
Legacy-Tagesjob, je Szenario konfigurierbar (Tabelle, Schlüsselfenster, bekannte Abweichungen), für
alle Tabellen, die das Neusystem schreibt — `kurs`, `tmp_if_last`, später ASF und Kennzahlen. Keim
dafür ist `DatabaseCompareService` (old/new-Kontext aus Properties, Vergleich noch `todo`);
Vergleichskern kann `PreismeldungDbDiff` (Domain, Schlüssel→Wert) bleiben. Das ist ein eigener Schritt
außerhalb von Schnitt 2 (Tracker, *Weitere Schritte*). `pool_if_kurs` als Kontrolltabelle (D2) wandert
mit dorthin.

Im Job bleibt Ebene 1 (Rückmeldung). Ausgebaut werden der Aufruf von `PreismeldungDbDiffService`,
`db-diff.txt` und die Befüllung von `db_diff_count`; ob die Spalte (V066) per Migration fällt oder
`null` bleibt, ist ein Detail für AP11. `PreismeldungDbDiffService` entfällt, `PreismeldungDbDiff`
bleibt für den generischen Job.

### D14 — Ableitbarkeit aus `kurs`, und warum wir trotzdem Legacy-getreu bleiben

Befund (Details unter *Stand 2026-09-11*): `tmp_if_last` unterscheidet sich von `kurs` in genau zwei
lebenden Punkten — Preise in Währung ≠ Fondswährung stehen nur dort, und „zuletzt verarbeitet gewinnt"
statt „jüngstes Datum". Dazu kommt, dass gelöschte Preise dort stehen bleiben, weil der Löschpfad
toter Code ist. Alles, was der `I2`-Preissatz braucht, steht in `kurs`.

Ob ein Preis, der nie in `kurs` ankam, Fallback-Kandidat sein soll, und ob ein zurückgezogener Preis
erneut veröffentlicht werden darf, sind **fachliche Fragen** an die Fachabteilung (Fragen-File vom
2026-09-11, Tracker O/P). Bis sie beantwortet sind, gilt: **Legacy-getreu** — der Währungsfall wird in
die Projektion geschrieben, `D` lässt die Zeile stehen. Die einzige bewusste Abweichung bleibt der
strengere Guard über `(preisdatum, angekommen_am)`, der im generischen Tabellenvergleich als bekannte
Abweichung zu führen ist. Fällt die Antwort „Fallback aus `kurs` genügt" oder „Fallback wird nicht
gebraucht" (N), verschwinden Projektion, Spiegel, Guard-Seed, Rebuild und Aufräumjob zusammen.

## Arbeitspakete

### AP1 — Stammdaten erweitern — **erledigt**
- `FondsStammdaten` um `numWfsKu` (aus `WknHist.numWfsKu` — existiert schon), `codArtF`
  (`wknDesc.wpArtF.codArtF`, vgl. `InvRepository:287`) und `status` (`Inv.status`) ergänzen, dazu
  die Prädikate `istTestIsin()` / `istCPlan()` / `istAif()` / `istInLiquidation()` /
  `istVorlaeufig()` als Methoden am Record (Legacy: `fondsbasis.cpp:3794-4075`, alle nur
  String-Vergleiche auf `cod_art_f` bzw. `status`).
- `PreismeldungStammdatenService` entsprechend erweitern; `ofStatic`-Testvariante nachziehen.

### AP2 — Properties — **erledigt**
- `FondspreiseProperties` nach D7, registriert wie `StmValidationProperties`; Defaults in
  `application.properties` dokumentiert, nicht dupliziert.

### AP3 — Persistenz + Flyway — **erledigt**
- `ifas-persistence-inv`: `Kurs` (`@Table(catalog="kurs", name="kurs")`, `@IdClass`/`@EmbeddedId`
  über `num_wfs_ku, dat_kurs, cod_fliesscode, waehrung`; Felder `cod_zusatz`, `cod_ex`, `num_kurs`,
  `num_bericht_kurs`, `guelt`) + `KursRepository` (`deleteByKey`, `findByKeys`, `save`).
  Die drei Code-Spalten brauchen trimmende Getter: Sybase füllt `char(2)` auf, `R` kommt als
  `"R "` zurück. Ein `@Convert` hilft nicht — JPA wendet Converter auf `@Id`-Attributen nicht an.
- `ifas-persistence-fondspreise`: `PreisHerkunft` (+ Repository mit dem bedingten
  Guard-Update als `@Modifying @Query`), `LetzterPreis` (+ Repository mit dem
  `(preisdatum, angekommen_am)`-Guard).
- Flyway: **ein** File je Baum, `V065__fondspreise_sync.sql` (Stand heute max V064 in beiden).
  Postgres legt `preis_herkunft`, `letzte_preise` und — nach dem Provisionierungs-Muster
  `V041__archivierung.sql` / `V062__tax_code.sql` — die Legacy-Tabelle `kurs` für lokale/CI-DBs an;
  der Sybase-Baum nur `kurs`, mit Kopfzeile, welche Hälfte dort fehlt und warum. H2 kennt kein
  `timestamptz` — `timestamp(6) with time zone` schreiben (wie V013/V014).

### AP4 — Domain: die Entscheidungslogik — **erledigt**
- `ifas-domain-fondspreise/.../sync/PreismeldungSyncDecisions.java`: reine Funktion je Gruppe →
  `SyncEntscheidung` (Operation `UPSERT` / `DELETE` / `SKIP`, Grund, betroffene Preiscodes,
  `korrekturVorgemerkt`, `vetoGrund`). Kein Persistenzzugriff, Reihenfolge exakt nach D1.
- Provider-Interfaces analog Schnitt 1 (`PreismeldungStammdatenProvider` als Vorbild, inkl.
  `ofStatic` mit benanntem nested `record Static`): `AusschuettungVetoProvider` (existiert zum
  Preisdatum eine aktive Ausschüttung?) und `VorlFondsAktivierung`.
- `SyncErgebnis`: Entscheidungen, Zähler, Veto-Liste, berührte Preisschlüssel.

**Namensvorgabe, damit die Diskussion aus Schnitt 1 sich nicht wiederholt:** zustandslose
Regelklassen sind `@UtilityClass` **im Plural** (`…Decisions`, `…Validations`, `…Checks`); ein
`-Processor`- oder `-Service`-Suffix ist Instanzklassen vorbehalten, die Kollaborateure im
Konstruktor halten. Gibt eine Prüfung Meldungen zurück, dann als Ergebnis-Record — nie über eine
übergebene Liste.

### AP5 — Sync-Service mit Guard und Klammer — **erledigt**
- `service/preismeldung/PreismeldungSyncService`: liest die Inbox-Zeilen des Jobs, gruppiert nach
  Preisschlüssel, sortiert, ruft je Schlüssel die Domain-Entscheidung und führt sie in der Klammer
  aus (D4/D9). Wiederverwendbar für den späteren Live-Job — wie `PreismeldungEingangService`.
- `AusschuettungVetoProvider`-Impl gegen `ifas..ASF` (Filter `aussch_status='A'`, Fonds/Datum/Währung).

### AP6 — Projektion, Rebuild, Seed — **erledigt**; Seed-Leser durch D11 hinfällig, Umbau in AP11
- `LetztePreiseService`: Fortschreiben aus dem Sync-Ergebnis mit dem Guard aus D5;
  `rebuildFromInbox(zeitraum)` in Ankunftsreihenfolge; Aufräumen nach
  `tage-letzte-preise-beendete`.
- Seed-Werkzeug: `ifas-dev-tools`-Kommando (Muster `DatabaseYamlExportTool`), das
  `kurs..tmp_if_last` aus dem legacyBusiness-Kontext liest und `letzte_preise` befüllt. Einmalig,
  idempotent, mit Trockenlauf-Ausgabe.

### AP7 — Job-Erweiterung — **erledigt**
- `PreisMeldungDiffJob`: Feld `angekommen_am` (DB-seitig `now()` beim Insert, D4) sowie Zähler
  `syncedCount`, `skippedCount`, `vetoCount`, `dbDiffCount`; Flyway-Migration dazu
  (`postgres15/V068__preis_meldung_diff_jobs__sync.sql`).
- `PreisMeldungDiffJobExecutionService`: Stufe 2 zwischen Inbox-Schreiben und Result-Bundle
  einhängen (heute `PreisMeldungDiffJobExecutionService.java:107-115`), `sync-report.txt` und
  `db-diff.txt` ins Result-ZIP, Zähler in `updateResult` mitschreiben.
- Wiederholte Jobs erben `angekommen_am` vom Original (`repeatedFromJob`).

### AP8 — Diff-Ebenen 3 und 4 — **erledigt, am 2026-09-11 zurückgenommen** (D13; Ausbau in AP11)
- `PreismeldungDbDiff` (Domain) + Service-Teil, der die Gegenseite im legacyBusiness-Kontext liest;
  bekannte Abweichungen über `PreisMeldungDiffSetting` (D8), Textreport ins Result-ZIP.

### AP9 — Tests (inkrementell, `.claude/rules/testing-conventions.md`)
- **Unit (Domain):** je Regel aus D1 ein Fall mit `ofStatic`-Providern — Ausschlüsse, Währung ≠
  Fondswährung, vorläufiger Fonds, `D` mit und ohne `R`, Veto, Korrektur-Erkennung, LMT wird
  übersprungen.
- **Guard:** zwei Lieferungen für denselben Schlüssel in beiden Reihenfolgen → gleicher Endzustand;
  wiederholter Job verliert am Prädikat; Insert-Konflikt-Pfad.
- **Projektion:** Guard über `(preisdatum, angekommen_am)`; Rebuild aus der Inbox reproduziert den
  fortgeschriebenen Stand exakt (der Konsistenz-Testfall aus dem Konzept).
- **Integration** (`PreisMeldungDiffJobTest` erweitern): Lieferung → Inbox → `kurs`-Zeilen;
  Idempotenz (Job zweimal → identischer Stand); Löschlieferung mit und ohne Ausschüttung;
  mindestens ein Multi-DB-Fall (`kurs` gegen H2/PG/Sybase, `@TestTemplate` wie bisher).
- **Testdaten:** `ifas-test-data` um einen `KursTestdataCreator` ergänzen; ASF-Seed für den
  Veto-Test.

### AP10 — Doku + Tracker
- Konzept: die beiden falschen „nur wenn Preisdatum neuer"-Stellen korrigieren (D5); `pool_if_kurs`
  in Entscheidung 8 als „nicht portiert, mit Begründung" nachziehen; Deck neu erzeugen.
- Tracker: Schnitt-2-Zeile auf den Detail-Plan verlinken; die Klärung „`pool_if_kurs` portieren?"
  mit dem Befund aus D2 schließen; neue offene Punkte: Veto-Zeile im Sammelreport (Schnitt 4),
  produktive INI-Werte, **zeitlicher Ablauf als eigener Schritt** (Ablaufdiagramm, „Sammellauf 1 vor
  Ausschüttungsjob 3", Punkt L).
- `docs/Technische Konzepte/ifas13-jobs.md`: Stufe 2 ergänzen.
- **Konzept-Korrekturen aus dem Designreview 2026-09-11** (als neue Runde ins Änderungsprotokoll):
  Entscheidung 9 — Schreiberliste: `R`-Löschpfad ist toter Code, „unbekannte ISIN" ist tot (D2), der
  einzige lebende Grund für „nicht aus `kurs` ableitbar" ist die Preiswährung; Entscheidung B —
  Verortung: geführte Tabelle bleibt B3, liegt aber als `kurs..tmp_if_last` in der Neusystem-Sybase,
  `letzte_preise` ist Guard + Spiegel; Abschnitt *Parallelbetrieb* — Tabelle der vier Diff-Ebenen:
  Ebenen 3/4 aus dem Job in den generischen Tabellenvergleich; Entscheidung M bleibt, gilt aber nur
  für **neue** Tabellen.

### AP11 — Umbau nach dem Designreview 2026-09-11 (D11–D13) — **erledigt**

- **Ausbau Diff-Ebenen 3/4** (D13): `PreisMeldungDiffJobExecutionService` ohne `dbDiffService`,
  ohne `db-diff.txt`, `db_diff_count` nicht mehr befüllt; `PreismeldungDbDiffService` entfernen,
  `PreismeldungDbDiff` (Domain) behalten; `PreisMeldungDiffJobTest` entsprechend. Spalte
  `db_diff_count` (V066): fallen lassen oder `null` — entscheiden.
- **`TmpIfLast` schreibend** (D11): Entity in `ifas-persistence-inv` um den Write, Repository um
  delete-by-`(num_okb, cod_waehrung, cod_preiscode, cod_ex)` als JPQL-Bulk (wie `KursRepository` —
  Hibernate flusht Inserts vor Deletes) und `save`; trimmende Getter für die `char`-Spalten.
- **Klammer** (D12): `LetztePreiseService.recordLastPriceIfNewer` wird zur Klammer — außen
  `letzte_preise`-Update/Insert im fondspreise-Kontext, innen der Sybase-Write im business-Kontext;
  Erstanspruch-Wiederholung wie bei der `kurs`-Klammer in `PreismeldungSyncService`. Der Aufrufer
  übergibt den business-Key.
- **Rebuild** (D11): nur die aus der Inbox hergeleiteten Schlüssel ersetzen, auf beiden Seiten; kein
  Leeren der Sybase-Tabelle, `letzte_preise` nur für diese Schlüssel.
- **Aufräumen** (D11): `cleanupEndedFunds` löscht in `tmp_if_last` **und** `letzte_preise`.
- **Guard-Seed** (D12): `importLegacyLastPrices` behalten; Leser gegen `tmp_if_last` im
  **business**-Kontext (Neusystem-Sybase), kein legacyBusiness. Gebaut, aber **nicht ausgeführt** —
  entschieden 2026-09-11, siehe D12.
- **Tests**: `tmp_if_last`-Write und -Delete auf allen drei DBMS (`@TestTemplate`, wie
  `KursRepositoryTest`); Klammer in beiden Reihenfolgen und mit verlorenem Guard (kein Sybase-Write);
  Rebuild lässt Vor-Go-live-Zeilen stehen; Cleanup beidseitig. `PreismeldungSyncGuardTest` bleibt
  gültig.

**Reihenfolge (aktualisiert 2026-09-11):** AP1 → (AP2 ∥ AP3) → AP4 → AP5 → AP6 → AP7 → AP8 →
**AP11** → AP9 → AP10.
Kritischer Pfad: AP1 → AP4 → AP5 → AP7.

## Verifikation

- `mvn clean install -Pno-proxy -Pdev-build` (Annotation-Prozessoren für die neuen Entities).
- Unit- und Integrationstests wie AP9; ein Multi-DB-Lauf ohne `-Pskip-*` (Sybase-Pfad für `kurs`).
- Manuell: `LocalH2OnlyIfasApplication`, eines der Beispielfiles über den Parallelbetrieb-Upload
  einspielen → Job läuft durch, Result-Bundle enthält `sync-report.txt` und `db-diff.txt`,
  `kurs`- und `letzte_preise`-Zeilen über die H2-Konsole prüfen.
- Reihenfolge-Test bewusst zweimal laufen lassen (Guard ist ein Nebenläufigkeitsmechanismus —
  ein einzelner grüner Lauf beweist wenig).
- `tmp_if_last`-Write gegen den Sybase-Testcontainer laufen lassen, nicht nur H2/PG — `char`-Padding
  und `ignore_dup_key`-Verhalten zeigen sich nur dort (AP11).

## Risiken / offene Punkte

1. **Klammer-Transaktion über zwei DBMS** ist der anspruchsvollste Teil. Fehlerfenster laut Konzept:
   Absturz zwischen Sybase-Commit und Postgres-Commit lässt `kurs` geschrieben und den Guard
   unmarkiert zurück — konvergiert über den Retry. Explizit testen.
2. **`kurs` in H2/Postgres für Tests** — die Tabelle ist eine Legacy-Sybase-Tabelle; ob ein
   Provisionierungsskript nötig ist, entscheidet sich beim Bau von AP3 (Muster V041/V062).
3. **`num_wfs_ku` vs. `num_wfs`** sind zwei verschiedene Nummern (`kurs` nutzt `num_wfs_ku` aus
   `vwkn..wkn_hist`, das ASF-Veto `WFS_WKN`). Verwechslung wäre still und falsch.
4. ~~**Seed-Zeitpunkt**~~ — **entfallen 2026-09-11 (D11):** die Daten kommen mit dem Voll-Sync. Der
   **Guard-Seed** (D12) entfällt ebenfalls (User 2026-09-11): beim ersten Write je Schlüssel nach dem
   Go-live gilt Legacy-Semantik, ab dem zweiten unsere Reihenfolgeregel — akzeptiert.
5. **Kennzahlen bleiben außen vor** (Schnitt 6): Korrekturen und `R`-Löschungen werden nur
   *vorgemerkt*, nicht nachgerechnet. In der Sybase heißt das vorübergehend: `kurs` aktuell,
   abhängige Kennzahlen veraltet. Als bekannte Abweichung führen.
6. **Flyway-Nummern** beim Merge erneut prüfen (heute frei ab V065). **Geprüft 2026-09-11 beim Merge
   von `origin/master` (`1ba887699`):** master, stable und production enden bei V064, V065–V067
   bleiben. `origin/ausschuettung` belegt V065/V066 eigenständig — wer von beiden später nach master
   mergt, nummeriert um; Vorgehen in `mathias/rules/flyway-versions-after-merge.md`.
7. **Fremdleser von `tmp_if_last`** (KUPL/KMS, Tracker O): welche Spalten sie lesen, entscheidet, wie
   exakt `txt_bez`, `liefer_id`, `eintragezeit` dem Legacy entsprechen müssen. Bis zur Antwort
   Legacy-getreu füllen (D11).
8. **Zweite Cross-DB-Klammer** (D12): dieselbe Fehlerfenster-Analyse wie für `kurs`, aber je Gruppe
   nun zwei Klammerarten hintereinander. Deadlockfrei bleibt es nur mit fester Reihenfolge (erst
   `kurs`-Schlüssel, dann Projektionsschlüssel) und sortierten Schlüsseln.

## Nicht in Schnitt 2

Kennzahlen-Nachrechnung und der `ASF.r_faktor`-Pfad (Schnitt 6, blockiert durch K);
`WirksamePreismeldungen` (Schnitt 3); Filegenerierung, Publikationsprotokoll und der
ASF-Statusfilter-Befund aus Q9–Q11/F6 (Schnitt 4); Fehlmeldung (Schnitt 7); Web-UI; die
Zeitablauf-Analyse inkl. Punkt L (eigener Schritt, siehe Context); der generische Tabellenvergleich
Sybase alt gegen Sybase neu (D13, eigener Schritt).

---

*Nach Freigabe nach `mathias/plans/fondspreise/2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md`
verschieben und im Tracker verlinken.*
