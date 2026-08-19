# Within-tolerance info-log diff should be a WARNING, not two ERRORs

## Context

A gf recalculation info-log diff currently reports this as **two `‼️` ERROR entries**:

```
Info-Log Details:
‼️ Nur im Altsystem-Info-Log (fehlend im Neusystem-Info-Log):
   Altsystem (Zeile-Nr: 3): Ausschuettung_e <0.0000> sollte groesser oder gleich sein Anteile_Tranche_Anzahl_e * StB_PAmO_KESt <791670.0417>
‼️ Nur im Neusystem-Info-Log:
   Neusystem (Zeile-Nr: 1): Ausschuettung_e <0.0000> sollte groesser oder gleich sein Anteile_Tranche_Anzahl_e * StB_PAmO_KESt <791670.0416>
```

The two messages are the **same logical validation**: same code, same first arg (`0.0000`), and a second arg differing by exactly one ULP at scale 4 (`791670.0417` vs `791670.0416`) — i.e. within the existing `DECIMAL_TOLERANCE = 0.0001`. They should surface as a **single `⚠️` WARNING deviation** (an "ABWEICHENDER TREFFER" pair), which is the user's chosen end state.

### Why it currently produces two errors

Matching happens per meldung group in `ValidationDeltaCalculator.compareValidationMsgs` (tiers: exact → allowed-divergent-args → covered → unmatched). Both messages are in the **same** meldung group (grouping is by meldung START line, identical across legacy/new for one meldung; only the per-message attributed line differs — Alt Zeile 3 vs Neu Zeile 1).

- **Exact tier** (`findBestExactMatch` → `isExactMatch`): tolerates the line offset via `hasCompatibleLineScope`, but `compareDecimalArgument` returns `MATCH_WITHIN_TOLERANCE` (not `MATCH`), so `argumentsMatch` is `false` → **no exact match**.
- **Divergent-args tier** (`isAllowedDivergentArgsMatch`): would accept a within-tolerance divergence, **but** it gates on the stricter `hasMatchingLineNumbers` (line 3 ≠ line 1) → **rejected**.
- Falls through → `onlyInLegacy` + `onlyInNew`. Neither code is in the warning allow-lists → both default to **ERROR** (`ValidationDeltaReports.isShowAsWarningIfOnlyIn{Legacy,New}` → `false`).

Root cause: the within-tolerance path is defeated whenever legacy/new attribute the message to different (but compatible-scope) lines, because the divergent-args tier uses strict line equality while the exact tier uses lenient scope.

Relevant files (all in `ifas-domain/ifas-domain-stm/.../validation/delta/`):
- `ValidationMsgMatcher.java` — `compareDecimalArgument` (L408–431, `DECIMAL_TOLERANCE` L401), `isExactMatch`/`argumentsMatch`, `isAllowedDivergentArgsMatch` (L123), `createDivergentArgsMatch` (L169), `hasCompatibleLineScope` (L72), `hasMatchingLineNumbers` (L257), `argumentsMatchAtIndex` (L345)
- `ValidationDeltaCalculator.java` — `compareValidationMsgs` (L299), `findBestExactMatch` (L407)
- `ValidationDeltaReports.java` — `isWarningMatch` (L189: any non-EXACT match ⇒ WARNING), `isErrorMatch` (L185: always `false`)
- `RecalculationProtocolWriter.java` — `writeLogDetails` (L1145) renders the deltas; `‼️`/`⚠️` from `getValidationDeltaSeverityIcon` (L1242)

## Approach

Add a dedicated **within-tolerance match tier** that mirrors the exact tier's lenient line-scope handling but produces a `DIVERGENT_ARGS` match (which is already classified WARNING and rendered as "ABWEICHENDER TREFFER" showing the value difference). This is preferred over simply relaxing `isAllowedDivergentArgsMatch` to `hasCompatibleLineScope`, because the strict line check there deliberately prevents cross-line mis-pairing of the allowed date-divergent codes (`ERR_GJE_UNGLEICH`/`ERR_GJB_UNGLEICH`, see comment at `ValidationMsgMatcher.java:141`). Keeping that tier untouched avoids a behavior change for those codes.

### 1. `ValidationMsgMatcher` — new predicate

Add `public boolean isWithinToleranceMatch(LegacyLogValidationMsg legacy, ValidationMsg newValidation)`:
- codes match (`validationMsgCodesMatch`)
- equal argument count
- every index is `MATCH` or `MATCH_WITHIN_TOLERANCE` (via existing `argumentsMatchAtIndex`)
- at least one index is `MATCH_WITHIN_TOLERANCE` (otherwise it is a plain exact match and belongs to the exact tier)

No change to `createDivergentArgsMatch` — it already emits an `ArgumentDivergence` for any index that is `!= MATCH`, so the `791670.0417`/`791670.0416` difference stays visible.

### 2. `ValidationDeltaCalculator.compareValidationMsgs` — new tier

Insert a tier **between** the exact tier (PRIORITY 1) and the allowed-divergent-args tier (PRIORITY 2): find a new message where `isWithinToleranceMatch(...)` **and** `hasCompatibleLineScope(...)` hold (same line-scope rule the exact tier uses, preferring an equal line number), then `matcher.createDivergentArgsMatch(...)`, add to `matchedLegacyErrors`/`matchedNewErrors`, set `foundMatch = true`.

To avoid duplicating `findBestExactMatch`, generalize it to take a `BiPredicate<LegacyLogValidationMsg, ValidationMsg>` (the per-pair predicate, still combined with `hasCompatibleLineScope` and same-line preference); call it once with `matcher::isExactMatch` and once with `matcher::isWithinToleranceMatch`.

### Net effect

The pair becomes one `DIVERGENT_ARGS` match → `ValidationDeltaReports.getValidationDeltas` emits `ofWarningDiff` → `RecalculationProtocolWriter` prints:

```
⚠️ Abweichung der Kategorie 'Warnung' im Info-Log
   Altsystem (Zeile-Nr: 3): Ausschuettung_e <0.0000> ... <791670.0417>
   Neusystem (Zeile-Nr: 1): Ausschuettung_e <0.0000> ... <791670.0416>
```

Error count drops by 2, warning count rises by 1 (`countLogDiffsWithSeverityError/Warning`).

## Verification

1. **Unit — `ValidationMsgMatcherTest`**: add `isWithinToleranceMatch` cases — within-tolerance-only ⇒ `true`; all-exact ⇒ `false`; over-tolerance (e.g. `0.0002`) ⇒ `false`. Use distinct-digit decimals per testing conventions.
2. **Grouping/line-scope — `ValidationDeltaCalculatorIntegrationTest`** (or a `ValidationDeltaCalculator` unit test): legacy message at Zeile 3, new message at Zeile 1 with a `CsvMessagePosition` whose span includes line 3, second arg differing by one ULP. Assert exactly one `DIVERGENT_ARGS` match (WARNING) and zero `onlyInLegacy`/`onlyInNew`. A within-tolerance pair whose new position is file-level or whose span excludes the legacy line must still **not** match (documents the boundary).
3. **End-to-end**: re-run the gf recalculation that produced the diff (`mvn ... -Pno-proxy`) and confirm the info-log line flips from two `‼️` entries to a single `⚠️` "Abweichung der Kategorie 'Warnung'".
4. `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy` (plus the integration-test module) green.

## Notes / boundaries

- Only helps when the new message carries a `CsvMessagePosition` whose span contains the legacy line (meldung-level messages). File-level (`CsvFilePosition`) within-tolerance diffs still require strict line equality — out of scope, and rare for these per-meldung checks.
- Exact matches keep priority; the allowed date-divergent codes keep their strict line rule — no regression there.
- A one-ULP (0.0001) delta is a rounding artifact (the reason the tolerance exists). It stays **visible** as a warning, not hidden.
