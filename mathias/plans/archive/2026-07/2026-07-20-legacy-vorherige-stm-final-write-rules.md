# Altsystem: Wann werden `vorherige_stm_id` und `vorherige_final_stm_id` gesetzt?

**Datum:** 2026-07-20
**Zweck:** Vollständiges Verhaltensbild des Altsystems (`c_st_meldung.cpp`, `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4`) als Grundlage für den `STM_ID_REF`-Fix im Neusystem. Legacy ist ISO-8859-1 → `grep -a`.

**Kernerkenntnis vorab:** Es gibt **zwei getrennte Artefakte** mit **unterschiedlicher** Belegung:
1. die **persistierten DB-Spalten** `vorherige_stm_id` / `vorherige_final_stm_id` (nur bei erfolgreichem Save),
2. das **Return-File-Feld Spalte 4** (`STM_ID_REF`), das die Runtime-Variable `nStm_id_vorherige` zum Schreibzeitpunkt ausgibt.

Beide speisen sich aus denselben zwei Runtime-Variablen, aber zu unterschiedlichen Zeitpunkten ihres Lebenszyklus — daher die Asymmetrie Erfolg vs. Fehler.

---

## Business-Regeln (Zusammenfassung)

Zwei Merksätze; Herleitung in §1–§9.

### Regel 1 — Wann wird `vorherige_final_stm_id` (DB) geschrieben?

**Geschrieben** wird die **per Ketten-Walk gefundene FINAL**, und nur wenn der Walk lief:
- **UPDATE auf eine OPEN** → Insert der neuen OPEN-Korrektur (`:9218` → `:10904`);
- **CONFIRMED einer aus UPDATE entstandenen OPEN** → Finalisierung (`:8883` → `:10995`).

**Leer** bleibt sie bei: **NEW**; **UPDATE auf FINAL** (Direktvorgänger *ist* der FINAL → steht in `vorherige_stm_id`, `:9060` walkt nicht); **UPDATE auf OPEN ohne FINAL in der Kette**; **CONFIRMED einer aus NEW entstandenen OPEN**. `DELETE` und der Beenden-Pfad (`BeendeAlteMeldung`) ändern keine der beiden Spalten (nur `guelt_bis`; Status bleibt).

**Fachlicher Kern:** `vorherige_final_stm_id` hält den bindenden FINAL, der erst durch *Überlaufen offener Korrekturen gefunden* werden musste. Ist der direkt korrigierte Satz selbst FINAL, steht dieser bereits in `vorherige_stm_id` — der Slot bleibt leer. Später kann ein CONFIRMED die Spalte für so eine Kette nachtragen.

**Invariante (Altsystem-Daten):** Existiert ein FINAL-Ahne, steht er in `vorherige_stm_id` (falls dieser FINAL ist) **oder** in `vorherige_final_stm_id` (falls tiefer) — nie beides leer.

`vorherige_stm_id` selbst = der **direkt korrigierte** Satz (referenzierte ID), geschrieben nur bei UPDATE (`:10613`); NEW/CONFIRMED/DELETE ändern ihn nicht.

### Regel 2 — Welcher Wert kommt in `stm_ref_id` (Return-File)?

`stm_ref_id` = `nStm_id_vorherige` zur Schreibzeit. Bei **Annahme** wurde er (nur für UPDATE) auf den **direkten Vorgänger** überschrieben (`:10613`); bei **Ablehnung/ERROR** (Rückkehr davor) hält er den **gewalkten FINAL**:

| Input | Ergebnis | `stm_ref_id` |
|---|---|---|
| NEW | OPEN (Annahme) | leer |
| NEW | abgelehnt (Duplikat, `ERR_JAHRESM_VORH`) | ID der existierenden Meldung |
| UPDATE | OPEN (Annahme) | **direkter Vorgänger** (referenzierte ID) |
| UPDATE | ERROR/DECLINED | **gewalkter FINAL**, falls Vorgänger OPEN-mit-FINAL; sonst leer (u. a. UPDATE-auf-FINAL) |
| CONFIRMED | FINAL (Annahme) / abgelehnt | **gewalkter FINAL**, falls Confirm-auf-UPDATE; sonst leer |
| DELETE | DELETED / abgelehnt | leer |

Für die **confirm.csv / delete.csv Vorschlagsfiles** (Status `CONFIRMED`/`DELETE`) wird `stm_ref_id` grundsätzlich unterdrückt (OEKBSD-45290) — betrifft nicht das Return-File.

**Fachlicher Kern:** Bei **Annahme** referenziert die Antwort den *direkt korrigierten* Satz (UPDATE) bzw. nichts (NEW/Confirm-auf-NEW/DELETE). Bei **Ablehnung** referenziert sie den *bindenden FINAL-Anker* der Korrektur, falls vorhanden — der Ablehnungsgrund hängt an der Korrekturfrist gegen diesen FINAL.

---

## 1. Lebenszyklus der zwei Runtime-Variablen

Beide werden pro Meldung in `ResetValues()` auf `0` gesetzt (`:811/:812`).

### `nStm_id_vorherige`
| Zeile | Kontext | Wert |
|---|---|---|
| `:7878` | `CheckVorhandeneMeldung`, NEW auf bereits vorhandene Jahresmeldung (`ERR_JAHRESM_VORH`) | ID der **existierenden** Meldung (`nAId`) |
| `:8882` | `CheckVorhandeneMeldung`, CONFIRMED-Walk trifft FINAL | **FINAL**-Ahne (`nBstm_id`) |
| `:9217` | `CheckVorhandeneMeldung`, UPDATE-auf-OPEN-Walk trifft FINAL | **FINAL**-Ahne (`nDstm_id`) |
| `:10613` | `SaveNewMeldung`, nur `if angeliefert=="UPDATE"` | **direkter Vorgänger** (`nStm_id` = referenzierte ID) — **nur im Erfolgspfad** |
| `ReadMeldung:12746` | Bind Spalte 22 beim DB-Lesen | DB-Wert `vorherige_stm_id` der gelesenen Meldung |

### `nStm_id_vorherigeFINAL`
| Zeile | Kontext | Wert |
|---|---|---|
| `:8883` | CONFIRMED-Walk trifft FINAL | FINAL-Ahne (`nBstm_id`) |
| `:9218` | UPDATE-auf-OPEN-Walk trifft FINAL | FINAL-Ahne (`nDstm_id`) |
| `ReadMeldung:12763` | Bind Spalte 39 beim DB-Lesen | DB-Wert `vorherige_final_stm_id` |

**Nie gesetzt im UPDATE-auf-FINAL-Zweig** (`:9060`) — der macht nur den Korrekturfrist-Check. Das ist der Grund, warum `649585` (UPDATE auf FINAL `649528`) `vorherige_final_stm_id = null` hat.

---

## 2. Wann werden die DB-Spalten persistiert?

Nur zwei Schreibpfade berühren die Spalten (plus `ReadMeldung`, das nur liest):

### `SaveNewMeldung` — INSERT einer neuen OPEN-Zeile (`:10583`)
- Frühabbruch bei Status ERROR (`IsNewError()`, `:10595`) → **kein INSERT**, nichts persistiert.
- Beide Spalten stehen **nur dann** in Spaltenliste + VALUES, wenn `angeliefert == "UPDATE"` (`:10790–10793`, `:10900–10907`):
  - `vorherige_stm_id = nStm_id_vorherige` — bei `:10613` auf `nStm_id` (= referenzierte/direkte Vorgänger-ID) gesetzt.
  - `vorherige_final_stm_id = nStm_id_vorherigeFINAL` **nur wenn `> 0`**, sonst `null`.
- Bei `angeliefert == "NEW"`: **keine** der beiden Spalten im INSERT → beide `null`.

### `SaveFinalMeldung` — UPDATE OPEN→FINAL bei CONFIRMED (`:10960`)
- `set ... vorherige_final_stm_id = nStm_id_vorherigeFINAL` **nur wenn `> 0`** (`:10994–10995`).
- `vorherige_stm_id` wird **nicht** angefasst (bleibt wie auf der OPEN-Zeile).
- `nConfirm_update == 1` (CONFIRMED auf UPDATE mit FINAL-Ahne) → zusätzlich `BeendeAlteMeldung(nStm_id_vorherige)` beendet die alte FINAL.

### `DeleteMeldung` (`:11627`)
- Setzt nur `status_code=DELETED`, `guelt_bis`, `delete_file_id`. **Keine** der Vorgänger-Spalten.

---

## 3. Tabelle A — Persistierte DB-Spalten je Übergang

„referenzierte Meldung" = die in der `STATUS`-Zeile genannte Meldung, auf die sich NEW/UPDATE/CONFIRMED/DELETE bezieht.

| Input | referenzierte Meldung | Ergebnis-Zeile | `vorherige_stm_id` | `vorherige_final_stm_id` |
|---|---|---|---|---|
| **NEW** | — (keine) | neue OPEN | `null` (nicht im INSERT) | `null` |
| **UPDATE** | OPEN, FINAL in Kette | neue OPEN | direkter Vorgänger (`:10613`) | **FINAL-Ahne** (Walk `:9218`) |
| **UPDATE** | OPEN, kein FINAL | neue OPEN | direkter Vorgänger | `null` |
| **UPDATE** | FINAL | neue OPEN | direkter Vorgänger (= die FINAL) | `null` (`:9060` setzt nie) |
| **CONFIRMED** | OPEN aus NEW (kein Vorgänger) | Zeile → FINAL | unverändert | `null` (Walk läuft nicht, `nConfirm_update=0`) |
| **CONFIRMED** | OPEN aus UPDATE (FINAL in Kette) | Zeile → FINAL | unverändert | **FINAL-Ahne** (Walk `:8883`) |
| **DELETE** | OPEN | Zeile → DELETED | unverändert | unverändert |

**Merksatz Persistenz:** `vorherige_stm_id` = *direkter* Vorgänger (nur bei UPDATE-Insert). `vorherige_final_stm_id` = *FINAL-Ahne aus dem Ketten-Walk* — geschrieben nur, wenn der Walk lief (UPDATE-auf-OPEN, CONFIRMED-auf-UPDATE). Bei UPDATE-auf-FINAL, NEW, CONFIRMED-auf-NEW bleibt es `null`.

---

## 4. Tabelle B — Return-File Spalte 4 (`STM_ID_REF`)

`WriteMeldung_STATUS` (Return-File-Zweig `:12223–12240`) gibt `nStm_id_vorherige` aus, außer bei `szPStatus ∈ {CONFIRMED, DELETE}` (das betrifft nur die confirm.csv/delete.csv-**Vorschlagsfiles**, nicht das Return-File). Maßgeblich ist der **Variablenwert zur Schreibzeit** — und der hängt davon ab, ob `SaveNewMeldung:10613` schon lief:

- **Erfolg (OPEN):** `:10613` hat `nStm_id_vorherige` auf den **direkten Vorgänger** überschrieben.
- **Fehler/Declined:** Rückkehr **vor** `:10613` (aus `CheckVorhandeneMeldung`, `CalcMeldung`, `CheckKontrollsummen`) → Variable hält den **Walk-Wert** (FINAL-Ahne) bzw. `0`.

| Ausgang | Input / Konstellation | col3 (`nStm_id`) | col4 (`STM_ID_REF`) | Herkunft col4 | Empirisch |
|---|---|---|---|---|---|
| Erfolg OPEN | NEW | neue ID | *leer* | `nStm_id_vorherige=0` | — |
| Erfolg OPEN | UPDATE | neue ID | **direkter Vorgänger** | `:10613` | `STATUS;OPEN;649595;649585` ✓ |
| Erfolg FINAL | CONFIRMED auf NEW | conf. ID | *leer* | Walk lief nicht | `STATUS;FINAL;649587` ✓ |
| Erfolg FINAL | CONFIRMED auf UPDATE | conf. ID | FINAL-Ahne | Walk `:8882` | (analog zu CONFIRM_DECLINED) |
| Erfolg DELETED | DELETE | ref. ID | *leer* | keine Var gesetzt | — |
| **Fehler ERROR** | **UPDATE auf OPEN, FINAL in Kette** | ref. ID | **FINAL-Ahne** | Walk `:9217`, `:10613` übersprungen | `STATUS;ERROR;649585;649528` ✓ |
| Fehler ERROR | UPDATE auf FINAL | ref. ID | *leer* | `:9060` setzt nie | — |
| Fehler ERROR | UPDATE auf OPEN, kein FINAL | ref. ID | *leer* | Walk findet nichts | — |
| Declined NEW_DECLINED | NEW, Jahresmeldung existiert | *leer* | existierende ID | `:7878` | (ERR_JAHRESM_VORH) |
| Declined NEW_DECLINED | NEW, Fristverletzung | *leer* | *leer* (+ Anmerkung) | — | `STATUS;NEW_DECLINED;;;Die Meldung erfolgt nach der Meldefrist…` ✓ |
| Declined UPDATE_DECLINED | UPDATE auf FINAL / ohne FINAL | ref. ID | *leer* | kein Walk-Treffer | `STATUS;UPDATE_DECLINED;649571` ✓ |
| Declined CONFIRM_DECLINED | CONFIRMED auf UPDATE, FINAL in Kette | conf. ID | **FINAL-Ahne** | Walk `:8882` | `STATUS;CONFIRM_DECLINED;649592;649553` ✓ |

**Merksatz Return-File:** Im **Erfolgs-OPEN**-Fall = direkter Vorgänger (`:10613`). In **allen Fehler-/Declined-Fällen** = der **FINAL-Ahne aus dem Walk** (oder leer, wenn kein FINAL / UPDATE-auf-FINAL / NEW; Sonderfall NEW-bereits-vorhanden = die existierende Meldung).

---

## 5. Die Asymmetrie Erfolg ↔ Fehler (der `:10613`-Dreh- und Angelpunkt)

Dieselbe Variable `nStm_id_vorherige` → dieselbe Ausgabespalte, aber:

```
CheckVorhandeneMeldung  → Walk setzt nStm_id_vorherige = FINAL-Ahne   (z.B. 649528)
   │
   ├─ Fehler → return -1 → WriteMeldung_StatusOnly  →  col4 = FINAL-Ahne
   │
   └─ Erfolg → CalcMeldung → SaveMeldung
                               └ SaveNewMeldung:10613  nStm_id_vorherige = nStm_id (direkter Vorgänger)
                                 → WriteMeldung        →  col4 = direkter Vorgänger
```

Für gf4-Zeile-21 fallen beide zusammen (649585's direkter Vorgänger **ist** die FINAL 649528). Erst bei einer tieferen Kette (`FIN → OPE → OPE`, UPDATE auf die zweite OPE) würden sie divergieren: Fehler-col4 = tiefe FINAL, Erfolg-col4 = direkte OPE.

---

## 6. Zwei getrennte Artefakte — die Entkopplung

Persistierte Spalte und Return-File-Feld sind **unabhängige Schreibpfade** und können getrennt behandelt werden:

| Artefakt | Quelle im Neusystem | Legacy-Semantik |
|---|---|---|
| persistierte `vorherige_final_stm_id` | `SteuerMeldungPersistInfo.vorherigeFinalStmId` (`SteuerMeldungPersistenceService:95-97`), berechnet in `finishProcessingOpen`/`finishProcessingConfirmed` | Tabelle A (nur bei erfolgreichem Save) |
| Return-File `STM_ID_REF` | `StmStatusWithAdditionalInfo.referencedStmId` → `ProcessedSteuerMeldung.of:42` | Tabelle B (`nStm_id_vorherige` zur Schreibzeit) |

**Korrektur einer früheren Fehlannahme:** Das Neusystem persistiert `vorherige_final_stm_id` sehr wohl (via PersistInfo). Es ermittelt den Wert aber durch **Lesen der Vorgänger-Spalte**, nicht per Walk:
- `finishProcessingOpen`: OPEN-Vorgänger → `updatedStm.getVorherigeFinalStm()`; FINAL-Vorgänger → `updatedStmId` selbst;
- `finishProcessingConfirmed`: `confirmedStm.getVorherigeFinalStm()`.

Daraus folgt ein **inkonsistenter Ist-Zustand** ggü. Legacy:
- bei UPDATE-auf-FINAL füllt das Neusystem den neuen Row mit der FINAL (`updatedStmId`) — Legacy lässt `null` (`:9060`) → Abweichung;
- bei UPDATE-auf-OPEN mit **importiertem, lückenhaftem** Vorgänger **propagiert** es die Lücke (schriebe `649595.vorherigeFinal = null`, wo Legacy `649528` hat).

Also: weder exakt legacy-parity noch vollständig.

---

## 7. Fix der Return-`STM_ID_REF` bei ERROR

Das Neusystem trennt die Ref-Pfade bereits weitgehend korrekt:
- **Erfolgs-OPEN** (`finishProcessingOpen`): `referencedStmId = updatedStmId` = direkter Vorgänger. ✓ passt zu Legacy-Erfolg (Tabelle B).
- **Declined** (`SteuerMeldungFristenValidators.findReferencedStmIdForKorrekturfrist`, `errConUpdTolate`, `ERR_JAHRESM_VORH`): benutzt bereits `vorherigeFinalSteuerMeldung` (Walk) bzw. die existierende ID. ✓
- **Hard-ERROR** (`SteuerlicheErmittlungDomainService.calculateDeclinedOrErrorStatus:628`): setzt `referencedStmId = null` — **die Lücke**.

**Benötigter Wert (referenzierte Meldung R = `inputStmId`):** nächster FINAL **strikt über R**, aber nur wenn R OPEN:

| R | referencedStmId |
|---|---|
| OPEN, FINAL in Kette | dieser FINAL |
| OPEN, kein FINAL | `null` |
| FINAL (UPDATE-auf-FINAL) | `null` (`:9060`) |
| NEW- / DELETE-Input | `null` |

**Auflösung (3-Fall, Cache-first mit Walk-Fallback):**
1. `R.getVorherigeFinalStm()` gesetzt → dessen ID (befüllte Altsystem-/Neusystem-Daten);
2. sonst `R.getVorherigeStm()` ist FINAL → dessen ID (u. a. gf4: R=649585, vorherige=649528=FIN);
3. sonst → **Repo-Walk** ab `R.getVorherigeStm()` (importierte lückenhafte Ketten).

Fall 2 ist der erste Hop von Fall 3 → äquivalent zu `Fall 1 + walk(R.getVorherigeStm())`. gf4 wird bereits durch Fall 2 grün; der Walk deckt nur tiefe importierte Ketten ab.

**Warum der Walk zwingend bleibt:** Der ERROR-Row wird **nicht persistiert** → seine Ref wird aus der referenzierten Vorgänger-Meldung aufgelöst, und die ist oft legacy-importiert **mit Lücke** (`649585.vorherigeFinal = null`). Vollständiges Befüllen ab jetzt (siehe Abschnitt 8) hilft dort nicht — importierte Vorgänger behalten ihre Lücken.

**Ausschließen:** `getVorherigeStm()` allein (direkter Vorgänger — nur gf4-Zufall korrekt, divergiert bei tiefer Kette) und reines `getVorherigeFinalStm()` (Spalte — bei importierten Vorgängern lückenhaft).

**Umsetzung:** `VorherigeFinalStmIdResolver` (repo-gestützt, 3-Fall) wieder einführen, in `SteuerlicheErmittlungDomainService` injizieren, entfernte Tests mitbringen. Validator bleibt beim In-Memory-Walk (andere Datenquelle — Reuse-Ausnahme). Nur an `:628` aufrufen, gated auf Input-Status UPDATE/CONFIRMED. `:108` (fatales Submission-Level) und `:234` (unbekannter Status) → vermutlich `null` lassen (Legacy-Pfad noch nicht getracet, siehe Abschnitt 9).

---

## 8. Persistierung von `vorherige_final_stm_id` — zwei Optionen

Da `StmDiffs:49` `VORHERIGE_FINAL_STM_ID` gegen die Legacy-`export-AFTER`-Baseline (mit Lücken) vergleicht, ist „in jedem Fall vollständig schreiben" eine **bewusste Abweichung** von der Baseline:

| | persistierte Spalte | StmDiffs / Baseline | Return `STM_ID_REF` |
|---|---|---|---|
| **Opt. 1 — legacy-parity** | Lücken **nachbilden** (bei UPDATE-auf-FINAL `null` lassen; importierte Lücken nicht auffüllen) | matcht Baseline unverändert | via Resolver legacy-treu |
| **Opt. 2 — vollständig** | immer nächster FINAL-Ahne (per Walk auch für UPDATE-auf-FINAL und importierte Ketten) | `VORHERIGE_FINAL_STM_ID` muss aus dem Diff **ausgenommen** oder Baseline neu erzeugt werden | via Resolver legacy-treu |

Beide halten den Return-File legacy-treu (Abschnitt 7 unverändert). Fachlich spricht nichts gegen Opt. 2; der Preis ist der Recalc-Vergleich.

Bei **Opt. 2** könnte **ein** gemeinsamer Walk-Resolver sowohl den Persist-Pfad (`finishProcessingOpen`/`finishProcessingConfirmed`) als auch die ERROR-Ref speisen → sauberste Variante, aber erst nach der StmDiffs-Entscheidung.

---

## 9. Empfehlung & offene Punkte

**Empfehlung — zweistufig:**
1. **Jetzt (der Bug):** nur die Return-`STM_ID_REF` bei ERROR via Resolver fixen (Abschnitt 7). Entkoppelt, rührt Persistenz & StmDiffs nicht an → gf4 wird grün.
2. **Separat:** Entscheidung Opt. 1 vs Opt. 2 für die persistierte Spalte (Abschnitt 8) als eigene Änderung.

**Offene Verifikationspunkte:**
- **StmDiffs-Kosten von Opt. 2:** Wird `VORHERIGE_FINAL_STM_ID` aktuell wirklich verglichen oder irgendwo gefiltert (`StmDiffFieldFilterPatterns`)? Entscheidet, wie teuer Opt. 2 ist — und ob der heutige inkonsistente Zustand (Abschnitt 6) schon Diffs wirft.
- **Legacy-Pfade `:108` / `:234`:** noch nicht getracet — schreibt das Legacy dort ein Ref oder leer? (bestimmt, ob der Resolver dort dranbleibt).
- **Keine tiefe-Ketten-ERROR-Fixture** (`FIN → OPE → OPE`): Divergenz direkter-Vorgänger vs. FINAL-Ahne ist aus dem Code hergeleitet; die CONFIRM_DECLINED-Zeile `649592;649553` belegt den Walk-Mechanismus unabhängig. Ggf. eigenen Testfall bauen.
