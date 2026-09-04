# Plan: oekb-Literal konsolidieren + ISIN-Listen-Berechtigung portieren

## Context

Bei der Analyse der `oekb`-Sonderbehandlung sind zwei Lücken aufgefallen, die als Follow-up
geschlossen werden sollen:

1. Der Bypass-Wert `"oekb"` steht als nacktes Literal an zwei Stellen im Code, ohne Konstante,
   ohne Doku. Er ist leicht mit der echten Lieferanten-Stamm-ID `db_oekbtest1` zu verwechseln —
   die aber ausdrücklich *nicht* gemeint ist.
2. Die Legacy-Berechtigungsprüfung für die ISIN-Listen-Sonderauswertung
   (`IsBerechtigt4IsinListe`, `m_st_meldung.cpp:1404`) wurde nie portiert. Sie fehlt für *alle*
   Lieferanten, nicht nur für `oekb`. Da die ISIN-Anforderungsliste im Parallelbetrieb per
   Diff-Job gegen das Altsystem verglichen wird, ist das eine echte Verhaltensabweichung.

Zwei getroffene Entscheidungen, die den Plan tragen:

- **`"oekb"` bleibt ein Literal-Schalter**, nur sauber als Konstante gefasst. Es ist das Pendant
  zum Legacy-Kommandozeilenschalter `preis_ins.e -Loekb` und bewusst *kein* Stammsatz.
  `db_oekbtest1` läuft weiter durch die normalen datengetriebenen Prüfungen — exakt wie im
  Altsystem. Damit bleiben Parallelbetrieb und Bestandstests unverändert grün.
- Die Ausschüttungs-Datumsprüfungen (`ERR_AUSSCHDAT01/02/03`, `ERR_GJAHR03`) und der Kleinkram
  (`testfile_oekb`-Skip, totes `supplier`-Select) sind **nicht** in Scope.

---

## Teil 1 — `"oekb"` in eine dokumentierte Konstante ziehen

### Wohin

`ifas-database/ifas-persistence-stamm/.../persistence/stamm/Lieferant.java`

Das ist das einzige Modul, das beide Konsumenten erreichen: `ifas-data-import-export` hängt direkt
an `ifas-persistence-stamm`, `ifas-domain-stm` transitiv über `ifas-persistence-inv`
(`Inv.vertreter` ist ein `Hdp` aus `persistence-stamm`). `ifas-domain-core` scheidet aus —
`ifas-data-import-export` hängt nicht daran.

```java
/**
 * Die Liefer-ID, unter der die Meldestelle selbst liefert — Pendant zum Legacy-Schalter
 * {@code preis_ins.e -Loekb} ({@code cProgParameter::szFondsLieferant}).
 *
 * <p>Bewusst <b>kein</b> Satz in {@code kurs.dbo.lieferanten}: der echte OeKB-Stammlieferant
 * heisst {@code db_oekbtest1} und durchlaeuft die normalen datengetriebenen Pruefungen
 * (HDP_lieferanten, isin_sonderauswertung) — genau wie im Altsystem. Der Vergleich ist
 * case-sensitiv, ebenfalls wie im Altsystem ({@code strcmp} gegen kleingeschriebenes "oekb").
 */
public static final String OEKB_LIEFER_ID = "oekb";
```

### Umstellen

| Datei | Zeile | Änderung |
|---|---|---|
| `ifas-domain-stm/.../validation/SteuerMeldungDomainValidationService.java` | 115 | `if (OEKB_LIEFER_ID.equals(lieferId) \|\| inv == null)`; Kommentar `// skip Lieferant validation for test lieferanten` durch einen Verweis auf die Konstante ersetzen |
| `ifas-data-import-export/.../FondsExporter.java` | 410 | `if (!OEKB_LIEFER_ID.equals(stmEntity.getLieferant().getLieferId()))` — nebenbei die Vergleichsrichtung angleichen |

`ifas-domain/ifas-domain-stm/pom.xml`: `ifas-persistence-stamm` **explizit** als Dependency
aufnehmen (wird für Teil 2 ohnehin gebraucht) statt sich auf die transitive Auflösung zu verlassen.

Kein Verhaltenswechsel — reines Benennen. Case-Sensitivität bleibt bewusst erhalten.

---

## Teil 2 — ISIN-Listen-Berechtigung portieren

### Legacy-Vorbild

`m_st_meldung.cpp:1404` `IsBerechtigt4IsinListe()`:

```sql
select isnull(isin_sonderauswertung, 'N') from kurs.dbo.lieferanten where liefer_id = '%s'
```
Berechtigt genau dann, wenn der Wert `'J'` ist. Fehlender Satz → nicht berechtigt.

Aufrufer `m_st_meldung.cpp:1044` in `RunIsinListeOutputFiles()`:

```cpp
if (!(strPLiefer_id.IsNull()))          // ohne Liefer-ID gar keine Pruefung
{
    if (strPLiefer_id != "oekb")        // oekb ist immer berechtigt
    {
        nRet = IsBerechtigt4IsinListe(dbc_p, strPLiefer_id);
        if (nRet == 0) { ...3 Zeilen nach cError.fOut...; return 2; }
    }
}
```

Wichtig für die Fidelity: Der Check läuft **nach** dem Header-Block (Separator, ISIN-Inputdatei,
Ausgabedatei, erweiterte Ausgabedatei, Zeitpunkt, Separator — Zeilen 997–1032), der zu diesem
Zeitpunkt bereits in *beide* Logs geschrieben ist. Beim Abbruch gehen die drei Meldungszeilen
**nur** nach `cError.fOut`; die info.log bleibt beim blossen Header (kein Summary-Footer, kein
Error-File-Hinweis), und die beiden CSVs werden nie angelegt.

Exakter Wortlaut (Umlaut in Zeile 1 beibehalten, `IFAS_LOG_CHARSET` = windows-1252 deckt ihn ab):

```
# Der Lieferant %s ist nicht für den Bezug der individuellen
# Steuerdatenmeldung basierend auf einer ISIN-Liste berechtigt.
# Sonderauswertung kann nicht erstellt werden.
```

### Umsetzung

**a) `lieferId` bis in den Domain-Service durchreichen**

Heute endet die Liefer-ID am Job: `IsinAnforderungslisteJob.n` wird gesetzt, aber
`IsinAnforderungDomainService.processIsinList(NamedResource, LocalDate[, observer])` kennt sie
nicht.

- `IsinAnforderungDomainService`: beiden `processIsinList`-Überladungen einen
  `@Nullable String lieferId` geben. `null` = keine Prüfung, exakt wie das Legacy-Guard
  `if (!(strPLiefer_id.IsNull()))`.
- `IsinAnforderungslisteJobExecutionService:75` → `job.getn()` mitgeben.
- `IsinAnforderungDiffService:94` → `null` mitgeben. `IsinAnforderungslisteDiffJob` führt keine
  Liefer-ID (nur `notes`), und der Diff vergleicht gegen einen Legacy-Lauf, der bereits
  Output produziert hat — also darf hier nie abgebrochen werden. Damit bleiben
  `IsinAnforderungDiffTest` und `QuickIsinAnforderungDiffTest` unverändert grün.

**b) Prüfung im Domain-Service**

`LieferantRepository.getLieferantByLieferId(String)` existiert bereits — wiederverwenden, nichts
Neues bauen. `Lieferant.isinSonderauswertung` ist bereits gemappt
(`@Convert(TJaNeinToBooleanConverter)` auf `isin_sonderauswertung`), deckt das legacy `'J'`/`'N'`
also schon ab.

```java
private boolean isBerechtigt4IsinListe(String lieferId) {
    return lieferantRepository.getLieferantByLieferId(lieferId)
            .map(Lieferant::getIsinSonderauswertung)
            .filter(Boolean.TRUE::equals)
            .isPresent();
}
```

Aufruf in `processIsinList`, nachdem die vier Temp-Resources angelegt sind und bevor
`doProcessIsinList` läuft:

```java
if (lieferId != null
        && !Lieferant.OEKB_LIEFER_ID.equals(lieferId)
        && !isBerechtigt4IsinListe(lieferId)) {
    return nichtBerechtigtResult(lieferId, inputFilename, estbStandard, estbErweitert, errorLog, infoLog);
}
```

**c) Log-Ausgabe**

Die drei `#`-Zeilen passen nicht in `IsinAnforderungValidationMsg` — das Record ist
zeilen-/ISIN-bezogen (`lineNumber`, `isin`, `datumAb`, …) und der Writer rendert es im
`- Zeile-Nr: N | …` / `ERROR | isin | …`-Format. Der Abbruch ist dagegen lauf-global. Deshalb
**keinen** neuen `IsinAnforderungValidationMsgCode` anlegen, sondern:

- `IsinAnforderungLogWriter`: neue Methode `writeNichtBerechtigt(String lieferId)`, die die drei
  Zeilen über `wh.writeLine(...)` ausgibt.
- `IsinAnforderungLogs`: zwei Abbruch-Varianten ergänzen — `writeNichtBerechtigtErrorLog(...)`
  (Header + drei Zeilen) und `writeAbortedInfoLog(...)` (nur Header, ohne Summary und ohne
  Error-File-Hinweis, weil das Legacy vorher zurückkehrt). Beide nutzen den bestehenden
  `writer.writeHeader(...)` samt `IsinAnforderungFilenames`.

**d) Abbruch nach aussen tragen**

`IsinAnforderungResult` um ein Feld erweitern, z.B. `@Nullable String nichtBerechtigtLieferId`
(null = regulärer Lauf). Die beiden CSV-Resources bleiben leer — das entspricht „Sonderauswertung
kann nicht erstellt werden".

In `IsinAnforderungslisteJobExecutionService`: Ergebnis-ZIP weiterhin schreiben und im Job
ablegen (die Logs sind hier das Lieferergebnis), danach den Job auf FAILED laufen lassen. Der
bestehende `catch`-Block wickelt Exceptions schon nach `DefaultJobStatus.FAILED` ab
(`AbstractJobWorkQueueHandler:42`), und `IsinAnforderungslisteJob` hat ein `statusMessage`-Feld
für den Grund. **Bei der Umsetzung prüfen**, dass das Werfen nach `storeResultInJob(...)` den
Store nicht mit zurückrollt — sonst Reihenfolge bzw. Transaktionsgrenze anpassen.

### Betroffene Dateien

```
ifas-database/ifas-persistence-stamm/.../stamm/Lieferant.java              (Konstante)
ifas-domain/ifas-domain-stm/pom.xml                                        (dep explizit)
ifas-domain/ifas-domain-stm/.../validation/SteuerMeldungDomainValidationService.java
ifas-database/ifas-data-import-export/.../importexport/FondsExporter.java
ifas-domain/ifas-domain-stm/.../isinanforderung/IsinAnforderungDomainService.java
ifas-domain/ifas-domain-stm/.../isinanforderung/IsinAnforderungLogWriter.java
ifas-domain/ifas-domain-stm/.../isinanforderung/IsinAnforderungLogs.java
ifas-domain/ifas-domain-stm/.../isinanforderung/IsinAnforderungResult.java
ifas-services/.../service/isinanforderung/IsinAnforderungslisteJobExecutionService.java
ifas-services/.../service/isinanforderungdiff/IsinAnforderungDiffService.java
```

---

## Tests

Bestandstests, die grün bleiben müssen (Regressionsnetz für die Entscheidung „Literal bleibt"):

- `SteuerMeldungDomainValidationServiceTest:830`
  `givenOekbLieferId_whenValidate_thenLieferantValidationSkipped` — unverändert.
- `IsinAnforderungDiffTest`, `QuickIsinAnforderungDiffTest` — durch `lieferId = null` unberührt.

Neu, in `ifas-testing/ifas-integration-tests/.../isinanforderung/`, given-when-then + AssertJ nach
`testing-conventions.md`:

1. **nicht berechtigt** → Lauf bricht ab, error.log enthält Header + die drei `#`-Zeilen mit der
   Liefer-ID, info.log enthält nur den Header, beide CSVs leer, Job FAILED.
2. **berechtigt** → `db_oekbtest1` (steht in `standard_LIEFERANT.yaml:4810` mit
   `isinSonderauswertung: true`) läuft regulär durch. Das ist zugleich der Beleg dafür, dass der
   echte OeKB-Lieferant den Bypass gar nicht braucht.
3. **`oekb`** → Bypass, Prüfung wird übersprungen, auch ohne Stammsatz.
4. **`lieferId == null`** → keine Prüfung (Diff-Pfad).

Der Wortlaut der drei Zeilen ist gegen **literale Strings** zu assertieren, nicht gegen einen
`formatMessage(<dieselben Args>)`-Aufruf — siehe [[project_lieferung-tests-tautological]].

---

## Verifikation

```bash
mvn clean install -Pno-proxy -Pdev-build
mvn test -Pno-proxy -Dtest=SteuerMeldungDomainValidationServiceTest
mvn test -Pno-proxy -Dtest=QuickIsinAnforderungDiffTest
```

End-to-end über die UI (`LocalH2OnlyIfasApplication`, http://localhost:8080/ifas-uat):
`/ui/isin-anforderungsliste` mit einer `.isin`-Datei hochladen — einmal mit dem vorbelegten
`oekb` (läuft durch), einmal mit einem Lieferanten ohne `isin_sonderauswertung` (Job FAILED,
error.log im Ergebnis-ZIP enthält die drei Zeilen), einmal mit `db_oekbtest1` (läuft durch).

Für den Parallelbetrieb zusätzlich einen ISIN-Anforderungs-Diff-Job über `/ui/isin-anforderung-diff`
starten und bestätigen, dass die error.log/info.log-Deltas gegenüber vorher unverändert sind.
