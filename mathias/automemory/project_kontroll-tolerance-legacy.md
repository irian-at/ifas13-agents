---
name: project_kontroll-tolerance-legacy
description: Legacy tolerance for the KONTROLL Kontrollsummen checks (INFO_KONTROLL_1 etc.) and where it lives
metadata: 
  node_type: memory
  type: project
  originSessionId: a41653fe-9a5e-4138-bad9-daa0666be37f
---

Legacy `CheckKontrollsummen()` in `c_st_meldung.cpp` (preise4) applies an **absolute** tolerance `dToleranz`:
- `10.0` when Stichtag `daDatum >= daUpdateFMVO2017` (= **2017-02-01**, "Neue Toleranz von 10 ab Februar 2017", FMVO 2017)
- `0.9` before that
(`c_st_meldung.cpp:6270-6279`; cutoff at `:103`). Separate `dToleranzKleiner0 = -0.00001` / `dToleranzGroesser0 = 0.00001` are only for the `< 0` KONTROLL checks.

`INFO_KONTROLL_1` (`:6293-6349`): SOLL `Ausschuettung_e >= Anteile_Tranche_Anzahl_e * StB_PAmO_KESt`. Operands read at **10 decimal places** (`GetValue0(field, nAnzNK)`, `nAnzNK = 10` — not 4). Fires the INFO only when BOTH `dValue < dValue2` AND `fabs(dValue-dValue2) > dToleranz`. It's `WriteStmInfo` (INFO, "sollte"), the ERR_KONTROLL_1 variant above it is commented out.

New system: `CalculatedSteuerMeldungValidators.infoKontroll1` uses `KontrollsummenComparisons.isGreaterThanOrEqualBigDecimals` (equality band `DEFAULT_TOLERANCE = 1e-8`) with a `// todo - add tolerance after 4.NK`. So it currently flags any shortfall > 1e-8 vs legacy's > 10.0. To match legacy use the already-defined `SCALE_10_TOLERANCE = 10.0` (only for Stichtag ≥ 2017-02-01 — see [[project_recalc-historical-fidelity]]). The todo's "4.NK" is misleading: legacy uses 10 NK + an absolute 10.0 tolerance, no 4-decimal rounding.

Gotcha: legacy .cpp are **ISO-8859-1**; `grep` treats `c_st_meldung.cpp` as binary and silently finds nothing — use `grep -a` (and `iconv -f ISO-8859-1` to read).
