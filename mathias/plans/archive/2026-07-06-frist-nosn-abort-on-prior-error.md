# Plan: `ERR_FRIST_NOSN` (and Selbstnachweis-Fristen) — abort-on-prior-error gate

> **Status: DRAFT — do NOT implement yet.** Awaiting confirmation with Fachabteilung
> (see "Open question for Fachabteilung" below). This document scopes the fix only.

## Context

**Symptom (gf3, Zeile 41).** For
`START;LU0136043634;InvF;T;EUR;01.01.2025;31.12.2025;NEIN;…` (`STATUS;CONFIRMED;649539`),
an Ausschüttungsmeldung, the new system emits `ERR_FRIST_NOSN`
("Die Meldung erfolgt nach der Meldefrist und ist nicht als Selbstnachweis gekennzeichnet")
as `[+] NUR IM NEUSYSTEM (FEHLER)`. The legacy does **not** emit it — legacy instead rejects
the meldung earlier with `ERR_AUSSCHT_AKT_CONF` (Ausschüttungstag ≤ Stichtag) and returns.

**Rejected idea — a Jahresmeldung gate.** The initial hypothesis was that `ERR_FRIST_NOSN`
should only fire for Jahresmeldungen (field 7 = `JA`), never for Ausschüttungsmeldungen
(field 7 = `NEIN`). This is **empirically false**: gf3 Zeile 132
(`LU0111465547`, `CONFIRMED 649584`, field 7 = `NEIN` = Ausschüttungsmeldung) is an
`[=] EXAKTER TREFFER` for `ERR_FRIST_NOSN` — the legacy *does* fire it on an
Ausschüttungsmeldung. A Jahresmeldung gate would:
- fix gf3-41 ✓, but
- turn gf3-132 from exact match into a **regression** (`[-] nur im Altsystem`) ✗, and
- not fix gf4-18 (which is `JA`) ✗.

The differentiator between gf3-41 (suppress) and gf3-132 (keep) is **not** Jahresmeldung —
both are `NEIN`. It is whether a **prior rejecting error** occurred:
- gf3-41: prior `ERR_AUSSCHT_AKT_CONF` → legacy `return -1` before the Fristen check.
- gf3-132: no prior error → legacy reaches the Fristen check → `ERR_FRIST_NOSN` fires legitimately.

**Root cause.** The new system's `SteuerMeldungStatusValidationService.validate()` never aborts;
it collects all messages and unconditionally runs the FRISTENPRÜFUNGEN block. The legacy
instead short-circuits: a rejecting error in the pre-Fristen checks means the Fristen check is
never reached. This is the same root cause already written up for gf4-18 in
`docs/Rekalkulation/Fachabteilung-FRIST-NOSN-gf4.md` (see its lines 128–130).

## Legacy mechanics (verified in `c_st_meldung.cpp`)

`ERR_FRIST_NOSN` lives **only** inside `CheckLieferfristen()` (`c_st_meldung.cpp:9579`), together
with `ERR_SN_INMELDEFRIST` and `ERR_FRIST_SN`. Its condition (line 9697–9706) is purely:

```cpp
if (strSelbstnachweis == "NEIN")            // no Jahresmeldung check anywhere
    if (daFristDatum > daGj_ende)           // filed after Meldefrist (gjEnde + 7M)
        → ERR_FRIST_NOSN
```

`CheckLieferfristen()` is invoked from three places, each with different pre-conditions:

| Call site | Status | Runs after… | Early-return before it? |
|---|---|---|---|
| `4175` (in generic `CheckMeldung`) | **NEW** (and dead `CONFIRMED` branch) | record checks (`CheckEARow`, etc.) | **No** — record errors do *not* abort; `CheckMeldung` reaches 4175 regardless. This is why gf1-1 shows `ERR_SN_AUSSCH` **and** `ERR_SN_INMELDEFRIST` together. |
| `3011` (in `ProcessMeldung_CONFIRMED`) | **CONFIRMED** | `CheckVorhandeneMeldung` (2988) | **Yes** — any error there `return -1` (line 3001) before 3011. `nConfirm_update==0` additionally required. |
| `9260` (in `CheckVorhandeneMeldung`, UPDATE-on-OPEN else-branch) | **UPDATE** | earlier `CheckVorhandeneMeldung` checks | **Yes** — earlier errors `return -1` first. |

Confirmed early-return errors in `CheckVorhandeneMeldung` (both `return -1`, both before the
Fristen check):
- `ERR_AUSSCHT_AKT_CONF` — `c_st_meldung.cpp:8942–8953` (gf3-41).
- `ERR_UNGL_VORH` (Gj vs. ursprüngliche Meldung) — hard ERROR for CONFIRMED, `return -1` at
  the end of the function (gf4-18). For UPDATE the same mismatch is soft (Info), so it does
  **not** abort.

Key asymmetry: the "Gj vs. **Stammdaten**" mismatch is a *different* check (not in
`CheckVorhandeneMeldung`) and does **not** abort — that is why gf1-64 / gf1-286 fire the
Stammdaten mismatch **and** `ERR_FRIST_NOSN` together.

## Empirical safety audit (all 8 grossfiles)

Every Fristen deviation (`ERR_SN_INMELDEFRIST`, `ERR_FRIST_SN`, `ERR_FRIST_NOSN`) was checked
for co-occurring errors:

- **Only two** Fristen deviations are `NUR IM NEUSYSTEM` (to be fixed): **gf3-41** and
  **gf4-18** — both `CONFIRMED`, both with a co-occurring **in-service** ERROR
  (`ERR_AUSSCHT_AKT_CONF` / `ERR_UNGL_VORH`).
- Every **exact-match** Fristen case co-occurs at most with errors produced by **other**
  services (`ERR_SN_AUSSCH`, "Ungültige Anzahl … EA", Gj-vs-Stammdaten mismatch, Fonds-beendet)
  — never with an in-service ERROR from `SteuerMeldungStatusValidationService`.
- gf3-132 (`NEIN`, exact match) has **no** co-occurring error → must keep firing.

**Conclusion:** gating the Fristen trio on "a prior **in-service** ERROR exists, for a non-NEW
meldung" fixes gf3-41 and gf4-18 and regresses nothing across the corpus. Because the gate only
sees this service's own `validationMsgs` list, the domain/CSV errors that legacy also does not
treat as aborting (`ERR_SN_AUSSCH`, Gj-vs-Stammdaten) are invisible to it — which is exactly the
faithful behavior.

## Proposed change

Single file: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java`
(`validate(...)`, the FRISTENPRÜFUNGEN block, currently lines ~233–312).

Insert a guard immediately before the Fristen trio and wrap the three `CheckLieferfristen`
validators (`errSnInmeldefrist`, `errFristSn`, `errFristNosn`) in it:

```java
// Legacy: for CONFIRMED/UPDATE the Fristen check (CheckLieferfristen) is only reached if
// CheckVorhandeneMeldung did not already reject the meldung (c_st_meldung.cpp:3001, 9260).
// A prior rejecting ERROR therefore suppresses the whole CheckLieferfristen trio.
// NEW is exempt: its Fristen check runs at c_st_meldung.cpp:4175 regardless of preceding
// (record-level) errors — e.g. ERR_SN_AUSSCH coexists with ERR_SN_INMELDEFRIST (gf1-1).
boolean priorRejectingError = status != StmStatus.NEW
        && validationMsgs.stream().anyMatch(ValidationMsg::isError);

if (!priorRejectingError) {
    SteuerMeldungFristenValidators.errSnInmeldefrist(...);
    SteuerMeldungFristenValidators.errFristSn(...);
    if (shouldCheckFristNosn) {
        SteuerMeldungFristenValidators.errFristNosn(...);
    }
}
```

Notes:
- Reuses the existing `ValidationMsg.isError()` helper
  (`ValidationMsg.java:69`; `Severity` has only `ERROR`/`INFO`).
- The existing `shouldCheckFristNosn` / `hasPriorFinal` gate
  (`isShouldCheckFristNosn`, Korrekturfrist-vs-Meldefrist) stays and composes with this guard.
- The `unglVorhSeverity` logic (`SteuerMeldungStatusValidators.java:533`) already returns ERROR
  for non-UPDATE and INFO for UPDATE, so keying on ERROR-severity automatically reproduces the
  legacy hard/soft asymmetry (CONFIRMED aborts, UPDATE-Gj-mismatch does not).
- `errUpdTolate` / `errConUpdTolate` (Korrekturfrist) stay **after** and **outside** the guard.

## Out of scope / deliberately excluded

- **`ERR_UPD_TOLATE` / `ERR_CON_UPD_TOLATE`.** These live in the legacy `CheckVorhandeneMeldung`,
  not `CheckLieferfristen`, with their own early-return ordering. All corpus occurrences are
  clean exact matches with no co-occurring gating error, so leaving them ungated causes no
  regression. Extending the abort semantics to them would be a separate, faithfulness-only change.
- **NEW path.** Intentionally never gated (legacy 4175 runs unconditionally).
- **Reordering / true early-return in `validate()`.** Not needed — a scoped guard is sufficient
  and keeps the "collect as much as possible" design for all non-Fristen messages.

## Open question for Fachabteilung

Confirm the business intent: *when a CONFIRMED/UPDATE meldung is already rejected by a
vorgelagerte Prüfung (e.g. Ausschüttungstag vergangen, Gj-Ende ≠ ursprüngliche Meldung), should
the Meldefrist-/Selbstnachweis-Fristen also be reported, or suppressed as in the legacy?*
The legacy suppresses them (early `return -1`); this plan mirrors that. The alternative
(new system reports them additionally as extra ERRORs) is arguably more informative but diverges
from the legacy return files. Proceed only after this is confirmed.

## Verification

1. `mvn -q -pl ifas-domain/ifas-domain-stm -am -Pno-proxy test` (unit tests).
2. Extend `SteuerMeldungFristenValidatorsTest` / status-validation tests with the two shapes:
   - CONFIRMED + prior `ERR_AUSSCHT_AKT_CONF` → no `ERR_FRIST_NOSN` (gf3-41).
   - CONFIRMED + prior `ERR_UNGL_VORH` (ERROR) → no `ERR_FRIST_NOSN` (gf4-18).
   - CONFIRMED, no prior error, late → `ERR_FRIST_NOSN` still fires (gf3-132, guard against
     over-suppression).
   - NEW + `ERR_SN_AUSSCH`-style prior error → `ERR_SN_INMELDEFRIST` still fires (gf1-1).
3. Re-run the grossfile recalc integration comparison and confirm the `error#diff.txt` deltas:
   gf3-41 and gf4-18 flip from `NUR IM NEUSYSTEM` to resolved; gf3-132 and all exact-match
   Fristen/Korrekturfrist lines remain exact matches; deviation counts for all 8 grossfiles do
   not regress.
```
