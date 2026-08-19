# Analyse: Java-Implementierung — FieldSpec / Ermittlungsvorgabe und Versions-Relevanz von Feldern

**Companion zu:** [`legacy-return-csv-versioning-analysis.md`](legacy-return-csv-versioning-analysis.md) (C++-Altsystem)
**Frage:** Kann man über den `FieldSpec` der Ermittlungsvorgabe ablesen, für welche Version ein Feld relevant ist?
**Kurzantwort:** Ja — aber **anders als im C++**. Der `FieldSpec` selbst trägt **kein** Versions-Attribut. Stattdessen ist jede `Ermittlungsvorgabe` **genau eine Version** (aus einem versions-spezifischen Excel-Template extrahiert). Die Versions-Relevanz eines Feldes ist implizit: „Feld X ist in Version V relevant" ⇔ `provider.getVorgabe(V).fieldExists("X")`. Um eine Feld→Versionen-Matrix zu bauen, iteriert man die Versionen und fragt `fieldExists` / `getFieldSpecByName` ab.

Package: `at.oekb.ifas.domain.stm.vorgabe` (+ `.excel`, `.db`).

---

## 1. Der zentrale Architektur-Unterschied zum C++

| | C++ (Altsystem) | Java (IFAS13) |
|---|---|---|
| Feldkatalog | **eine** flache Tabelle `kurs.dbo.steuer_fields`, jede Zeile mit Spalte `versions_nr` | **ein `Ermittlungsvorgabe`-Objekt pro Version**, extrahiert aus versions-spezifischem Excel-Template |
| Versions-Relevanz | Attribut *pro Feldzeile* (`cStF[j].nVersions_nr`) | *emergent* aus Zugehörigkeit: das Feld ist im FieldSpec-Set dieser Version enthalten oder nicht |
| Output-Filterung | `if (GetAkt_Version() != cStF[j].nVersions_nr) continue;` (`c_stfields.cpp:3966`) | Writer iteriert nur die Felder der aktiven Version: `getErmittlungsvorgabe().getCategoryOutputFields(...)` |
| FieldSpec-Versionsfeld | ja (`versions_nr`) | **nein** — `FieldSpec` hat kein Versionsfeld |

Im C++ „lebt" also die Versions-Zugehörigkeit auf der Feldzeile; in Java lebt sie auf dem Container (Ermittlungsvorgabe = Version).

---

## 2. `Ermittlungsvorgabe` = eine konkrete BMF-Version

`Ermittlungsvorgabe.java`:

```java
/** Definition der Ermittlungsvorgaben.
 *  Entspricht einer konkreten Version des BMF Ermittlungsvorgaben Excel Templates. */
public interface Ermittlungsvorgabe {
    int getVersion();
    Stream<FieldSpec> getAllFields();
    @Nullable FieldSpec getFieldSpecByName(String name);
    default boolean fieldExists(String fieldName) { return getFieldSpecByName(fieldName) != null; }
    default Stream<FieldSpec> getAllOutputFields(boolean erweitertFormat) {
        return getAllFields().filter(fieldSpec -> fieldSpec.isIncludeInOutput(erweitertFormat));
    }
    default Stream<FieldSpec> getCategoryOutputFields(FieldCategory fieldCategory, boolean erweitertFormat) {
        return getAllOutputFields(erweitertFormat).filter(f -> fieldCategory == f.fieldCategory());
    }
}
```

Jede Version wird aus einer eigenen Excel-Ressource geladen (`ExcelErmittlungsvorgaben.load(int version)`):

```java
Resource excelResource = ExcelErmittlungsvorgabeResources.getExcelErmittlungsvorgabeResource(version);
Ermittlungsvorgabe erm = new ExcelErmittlungsvorgabeExtractor(excelResource).extractErmittlungsvorgabe();
// hard check: erm.getVersion() muss == version
```

Der FieldSpec-Bestand einer Version = exakt die Felder ihres Templates. Deshalb braucht `FieldSpec` kein Versionsfeld.

---

## 3. `FieldSpec` — was es steuert (und was nicht)

`FieldSpec.java` (record, 294 Zeilen). Relevante Achsen für Output/Relevanz:

- **`OutputType`**: `NONE` / `START` / `ERWEITERTE_ANGABEN` / `STANDARD` / `EXTENDED`
  ```java
  public boolean isIncludeInOutput(boolean erweitertFormat) {
      return erweitertFormat && outputType == OutputType.EXTENDED || outputType == OutputType.STANDARD;
  }
  ```
  → Das ist die **Dateivarianten-Achse** (small vs. erweitert), das Java-Pendant zum C++ `nVersion`-Param (0/1) — **nicht** die Ermittlungsvorgabe-Version.
- **`Publikation` (J/N)**, **`Berechnung` (J/N)**, **`Befuellung`** (M / O / M(>0) / …), **`Quelle`**, **`javaType`/`javaSubType`**, **`fieldCategory`**, **`countryVectorSpec`**, `untergrenze`/`obergrenze`, `codeListe`.
- **Kein** `version()`-Feld. `equals`/`hashCode` gehen rein über `definedName()`.

> Fazit: Aus einem einzelnen `FieldSpec` allein lässt sich die Version **nicht** ablesen — man braucht den Kontext „aus welcher Ermittlungsvorgabe stammt er".

---

## 4. Versions-Auflösung — 1:1-Pendant zum C++

`DefaultErmittlungsvorgabeProvider.java`:

- **Nach Gj-Beginn × Stichtag** (mirror von `c_stm_version.cpp:420-421`):
  ```java
  int getApplicableBmfVersion(LocalDate gjBeginn, LocalDate stichTag) {
      return steuerMeldungVersionRepository.getAllStmVersions().stream()
          .filter(v -> isApplicable(v, gjBeginn, stichTag))   // gjBeginnAb..Bis UND stichtagAb..Bis
          .map(StmVersion::versionsNr)
          .reduce((v1,v2) -> { throw new IllegalStateException("More than one STM version ..."); })
          .orElseThrow(() -> new IllegalArgumentException("No applicable STM version ..."));
  }
  ```
  `isApplicable` prüft `gjBeginnAb <= gjBeginn <= gjBeginnBis` **und** `stichtagAb <= stichTag <= stichtagBis`. Genau ein Treffer erwartet.
- **Nach gespeicherter Version der Meldung** (historische Treue, mirror von `nAVersions_nr`):
  ```java
  public Ermittlungsvorgabe getVorgabe(Long stmId) {
      ... return getVorgabe(steuerMeldungEntity.getVersionsNr());   // NICHT neu berechnen
  }
  ```
- Quelle der Versions-Ranges: DB via `SteuerMeldungVersionRepository` (Pendant zu `kurs.dbo.steuer_meldung_version`).
- Cache pro Version (`ConcurrentHashMap`).

---

## 5. Wie der Return-CSV-Writer die Version nutzt

`CsvSteuerMeldungenWriter.writeMultiRowMultiValueRecord(...)` (`:217-246`):

```java
List<FieldSpec> fieldsOfCategory =
    steuerMeldung.getErmittlungsvorgabe()          // <-- die versions-spezifische Vorgabe
                 .getCategoryOutputFields(fieldCategory, erweitert)
                 .toList();
for (FieldSpec fieldSpec : fieldsOfCategory) { ... }
```

`steuerMeldung.getErmittlungsvorgabe()` liefert die zur Meldung gehörende Version (via `entity.getVersionsNr()`, siehe `EagerDbSteuerMeldung.java:86`). Die Versions-Filterung des Outputs passiert also **implizit** durch die Wahl der Ermittlungsvorgabe — es gibt keinen expliziten `if version == …`-Filter im Writer (anders als C++ `:3966`).

---

## 6. Die versions-skalierte DB-Seite (nur Nummerncode-Map)

Es gibt sehr wohl versions-skalierte DB-Tabellen — aber nur für die **numerische Code↔Feldname-Zuordnung** (Pendant zu `st_field_id`), nicht für die Felddefinitionen:

- `SteuerFieldRepository` (`ifas-persistence-stm/.../metadata/`):
  ```java
  where steuerField.version.versionsNr = :version
  ```
  Methoden: `getSteuerCodeByVersionAndFieldName(version, name)`, `getFieldNameByVersionAndSteuerCode(version, code)`, `getAllSteuerCodesAndFieldNamesByVersion(version)`, `findByVersion(SteuerMeldungVersion)`.
- Analog `SteuerBehFieldRepository` für `StB_*`-Felder.
- `FieldCodeMapErmittlungsvorgabe` wrappt eine Ermittlungsvorgabe und ergänzt `getNumericCode` / `getFieldName` aus diesen Maps (`DefaultErmittlungsvorgabeProvider.createWrappedErmittlungsvorgabe`).

Also: `steuer_fields.versions_nr` existiert in Java weiterhin — aber die **maßgeblichen Felddefinitionen** (welche Felder es gibt, Output-Typ, Berechnung, Grenzen) kommen aus dem **Excel-Template pro Version**, nicht aus dieser Tabelle.

---

## 7. Die Idee des Users — konkret umsetzbar

**Das Primitiv existiert bereits:** `Ermittlungsvorgabe.fieldExists(String)` (Default-Methode, `Ermittlungsvorgabe.java:38-40`) beantwortet „Feld X in Version V relevant?" direkt:

```java
provider.getVorgabe(version).fieldExists("Anteile_Tranche_Anzahl_e");   // true/false
// bzw. getFieldSpecByName(name) für den FieldSpec selbst (Attribute pro Version)
```

Kein neuer Helper nötig. Was die Domain (noch) nicht fertig anbietet, ist nur die **Aggregation über alle Versionen** — und das ist eine triviale Schleife über das vorhandene `fieldExists`/`getAllFields`.

### 7a. Cross-Version-Rollup — Feld → Menge der Versionen

Die Menge der „bekannten Versionen" kommt aus der maßgeblichen Quelle `SteuerMeldungVersionRepository.getAllStmVersions()` (dieselbe, die auch `getApplicableBmfVersion` nutzt):

```java
/** Feld (definedName) -> Menge der Versionen, in denen das Feld als FieldSpec existiert. */
Map<String, SortedSet<Integer>> relevanteVersionenProFeld(
        ErmittlungsvorgabeProvider provider,
        SteuerMeldungVersionRepository versionRepository
) {
    List<Integer> versionen = versionRepository.getAllStmVersions().stream()
            .map(SteuerMeldungVersionRepository.StmVersion::versionsNr)
            .sorted()
            .toList();

    Map<String, SortedSet<Integer>> byField = new TreeMap<>();
    for (Integer v : versionen) {
        provider.getVorgabe(v).getAllFields().forEach(fs ->
                byField.computeIfAbsent(fs.definedName(), k -> new TreeSet<>()).add(v));
    }
    return byField;
}

// Nutzung:
// "In welchen Versionen ist Feld X relevant?"  -> byField.get("X")                 // z.B. [4, 5, 6]
// "Ist Feld X in Version V relevant?"          -> byField.get("X").contains(V)
//                                              -> provider.getVorgabe(V).fieldExists("X")   // ohne Rollup
```

### 7b. Version-Diff — was kam/entfiel zwischen zwei Versionen

Baut direkt auf dem Rollup auf (bzw. auf `getAllFields()` zweier Versionen):

```java
record FieldVersionDiff(SortedSet<String> nurInAlt, SortedSet<String> nurInNeu, SortedSet<String> inBeiden) {}

FieldVersionDiff diff(ErmittlungsvorgabeProvider provider, int alt, int neu) {
    Set<String> feldeAlt = provider.getVorgabe(alt).getAllFields()
            .map(FieldSpec::definedName).collect(Collectors.toSet());
    Set<String> feldeNeu = provider.getVorgabe(neu).getAllFields()
            .map(FieldSpec::definedName).collect(Collectors.toSet());

    SortedSet<String> nurAlt   = new TreeSet<>(feldeAlt); nurAlt.removeAll(feldeNeu);   // in neuer Version entfallen
    SortedSet<String> nurNeu   = new TreeSet<>(feldeNeu); nurNeu.removeAll(feldeAlt);   // in neuer Version neu
    SortedSet<String> gemeinsam= new TreeSet<>(feldeAlt); gemeinsam.retainAll(feldeNeu);
    return new FieldVersionDiff(nurAlt, nurNeu, gemeinsam);
}
```

> Für gemeinsame Felder reicht Existenz nicht: `getFieldSpecByName(name)` in beiden Versionen holen und die relevanten Attribute vergleichen (`outputType`, `befuellung`, `publikation`, `berechnung`, `expression`, `untergrenze`/`obergrenze`, `javaType`) — so sieht man *geänderte* (nicht nur hinzugefügte/entfallene) Felder.

Verfeinerungen, falls „relevant" enger gemeint ist als „existiert" — den `getAllFields()`-Stream im Rollup zusätzlich filtern:
- **im Output** relevant → `fs.isIncludeInOutput(erweitert)` (OutputType STANDARD/EXTENDED).
- **berechnet** → `fs.berechnung() == J` bzw. `erm.getAllCalculatedFields()`.
- **publiziert** → `fs.publikation() == J`.
- **von St.Vertreter meldbar** → `fs.isReportedBySteuerlicherVertreter()`.

Alternative Versions-Quelle statt DB: die vorhandenen Excel-Ressourcen V4/V5/V6 (`ExcelErmVorgabeVersionSpecs`).

> Wichtig: Die Antwort ist **pro definedName**, nicht pro FieldSpec-Instanz — ein Feld mit gleichem `definedName` kann in mehreren Versionen vorkommen (ggf. mit unterschiedlichem `OutputType`/`Befuellung`/`expression`, weil aus unterschiedlichen Templates extrahiert). Für einen echten Versions-*Diff* also nicht nur Existenz, sondern die FieldSpec-Attribute pro Version vergleichen.

---

## 8. Fazit

- In Java gibt es **kein** `versions_nr` am `FieldSpec`; die Version ist eine Eigenschaft der **`Ermittlungsvorgabe`** (= ein Excel-Template pro Version).
- Versions-Relevanz eines Feldes ⇒ über `provider.getVorgabe(version).fieldExists(name)` / `getFieldSpecByName(name)` bestimmen; für eine Matrix über alle Versionen iterieren.
- Versions-Auflösung (Gj-Beginn × Stichtag, bzw. gespeicherte Version bei Recalc) ist ein exaktes Pendant zum C++.
- Die Output-Versions-Filterung des C++ (`nVersions_nr`-Vergleich beim Schreiben) entfällt in Java, weil der Writer ohnehin nur die Felder der gewählten Version durchläuft.

---

## Datei-Referenzen (Java)

- `vorgabe/FieldSpec.java` — Feld-Spezifikation (Record); `OutputType`, `isIncludeInOutput`, kein Versionsfeld
- `vorgabe/Ermittlungsvorgabe.java` — Interface, „entspricht einer konkreten Version"; `getVersion`, `getAllFields`, `fieldExists`, `getAllOutputFields`, `getCategoryOutputFields`
- `vorgabe/Ermittlungsvorgaben.java` → `excel/ExcelErmittlungsvorgaben.java` — Registry/Cache; `load(version)` aus Excel-Ressource
- `vorgabe/DefaultErmittlungsvorgabeProvider.java` — Versions-Auflösung (`getApplicableBmfVersion`, `isApplicable`), `getVorgabe(gjBeginn,stichtag|version|stmId)`
- `vorgabe/excel/ExcelVersions.java` — Versions-Erkennung aus Workbook (Change-Log / Erträge-Header → 4/5/6)
- `vorgabe/excel/ExcelErmVorgabeVersionSpec{,V4,V5,V6}.java` — Template-Struktur pro Version
- `vorgabe/db/FieldCodeMapErmittlungsvorgabe.java` — Wrapper für numerische Codes
- `persistence.stm.metadata.SteuerFieldRepository` / `SteuerBehFieldRepository` / `SteuerMeldungVersionRepository` — versions-skalierte DB-Queries
- `meldung/csv/CsvSteuerMeldungenWriter.java:217-246` — Return-CSV-Writer, iteriert `getCategoryOutputFields`
- `meldung/SteuerMeldung.java:300`, `meldung/db/EagerDbSteuerMeldung.java:86` — Meldung → Ermittlungsvorgabe (über gespeicherte Version)
