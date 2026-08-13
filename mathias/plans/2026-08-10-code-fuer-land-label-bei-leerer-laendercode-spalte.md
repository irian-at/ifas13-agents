# Altsystem-Parität: `Code fuer Land` bei leerer LAENDERCODE-Spalte

## Context

Der `QuickRecalculationTest`-Lauf (Bundle `202409_AT0000A10QR4_JM_1302971_return_1885191`) erzeugt
780 Fehler-Abweichungen in `target/quick-recalc/error#diff-deviations.txt`. Die Analyse zeigt,
dass **alle 780** auf genau zwei Ursachen zurückgehen — es gibt keinen langen Schwanz an Einzelfällen.

Die vom Anwender adressierte Ursache: bei D/Z/ZA/AS-Zeilen mit leerer Ländercode-Spalte meldet das
Altsystem `Das Pflichtfeld <Code fuer Land> ...`, das Neusystem dagegen den Feldnamen der Zeile
(`<SummeDividenden_Direktanlage>`). Betroffen sind 157 Zeilen (D 61, ZA 36, Z 35, AS 25).

### Warum das Neusystem den falschen Namen meldet

Es gibt **zwei** Emitter für `CsvErrorCode.MISSING_FIELD`, beide in
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasMessageProcessor.java`:

| Pfad | Auslöser | Label |
|------|----------|-------|
| A — `validateRecordHasRequiredColumns` (Z. 220) → `handleMissingRequiredField` (Z. 770) | Spalte **fehlt ganz** (`colIdx >= record.size()`) | `resolveFieldNameForMissingField` (Z. 834) → **korrekt** `"Code fuer Land"` |
| B — `validateKeyColumnValues` (Z. 531) → `validateValue` (Z. 556) | Spalte **vorhanden, aber leer** | `resolveFieldName` (Z. 585) → **falsch**: liefert für `MULTI_ROW_MAP` immer den Wert der CODE-Spalte |

`resolveFieldNameForMissingField` implementiert die Altsystem-Konvention bereits vollständig
(`"Code fuer Land"` für LAENDERCODE bei D/Z/ZA/AS, `"Wert des Feldes"` für BETRAG bei E) — sie wird von
Pfad B nur nicht aufgerufen.

Die Zeile `D;SummeDividenden_Direktanlage;0.0;;2072;0.0` hat 6 Spalten, `colIdx 3` existiert also als
Leerstring → Pfad A greift nicht, Pfad B liefert das falsche Label.

Legacy-Referenz: `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp:2482-2491`
(`strALand.IsNull()` → `ERR_PFLICHT_FEHL` mit Literal `"Code fuer Land"`, Z. 2485). D/Z/ZA/AS teilen
dort einen Codepfad (Z. 2363-2366); Prüfreihenfolge ist Feldname → Wert → Land.

**Latenter Zwillingsfehler:** Eine E-Zeile mit vorhandener, aber leerer BETRAG-Spalte läuft ebenfalls
über Pfad B und meldet den E-Code statt `"Wert des Feldes"` (Legacy: `c_st_meldung.cpp:2471-2480`).
Derselbe Fix behebt beides.

## Änderung

### 1. `CsvIfasMessageProcessor.validateValue` (Z. 556-581)

Das Label so bestimmen, wie es der nachgelagerte Validator interpretiert: Wenn
`CsvIfasValueTypeValidator.validate` (Z. 73) den `MISSING_FIELD`-Zweig nimmt — also `required &&
isEmpty(value)` —, den generischen Altsystem-Namen verwenden, sonst wie bisher den CODE-Wert.

```java
private CsvValidationMsg validateValue(...) {
    Optional<String> optionalCountryCode = extractOptionalCountryCode(record, recordSchema);
    String value = trimNullSafe(record.get(columnSchema.getColIdx()));

    // Leere Pflichtspalte wird zu MISSING_FIELD (CsvIfasValueTypeValidator) -> Altsystem-Label
    String fieldName = columnSchema.isRequired() && isEmpty(value)
            ? resolveFieldNameForMissingField(record, recordSchema, columnSchema)
            : resolveFieldName(record, recordSchema, columnSchema);

    return validator.validate(csvMessage, columnSchema.getValueType(), value, lineNumber, record,
            columnSchema.isRequired(), fieldName, columnSchema.getColIdx(),
            recordSchema.getCode(), optionalCountryCode.orElse(null));
}
```

Vorhandenes wiederverwenden, nichts Neues: `resolveFieldNameForMissingField` (Z. 834),
`trimNullSafe`, `isEmpty` (bereits statisch importiert, s. Z. 819). Der Ausdruck spiegelt exakt die
Bedingung in `CsvIfasValueTypeValidator:73` — alle anderen Meldungen (`VALUE_TYPE_VALIDATION` etc.)
bleiben unverändert.

Die Änderung wirkt über `validateKeyColumnValues` (Z. 531) **und** die beiden Value-Spalten-Aufrufe
(Z. 374 für `SINGLE_ROW_MAP`, Z. 459 für `MULTI_ROW_MAP`). Für `SINGLE_ROW_MAP` (START/EA/STATUS)
fällt `resolveFieldNameForMissingField` auf `resolveFieldName` → `columnSchema.getFieldName()` zurück,
dort ändert sich also nichts.

Kein Eingriff in `CsvIfasValueTypeValidator` und keine Signaturänderung an
`CsvValueTypeValidator` (`support-libs/csv-schema`) — der Label-Parameter ist bereits ein reiner Input.

### 2. Tests

Bisher gibt es **keinen** Test, der `"Code fuer Land"` oder `"Wert des Feldes"` prüft — die Literale
kommen nur in `CsvIfasMessageProcessor.java` vor. Neu in
`ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasValidationTest.java`
(bestehende Konventionen: given-when-then, AssertJ, `CsvValidationMsgAssertions.assertThat`):

- `givenCountryRecordWithEmptyLaendercode_whenValidate_thenMissingFieldNamesCodeFuerLand` —
  je eine Zeile für D, Z, ZA, AS mit leerer Spalte 3 (Wert vorhanden) → `MISSING_FIELD` mit
  Argument `"Code fuer Land"`.
- `givenCountryRecordWithoutLaendercodeColumn_whenValidate_thenMissingFieldNamesCodeFuerLand` —
  Zeile endet vor Spalte 3 (Pfad A) → gleiches Label; sichert, dass beide Pfade übereinstimmen.
- `givenERecordWithEmptyBetrag_whenValidate_thenMissingFieldNamesWertDesFeldes` — Zwillingsfall.

Zusätzlich `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/CsvToValidationMsgCodeTest.java`
um einen Fall erweitern, der die fertige Meldung `Das Pflichtfeld <Code fuer Land> im Satz <D> ist
nicht befuellt.` gegen den **Literalstring** prüft (nicht gegen `formatMessage(<dieselben Args>)` —
das wäre tautologisch, siehe frühere Erfahrung mit den `_LIEFERUNG`-Tests).

## Verifikation

1. `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=CsvIfasValidationTest+CsvIfasValueTypeValidatorTest+CsvToValidationMsgCodeTest`
2. `QuickRecalculationTest#givenSingleLieferungData_...` (`@Disabled` entfernen bzw. aus der IDE
   starten) mit demselben Bundle laufen lassen.
3. In `ifas-testing/ifas-integration-tests/target/quick-recalc/error#diff-deviations.txt` gegenprüfen:

   ```bash
   grep -c "Pflichtfeld <Code fuer Land>" error#diff-deviations.txt   # erwartet: 0
   grep -o "Das Pflichtfeld <[^>]*> im Satz <[^>]*>" error#diff-deviations.txt | sort | uniq -c
   ```

   Erwartung: die 157 `[-] Code fuer Land` / `[+] <Feldname>`-Paare verschwinden; die Gesamtzahl der
   `ERROR!`-Zeilen im Deviations-Report sinkt von 780 auf 466.
4. `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am` zur Absicherung, dass keine
   anderen Meldungstexte betroffen sind (STM-Regressionstests).

## Nicht Teil dieser Änderung (bewusst zurückgestellt)

Die verbleibenden 466 Abweichungen aus demselben Lauf gehen auf zwei weitere Ursachen zurück —
beide sind eigenständige Themen und hier nur dokumentiert, damit der Report lesbar bleibt:

**A) 157×2 Folgefehler auf denselben D/Z/ZA/AS-Zeilen (307 Einträge).** Legacy bricht die
Zeilenprüfung nach dem fehlenden Land ab (`return -1`, `c_st_meldung.cpp:2491`) und erreicht
`IsDBAKennungOK`/`SetLandNumberValue` nie. Das Neusystem prüft weiter und meldet zusätzlich
`ERR_RECHENFELD` (150×) bzw. `ERR_KENNUNG_DBA` (7×) aus `SteuerMeldungErmittlungsvorgabeValidators`.
Nachbilden hieße: eine Zeile mit leerer Pflicht-Key-Spalte gar nicht erst ins Modell aufnehmen —
echte Verhaltensänderung, nicht nur Meldungstext.

**B) 309 Abweichungen auf STB-Zeilen.** Legacy kennt die Satzart `STB` im Eingabeformat nicht
(`ERR_SATZART`, Fallthrough `c_st_meldung.cpp:2555`); das Neusystem hat sie im Lieferformat-Schema
(`STM_LIEFERFORMAT_2022-04-03.csv-schema.yml:284-323`) und meldet stattdessen `ERR_ANZ_PARAM` (142×)
plus `ERR_PFLICHT_FEHL` (25×).

*Vorgabe für die spätere Umsetzung (vom Anwender):* **STB darf nur im Auslieferformat vorkommen.**
Das Lieferformat ist ausschließlich für Input-Steuermeldungs-CSVs; beim Einlesen alter Return-Files
muss immer das Auslieferformat verwendet werden. Die Trennung existiert bereits —
`CsvSteuerMeldungen.loadReturnFromCsv` (Z. 67-82) verwendet `CsvSchemaType.STM_AUSLIEFERFORMAT`,
der Input-Pfad `internalLoadAndValidateInputSteuerMeldungenFromCsv` (Z. 91) das
`STM_LIEFERFORMAT`. Offen bleibt also: den `STB`-Block aus dem Lieferformat-Schema entfernen und
alle Aufrufer prüfen, ob Return-Files tatsächlich durchgängig über `loadReturnFromCsv` laufen.
(Im vorliegenden Fixture wird ein Legacy-*Return*-File absichtlich als *Input* eingespielt — genau
wie beim Legacy-Lauf, der die Vergleichs-`error.log` erzeugt hat. Der Deviation ist damit ein echter
Paritätsbefund, kein Fixture-Artefakt.)

Der INFO-Report (`info#diff-deviations.txt`) ist sauber (nur Lieferant/Datum, erwartet).
