# Plan: Lieferanten-Autocomplete für die Lieferant-Eingabefelder

## Context

Der Lieferant wird im Web-UI heute an fünf Stellen als **freier Text** eingegeben — vorbelegt mit
`oekb`, ohne jede Hilfe. Wer die Liefer-ID eines konkreten Lieferanten nicht auswendig weiß, muss
sie außerhalb der Anwendung nachsehen; ein Tippfehler fällt erst beim Verarbeiten auf.

Eine sechste Stelle, der Lieferant-Filter der Steuermeldungen-Liste, ist bereits ein DB-gefülltes
`<select>` — aber ein natives `<select>` **filtert nicht mit**, es springt beim Tippen nur auf den
Präfix. Bei ~316 Lieferanten ist das Scrollen durch eine flache Liste.

Ziel: an allen sechs Stellen dieselbe mitfilternde Vorschlagsliste — beim Tippen wird auf
Teilstrings von Liefer-ID *und* Bezeichnung eingeschränkt. Die Felder bleiben freier Text, weil
`oekb` bewusst **kein** Satz in `kurs..lieferanten` ist (Pendant zum Legacy-Schalter
`preis_ins.e -Loekb`; der echte OeKB-Stammsatz heißt `db_oekbtest1`) und ein noch nicht erfasster
Lieferant tippbar bleiben muss.

**Getroffene Entscheidungen:** natives HTML5 `<datalist>` (kein JS, keine neue Endpoint, kein
Fremd-Asset); der Steuermeldungen-Filter wird mit umgestellt; es werden **alle** Lieferanten
vorgeschlagen, inaktive erkennbar als `(inaktiv)` markiert — im Test-Export sind nur 50 von 316
aktiv, ohne Markierung wären 84 % der Vorschläge stillgelegte Konten.

---

## Mechanismus

Server-gerendertes `<datalist>` in einem Thymeleaf-Fragment. Ein `<datalist>` filtert im Gegensatz
zum `<select>` bei jedem getippten Zeichen per Teilstring — genau das gewünschte Verhalten — und
sein Popup malt der Browser außerhalb des DOM, ist also immun gegen `overflow`/`z-index` der zwei
Bootstrap-Modals.

Gewicht: ~317 Optionen ≈ 30 KB roh, **~6 KB gzip**. `application.properties:15-16` hat
`server.compression.enabled=true` mit `text/html`, alle betroffenen Seiten liegen über der 2-KB-
Schwelle. Gegen 205 KB Bootstrap-CSS ist das nicht messbar — eine JSON-Endpoint mit Debounce/
Stale-Guard-JS würde nichts einsparen, das die Komplexität rechtfertigt.

Bewusst in Kauf genommen: kein Styling, kein Match-Highlighting, kein „keine Treffer"-Hinweis, und
Firefox rendert nur das `label`. Letzteres wird entschärft, indem das `label` die **kombinierte**
Zeichenkette trägt (siehe unten).

---

## Server-Seite

### 1. `LieferantOption` um `aktiv` erweitern und nach `service.stamm` verschieben

`ifas-services/ifas-main-service/.../service/steuermeldung/LieferantOption.java`
→ `.../service/stamm/LieferantOption.java` (IntelliJ *Refactor ▸ Move*, siehe
`ide-refactoring.md`). Das Paket `service.stamm` ist neu; `IntegrationTestApplication` scannt
`at.oekb.ifas.service`, also keine Konfigurationsänderung.

```java
/** Ein Lieferant, wie er in der Vorschlagsliste der Lieferant-Felder angeboten wird. */
@NullMarked
public record LieferantOption(String lieferId, @Nullable String bezeichnung, boolean aktiv) {

    public String label() {
        String base = bezeichnung == null || bezeichnung.isBlank() ? lieferId : lieferId + " - " + bezeichnung;
        return aktiv ? base : base + " (inaktiv)";
    }
}
```

`Lieferant.aktiv` ist ein nullable `Boolean` (`@Convert(TJaNeinToBooleanConverter)`, DDL-Default
`'J'`). Als inaktiv gilt nur ein explizites `'N'` — `!Boolean.FALSE.equals(...)` —, damit ein
NULL-Satz nicht falsch markiert wird.

### 2. Neu: `LieferantQueryService`

`ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/stamm/LieferantQueryService.java`

Reine Verschiebung + Erweiterung von `SteuerMeldungQueryService.getLieferantOptions()` (:65-70) an
eine neutrale Stelle: `StmRecalcFormPageController` hat nichts mit Steuermeldung-Abfragen zu tun,
und ein `service.stamm`, das ein `service.steuermeldung.LieferantOption` zurückgibt, wäre eine
verdrehte Paketabhängigkeit.

```java
/** Lesezugriff auf den Lieferantenstamm ({@code kurs..lieferanten}) der gewählten Datenbank. */
@Service @NullMarked
public class LieferantQueryService {

    /**
     * Der Bypass-Lieferant der Steuermeldungs-Kette — bewusst kein Satz dieser Tabelle, sondern
     * das Pendant zum Legacy-Schalter {@code preis_ins.e -Loekb}. Er ist die Vorbelegung der
     * Lieferant-Felder und muss deshalb vorgeschlagen werden; ohne ihn würde die Liste bei der
     * Eingabe {@code oe} auf {@code db_oekbtest1} lenken, also auf den falschen Wert.
     */
    private static final LieferantOption OEKB_BYPASS =
            new LieferantOption(Lieferant.OEKB_LIEFER_ID, "OeKB (ohne Lieferanten-Prüfung)", true);

    private final LieferantRepository lieferantRepository;

    public LieferantQueryService(LieferantRepository lieferantRepository) {
        this.lieferantRepository = lieferantRepository;
    }

    /** Alle Lieferanten nach Liefer-ID, mit {@code oekb} an erster Stelle. */
    public List<LieferantOption> getLieferantOptions() {
        List<LieferantOption> options = new ArrayList<>();
        options.add(OEKB_BYPASS);
        lieferantRepository.findAll(Sort.by("lieferId")).stream()
                .map(lieferant -> new LieferantOption(
                        lieferant.getLieferId(),
                        lieferant.getBezeichnung(),
                        !Boolean.FALSE.equals(lieferant.getAktiv())
                ))
                .forEach(options::add);
        return options;
    }
}
```

**Keine neue Repository-Methode.** Das vorhandene `findAll(Sort.by("lieferId"))` liefert genau das
Gewünschte — und damit auch kein neues JPQL, das gegen alle drei DBMS abzusichern wäre.

`liefer_id` und `bezeichnung` sind `varchar` (`V011__lieferanten.sql`), also nicht Space-gepaddet;
kein `stripTrailing()` nötig.

### 3. `SteuerMeldungQueryService` entschlacken

`getLieferantOptions()` (:65-70), das Feld `lieferantRepository` (:32), der Konstruktor-Parameter
(:38) und die Zuweisung (:43) sowie der `LieferantRepository`-Import (:6) entfallen. Der Import von
`Lieferant` bleibt — `toDetail` (:76) braucht ihn weiter. Geprüft: `new SteuerMeldungQueryService`
kommt nirgends vor, der Service wird ausschließlich von Spring verdrahtet.

### 4. Konstante `Lieferant.OEKB_LIEFER_ID`

`ifas-database/ifas-persistence-stamm/.../stamm/Lieferant.java`:

```java
/**
 * Der Lieferant, unter dem die Meldestelle selbst liefert — bewusst kein Satz dieser Tabelle,
 * sondern das Pendant zum Legacy-Schalter {@code preis_ins.e -Loekb}. Der echte OeKB-Stammsatz
 * heißt {@code db_oekbtest1}. Der Vergleich ist case-sensitiv wie im Altsystem.
 */
public static final String OEKB_LIEFER_ID = "oekb";
```

Die Konstante existiert im Arbeitsbaum noch nicht (heute nur nackte Literale in
`SteuerMeldungDomainValidationService:115` und `FondsExporter:410`).

> **Überschneidung:** Der Plan `2026-09-04-oekb-lieferid-konstante-und-isin-listen-berechtigung.md`
> besitzt dieselbe Konstante *und* die Umstellung der beiden Literale. Hier wird **nur** die
> Konstante eingeführt, die Literal-Umstellung bleibt dort — sonst kollidieren die beiden Änderungen.

### 5. Neu: `LieferantSuggestionsAdvice`

`ifas-web/ifas-web-ui/src/main/java/at/oekb/ifas/web/LieferantSuggestionsAdvice.java`

```java
/**
 * Füllt das Model-Attribut {@code lieferantSuggestions}, das {@code fragments/lieferant-datalist}
 * rendert.
 * <p>
 * Bewusst auf diese Controller beschränkt: als globales {@code @ControllerAdvice} liefe die Abfrage
 * bei jedem Seitenaufbau der Anwendung.
 */
@ControllerAdvice(assignableTypes = {
        StmCalcFormPageController.class,
        IsinAnforderungslisteFormPageController.class,
        StmRecalcFormPageController.class,
        StmRecalcDetailPageController.class,
        StmRecalcListPageController.class,
        SteuerMeldungListPageController.class
})
@NullMarked
public class LieferantSuggestionsAdvice {
    // Konstruktor-Injektion von LieferantQueryService

    @ModelAttribute("lieferantSuggestions")
    List<LieferantOption> lieferantSuggestions() {
        return lieferantQueryService.getLieferantOptions();
    }
}
```

Warum ein Advice und nicht `model.addAttribute` je Handler: `stm-calc-form` und
`isin-anforderungsliste-form` rendern dasselbe Template bei Validierungsfehlern **erneut**
(`StmCalcFormPageController:174-180`, `IsinAnforderungslisteFormPageController:150-154`, bewusst
statt Redirect wegen `LegacyUiRedirectFilter`). Es wären also 7 Aufrufstellen plus 6
Konstruktor-Parameter. So bleibt es eine greppbare Deklaration und **kein** Controller wird
angefasst — außer `SteuerMeldungListPageController`, der dadurch sogar *einfacher* wird
(siehe unten).

Nicht in `GlobalModelAttributes`: das ist ein unqualifiziertes Advice, die Abfrage liefe dann auf
`/ui/`, `/ui/jobs`, jedem Download und jeder JSON-Endpoint unter `/ui/**` — ein `SELECT` gegen ein
entferntes Sybase für Seiten, die das Datalist nie rendern.

Multi-DB ist gratis korrekt: `WebAppMultiDbWebMvcConfig.WebAppMultiDbDataSourceInterceptor`
bindet `DatabaseContextHolder` in `preHandle` (:64-78) und räumt erst in `afterCompletion` (:80-91)
auf, also **nach** dem View-Rendering. Die Vorschläge kommen damit immer aus der in der Session
gewählten Datenbank.

### 6. `SteuerMeldungListPageController` vereinfachen

`model.addAttribute("lieferantOptions", queryService.getLieferantOptions())` (:71) **entfällt** —
das Attribut kommt jetzt unter dem einheitlichen Namen `lieferantSuggestions` aus dem Advice.
Keine neue Abhängigkeit, eine Zeile weniger.

---

## Template-Seite

### 7. Neu: `templates/fragments/lieferant-datalist.html`

Aufbau und der erklärende Kommentar nach dem Muster von `fragments/server-health-overview.html`.

```html
<!DOCTYPE html>
<html xmlns:th="http://www.thymeleaf.org" lang="de">
<body>

<!--
  Vorschlagsliste für die Lieferant-Felder. Erwartet eine List<LieferantOption>
  'lieferantSuggestions' (siehe LieferantSuggestionsAdvice). Einmal pro Seite einfügen, und zwar
  innerhalb von <section> - das Layout übernimmt nur ~{::section} -, und das Feld darauf zeigen:

      <input type="text" name="lieferant" list="lieferantSuggestionList" autocomplete="off" ...>
      <div th:replace="~{fragments/lieferant-datalist :: datalist}"></div>

  Das Feld bleibt absichtlich freier Text: "oekb" und noch nicht erfasste Lieferanten müssen
  tippbar bleiben, ein <select> wäre hier falsch.
-->
<datalist th:fragment="datalist" id="lieferantSuggestionList">
    <option th:each="option : ${lieferantSuggestions}"
            th:value="${option.lieferId}"
            th:attr="label=${option.label()}"></option>
</datalist>

</body>
</html>
```

Details, die so und nicht anders sein müssen:

- **`value` = nackte `lieferId`.** Das ist der Wert, der im Feld landet und an den Server geht.
- **`label` = die kombinierte Zeichenkette** aus `LieferantOption.label()`
  (`af_1741 - Erste AM`). Chrome/Edge zeigen `value` primär und filtern auf beides; Firefox zeigt
  nur das `label`. Steht die ID in beiden, sind ID *und* Bezeichnung in jedem Browser auffindbar
  und die ID auch in Firefox sichtbar. Preis: Chrome zeigt die ID zweimal.
- `th:attr="label=..."` statt `th:label` — `th:attr` ist im Projekt etabliert
  (`sql-console.html:45`), `th:label` kommt nirgends vor.
- Kein `th:if`-Leerlauf-Schutz nötig: `oekb` ist immer enthalten.
- `th:value`/`th:attr` escapen, das `&` in `"Ernst & Young …"` und Umlaute sind abgedeckt.

### 8. Die fünf Freitext-Felder

Je Feld zwei Attribute plus eine Zeile. Ein gemeinsames Input-Fragment wäre falsch: die Felder
unterscheiden sich in Klasse (`form-control` vs. `form-control-sm`), ID, Vorbelegung
(`value="oekb"` vs. `th:value="${settings.lieferant()}"` vs. `disabled`) und Umgebung — es bräuchte
sechs Parameter und wäre schlechter als die Wiederholung.

| Template | Feld | Fragment platzieren in |
|---|---|---|
| `stm-calc-form.html:31-37` | `id="lieferant"` | `<form th:if="${submittedJob == null}">` (:13) |
| `isin-anforderungsliste-form.html:31-37` | `id="lieferant"` | `<form th:if="${submittedJob == null}">` (:13) |
| `stm-recalc-form.html:38-44` | `id="lieferant"` | `<form th:if="${submittedJob == null}">` (:13) |
| `stm-recalc-detail.html:477-478` | `id="modalLieferant"` | `th:if="${recalculation != null and settings != null}"` |
| `stm-recalc-list.html:336` | `id="batchLieferant"` | `th:if="${archivedFilter == 'false'}"` |

Das Fragment muss **innerhalb** desselben bedingten Blocks wie das Feld liegen, sonst wird ein
verwaistes Datalist gerendert.

Beispiel `stm-calc-form.html`:

```html
<div class="col-12 col-md-6 col-lg-7">
    <input type="text"
           class="form-control"
           id="lieferant"
           name="lieferant"
           value="oekb"
           list="lieferantSuggestionList"
           autocomplete="off"
           placeholder="Lieferant eingeben oder auswählen"
           required>
    <div th:replace="~{fragments/lieferant-datalist :: datalist}"></div>
</div>
```

`autocomplete="off"` unterdrückt die Formular-Historie des Browsers, die sonst mit dem
Datalist-Popup konkurriert — es schaltet das Datalist **nicht** ab. Das wäre das erste
`autocomplete=`-Attribut im Projekt.

### 9. Der Steuermeldungen-Filter (`steuermeldung-list.html:71-79`)

Das `<select>` wird zum Textfeld mit demselben Datalist:

```html
<div class="col-md-3">
    <label for="filterLieferant" class="form-label">Lieferant:</label>
    <input type="text" class="form-control" id="filterLieferant" name="lieferant"
           th:value="${lieferantFilter}"
           list="lieferantSuggestionList"
           autocomplete="off"
           placeholder="Alle">
    <div th:replace="~{fragments/lieferant-datalist :: datalist}"></div>
</div>
```

Warum das serverseitig **nichts** kostet:

- `SteuerMeldungListQueryRepositoryImpl:146` prüft bereits
  `filter.lieferId() != null && !filter.lieferId().isBlank()` — leeres Feld = kein Filter, genau
  wie die bisherige `<option value="">Alle</option>`.
- Der Vergleich bleibt exakt (`lieferant.lieferId = :lieferId`), weil das Datalist die nackte
  `lieferId` einsetzt. Ein Tippfehler liefert 0 Treffer — dasselbe Verhalten wie beim
  Textfilter daneben.
- Das Auto-Submit funktioniert unverändert: `filterLieferant` steht schon in der
  `change`-Liste (:417), und ein `change` feuert beim Übernehmen eines Vorschlags wie beim Blur.
  **Keine JS-Änderung.**
- `lieferant=${lieferantFilter}` in den 16 Sortier-/Paging-Links bleibt unberührt.

Zwei Nebeneffekte, bewusst mitgenommen:

- **`oekb` wird filterbar.** `steuer_meldung.liefer_id` hat keinen FK auf `lieferanten`
  (`SteuerMeldungEntity:140-141`), Meldungen tragen real `liefer_id = 'oekb'` — genau das
  behandelt `FondsExporter:410` gesondert. Bisher war dieser Wert im Dropdown nicht wählbar, diese
  Zeilen also nicht filterbar. Das ist eine Lücke, die hier gratis zugeht.
- Inaktive Lieferanten erscheinen im Filter jetzt als `(inaktiv)` — im Filter über historische
  Meldungen eine nützliche Information, und sie bleiben selbstverständlich wählbar.

**Optionaler Einzeiler** in `SteuerMeldungListQueryRepositoryImpl:148`:
`parameters.put("lieferId", filter.lieferId().trim())`, damit ein mitkopiertes Leerzeichen nicht zu
0 Treffern führt. Der `text`-Zweig (:106) trimmt schon.

---

## Tests

Es entsteht kein neues SQL und in `ifas-web-ui` gibt es keinen Thymeleaf-Render-Harness (nur
Mockito-Unit-Tests wie `SqlConsolePageControllerTest`). Ein Render-Harness für ein `<datalist>` wäre
unverhältnismäßig. Getestet wird deshalb genau das, was Logik trägt — als reine Unit-Tests in
`ifas-services/ifas-main-service/src/test/java/at/oekb/ifas/service/stamm/`, wo
`spring-boot-starter-test` (JUnit 5, AssertJ, Mockito) schon vorhanden ist. Given-when-then + AssertJ
nach `testing-conventions.md`.

**`LieferantOptionTest`** — `label()` trägt jetzt die Markup-Semantik und war bisher ungetestet:
1. `givenBezeichnung_whenLabel_thenLieferIdAndBezeichnung`
2. `givenBlankBezeichnung_whenLabel_thenBareLieferId`
3. `givenInactiveLieferant_whenLabel_thenMarkedInaktiv`

**`LieferantQueryServiceTest`** (Mockito auf `LieferantRepository`):
4. `givenLieferanten_whenGetLieferantOptions_thenOekbFirstThenByLieferId` — pinnt Reihenfolge und
   den `oekb`-Eintrag in einer Assertion
   (`extracting(LieferantOption::lieferId).containsExactly("oekb", ...)`).
5. `givenLieferantWithAktivNull_whenGetLieferantOptions_thenTreatedAsActive` — pinnt
   `!Boolean.FALSE.equals(...)`, die einzige nicht offensichtliche Abbildung.

Nicht getestet, mit Absicht: `LieferantSuggestionsAdvice` (dreizeilige Delegation, die Logik liegt
im Service), das Fragment und die sechs Template-Änderungen (das würde Thymeleaf testen), sowie
das Filterverhalten der Browser (ohne Playwright-Harness in diesem Modul nicht prüfbar) — dafür
die manuelle Verifikation unten.

---

## Betroffene Dateien

```
NEU   ifas-services/ifas-main-service/.../service/stamm/LieferantQueryService.java
MOVE  ifas-services/ifas-main-service/.../service/steuermeldung/LieferantOption.java
      → .../service/stamm/LieferantOption.java        (+ Feld aktiv, label())
EDIT  ifas-services/ifas-main-service/.../service/steuermeldung/SteuerMeldungQueryService.java
EDIT  ifas-database/ifas-persistence-stamm/.../stamm/Lieferant.java          (OEKB_LIEFER_ID)
NEU   ifas-web/ifas-web-ui/.../web/LieferantSuggestionsAdvice.java
NEU   ifas-web/ifas-web-ui/.../templates/fragments/lieferant-datalist.html
EDIT  ifas-web/ifas-web-ui/.../web/stm/SteuerMeldungListPageController.java  (Zeile 71 entfällt)
EDIT  templates/stm-calc-form.html, isin-anforderungsliste-form.html, stm-recalc-form.html,
      stm-recalc-detail.html, stm-recalc-list.html, steuermeldung-list.html
NEU   ifas-services/ifas-main-service/src/test/.../service/stamm/LieferantOptionTest.java
NEU   ifas-services/ifas-main-service/src/test/.../service/stamm/LieferantQueryServiceTest.java
```

Commit-Aufteilung (nach `commit-messages.md`, direkt auf `master`):

1. `refactor: move the Lieferanten options query to a neutral LieferantQueryService`
2. `feat: suggest the known Lieferanten in the Lieferant input fields`

---

## Verifikation

```bash
# schnelle Runde
mvn clean install -Pno-proxy -Pdev-build \
  -pl ifas-database/ifas-persistence-stamm,ifas-services/ifas-main-service,ifas-web/ifas-web-ui -am
mvn test -Pno-proxy -pl ifas-services/ifas-main-service -Dtest='Lieferant*Test'

# voller Build (deckt auch forbiddenapis ab)
mvn clean install -Pno-proxy -Pdev-build
```

Der Teilbuild ist der eigentliche Test des Refactorings: er beweist, dass der `LieferantOption`-Move
alle Referenzen mitgenommen hat und der geschrumpfte `SteuerMeldungQueryService`-Konstruktor noch
verdrahtet.

**Manuell**, `LocalH2OnlyIfasApplication`, http://localhost:8080/ifas-uat:

1. **Zuerst mit leerer H2:** das Datalist enthält genau eine Option, `oekb`. Beweist den
   synthetischen Eintrag und dass keine Seite an einer leeren `lieferanten`-Tabelle bricht.
2. **Stammdaten laden**, z. B. „Basisdaten importieren" bei einer Rekalkulation
   (`StammBasedataCreator` → `LieferantTestdataCreator.createStandardLieferanten()`, 316 Sätze).
3. Alle sechs Felder durchgehen: `/ui/stm-calc`, `/ui/isin-anforderungsliste`, `/ui/stm-recalc`,
   `/ui/stm-recalculations/{id}` (Modal „Wiederholen"), `/ui/stm-recalculations` (Batch-Modal —
   erst „Lieferant überschreiben" anhaken), `/ui/steuermeldungen`. Erwartet: **317** Optionen,
   `oekb` zuerst, inaktive mit `(inaktiv)`.
4. `kepler` tippen → passender Satz erscheint (belegt das Label-Matching); `af_` tippen → nur die
   `af_*`-Sätze; einen Vorschlag übernehmen und absenden → die Anfrage trägt die nackte `lieferId`
   (POST-Body bzw. `liefer_id` des erzeugten Jobs prüfen).
5. **Beide Modals gezielt:** Popup wird nicht abgeschnitten, der Bootstrap-Focus-Trap frisst ↓/Enter
   nicht.
6. **Seitenquelltext einmal ansehen:** genau *ein* `<datalist id="lieferantSuggestionList">` pro
   Seite, innerhalb des gerenderten `<section>`, `&` und Umlaute escaped.
7. **Zwei Browser** — Chrome/Edge *und* Firefox. Firefox zeigt nur das `label`; dort bestätigt sich,
   ob die kombinierte Zeichenkette die richtige Wahl war.
8. **Regression `/ui/steuermeldungen`:** Filter auf einen Lieferanten setzen, sortieren und blättern
   — der Filter muss über Sortier- und Paging-Links erhalten bleiben; leeres Feld = alle Meldungen.

## Offene Punkte

- Firefox' exakte Matching-Regeln (Wert vs. Label) haben sich über Versionen verschoben und sind
  hier nicht empirisch geprüft — Schritt 7 ist deshalb Pflicht, nicht Kür.
- Welche Browser die OeKB-Anwender tatsächlich einsetzen (angenommen Chrome/Edge unter Windows).
- Ob `kurs..lieferanten` in Produktion dasselbe Aktiv-Verhältnis (~16 %) hat wie `sybtst02_tst`.
  Am Mechanismus ändert das nichts, nur an der Anzahl der `(inaktiv)`-Markierungen.
- Die Formulierung des synthetischen Eintrags (`"OeKB (ohne Lieferanten-Prüfung)"`).

---

## Ergebnis (2026-09-04)

Umgesetzt wie geplant, in zwei Commits:

- `fcc900d05` `feat: suggest the known Lieferanten in the Lieferant input fields`
- `86cea5311` `fix: give the Lieferant fields a chevron in every browser`

Der geplante Zwei-Commit-Split (Refactoring getrennt vom Feature) ging nicht: ohne das Advice
iteriert die Steuermeldungen-Liste ein fehlendes Model-Attribut, der Zwischenstand wäre also
kaputt. Deshalb ein Feature-Commit.

### Nachgezogen: Chevron

Firefox zeichnet für `input[list]` **keine** Affordance, Chrome eine eigene — das Feld sah in
Firefox wie ein reines Textfeld aus. Statt sich auf die Browser-Affordance zu verlassen, zeichnet
`ifas.css` jetzt den `.form-select`-Chevron für jedes `input[list]` selbst, `js/datalist-picker.js`
öffnet die Liste beim Klick darauf (`showPicker()`, nur in der Chevron-Zone, deren Breite aus
`padding-right` gelesen wird). Chromes eigener Pfeil braucht zum Ausblenden `!important` — siehe
[[project_native-datalist-limits]].

### Verworfen: `color-scheme: light`

Das schwarze Popup unter dunklem Firefox-Theme war **nicht** mit `color-scheme: light` auf `:root`
zu beheben — der Commit wurde zurückgenommen. Das Popup ist Browser-UI (Mozilla Bug 1756203), kein
Seiteninhalt; Firefox nimmt dafür sein eigenes Theme. Ebenso ist die Popup-Platzierung in Chrome
nicht steuerbar.

### Bewusst offen geblieben

Mathias hat sich nach Vorlage der Alternativen (eigenes DOM-Dropdown vs. reines `<select>` vs.
so lassen) entschieden, **das native `<datalist>` zu behalten** und mit dem dunklen bzw. versetzten
Popup zu leben. Damit bleibt offen und ist akzeptiert:

- Popup schwarz unter dunklem Firefox-Theme (nur über die Firefox-Theme-Einstellung hell zu
  bekommen)
- Popup in Chrome je nach Feldbreite und Label-Länge seitlich versetzt statt unter dem Feld

Zur Korrektur einer Plan-Aussage: „ein `<select>` wäre hier falsch" hält nicht. `oekb` steht
inzwischen selbst in der Liste, und ein nicht erfasster Lieferant ist zwar tippbar, scheitert aber
ohnehin an `ERR_LIEFERANT` (`SteuerMeldungDomainValidationService:119`). Ein `<select>` wäre also
möglich — er filtert nur nicht mitlaufend, und genau das war die Anforderung.
