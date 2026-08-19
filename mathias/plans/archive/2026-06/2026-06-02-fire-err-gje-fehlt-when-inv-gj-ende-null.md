# Plan: Fire `ERR_GJE_FEHLT` when `inv.gj_ende` is null

## Problem

`SteuerMeldungDomainValidationService.validateGeschaeftsjahr` (line ~406) calls
`geschaeftsjahreDomainService.getOrCalcGeschaeftsjahre(stichtag, inv)`. The
calculator immediately throws `IllegalStateException` when `inv.getGjEnde()` is
null (`Geschaeftsjahre.getInvGjEnde`, line 182). The catch block at lines
427-430 of the validation service swallows the exception and returns early, so
`errGjeFehlt` is never invoked.

Result: STMs for funds with a missing `INV.gj_ende` produce no
`ERR_GJE_FEHLT`, even though that is exactly the situation the error code is
meant to flag.

## CPP reference behaviour

- SQL in `cSt_Meldung::ReadDetails4Isin` (`c_st_meldung.cpp:9431`) maps
  `isnull(gj_ende, '-')`, so a null INV.gj_ende arrives as `"-"`.
- `cAGeschaeftsjahr_col::Calc` (`c_geschaeftsjahr.cpp:2560`):
  - If `daDatum < daFonds_beginn` → returns 0 silently (no calc, no error).
  - If **no existing GJ rows in DB** and INV.gj_ende is `"-"` →
    `SetOhneJahr("-")` returns -1 → `Calc` returns -1.
  - If **at least one existing GJ row** exists, the code computes the
    Zeitreihe from those rows; the inner `SetOhneJahr` calls at lines 2893 /
    2992 ignore their -1 return — `Calc` can still succeed.
- `cSt_Meldung::CheckIsin` (`c_st_meldung.cpp:5561-5575`) emits
  `ERR_GJE_FEHLT` iff `ReadDetails4Isin` returned -1 **and**
  `strIsinGj_ende.IsNull()`.

Summary: `ERR_GJE_FEHLT` fires when INV.gj_ende is null **and** the calc
cannot produce a Zeitreihe from existing rows. When existing rows are usable,
CPP still computes the Zeitreihe and continues with the normal GJ-table
validations.

## Java gap

1. `getInvGjEnde` throws on null *before* the calculator looks at existing GJ
   rows. CPP would have computed from the existing rows in that case.
2. When the calc legitimately cannot proceed because of a null gj_ende, the
   explicit `ERR_GJE_FEHLT` is not emitted.

## Proposed change

### Step 1 — make `getInvGjEnde` nullable

File: `ifas-domain/ifas-domain-stm/.../geschaeftsjahr/Geschaeftsjahre.java`

- Change signature of `getInvGjEnde(Inv inv)` to return `@Nullable DayMonth`.
- Remove the `throw new IllegalStateException(...)` branch; return `null`
  instead when `inv.getGjEnde()` is null.

### Step 2 — make `GjFondsInfo.gjEnde` nullable

File: `.../geschaeftsjahr/GjFondsInfo.java`

- Mark the `gjEnde` component `@Nullable`.
- Adjust the secondary constructor accordingly (or remove it if no longer
  needed).

### Step 3 — handle null `gjEnde` in `GeschaeftsjahreCalculator`

File: `.../geschaeftsjahr/GeschaeftsjahreCalculator.java`

- When `info.gjEnde() == null`:
  - If existing GJ rows can carry the Zeitreihe (CPP's "at least one GJ"
    branch) → compute as today, just skip any step that requires the
    INV-derived day/month.
  - If no existing GJ rows are usable → return a sentinel result that signals
    "no Zeitreihe available because INV.gj_ende is missing". Options:
    - return a typed empty `GjZeitreihe` plus a status flag; or
    - throw a dedicated `MissingInvGjEndeException` that the caller can
      distinguish from other failures.
  - Decision point for review with the colleague: which signalling shape do
    we prefer? (sentinel vs typed exception)

### Step 4 — explicit `ERR_GJE_FEHLT` in the validation service

File: `.../validation/SteuerMeldungDomainValidationService.java`
(around lines 402-431)

- Replace the broad `try/catch (IllegalStateException)` with handling for the
  dedicated signal from Step 3.
- When the calc reports "no Zeitreihe available due to missing INV.gj_ende"
  **and** `"A".equals(inv.getStatus())` (matches the status guard already
  inside `errGjeFehlt`) → add `ERR_GJE_FEHLT` directly to `validationMsgs`,
  using `stmGjEnde.position()`, severity `ERROR`.
- Skip the remaining GJ-table validations (they all need a Zeitreihe).
- Keep the existing `log.warn` for unexpected calc failures unrelated to
  gj_ende.

### Step 5 — tests

- Unit test in `SteuerMeldungDomainValidationServiceTest` (or the appropriate
  validator test class) for the scenarios:
  - INV.gj_ende null, status `"A"`, no existing GJ rows → expect
    `ERR_GJE_FEHLT` and no other GJ-table errors.
  - INV.gj_ende null, status `"A"`, existing GJ rows present → expect normal
    GJ-table validation outcome (no spurious `ERR_GJE_FEHLT`).
  - INV.gj_ende null, status `≠ "A"` → no `ERR_GJE_FEHLT` (matches existing
    `errGjeFehlt` guard).
  - INV.gj_ende null, `stichtag < fondsBeginn` → CPP returns 0; we should
    short-circuit before the missing-gj_ende signal fires.
- Update existing tests that rely on the current "exception swallowed → empty
  result" behaviour.

## Open questions for the discussion

1. **Signalling shape** in `GeschaeftsjahreCalculator` — sentinel value vs
   typed exception? Sentinel is easier to test, but the calculator currently
   has a single return type; a typed exception keeps the happy path clean.
2. **"At least one GJ row exists" behaviour** — do we want to faithfully
   mirror CPP (compute from existing rows even if INV.gj_ende is null), or
   treat null gj_ende as always an error regardless of existing rows? The
   first is closer to the legacy contract; the second is simpler and may be
   acceptable if business agrees current data quality should not be papered
   over.
3. **Status guard placement** — keep the `"A".equals(invStatus)` check
   inside the `errGjeFehlt` helper (current location), or hoist it to the
   caller so the calc-cannot-proceed signal is the single source of truth?
4. **Other callers of `getOrCalcGeschaeftsjahre`** — `KestMeldefristCheckService`,
   `SteuerMeldungStatusValidationService`, `SteuerMeldungLieferungService`
   also call this. Confirm none of them implicitly depend on the current
   "throws on null gj_ende" behaviour; if they do, adjust per Step 3's
   signalling decision.

## Out of scope

- No change to CSV-level validations.
- No change to the `errGjeFehlt` helper itself; only its invocation path.
- No data-quality fix for the underlying missing `INV.gj_ende` rows — that
  is a separate Stammdaten concern.
