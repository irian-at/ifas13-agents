# Fix: `DataExporter.exportByTypeIds` verliert die TypeId-Reihenfolge

## Context

Ausgangspunkt war die Frage eines Kollegen, wie im Daten-Import/-Export-Tool n:n-Beziehungen
(konkret HDP ↔ Lieferant) abgebildet werden. Antwort: Sie **sind** abgebildet — über
`@Mapping(expression = …)` in `DtoEntityMapper` (Zeilen 66–82), mit `List<String>` von
Fremd-Primärschlüsseln im DTO. Details siehe „Fachliche Antwort" unten.

Beim Nachprüfen ist aber ein echter Bug aufgefallen: Weil `DataImporter` die Entities strikt in
Dateireihenfolge per `em.merge` + `em.flush` schreibt und Referenzen über `em.getReference`
(Lazy-Proxy, keine Existenzprüfung) auflöst, **muss LIEFERANT im YAML vor HDP stehen** — sonst
schlägt auf Postgres/H2 die FK `FK_HDP_lieferanten` zu. Genau diese Reihenfolge kann der Aufrufer
von `DataExporter.exportByTypeIds(List)` aber seit Commit `85678453f` (2026-01-29) nicht mehr
steuern: Die Liste wird durch `Collectors.toMap` in eine `HashMap` geschoben.

Empirisch verifiziert (Java 21):

```
input=[LIEFERANT, HDP]        ->  iteration=[HDP, LIEFERANT]
input=[LIEFERANT, KAG, HDP]   ->  iteration=[KAG, HDP, LIEFERANT]
input=[HWA, KAG, HDP]         ->  iteration=[KAG, HWA, HDP]
```

Der Export schreibt also HDP **vor** LIEFERANT, egal was der Aufrufer angibt. Betroffen sind
`DatabaseYamlExportTool` und `DataExportService.exportTypes(List)`. Der Web-UI-Pfad ist *nicht*
betroffen — `DataExportPageController.parseTypeIdsWithPrimaryKeys` baut eine `LinkedHashMap`.
Kein Test deckt das ab: `DataExportServiceTest` prüft mit `satisfiesExactlyInAnyOrder`.

Ziel: Die vom Aufrufer angegebene Reihenfolge wird eingehalten, und ein Test hält das fest.

## Änderungen

### 1. `DataExporter.exportByTypeIds` — Reihenfolge erhalten

`ifas-database/ifas-data-import-export/src/main/java/at/oekb/ifas/importexport/DataExporter.java:61-73`

`Collectors.toMap(identity(), typeId -> List.of())` durch eine ordnungserhaltende Map ersetzen:

```java
Map<String, List<String>> typeIdsWithPrimaryKeys = new LinkedHashMap<>();
typeIds.forEach(typeId -> typeIdsWithPrimaryKeys.put(typeId, List.of()));
exportByTypeIdsWithPrimaryKeys(outputStream, testdataName, typeIdsWithPrimaryKeys, additionalPredicateSupplier);
```

Nebeneffekt: Doppelte TypeIds in der Liste werfen dann keine `IllegalStateException` aus
`Collectors.toMap` mehr, sondern werden — wie in der Map-Variante — zusammengeführt.
Import `java.util.stream.Collectors` / `static java.util.function.Function.identity` prüfen und
falls unbenutzt entfernen.

### 2. Kurzer Javadoc auf `exportByTypeIdsWithPrimaryKeys`

Gleiche Datei, `:83`. Die Signatur nimmt ein `Map` entgegen, die Iterationsreihenfolge ist aber
Teil des Vertrags — sie bestimmt die Importreihenfolge. Ein Satz nach `code-comments.md`
(öffentliches Verhalten, aus der Signatur nicht ersichtlich), z.B.:

> Entities werden in Iterationsreihenfolge der Map geschrieben; das ist zugleich die
> Importreihenfolge, in der `DataImporter` die Fremdschlüssel auflöst. Referenzierte Typen
> gehören vor die referenzierenden (LIEFERANT vor HDP/KAG).

### 3. Regressionstest für die Reihenfolge

`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/service/tool/DataExportServiceTest.java`

Neuer `@TestTemplate` neben `givenAFonds_whenExportAsYaml_expectSuccess`. Die vorhandene
`InvTestdata.simpleInv()`-Fixture reicht (legt Kag, Hdp, Hwa mit an). Ein `List.of("INV", "HWA",
"HDP", "KAG")` liefert unter `HashMap` die Reihenfolge `KAG, INV, HWA, HDP` — der Test schlägt
also ohne den Fix fehl.

Assertion auf den rohen YAML-Text, gegen die vom `DtoTypeCommentInjectionStrategy` erzeugten
Banner bzw. die `- !<TYPE>`-Tags:

```java
assertThat(List.of("- !<INV>", "- !<HWA>", "- !<HDP>", "- !<KAG>").stream().map(exportedYaml::indexOf).toList())
        .doesNotContain(-1)
        .isSorted();
```

Given-when-then und AssertJ gemäß `testing-conventions.md`; die Klasse läuft bereits über
`TEST_WITH_ALL_DATABASE_SYSTEMS`.

### 4. Optional: n:n-Round-Trip absichern

Kein Test deckt aktuell ab, dass `HDP_lieferanten` einen Export→Import-Zyklus übersteht. Ein
zweiter `@TestTemplate` in derselben Klasse:

- **given**: `LieferantTestdataCreator.createSimpleLieferant()`, dazu ein `Hdp` via
  `Hdp.builder()…lieferanten(List.of(lieferant))` speichern
  (`ifas-testing/ifas-test-data/src/main/java/at/oekb/ifas/testdata/stamm/`)
- **when**: `exportTypes(out, List.of("LIEFERANT", "HDP"))`, dann `DataImporter.importTestData`
  des Ergebnisses
- **then**: `LieferantRepository.getLieferantByDepBankAndInlAusl(depBank, "A")` liefert den
  Lieferanten

Deckt Bug und n:n-Mapping in einem ab. Ohne Fix scheitert er auf Postgres/H2 an der FK.

## Verifikation

```bash
mvn -Pno-proxy -pl ifas-database/ifas-data-import-export -am install -DskipTests
mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test -Dtest=DataExportServiceTest
```

Erwartung: neue Tests grün; die bestehende `givenAFonds_whenExportAsYaml_expectSuccess` bleibt
unverändert grün. Zusätzlich `mvn -Pno-proxy -pl ifas-database/ifas-data-import-export test`
(`DataExporterTest`, `ReferenceDataDeduplicatingFilterTest`) — die Banner-Reihenfolge-Tests dort
dürfen nicht kippen.

Gegenprobe ohne Fix: Test 3 muss rot sein (Reihenfolge `KAG, INV, HWA, HDP`).

---

## Fachliche Antwort für den Kollegen (kein Code, nur Kontext)

**n:n ist abgebildet, aber ohne `source =`.** Für 1:n/n:1 genügt ein Pfadausdruck
(`@Mapping(target = "depBank", source = "depBank.depBank")`). Bei n:n geht das nicht, deshalb
steht dort ein `expression =` — `DtoEntityMapper.java:66-82`:

```java
@Mapping(target = "lieferanten", expression = "java( entity.getLieferanten().stream().map(Lieferant::getLieferId).distinct().toList() )")
public abstract HdpDto toDto(Hdp entity);

@Mapping(target = "lieferanten", expression = "java( lookup.getEntities(Lieferant.class, dto.getLieferanten()) )")
public abstract Hdp toEntity(HdpDto dto);
```

Konventionen dahinter:

- Das DTO trägt die Beziehung als `List<String>` der Fremd-PKs — `HdpDto.lieferanten`,
  `KagDto.lieferanten`. Keine verschachtelten Objekte.
- Die Beziehung wird **nur von einer Seite** geschrieben: `LieferantDto` hat weder `hdps` noch
  `kags`, das ist in `DtoEntityMapper.java:197` per
  `@BeanMapping(ignoreUnmappedSourceProperties = {"kags", "hdps", …})` explizit abgewählt.
- Es gibt keine generische n:n-Unterstützung. Ein neues `@ManyToMany` bricht wegen
  `unmappedSourcePolicy = ERROR` den MapStruct-Build, bis diese zwei Zeilen von Hand da stehen.

**YAML-Form** (`SteuerMeldungDomainValidatorTest_lieferant_authorized.yaml`, `testdata_HDP_2.yaml`):

```yaml
- !<LIEFERANT>
  lieferId: "af_1741"
  inlandAusland: "A"
- !<HDP>
  depBank: 58000
  bezeichnung: "Hypo Vorarlberg Bank AG"
  lieferanten:
    - "af_1741"
```

**Zur `HDP_lieferanten`-Tabelle**: Die legt Flyway an, nicht der Import —
`db/migration/postgres15/V011__lieferanten.sql:41` (H2 nutzt dieselben Skripte,
`DbConfigs.java:23-25`) bzw. `sybase16/V011__lieferanten.sql:47`. Der Import befüllt sie nur,
über das `@ManyToMany` auf `Hdp`.

**Fallstricke:**

1. **Reihenfolge**: LIEFERANT vor HDP. Deshalb pro Typ eine Datei exportieren und die Reihenfolge
   beim Import steuern (so macht es `MeldefondsListDataCreator`: LIEFERANT Zeile 40, HDP Zeile 43),
   oder im Web-UI (Data Export) einen Typ pro Zeile in der richtigen Reihenfolge. `FondsExporter`
   macht es intern korrekt (`getAllLieferanten` vor Kag/Hdp, `FondsExporter.java:255-259`). Über
   `DatabaseYamlExportTool` geht die Reihenfolge derzeit verloren — siehe Fix oben.
2. **Fehlendes `lieferanten` löscht**: `getEntities(null)` liefert `List.of()`, und `em.merge`
   ersetzt die Collection. Ein HDP-Eintrag ohne `lieferanten` **löscht** also bestehende
   Join-Zeilen. Relevant für `standard_HDP_data.yaml` (enthält kein `lieferanten`) und
   `StammBasedataCreator`, das HDP vor LIEFERANT lädt.
3. **Sybase hat keine FKs** auf `HDP_lieferanten` (die Postgres-Migration schon) — eine falsche
   Reihenfolge fällt dort nicht auf, sondern erzeugt verwaiste Join-Zeilen.
4. Die Spalten `guelt` und `user_id` der Join-Tabelle sind im `@ManyToMany` nicht gemappt und
   gehen beim Round-Trip verloren (auf Sybase per `default` gefüllt, auf Postgres `null`).
