# `_STATUS_MELDUNGS_ID_REF` recalc diff (gf5) — decision needed

**Date:** 2026-07-21
**Status:** analysis complete, awaiting decision
**Scope:** `VorherigeFinalStmIdResolver` (production) + `GrossfileRecalculationTest` lockdown (test)

## Context

While enhancing `GrossfileRecalculationTest` to lock down field-level `StmDiff`s, gf5 shows exactly
one status-field diff:

```
STATUS_MELDUNGS_ID_REF: NEU = 649528 / ALT = n.v.
```

The new system writes a previous-final-STM reference (`649528`) into the return file where the
legacy return left it empty. This is driven by the (currently uncommitted) `VorherigeFinalStmIdResolver`.
Question to resolve: **is this an intended improvement over legacy, or a resolver gap that should
reproduce legacy's null?**

## The concrete case

Fund **numWfsKu 35705**, ISIN **LU0114064917**, GJ-Ende **2025-12-31**. The gf5 DB seed
(`gf4-d20260807-export-AFTER.yaml.txt`) contains exactly two meldungen for this fund/GJ:

| STM     | status        | `vorherige_stm` | `vorherige_final_stm_id` (stored) | gueltBis | gueltAb    |
|---------|---------------|-----------------|-----------------------------------|----------|------------|
| 649528  | `FIN` (final) | — (base of chain) | —                               | null (active) | 2026-02-27 |
| 649585  | `OPE` (open)  | **649528** (on the final)    | **null**             | null (active) | 2026-03-02 |

Chain: **649585 (OPE) → 649528 (FIN)**. 649585 is an open working version sitting directly on the
finalized report 649528.

gf5 delivery (Stichtag 2026-08-10) applies one operation: input `STATUS;UPDATE;649585` (no confirm,
no delete). Both systems process it to `ERROR` status; neither recalculates the Ermittlung
(`nachgerechnet: ❌`).

The resolver walk (recalc mode):
```
findFinalAncestorId( vorherige_stm(649585) = 649528 )
  → look up 649528 → status == FIN → return 649528   (stops at the first hop)
```

This is the **UPDATE-on-FINAL** boundary: the updated meldung's immediate `vorherige_stm` is itself
the FINAL, so the single-hop walk returns 649528 — where legacy wrote null.

## Root cause

- **Legacy return:** `STATUS;ERROR;649585` — no ref. Per `VorherigeFinalStmIdResolver`'s own Javadoc,
  legacy only filled `vorherige_final_stm_id` "when its runtime walk found a FIN; **UPDATE-on-FINAL**
  and imported gaps stay null (`c_st_meldung.cpp:9060`)." The seed confirms 649585's stored
  `vorherigeFinalStmId` is null.
- **New system (recalc mode):**
  `VorherigeFinalStmIdResolver.findFinalAncestorId(vorherigeStmId(649585))` = `findFinalAncestorId(649528)`.
  It checks 649528 first, sees `status = FIN`, and returns it immediately → the return gets
  `_STATUS_MELDUNGS_ID_REF = 649528`.

So the walk returns the **immediate FINAL predecessor** for an UPDATE-on-FINAL, where legacy left it null.

## Proof from the altsystem return files (what legacy actually writes in col 4)

Empirical analysis of all 8 legacy `_return.csv` files: the `_STATUS_MELDUNGS_ID_REF`
(col 4) is **always the meldung's immediate `vorherige_stm`** (the previous version) — open or
final alike, **not** the nearest FINAL. Across the grossfiles, legacy refs point to an **OPEN**
predecessor **13×** and a **FINAL** predecessor **11×**; in every verifiable row `ref ==
vorherige_stm(meldung)`.

Clinching case — chain `649595 (OPE) → 649585 (OPE) → 649528 (FIN)`:

| delivery | legacy return  | ref written | ref status |
|----------|----------------|-------------|------------|
| gf3      | `OPEN; 649585` | 649528      | FIN (649528 is 649585's immediate predecessor) |
| gf6      | `OPEN; 649595` | **649585**  | **OPE** — the open immediate predecessor, not the final 649528 two hops back |

⇒ Legacy col 4 = DB `vorherige_stm_id` (immediate previous), **not** `vorherige_final_stm_id`.
The resolver's `findFinalAncestorId` (walks past OPEN to the nearest FINAL) does **not** match this
for open-on-open chains: gf6 would yield 649528 where legacy wrote the open 649585. This reframes
the decision below — the question isn't only UPDATE-on-FINAL; legacy's semantics for col 4 appear to
be "immediate previous version," full stop.

## Legacy code confirmation — `WriteMeldung_STATUS` (c_st_meldung.cpp:12187)

Two output files, two different refs:
- **Return file** (else branch, 12218-12237): col 4 = `nStm_id_vorherige` = *"die ID der vorherigen
  Meldung (unabhängig ob OPEN oder FINAL)"* — the immediate previous. Skipped for `CONFIRMED`/`DELETE`.
- **EStB / Datenbezieher file** (12204-12213): col 4 = `nStm_id_vorherigeFINAL` (previous FINAL),
  skipped for `CONFIRMED` — *"Datenbezieher ... mit dem Bezug auf OPEN Meldungen nichts anfangen können"*.

Return status for a confirmation = `FINAL` (via `GetNewStatus()`, callers 11887/11937), and for a
confirmation `nStm_id_vorherige == 0` (a CONFIRMED finalizes the current meldung, references no previous)
⇒ **col 4 is empty on FINAL rows**. Holds for all 29 FINAL return rows incl. 649579 (DB pred 649522, no ref).
Field semantics: c_st_meldung.h:639 (`nStm_id_vorherige`) vs :643 (`nStm_id_vorherigeFINAL`).

**Resolution of the line-550/551 todo:** for the CONFIRMED path, `vorherigeFinalStmId` is used for two
things — split them:
- return-file col 4 (`StmStatusWithAdditionalInfo` referencedStmId, line 550) → should be **`null`** (legacy writes null on FINAL).
- persisted DB `vorherige_final_stm_id` (`SteuerMeldungPersistInfo`, line 563) → **keep** `vorherigeFinalStmId` (legacy maintains it, c_st_meldung.cpp:10995).

Current code matches legacy only when `vorherigeFinalStmId` resolves to null (e.g. 649579); it diverges on
a re-confirmation where a prior FINAL exists (writes the final into col 4 where legacy writes null).

## ERROR-case col 4 — confirmed CORRECT (no change needed)

Legacy `CheckVorhandeneMeldung` walks from the referenced meldung's predecessor back to the first FINAL
and stores it in `nStm_id_vorherige`: UPDATE-on-OPEN at c_st_meldung.cpp:9211-9218, CONFIRMED-with-pred
at :8876-8883 (both set `nStm_id_vorherige = nStm_id_vorherigeFINAL = <FIN id>`). The ERROR return row
emits `nStm_id_vorherige` (status ERROR ≠ CONFIRMED/DELETE, not suppressed) ⇒ **nearest FINAL ancestor**.
`resolveErrorReferencedStmId` (guards UPDATE/CONFIRMED + referenced status OPEN, then resolves FIN ancestor)
matches exactly. Per-operation summary: OPEN(accepted update)=immediate vorherige; ERROR=nearest FINAL;
FINAL(confirmed)=null. Data can't independently prove it (only error-ref case gf4 649585→649528 has the
FINAL as the immediate predecessor), but the legacy code is unambiguous.

## The tension

`VorherigeFinalStmIdResolver`'s recalc-mode contract says the chain-walk exists to *"reproduce the
value legacy wrote to the return file."* Here it does the opposite — it produces `649528` where
legacy's return had nothing, for exactly the `UPDATE-on-FINAL` case the Javadoc names as a legacy null.

## Current implementation vs. legacy (per operation, col 4 = `referencedStmId` arg of `StmStatusWithAdditionalInfo`)

| operation | col-4 source (code) | matches legacy "immediate previous"? |
|-----------|---------------------|--------------------------------------|
| UPDATE→OPEN (`finishProcessingOpen:604-610`) | `updatedStmId` (the updated STM) | ✅ yes |
| CONFIRMED→FINAL (`finishProcessingConfirmed:547-552`) | `vorherigeFinalStmId` = resolver nearest-FINAL | ⚠️ no (only when immediate predecessor is FINAL) |
| hard ERROR (`:655-658`→`resolveErrorReferencedStmId:700`) | resolver nearest-FINAL of referenced open STM | ⚠️ no |
| DECLINED (`:670-673`) | `declinedInfo.referencedStmId()` | separate source |
| DB read (`DbSteuerMeldungen:105-107`) | `getVorherigeStm().getId()` | ✅ yes |

So the UPDATE path already writes the immediate previous; **CONFIRMED and hard-ERROR write the nearest
FINAL** (`findFinalAncestorId`), diverging from legacy only when the immediate predecessor is OPEN with a
FINAL behind it. Existing `// todo`s at `SteuerlicheErmittlungDomainService:550-551` flag exactly this
(incl. "create test for new, confirmed, update, update, confirmed — welche ID ist tatsächlich stm_id_ref").

**Legacy col-4 rule (proven from existing real returns — no synthetic fixture needed, which would be
tautological anyway):**
- OPEN rows → immediate `vorherige_stm` (open or final)
- ERROR / *_DECLINED → referenced stm
- **FINAL rows → NO ref, always** — incl. the real confirmed-on-open case gf5 649579 (FIN, immediate
  pred 649522 = OPE) which legacy left ref-less; all 29 FINAL rows are ref-less.

⇒ For `new→confirmed→update→update→confirmed` the final return row carries **no ref**; the ref only
appears on the intermediate OPEN update rows (= immediate previous). This answers the line-551 todo
directly. Definitive cross-check available in legacy C++ `c_st_meldung.cpp` (~/dev/projects/oekb/ifas,
cited at :9060) — the status-record writer — without needing any new fixture.

## Options

1. **Expected improvement (keep as-is).** Legacy's return was genuinely gappy for UPDATE-on-FINAL;
   referencing the superseded final is more correct. No code change. The diff stays locked down as
   `gf5 StatusDiffExpectation(1, 0)`.

2. **Resolver gap (fix).** To faithfully reproduce legacy, `findFinalAncestorId` should return empty
   when the starting cursor *is itself* the FINAL being updated (legacy's "vorherige final" = a final
   *strictly before* the updated one). Likely a guard in `findFinalAncestorId`, or pass
   `vorherigeStmId(referencedStm.vorherigeStm)` as the initial cursor. Then gf5's status count drops
   to 0 → update `gf5` baseline to `StatusDiffExpectation(0, 0)`.

**Decision hinges on:** for an UPDATE directly on a FINAL, should the return reference that FINAL, or
match legacy's null?

## Current test state (already in place)

`GrossfileRecalculationTest` (test-only, no production change) now locks down, per grossfile:
- `FieldDiffExpectation` — `calculatedVsOldReturn` error/warning counts (all datasets `(0,0)`:
  calculated STM matches legacy return field-by-field).
- `StatusDiffExpectation` — `STATUS_*` diffs from `newReturnVsOldReturn` only:
  gf1 `(7,0)`, gf2 `(2,0)`, **gf5 `(1,0)`** (this diff), rest `(0,0)`.

If option 2 is chosen, only the `gf5` `StatusDiffExpectation` needs re-baselining to `(0,0)`.

## Relevant files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/VorherigeFinalStmIdResolver.java`
  — `findFinalAncestorId` (the walk), recalc-vs-calculation mode contract.
- `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/GrossfileRecalculationTest.java`
  — `countStatusReturnDiffs`, `StatusDiffExpectation`, gf5 baseline.
- Related background: `mathias/automemory/project_gf1-fielddiff-null-vs-zero.md`
  (why calculatedVsOldReturn is 0; the null-vs-explicit-zero return-file noise excluded from the lockdown).
