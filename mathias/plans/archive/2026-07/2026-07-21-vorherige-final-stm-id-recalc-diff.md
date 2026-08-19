# `_STATUS_MELDUNGS_ID_REF` (col 4) semantics — legacy rule + neusystem mapping

**Date:** 2026-07-21 (corrected 2026-07-23)
**Status:** CONFIRMED path reverted to `vorherigeFinalStmId`; two open items remain
**Scope:** `SteuerlicheErmittlungDomainService` (col-4 population), `VorherigeFinalStmIdResolver`,
`GrossfileRecalculationTest` lockdown

## ⚠️ Correction (2026-07-23)

An earlier version of this doc concluded **"legacy never writes a ref on FINAL rows / col 4 = the
immediate `vorherige_stm`, full stop."** That was **wrong**. It was an artifact of the 8 grossfiles
containing only *first-time* confirmations (no prior FINAL in the chain → nearest-final is trivially
null → empty). A real return file with a **re-confirmation** shows a FINAL row that *does* carry a ref.
The `null` change to the CONFIRMED path was reverted back to `vorherigeFinalStmId`.

## What col 4 is

`_STATUS_MELDUNGS_ID_REF` — the referenced previous meldung id in the return-file STATUS record
(4th field: `STATUS;<status>;<meldungs_id>;<ref_id>`).

## Legacy rule (return file), from `WriteMeldung_STATUS` (c_st_meldung.cpp:12187-12241)

Return file is written by `WriteMeldung` / `WriteMeldung_StatusOnly` →
`WriteMeldung_STATUS(fOut, pcStatusM->GetNewStatus())` (11887/11937). A confirmation carries status
**`FINAL`** — *not* `CONFIRMED`. The literal `"CONFIRMED"` is only passed by `WriteConfirmMeldung`
(11965), which writes the **separate confirm file**. So the return branch's guard
(`szPStatus != "CONFIRMED" && != "DELETE"`, 12228-12234) does **not** suppress FINAL rows → col 4 =
`nStm_id_vorherige` is written on FINAL rows too.

`nStm_id_vorherige` is populated per operation (validation walk in `CheckVorhandeneMeldung` sets it to
the nearest FINAL; the accepted-OPEN path then overwrites it with the immediate id, e.g. :10613):

| operation → return row | col 4 = | legacy source |
|------------------------|---------|---------------|
| accepted UPDATE → OPEN | **immediate `vorherige_stm`** (open or final) | :7878/:10613 overwrite |
| CONFIRMED → FINAL | **nearest FINAL ancestor** | walk :8825-8886 (`nStm_id_vorherige = nStm_id_vorherigeFINAL = <FIN>`) |
| ERROR (UPDATE/CONFIRMED-on-open) | **nearest FINAL ancestor** | walk :9157-9218 / :8825-8886 |
| NEW → OPEN base / no predecessor | empty | — |
| EStB/Datenbezieher file (any) | `nStm_id_vorherigeFINAL` | branch 12204-12213 |

So col 4 is populated on OPEN, FINAL and ERROR rows alike — empty only when the relevant predecessor
doesn't exist. Empirically the grossfiles only cover the coincident cases (immediate == nearest-final)
and first-time finals; the asymmetry above is from the legacy code, confirmed by the user's real
re-confirmation return file.

## Neusystem mapping (current — correct after the revert)

| operation | col-4 source (code) | matches legacy |
|-----------|---------------------|----------------|
| UPDATE→OPEN (`finishProcessingOpen`) | `updatedStmId` (immediate) | ✅ |
| CONFIRMED→FINAL (`finishProcessingConfirmed`) | `vorherigeFinalStmId` (nearest FINAL) | ✅ **(reverted 2026-07-23)** |
| ERROR on UPDATE/CONFIRMED-on-open (`resolveErrorReferencedStmId`) | nearest FINAL | ✅ |
| ERROR on FINAL / NEW / DELETE | null | ✅ |
| DECLINED (`declinedInfo.referencedStmId`) | separate source | ❓ unaudited |

`VorherigeFinalStmIdResolver.resolve`: recalc mode walks `vorherige_stm` to the first FIN (mirrors
legacy's gappy stored column); calc mode reads the persisted `vorherige_final_stm_id`. The persisted
column is maintained independently (c_st_meldung.cpp:10995) and should keep getting `vorherigeFinalStmId`.

## Remaining open items

1. **All-open-chain ERROR** — an errored UPDATE on an open meldung whose lineage never had a FINAL.
   Neusystem emits null (walk finds no FIN); legacy may fall back to the immediate open id (`:7878`
   assignment that the no-FINAL walk never overwrites). Untested — no grossfile case.
2. **DECLINED col 4** — comes from `declinedInfo.referencedStmId()`, a code path never audited against
   legacy. Legacy declined rows *do* carry refs (NEW_DECLINED→649517, CONFIRM_DECLINED 649592→649553).
   This is the bigger unknown.

## gf5 status diff (locked as `StatusDiffExpectation(1,0)`)

gf5 649585 errored UPDATE: neusystem col 4 = 649528, legacy = none. The input GJ (29.12.2025) differs
from the DB meldung's GJ (31.12.2025) — a GJ-mismatch edge where legacy didn't resolve a ref. Neusystem's
nearest-final (649528) is arguably more correct; locked down as-is.

## Test state

`GrossfileRecalculationTest` (test-only): `FieldDiffExpectation` all `(0,0)`; `StatusDiffExpectation`
gf1 `(7,0)`, gf2 `(2,0)`, gf5 `(1,0)`, rest `(0,0)`. Note: the ValidationSetting ctor now takes 3 args.

## Relevant files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java`
  — col-4 population: `finishProcessingConfirmed` (~547), `finishProcessingOpen` (~604),
  `resolveErrorReferencedStmId` (~690).
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/VorherigeFinalStmIdResolver.java`
  — `findFinalAncestorId` (the walk).
- legacy `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp` — `WriteMeldung_STATUS`:12187,
  return-writer callers :11887/:11937, confirm file :11965, walks :8825-8886 / :9157-9218.
- `ifas-testing/.../GrossfileRecalculationTest.java` — the lockdown.
- `mathias/automemory/project_gf1-fielddiff-null-vs-zero.md` — background.
