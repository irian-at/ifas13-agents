---
name: project_kontroll-tolerance-legacy
description: Legacy dToleranz for the KONTROLL Kontrollsummen checks, why it is a business rule, and how IFAS13 models it
metadata: 
  node_type: memory
  type: project
  originSessionId: a41653fe-9a5e-4138-bad9-daa0666be37f
  modified: 2026-08-06T13:45:36.016Z
---

Legacy `CheckKontrollsummen()` in `c_st_meldung.cpp` (preise4) applies one **absolute** tolerance `dToleranz` (`:6270-6279`, cutoff at `:103`):
- `10.0` when Stichtag `>= daUpdateFMVO2017` (**2017-02-01**, FMVO 2017), `0.9` before.
- It guards **INFO_KONTROLL_1 + ERR_KONTROLL_2/3/4/5/6/7/8/10** — a *shared* variable, not a KONTROLL_1 speciality. (`_6`/`_8` are legacy versions 1/2 only, so the implemented set is **1, 2, 3, 4, 5, 7, 10**.)
- **Not** guarded by it: INFO_KONTROLL_9 (its `if (dValue3 > dToleranz)` is commented out per **QEKBSD-73393, 2026-04-14** — Protokoll prints `"Toleranz:    keine"`) and the `N<0`/`LSN<0` sign checks.
- Operands are read at **10 NK** via `GetValue0(field, nAnzNK=10)`, which **rounds** (`roundFloat` → `round(v*1e10)/1e10`, `libsyb/tools.cpp:726`) — max error 5e-11.

**It is a fachliche tolerance, not a float epsilon.** Decisive evidence: every guarded check compares a KAG-delivered field (metadata `quelle="S"`) against an OeKB-computed one (`quelle="O"`) — ERR_KONTROLL_7 compares two delivered fields — so it absorbs the KAG's own rounding of a declared Kontrollsumme. Also: only KONTROLL_1 multiplies by a share count (no "amplification" to pad elsewhere), the 0.9→10.0 step is date-gated, it is printed to the business Protokoll (`:6283`), and the Fachabteilung tunes it per check by ticket.

IFAS13 (as of 2026-08-06, all in `at.oekb.ifas.domain.stm.validation`, note: `KontrollsummenComparisons` is **not** in the `.calculated` subpackage):
- `StmValidationProperties.kontrollsummenToleranz` = `10.0` (`ifas.stm.validation.kontrollsummen-toleranz`) — the shared knob for KONTROLL_1 + 2/3/4/5/7/10.
- `StmValidationProperties.infoKontroll9Toleranz` = `0.0001` (`ifas.stm.validation.info-kontroll9-toleranz`) — separate because legacy has *no* tolerance for K9. Don't merge it into the shared knob. **Open question, do not restate as fact either way:** the 0.0001 came from a reported case where delivered `Ausschuettung_e` 273468.0766 vs computed Kontrollsumme 273468.0767 (1 ULP at 4 NK) produced a "misleading" INFO (plan `archive/2026-06-11-kontrollsummen-tolerance-for-isLessThan.md`, which contains **no** legacy comparison). Unknown whether legacy also reports it: if legacy computes the same ...0767 → permanent intentional deviation, keep 0.0001; if legacy computes ...0766 → our Kontrollsumme has a 1-ULP bug and the target is 0. Settle by re-running that Meldung through legacy and reading its INFO_KONTROLL_9 Protokoll line (prints both operands). The case data is **not** in the repo.
- `KontrollsummenComparisons` has **no default tolerance** — every operator takes it explicitly. `DEFAULT_TOLERANCE` was deleted; do not reintroduce it. `LT_ZERO_TOLERANCE = -0.00001` stays (different mechanism).
- `CalculatedSteuerMeldungValidationService` injects the properties and threads `BigDecimal toleranz` into the static validators. Don't pass the properties bean into the `@UtilityClass`.
- Mathias decided **not** to model legacy's pre-2017 `0.9` branch — cutoff is far past ([[project_recalc-historical-fidelity]] does not apply).

History that misled a previous session: `DEFAULT_TOLERANCE` was `1e-8`, then `0.0001` (commit `9ceb7714c`, 2026-07-13, rationale "simplification"); its javadoc claimed legacy's 10.0 "only existed to pad 10-NK-truncation-then-times-count amplification". Both halves are false (it rounds, and only KONTROLL_1 multiplies). A `SCALE_10_TOLERANCE = 10.0` existed from the first implementation but was always dead code.

Known open deviation (deliberately out of scope): `ERR_KONTROLL_N_LT_0`/`LSN_LT_0` — legacy rounds to 5 NK then tests the sign (`:7015-7019`, `:7362-7364`), effective threshold **-0.000005**; ours is `< -0.00001`, i.e. 2× more permissive. Not a precision advantage (BigDecimal exactness would argue for `signum() < 0`, stricter than both). Also: legacy checks 9 fields there, we list 7. Two legacy N<0 sites (`:7559`, `:7597`) skip the rounding entirely — a copy-paste oversight, don't replicate.

Gotcha: legacy .cpp are **ISO-8859-1**; `grep` treats `c_st_meldung.cpp` as binary and silently finds nothing — use `grep -a` (and `iconv -f ISO-8859-1` to read).
