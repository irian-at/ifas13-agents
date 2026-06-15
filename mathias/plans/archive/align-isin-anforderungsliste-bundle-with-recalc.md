# ISIN Anforderungsliste — angleichen des Ergebnis-Bundles an Rekalkulation

## Context

Der Ergebnis-Bundle (ZIP) des **STM-Rekalkulation-Jobs** enthält neben den Berechnungs-Outputs auch:
- die ursprünglichen Eingabe-Dateien (alle `BundleFileType` mit `isInputFile() && isAllowedToBeWrittenToOutputBundle()`),
- eine via `FondsExporter` erzeugte **Testdaten-YAML** (`*_testdata#recalc.yaml.txt`).

Der **ISIN-Anforderungsliste-Job** (EstB-Report-Diff) hingegen schreibt aktuell ausschließlich die berechneten EstB-Outputs (`#neu_EStB.csv`, `#neu_EStB_erweitert.csv`, `#neu_error.log`, `#neu_info.log`) plus Diff-Reports — **keine Input-Files, keine YAML**. Das erschwert die Reproduktion und Nachvollziehbarkeit.

**Ziel:** Den ISIN-Job so erweitern, dass sein Ergebnis-Bundle dieselben Datei-Kategorien enthält wie der Rekalkulations-Job (jeweils sofern für den ISIN-Anwendungsfall vorhanden). Steuerung über zwei neue Schalter in `EstbReportSetting`, die wie die bestehenden Checkboxen (`importBasedata`, `performStmFieldDiff`, `skipUnsupportedVersions`) im Upload-Formular gesetzt werden.

## Approach

Zwei Inhalte werden ergänzt — mit **unterschiedlicher Steuerung**:

- **Input-Files**: **immer mitgeschrieben**, kein Setting, keine UI-Checkbox. Analog zur Rekalkulation, wo die vier Bundle-Content-Flags im `StmRecalcJobExecutionService` hartkodiert auf `true` stehen und nicht über das Form gesteuert werden.
- **Testdaten-YAML**: über ein neues boolesches Feld `includeTestdataYaml` in `EstbReportSetting` und eine zugehörige UI-Checkbox steuerbar. **Default `true`** (Checkbox initial angehakt; User kann sie abwählen, um den YAML-Export wegzulassen).

Die Logik wird **am Vorbild von `RecalculationOutputs` orientiert**. Das `TestdataExporter`-Interface wird aus `RecalculationOutputs` **herausrefaktoriert** in ein eigenständiges Top-Level-Interface, damit beide Output-Klassen es konzeptuell sauber teilen (siehe Punkt 7 unten).

## Critical files (changes)

### 1. `ifas-services/.../service/estbreport/EstbReportSetting.java`
Record um **ein** boolesches Feld erweitern (Input-Files-Flag wird **nicht** ins Setting aufgenommen — immer-an wird im Execution-Service hartkodiert):
```java
public record EstbReportSetting(
        boolean importBasedata,
        @Nullable String databaseContext,
        boolean performStmFieldDiff,
        boolean skipUnsupportedVersions,
        boolean includeTestdataYaml
) {}
```
Jackson hat `@JsonIgnoreProperties(ignoreUnknown = true)`, ältere serialisierte Settings deserialisieren weiterhin (fehlendes Feld → `false`; das ist eine **bewusste Abweichung vom UI-Default `true`**, betrifft aber nur historische Jobs, die nie eine YAML-Datei beigelegt bekommen sollten).

### 2. `ifas-web-ui/.../web/testing/EstbReportDiffFormPageController.java`
- Im `@PostMapping("/upload")` einen neuen Parameter ergänzen: `@RequestParam(value = "includeTestdataYaml", required = false, defaultValue = "false") boolean includeTestdataYaml`.
  Wichtig: `defaultValue = "false"`, weil ein **nicht angehakter** Checkbox-Submit keinen Wert sendet → muss `false` werden. Der „Default true" wird ausschließlich über die initial angehakte Checkbox im Template realisiert.
- An `submissionService.submit(...)` durchreichen.

### 3. `ifas-web-ui/.../resources/templates/estb-report-diff-form.html`
Im Block `Optionen` (Zeilen 32–57) eine zusätzliche Checkbox analog zu den bestehenden anlegen, **initial angehakt**:
```html
<div class="form-check mb-2">
    <input class="form-check-input" type="checkbox" id="includeTestdataYaml" name="includeTestdataYaml"
           value="true" checked>
    <label class="form-check-label" for="includeTestdataYaml">
        Testdaten-YAML ins Ergebnis-Bundle exportieren
    </label>
</div>
```
Keine Checkbox für Input-Files (immer aktiv).

### 4. `ifas-services/.../service/estbreport/EstbReportDiffJobSubmissionService.java`
- `submit(...)` um den booleschen Parameter `includeTestdataYaml` erweitern.
- Im `EstbReportSetting.builder()` (Zeilen 61–66) das neue Feld setzen.

### 5. `ifas-services/.../service/estbreport/EstbReportDiffJobExecutionService.java`
- **Constructor injection für `FondsExporter`** ergänzen (FQN `at.oekb.ifas.importexport.FondsExporter`; bereits transitive Abhängigkeit, kein neues `pom.xml`-Eintrag nötig, vgl. `StmRecalcJobExecutionService` Zeile 64–69).
- Lokale Methode analog `StmRecalcJobExecutionService.exportTestdata(...)` (Zeilen 251–253):
  ```java
  private void exportTestdata(List<String> isinList, LocalDate stichtag, OutputStream out) {
      fondsExporter.exportFondsByIsin(out, isinList, stichtag, 0, false, false);
  }
  ```
- Aufruf von `EstbReportDiffOutputs.writeResultZip(...)` (Zeilen 126–129) erweitern:
  - `includeInputFiles` **hartkodiert `true`** (analog Rekalkulation),
  - `includeTestdataYaml` aus `setting.includeTestdataYaml()`,
  - `testdataExporter` als Methodenreferenz `this::exportTestdata`.

### 6. `ifas-domain-stm/.../domain/stm/estbreport/EstbReportDiffOutputs.java`
Signatur erweitern (verwendet das neu extrahierte `TestdataExporter`-Interface):
```java
public static void writeResultZip(
        String isinFilename,
        EstbReportDiffResult result,
        boolean includeInputFiles,
        boolean includeTestdataYaml,
        @Nullable TestdataExporter testdataExporter,
        OutputStream zipOut
) throws IOException
```
Im `try (ZipOutputStream zos = ...)`-Block nach den bestehenden Writes:

**(a) Input-Files** — Filter und Loop analog `BundleRecalculationResults.getInputFileTypesAndNames(...)` (Zeilen 137–147 in `BundleRecalculationResults.java`):
```java
if (includeInputFiles) {
    for (var typeAndName : result.inputBundle().getAllFiles().keySet()) {
        if (typeAndName.type().isInputFile()
                && typeAndName.type().isAllowedToBeWrittenToOutputBundle()) {
            writeInputBundleFileEntry(zos, result.inputBundle(), typeAndName);
        }
    }
}
```
Eine kleine `private static` Helper-Methode `writeInputBundleFileEntry(...)` neben den bestehenden `writeEntry`-Helfern in derselben Datei einfügen. Wir **duplizieren bewusst** nicht aus `RecalculationOutputs`, da das dortige Konstrukt eng mit dessen `switch` über alle Output-Typen verzahnt ist — eine separate, schlanke Hilfsmethode hier ist sauberer als ein Refactoring quer durch beide Output-Klassen.

**(b) Testdaten-YAML** — orientiert an `RecalculationOutputs.writeTestDataYamlFile(...)` (Zeilen 566–584):
```java
if (includeTestdataYaml && testdataExporter != null) {
    List<String> isinList = extractIsinsFromBundle(result.inputBundle());
    if (!isinList.isEmpty()) {
        LocalDate stichtag = /* siehe Hinweis unten */;
        var entry = new ZipEntry(EstbReportFilenames.testdataYaml(isinFilename));
        zos.putNextEntry(entry);
        testdataExporter.exportTestData(isinList, stichtag, new NonClosingOutputStream(zos));
        zos.closeEntry();
    }
}
```
- **ISIN-Quelle:** Die ISIN-Liste aus dem Input-Bundle einlesen. Es existiert genau eine Ressource `BundleFileType.ISIN_LIST_FILE` (vgl. `EstbReportDiffJobExecutionService` Zeile 95). Im EstB-Service muss bereits eine Parser-Logik für diese Datei existieren (über `EstbReportDiffService.process(...)`) — bei der Implementierung den dort verwendeten Reader wiederverwenden. Falls kein wiederverwendbarer Reader existiert, eine triviale Zeilen-Lese-Hilfsmethode (`CsvSchema`-basiert wie bei anderen Bundle-Files) ergänzen.
- **Stichtag:** Aus `EstbReportDiffResult` ableiten. Wenn der Stichtag dort nicht direkt liegt, an `writeResultZip(...)` als zusätzlichen Parameter durchreichen (kommt vom Service-Aufrufer via `jobInfo.job().getKeyDate()`).
- **Filename-Konstante:** Neue Methode `EstbReportFilenames.testdataYaml(isinFilename)` analog den bestehenden Naming-Helpern. Konvention z. B. `{basename}_testdata#estb.yaml.txt`.

### 7. `TestdataExporter`-Interface — herausrefaktorieren

Schritte (in der IDE, via **„Refactor → Move"** — siehe `ide-refactoring.md`):

1. In `RecalculationOutputs.java` (Zeilen 561–564) den verschachtelten Interface-Block markieren und per **„Move Inner to Upper Level"** (oder Cursor auf `TestdataExporter` → F6 → Move) zu einer eigenen Top-Level-Datei extrahieren.
2. Ziel-Package: `at.oekb.ifas.domain.stm.testdata` (neues Paket im selben Modul `ifas-domain-stm`). Begründung: Das Konzept „Testdaten-Export für eine ISIN-Liste zu einem Stichtag" ist nicht recalc- oder estbreport-spezifisch; ein dediziertes `testdata`-Paket bietet einen sauberen, gemeinsamen Ort.
3. Resultierende Datei: `at.oekb.ifas.domain.stm.testdata.TestdataExporter` mit `@NullMarked` und ggf. Javadoc-Hinweis auf den fachlichen Zweck.
4. IntelliJ aktualisiert sämtliche bestehenden Referenzen (in `RecalculationOutputs`, `StmRecalcJobExecutionService`) automatisch.
5. In `EstbReportDiffOutputs` und `EstbReportDiffJobExecutionService` die neue FQN importieren.

Begründung gegen Wiederverwendung als geschachteltes Interface: `RecalculationOutputs.TestdataExporter` würde aus `EstbReportDiffOutputs` eine fachfremde Abhängigkeit erzeugen (estbreport hängt an recalc, obwohl beide gleichwertige Konsumenten desselben Konzepts sind).

## Reuse / shared utilities

| Zweck | Wiederverwenden | Pfad |
|---|---|---|
| Testdaten-Export-Callback | `TestdataExporter` (nach Move-Refactoring) | `ifas-domain-stm/.../domain/stm/testdata/TestdataExporter.java` (neu) |
| YAML-Erzeugung | `FondsExporter.exportFondsByIsin(...)` (bereits in `ifas-main-service` Dependency) | `ifas-data-import-export/.../FondsExporter.java` |
| Input-File-Filter-Logik | Muster aus `BundleRecalculationResults.getInputFileTypesAndNames(...)` (Filter-Predicate kopieren) | `ifas-domain-stm/.../recalc/BundleRecalculationResults.java:137-147` |
| Pattern zum YAML-Write | Muster aus `RecalculationOutputs.writeTestDataYamlFile(...)` | `ifas-domain-stm/.../recalc/RecalculationOutputs.java:566-584` |

## Verification

1. **Build:**
   ```bash
   mvn -Pno-proxy clean compile
   ```

2. **Integration-Test erweitern / spiegeln:** Es gibt bereits `EstbReportTest` in `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/estbreport/`. Test-Cases ergänzen:
   - **Case A** — `includeTestdataYaml=true`: Job ausführen, ZIP entpacken und prüfen:
     - die Original-ISIN-Liste (`*.csv`) ist enthalten (immer-an),
     - eine `*_testdata#estb.yaml.txt` ist enthalten und nicht leer,
     - die Standard-EstB-Outputs sind weiterhin enthalten.
   - **Case B** — `includeTestdataYaml=false`: Job ausführen, ZIP entpacken und prüfen:
     - die Original-ISIN-Liste (`*.csv`) ist trotzdem enthalten (immer-an),
     - **keine** `*_testdata#estb.yaml.txt`,
     - die Standard-EstB-Outputs sind enthalten.

3. **Manuelle UI-Verifikation:**
   ```bash
   # In IDE: LocalH2OnlyIfasApplication starten
   ```
   - `http://localhost:8080/ifas-uat` → ISIN-Anforderungsliste / EstB-Report-Diff-Formular öffnen
   - die neue Checkbox „Testdaten-YAML ..." ist sichtbar und **initial angehakt**
   - Datei hochladen ohne Änderung → Ergebnis-ZIP enthält Input-CSV **und** YAML
   - Erneut hochladen mit abgewählter Checkbox → Ergebnis-ZIP enthält Input-CSV, **aber keine YAML**

4. **Backwards-compat:** Alte, in DB persistierte `EstbReportSetting`-JSON-Strings (ohne `includeTestdataYaml`) deserialisieren weiterhin (`@JsonIgnoreProperties(ignoreUnknown = true)`); fehlendes Feld → `false` → kein YAML-Export für historische Jobs (akzeptabel, da diese Jobs den Effekt vor der Änderung ohnehin nicht hatten).

## Out of scope

- Keine Konsolidierung von `RecalculationOutputs` und `EstbReportDiffOutputs` in eine gemeinsame Abstraktion (separate Aufgabe, ggf. später).
- Keine zusätzlichen Output-Dateien des Rekalkulations-Bundles (Prefilled Excel, Macro-Excel, Protocol-TXT-Varianten) — diese sind im ISIN-Kontext fachlich nicht anwendbar.
- Keine i18n-Migration der Form-Labels (existieren auch für die bisherigen Optionen nicht).