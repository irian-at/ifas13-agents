# Review: removing `_LIEFERUNG` codes from `ValidationMsgCodePattern`

## Context

Commit `c5f04dbce` removed `ERR_STATUS_NM_LIEFERUNG` and `ERR_UPD_OLDM_LIEFERUNG`
from `ValidationMsgCodePattern` (the enum used to parse **legacy** log lines back
into codes). The reasoning — these codes are produced only by the neusystem and
never appear in legacy log files — is correct. But the *same commit* also rewrote
the neusystem message **text** of both codes, and that is where something was
missed.

## Part A — the pattern removal itself is safe ✅

Verified, no action needed:

- **Legacy-log parsing** (`LegacyLogPatternMatcher`) uses anchored
  `matcher.matches()`. The removed patterns had *unique* templates, so each was a
  singleton equivalence group (`ValidationMsgCodePattern.equivalentCodeNames()`);
  they never contributed to matching any other code. Removing them cannot change
  which pattern a legacy line resolves to.
- **Delta code-matching** (`ValidationMsgMatcher.validationMsgCodesMatch`) relies
  on `equivalentCodeNames()` plus the two covered-by rules
  (`StatusNmCoveredByStatusNmLieferung`, `UpdOldmCoveredByUpdOldmLieferung`).
  Those rules key off `ValidationMsgCodePattern.ERR_STATUS_NM` / `.ERR_UPD_OLDM`
  (still present) and `ValidationMsgCode.*_LIEFERUNG` (still present). None
  reference the removed patterns.
- **No reverse lookup**: there is no `ValidationMsgCodePattern.valueOf(code.name())`
  anywhere, so a code without a pattern raises no `IllegalArgumentException`.
  `toErrorCode()` only goes pattern→code, unaffected.
- No fixture or legacy C++ source contains "in dieser Lieferung"; no
  code↔pattern completeness test exists.

## Part B — the bug that was missed 🐞

`c5f04dbce` changed the **placeholder counts** of the two message texts in
`ValidationMsgCode`, but the factory methods in `SteuerMeldungStatusValidators`
still pass the **old argument counts**. `ValidationMsgCode.formatMessage` uses
`MessageFormat`, which silently drops extra args and renders missing ones as a
literal `{n}`.

1. **`ERR_UPD_OLDM_LIEFERUNG` — real, user-visible defect.**
   New text: `"Zur Melde-ID <{0}> wurde bereits ein UPDATE geliefert. Aktuelle Melde-ID: <{1}>."`
   (2 placeholders). Factory `errUpdOldmLieferung` (line ~238) passes **1** arg
   (`stmId`). `MessageFormat` renders `{1}` literally, so every within-lieferung
   duplicate-UPDATE message reads:
   `... Aktuelle Melde-ID: <{1}>.`

2. **`ERR_STATUS_NM_LIEFERUNG` — dead argument / inconsistency.**
   New text: `"Aktueller Status <{0}>, {1} nicht moeglich."` (2 placeholders).
   Factory `errStatusNmLieferung` (line ~206) still passes **3** args; the 3rd
   (`stmId`) is silently ignored. Rendered text is fine, but the
   `ValidationMsg.arguments` array carries a stale 3rd element (length 3 vs the
   legacy `ERR_STATUS_NM`'s length 2 — the two are supposed to be equivalent).

**Why the unit tests don't catch it:** `SteuerMeldungStatusValidatorsTest`
asserts `msg.getFormattedMessage()` against
`ValidationMsgCode.<CODE>.formatMessage(<same args>)` — i.e. it compares the
value against itself with identical arguments. Any placeholder/arg mismatch is
mirrored on both sides, so the assertions are tautological here (lines ~761,
~779, ~795, ~852).

## Decided approach

Goal (per discussion): each `_LIEFERUNG` code should be a true clone of its
twin — identical text **and** identical argument shape. Text already matches for
all four pairs; only the two parameterized factories need their argument lists
brought in line.

### `ERR_STATUS_NM_LIEFERUNG`
In `SteuerMeldungStatusValidators.errStatusNmLieferung` (~line 220), drop the
now-unused 3rd argument so the `ValidationMsg.of(...)` call passes exactly
`(inLieferungCurrentStatus, deliveredStatus)` — 2 args, matching the
2-placeholder text and `ERR_STATUS_NM`'s shape. The method signature
(`..., @Nullable StmStatus inLieferungCurrentStatus`) is unchanged.

### `ERR_UPD_OLDM_LIEFERUNG`
In `errUpdOldmLieferung` (~line 246), pass a 2nd argument to match the
2-placeholder text. The real in-lieferung successor stmId does not exist at
validation time (assigned later by persistence — see `InLieferungAcceptedState`
lines 32-33), so **pass `null`** for now; `formatMessage` renders `null` as
`leer`, giving `"... Aktuelle Melde-ID: <leer>."` instead of the current broken
literal `<{1}>`. Call shape: `ValidationMsg.of(pos, code, ERROR, stmId, null)`.

Add a TODO on that call explaining: the in-lieferung UPDATE successor Melde-ID is
only assigned during persistence, so a real "Aktuelle Melde-ID" cannot be shown
yet — we may need to change the persistence sequence for all Steuermeldungen
(assign the successor stmId earlier) to populate this properly.

### Tests — `SteuerMeldungStatusValidatorsTest`
The existing assertions are self-referential (`getFormattedMessage()` compared to
`ValidationMsgCode.<CODE>.formatMessage(<same args>)`), which is why the mismatch
went unnoticed. Update and de-tautologize:
- `ERR_STATUS_NM_LIEFERUNG` assertions (~lines 761-763, 779-781, 795-797): assert
  against a **literal** expected string, e.g.
  `"Aktueller Status <FINAL>, CONFIRMED nicht moeglich."`.
- `ERR_UPD_OLDM_LIEFERUNG` assertion (~lines 852-854): assert against the literal
  `"Zur Melde-ID <649538> wurde bereits ein UPDATE geliefert. Aktuelle Melde-ID: <leer>."`.

The factory *call* signatures in the tests do not change.

## Verification

- `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy -Dtest=SteuerMeldungStatusValidatorsTest,StatusNmCoveredByStatusNmLieferungTest,UpdOldmCoveredByUpdOldmLieferungTest`
- Confirm no literal `<{1}>` in a within-lieferung duplicate-UPDATE message
  (now renders `<leer>`), and that `ERR_STATUS_NM_LIEFERUNG` carries 2 args.
