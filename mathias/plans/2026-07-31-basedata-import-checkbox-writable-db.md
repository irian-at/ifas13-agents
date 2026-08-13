# Basisdaten-Import-Checkbox an "writable DB" koppeln

**Datum:** 2026-07-31
**Status:** Entwurf — zur Prüfung

## Ziel

Die Checkbox "Standard-Basisdaten importieren" (Recalc- und ISIN-/ESTB-Seiten) soll

1. **genau den Zustand darstellen, der im Backend verwendet wird**, und
2. **deaktiviert sein, wenn die aktuelle DB nicht schreibbar ist** — sonst immer togglebar.

Sie darf nicht mehr am Feature-Flag der Datenverwaltung hängen.

---

## Ausgangslage

### Wie es aktuell verdrahtet ist

Die Checkbox wird über das Model-Attribut `importBasedataCheckboxEnabled` gesteuert, das aus
`WebUiFeatureConfiguration.isClearDatabaseCheckboxEnabled(...)`
(`ifas-web/ifas-web-ui/.../web/config/WebUiFeatureConfiguration.java:106`) kommt. Dahinter steht die
Allowlist-Property

```
web-ui.feature.clear-and-import-basedata-enabled-for-databases=h2-db1,h2-db2,h2-db3
```

Dieses Flag gehört fachlich zur **Datenverwaltung → Import**
(`web/datamanagement/DataImportPageController.java:52,168`), wo es die tatsächlich destruktive Aktion
"DB leeren + Basisdaten importieren" absichert. Die Recalc-/ISIN-Seiten haben es mitbenutzt.

### Drei verschiedene Bedeutungen desselben Flags

| Ort | Verwendung |
|---|---|
| `DataImportPageController:52,168` | Gate für die echte Clear+Import-Aktion (**korrekt**) |
| `stm-recalc-form.html:160`, `stm-recalc-detail.html:499`, `stm-recalc-list.html:371` | `th:disabled` |
| `estb-report-diff-form.html:37` | `th:checked` — also **Default-Wert**, kein Gate |

### Warum das Probleme macht

- **Ein deaktiviertes Checkbox-Feld wird vom Browser nicht submitted.** Zusammen mit
  `@RequestParam(..., defaultValue = "false")` ist "abgewählt" nicht von "nicht gesendet"
  unterscheidbar → der Wert fällt still auf `false`, ohne Rückmeldung.
- Das Form-JS (`stm-recalc-form.html:348-357`) **entfernt zusätzlich still den Haken**, wenn nach dem
  Ankreuzen die Datenquelle gewechselt wird.
- Die Einschränkung existiert **ausschließlich clientseitig**. Ein POST mit `importBasedata=true`
  würde `basedataCreator.getBasedataDtos()` auch gegen `sybase-gast` importieren — es gibt keine
  serverseitige Prüfung.
- `writable-context-mapping.sybase-gast=NONE` schützt hier **nicht**: dieser Mechanismus greift nur
  für Schreibzugriffe über `DatabaseWriteSwitch.doWithWritableDbContext(...)`
  (`service/dbctx/DefaultDatabaseWriteSwitch.java:57-68`). Der Basisdaten-Import
  (`dataImporter.importTestData(...)`) läuft direkt im aktuellen Kontext daran vorbei.

### Namensgebung

`RecalculationSetting.clearDatabaseAndImportBasedata` trägt bereits den Kommentar
*"bad name: data is actually only imported NOT cleared"* (`RecalculationSetting.java:20`). Der Import
ist ein reines `em.merge`-Upsert (`DataImporter.importTestDataEntry`), er löscht nichts. Das Label in
`estb-report-diff-form.html:39` ("DB leeren & neu laden") ist entsprechend falsch.

---

## Design

**Eine einzige Bedingung: "Hat der aktuelle DB-Kontext ein beschreibbares Ziel?"**

Diese Frage berechnet `DefaultDatabaseWriteSwitch` heute schon — nur privat
(`getWritableDbContextForCurrentDbContext()`, `:49-55`; `NONE` → `Optional.empty()`). Sie wird auf dem
Interface öffentlich gemacht und ersetzt die Allowlist auf den Recalc-/ISIN-Seiten. Keine neue
Property.

Resultierendes Verhalten:

| DB-Kontext | `writable-context-mapping` | Checkbox |
|---|---|---|
| `h2-db1/2/3` (Temp-DB) | kein Eintrag → schreibt in sich selbst | **aktiv** |
| `postgres-server` | kein Eintrag | **aktiv** |
| `sybase-ifasneu` | → `sybase-ifasneu` | **aktiv** |
| `sybase-gast` | → `NONE` | **deaktiviert** |

Damit ist "nicht gesendet → `false`" wieder *wahr*: die Checkbox ist genau dann deaktiviert, wenn das
Backend den Import ohnehin nicht ausführen würde. Ein Hidden-Field-Workaround ist nicht nötig.

⚠️ **Abweichung zum Ist-Zustand:** `postgres-server` und `sybase-ifasneu` sind heute per Allowlist
ausgeschlossen, künftig wären sie aktiv. Das folgt direkt aus der Anforderung
"deaktiviert wenn nicht auf einer schreibbaren DB" — falls diese beiden weiter ausgeschlossen bleiben
sollen, muss die Bedingung enger gefasst werden (siehe Offene Punkte).

---

## Änderungen im Detail

### 1. `DatabaseWriteSwitch` — Prädikat veröffentlichen

Datei: `ifas-domain/ifas-domain-core/src/main/java/at/oekb/ifas/domain/core/DatabaseWriteSwitch.java`

Neue Methode auf dem Interface (bewusst **ohne** `default`, damit alle Implementierungen sie
explizit beantworten müssen):

```java
/** Whether the current database context has a writable target at all. */
boolean hasWritableDbContext();
```

Anzupassende Implementierungen — vollständige Liste (Suche: `implements DatabaseWriteSwitch`):

| Implementierung | Rückgabe |
|---|---|
| `DefaultDatabaseWriteSwitch` (`service/dbctx/`) | `getWritableDbContextForCurrentDbContext().isPresent()` |
| `DatabaseWriteSwitch.NO_SWITCH` (anonym, `:37`) | `true` |
| `DatabaseWriteSwitch.NoOpDatabaseWriteSwitch` (`:57`) | `false` |

Weitere Implementierungen existieren nicht. Verwender der Konstanten:
`IntegrationTestConfig:51` (`NO_SWITCH`), `IfasDevToolApplication:27` (`NO_OP`) — beide ohne
Anpassungsbedarf.

Bean-Definition: `IfasMainApplication:54`. `ifas-web-ui` hängt über `ifas-main-service` bereits am
Interface (`ifas-web/ifas-web-ui/pom.xml:44`), es ist also injizierbar.

### 2. Model-Attribut umstellen

`featureConfiguration.isClearDatabaseCheckboxEnabled(multiDbCtxDatabaseSessionManager)` →
`databaseWriteSwitch.hasWritableDbContext()` an folgenden Stellen:

| Datei | Zeile |
|---|---|
| `web/testing/StmRecalcFormPageController.java` | `113-115` (GET) |
| `web/testing/StmRecalcFormPageController.java` | `276` (AJAX-Endpoint `/clear-database-checkbox-enabled`) |
| `web/testing/StmRecalcDetailPageController.java` | `141-142` |
| `web/testing/StmRecalcListPageController.java` | `100-101` |
| `web/testing/IsinAnforderungDiffFormPageController.java` | `85-86` |
| `web/testing/IsinAnforderungDiffDetailPageController.java` | `114-115` |

`DataImportPageController:52,168` bleibt **unverändert** auf `WebUiFeatureConfiguration`.

Zu klären: Ob `WebUiFeatureConfiguration.isClearDatabaseCheckboxEnabled(...)` danach nur noch von der
Datenverwaltung genutzt wird (dann ggf. dorthin verschieben) oder unverändert bleibt.

### 3. Templates

- `stm-recalc-form.html:160`, `stm-recalc-detail.html:499`, `stm-recalc-list.html:371`:
  `th:disabled` bleibt inhaltlich gleich, speist sich nur aus der neuen Quelle.
- `stm-recalc-list.html:376`: das innere `disabled` der Batch-Repeat-Checkbox bleibt — das ist die
  Override-Mechanik (`.batch-override-toggle`-JS, `:612-619`), kein Bug.
- `estb-report-diff-form.html:37`: `th:checked="${importBasedataCheckboxEnabled}"` ist die dritte
  Bedeutung des Flags und muss entschieden werden — vermutlich `th:disabled` analog zu den anderen
  Seiten, plus Korrektur des Labels `:39` ("DB leeren & neu laden" stimmt nicht).
- Das JS `updateClearDatabaseCheckbox()` (`stm-recalc-form.html:346-366`) kann bleiben: der Endpoint
  liefert künftig die Writable-Aussage. Das stille Abwählen (`:353-355`) ist dann korrekt, weil das
  Backend in diesem Kontext tatsächlich nicht importieren würde.

### 4. Serverseitige Absicherung (neu)

Bleibt notwendig, weil der Import den `DatabaseWriteSwitch` umgeht. In jedem POST-Endpoint vor dem
Bauen des `RecalculationSetting`:

```java
if (importBasedata && !databaseWriteSwitch.hasWritableDbContext()) {
    redirectAttributes.addFlashAttribute("errorMsg",
            "Basisdaten-Import ist für die Datenbank '%s' nicht möglich (nicht schreibbar)."
                    .formatted(databaseContextHelper.getCurrentDbKey()));
    return "redirect:/ui/stm-recalc/error";
}
```

Betroffene Endpoints:

| Controller | Endpoint | Param / Verwendung |
|---|---|---|
| `StmRecalcFormPageController` | `POST /upload` | `:133` → `:175` |
| `StmRecalcDetailPageController` | `POST /{id}/repeat` | `:234` → `:250` |
| `StmRecalcDetailPageController` | `POST /{id}/archive-and-repeat` | `:279` → `:295` |
| `StmRecalcListPageController` | Batch-Repeat | `:237-238` → `:259` (`RepeatBatchOverride`) |
| `IsinAnforderungDiffFormPageController` | `POST /upload` | `:102` → `:133` |

Wiederverwendung statt Duplikat: die Prüfung als eine kleine private Helper-Methode je Controller
oder — besser — als gemeinsamer Helper (z. B. in `web/multidb/` neben
`MultiDbCtxDatabaseSessionManager`), damit die Meldung einheitlich bleibt.

Fehlerverhalten: **laut ablehnen**, nicht still auf `false` korrigieren. Stilles Korrigieren würde
genau das Verhalten reproduzieren, das behoben werden soll.

---

## Tests

Konventionen: given-when-then, AssertJ, `@Inject`.

1. `DefaultDatabaseWriteSwitchTest`
   - `givenContextMappedToNone_whenHasWritableDbContext_thenFalse`
   - `givenContextWithoutMapping_whenHasWritableDbContext_thenTrue`
   - `givenContextMappedToOtherDb_whenHasWritableDbContext_thenTrue`
2. Controller-Test (`@WebMvcTest` oder bestehender Web-Test-Setup) für `POST /ui/stm-recalc/upload`
   - `givenNoImportBasedataParam_whenUpload_thenSettingIsFalse`
   - `givenImportBasedataTrueOnWritableDb_whenUpload_thenSettingIsTrue`
   - `givenImportBasedataTrueOnNonWritableDb_whenUpload_thenRejectedWithErrorMsg`
3. Regressionsschutz für die stillen Defaults: Test, dass ein fehlender Parameter **nicht**
   versehentlich als `true` interpretiert wird (Absicherung gegen künftige Hidden-Field-Umbauten).

---

## Verifikation nach dem Umbau

1. Auf einer Temp-DB (`h2-db1`): Checkbox aktiv, ankreuzen, Recalc starten →
   Detailseite zeigt "Basisdaten importieren: **Ja**" (`stm-recalc-detail.html:256-259`), und das
   Protokoll enthält den Abschnitt **Basisdaten** mit `STEUER_FIELD: 10726` /
   `STEUER_BEH_FIELD: 929` (`RecalculationDomainService:102`).
2. Danach in der Temp-DB:
   `select versions_nr, count(*) from steuer_fields group by versions_nr;`
   → Version 6 muss **2251** liefern (nicht 974).
3. Auf `sybase-gast`: Checkbox deaktiviert; ein manuell abgesetzter POST mit `importBasedata=true`
   wird mit Fehlermeldung abgelehnt.

---

## Nicht Teil dieser Änderung

- **Ursache des ursprünglichen Fehlers** (`Unknown numeric code for field name: Ausschuettung_e`):
  Die Temp-DB enthielt nur die 974 V6-`steuer_fields`-Zeilen aus
  `gf1-d20260724-export.yaml.txt` (Bundle-Testdaten werden in
  `RecalculationDomainService:105-115` **immer** importiert, unabhängig vom Flag), nicht die 2251
  Zeilen der Standard-Basisdaten. Diese Änderung verhindert die Wiederholung, behebt aber nicht die
  bereits befüllte DB.
- Umbenennung von `RecalculationSetting.clearDatabaseAndImportBasedata` → eigener Commit wert
  (Feld ist Teil des in `infra.stm_recalc_jobs.recalculation_settings` persistierten JSON;
  `@JsonIgnoreProperties(ignoreUnknown = true)` fängt alte Jobs ab, ein `@JsonAlias` wäre nötig,
  damit bestehende Jobs den Wert behalten).
- Anzeige des Flags in der Recalc-Liste (`stm-recalc-list.html`, analog BMF-Version `:261`).
- Beschriftung der Batch-Repeat-Checkbox (`stm-recalc-list.html:375-378`): Kombination
  "überschreiben = an" + "Wert = aus" erzwingt den Import **aus** — fachlich korrekt, aber
  missverständlich.

---

## Offene Punkte

1. **Sollen `postgres-server` und `sybase-ifasneu` weiterhin ausgeschlossen sein?** Mit dem reinen
   Writable-Kriterium wären sie aktiv. Falls nein: zusätzliche Einschränkung nötig (z. B. nur
   In-Memory-/Temp-DBs), was wieder auf eine Allowlist hinausliefe.
2. **ESTB-Formular** (`estb-report-diff-form.html:37`): `th:disabled` wie die anderen Seiten, oder
   soll das Feld dort bewusst vorbelegt bleiben?
3. **Bleibt `WebUiFeatureConfiguration.clearAndImportBasedataEnabledForDatabases`** nach dem Umbau
   in der aktuellen Form bestehen (nur noch Datenverwaltung), oder wird es dorthin verschoben?
