# Generischer Lookup für bestehende Links im DTO-Mapper

## Context

`DtoEntityLookupHelper.getLieferantenOrLinked` (uncommitted, Arbeitskopie auf `master`) vereint zwei Dinge:
die Auflösung der im DTO genannten Lieferanten und das Nachladen der bereits verknüpften, wenn das DTO
keine Liste nennt. Die null-Regel ist dadurch in der Helper-Methode versteckt statt dort sichtbar, wo
gemappt wird, und die Methode ist auf `Lieferant` festgelegt.

Ziel: eine generische Methode, die für jede n:n-Beziehung die aktuell verknüpften Entities des Owners
liefert, und die Entscheidung „Liste genannt → diese, sonst → bestehende“ steht in der
MapStruct-Expression. Verhalten bleibt gleich (fehlt = Links bleiben, `[]` = Links weg, Liste = ersetzt).

Der Plan für den Stammdaten-Export ist damit zurückgestellt; die Semantik „fehlt = unverändert“ bleibt.

## Änderungen

### `ifas-database/ifas-data-import-export/.../importexport/dto/DtoEntityLookupHelper.java`

`getLieferantenOrLinked` ersetzen durch:

```java
/**
 * The entities the owner already links to through {@code association}, or none when the owner is
 * not in the database yet - for a DTO that leaves an association out, since {@code merge} replaces
 * the whole collection.
 */
public <O, E> List<E> getLinkedEntities(Class<O> ownerType, Object ownerId, Function<O, List<E>> association) {
    O owner = ownerId != null ? em.find(ownerType, ownerId) : null;
    List<E> linked = owner != null ? association.apply(owner) : null;
    return linked != null ? List.copyOf(linked) : List.of();
}
```

- Import `Lieferant` entfällt, `Function` bleibt.
- Stil wie die Nachbarn (`getEntity`, `getEntities`): keine JSpecify-Annotationen, die Klasse ist nicht `@NullMarked`.

### `ifas-database/ifas-data-import-export/.../importexport/dto/DtoEntityMapper.java`

Die zwei `lieferanten`-Mappings in `toEntity(KagDto)` / `toEntity(HdpDto)`:

```java
@Mapping(target = "lieferanten", expression = "java( dto.getLieferanten() != null "
        + "? lookup.getEntities(Lieferant.class, dto.getLieferanten()) "
        + ": lookup.getLinkedEntities(Kag.class, dto.getKag(), Kag::getLieferanten) )")
```

analog für HDP mit `Hdp.class, dto.getDepBank(), Hdp::getLieferanten`. Konkatenierte Konstante,
damit die Zeile lesbar bleibt (Annotation-Werte dürfen Compile-Time-Konkatenation sein).

### Nicht angefasst

- `Lieferant` (`mappedBy`), `Kag`/`Hdp` (FK-Namen), `FondsExporter` (volle Währungstabellen), Tests.
- `DataImporterTest` deckt das Verhalten unverändert ab; kein neuer Test nötig.

## Verifikation

1. `mvn -Pno-proxy -o -q install -DskipTests -pl ifas-database/ifas-data-import-export`
2. Generierten Mapper prüfen: `target/generated-sources/.../DtoEntityMapperImpl.java` enthält den
   Ternary in `toEntity(KagDto)`/`toEntity(HdpDto)`.
3. `mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest='DataImporterTest,DataExportServiceTest,SteuerMeldungDomainValidationServiceTest,KestMeldefristCheckDomainServiceTest' -Dsurefire.failIfNoSpecifiedTests=false`
   — `DataImporterTest` läuft auf H2, Postgres und Sybase.
4. Memory-Notiz `project_importexport-nn-lieferanten.md`: Methodenname auf `getExistingLinkedEntities` ändern.
