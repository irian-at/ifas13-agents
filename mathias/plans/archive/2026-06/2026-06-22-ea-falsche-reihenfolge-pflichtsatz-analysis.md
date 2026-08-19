# Analysis: Why Neusystem Rejects `EY_2026-06-03_144604.csv` With `Falsche Reihenfolge Pflichtsatz <EA>`

## Context

A quick-recalc validation comparing Altsystem (legacy CPP) vs. Neusystem (IFAS13 Java) shows 6 `ERROR` deviations — all of them only present in Neusystem, all of the same kind:

```
Zeile-Nr: 4  | EA;04.06.2026;02.06.2026
ERROR! Falsche Reihenfolge Pflichtsatz <EA>, Meldung kann nicht verarbeitet werden.
```

Goal: explain the behavioural difference and decide what to do about it.

## What the input actually looks like

`ifas-testing/ifas-integration-tests/target/quick-recalc/EY_2026-06-03_144604.csv` (first Meldung, lines 1‑17):

```
START;LU1699965122;InvF;A;EUR;...
STATUS;NEW
E;Ausschuettung_e;13489,6505           ← E record FIRST
EA;04.06.2026;02.06.2026               ← EA record AFTER first E
E;Gewinnvortrag_Ertraegeordentlich_versteuert_e;3,5549
...
Z;Z_Zinsen_Direktanlage_e;6207,2532;Y3
Z;Z_Ertragsausgleich_Zinsen_Direktanlage_e;930,8319;Y3
END;LU1699965122
```

EA appears **after the first E** but **before any D/Z/ZA/AS**. The same pattern repeats in all six Meldungen in the file → six identical errors.

## Why Neusystem rejects it

Validation rule for `STATUS=NEW` in
`ifas-domain/ifas-domain-stm/.../meldung/csv/CsvIfasStructureValidationRules.java:28-34`:

```java
case NEW, NEW_DECLINED -> new CsvIfasStructureValidationRules()
    .status(status)
    .requiredRecords("START", "STATUS", "E", "END")
    .uniqueRecords ("START", "STATUS", "EA", "END")
    .allowedRecords("START", "STATUS", "EA", "E", "D", "Z", "ZA", "AS", "END")
    .sequence      ("START", "STATUS", "EA", "E|D|Z|ZA|AS", "END");
```

The sequence checker (`CsvIfasSequenceValidations.java`) tracks the *highest position seen*:

- Line 3 `E` → position 3 → `highestSeen = 3`
- Line 4 `EA` → position 2 → `2 < 3` → **SEQUENCE_VIOLATION**

Mapped to user-facing message via `ValidationMsgMapper` → `ValidationMsgCode.ERR_REIHENFOLGE`
(`ifas-domain-stm/.../validation/ValidationMsgCode.java:161`).

## Why the legacy CPP doesn't complain

Source: `/home/sma/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp`

- Lines are processed strictly line-by-line in `AddZeile()`; the first column selects a per-record handler.
- The EA handler validates **field contents** (`CheckEARow`) but not its **position relative to E/D/Z/ZA/AS**.
- `cRecordCounter` is used only to forbid certain records in `DELETE`/`CONFIRMED` Meldungen, not to enforce ordering in `NEW`/`UPDATE`.
- No "Falsche Reihenfolge" / "Reihenfolge" / sequence string exists for EA in the legacy code.

Legacy accepts EA at any position between START/STATUS and END.

## The real bug: implementation is stricter than the documented business rule

The comment immediately above the rule definition
(`CsvIfasStructureValidationRules.java:25-26`) states:

```
// Bei den Feldern E, D, Z, ZA, AS prüfe ich die Reihenfolge derzeit nicht
//   – diese können in beliebiger Reihenfolge geliefert werden
// EA muss vor einem D, Z, ZA oder AS Satz geliefert werden
```

Documented intent:
- E/D/Z/ZA/AS are mutually order-free.
- **EA must precede D, Z, ZA, AS — but explicitly not E.**

What the code actually does: `sequence("START", "STATUS", "EA", "E|D|Z|ZA|AS", "END")` forces EA before *all of* E/D/Z/ZA/AS, including E. The EY file satisfies the documented rule (EA is before every Z) but violates the implemented sequence.

Same mismatch exists for `OPEN/ERROR/UPDATE/UPDATE_DECLINED/DELETED/FINAL` (line 57): `sequence("START", "STATUS", "EA", "E", "D", "STB", "END")` — even stricter.

## Recommendation (pending your call)

Three options, depending on who owns the truth here:

1. **Treat as Neusystem bug — align with documented rule and legacy behaviour.**
   Change the sequence for `NEW`/`NEW_DECLINED` (and analogously for the UPDATE-family rule) so that EA only needs to precede D/Z/ZA/AS, not E. Concretely place EA at the same sequence position as E (alternative), e.g.
   `sequence("START", "STATUS", "EA|E", "D|Z|ZA|AS", "END")`
   — verify against existing sequence tests (`CsvIfasValidationContextTest`, `invalid_sequence_validation.csv`).

2. **Treat as supplier bug — keep the strict rule.**
   Reject the EY file and have af_ernstyoung produce CSV with EA immediately after STATUS. Legacy was lax; tightening on purpose for IFAS13 is a defensible product decision.

3. **Make it status-version-dependent.**
   Some legal versions may require EA-first; others not. The `// todo - enhance with version` on line 20 already anticipates this.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/csv/CsvIfasStructureValidationRules.java` — rule definitions (lines 25‑34, 47‑57)
- `…/meldung/csv/CsvIfasSequenceValidations.java` — sequence-checking algorithm
- `…/validation/ValidationMsgCode.java:161` — `ERR_REIHENFOLGE` message
- `…/validation/ValidationMsgMapper.java` — `SEQUENCE_VIOLATION` → `ERR_REIHENFOLGE`
- Tests: `CsvIfasValidationContextTest`, `invalid_sequence_validation.csv` (currently only test E-before-STATUS, not the EA/E case)

## Verification

If option 1 is chosen:
- Re-run the quick-recalc; `error#diff-deviations.txt` should report 0 "Nur im Neusystem" errors for this file.
- Run the STM module tests: `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy`.
- Add a new sequence test case covering `START, STATUS, E, EA, E, Z, END` (should pass) and `START, STATUS, Z, EA, END` (should still fail).
