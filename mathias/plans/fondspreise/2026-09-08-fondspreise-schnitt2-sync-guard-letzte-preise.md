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

## Stand 2026-09-08

**AP1–AP3 umgesetzt und verifiziert**, committet als `4e9bc49e6` auf dem Branch
`feat/fondspreise-sync-stage-foundation` (nicht gepusht). Gesamtbuild grün; 95 Domain-Tests,
`PreismeldungSyncGuardTest` 14 (7 Fälle × H2 + Postgres), `KursRepositoryTest` 9 (alle drei DBMS),
`PreisMeldungDiffJobTest` 2.

| AP | Stand |
|---|---|
| AP1 Stammdaten | fertig — `FondsStammdaten` um `numWfsKu`/`codArtF`/`status` + Prädikate erweitert, eine gebündelte `InvRepository#findFondsStammdatenByIsin` ersetzt die zwei bisherigen Lookups |
| AP2 Properties | fertig — `FondspreiseProperties` (`ifas.fondspreise`) |
| AP3 Persistenz + Flyway | fertig — `Kurs`/`KursId`/`KursRepository`, `PreisHerkunft`(+Id/Repo), `LetzterPreis`(+Id/Repo), `V065__fondspreise_sync.sql` je Baum |
| AP4–AP10 | offen |

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
| 5 | Preiswährung ≠ Fondswährung → **nicht** nach `kurs`, aber in die Projektion | `:2843-2848` | portieren |
| 6 | vorläufiger Fonds (`status='V'`) mit `R` → Aktivierungsversuch | `:2747-2782` | portieren, Pool-Ausgang entfällt |
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
| `kurs.letzte_preise` | Postgres, **fondspreise** | `ifas-persistence-fondspreise` | neue Business-Tabelle |

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
| Diff-Gegenseite | legacyBusiness, **nur lesend** | `withDatabaseContext(getLegacyBusinessDbKey(), …)` |

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

### AP4 — Domain: die Entscheidungslogik (nach AP1)
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

### AP5 — Sync-Service mit Guard und Klammer (nach AP3/AP4)
- `service/preismeldung/PreismeldungSyncService`: liest die Inbox-Zeilen des Jobs, gruppiert nach
  Preisschlüssel, sortiert, ruft je Schlüssel die Domain-Entscheidung und führt sie in der Klammer
  aus (D4/D9). Wiederverwendbar für den späteren Live-Job — wie `PreismeldungEingangService`.
- `AusschuettungVetoProvider`-Impl gegen `ifas..ASF` (Filter `aussch_status='A'`, Fonds/Datum/Währung).

### AP6 — Projektion, Rebuild, Seed (nach AP3/AP5)
- `LetztePreiseService`: Fortschreiben aus dem Sync-Ergebnis mit dem Guard aus D5;
  `rebuildFromInbox(zeitraum)` in Ankunftsreihenfolge; Aufräumen nach
  `tage-letzte-preise-beendete`.
- Seed-Werkzeug: `ifas-dev-tools`-Kommando (Muster `DatabaseYamlExportTool`), das
  `kurs..tmp_if_last` aus dem legacyBusiness-Kontext liest und `letzte_preise` befüllt. Einmalig,
  idempotent, mit Trockenlauf-Ausgabe.

### AP7 — Job-Erweiterung (nach AP5/AP6)
- `PreisMeldungDiffJob`: Feld `angekommen_am` (DB-seitig `now()` beim Insert, D4) sowie Zähler
  `syncedCount`, `skippedCount`, `vetoCount`, `dbDiffCount`; Flyway-Migration dazu
  (`postgres15/V068__preis_meldung_diff_jobs__sync.sql`).
- `PreisMeldungDiffJobExecutionService`: Stufe 2 zwischen Inbox-Schreiben und Result-Bundle
  einhängen (heute `PreisMeldungDiffJobExecutionService.java:107-115`), `sync-report.txt` und
  `db-diff.txt` ins Result-ZIP, Zähler in `updateResult` mitschreiben.
- Wiederholte Jobs erben `angekommen_am` vom Original (`repeatedFromJob`).

### AP8 — Diff-Ebenen 3 und 4 (nach AP7)
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

**Reihenfolge:** AP1 → (AP2 ∥ AP3) → AP4 → AP5 → AP6 → AP7 → AP8 → AP9 → AP10.
Kritischer Pfad: AP1 → AP4 → AP5 → AP7.

## Verifikation

- `mvn clean install -Pno-proxy -Pdev-build` (Annotation-Prozessoren für die neuen Entities).
- Unit- und Integrationstests wie AP9; ein Multi-DB-Lauf ohne `-Pskip-*` (Sybase-Pfad für `kurs`).
- Manuell: `LocalH2OnlyIfasApplication`, eines der Beispielfiles über den Parallelbetrieb-Upload
  einspielen → Job läuft durch, Result-Bundle enthält `sync-report.txt` und `db-diff.txt`,
  `kurs`- und `letzte_preise`-Zeilen über die H2-Konsole prüfen.
- Reihenfolge-Test bewusst zweimal laufen lassen (Guard ist ein Nebenläufigkeitsmechanismus —
  ein einzelner grüner Lauf beweist wenig).

## Risiken / offene Punkte

1. **Klammer-Transaktion über zwei DBMS** ist der anspruchsvollste Teil. Fehlerfenster laut Konzept:
   Absturz zwischen Sybase-Commit und Postgres-Commit lässt `kurs` geschrieben und den Guard
   unmarkiert zurück — konvergiert über den Retry. Explizit testen.
2. **`kurs` in H2/Postgres für Tests** — die Tabelle ist eine Legacy-Sybase-Tabelle; ob ein
   Provisionierungsskript nötig ist, entscheidet sich beim Bau von AP3 (Muster V041/V062).
3. **`num_wfs_ku` vs. `num_wfs`** sind zwei verschiedene Nummern (`kurs` nutzt `num_wfs_ku` aus
   `vwkn..wkn_hist`, das ASF-Veto `WFS_WKN`). Verwechslung wäre still und falsch.
4. **Seed-Zeitpunkt:** `letzte_preise` muss vor dem ersten Parallelbetrieb-Lauf gefüllt sein, sonst
   ist Diff-Ebene 4 von Tag 1 an rot.
5. **Kennzahlen bleiben außen vor** (Schnitt 6): Korrekturen und `R`-Löschungen werden nur
   *vorgemerkt*, nicht nachgerechnet. In der Sybase heißt das vorübergehend: `kurs` aktuell,
   abhängige Kennzahlen veraltet. Als bekannte Abweichung führen.
6. **Flyway-Nummern** beim Merge erneut prüfen (heute frei ab V065).

## Nicht in Schnitt 2

Kennzahlen-Nachrechnung und der `ASF.r_faktor`-Pfad (Schnitt 6, blockiert durch K);
`WirksamePreismeldungen` (Schnitt 3); Filegenerierung, Publikationsprotokoll und der
ASF-Statusfilter-Befund aus Q9–Q11/F6 (Schnitt 4); Fehlmeldung (Schnitt 7); Web-UI; die
Zeitablauf-Analyse inkl. Punkt L (eigener Schritt, siehe Context).

---

*Nach Freigabe nach `mathias/plans/fondspreise/2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md`
verschieben und im Tracker verlinken.*
