# Two-Mode `vorherige_final_stm_id` Resolver

**Datum:** 2026-07-21
**Ziel:** `STM_ID_REF` (Return-File Spalte 4) bei Hard-ERROR legacy-treu befüllen, indem der
entfernte `VorherigeFinalStmIdResolver` als **Provider mit zwei Modi** wieder eingeführt wird.
**Vorarbeit:** `plans/2026-07-20-legacy-vorherige-stm-final-write-rules.md` (Legacy-Verhalten),
`plans/2026-07-17-error-stm-id-ref-vorherige-stm.md` (Bug gf4 Zeile 21).

---

## Kernidee — zwei Auflösungsmodi, gekeyed auf `recalculationMode`

Die Spalte `vorherige_final_stm_id` ist in **legacy-importierten** Daten lückenhaft (Legacy
füllte sie nur, wenn der Ketten-Walk zur Laufzeit ein FINAL *fand* — UPDATE-auf-OPEN,
CONFIRMED-auf-UPDATE; bei UPDATE-auf-FINAL und importierten Lücken bleibt sie `null`,
`c_st_meldung.cpp:9060`). Die Spalte `vorherige_stm_id` (direkter Vorgänger) ist dagegen
durchgehend gesetzt.

Daraus die Zwei-Modus-Regel:

| Modus | `recalculationMode` | Datenquelle | Auflösung |
|---|---|---|---|
| **Calc** (wir persistieren selbst) | `false` | unsere eigene, vollständige Spalte | **direkt**: `referencedStm.getVorherigeFinalStm()` |
| **Recalc** (wir persistieren nicht, hängen an Legacy-Daten) | `true` | legacy-importierte, lückenhafte Spalte | **Ketten-Walk** über `vorherigeStm` bis zum ersten FINAL |

**Begründung:** Im Calc-Modus ist die Spalte von uns geschrieben und vollständig → direktes
Lesen ist korrekt und billiger. Im Recalc-Modus ist die Spalte Legacy-Import mit Lücken → wir
dürfen sie *nicht* lesen, sondern müssen den (verlässlichen) `vorherigeStm`-Chain walken, um
exakt den Wert zu reproduzieren, den Legacy zur Laufzeit ermittelt und ins Return-File
geschrieben hätte.

`recalculationMode()` und `persistResult()` sind getrennte Flags
(`SteuerlicheErmittlungDomainService:183/238/285/306/502/548/604`). Der Provider keyed auf
`recalculationMode()`.

---

## Ist-Zustand

- Resolver in `2a329ac00` entfernt; **Walk-Infrastruktur überlebte**:
  `SteuerMeldungRepository.findAncestorInfoById()` (`:39`) + `StmAncestorInfo`-Projektion
  existieren noch. `SteuerMeldungRepository:29` javadoc referenziert noch den entfernten Resolver.
- ERROR-Ref-Helper `SteuerlicheErmittlungDomainService.getVorherigeStmId()` (`:677`) liefert den
  **direkten Vorgänger** (single hop, kein FIN-Check) — semantisch falsch, zwei TODOs markieren es.
  Aufrufer: `:118` (fatal submission-level), `:245` (unknown status recalc), `:649` (real ERROR).
- Persist-Pfad `finishProcessingOpen:579-593`: UPDATE-auf-FINAL → `updatedStmId` (`:585`);
  UPDATE-auf-OPEN → `updatedStm.getVorherigeFinalStm()` (`:588`, `//todo walk the chain`);
  CONFIRMED analog `:536`. Das ist bereits **Calc-Modus-direkt** (One-Hop + Spalte).
- `calcPersistedStmDiffs` (einziger Vergleich von `VORHERIGE_FINAL_STM_ID`, `StmDiffs:49`) ist
  **totes Codepfad** — nirgends aufgerufen. Grossfile-Recalc vergleicht via
  `compareCalculatedStmWithLegacyReturnStm` nur das Return-File (`STM_ID_REF`).

## Legacy-Fakten (verifiziert)

- **`:118` file-level fatal** und **`:245` unknown status**: Legacy schreibt Spalte 4 **leer** —
  Fehler wird vor jedem der vier `nStm_id_vorherige`-Setz-Punkte erkannt, `ResetValues()` hat
  auf 0 gesetzt. → beide Neusystem-Sites geben `null`.
- **`:649` real ERROR**, referenzierte Meldung R = `inputStmId` (§7 Tabelle):
  | R | ref |
  |---|---|
  | OPEN, FINAL in Kette | dieser FINAL |
  | OPEN, kein FINAL | `null` |
  | FINAL (UPDATE-auf-FINAL) | `null` (`:9060`) |
  | Input NEW / DELETE | `null` |
- gf4 Zeile 21: R = 649585 (OPEN), `vorherigeStm` = 649528 (FINAL) → Walk liefert 649528 →
  `STATUS;ERROR;649585;649528`.

---

## Umsetzung

### 1. Resolver wieder einführen, als Zwei-Modus-Provider

Wiederherstellen aus `2a329ac00^` nach
`ifas-domain/ifas-domain-stm/.../meldung/VorherigeFinalStmIdResolver.java`, erweitert:

```java
@Service @NullMarked @RequiredArgsConstructor
public class VorherigeFinalStmIdResolver {

    private final SteuerMeldungRepository stmRepository;

    /**
     * Auflösung von vorherige_final_stm_id für die referenzierte/aktualisierte Meldung.
     * Calc-Modus liest die eigene (vollständige) Spalte; Recalc-Modus walkt die
     * legacy-importierte vorherigeStm-Kette, weil deren Spalte lückenhaft ist.
     */
    public Optional<Long> resolve(SteuerMeldungEntity referencedStm, boolean recalculationMode) {
        return recalculationMode
                ? findFinalAncestorId(vorherigeStmId(referencedStm))   // exklusiv: R selbst übersprungen
                : directColumn(referencedStm);
    }

    private Optional<Long> directColumn(SteuerMeldungEntity stm) {
        return stm.getVorherigeFinalStm() != null
                ? Optional.of(stm.getVorherigeFinalStm().getId())
                : Optional.empty();
    }

    // erhaltene Projektion, kein Managed-Entity im Read-Context
    public Optional<Long> findFinalAncestorId(@Nullable Long startVorherigeStmId) {
        String finCode = StmStatus.FINAL.getX3Code();
        Long cursor = startVorherigeStmId;
        while (cursor != null) {
            StmAncestorInfo a = stmRepository.findAncestorInfoById(cursor).orElse(null);
            if (a == null) return Optional.empty();
            if (finCode.equals(a.getStatusCode())) return Optional.of(a.getId());
            cursor = a.getVorherigeStmId();
        }
        return Optional.empty();
    }
}
```

- Walk startet **exklusiv** bei `R.getVorherigeStm()` (R selbst übersprungen) — deckt „direkter
  Vorgänger ist FINAL" (erster Hop, gf4) und tiefere Ketten ab.
- `SteuerMeldungRepository:29` javadoc bleibt gültig (referenziert wieder den Resolver).

### 2. ERROR-Ref-Pfad (`:649`)

`getVorherigeStmId(...)`-Aufruf ersetzen. Gating nach §7-Tabelle:

```java
Long ref = null;
if ((inputStatus == StmStatus.UPDATE || inputStatus == StmStatus.CONFIRMED)
        && isOpen(referencedStm)) {                       // R FINAL / NEW / DELETE → null
    ref = vorherigeFinalStmIdResolver
            .resolve(referencedStm, options.recalculationMode())
            .orElse(null);
}
return StmStatusWithAdditionalInfo.of(StmStatus.ERROR, inputStmId, ref);
```

- `referencedStm` = `steuerMeldungRepository.getById(inputStm.getStmId())`.
- R-OPEN-Guard bildet „UPDATE-auf-FINAL → null" ab (Legacy `:9060`).

### 3. Sites `:118` / `:245`

`getVorherigeStmId(...)` durch `null` ersetzen (Legacy schreibt dort leer). Danach den
ungenutzten Helper `getVorherigeStmId` (`:677`) löschen.

### 4. Persist-Pfad — Wert immer über den Zwei-Modus-Resolver auflösen und persistieren

**Präzisierung (Nutzer):** Zwei entkoppelte Artefakte:
- **Return-File** (`referencedStmId` / Spalte 4) → **spiegelt Legacy** (Tabellen A/B) — inkl.
  Legacy-Lücken (DELETE = leer, UPDATE-auf-FINAL-ERROR = leer …).
- **Persistierte DB-Spalte** `vorherige_final_stm_id` → **immer den aufgelösten Wert schreiben**
  (falls vorhanden), *nicht* Legacy-Persistenzlücken nachbilden.
- **Auflösung** überall über den Resolver: Recalc → Ketten-Walk (spiegelt Legacy-Laufzeit),
  Calc → direkte Spalte.

Konkret:
- `finishProcessingOpen` UPDATE-auf-OPEN → `resolver.resolve(updatedStm, recalculationMode)`
  (statt reine Spalte); UPDATE-auf-FINAL bleibt `updatedStmId` (die FINAL selbst).
  `referencedStmId` bleibt = direkter Vorgänger (`updatedStmId`), Legacy-treu.
- `finishProcessingFinal` (CONFIRMED) → `resolver.resolve(confirmedStm, recalculationMode)`;
  speist **beides** (Return Spalte 4 *und* persistierte Spalte) — Table B: CONFIRMED-col4 =
  FINAL-Ahne, deckt sich mit der persistierten Spalte, daher hier korrekt zusammengeführt.
- `finishProcessingDeleted` → Return Spalte 4 = **`null`** (Legacy Table B: DELETED leer);
  `deleteSteuerMeldung` fasst die Spalte ohnehin nicht an (Legacy `DeleteMeldung` ebenso), Zeile
  behält ihren bereits persistierten Wert → PersistInfo bekommt `null`. Der reine `getById`-Load
  entfällt (Existenz oben validiert + Write-Kontext prüft erneut).

`directColumn` ist damit nur noch resolver-intern (Calc-Zweig) → `private`.

### 5. Tests

- `VorherigeFinalStmIdResolverTest` aus `2a329ac00^` wiederherstellen, um **beide Modi** erweitern:
  - Calc: `resolve(stm, false)` = Spaltenwert bzw. leer.
  - Recalc: `resolve(stm, true)` = Walk-Ergebnis (erster Hop FINAL; tiefe Kette; keine FINAL → leer).
- Neuer Recalc-Fall **tiefe Kette** (`FIN → OPE → OPE`, ERROR referenziert die zweite OPE) — die
  einzige Konstellation, die direkter-Vorgänger von FINAL-Ahne unterscheidet (gf4 wird schon vom
  ersten Hop grün). Deckt die Divergenz ab, die gf4 nicht zeigt.
- ERROR-Ref-Gating: R FINAL → null; Input NEW/DELETE → null; R OPEN ohne FINAL → null.
- `SteuerMeldungPersistenceServiceTest`: unverändert grün (Persist-Verhalten gleich).
- Verifikation: gf4-Recalc Zeile 21 `LU0114064917` → `STATUS;ERROR;649585;649528`; `error#diff.txt`
  für gf4 Zeile 21 verschwindet; keine Regression bei anderen ERROR-STMs.

---

## Entscheidungen & Annahmen

- **Opt.1/Opt.2 obsolet:** Ersetzt durch die Entkopplung Return (spiegelt Legacy) ↔ Persist
  (schreibt immer den aufgelösten Wert). Auflösung ist zwei-modig (Recalc-Walk / Calc-Spalte).
  Persist walkt im Recalc-Modus mit → die persistierte Spalte kann von der Legacy-`export-AFTER`-
  Baseline abweichen; da `calcPersistedStmDiffs` tot ist, hat das aktuell keine Test-Kosten.
- **`calcPersistedStmDiffs` bleibt tot** — keine aktive Absicherung der persistierten
  `vorherige_final_stm_id`. Wenn später eine Regressionsabsicherung gewünscht ist, separat in
  `GrossfileRecalculationTest` verdrahten (eigene Änderung, hier bewusst out-of-scope).
- **Calc-Modus-Lücke am Migrationsrand:** Referenziert eine Calc-Produktions-UPDATE einen
  legacy-importierten OPEN mit lückenhafter Spalte, propagiert das direkte Lesen die Lücke. Vom
  Nutzer akzeptiert (Calc-Modus vertraut eigenen Daten); Recalc walkt ohnehin, daher keine
  Recalc-Fidelity-Einbuße. Dokumentiert, nicht behoben.

## Betroffene Dateien

- `ifas-domain/ifas-domain-stm/.../meldung/VorherigeFinalStmIdResolver.java` (neu/wiederhergestellt)
- `ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java` (Inject +
  `:118/:245/:649`, Helper löschen, `:588`-Kommentar)
- `ifas-database/ifas-persistence-stm/.../steuermeldung/SteuerMeldungRepository.java` (javadoc `:29`)
- `ifas-testing/.../meldung/VorherigeFinalStmIdResolverTest.java` (wiederhergestellt + erweitert)
- ggf. Grossfile-Recalc-Fixture für die tiefe ERROR-Kette
