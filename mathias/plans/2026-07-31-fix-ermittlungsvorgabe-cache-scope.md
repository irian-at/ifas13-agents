# Ermittlungsvorgabe-Cache: Gültigkeitsbereich korrigieren

**Datum:** 2026-07-31
**Status:** Entwurf — zur Prüfung
**Auslöser:** `IllegalArgumentException: Unknown numeric code for field name: Ausschuettung_e` auf dem
Testserver, reproduzierbar auch nach Import der Standard-Basisdaten.

## Problem

`DefaultErmittlungsvorgabeProvider` cached die aus der DB aufgebaute `Ermittlungsvorgabe`
anwendungsweit und unbegrenzt:

```java
// DefaultErmittlungsvorgabeProvider.java:31
private final Map<Integer, Ermittlungsvorgabe> cachedErmittlungsvorgabenByVersion = new ConcurrentHashMap<>();

// :40-45
public Ermittlungsvorgabe getVorgabe(int bmfVersion) {
    return cachedErmittlungsvorgabenByVersion.computeIfAbsent(bmfVersion, this::createWrappedErmittlungsvorgabe);
}
```

`createWrappedErmittlungsvorgabe` (`:58-61`) liest über `getSteuerFieldInfoResolver(bmfVersion)`
(`:63-67`) die Tabellen `steuer_fields` und `steuer_beh_fields` und baut daraus den
`FieldInfoResolverErmittlungsvorgabe`, der `fieldName → steuer_code` auflöst.

### Warum der Cache zwischen Jobs überlebt

| Fakt | Beleg |
|---|---|
| Der Provider ist ein **Singleton des Parent-Contexts** | `@Component` in `at.oekb.ifas.domain.stm.vorgabe`; `IfasMainApplication:21-26` scannt `at.oekb.ifas.domain` im Hauptkontext ("NO database persistence packages here!") |
| Die Repositories sind **Routing-Proxies** | `RoutingRepositoryFactoryBean` — delegiert an das Repository des *aktuell gewählten* DB-Kontexts |
| Child-Contexts leben so lange wie die Anwendung | `DatabaseChildContextInitializer` erzeugt sie einmalig als `BeanFactoryPostProcessor`, `refresh()` bei `:231` |
| Die Map wird **nie** geleert | Einziger Zugriff im gesamten Repo ist das `computeIfAbsent` bei `:41` — keine Eviction, kein `@CacheEvict`, kein Hook auf Import |
| Der Schlüssel ist **nur die Versionsnummer** | `Map<Integer, Ermittlungsvorgabe>`, kein DB-Kontext im Key |

Konsequenz: die **erste** Auflösung einer BMF-Version irgendwo in der Anwendung friert die
`fieldName → steuer_code`-Map dieser Version für die gesamte Anwendungslaufzeit ein — über Jobs
hinweg **und über Datenbank-Kontexte hinweg**. Der Routing-Proxy macht den *Lesezugriff*
kontextabhängig, der davorliegende Cache ist es nicht.

### Beobachtetes Verhalten (Testserver, Temp-DB)

1. **Lauf 1** (AUTO, ohne Basisdaten): In der DB lagen nur die 974 V6-`steuer_fields`-Zeilen aus
   `gf1-...-export.yaml.txt` (Bundle-Testdaten werden in `RecalculationDomainService:105-115`
   **immer** importiert). Daraus wird der V6-Resolver gebaut und gecached → Abbruch bei
   `Ausschuettung_e`.
2. **Lauf 2** (Basisdaten-Flag gesetzt, Version 6 erzwungen): Der Basisdaten-Import läuft und fügt
   alle 2251 V6-Zeilen ein — aber `getVorgabe(6)` greift nie wieder auf die DB zu, sondern liefert
   den gecachten Resolver aus Lauf 1. Gleicher Fehler.
3. Nach dem Abbruch ist die Temp-DB leer: `WorkQueueExecutor.doExecuteItem:342-361` führt den
   gesamten Handler in **einer** Transaktion aus ("Main Transaction"), der Fehler rollt Basisdaten-
   und Testdaten-Import mit zurück. Der In-Memory-Cache wird davon **nicht** zurückgerollt.

Lokal fällt das nicht auf: jeder Testlauf startet einen frischen Spring-Context, und
`GrossfileRecalculationTest:76` importiert die Basisdaten, bevor irgendetwas eine Vorgabe auflöst.
Innerhalb *eines* Jobs stimmt die Reihenfolge ebenfalls (Import `:96-115`, Auflösung danach) —
vergiftet sind erst der zweite und alle folgenden Jobs derselben JVM.

## Nicht betroffen

`ExcelErmittlungsvorgaben.VORGABEN_BY_VERSION_CACHE` (`:20-23`) ist ein statischer Cache über die
Excel-Ressourcen im Classpath. Die sind unveränderlich — dieser Cache ist korrekt und soll bleiben.
Betroffen ist ausschließlich der DB-abhängige Wrapper darum herum.

## Warum der Cache nicht einfach entfallen kann

`getVorgabe` wird **pro CSV-Message** aufgerufen (`CsvSteuerMeldungen.getErmittlungsvorgabe`, über
`internalLoadSteuerMeldungen...`), also pro Meldung eines Grossfiles. Ein Rebuild kostet zwei
Projections-Queries über ~2251 + ~169 Zeilen. Ohne Cache wäre das pro Meldung — bei Grossfiles
inakzeptabel. (`getVorgabe(gjBeginn, stichtag)` ruft zusätzlich heute schon pro Meldung
`getAllStmVersions()` auf — separat betrachtenswert, siehe Offene Punkte.)

Der Cache muss also bleiben, nur sein **Gültigkeitsbereich** ist falsch.

---

## Optionen

### Option A — Transaktions-gebundener Cache, Key `(dbContextKey, version)` ← **Empfehlung**

Die Map wird nicht mehr als Feld gehalten, sondern über
`TransactionSynchronizationManager.bindResource(...)` an die laufende Transaktion gebunden.

- **Lebensdauer = eine Transaktion = ein Job.** Genau der Bereich, in dem die Daten stabil sind.
- **Rollback-sicher:** die Ressource verschwindet mit der Transaktion, es können keine Einträge
  überleben, die nie committed wurden (das passiert bei Option B sonst genau).
- **Keine Invalidierungs-Disziplin nötig** — kein Aufrufer muss daran denken.
- `spring-tx` ist über `spring-boot-starter-data-jpa` (`ifas-domain-stm/pom.xml:85`) bereits da.
- Ohne aktive Transaktion (Dev-Tools, Einzelaufrufe): ohne Cache aufbauen.

### Option B — Anwendungsweiter Cache mit Key `(dbContextKey, version)` + explizite Invalidierung

`invalidateAll()` auf dem Provider, aufgerufen nach jedem Basisdaten-/Testdaten-Import
(`RecalculationDomainService:103` und `:113`, Datenverwaltung-Import, `IsinAnforderungDiffService:97`).

- Kleinerer Eingriff, als Hotfix brauchbar.
- **Bleibt fehlerhaft bei Rollback:** Import → Invalidierung → Rebuild mit 2251 Zeilen → Abbruch →
  Rollback. Die DB ist wieder leer, der Cache hält aber den "guten" Resolver. Der nächste Lauf
  funktioniert dann aus unsichtbarem Zustand heraus. Nur reparierbar, indem zusätzlich eine
  `TransactionSynchronization.afterCompletion` die Einträge verwirft — womit man bei Option A ist.
- Erfordert, dass jeder künftige Import-Pfad daran denkt.

### Option C — Cache ersatzlos entfernen

Korrekt, aber wegen der Kosten pro Meldung nicht tragfähig (siehe oben). Verworfen.

---

## Umsetzung Option A

### 1. DB-Kontext-Schlüssel in der Domain verfügbar machen

`ifas-domain-stm` hängt **nicht** an `multidbctx-support`, `DatabaseContextHolder` ist dort also
nicht sichtbar. Vorbild ist `DatabaseWriteSwitch`: ein schmales Interface in `ifas-domain-core`,
implementiert in der Service-Schicht.

Neu: `ifas-domain/ifas-domain-core/src/main/java/at/oekb/ifas/domain/core/DatabaseContextKeys.java`
(Name zu klären, siehe Offene Punkte)

```java
public interface DatabaseContextKeys {
    /** Key of the currently selected database context, or null if none is bound. */
    @Nullable String currentDatabaseKey();
}
```

Implementierung in `ifas-services/.../service/dbctx/` als dünner Delegate auf das vorhandene
`DatabaseContextHelper.getCurrentDbKey()`; Bean-Definition analog `IfasMainApplication:54`
(`databaseWriteSwitch`). Für Dev-Tools/Tests eine Konstante analog `DatabaseWriteSwitch.NO_SWITCH`.

**Alternative prüfen:** wenn eine Transaktion garantiert nie den DB-Kontext wechselt, ist der Key
überflüssig und Option A kommt ohne dieses Interface aus. Das ist aber **nicht** garantiert —
`WorkQueueExecutor:342-348` legt die Transaktion *um* den Kontextwechsel, und es gibt
`SynchronizingTransactionManager` für kontextübergreifende Transaktionen. Der zusammengesetzte Key
ist daher die sichere Variante.

### 2. `DefaultErmittlungsvorgabeProvider` umbauen

Datei: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/DefaultErmittlungsvorgabeProvider.java`

- Feld `cachedErmittlungsvorgabenByVersion` (`:31`) entfernen.
- `getVorgabe(int)` (`:40-45`) auf einen transaktionsgebundenen Cache umstellen:

```java
@Override
public Ermittlungsvorgabe getVorgabe(int bmfVersion) {
    Map<CacheKey, Ermittlungsvorgabe> cache = currentTransactionCache();
    if (cache == null) {
        // no transaction bound -> no caching, correctness over speed
        return createWrappedErmittlungsvorgabe(bmfVersion);
    }
    return cache.computeIfAbsent(
            new CacheKey(databaseContextKeys.currentDatabaseKey(), bmfVersion),
            key -> createWrappedErmittlungsvorgabe(key.version())
    );
}
```

- `currentTransactionCache()`: `TransactionSynchronizationManager.isSynchronizationActive()` prüfen,
  Ressource unter einem konstanten Key holen bzw. per `bindResource` anlegen und eine
  `TransactionSynchronization` zum `unbindResource` in `afterCompletion` registrieren.
- Der Konstruktor bekommt zusätzlich `DatabaseContextKeys` (Lombok `@RequiredArgsConstructor` bleibt).

### 3. Nichts an den Aufrufern

Die 12 Verwender von `ErmittlungsvorgabeProvider` (u. a. `CsvSteuerMeldungen`,
`SteuerMeldungLieferungService`, `RecalculationDomainService`, `StmDiffs`, `EagerDbSteuerMeldung`,
`IsinAnforderungDomainService`, `CsvExcelToolService`, Dev-Tools) bleiben unverändert — die
Schnittstelle ändert sich nicht.

---

## Tests

Konventionen: given-when-then, AssertJ, `@Inject`.

1. `DefaultErmittlungsvorgabeProviderTest` (Integrationstest, H2)
   - `givenVorgabeResolvedWithIncompleteFields_whenFieldsImportedAndNewTransaction_thenResolverIsRebuilt`
     — der Regressionstest für genau diesen Bug: Vorgabe in Transaktion 1 mit unvollständigen
     `steuer_fields` auflösen, danach vollständige Basisdaten importieren, in Transaktion 2
     `getNumericCode("Ausschuettung_e")` muss auflösen.
   - `givenSameTransaction_whenGetVorgabeTwice_thenResolverIsCached` — Cache greift innerhalb einer
     Transaktion (z. B. über Query-Zähler oder Identitätsvergleich).
   - `givenDifferentDatabaseContexts_whenGetVorgabeForSameVersion_thenSeparateResolvers`
     — nutzt das Setup aus `ifas-integration-tests-multidbctx`.
   - `givenRolledBackImport_whenGetVorgabeAfterwards_thenResolverReflectsRolledBackState`
     — sichert die Rollback-Eigenschaft ab, die Option B nicht hat.
2. `GrossfileRecalculationTest` muss unverändert grün bleiben (aktuell 8/8) — dient als
   Performance-/Regressionsnetz: mehrere Grossfiles in einer JVM.

## Verifikation auf dem Testserver

1. Anwendung neu starten (leert den bestehenden Cache) — **vor** dem Deployment, um zu bestätigen,
   dass der Cache tatsächlich der Blocker war: ein Lauf mit Basisdaten-Flag muss dann durchlaufen.
2. Nach dem Fix **ohne** Neustart: zwei Läufe hintereinander in derselben JVM, der erste ohne, der
   zweite mit Basisdaten-Import. Der zweite muss durchlaufen.
3. Gegenprobe Kontexttrennung: Recalc auf Temp-DB 1, danach auf Temp-DB 2 mit unterschiedlichem
   Datenstand — beide müssen ihre eigene Vorgabe sehen.

---

## Nicht Teil dieser Änderung

- **Checkbox "Basisdaten importieren"** → eigener Plan
  `2026-07-31-basedata-import-checkbox-writable-db.md`. Der Cache ist der eigentliche Blocker; die
  Checkbox-Änderung hätte diesen Fehler nicht behoben.
- **Transaktionszuschnitt des Recalc-Jobs.** Dass Import + Berechnung + Ergebnis in *einer*
  Transaktion laufen (`WorkQueueExecutor:342`) und ein Fehler die importierten Stammdaten
  mitrollt, ist für sich diskussionswürdig (eine leere Temp-DB nach jedem Fehlversuch ist beim
  Debuggen unangenehm) — aber eine separate Entscheidung.
- Unvollständige V6-Metadaten in einer konkreten Temp-DB — Datenzustand, kein Code.

## Offene Punkte

1. **Name und Ort des Kontext-Interfaces.** `DatabaseContextKeys` in `ifas-domain-core` neben
   `DatabaseWriteSwitch`? Oder `DatabaseWriteSwitch` um `currentDatabaseKey()` erweitern (weniger
   neue Typen, aber semantisch überladen)?
2. **Verhalten ohne Transaktion:** ungecached aufbauen (Vorschlag oben) oder hart ablehnen? Die
   Dev-Tools (`CsvSteuerMeldungRoundTripTool`, `ExcelSteuerMeldungRawWriter`) laufen ggf. ohne
   Transaktion — ungecached ist dort funktional, aber langsam.
3. **`getAllStmVersions()` pro Meldung** (`DefaultErmittlungsvorgabeProvider:70`): dieselbe
   Cache-Frage in klein, mit demselben Stale-Risiko. Im selben Zug mitmachen oder bewusst
   ungecached lassen?
4. **Hotfix nötig?** Falls der Testserver kurzfristig laufen muss: Neustart + ein Lauf mit
   Basisdaten-Flag genügt als Workaround, bis der Fix deployt ist.
