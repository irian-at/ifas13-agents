# ERROR-STMs: `STM-ID-Ref` im Return-File — falscher Vorgänger-Getter

**Datum:** 2026-07-17
**Fundstelle:** gf4 (`gf4-d20260807.zip`), Zeile 21 — `LU0114064917`, `UPDATE 649585`
**Betroffene Datei:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java`

## Symptom

Return-File-STATUS-Zeile weicht zwischen Alt- und Neusystem ab:

```
Neusystem:  STATUS;ERROR;649585;;
Altsystem:  STATUS;ERROR;649585;649528
```

Das 4. Feld (`_STATUS_MELDUNGS_ID_REF`, im Legacy `nStm_id_vorherige`) bleibt im Neusystem leer.

## Feld-Mechanik (Neusystem)

- Output-Feld `STM_ID_REF` ← `StmStatusWithAdditionalInfo.referencedStmId()` (via `ProcessedSteuerMeldung.of(...)`, `ProcessedSteuerMeldung.java:42`).
- Erzeugt in `SteuerlicheErmittlungDomainService.calculateDeclinedOrErrorStatus`:
  - **DECLINED**-Zweige (`:639–642`) reichen `declinedInfo.referencedStmId()` durch (von den Validatoren aus der DB aufgelöst).
  - **Hard-ERROR**-Zweig (`:628`) rief ursprünglich `StmStatusWithAdditionalInfo.of(StmStatus.ERROR, inputStmId)` — und `.of(...)` setzt `referencedStmId = null` (`StmStatusWithAdditionalInfo.java:14–16`).
- Es gibt **keinen** zentralen STATUS-Writer mit Status-Guard: `writeReturnSteuerMeldungenToCsv` reicht `STM_ID_REF` unverändert durch. Nur die Command-Files `confirm.csv`/`delete.csv` löschen die Ref explizit (`CsvSteuerMeldungenWriter.java:70–91`, `withStmIdRef(null)`, OEKBSD-45290). CONFIRMED/DELETE sind Lieferant-Status und tauchen im Return-File nicht auf → für den ERROR-Fix irrelevant.

→ Der Wert muss **positiv upstream** im Domain-Layer gesetzt werden (wie die OPEN-/FINAL-/DECLINED-Zweige es bereits tun).

## Legacy-Referenz — welches Feld?

`WriteMeldung_STATUS` (`c_st_meldung.cpp:12200–12240`):

- **Return-File-Zweig** (`nIsEStBFile == 0`): schreibt `nStm_id_vorherige` (direkter Vorgänger, egal ob OPEN/FINAL) für jeden Status außer `CONFIRMED`/`DELETE` — **ERROR eingeschlossen**.
- **EStB-File-Zweig** (`nIsEStBFile == 1`): schreibt `nStm_id_vorherigeFINAL`.

→ Für das Return-File ist `nStm_id_vorherige` = `vorherige_stm_id` = Entity-`getVorherigeStm()` maßgeblich, **nicht** `vorherige_final_stm_id`.

## Der eigentliche Fehler im ersten Fix-Versuch

Der Fix hat `getVorherigeFinalStm()` (Spalte `vorherige_final_stm_id`) verwendet. Zwei zusammenfallende Probleme:

1. **Semantisch falsches Feld** — Return-File braucht den direkten Vorgänger, nicht den FINAL.
2. **Feld ist leer** — `vorherige_final_stm_id` ist in den gf-Fixtures praktisch überall `null` (kein `setVorherigeFinalStm`-Schreibpfad im Neusystem; gf4-Doc Z. 217–221).

Fixture-Beleg (`gf3-d20260805-export-AFTER.yaml.txt`, DB-Ausgangsstand für gf4):

```yaml
id: 649528
status: "FIN"           # 649528 IST FINAL (eigener Status)

id: 649585
status: "OPE"
vorherigeStmId: 649528  # gesetzt
# vorherigeFinalStmId:  → absent = null
```

→ `getVorherigeFinalStm(649585)` = null → `STM_ID_REF` leer → identischer Diff.

## Warum ist `vorherige_final_stm_id` im Altsystem null? (Legacy-Analyse)

`nStm_id_vorherigeFINAL` startet bei `0` (`c_st_meldung.cpp:812`) und wird nur gesetzt in:

| Ort | Zweig | Bedingung |
|---|---|---|
| `:8882` | CONFIRMED | Vorgängerkette erreicht FINAL |
| `:9217` | UPDATE auf OPEN | Chain-Walk findet FINAL-Ahnen |
| — | **UPDATE auf FINAL** (`:9060`) | **wird nie gesetzt** |

Geschrieben wird die Spalte nur bei `> 0` (`:10903` Insert / `:10994` Update).

**Wichtig:** Der Zweig hängt am Status der **referenzierten (aktualisierten)** Meldung (`strAStatus`), **nicht** am Status der Ergebnis-Meldung.

649585 entstand als **UPDATE direkt auf FINAL 649528** → `strAStatus == "FINAL"` → Zweig `:9060`. Der macht nur den Korrekturfrist-Check (15.12., SN-Fristen) und setzt `nStm_id_vorherigeFINAL` nie → Spalte bleibt `null`. Der direkte Vorgänger wird dagegen gesetzt (`nStm_id_vorherige = nStm_id`, `:10613`) → `vorherige_stm_id = 649528`.

### Gegenbeispiel 649595 — auch OPEN, aber Feld GESETZT

`gf6-d20260813-export-AFTER.yaml.txt` (Kette `649528 FIN → 649585 OPE → 649595 OPE`):

```yaml
id: 649595
status: "OPE"
vorherigeStmId: 649585        # direkter Vorgänger = OPEN
vorherigeFinalStmId: 649528   # ← GESETZT
```

| Ergebnis | UPDATE auf … | Zweig | `vorherige_final_stm_id` |
|---|---|---|---|
| 649585 (OPE) | 649528 = FINAL | `:9060` | null (nie gesetzt) |
| 649595 (OPE) | 649585 = OPEN | `:9157/:9217` | 649528 (Walk findet FINAL) |

→ Widerlegt „auf OPEN-Meldungen wird es generell nicht gesetzt". Es wird gesetzt — aber nur, wenn das FINAL erst per Chain-Walk *gesucht* werden musste (UPDATE auf OPEN). Beim direkten UPDATE auf ein FINAL wird es übersprungen.

**Bewertung:** Datenseitig unvollständige Denormalisierung (latenter Legacy-Bug), aber im Legacy harmlos — der FINAL-Zweig liest die Cache-Spalte nicht, sondern nimmt den Zufluss der direkt referenzierten Meldung. Bestätigt die Doku-Aussage „Cache, nicht Quelle, lückenhaft befüllt" und Option A (Chain-Walk statt Spalte).

## Fix

In `SteuerlicheErmittlungDomainService`:

1. Helper von `getVorherigeFinalStm()` auf `getVorherigeStm()` umstellen:

```java
@Nullable
private Long getVorherigeStmId(@Nullable Long stmId) {
    if (stmId == null) {
        return null;
    }
    SteuerMeldungEntity steuerMeldung = steuerMeldungRepository.getById(stmId);
    return steuerMeldung.getVorherigeStm() != null
            ? steuerMeldung.getVorherigeStm().getId()
            : null;
}
```

2. Methode `getVorherigeFinalStmId` → `getVorherigeStmId` umbenennen (irreführend), an allen drei Aufrufstellen:
   - `:108` (fatal-submission-level ERROR-Mapping)
   - `:234` (nicht-Lieferant-Status im recalc-Mode)
   - `:628` (real-ERROR-Zweig in `calculateDeclinedOrErrorStatus`)

## Verifikation

- gf4-Recalc: Zeile 21 (`LU0114064917`) → `STATUS;ERROR;649585;649528` statt `;;`.
- Diff `error#diff.txt` für gf4 Zeile 21 muss verschwinden.
- Regressions-Check: keine anderen ERROR-STMs verlieren/gewinnen fälschlich eine Ref (Return-File nur direkter Vorgänger).
