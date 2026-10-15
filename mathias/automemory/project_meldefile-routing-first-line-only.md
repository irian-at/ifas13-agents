---
name: project_meldefile-routing-first-line-only
description: "Decision 2026-10-14 - Meldefile type routing inspects only the first non-blank line (START / date / ISIN); the 100-line scan of IFAS13-244 was reverted; broken first lines go to the bad-input job, STM validation stays untouched"
metadata:
  node_type: memory
  type: project
  originSessionId: 780e0c7a-9363-4951-a31b-d4060d35fa00
  modified: 2026-10-14T09:40:04.557Z
---

`IfasCsvMeldeFileTypes.determineIfasMeldungCsvOrTxtFileType` decides the Meldefile type from the
FIRST non-blank line only: `START` → STM, date → Preis, ISIN → Ausschüttung. Commit `7acb987a7`
(IFAS13-244, scan up to 100 lines, accept STATUS/END) was reverted on 2026-10-14.

**Why:** Mathias decided that a Steuermeldung whose first line is formally broken (`SSTART`, `STAT`,
`STATUS` as line 1) must not be routed into the STM pipeline at all. It stays `UNSPECIFIED_CSV_FILE`;
a colleague extends the bad-input job so that such files get an error.log. An earlier attempt
(new `ERR_ZEILE1_SATZ` in `FATAL_SUBMISSION_LEVEL_CODES`, rejecting the whole file inside the STM
pipeline) was built, verified and then discarded the same day — do not revive it.

**How to apply:** do not widen the detection window or add Satzart markers again. The known
recalc side effect of IFAS13-244 (an unrecognised Melde-CSV lets `RecalculationDomainService` fall
through to the bundle's `_confirm.csv`) is accepted until the bad-input job covers it. STM
structural validation (`ERR_OHNE_START`, `ERR_SATZART` per orphan record) is unchanged and matches
legacy. See [[project_recalc-historical-fidelity]].
