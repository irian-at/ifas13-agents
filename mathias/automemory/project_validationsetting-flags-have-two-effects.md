---
name: project_validationsetting-flags-have-two-effects
description: "Each ValidationSetting recalc-artifact flag drives both delta-report severity AND the meldung's result status; wiring only the report half leaves a half-flag."
metadata: 
  node_type: memory
  type: project
  originSessionId: 90ae94fb-17a3-4339-847e-6f27c2d73525
  modified: 2026-08-06T07:52:56.440Z
---

Every recalc-artifact leniency flag on `ValidationSetting` (`vorhandenDiffsAsWarning`,
`meldIdNichtMehrGueltigDiffsAsWarning`, `statusNmDiffsAsWarning`, `updOldmDiffsAsWarning`) has **two**
effects, not one:

1. **Delta-report severity** — `ValidationDeltaReports.isShowAsWarningIfOnlyInNew` downgrades the
   only-in-new deviation from `FEHLER` to `WARNUNG`.
2. **Result status** — `RecalculationDomainService` copies each flag into the matching
   `SteuerlicheErmittlungRecalcOptions.ignore*Errors`, which
   `SteuerlicheErmittlungDomainService.mayIgnoreRecalcIssueErrors` uses to suppress `*_DECLINED`
   when *every* error on the STM is a known artifact **and** the legacy return status
   (`legacyReturnStatusSupplier`) is successful or absent. Gated on `recalculationMode()` — never
   production, and the record's compact constructor now rejects recalc-only options in production mode.

**Why:** the two halves live in different packages (`validation.delta` vs `ermittlung`) and neither
javadoc used to mention the other, so adding a flag and wiring only the report half looks complete but
leaves the return-file `STATUS_*` diffs (`STATUS_STATUS`, `STATUS_MELDUNGS_ID`,
`STATUS_MELDUNGS_ID_REF`) in place — they are consequences of the decline, not of the log entry. This
cost a wrong "out of scope" call when `updOldmDiffsAsWarning` was added on 2026-08-05.

**How to apply:** adding a fifth flag means touching both halves plus
`ValidationSetting.ofRecalcArtifactDiffsAsWarning` (the single-UI-checkbox expander) and the
`recalcArtifactDiffsAsWarning()` aggregate. The `ignore*Errors` predicates must match only the **plain**
code, never the `_LIEFERUNG` twin — a within-delivery duplicate is genuine and must keep declining.
Note the flags do *not* touch the new system's own `error#recalc.log` / `statistics#recalc.log`, which
keep reporting the error while the return file says `OPEN`; that inconsistency is accepted (wontfix,
2026-08-06).

**The legacy-return-status half is load-bearing, not belt-and-braces.** `ERR_STATUS_NM[FINAL,
CONFIRMED]` — the transition `StatusNmRecalcArtifacts` whitelists — is raised *both* by a replay
artifact and by a genuinely duplicated confirm delivery, because finalization updates the row in
place and leaves `guelt_bis` null (`SteuerMeldungEntity.confirmAsFinalAt`, legacy
`SaveFinalMeldung`). The DB snapshot is identical for both, and nothing run-scoped can substitute:
`persistResult=false` in recalc, and `doRecalc` replays one input file per bundle, so
`InLieferungAcceptedState` (which catches the *within-file* duplicate as `ERR_STATUS_NM_LIEFERUNG`)
never spans deliveries. The legacy return status is the only available discriminator. Use it as a
**gate** on the suppression, never adopt it as the emitted status — the new system reaches
`CONFIRM_DECLINED` on its own once the suppression is skipped.

Related: [[project_gf1-fielddiff-null-vs-zero]] (the residual field diff this fix exposed once the
meldung was no longer declined), [[project_recalc-fixture-data-recovery]] (why replay fixtures contain
the delivery's own product in the first place), [[project_lieferung-codes-are-clones]].
