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
   `SteuerlicheErmittlungDomainService.hasOnlyKnownRecalcIssueErrors` uses to suppress `*_DECLINED`
   when *every* error on the STM is a known artifact **and** the legacy return status was successful.
   Gated on `recalculationMode()` — never production.

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

Related: [[project_gf1-fielddiff-null-vs-zero]] (the residual field diff this fix exposed once the
meldung was no longer declined), [[project_recalc-fixture-data-recovery]] (why replay fixtures contain
the delivery's own product in the first place), [[project_lieferung-codes-are-clones]].
