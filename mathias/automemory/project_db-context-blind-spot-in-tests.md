---
name: project_db-context-blind-spot-in-tests
description: In ifas-integration-tests zeigen alle database-context.*.db-key auf dieselbe h2-test-DB (Kontextfehler unsichtbar); Routing-/Commit-Reihenfolge-Beweise gehören ins Modul ifas-integration-tests-multidbctx (drei H2).
metadata: 
  node_type: memory
  type: project
  originSessionId: 528d937e-26e2-4cf1-9de9-816f7d2b9944
  modified: 2026-09-14T11:29:45.798Z
---

`ifas-integration-tests/src/test/resources/application.properties` mappt **alle**
`database-context.*.db-key` (business, legacy-business, web-ui-default, business-new-introduced,
ausschuettung-tmp, ausschuettung-asf, work-queue …) auf `h2-test`. Ein Seed im einen und ein
Lesezugriff im anderen Kontext treffen deshalb zufällig dieselbe Datenbank — der Fehler zeigt sich
erst im Server-Deployment, wo die Keys auseinanderfallen.

Zwei Fälle, die genau daran hingen (beide 2026-09-14 gefunden):

- `kurs..tax_code` wurde über den Fondspreise-Kontext (heute `business-new-introduced`) geseedet,
  aber im **Business**-Kontext
  gelesen. Deshalb stand es auch nicht im Standard-Basisimport — jede per Basisimport bestückte DB
  kannte keine Preiscodes (`f89c5d06b`).
- Der `PreisMeldungDiffJob` erbte den Kontext des Einreichers; beide Einstiege binden dort
  `sybase-gast` (`9e5f0ecdb`).

**Why:** In `ifas-integration-tests` sind Kontextfehler strukturell untestbar, weil das Profil ein DBMS
für alle Kontexte fährt. Nur die Deklaration verrät die Wahrheit.

**Gegenstück (seit 2026-10-09 genutzt):** `ifas-testing/ifas-integration-tests-multidbctx` fährt drei
physische H2 mit dem produktiven Routing — `h2-test-write` = `business`, `h2-test` =
`business-new-introduced`/`legacy-business`, `h2-infra-test` = Job-System/Work-Queue/Filestore
(`workqueue.enabled=false`, Executor von Hand bauen). Dort gehören Tests hin, die Routing oder
Commit-Reihenfolge über Kontexte beweisen (`PreisVersionSyncJobCommitOrderMultiDbCtxTest`, `03804889c`).
Falle: eine Testklasse mit eigenem `properties=` und `workqueue.enabled=true` hält ihren gecachten
Kontext samt pollendem Executor am Leben, der Items späterer Klassen aus der geteilten In-Memory-Infra-DB
claimt — `@DirtiesContext` dort.

**How to apply:** Bei jeder kontextgerouteten Tabelle nicht dem Seeding-Code glauben, sondern dem
`package-info` des Persistence-Pakets und dem `@Table(catalog=…)` der Entity — dort steht, in
welchem Kontext sie tatsächlich gelesen wird. Für Schreibziele gilt das Muster der
Ausschüttungs-Kette: Kontext aus der Konfiguration auflösen, nie vom Einreicher erben
([[project_sybase-schema-freeze]]).
