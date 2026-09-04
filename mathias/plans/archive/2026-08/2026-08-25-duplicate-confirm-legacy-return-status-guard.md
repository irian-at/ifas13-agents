# Duplicate confirm delivery: restore the legacy-return-status precondition

## Context

The four recalc-artifact leniency flags on `ValidationSetting` (`vorhandenDiffsAsWarning`,
`meldIdNichtMehrGueltigDiffsAsWarning`, `statusNmDiffsAsWarning`, `updOldmDiffsAsWarning`) encode a
single assumption: *"legacy already applied this delivery, so this error is an artifact of replaying
it against post-import data — legacy itself succeeded here."*

A production delivery breaks that assumption. The Lieferant sent the **same confirm file twice**:

1. Confirm #1 — legacy finalizes the STMs, successful return status.
2. Confirm #2 — legacy rejects it, returns `CONFIRM_DECLINED` (`CDL`).

Replaying confirm #2, the new system raises `ERR_STATUS_NM` — *"Aktueller Status &lt;FINAL&gt;, CONFIRMED
nicht moeglich."* — which `statusNmDiffsAsWarning` suppresses, so the meldung keeps a successful
status and the recalc return file reports success where legacy reported `CONFIRM_DECLINED`. The
leniency, built to suppress replay noise, is suppressing a real outcome.

The assumption is checkable — and the check existed until 2026-08-12.

## The root cause: `FINAL ← CONFIRMED` is ambiguous, and it was assumed not to be

`statusNmDiffsAsWarning` is the one flag with a *narrowing* predicate:
`StatusNmRecalcArtifacts.isRecalcArtifactTransition` (`.../validation/status/StatusNmRecalcArtifacts.java:25-28`)
whitelists exactly two transitions, `FINAL ← CONFIRMED` and `DELETED ← DELETE`. `ValidationSetting`'s
javadoc justifies the whitelist as *"where legacy already successfully applied the operation and
persisted the terminal status"*, and contrasts it with `updOldmDiffsAsWarning`, which gets no
predicate because *"the code's arguments … cannot tell an artifact from a genuine hit"*.

That contrast is wrong. `FINAL ← CONFIRMED` has **two** causes that are indistinguishable at the
code-plus-args level:

| | State the replay sees | Code + args |
|---|---|---|
| Replay artifact | legacy applied *this* confirm | `ERR_STATUS_NM[FINAL, CONFIRMED]` |
| Genuine duplicate | legacy applied the *previous* confirm and declined this one | `ERR_STATUS_NM[FINAL, CONFIRMED]` |

They collapse because finalization is an **in-place update that never touches `guelt_bis`** — legacy
`SaveFinalMeldung` (`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp:10984-10996`) and
the new system's `SteuerMeldungEntity.confirmAsFinalAt`
(`ifas-persistence-stm/.../SteuerMeldungEntity.java:368-381`, "gueltBis is intentionally left alone")
both leave the row active with `status_code = FIN`. So the `guelt_bis is null` lookup still finds it
and `errStatusNm` fires, rather than the `ERR_MELDID_NICHT_MEHR_GUELTIG` that a superseded row would
produce. Legacy's own decline is the mirror image: `c_st_meldung.cpp:8797-8817`, *"Nur eine OPEN
Meldung kann CONFIRMED werden"* → `SetNewStatusIfNotError("CONFIRM_DECLINED")` + `ERR_STATUS_NM`.

Note the design *already* knows a duplicate confirm is genuine — but only within one file:
`InLieferungAcceptedState` records `stmId -> FINAL` after an accepted CONFIRMED
(`.../validation/status/InLieferungAcceptedState.java:100-105`), so a second CONFIRMED in the same
CSV becomes `ERR_STATUS_NM_LIEFERUNG`, which the leniency deliberately never covers. The
cross-delivery duplicate falls straight through that gap.

## Why nothing except the legacy return file can detect it

- **DB state: useless.** As above — byte-identical for both causes.
- **Intra-run state: does not exist.** `persistResult` is `false` for recalc
  (`RecalculationDomainService.java:477`), so every write in `SteuerlicheErmittlungDomainService`
  (`:150`, `:489`, `:537`, `:581`) is skipped; bundle N's finalization is invisible to bundle N+1.
  Chronology in a grossfile replay comes solely from the per-day `*-export.yaml.txt` snapshots. There
  is no run id, no session, no change-tracking set at run scope.
- **Cross-file duplicate detection: out of reach.** `doRecalc` replays exactly one input file per
  bundle (`getOptionalSingleResource(CONFIRM_CSV_FILE)`, `RecalculationDomainService.java:494-508`),
  so the two confirm deliveries are two separate bundles, each with its own `_return.csv`.
  `InLieferungAcceptedState` is constructed fresh per CSV (`SteuerMeldungLieferungService.java:84`).
- **The legacy return file: the one usable signal.** Loaded per bundle, keyed per meldung, already
  plumbed to the decision point — just not read.

## The fix

`SteuerlicheErmittlungRecalcOptions` carries `legacyReturnStatusSupplier`, wired in
`RecalculationDomainService.java:139` as `stm -> getLegacyStmStatus(legacyReturnSteuerMeldungen, stm)`.
It resolves per `LieferungStmKey` (ISIN + jahresdatenmeldung + gjEnde + selbstnachweis —
deliberately **no** STM-ID), so it resolves for a record legacy returned as `CDL`.

`SteuerlicheErmittlungDomainService.java:302` still defines `getLegacyReturnStatus(...)` — with no
callers. Commit `e60519be0` ("refactor: simplify recalculation logic by removing unused legacy status
handling", 2026-08-12) dropped the guard that called it. Reinstate it in `calcFailedStatus` (~`:288`),
wrapping the existing `hasOnlyKnownRecalcIssueErrors` call:

```java
if (options.recalculationMode()) {
    StmStatus legacyReturnStatus = getLegacyReturnStatus(inputStm, options);
    // Only trust the leniency flags where legacy itself succeeded. A failed legacy return means the
    // error is genuine -- e.g. a confirm file delivered twice, where ERR_STATUS_NM[FINAL, CONFIRMED]
    // is indistinguishable from the replay artifact of the same transition.
    if (legacyReturnStatus == null || legacyReturnStatus.isSuccessfulReturnStatus()) {
        if (hasOnlyKnownRecalcIssueErrors(options, validationMsgsForThisStm)) {
            return null; // allow creating return file with OPEN/FINAL/DELETE
        }
    }
}
return calculateDeclinedOrErrorStatus(inputStm, validationMsgsForThisStm, options);
```

`StmStatus.isSuccessfulReturnStatus()` (`ifas-persistence-stm/.../StmStatus.java:53-55`) is
`OPEN || FINAL || DELETED`, false for `ERROR` and all four `*_DECLINED`. The `null` branch keeps
today's behaviour when no `_return.csv` is in the bundle.

Three properties worth stating:

- The guard only ever **narrows** suppression, never widens it, so it cannot mask a regression.
- With it in place, confirm #2 reaches `calculateDeclinedOrErrorStatus` (`:651-729`), where
  `ERR_STATUS_NM` (`declined = true`) on a `CONFIRMED` input maps to `CONFIRM_DECLINED` (`:705-713`)
  — matching legacy, and clearing the `STATUS_STATUS` / `STATUS_MELDUNGS_ID` /
  `STATUS_MELDUNGS_ID_REF` return-file diffs that are consequences of the decline.
- Because the guard sits inside `calcFailedStatus`, both call sites get it for free —
  `handleInputStm` (`:238`) and the post-calculation re-decision in `finishProcessing` (`:405`).

### Gate, not adopt

The legacy status must be used as **permission to suppress**, never as the value to emit:

| | Effect | Verdict |
|---|---|---|
| **Gate** — legacy failed ⇒ skip the leniency, let the new system derive its own status | New system independently reaches `CONFIRM_DECLINED` from its own `ERR_STATUS_NM` | ✅ what to build |
| **Adopt** — legacy said `CDL` ⇒ emit `CDL` | Copies the answer; every `STATUS_*` diff becomes undetectable by construction | ❌ |

The gate is sufficient here precisely because the new system *already* computes the correct outcome
on its own — `ERR_STATUS_NM` carries `declined = true`, so the `CONFIRMED` input lands on
`CONFIRM_DECLINED` unaided. Legacy's status is only needed to decide whether to *stop suppressing*.

Honest caveat: the gate does not guarantee a match. If legacy failed for a different reason than the
new system's error, the new system will decline with its own Anmerkung and that stays a reported
diff — which is correct behaviour, not a regression.

### Keeping recalc and production separate

The separation is already structural, and doubly so:

1. The whole leniency block is inside `if (options.recalculationMode())`
   (`SteuerlicheErmittlungDomainService.java:287`).
2. `legacyReturnStatusSupplier` is only ever populated in `RecalculationDomainService.doRecalc`
   (`:478`). Production passes `SteuerlicheErmittlungRecalcOptions.DEFAULT`
   (`CalculationDomainService.java:105`), whose supplier is `null` and whose `recalculationMode` is
   `false`. There is no other construction site.

So no legacy status can reach a production calculation today. To make that a maintained invariant
rather than a coincidence of two call sites, add a compact constructor to
`SteuerlicheErmittlungRecalcOptions` rejecting `legacyReturnStatusSupplier != null` when
`!recalculationMode` — a one-line guard that fails loudly if someone later wires the supplier into
the production path. Same reasoning for the four `ignore*Errors` flags, which are equally meaningless
outside recalculation mode.

### Files to change

| File | Change |
|---|---|
| `ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java` | Reinstate the precondition in `calcFailedStatus` (~`:288`); `getLegacyReturnStatus` (`:302`) becomes live again |
| `ifas-domain/ifas-domain-stm/.../validation/status/StatusNmRecalcArtifacts.java` | Javadoc only: record that `FINAL ← CONFIRMED` is ambiguous and that the whitelist is safe *only* under the legacy-return-status guard |
| `ifas-domain/ifas-domain-stm/.../validation/ValidationSetting.java` | Javadoc `:41-42` already claims "and the legacy return status was successful"; it becomes true again. Fix the `statusNmDiffsAsWarning` paragraph (`:17-23`), which currently asserts the whitelisted transitions are unambiguous |
| `ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungRecalcOptions.java` | Compact constructor asserting the recalc-only fields (`ignore*Errors`, `legacyReturnStatusSupplier`) are unset when `!recalculationMode` |

Deliberately **not** changed: the four `ignore*Errors` predicates. Narrowing them further is
guesswork — the ambiguity is in the domain state, not in the message arguments. The return status
carries the information the codes lack.

## Scope note: production is unaffected

The flags are gated on `options.recalculationMode()`, and production passes
`SteuerlicheErmittlungRecalcOptions.DEFAULT` (`recalculationMode=false`, `persistResult=true`) from
`CalculationDomainService.java:105`. A customer confirm delivery arrives as a normal STM-Lieferformat
CSV with `STATUS;CONFIRMED`, so the production path runs `errStatusNm` → `CONFIRM_DECLINED`,
identical to legacy. The wrong successful status can therefore only originate in a recalc /
Parallelbetrieb run — which is also where `RECALC_ARTIFACT_DIFFS_AS_WARNING` is switched on
wholesale, by `RecalculationRestController.java:60` and the single UI checkbox.

## Note on the delta report

The report half needs no change. `isShowAsWarningIfOnlyInNew`
(`ValidationDeltaReports.java:186-198`) only downgrades deviations that are **only in the new
system**; for confirm #2 legacy logged its own `ERR_STATUS_NM`, so the entry matches (or is handled
by `StatusNmCoveredByStatusNmLieferung`) and the downgrade never fires. Only the status-derivation
half was broken — consistent with the known, accepted inconsistency where `error#recalc.log` keeps
reporting an error while the return file says success.

## Verification

1. **Unit level** — extend `RecalculationDomainServiceTest`
   (`ifas-domain-stm/src/test/.../recalc/`), which already builds `RECALC_ARTIFACT_DIFFS_AS_WARNING`:
   with all flags on and `ERR_STATUS_NM[FINAL, CONFIRMED]` as the only error, assert the status is
   successful when the supplied legacy status is `FINAL`, and `CONFIRM_DECLINED` when it is
   `CONFIRM_DECLINED`. A `null` supplier must keep today's lenient behaviour.
2. **Regression baselines** — `GrossfileRecalculationTest.java:86` passes `ValidationSetting.DEFAULT`
   (all flags off → `hasOnlyKnownRecalcIssueErrors` short-circuits on `known.isEmpty()`), so its 8
   dataset baselines must be unchanged. In `JiraIssueRecalculationTest` only the `IFAS13-204` row
   sets a flag (`vorhandenDiffsAsWarning=true`, 0 errors / 1 warning); confirm it still passes.
   `ValidationDeltaReportsStatusNmTest` covers the report half and should be untouched.
3. **The actual scenario** — build a two-bundle input from the production deliveries (each with its
   own `_return.csv`) and add it as a `JiraIssueRecalculationTest` row, or drive it through
   `QuickRecalculationTest`. Expect delivery #1 → `FINAL`, delivery #2 → `CONFIRM_DECLINED` with the
   legacy Anmerkung, and no `STATUS_*` diffs. Use `bundleOf(Resource)` for a single-bundle zip, never
   `bundlesOf(...).getFirst()`.
4. **Build** — `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am`, then the recalc
   integration tests.

## Open points to settle before coding

- **Which successful status did the run actually emit?** `handleInputStm:255` maps a `CONFIRMED`
  input to a tentative `FINAL`, and `finishProcessingFinal` (`:507-604`) carries that through — so
  the expected wrong result is `FINAL`, not `OPEN`. If the artifacts really show `OPEN`, a second
  mechanism is in play (e.g. the meldung was declined for a *different* reason and re-entered the
  OPEN path) and is worth pinning down from `*#recalc.csv` before implementing.
- **No `_return.csv` in the bundle** → `legacyReturnStatusSupplier` yields `null` and the leniency
  applies unconditionally, unchanged from today. No second signal exists in that case. Worth
  deciding whether enabling the leniency flags should *require* a legacy return file.
