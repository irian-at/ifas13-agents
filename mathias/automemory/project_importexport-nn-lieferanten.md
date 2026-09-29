---
name: project_importexport-nn-lieferanten
description: "n:n im YAML-Import/Export (HDP/KAG ↔ Lieferant) — nur KAG/HDP-Seite ist owning; `lieferanten` fehlt = Links bleiben, `[]` = Links weg; Sybase ohne FKs."
metadata:
  node_type: memory
  type: project
  originSessionId: 1e7d63a5-40a0-4a42-983e-b7b4eb4c21ba
  modified: 2026-09-29T13:34:14.861Z
---

Stand 2026-09-28, Commit `ee12a63fc` auf master:

- `Kag.lieferanten` / `Hdp.lieferanten` sind die einzige owning Seite von `KAG_lieferanten` /
  `HDP_lieferanten` (FK-Namen dort); `Lieferant.kags`/`hdps` sind `mappedBy`, der Builder hat
  kein `hdps` mehr. Ein LIEFERANT-Import fasst die Links nicht an.
- `KagDto`/`HdpDto.lieferanten`: fehlt (null) → bestehende Links bleiben
  (Ternary in `DtoEntityMapper`, generisch über `DtoEntityLookupHelper.getExistingLinkedEntities`); `[]` → Links weg; Liste → ersetzt.
  YAML schreibt NON_NULL, ein Export mit leerer Liste steht als `lieferanten: []` drin.
- Damit räumt „Basisdaten importieren" (standard_KAG/HDP ohne `lieferanten`) keine
  Berechtigungen mehr ab, auch wenn das Fonds-YAML vorher per Data-Import-Seite geladen wurde.
- Abgesichert durch `DataImporterTest` (alle 3 DBMS). Volle Währungstabellen im Fonds-Export wurden verworfen; geplant ist ein eigener Stammdaten-Export (zurückgestellt).

Weiterhin gültig:

- `em.merge` ersetzt jede Collection (Hibernate 6.6 `CollectionType.replace` leert bei
  `original == null`). Seit `9f40d7eaa` sind die n:n-Collections `Set` statt `List`, also keine
  Bag mehr, die bei jeder Änderung per DELETE+INSERT komplett neu geschrieben wird.
- **Sybase hat auf `HDP_lieferanten` keine FKs**, Postgres/H2 schon. Eine falsche Importreihenfolge
  fällt dort nicht auf, erzeugt aber verwaiste Join-Zeilen. LIEFERANT vor KAG/HDP einreihen.
- ERR_LIEFERANT prüft nur `INV.vertreter → HDP_lieferanten` (`InvRepository.existsInvByWfsWknAndLieferId`).
- Recalc/ISIN-Diff importieren Basisdaten vor jedem Bundle, dann dessen `.yaml`s nach Dateiname.

**Why:** Die Link-Verluste waren still (keine Exception) und DBMS-abhängig sichtbar.

**How to apply:** Vor `ee12a63fc` gelten die alten Fallen (LIEFERANT-Import und
KAG/HDP ohne Liste löschen Links). Siehe [[project_stm-delivery-chain-test-harness]].
