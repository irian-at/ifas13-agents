# Sync Kontrollsummen tolerance with the Altsystem

## Context

`INFO_KONTROLL_1` was just made legacy-faithful: it now honours the Altsystem's absolute
tolerance of `10.0` via `ifas.stm.validation.info-kontroll1-toleranz`. Investigating the naming
of that property revealed that legacy does **not** treat this as a KONTROLL_1 speciality — a
single local `dToleranz` (`c_st_meldung.cpp:6270-6279`, `10.0` for Stichtag ≥ 2017-02-01 per
FMVO 2017, `0.9` before) guards **seven** implemented checks. IFAS13 currently applies it to one
and runs the other six at `KontrollsummenComparisons.DEFAULT_TOLERANCE = 0.0001` — five orders of
magnitude tighter, on **ERROR-level checks that fail a Meldung** (`StmStatus.ERROR`).

The rationale recorded in `DEFAULT_TOLERANCE`'s javadoc — that legacy's `10.0` "only existed to
pad legacy's 10-NK-truncation-then-times-count amplification" — does not survive inspection:

- `GetValue0(field, nAnzNK=10)` **rounds** (`roundFloat` → `round(v*1e10)/1e10`, `libsyb/tools.cpp:726`),
  max error 5e-11 per operand — it does not truncate.
- Only `INFO_KONTROLL_1` multiplies by a share count (`dAnzAnteile`, `c_st_meldung.cpp:6310`).
  ERR_KONTROLL_2/3/4/5/7/10 compare two direct field reads — no amplification exists there.
- The `0.9 → 10.0` step is **date-gated on FMVO 2017**; a rounding pad would not be.
- Legacy prints it to the business Protokoll as `"Toleranz: %10.2lf"` (`:6283`), and the
  Fachabteilung has tuned it per-check by ticket (QEKBSD-73393 removed it for INFO_KONTROLL_9).

The decisive fact: in every one of these checks at least one operand is **KAG-delivered**
(`quelle: "S"`) and compared against an **OeKB-computed** value (`quelle: "O"`) — ERR_KONTROLL_7
compares two delivered values. `dToleranz` is a business tolerance for the KAG's own rounding of a
declared checksum, not a float epsilon. A KAG reporting `Aufwand_Gesamtbetrag_e` to whole euros
produces diffs legacy accepts by design and we currently reject.

Historically no version of this code ever applied legacy's tolerance: `SCALE_10_TOLERANCE = 10.0`
existed from `6fc0526ae` but was dead code; `9ceb7714c` (2026-07-13) deleted it and collapsed
everything to `0.0001`, stated rationale "simplification".

**Outcome:** implement `dToleranz` as the shared business rule it is, for all seven checks.

## Decisions taken

| Question | Decision |
|---|---|
| Adopt `10.0` for ERR_KONTROLL_2/3/4/5/7/10 | Yes — one shared knob, as in legacy |
| Property naming | Back to a single `kontrollsummenToleranz`; the check-specific name was only right while one check used it |
| INFO_KONTROLL_9 | Own knob `infoKontroll9Toleranz`, default `0.0001`, documented as a deliberate deviation with target `0` |
| N&lt;0 / LSN&lt;0 family | Out of scope; documented as a known deviation (see below) |

`ERR_KONTROLL_6` and `_8` are legacy versions 1/2 only and are not implemented — the set is
**1, 2, 3, 4, 5, 7, 10**. Existing comments saying "2..8/10" overstate it and must be corrected.

## Changes

### 1. `ifas-domain-stm/.../validation/StmValidationProperties.java`

- Rename `infoKontroll1Toleranz` → `kontrollsummenToleranz` (IDE rename refactoring), default
  stays `new BigDecimal("10.0")`. Key becomes `ifas.stm.validation.kontrollsummen-toleranz`.
- Rewrite its javadoc: legacy's single `dToleranz` (FMVO 2017, 10.0 from 2017-02-01; the 0.9
  branch is not modelled), governing INFO_KONTROLL_1 + ERR_KONTROLL_2/3/4/5/7/10. State the
  *reason* — one side KAG-delivered (`quelle: S`), one side OeKB-computed (`quelle: O`).
  Delete the "here those keep DEFAULT_TOLERANCE, hence the check-specific name" sentence.
- Add `private BigDecimal infoKontroll9Toleranz = new BigDecimal("0.0001");` with javadoc:
  legacy has **no** tolerance here since QEKBSD-73393 (2026-04-14, Protokoll prints
  `"Toleranz:    keine"`); our `0.0001` masks a known ~1e-4 drift in our computation of
  `Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB` (`Ausschuettung_e` is delivered,
  so the gap is entirely ours). Target value is `0` once that drift is fixed.

### 2. `ifas-domain-stm/.../validation/KontrollsummenComparisons.java`

Make tolerance explicit on every operator and **delete `DEFAULT_TOLERANCE` together with the
four no-arg overloads** — after this change nothing uses it, and the silent default is exactly
how the wrong band reached six ERROR checks unnoticed.

- `isEqualBigDecimals(bd1, bd2, tolerance)` — widen the existing private 3-arg method to public
- `isLessThanOrEqualBigDecimals(bd1, bd2, tolerance)`
- `isLessThanBigDecimals(bd1, bd2, tolerance)`
- `isGreaterThanOrEqualBigDecimals(bd1, bd2, tolerance)` — already exists
- `isLessThanZeroByTolerance(value)` and `LT_ZERO_TOLERANCE` — unchanged (see Out of scope)

Net: −1 constant, −4 methods, no new abstraction. The discredited javadoc dies with the constant.

These helper semantics already mirror legacy exactly, so no logic changes beyond threading:
legacy's `if (one-sided) if (fabs(diff) > tol)` for _2/_5/_7 matches
`isGreaterThanOrEqual`/`isLessThanOrEqual`; the unguarded `if (dValue3 > dToleranz)` for
_3/_4/_10 matches `isEqual` (symmetric, so the guard is immaterial).

### 3. `ifas-domain-stm/.../validation/calculated/CalculatedSteuerMeldungValidators.java`

Add a `BigDecimal toleranz` parameter to `errKontroll2`, `errKontroll3`, `errKontroll4`,
`errKontroll5`, `errKontroll7`, `errKontroll10`, `infoKontroll9`. `infoKontroll1` already has it.
`errKontrollNLt0` / `errKontrollLsnLt0` / `infoAuslqstJa` / `infoSubstanzAltem` are untouched.

Pass `BigDecimal`, not the properties bean — these are pure functions in a `@UtilityClass`;
dragging a Spring `@ConfigurationProperties` bean into the domain would force every unit test to
build one, and `infoKontroll1` already established this shape.

### 4. `ifas-domain-stm/.../validation/calculated/CalculatedSteuerMeldungValidationService.java`

Read both values into locals at the top of `validate(SteuerMeldung)` and thread them into the
seven / one call sites respectively.

### 5. `ifas-main-application/src/main/resources/application.properties`

Under the existing `# ========== STM Validation ==========` section: rename the key, add
`ifas.stm.validation.info-kontroll9-toleranz=0.0001`, and rewrite the comment block. The current
line *"the Altsystem applies the same dToleranz to ERR_KONTROLL_2..8/10; those checks are not
governed by this property"* becomes false and must be replaced by the list of governed checks
plus the KONTROLL_9 exception.

**Hazard:** `ifas-testing/ifas-integration-tests/src/test/resources/application.properties` has no
`ifas.stm.validation.*` entries, so tests exercise the **Java field defaults**, not this file.
Keep the two in sync — a properties-only edit would pass CI and ship wrong.

## Tests

**`KontrollsummenComparisonsTest`** — every 2-arg call stops compiling, which is the point: each
test must now name the band it pins. Three existing assertions flip and need new fixtures:

| Test | Under 10.0 |
|---|---|
| `givenDiffAboveLessThanToleranceWithLeftLarger_whenIsLessThanOrEqual…_thenFalse` (…0768/…0766) | flips → rewrite to a diff > 10 |
| `givenDiffJustAboveToleranceBoundary_whenIsEqualBigDecimals_thenFalse` (0/0.00011) | flips → rewrite to (0 / 10.0001) |
| `givenSmallerJustAboveTolerance_whenIsGreaterThanOrEqual…_thenFalse` (0/0.00011) | flips → rewrite to (0 / 10.0001) |

The `isLessThan*` tests at `0.0001` stay valid — retarget them as the KONTROLL_9 band.

Add: boundary triple per operator at `10.0` (diff `10.0` inside, `10.0001` outside, one-sided
asymmetry passes), using distinct digits per the testing convention.

**`CalculatedSteuerMeldungValidatorsTest`** — mechanical parameter threading only; no existing
fixture flips (smallest "expect a message" diff is 50, smallest "expect none" is 0). Add per
check `errKontroll2/3/4/5/7/10`: diff `9.9999` → no message, diff `10.0001` → message. Add an
`InfoKontroll9Tests` case with diff `5.0` → **message fires** — this pins _9 off the shared band
and fails loudly if someone later merges the two knobs.

**`CalculatedSteuerMeldungValidationServiceTest`** (integration) — already threads
`new StmValidationProperties()`; consider switching to `private @Inject
CalculatedSteuerMeldungValidationService` and dropping the `@BeforeEach` so the real bean wiring
is exercised.

## Verification

1. `mvn -Pno-proxy test -pl ifas-domain/ifas-domain-stm -Dtest='KontrollsummenComparisonsTest,CalculatedSteuerMeldungValidatorsTest'`
2. `mvn -Pno-proxy test -pl ifas-testing/ifas-integration-tests -Dtest='CalculatedSteuerMeldungValidationServiceTest'`
3. **Grossfile gate** — the real check. `GrossfileRecalculationTest` writes
   `target/grossfile-recalc/*/error#diff-deviations.txt` and `info#…`. Archive them on current
   HEAD, apply the change, re-run, diff. Reading the movement:
   - This change is a pure **widening**, so it can only turn "we fire" into "we don't fire".
   - `onlyInNewError ↓` on a KONTROLL code → **improvement** (a false error we invented is gone).
   - `onlyInLegacy ↑` / `exactMatch ↓` on a KONTROLL code → **regression**; investigate before
     touching any baseline.
   - No movement is the expected outcome: no fixture or grossfile case currently has a KONTROLL
     diff in the `(0.0001, 10.0]` band (observed diffs are 0.0000, 60, 85, 274, 449, 625, 450000).
4. Because the 8 baselines cannot prove production impact, additionally grep the legacy Protokoll
   files in the recalc corpus for the `(Diff. abs.: %20.4lf, Toleranz: %10.4lf)` lines and count
   rows landing in `(0.0001, 10.0]`. That bounds the real blast radius far better than the gate.

## Out of scope — record as known deviations, do not silently keep

- **ERR_KONTROLL_N_LT_0 / LSN_LT_0**: legacy rounds to 5 NK then tests `< 0`
  (`c_st_meldung.cpp:7015-7019`, `7362-7364`), effective threshold `-0.000005`; ours is
  `< -0.00001`, i.e. **2× more permissive** — legacy raises an ERROR in the band between and we
  stay silent. This is a tolerance difference, not a precision advantage; the BigDecimal-exactness
  argument would give `signum() < 0`, stricter than both. Band is 5e-6 wide, so impact is
  negligible. Note it in the `errKontrollNLt0` javadoc; fix separately if ever wanted.
  Two of legacy's N&lt;0 fields (`AIF_Gewinnvortrag_Einkuenfte_AIF_inklEA` `:7559`,
  `Substanzverluste_inklEA` `:7597`) skip the rounding step entirely — a legacy copy-paste
  oversight that should **not** be replicated.
- **`errKontrollNLt0` field coverage**: legacy checks 9 fields, we list 7. Missing for v4:
  `ImmoInvF_Gewinnvortrag_ImmoInvF_Bewirtschaftungsgewinne_inklEA` (`:6952`) and
  `ImmoInvF_Gewinnvortrag_ImmoInvF_WPundLiquiditaetsgewinne_inklEA` (`:7484`), both renamed to
  `ImmoInvF_Gewinnvortrag_inklEA` in v5 — we only carry the v5 name. Own ticket.
- **`infoAuslqstJa` / `infoSubstanzAltem`** use plain `compareTo` with no tolerance at all.
  Not `dToleranz`-guarded in legacy either; left alone.
