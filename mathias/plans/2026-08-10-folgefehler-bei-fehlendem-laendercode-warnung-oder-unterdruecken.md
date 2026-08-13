# Folgefehler auf D/Z/ZA/AS-Zeilen mit fehlendem Ländercode — zwei Wege

**Status: Planung. Nicht implementieren.** Beide Optionen sind ausformuliert, die Entscheidung steht aus.

## Context

Nach dem `Code fuer Land`-Label-Fix bleiben im `QuickRecalculationTest`-Lauf
(`202409_AT0000A10QR4_JM_1302971_return_1885191`) 466 Fehler-Abweichungen. Davon gehen **157 auf eine
einzige Ursache** zurück:

Legacy bricht die Prüfung einer D/Z/ZA/AS-Zeile beim fehlenden Ländercode ab
(`c_st_meldung.cpp:2482-2491`, `return -1`) und erreicht `IsDBAKennungOK` / `SetLandNumberValue` nie.
Das Neusystem prüft weiter und meldet auf derselben Zeile zusätzlich:

| Code | Anzahl | Emittiert in |
|------|--------|--------------|
| `ERR_RECHENFELD` | 150 | `SteuerMeldungErmittlungsvorgabeValidators.java:495-501` |
| `ERR_KENNUNG_DBA` | 7 | `SteuerMeldungErmittlungsvorgabeValidators.java:457-463` |

Das ist kein Rechenfehler und kein Recalc-Artefakt — das Neusystem ist hier schlicht gründlicher als
Legacy. Zu klären ist nur, ob das im Delta-Report als **Fehler**, als **Warnung** oder gar nicht
erscheinen soll.

### Aktueller Report-Stand

```
Exakte Treffer      : 903
Abgedeckte Treffer  : 0
Nur im Altsystem    : 142     (STB — separates Thema)
Nur im Neusystem (Fehler)  : 324     davon 157 = dieses Thema, 167 = STB
Nur im Neusystem (Warnung) : 0
```

### Was ausscheidet

`CoveredByRule` (`delta/CoveredByRule.java:12-17`) ist **nicht anwendbar**: die Signatur ist
`isCoveredBy(LegacyLogValidationMsg, ValidationMsg)` — jede Regel braucht eine Legacy-Meldung. Für
unsere 157 hat Legacy auf der Zeile gar nichts emittiert (die `ERR_PFLICHT_FEHL` ist bereits exakt
gematcht und damit verbraucht). Alle sechs bestehenden Regeln laufen legacy→neu.

Ein `ValidationSetting`-Flag scheidet ebenfalls aus: alle vier bestehenden Flags sind laut Javadoc
(`ValidationSetting.java:33-42`) für *Recalc-Artefakte* — Fehler, die nur entstehen, weil gegen bereits
persistierte Daten gerechnet wird. Das trifft hier nicht zu.

---

## Option A — im Delta-Report als WARNUNG führen

Die Validierung bleibt unangetastet; nur die Einstufung der Abweichung ändert sich.

### A1. Prädikat

Neue Utility-Klasse neben den emittierenden Validatoren —
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/validation/MissingLaendercodeFollowUps.java`
— analog zu `at/oekb/ifas/domain/stm/validation/status/StatusNmRecalcArtifacts.java:25-43`, dem
bestehenden Muster für „nur in einer bestimmten Konstellation herabstufen".

Prädikat `isMissingLaendercodeFollowUp(ValidationMsg msg)`, alle Bedingungen müssen gelten:

1. `msg.getValidationMsgCode()` ∈ `{ERR_RECHENFELD, ERR_KENNUNG_DBA}`.
   `ERR_RECHENFELD_L` bewusst **nicht** — die `_L`-Form setzt einen vorhandenen Ländercode voraus.
2. `msg.getPosition() instanceof CsvMessagePosition pos` und
   `RecordType.isCountryCodeRecord(pos.recordType())` (`meldung/csv/RecordType.java:18`).
3. **Zeile prüfen:** die Ländercode-Spalte in `pos.csvRecord()` ist abwesend oder leer.

Zu (3): `CsvMessagePosition` (`support-libs/csv-schema/.../CsvMessagePosition.java:14-20`) führt den
`@Nullable CSVRecord csvRecord` mit. Ist er `null`, liefert das Prädikat `false` — im Zweifel bleibt es
ein Fehler.

**Nicht die `3` hartkodieren.** `CsvIfasMessageProcessor.extractOptionalCountryCode` (Z. 603-609) tut
das heute, das ist die einzige Stelle. Statt einen zweiten Hardcode anzulegen: diese Auflösung in einen
gemeinsamen Helper ziehen (Spaltenindex des `LAENDERCODE`-MapCodes aus dem Record-Schema, Konstante
`LAENDERCODE_MAP_CODE` liegt in `CsvIfasMessageProcessor.java:825`) und von beiden Stellen nutzen.

Zur Trennschärfe — in beiden vorhandenen Legacy-Logs verifiziert:

| Fixture | Legacy `ERR_RECHENFELD` auf D/Z/ZA/AS **ohne** Land | **mit** Land |
|---|---|---|
| `gf1-d20260724/error.log` | 0 | 4 |
| quick-recalc `error.log` | 0 | 25 |

Legacy liefert auf Länder-Sätzen ausnahmslos die `_L`-Form. Für `ERR_KENNUNG_DBA` gibt es keine
`_L`-Variante und Legacy emittiert den Code durchaus auf Länder-Sätzen (gf1: 1×D, 2×Z; quick-recalc:
1×Z) — deshalb ist die Zeilenprüfung aus (3) dort nicht optional, sondern das einzige verlässliche
Signal.

### A2. Verdrahtung

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaReports.java`,
Methode `isShowAsWarningIfOnlyInNew` (Z. 192-204) um eine Bedingung erweitern — **unkonditioniert**,
ohne `ValidationSetting`-Flag:

```java
if (MissingLaendercodeFollowUps.isMissingLaendercodeFollowUp(msg)) {
    return true;
}
```

Präzedenzfall für „unkonditioniert": die `_LIEFERUNG`-Codes in
`MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` (Z. 47-55) stehen mit genau derselben Begründung
dort — laut Javadoc (Z. 38-45) landen sie nur dann in diesem Bucket, wenn *„legacy declined the first
row of the ISIN upstream and therefore never updated its in-memory state. That is
new-system-stricter-by-design, not a regression."* Wortgleich unsere Situation.

Kein weiterer Eingriff nötig: `isShowAsWarningIfOnlyInNew` wird von genau drei Stellen aufgerufen —
dem Summary-Zähler (`ValidationDeltaCalculator.java:493-501`), `getValidationDeltas`
(`ValidationDeltaReports.java:162-165`) und dem Abschnitts-Label
(`ValidationDeltaReportWriter.java:288-296`).

### A3. Tests

Neu: `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaReportsMissingLaendercodeTest.java`,
nach dem Vorbild von `ValidationDeltaReportsStatusNmTest.java` (dort ist auch die `SimplePosition`-Hilfe
für Nicht-CSV-Positionen zu finden). Fälle:

- `ERR_RECHENFELD` auf D-Zeile mit leerer Ländercode-Spalte → `true`
- `ERR_KENNUNG_DBA` auf Z-Zeile mit leerer Ländercode-Spalte → `true`
- `ERR_KENNUNG_DBA` auf D-Zeile **mit** Ländercode → `false` (der gf1-Fall)
- `ERR_RECHENFELD` auf E-Satz → `false`
- `ERR_RECHENFELD_L` → `false`
- Position ohne `csvRecord` → `false`

### A4. Ergebnis

| | vorher | nachher |
|---|---|---|
| Nur im Neusystem (Fehler) | 324 | **167** |
| Nur im Neusystem (Warnung) | 0 | **157** |
| Gesamt-Abweichungen | 466 | 466 |

Die Einträge bleiben sichtbar, zählen aber nicht mehr in `countErrorDiffs()`
(`recalc/BundleRecalculationResult.java:71-93`).

---

## Option B — an der Quelle unterdrücken

Echte Legacy-Parität: die Folgefehler entstehen gar nicht erst. Zwei Umsetzungen, deutlich
unterschiedlich im Risiko.

### B1 (empfohlen innerhalb B) — Präzedenzregel in `ValidationMsgStore`

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgStore.java`,
Methode `applyLegacyCheckPrecedence()` (Z. 146-172).

Diese Stufe existiert bereits **genau für dieses Problem** — ihr Javadoc (Z. 126-145) beschreibt
wörtlich Legacys „fixed order and `return -1`s on the first failure" und bildet heute schon zwei solche
Regeln ab. `ERR_KENNUNG_DBA` / `ERR_RECHENFELD(_L)` sind dort bereits *Quelle* einer Unterdrückung; wir
ergänzen eine Regel eine Stufe darüber.

Änderung:

- Neue Präzedenz-Quelle: `ERR_PFLICHT_FEHL`, deren Position eine `CsvMessagePosition` mit
  Länder-Satzart und `colIdx()` = Ländercode-Spalte ist → `issueLineNumber()` in ein
  `Set<Integer> linesWithMissingLaendercode` sammeln.
- In `isSuppressedByPrecedence` (Z. 174-186) unterdrücken, wenn die Position auf derselben Zeile liegt:
  `ERR_KENNUNG_DBA`, `ERR_RECHENFELD`, `ERR_RECHENFELD_L`, `INFO_FELD_MELDEST`.

Zwei Fallstricke:

1. Die bestehenden Regeln keyen auf **Argumente** (`addArgument` / `matchesArgument`, Z. 189-199).
   Unsere Regel muss auf die **Zeilennummer** keyen, weil `arg[0]` der generische Text
   `"Code fuer Land"` ist und nicht der Feldname. Also ein zweites, positionsbasiertes Helper-Paar.
2. Die Ermittlungsvorgabe-Schicht emittiert `ERR_PFLICHT_FEHL` ebenfalls
   (`SteuerMeldungErmittlungsvorgabeValidators.java:293-302`), mit Fallback-Position auf der ersten
   Zeile der Meldung. Die Einschränkung auf Länder-Satzart **und** Ländercode-Spaltenindex ist deshalb
   Pflicht, sonst unterdrückt eine solche Meldung wahllos.

Aufrufkette: einziger Produktiv-Aufrufer ist `SteuerMeldungLieferungService.java:113`
(`applyLegacyCheckPrecedence().deduplicate()`). Die Regel wirkt also für **jede** Lieferung, nicht nur
im Recalc — das ist beabsichtigt, es geht um Parität.

Was sich **nicht** ändert: das geparste Modell, das Return-File, die Persistenz. Nur die Menge der
gemeldeten Validierungen. Die Meldung behält ihren `ERR_PFLICHT_FEHL` und damit ihren Fehlerstatus.

Tests: `ValidationMsgStoreTest.java` ab Z. 333 (Abschnitt `=== applyLegacyCheckPrecedence ===`)
erweitern — unterdrückt / nicht unterdrückt bei anderer Zeile / nicht unterdrückt bei
Ermittlungsvorgabe-`ERR_PFLICHT_FEHL` mit Fallback-Position. Dazu ein End-to-end-Fall in
`CsvToValidationMsgCodeTest.java` (dort steht bei Z. 731 bereits ein Kommentar zu dieser Stufe).

### B2 (Alternative) — Zeile gar nicht ins Modell aufnehmen

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasMessageProcessor.java`,
`addMultiRowRecordValues` Z. 439-447.

Heute wird nur auf einen **komplett leeren** Key-Path abgebrochen. `toRecordKeyPath` (Z. 619-643)
filtert leere Key-Spalten heraus, statt sie zu füllen — eine D-Zeile ohne Land liefert also einen
Pfad der Länge 1 und läuft weiter durch. Die Zeile landet dadurch in `CsvMessage.data` in der Form
eines E-Satz-Feldes (`Feldname -> {BETRAG, CODE_NUM, BETRAG_JE_ANTEIL}`), also einen Verschachtelungs-
grad zu flach für einen Ländervektor.

Änderung: `validateKeyColumnValues` **vor** den Guard ziehen (sie erzeugt die `Code fuer Land`-Meldung)
und dann auf einen *unvollständigen* Pfad abbrechen:
`recordKeyPath.size() < recordSchema.getKey().size()`. Entspricht Legacys `return -1` zeilengenau. Nur
D/Z/ZA/AS betroffen — E und STB haben nur eine Key-Spalte.

Zwei Nebenbefunde, die B2 gratis miterledigt (und die unabhängig von dieser Entscheidung ein eigenes
Ticket verdienen):

- **Leere CODE-Spalte:** `D;;0.0;AT` kehrt heute vor `validateKeyColumnValues` zurück und erzeugt gar
  keinen `MISSING_FIELD` — der Ländercode wird stattdessen zum Top-Level-Datenschlüssel.
- **Latenter `ClassCastException`:** ist das fehlgeschlüsselte Feld ein echter Ländervektor, wirft
  `CsvSteuerMeldung.extractCountryVectorMapValues` (Z. 180-181) beim Cast. In den aktuellen Fixtures
  trifft der Fall nur Nicht-Vektor-`Summe*`-Felder, deshalb ist er bisher nicht aufgeschlagen.

Blast Radius von B2 — jeweils Parität mit Legacy, aber sichtbare Ausgabeänderungen:

- **Return-File:** `CsvSteuerMeldungenWriter.writeSingleAmountRow` (Z. 266-280) liest über
  `getFieldValue`; der heute ausgegebene Wert wird `null`, die Zeile entfällt.
- **Persistenz:** der Wert wird nicht mehr geschrieben (`SteuerMeldungPersistenceService:114-116`).
- **Dublettenprüfung:** ein mögliches `ERR_DOPP_FELD(_L)` entfällt — Legacy bricht ebenfalls davor ab.

### B-Ergebnis (beide Varianten)

| | vorher | nachher |
|---|---|---|
| Nur im Neusystem (Fehler) | 324 | **167** |
| Gesamt-Abweichungen | 466 | **309** |

---

## Empfehlung

**A umsetzen, B als eigenes Ticket.** A ändert ausschließlich die Einstufung im Delta-Report, hat
keinerlei Rückwirkung auf Validierung, Return-File oder Persistenz, und trifft mit dem Zeilen-Prädikat
exakt die 157 Fälle. B ist die fachlich sauberere Parität, ändert aber echtes Verhalten und gehört mit
eigener Regressionsrunde gefahren — innerhalb B ist **B1** vorzuziehen (gleiches Ergebnis im Report,
kein Eingriff ins geparste Modell), **B2** nur, wenn zusätzlich die beiden Nebenbefunde adressiert
werden sollen.

A und B sind Alternativen, keine Ergänzungen: nach B feuert das Prädikat aus A nie mehr, weil die
Meldungen gar nicht erst entstehen. Wird B später umgesetzt, ist A ersatzlos zurückzubauen.

## Verifikation

Für beide Optionen identisch:

1. `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm` — Modul-Suite (aktuell 1253 Tests).
2. `mvn install -DskipTests -Pno-proxy -pl ifas-domain/ifas-domain-stm`, **danach**
   `mvn test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`.
   Ohne den vorherigen `install` läuft der Integrationstest gegen das alte Artefakt aus dem lokalen
   Repository und beweist nichts. **Offen:** dieses Gate ist seit dem `Code fuer Land`-Fix noch nicht
   gegen das neu gebaute Artefakt gelaufen. Vor jeder weiteren Änderung nachholen — bei Option A
   erwarten wir dort verschobene `onlyInNewError` → `onlyInNewWarning`-Zahlen in den
   `SummaryExpectation`-Baselines (`GrossfileRecalculationTest.java:199-230`), bei Option B sinkende
   `onlyInNewError`-Zahlen.
3. `QuickRecalculationTest#givenSingleLieferungData_...` (`@Disabled` temporär entfernen, danach
   wieder setzen) und die Zusammenfassung in
   `ifas-testing/ifas-integration-tests/target/quick-recalc/error#diff-deviations.txt` gegen die
   Tabellen oben prüfen.
