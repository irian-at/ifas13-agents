---
name: project_importexport-nn-lieferanten
description: n:n im YAML-Import/Export (HDP/KAG ↔ Lieferant) — nur eine Seite wird geschrieben, fehlendes `lieferanten` löscht Join-Zeilen.
metadata:
  type: project
---

`HdpDto.lieferanten` / `KagDto.lieferanten` (`List<String>` der lieferIds) sind die einzige
Abbildung der `HDP_lieferanten` / `KAG_lieferanten` Join-Tabellen; `LieferantDto` lässt `hdps`
und `kags` bewusst weg, damit die Zeile nur einmal geschrieben wird (beide Entity-Seiten sind
owning, keine hat `mappedBy`).

Zwei Fallen, die man dem Code nicht ansieht:

- **Ein HDP-Eintrag ohne `lieferanten` löscht bestehende Join-Zeilen.**
  `DtoEntityLookupHelper.getEntities(type, null)` liefert `List.of()`, und `em.merge` ersetzt die
  Collection. Betrifft u.a. `standard_HDP_data.yaml` (enthält kein `lieferanten`) zusammen mit
  `StammBasedataCreator`, das HDP *vor* LIEFERANT lädt.
- **Sybase hat auf `HDP_lieferanten` keine FKs**, Postgres/H2 schon. Eine falsche Importreihenfolge
  fällt dort nicht auf, erzeugt aber verwaiste Join-Zeilen.

**Why:** Beides schlägt still fehl (verlorene Beziehung statt Exception), und der Unterschied
zwischen den DBMS lässt es wie ein Postgres-Problem aussehen.

**How to apply:** Beim Bauen von Stammdaten-Fixtures LIEFERANT vor HDP/KAG einreihen und prüfen,
ob ein späterer HDP-Import die Beziehung wieder wegräumt. Siehe
[[project_stm-delivery-chain-test-harness]].
